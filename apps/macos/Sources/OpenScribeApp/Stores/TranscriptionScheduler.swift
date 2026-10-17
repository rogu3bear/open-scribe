import Combine
import Foundation

enum TranscriptionHold: Equatable, Sendable {
  case pausedByUser, recordingInProgress, launchRecoveryPending, noSpeechModel
  case pressure(String)
  case unavailable(String)
  init(_ hold: NativeWorkHold) {
    switch hold {
    case .capture: self = .recordingInProgress
    case .mediaRecovery: self = .launchRecoveryPending
    case .automaticPaused: self = .pausedByUser
    case .modelAbsent: self = .noSpeechModel
    case .diskPressure:
      self = .pressure(
        "Waiting: less than \(SystemPressureReading.bytes(SystemPressureReading.minimumDiskBytesForTranscription)) is free on the library disk."
      )
    case .memoryPressure: self = .pressure("Waiting: macOS reports critical memory pressure.")
    case .thermalPressure: self = .pressure("Waiting: this Mac is too hot to add work.")
    case .modelUnverified: self = .unavailable("Waiting for speech model verification.")
    case .modelInvalid:
      self = .unavailable("The speech model needs repair. Choose a replacement file in Settings.")
    case .modelIncompatible:
      self = .unavailable("The speech model is incompatible with this engine.")
    case .automaticDisabled: self = .unavailable("Automatic transcription is off.")
    case .alreadyRunning: self = .unavailable("Waiting for the current transcription.")
    case .noAudio: self = .unavailable("No transcribable audio is available.")
    case .unknownState:
      self = .unavailable("Transcript status is unavailable; work was not started.")
    }
  }
  var text: String {
    switch self {
    case .pausedByUser: "Paused by you."
    case .recordingInProgress: "Waiting for the current recording to finish."
    case .launchRecoveryPending: "Waiting for capture-safety recovery."
    case .noSpeechModel: "Waiting for a speech model to be installed."
    case .pressure(let text), .unavailable(let text): text
    }
  }
}
struct TranscriptionQueueEntry: Equatable, Identifiable, Sendable {
  let sessionId: String
  let requestedByUser: Bool
  var id: String { sessionId }
}
enum TranscriptionOutcome: Equatable, Sendable {
  case finished(String)
  case failed(String)
  case cancelled, preempted, deferred, incomplete
}
enum TranscriptionJobState: Equatable, Sendable {
  case queued(position: Int, hold: TranscriptionHold?)
  case running
  case finished(String)
  case failed(String)
  case cancelled, preempted, deferred, incomplete
}

/// Native measurements and execution adapter. Rust persists intent and owns
/// eligibility, order, admission, and outcomes. Refreshes cannot replace a live
/// runner or reconstruct its origin from presentation flags.
@MainActor
final class TranscriptionScheduler: ObservableObject {
  typealias Runner = @MainActor (NativeTranscriptionWork) async -> NativeWorkOutcome
  static let automaticDefaultsKey = "OpenScribeTranscribeNewRecordingsAutomatically"
  static let pausedDefaultsKey = "OpenScribeTranscriptionPaused"
  static let declinedDefaultsKey = "OpenScribeTranscriptionDeclinedSessions"
  @Published private(set) var queue: [TranscriptionQueueEntry] = []
  @Published private(set) var runningSessionId: String?
  @Published private(set) var hold: TranscriptionHold?
  @Published private(set) var outcomes: [String: TranscriptionOutcome] = [:]
  @Published var isAutomatic: Bool {
    didSet {
      defaults.set(isAutomatic, forKey: Self.automaticDefaultsKey)
      reconsider()
    }
  }
  @Published var isPaused: Bool {
    didSet {
      defaults.set(isPaused, forKey: Self.pausedDefaultsKey)
      reconsider()
    }
  }
  var automationSuspended = false { didSet { reconsider() } }
  private let defaults: UserDefaults
  private let coordinator: NativeWorkCoordinator?
  private let runner: Runner
  private let observations: @MainActor () -> NativeWorkObservations
  private let stop: @MainActor (Bool) -> Void
  private let maintenanceWarning: @MainActor (String?) -> Void
  private var subscriptions = Set<AnyCancellable>()
  private var refreshTask: Task<Void, Never>?
  private var commandTask: Task<Void, Never>?
  private var workTask: Task<Void, Never>?
  private var maintenanceTask: Task<Void, Never>?
  private var maintenanceJob: NativeTranscriptionJob?
  private var recoveredIntent = false
  private var maintenanceComplete = false
  private var refreshAgain = false

