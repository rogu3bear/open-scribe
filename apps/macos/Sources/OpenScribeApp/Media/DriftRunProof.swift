import Foundation

/// The recorder half of the two-hour synchronization run (ADR 0005; the M1
/// operator session). It records both required sources, reports durable
/// capture so the operator script can start the stimulus in a separate
/// process (system-audio capture excludes this app's own output), stops at a
/// scheduled deadline, and reports the saved session. It never records past
/// its deadline or past three hours. Rust measures the drift afterwards.
@MainActor
enum DriftRunProof {
  static let maximumSeconds: UInt64 = 3 * 60 * 60
  static let startedName = "capture-started.json"
  static let outcomeName = "run.json"

  struct Outcome: Codable, Equatable {
    var result: String
    var detail: String
    var requestedSeconds: UInt64
    var recordedSeconds: Double
    var sessionId: String?
  }

  /// `uptime` is monotonic seconds; `sleep` takes nanoseconds.
  static func run(
    controller: LiveMicrophoneRecordingController,
    root: URL,
    seconds: UInt64,
    uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: @escaping (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
  ) async -> Outcome {
    var outcome = Outcome(
      result: "refused", detail: "duration", requestedSeconds: seconds, recordedSeconds: 0,
      sessionId: nil)
    guard (1...maximumSeconds).contains(seconds) else {
      write(outcome, named: outcomeName, in: root)
      return outcome
    }
    await controller.start()
    for _ in 0..<600 where controller.phase != .capturing && controller.phase != .failed {
      await sleep(100_000_000)
    }
    guard controller.phase == .capturing else {
      outcome.result = "failed"
      outcome.detail = controller.failureCode ?? controller.phase.rawValue
      write(outcome, named: outcomeName, in: root)
      return outcome
    }
    let started = uptime()
    write(
      ["phase": "capturing", "requested_seconds": String(seconds)], named: startedName, in: root)
    let deadline = started + TimeInterval(seconds)
    while uptime() < deadline, controller.phase == .capturing {
      await sleep(UInt64(min(1, deadline - uptime()) * 1_000_000_000))
    }
    let interrupted = controller.phase != .capturing
    outcome.recordedSeconds = uptime() - started
    if !interrupted {
      await controller.stop()
    }
    outcome.sessionId = controller.lastSavedSessionId
    outcome.result = !interrupted && controller.phase == .saved ? "saved" : "failed"
    outcome.detail = interrupted ? "capture_stopped_early" : controller.phase.rawValue
    write(outcome, named: outcomeName, in: root)
    return outcome
  }

  private static func write<Value: Encodable>(_ value: Value, named name: String, in root: URL) {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return }
    try? data.write(to: root.appendingPathComponent(name), options: .atomic)
  }
}
