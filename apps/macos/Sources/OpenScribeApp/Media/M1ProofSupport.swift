@preconcurrency import AVFoundation
import AppKit
import Darwin
import Foundation

/// Inert in ordinary capture. The explicit process harness can suspend at a
/// real boundary; only its parent process delivers SIGKILL.
enum RecorderProofPhase: String, Sendable {
  case preparation, recording, stop, seal, processing
}

enum M1ProofError: Error {
  case failed(String)
}

func requireM1(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw M1ProofError.failed(message) }
}

enum M1ProofFiles {
  static func write(_ value: [String: Any], name: String, root: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try data.write(to: root.appendingPathComponent(name), options: .atomic)
  }

  static func suspend(phase: RecorderProofPhase, sessionId: String, root: URL) {
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
    try? String(describing: error).write(
      to: root.appendingPathComponent("proof-error"),
      atomically: true, encoding: .utf8)
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
  private var firstSample: MicrophoneFirstSampleHandler?
  private var failure: (@Sendable () -> Void)?
  private var firstSent = false
  private var finalTime: UInt64?
  private(set) var stopped = false

  init(_ writer: ManagedSegmentWriting) { self.writer = writer }

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
      _ = try writer.writeCapturedBuffer(
        TimelineRuntimeProof.buffer(
          frames: frames, value: mono ? 8192 : 16384,
          channels: writer.authorization.channels, rightValue: -8192), hostTime: host)
      finalTime = host + AVAudioTime.hostTime(forSeconds: Double(frames) / 48_000)
      if !firstSent {
        firstSent = true
        firstSample?(try writer.firstSampleReceipt(hostTime: host, frameCount: UInt64(frames)))
      }
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
  private let lock = NSLock()
  private var storageOverride: UInt64?
  private var host = mach_absolute_time()
  // Factories and emissions are confined to MainActor.
  var microphone: M1ProofSource?
  var audio: M1ProofSource?

  var now: UInt64 { lock.withLock { host } }
  func advance() { lock.withLock { host += AVAudioTime.hostTime(forSeconds: 1) } }
  func storage(_ bytes: UInt64?) { lock.withLock { storageOverride = bytes } }
  func available(at path: String) throws -> UInt64 {
    if let value = lock.withLock({ storageOverride }) { return value }
    return try RecorderStorage.availableBytes(at: path)
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
