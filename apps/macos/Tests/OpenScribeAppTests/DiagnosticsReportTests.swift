import XCTest

@testable import OpenScribeApp

final class DiagnosticsReportTests: XCTestCase {
  override func tearDown() {
    DiagnosticJournal.shared.resetForTest()
    super.tearDown()
  }

  func testReportKeepsModelIdentityAndOmitsATitleItWasNotGiven() {
    let text = DiagnosticsReport.text(
      product: "Open Scribe",
      version: "0.0.0",
      build: "1",
      operatingSystem: "Version 27.0",
      architecture: "arm64",
      bundleIdentifier: "app.open-scribe.dev",
      microphone: "notDetermined",
      screenCapture: "not_authorized",
      signature: "unsigned",
      recoveryPhase: "none",
      recoveredCount: 0,
      sessions: [
        DiagnosticsReport.SessionLine(
          sessionId: "session-1",
          lifecycle: "ready_for_review",
          health: "healthy",
          recovered: false,
          journalDurable: true,
          mediaFilesOpen: false
        )
      ],
      models: [
        DiagnosticsReport.ModelLine(
          modelId: "whisper-tiny", fileName: "ggml-tiny.bin", installed: false)
      ],
      events: [
        DiagnosticEvent(
          category: "Scenes",
          message: "scene=settings lifecycle=idle",
          recordedAt: Date(timeIntervalSince1970: 0),
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
      ]
    )

    XCTAssertTrue(text.contains("microphone=notDetermined"))
    XCTAssertTrue(text.contains("signature=unsigned"))
    XCTAssertTrue(text.contains("recovery_phase=none"))
    XCTAssertTrue(
      text.contains(
        "session id=session-1 lifecycle=ready_for_review health=healthy recovered=false journal_durable=true media_files_open=false"
      ))
    XCTAssertTrue(text.contains("model id=whisper-tiny installed=false file=ggml-tiny.bin"))
    XCTAssertTrue(text.contains("session titles, transcript text, and file paths are omitted"))
    XCTAssertFalse(text.contains("Monday standup"))
  }

  func testReportRedactsASessionFieldThatLooksLikeAPath() {
    let text = DiagnosticsReport.text(
      product: "Open Scribe",
      version: "0.0.0",
      build: "1",
      operatingSystem: "Version 27.0",
      architecture: "arm64",
      bundleIdentifier: "app.open-scribe.dev",
      microphone: "authorized",
      screenCapture: "authorized",
      signature: "ad_hoc",
      recoveryPhase: "available",
      recoveredCount: 1,
      sessions: [
        DiagnosticsReport.SessionLine(
          sessionId: "/Users/star/Library/Application Support/Open Scribe/secret",
          lifecycle: "ready_for_review",
          health: "healthy",
          recovered: true,
          journalDurable: true,
          mediaFilesOpen: false
        )
      ],
      models: [],
      events: []
    )

    XCTAssertTrue(text.contains("session id=redacted"))
    XCTAssertFalse(text.contains("/Users/star"))
    XCTAssertFalse(text.contains("Application Support"))
  }

  func testJournalRedactsPathsAndKeepsARecoveryNote() {
    let journal = DiagnosticJournal.shared
    journal.resetForTest()
    journal.record(
      category: "RecoveryProof",
      message: "stage=scan-finished detail=phase=none count=0 milliseconds=4")
    journal.record(
      category: "RecoveryProof", message: "stage=scan-failed detail=/tmp/open-scribe/library")
    let recent = journal.recent()
    XCTAssertEqual(
      recent.first?.message, "stage=scan-finished detail=phase=none count=0 milliseconds=4")
    XCTAssertEqual(recent.last?.message, "redacted=private_or_unbounded")
    XCTAssertFalse(recent.contains { $0.message.contains("/") })
  }

  func testSignatureStatusOmitsTheExecutablePath() {
    let status = DiagnosticsSignature.current()
    XCTAssertFalse(status.contains("/"))
    XCTAssertFalse(status.contains("\\"))
    XCTAssertTrue(
      status == "unsigned" || status == "ad_hoc" || status.hasPrefix("signed team="))
  }

  func testPlaybackCopyRunsOffTheMainThread() async throws {
    let observation = MainThreadObservation()
    let value = try await StructuredImportedPlaybackCopy.run { _ in
      observation.record(Thread.isMainThread)
      return 7
    }
    XCTAssertEqual(value, 7)
    XCTAssertEqual(observation.value, false)
  }

  func testCaptureProgressStaysOutOfTheJournal() {
    let journal = DiagnosticJournal.shared
    journal.resetForTest()
    let identity = MicrophoneCaptureIdentity.testFixture(generation: 1)
    func observation(
      _ event: MicrophoneSourceHealthEvent
    ) -> MicrophoneSourceHealthObservation {
      MicrophoneSourceHealthObservation(
        identity: identity,
        sequence: 1,
        event: event,
        callbackCount: 1,
        successfullyWrittenFrameCount: 1,
        lastProgressMonotonicNanoseconds: 1
      )
    }
    AppTelemetry.captureSourceHealth(
      CaptureSourceHealthTelemetryRecord(
        observation: observation(.progress),
        rustSourceState: "active",
        visibleState: "capturing"
      )
    )
    XCTAssertTrue(journal.recent().isEmpty)
    AppTelemetry.captureSourceHealth(
      CaptureSourceHealthTelemetryRecord(
        observation: observation(.routeInterrupted),
        rustSourceState: "active",
        visibleState: "capturing"
      )
    )
    let recent = journal.recent()
    XCTAssertEqual(recent.count, 1)
    XCTAssertTrue(recent[0].message.contains("event=route_interrupted"))
    XCTAssertFalse(recent[0].message.contains("/"))
  }

  func testTokenRedactsOneField() {
    XCTAssertEqual(DiagnosticPrivacy.token("/tmp/secret"), "redacted")
    XCTAssertEqual(DiagnosticPrivacy.token("session-1"), "session-1")
  }

  func testJournalKeepsOnlyTheLatestBoundedNotes() {
    let journal = DiagnosticJournal.shared
    journal.resetForTest()
    for index in 0..<(DiagnosticJournal.limit + 5) {
      journal.record(
        category: "Performance", message: "operation=library_snapshot milliseconds=\(index)")
    }
    let recent = journal.recent()
    XCTAssertEqual(recent.count, DiagnosticJournal.limit)
    XCTAssertEqual(recent.first?.message, "operation=library_snapshot milliseconds=5")
    XCTAssertEqual(
      recent.last?.message,
      "operation=library_snapshot milliseconds=\(DiagnosticJournal.limit + 4)")
  }
}

private final class MainThreadObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: Bool?
  func record(_ value: Bool) {
    lock.lock()
    recorded = value
    lock.unlock()
  }
  var value: Bool? {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}
