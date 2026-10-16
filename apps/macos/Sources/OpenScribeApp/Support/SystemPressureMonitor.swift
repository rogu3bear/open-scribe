import Combine
import Darwin
import Foundation

/// Machine conditions that decide whether derived work should wait. Every
/// value is a macOS-reported measurement: the library volume's available
/// capacity for important usage, the kernel's memory-pressure level, host
/// memory statistics, the thermal state, and this process's own CPU time and
/// resident size. Nothing here is estimated or smoothed.
struct SystemPressureReading: Equatable, Sendable {
  enum MemoryPressure: String, Equatable, Sendable {
    case normal
    case warning
    case critical
  }

  /// Bytes the library volume can still give this app for important usage,
  /// from `volumeAvailableCapacityForImportantUsage`; `nil` when unreadable.
  let availableDiskBytes: Int64?
  /// The last level the kernel's memory-pressure source delivered.
  let memoryPressure: MemoryPressure
  /// Whether the kernel has delivered any memory-pressure event yet.
  let memoryPressureObserved: Bool
  /// Pages the host reports as free, from `host_statistics64`.
  let freeMemoryBytes: UInt64?
  /// Physical memory, from `ProcessInfo`.
  let totalMemoryBytes: UInt64
  let thermalState: ProcessInfo.ThermalState
  /// This process's CPU time over the last sampling interval, as cores
  /// (2.0 means two cores' worth); `nil` until two samples exist.
  let processCPUCores: Double?
  /// This process's resident memory, from `task_info`.
  let residentMemoryBytes: UInt64?
  let sampledAt: Date

  static let unknown = SystemPressureReading(
    availableDiskBytes: nil, memoryPressure: .normal, memoryPressureObserved: false,
    freeMemoryBytes: nil, totalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
    thermalState: .nominal, processCPUCores: nil, residentMemoryBytes: nil,
    sampledAt: .distantPast)

  /// Below this, transcription waits so capture keeps room to write.
  static let minimumDiskBytesForTranscription: Int64 = 1 << 30

  var diskIsLow: Bool {
    guard let availableDiskBytes else { return false }
    return availableDiskBytes < Self.minimumDiskBytesForTranscription
  }

  var memoryIsCritical: Bool { memoryPressure == .critical }

  var thermalIsCritical: Bool { thermalState == .critical }

  /// Why derived work should wait, in the user's words; `nil` when nothing
  /// measured says so.
  var transcriptionHoldReason: String? {
    if diskIsLow {
      return
        "Waiting: less than \(Self.bytes(Self.minimumDiskBytesForTranscription)) is free on the library disk."
    }
    if memoryIsCritical {
      return "Waiting: macOS reports critical memory pressure."
    }
    if thermalIsCritical {
      return "Waiting: this Mac is too hot to add work."
    }
    return nil
  }

  var diskText: String {
    guard let availableDiskBytes else { return "Disk space unavailable" }
    return "\(Self.bytes(availableDiskBytes)) free"
  }

  var memoryText: String {
    let level: String
    switch memoryPressure {
    case .normal: level = memoryPressureObserved ? "normal" : "no pressure reported"
    case .warning: level = "warning"
    case .critical: level = "critical"
    }
    if let freeMemoryBytes {
      return
        "Memory \(level), \(Self.bytes(Int64(clamping: freeMemoryBytes))) unused of \(Self.bytes(Int64(clamping: totalMemoryBytes)))"
    }
    return "Memory \(level)"
  }

  var thermalText: String {
    switch thermalState {
    case .nominal: "Thermal state normal"
    case .fair: "Thermal state fair"
    case .serious: "Thermal state serious"
    case .critical: "Thermal state critical"
    @unknown default: "Thermal state unknown"
    }
  }

  /// This app's own use while it works; `nil` before two samples.
  var processText: String? {
    guard let processCPUCores, let residentMemoryBytes else { return nil }
    let cores = String(format: "%.1f", processCPUCores)
    return
      "Open Scribe using \(cores) CPU cores, \(Self.bytes(Int64(clamping: residentMemoryBytes))) resident"
  }

  static func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }
}

/// Samples `SystemPressureReading` on a fixed cadence and on kernel events.
/// It never changes a thing; the scheduler and the views read it.
@MainActor
final class SystemPressureMonitor: ObservableObject {
  @Published private(set) var reading: SystemPressureReading = .unknown

  private let libraryRoot: URL?
  private let interval: Duration
  private var memorySource: DispatchSourceMemoryPressure?
  /// Cancels itself when the monitor is released.
  private var thermalSubscription: AnyCancellable?
  private var samplingTask: Task<Void, Never>?
  private var memoryPressure: SystemPressureReading.MemoryPressure = .normal
  private var memoryPressureObserved = false
  private var lastCPUSample: (wall: Date, cpu: TimeInterval)?

  init(libraryRoot: URL?, interval: Duration = .seconds(3), samplesAutomatically: Bool = true) {
    self.libraryRoot = libraryRoot
    self.interval = interval
    guard samplesAutomatically else { return }
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      let event = source.data
      self.memoryPressureObserved = true
      if event.contains(.critical) {
        self.memoryPressure = .critical
      } else if event.contains(.warning) {
        self.memoryPressure = .warning
      } else {
        self.memoryPressure = .normal
      }
      self.sample()
    }
    source.resume()
    memorySource = source
    thermalSubscription = NotificationCenter.default
      .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.sample() }
    sample()
    samplingTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        self?.sample()
      }
    }
  }

  deinit {
    samplingTask?.cancel()
    memorySource?.cancel()
  }

  /// Reads every measurement once and publishes the result.
  func sample() {
    let now = Date()
    let cpu = Self.processCPUTime()
    var cores: Double?
    if let last = lastCPUSample {
      let wall = now.timeIntervalSince(last.wall)
      if wall > 0.5 {
        cores = max(0, (cpu - last.cpu) / wall)
        lastCPUSample = (now, cpu)
      } else {
        cores = reading.processCPUCores
      }
    } else {
      lastCPUSample = (now, cpu)
    }
    let next = SystemPressureReading(
      availableDiskBytes: libraryRoot.flatMap(Self.availableDiskBytes(at:)),
      memoryPressure: memoryPressure,
      memoryPressureObserved: memoryPressureObserved,
      freeMemoryBytes: Self.hostFreeMemoryBytes(),
      totalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      thermalState: ProcessInfo.processInfo.thermalState,
      processCPUCores: cores,
      residentMemoryBytes: Self.residentMemoryBytes(),
      sampledAt: now)
    if next != reading {
      reading = next
    }
  }

  /// `volumeAvailableCapacityForImportantUsage` on the volume holding `url`:
  /// what macOS will let this app write, counting purgeable space.
  nonisolated static func availableDiskBytes(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  nonisolated static func hostFreeMemoryBytes() -> UInt64? {
    var statistics = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
    return UInt64(statistics.free_count) * UInt64(pageSize)
  }

  nonisolated static func residentMemoryBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(info.resident_size)
  }

  /// User plus system CPU seconds this process has consumed.
  nonisolated static func processCPUTime() -> TimeInterval {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    let user =
      TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
    let system =
      TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
    return user + system
  }
}
