import XCTest

@testable import OpenScribeApp

private final class SnapshotFailureSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func enable() {
    lock.withLock { value = true }
  }

  func isEnabled() -> Bool {
    lock.withLock { value }
  }
}

@MainActor
final class FixtureSessionTests: XCTestCase {
  func testEveryRustFixtureMapsIntoSwift() {
    let fixtures = FixtureCatalog.load()

    XCTAssertEqual(fixtures.count, 10)
    XCTAssertEqual(Set(fixtures.map(\.fixtureName)).count, 10)
    XCTAssertTrue(fixtures.allSatisfy { !$0.accessibilityValue.isEmpty })
  }

  func testReadyAndStartingCannotPresentAsRecording() {
    let ready = SessionPresentation(native: nativeFixture(fixture: .ready))
    let starting = SessionPresentation(native: nativeFixture(fixture: .starting))

    for presentation in [ready, starting] {
      XCTAssertFalse(presentation.isDurableRecording)
      XCTAssertEqual(presentation.timerBehavior, .hidden)
      XCTAssertNil(presentation.timerText)
      XCTAssertNotEqual(presentation.resolvedSymbolName, "record.circle.fill")
    }
    XCTAssertEqual(starting.lifecycle, "ready")
    XCTAssertEqual(starting.label, "Starting…")
  }

  func testEveryReviewedSymbolOrFallbackResolves() {
    for fixture in FixtureCatalog.load() {
      if fixture.primarySymbol != nil || fixture.fallbackSymbol != nil {
        XCTAssertNotNil(fixture.resolvedSymbolName, fixture.fixtureName)
      }
    }
  }

  func testIllegalCommandReturnsStableNativeError() {
    XCTAssertThrowsError(
      try nativeApplyFixtureCommand(
        fixture: .idle,
        command: NativeCommand(
          kind: .pause,
          journalDurable: false,
          mediaFilesOpen: false,
          mediaSafe: false,
          elapsedSeconds: 0
        )
      )
    ) { error in
      XCTAssertEqual(error as? NativeSessionError, .IllegalTransition)
    }
  }

  func testTimerAdvancesOnlyForAdvancingFixtures() {
    let recording = FixtureSessionStore(fixture: .recording)
    let paused = FixtureSessionStore(fixture: .paused)
    let ready = FixtureSessionStore(fixture: .ready)

    recording.tick()
    paused.tick()
    ready.tick()

    XCTAssertEqual(recording.displayedTimerText, "00:12:35")
    XCTAssertEqual(recording.displayedLabel, "Recording · 00:12:35")
    XCTAssertEqual(paused.displayedTimerText, "00:12:34")
    XCTAssertNil(ready.displayedTimerText)
  }

  func testMainAndMenuShareOneRustOwnedRuntimeLibrarySnapshot() {
    let current = NativeRuntimeSessionSnapshot(
      sessionId: "session-live",
      title: "Design review",
      lifecycle: "recording",
      health: "healthy",
      elapsedSeconds: 65,
      journalDurable: true,
      mediaFilesOpen: true,
      interruptionReason: nil,
      recovered: false,
      sources: [
        NativeRuntimeSourceSnapshot(
          kind: .microphone,
          displayName: "Mac microphone",
          lifecycle: "capturing"
        ),
        NativeRuntimeSourceSnapshot(
          kind: .systemAudio,
          displayName: "Mac system audio",
          lifecycle: "capturing"
        ),
      ]
    )
    let saved = NativeRuntimeSessionSnapshot(
      sessionId: "session-saved",
      title: "Saved conversation",
      lifecycle: "ready_for_review",
      health: "healthy",
      elapsedSeconds: 120,
      journalDurable: true,
      mediaFilesOpen: false,
      interruptionReason: nil,
      recovered: true,
      sources: current.sources.map {
        NativeRuntimeSourceSnapshot(
          kind: $0.kind,
          displayName: $0.displayName,
          lifecycle: "sealed"
        )
      }
    )
    let store = RuntimeLibraryStore(
      snapshotProvider: {
        NativeRuntimeLibrarySnapshot(currentSession: current, savedSessions: [saved])
      },
      startsPolling: false
    )

    store.refresh()
    let menu = MenuBarContent(store: store)
    let live = CompactLiveView(store: store)

    XCTAssertTrue(menu.store === live.store)
    XCTAssertEqual(store.currentSession?.sessionId, "session-live")
    XCTAssertEqual(store.currentSession?.timerText, "00:01:05")
    XCTAssertEqual(store.currentSession?.sources.map(\.stateText), ["Capturing", "Capturing"])
    XCTAssertEqual(store.savedSessions.map(\.sessionId), ["session-saved"])
    XCTAssertTrue(store.savedSessions[0].recovered)
  }

