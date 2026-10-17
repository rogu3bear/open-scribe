import Darwin
import Foundation
import XCTest

@testable import OpenScribeApp

/// Observes the production logger in the isolated production test host. Empty
/// output is a failed observation, never evidence that private content is absent.
@MainActor
final class DiagnosticsUnifiedLogTests: XCTestCase {
  func testEmptyMissingAndForeignObservationsCannotQualifyTheLogSink() throws {
    let expected = UnifiedLogExpectation(
      category: "Library", message: "stage=snapshot detail=count=1")
    for records: [[String: Any]] in [
      [],
      [
        [
          "processID": 42, "subsystem": "other", "category": "Library",
          "eventMessage": expected.message,
        ]
      ],
      [
        [
          "processID": 43, "subsystem": "test", "category": "Library",
          "eventMessage": expected.message,
        ]
      ],
    ] {
      let data = try JSONSerialization.data(withJSONObject: records)
      XCTAssertThrowsError(
        try UnifiedLogObservation.validate(
          data, process: 42, subsystem: "test", expected: [expected], canaries: []))
    }
    let leaked = try JSONSerialization.data(withJSONObject: [
      [
        "processID": 42, "subsystem": "test", "category": "Library",
        "eventMessage": expected.message,
      ],
      [
        "processID": 42, "subsystem": "test", "category": "Launch",
        "eventMessage": "FICTIONAL_SECRET",
      ],
    ])
    XCTAssertThrowsError(
      try UnifiedLogObservation.validate(
        leaked, process: 42, subsystem: "test", expected: [expected], canaries: ["FICTIONAL_SECRET"]
      ))
    let valid = try JSONSerialization.data(withJSONObject: [
      [
        "processID": 42, "subsystem": "test", "category": "Library",
        "eventMessage": expected.message,
      ]
    ])
    let banner = Data(UnifiedLogObservation.banner(process: 42, subsystem: "test").utf8)
    XCTAssertEqual(
      try UnifiedLogObservation.validate(
        banner + valid, process: 42, subsystem: "test", expected: [expected], canaries: []), 1)
    XCTAssertThrowsError(
      try UnifiedLogObservation.validate(
        Data("unknown preamble\n".utf8) + valid,
        process: 42, subsystem: "test", expected: [expected], canaries: []))
    XCTAssertThrowsError(
      try UnifiedLogObservation.validate(
        valid, process: 42, subsystem: "test", expected: [], canaries: []))
  }

  func testProductionTelemetryReachesTheLiveUnifiedLogWithoutFictionalContent() async throws {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "app.open-scribe.dev.verification")
    let subsystem = try XCTUnwrap(Bundle.main.bundleIdentifier)
    let process = ProcessInfo.processInfo.processIdentifier
    let start = "stage=snapshot detail=session=\(UUID().uuidString)"
    let end = "stage=snapshot detail=session=\(UUID().uuidString)"
    let canaries = [
      "FICTIONAL_TRANSCRIPT_94E2", "FICTIONAL_OCR_94E2", "/fictional/private-path-94E2",
      "FICTIONAL_CREDENTIAL_94E2", "FICTIONAL_PARTICIPANT_94E2", "FICTIONAL_PROMPT_94E2",
      "FICTIONAL_WINDOW_94E2", "FICTIONAL_PERMISSION_94E2",
    ]
    let capture = try LiveUnifiedLogCapture(process: process, subsystem: subsystem)
    defer {
      capture.close()
      let attachment = XCTAttachment(data: capture.data, uniformTypeIdentifier: "public.json")
      attachment.name = "production-unified-log-privacy"
      attachment.lifetime = .keepAlways
      add(attachment)
      let errors = XCTAttachment(string: capture.errorText)
      errors.name = "owned-unified-log-observer-stderr"
      errors.lifetime = .keepAlways
      add(errors)
    }
    let readyDeadline = ContinuousClock.now + .seconds(3)
    while capture.isRunning && !capture.text.contains(start) && ContinuousClock.now < readyDeadline
    {
      AppTelemetry.libraryNote(
        stage: "snapshot", detail: String(start.dropFirst("stage=snapshot detail=".count)))
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertTrue(
      capture.text.contains(start), "The live observer did not receive its positive control")
    guard capture.text.contains(start) else { return }

    DiagnosticJournal.shared.resetForTest()
    defer { DiagnosticJournal.shared.resetForTest() }
    AppTelemetry.commandInvoked(canaries[0])
    AppTelemetry.captureProof(stage: "requested", detail: canaries[1])
    AppTelemetry.recoveryProof(stage: "scan-failed", detail: canaries[2])
    AppTelemetry.launchFailed(canaries[3])
    AppTelemetry.libraryNote(stage: "snapshot", detail: canaries[4])
    AppTelemetry.performanceStall(operation: canaries[5], milliseconds: 123)
    AppTelemetry.runtimeSceneAppeared(canaries[6], session: nil)
    AppTelemetry.launchAdmitted(microphone: canaries[7], screenCapture: canaries[7])

    let expected: [UnifiedLogExpectation] = [
      .init(category: "Commands", message: "command=redacted"),
      .init(category: "CaptureProof", message: "stage=requested detail=redacted"),
      .init(category: "RecoveryProof", message: "redacted=private_or_unbounded"),
      .init(category: "Launch", message: "single_instance_failure=redacted"),
      .init(category: "Library", message: "stage=snapshot detail=redacted"),
      .init(category: "Performance", message: "operation=redacted milliseconds=123"),
      .init(
        category: "Scenes",
        message:
          "scene=redacted runtime_session=none lifecycle=idle journal_durable=false media_files_open=false"
      ),
      .init(category: "Launch", message: "admitted microphone=redacted screen_capture=redacted"),
    ]
    let journal = DiagnosticJournal.shared.recent()
    for line in expected {
      XCTAssertTrue(journal.contains { $0.category == line.category && $0.message == line.message })
    }
    XCTAssertFalse(journal.contains { event in canaries.contains { event.message.contains($0) } })
    AppTelemetry.libraryNote(
      stage: "snapshot", detail: String(end.dropFirst("stage=snapshot detail=".count)))
    let deadline = ContinuousClock.now + .seconds(8)
    while capture.isRunning && ContinuousClock.now < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertFalse(capture.isRunning, "The owned log observer exceeded its bounded timeout")
    let data = try capture.finish()
    let count = try UnifiedLogObservation.validate(
      data, process: process, subsystem: subsystem,
      expected: [.init(category: "Library", message: start)] + expected
        + [.init(category: "Library", message: end)], canaries: canaries)
    print(
      "UNIFIED_LOG_PRIVACY_NATIVE_GREEN observed=\(count) expected=\(expected.count) process=\(process)"
    )
  }
}

