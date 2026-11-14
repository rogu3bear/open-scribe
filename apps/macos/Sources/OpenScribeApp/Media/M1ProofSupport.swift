// Proof launches exist only in Debug builds; candidates build Debug.
#if DEBUG
@preconcurrency import AVFoundation
import AppKit
import Darwin
import Foundation

/// Suspends a forced-termination case at its recording boundary; only the
/// parent process delivers SIGKILL.
final class M1KillCheckpoint: RecordingObserver {
  let boundary: RecordingBoundary
  let root: URL

  init(boundary: RecordingBoundary, root: URL) {
    self.boundary = boundary
    self.root = root
  }

  func recording(reached: RecordingBoundary, sessionId: String) {
    if reached == boundary { ProofFiles.suspend(phase: reached, sessionId: sessionId, root: root) }
  }
}

enum M1ProofError: Error {
  case failed(String)
}

func requireM1(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw M1ProofError.failed(message) }
}

/// The files every Debug proof leaves in its root for the harness: JSON
/// receipts, the kill checkpoint, and `proof-error`. Scripts read their names
/// and bytes, so each is written here and nowhere else.
enum ProofFiles {
  static func write(_ value: [String: Any], name: String, root: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try data.write(to: root.appendingPathComponent(name), options: .atomic)
  }

  static func suspend(phase: RecordingBoundary, sessionId: String, root: URL) {
    do {
      try write(
        ["phase": phase.rawValue, "session_id": sessionId, "pid": getpid()],
        name: "checkpoint.json", root: root)
      // A stopped process cannot accidentally pass the intended boundary while
      // the parent reads the journal and snapshots the source-media digests.
      guard kill(getpid(), SIGSTOP) == 0 else { throw POSIXError(.EIO) }
      // SIGCONT is not an admitted substitute for the external kill.
      throw M1ProofError.failed("checkpoint resumed without forced termination")
    } catch {
      fail(error, root: root)
      Darwin.exit(1)
    }
  }

  static func fail(_ error: Error, root: URL) {
    fail(String(describing: error), root: root)
  }

  static func fail(_ reason: String, root: URL) {
    try? reason.write(
      to: root.appendingPathComponent("proof-error"), atomically: true, encoding: .utf8)
  }

  @MainActor
  static func wait(root: URL, name: String) async throws {
    for _ in 0..<600 {
      if FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw M1ProofError.failed("timed out waiting for \(name)")
  }
}

extension LiveMicrophoneRecordingController {
  /// Returns once the recorder leaves `phase` or `timeout` passes. `start()`
  /// returns while Rust still waits for every source's first sample.
  func waitWhile(_ phase: LiveMicrophoneRecordingPhase, timeout: Duration = .seconds(60)) async {
    let deadline = ContinuousClock.now + timeout
    while self.phase == phase, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
  }
}

@MainActor
final class M1ProofPermission: MicrophonePermissionProviding {
  let currentState: MicrophonePermissionState = .authorized
  func request() async -> MicrophonePermissionState { currentState }
}

/// MainActor serializes proof emissions/factories, just as production adapters
/// serialize their writer queues. This substitutes audio and failure callbacks,
/// never the media writer, journal, lifecycle, playback plan, or storage policy.
final class M1ProofSource: MicrophoneCapturing, SystemAudioCapturing, @unchecked Sendable {
  let writer: ManagedSegmentWriting
  private let core: CaptureSourceCore
  private var firstSample: CaptureFirstSampleHandler?
  private var failure: (@Sendable () -> Void)?
  private var finalTime: UInt64?
  private(set) var stopped = false
  var liveAudio: LiveAudioListenerSlot { core.liveAudio }

  init(_ writer: ManagedSegmentWriting) {
    self.writer = writer
    core = CaptureSourceCore(writer: writer)
  }

  func start(
    onFirstSample: @escaping MicrophoneFirstSampleHandler,
    onObservation: @escaping MicrophoneHealthHandler,
    onFailure: @escaping MicrophoneFailureHandler
  ) throws {
    firstSample = onFirstSample
    failure = { onFailure(.writerFailed) }
  }

  func start(
    onFirstSample: @escaping SystemAudioFirstSampleHandler,
    onFailure: @escaping SystemAudioFailureHandler
  ) async throws {
    firstSample = onFirstSample
    failure = { onFailure(.streamStopped) }
  }

  func emit(at host: UInt64, frames: AVAudioFrameCount = 48_000) throws {
    try requireM1(!stopped, "emitted on stopped source")
    let mono = writer.authorization.channels == 1
    do {
      let (_, receipt) = try core.write(
        TimelineRuntimeProof.buffer(
          frames: frames, value: mono ? 8192 : 16384,
          channels: writer.authorization.channels, rightValue: -8192), hostTime: host)
      let seconds = Double(frames) / NativeCapturePolicy.current.sampleRate
      finalTime = host + AVAudioTime.hostTime(forSeconds: seconds)
      if let receipt { firstSample?(receipt) }
    } catch {
      failure?()
      throw error
    }
  }

  func lose() { failure?() }
  func stop() -> UInt64? {
    stopped = true
    return finalTime
  }
  func stop() async throws -> UInt64? {
    stopped = true
    return finalTime
  }
}

final class M1ProofInputs: @unchecked Sendable {
  private let proofRoot: URL
  private let lock = NSLock()
  private var storageOverride: UInt64?
  private var host = mach_absolute_time()
  // Factories and emissions are confined to MainActor.
  var microphone: M1ProofSource?
  var audio: M1ProofSource?

  init(root: URL) { proofRoot = root }

  var now: UInt64 { lock.withLock { host } }
  func advance(seconds: Double) {
    lock.withLock { host += AVAudioTime.hostTime(forSeconds: seconds) }
  }
  func advance() { advance(seconds: 1) }
  func storage(_ bytes: UInt64?) { lock.withLock { storageOverride = bytes } }
  func available(at path: String) throws -> UInt64 {
    do {
      let value = try lock.withLock({ storageOverride }) ?? RecorderStorage.availableBytes(at: path)
      try ProofFiles.write(
        ["available_bytes": value], name: "storage-probe.json", root: proofRoot)
      return value
    } catch {
      let observed = error as NSError
      try? ProofFiles.write(
        ["error_domain": observed.domain, "error_code": observed.code],
        name: "storage-probe.json", root: proofRoot)
      throw error
    }
  }
  func makeMicrophone(_ writer: ManagedSegmentWriting) -> M1ProofSource {
    let source = M1ProofSource(writer)
    microphone = source
    return source
  }
  func makeAudio(_ writer: ManagedSegmentWriting) -> M1ProofSource {
    let source = M1ProofSource(writer)
    audio = source
    return source
  }
}
#endif