  func testInterruptedRuntimeSnapshotNeverPresentsRecordingAndExplainsRecovery() {
    let interrupted = RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "session-interrupted",
        title: "Interrupted conversation",
        lifecycle: "interrupted",
        health: "degraded",
        elapsedSeconds: 42,
        journalDurable: true,
        mediaFilesOpen: true,
        interruptionReason: "capture_failed",
        recovered: false,
        sources: [
          NativeRuntimeSourceSnapshot(
            kind: .microphone,
            displayName: "Mac microphone",
            lifecycle: "failed"
          ),
          NativeRuntimeSourceSnapshot(
            kind: .systemAudio,
            displayName: "Mac system audio",
            lifecycle: "failed"
          ),
        ]
      )
    )

    XCTAssertFalse(interrupted.isRecording)
    XCTAssertTrue(interrupted.needsAttention)
    XCTAssertEqual(interrupted.statusText, "Recording interrupted")
    XCTAssertEqual(interrupted.recoveryText, "Recovery required")
    XCTAssertEqual(interrupted.sources.map(\.stateText), ["Failed", "Failed"])
    XCTAssertEqual(
      interrupted.interruptionText,
      "A capture source failed; durable recovery state was preserved."
    )
  }

  func testRuntimeSnapshotReadFailureInvalidatesLiveAuthorityButPreservesSavedLibrary() {
    let current = NativeRuntimeSessionSnapshot(
      sessionId: "session-live",
      title: "Live conversation",
      lifecycle: "recording",
      health: "healthy",
      elapsedSeconds: 12,
      journalDurable: true,
      mediaFilesOpen: true,
      interruptionReason: nil,
      recovered: false,
      sources: [
        NativeRuntimeSourceSnapshot(
          kind: .microphone,
          displayName: "Mac microphone",
          lifecycle: "capturing"
        )
      ]
    )
    let saved = NativeRuntimeSessionSnapshot(
      sessionId: "session-saved",
      title: "Saved conversation",
      lifecycle: "ready_for_review",
      health: "healthy",
      elapsedSeconds: 60,
      journalDurable: true,
      mediaFilesOpen: false,
      interruptionReason: nil,
      recovered: false,
      sources: [
        NativeRuntimeSourceSnapshot(
          kind: .microphone,
          displayName: "Mac microphone",
          lifecycle: "sealed"
        )
      ]
    )
    let failure = SnapshotFailureSwitch()
    let store = RuntimeLibraryStore(
      snapshotProvider: {
        if failure.isEnabled() { throw CocoaError(.fileReadUnknown) }
        return NativeRuntimeLibrarySnapshot(currentSession: current, savedSessions: [saved])
      },
      startsPolling: false
    )
    XCTAssertTrue(store.currentSession?.isRecording == true)

    failure.enable()
    store.refresh()

    XCTAssertNil(store.currentSession)
    XCTAssertEqual(store.savedSessions.map(\.sessionId), ["session-saved"])
    XCTAssertTrue(store.isSnapshotStale)
    XCTAssertNotNil(store.errorMessage)
    XCTAssertEqual(
      MenuBarLabel.accessibilityStatus(
        session: store.currentSession,
        snapshotStale: store.isSnapshotStale,
        livePhase: .capturing,
        liveStatus: "Recording microphone + system audio"
      ),
      "Live recording state unavailable"
    )
  }
}