private struct UnifiedLogExpectation {
  let category: String
  let message: String
}

private enum UnifiedLogObservation {
  enum Failure: Error { case malformed, missingExpectedEvent, privateContent, observerFailure }

  static func banner(process: Int32, subsystem: String) -> String {
    "Filtering the log data using \"processIdentifier == \(process) AND subsystem == \"\(subsystem)\" AND type == 1024\"\n"
  }

  static func validate(
    _ data: Data, process: Int32, subsystem: String,
    expected: [UnifiedLogExpectation], canaries: [String]
  ) throws -> Int {
    // `log stream --style json` prepends this exact, process-bound status line
    // on stdout. Remove only that known header; unexpected framing still fails.
    let header = Data(banner(process: process, subsystem: subsystem).utf8)
    let payload = data.starts(with: header) ? Data(data.dropFirst(header.count)) : data
    guard let records = try JSONSerialization.jsonObject(with: payload) as? [[String: Any]],
      !records.isEmpty, !expected.isEmpty
    else { throw Failure.malformed }
    for record in records {
      guard record["processID"] as? Int == Int(process),
        record["subsystem"] as? String == subsystem
      else { throw Failure.malformed }
      guard let message = record["eventMessage"] as? String else { throw Failure.malformed }
      guard !canaries.contains(where: message.contains) else { throw Failure.privateContent }
    }
    for line in expected {
      guard
        records.contains(where: {
          $0["category"] as? String == line.category
            && $0["eventMessage"] as? String == line.message
        })
      else { throw Failure.missingExpectedEvent }
    }
    return records.count
  }
}

/// This test owns only this read-only `log stream` process and its pipes. The
/// subprocess has an independent six-second timeout; cleanup never signals an app.
private final class LiveUnifiedLogCapture {
  private let process = Process()
  private let output = BoundedLogBytes()
  private let errors = BoundedLogBytes()
  private let readers = DispatchGroup()

  init(process identifier: Int32, subsystem: String) throws {
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "stream", "--style", "json", "--level", "info", "--type", "log", "--timeout", "6",
      "--process", String(identifier), "--predicate", "subsystem == '\(subsystem)'",
    ]
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    drain(stdout.fileHandleForReading, into: output)
    drain(stderr.fileHandleForReading, into: errors)
  }

  var isRunning: Bool { process.isRunning }
  var data: Data { output.snapshot() }
  var text: String { String(decoding: output.snapshot(), as: UTF8.self) }
  var errorText: String { String(decoding: errors.snapshot(), as: UTF8.self) }

  func finish() throws -> Data {
    guard !process.isRunning else { throw UnifiedLogObservation.Failure.observerFailure }
    process.waitUntilExit()
    guard readers.wait(timeout: .now() + 2) == .success,
      process.terminationStatus == 0, !output.failed, !errors.failed
    else { throw UnifiedLogObservation.Failure.observerFailure }
    return output.snapshot()
  }

  func close() {
    if process.isRunning { process.terminate() }
    let deadline = Date().addingTimeInterval(1)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    _ = readers.wait(timeout: .now() + 2)
  }

  private func drain(_ handle: FileHandle, into destination: BoundedLogBytes) {
    readers.enter()
    let readers = readers
    DispatchQueue.global(qos: .utility).async {
      defer { readers.leave() }
      do {
        while let bytes = try handle.read(upToCount: 4_096), !bytes.isEmpty {
          destination.append(bytes)
        }
        try handle.close()
      } catch { destination.markFailed() }
    }
  }
}

private final class BoundedLogBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  private var didFail = false

  var failed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didFail
  }

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard bytes.count + data.count <= 512 * 1_024 else {
      didFail = true
      return
    }
    bytes.append(data)
  }

  func markFailed() {
    lock.lock()
    didFail = true
    lock.unlock()
  }
  func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return bytes
  }
}
