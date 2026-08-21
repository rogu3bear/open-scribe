import XCTest

@testable import OpenScribeApp

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

  func testMenuAndLiveViewsShareOneFixtureStore() {
    let store = FixtureSessionStore(fixture: .recordingDegraded)
    let menu = MenuBarContent(store: store)
    let live = CompactLiveView(store: store)

    XCTAssertTrue(menu.store === live.store)
    XCTAssertEqual(menu.store.snapshot.surfaceTruth, live.store.snapshot.surfaceTruth)
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
}