  init(
    coordinator: NativeWorkCoordinator?, runner: @escaping Runner,
    observations: @escaping @MainActor () -> NativeWorkObservations,
    stop: @escaping @MainActor (Bool) -> Void, defaults: UserDefaults,
    maintenanceWarning: @escaping @MainActor (String?) -> Void = { _ in }
  ) {
    self.coordinator = coordinator
    self.runner = runner
    self.observations = observations
    self.stop = stop
    self.defaults = defaults
    self.maintenanceWarning = maintenanceWarning
    defaults.register(defaults: [Self.automaticDefaultsKey: true, Self.pausedDefaultsKey: false])
    isAutomatic = defaults.bool(forKey: Self.automaticDefaultsKey)
    isPaused = defaults.bool(forKey: Self.pausedDefaultsKey)
  }
  convenience init(
    managedRoot: URL?, speech: SpeechTranscriptionModel, store: RuntimeLibraryStore,
    liveRecording: LiveMicrophoneRecordingController, recovery: RecoveredSessionController,
    pressure: SystemPressureMonitor, defaults: UserDefaults = .standard
  ) {
    self.init(
      coordinator: try? managedRoot.map { try NativeWorkCoordinator.open(managedRoot: $0.path) },
      runner: {
        await speech.process(sessionId: $0.sessionId, intent: $0.intent, admission: $0.admission)
      },
      observations: {
        NativeWorkObservations(
          automatic: true, paused: false,
          captureActive: ![.idle, .saved, .failed].contains(liveRecording.phase),
          mediaRecoveryPending: !recovery.captureSafetyComplete, model: speech.readiness,
          availableDiskBytes: pressure.reading.availableDiskBytes.map { UInt64(clamping: $0) },
          memoryCritical: pressure.reading.memoryIsCritical,
          thermalCritical: pressure.reading.thermalIsCritical)
      }, stop: { preempt in preempt ? speech.preemptForCapture() : speech.cancel() },
      defaults: defaults, maintenanceWarning: { recovery.reportTranscriptMaintenance($0) })
    store.$savedSessions.sink { [weak self] _ in Task { @MainActor in self?.reconsider() } }.store(
      in: &subscriptions)
    store.$currentSession.sink { [weak self] _ in Task { @MainActor in self?.reconsider() } }.store(
      in: &subscriptions)
    liveRecording.$phase.sink { [weak self] _ in Task { @MainActor in self?.reconsider() } }.store(
      in: &subscriptions)
    recovery.$captureSafetyComplete.sink { [weak self] _ in
      Task { @MainActor in self?.reconsider() }
    }.store(in: &subscriptions)
    pressure.$reading.sink { [weak self] _ in Task { @MainActor in self?.reconsider() } }.store(
      in: &subscriptions)
    speech.$models.sink { [weak self] _ in Task { @MainActor in self?.reconsider() } }.store(
      in: &subscriptions)
    speech.$isRefreshing.sink { [weak self] _ in Task { @MainActor in self?.reconsider() } }.store(
      in: &subscriptions)
  }
  deinit {
    refreshTask?.cancel()
    maintenanceJob?.cancel()
  }
  static func inert() -> TranscriptionScheduler {
    TranscriptionScheduler(
      coordinator: nil, runner: { _ in .deferred },
      observations: {
        NativeWorkObservations(
          automatic: false, paused: false, captureActive: false,
          mediaRecoveryPending: true, model: .absent, availableDiskBytes: nil,
          memoryCritical: false, thermalCritical: false)
      }, stop: { _ in }, defaults: UserDefaults(suiteName: "OpenScribe.Proof.Inert.\(UUID())")!)
  }
  func observe(saved: [RuntimeSessionPresentation]) { reconsider() }
  func request(sessionId: String, intent: NativeTranscriptionIntent = .resumeIncomplete) {
    command { try $0.request(sessionId: sessionId, intent: intent) }
  }
  func resumeReplacement(sessionId: String) {
    command { try $0.resumeReplacement(sessionId: sessionId) }
  }
  func cancel(sessionId: String) {
    if runningSessionId == sessionId { stop(false) }
    command { try $0.cancel(sessionId: sessionId) }
  }
  private func command(_ operation: @escaping @Sendable (NativeWorkCoordinator) throws -> Void) {
    guard let coordinator else { return }
    let previous = commandTask
    commandTask = Task {
      await previous?.value
      do { try await StructuredNativeIO.mutation { try operation(coordinator) } } catch {
        hold = .unavailable("The transcription request could not be saved. Try again.")
      }
      reconsider()
    }
  }
  func state(for sessionId: String) -> TranscriptionJobState? {
    if runningSessionId == sessionId { return .running }
    if let index = queue.firstIndex(where: { $0.sessionId == sessionId }) {
      return .queued(position: index + 1, hold: index == 0 ? hold : nil)
    }
    switch outcomes[sessionId] {
    case .finished(let text): return .finished(text)
    case .failed(let text): return .failed(text)
    case .cancelled: return .cancelled
    case .preempted: return .preempted
    case .deferred: return .deferred
    case .incomplete: return .incomplete
    case nil: return nil
    }
  }
  func canPrioritize(sessionId: String) -> Bool {
    queue.contains { $0.sessionId == sessionId && !$0.requestedByUser }
  }
  func dismissOutcome(sessionId: String) { outcomes[sessionId] = nil }
  private var currentObservations: NativeWorkObservations {
    let value = observations()
    return NativeWorkObservations(
      automatic: isAutomatic && !automationSuspended, paused: isPaused,
      captureActive: value.captureActive, mediaRecoveryPending: value.mediaRecoveryPending,
      model: value.model, availableDiskBytes: value.availableDiskBytes,
      memoryCritical: value.memoryCritical, thermalCritical: value.thermalCritical)
  }
  func reconsider() {
    if currentObservations.captureActive {
      if workTask != nil { stop(true) }
      maintenanceJob?.preemptForCapture()
    }
    guard refreshTask == nil else {
      refreshAgain = true
      return
    }
    guard let coordinator else { return }
    refreshTask = Task {
      defer {
        refreshTask = nil
        if refreshAgain {
          refreshAgain = false
          reconsider()
        }
      }
      let observed = currentObservations
      guard !observed.mediaRecoveryPending else {
        hold = .launchRecoveryPending
        return
      }
      do {
        if !recoveredIntent {
          try await StructuredNativeIO.mutation { try coordinator.recoverIntent() }
          // Migrate surviving legacy opt-outs once; SQLite owns later choices.
          if let declined = defaults.stringArray(forKey: Self.declinedDefaultsKey) {
            var migrated = true
            for id in declined {
              do {
                try await StructuredNativeIO.mutation { try coordinator.cancel(sessionId: id) }
              } catch { migrated = false }
            }
            if migrated { defaults.removeObject(forKey: Self.declinedDefaultsKey) }
          }
          recoveredIntent = true
        }
        let list = try await StructuredNativeIO.read {
          try coordinator.queue(observations: observed)
        }
        queue = list.filter { $0.admission == nil }.map {
          TranscriptionQueueEntry(sessionId: $0.sessionId, requestedByUser: $0.manual)
        }
        hold = list.first(where: { $0.admission == nil })?.hold.map(TranscriptionHold.init)
        let saved = try await StructuredNativeIO.read { try coordinator.outcomes() }
        outcomes = Dictionary(
          uniqueKeysWithValues: saved.map { ($0.sessionId, Self.presentation($0.outcome)) })
        guard workTask == nil, maintenanceTask == nil, !Task.isCancelled else { return }
        let latest = currentObservations
        if let admitted = try await StructuredNativeIO.mutation({
          try coordinator.admit(observations: latest)
        }) {
          start(admitted, coordinator: coordinator)
        } else if !maintenanceComplete && !automationSuspended {
          startMaintenance(coordinator)
        }
      } catch {
        hold = .unavailable(
          "The transcript queue is unavailable. Recorded audio remains in the library.")
      }
    }
  }
  private func startMaintenance(_ coordinator: NativeWorkCoordinator) {
    let job = NativeTranscriptionJob()
    let observed = currentObservations
    maintenanceJob = job
    maintenanceTask = Task {
      do {
        let outcome = try await StructuredNativeIO.mutation {
          try coordinator.maintainRetained(job: job, observations: observed)
        }
        maintenanceComplete = outcome == .completed
        maintenanceWarning(nil)
      } catch {
        maintenanceComplete = true
        maintenanceWarning(
          "Transcript maintenance could not finish. Recovered audio remains available; retry transcription when ready."
        )
      }
      maintenanceJob = nil
      maintenanceTask = nil
      if maintenanceComplete { reconsider() }
    }
  }
  private func start(_ entry: NativeTranscriptionWork, coordinator: NativeWorkCoordinator) {
    guard let token = entry.admission else { return }
    runningSessionId = entry.sessionId
    queue.removeAll { $0.sessionId == entry.sessionId }
    workTask = Task {
      let outcome = await runner(entry)
      do {
        try await StructuredNativeIO.mutation {
          try coordinator.finish(admission: token, outcome: outcome)
        }
      } catch {
        hold = .unavailable(
          "Completion could not be saved. The next library recovery will reconcile durable work.")
      }
      outcomes[entry.sessionId] = Self.presentation(outcome)
      runningSessionId = nil
      workTask = nil
      reconsider()
    }
  }
  private static func presentation(_ outcome: NativeWorkOutcome) -> TranscriptionOutcome {
    switch outcome {
    case .completed: .finished("Transcript ready.")
    case .userCancelled: .cancelled
    case .capturePreempted: .preempted
    case .failed: .failed("Transcription did not finish. The recorded audio is unchanged.")
    case .deferred: .deferred
    case .incomplete: .incomplete
    }
  }
  func summaryText(titles: [String: String], progress: Double?) -> String? {
    if let runningSessionId {
      let text = "Transcribing “\(titles[runningSessionId] ?? "a conversation")”"
      return progress.map { "\(text), \(Int(($0 * 100).rounded()))%" } ?? text
    }
    if !queue.isEmpty {
      return "\(queue.count) conversation\(queue.count == 1 ? "" : "s") waiting for a transcript"
        + (hold.map { ". \($0.text)" } ?? "")
    }
    if automationSuspended { return nil }
    if isPaused { return "Automatic transcription paused" }
    if !isAutomatic { return "Automatic transcription off" }
    return hold?.text
  }
}
