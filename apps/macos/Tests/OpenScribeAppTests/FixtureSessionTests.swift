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
  func testConversationIdentityFormatsOnlyCanonicalGeneratedTitles() {
    let locale = Locale(identifier: "en_US")
    let zone = TimeZone(secondsFromGMT: -4 * 3600)!
    let generated = "Conversation 2026-10-06T17:20:28Z"
    let displayed = ConversationIdentityPresentation.title(
      generated, locale: locale, timeZone: zone)
    XCTAssertTrue(displayed.contains("Oct 6, 2026"))
    XCTAssertTrue(displayed.contains("1:20"))
    XCTAssertFalse(displayed.contains("17:20:28Z"))
    for title in [
      "Troy and James", "Conversation about 2026", "Conversation 2026-10-06T17:20:28Z notes",
    ] {
      XCTAssertEqual(ConversationIdentityPresentation.title(title), title)
    }
  }

  func testConversationReferencesDistinguishCollidingRowsWithoutChangingTitles() {
    func session(_ id: String, seconds: UInt64 = 3) -> RuntimeSessionPresentation {
      RuntimeSessionPresentation(
        native: NativeRuntimeSessionSnapshot(
          sessionId: id, title: "speech48", lifecycle: "ready_for_review", health: "healthy",
          elapsedSeconds: seconds, journalDurable: true, mediaFilesOpen: false,
          interruptionReason: nil, recovered: false, hasCaptureTimeline: false,
          sources: [], playableMedia: nil
        ))
    }
    let first = session("first-aaaaaa")
    let second = session("second-aaaaaa")
    let distinct = session("different-aaaaaa", seconds: 9)
    let references = ConversationIdentityPresentation.references(for: [
      first, second, distinct, first,
    ])
    XCTAssertEqual(references.count, 2)
    XCTAssertNotEqual(references[first.sessionId], references[second.sessionId])
    XCTAssertGreaterThan(references[first.sessionId]!.count, 6)
    XCTAssertNil(references[distinct.sessionId])
    XCTAssertTrue(ConversationIdentityPresentation.references(for: [first, first]).isEmpty)
    XCTAssertEqual(first.title, "speech48")
  }

  func testRuntimeCaptureAnnouncementsRequireDurableTruthAndIgnoreTicks() {
    var announcements = RuntimeCaptureAnnouncements()
    XCTAssertTrue(announcements.update(current: captureSession("preparing"), saved: []).isEmpty)
    XCTAssertTrue(
      announcements.update(
        current: captureSession("recording", durable: false), saved: []
      ).isEmpty
    )
    XCTAssertTrue(
      announcements.update(
        current: captureSession("recording", durable: false, mediaOpen: true), saved: []
      ).isEmpty
    )
    XCTAssertTrue(
      announcements.update(
        current: captureSession("recording", mediaOpen: false), saved: []
      ).isEmpty
    )
    XCTAssertEqual(
      announcements.update(current: captureSession("recording"), saved: []),
      ["Recording Mac microphone and Mac system audio."]
    )
    XCTAssertTrue(
      announcements.update(current: captureSession("recording", seconds: 900), saved: []).isEmpty
    )
    XCTAssertEqual(
      announcements.update(current: captureSession("paused"), saved: []),
      ["Paused. Capture is suspended."]
    )
    XCTAssertTrue(announcements.update(current: captureSession("paused"), saved: []).isEmpty)
    XCTAssertTrue(
      announcements.update(
        current: captureSession("paused", sourceLifecycle: "sealed"), saved: []
      ).isEmpty
    )
    XCTAssertEqual(announcements.update(current: captureSession("recording"), saved: []).count, 1)
  }

  func testRuntimeSourceFailureNamesFailureAndActualContinuationOnce() {
    var announcements = RuntimeCaptureAnnouncements()
    _ = announcements.update(current: captureSession("recording"), saved: [])
    let degraded = captureSession("recording", health: "degraded", microphoneFailed: true)
    let messages = announcements.update(current: degraded, saved: [])
    XCTAssertEqual(messages.count, 1)
    XCTAssertTrue(messages[0].contains("Mac microphone failed."))
    XCTAssertTrue(messages[0].contains("Capture continues on Mac system audio."))
    XCTAssertTrue(announcements.update(current: degraded, saved: []).isEmpty)
    let revoked = captureSession(
      "interrupted", health: "degraded", reason: "permission_revoked", microphoneFailed: true
    )
    let permission = announcements.update(current: revoked, saved: [])
    XCTAssertEqual(permission.count, 1)
    XCTAssertTrue(permission[0].contains("Capture permission was withdrawn."))
    XCTAssertTrue(permission[0].contains("Mac microphone failed."))
    XCTAssertTrue(permission[0].contains("No source is confirmed capturing."))
    XCTAssertTrue(permission[0].contains("Recovery required."))
    XCTAssertFalse(permission[0].contains("Capture continues"))
    XCTAssertTrue(announcements.update(current: revoked, saved: []).isEmpty)
  }

  func testRuntimeAnnouncementsDoNotPromoteUndurableDegradedRecording() {
    var announcements = RuntimeCaptureAnnouncements()
    XCTAssertTrue(
      announcements.update(
        current: captureSession("recording", health: "degraded", durable: false), saved: []
      ).isEmpty
    )
  }

  func testRecoveryAnnouncementsSeedHistoryAndAnnounceNewPartialRecoveryOnce() {
    var announcements = RuntimeCaptureAnnouncements()
    let recovered = captureSession("ready_for_review", health: "degraded", recovered: true)
    XCTAssertTrue(announcements.update(current: nil, saved: [recovered]).isEmpty)
    XCTAssertTrue(announcements.update(current: nil, saved: [recovered]).isEmpty)

    var emptyLibrary = RuntimeCaptureAnnouncements()
    _ = emptyLibrary.update(current: nil, saved: [])
    let messages = emptyLibrary.update(current: nil, saved: [recovered])
    XCTAssertEqual(messages.count, 1)
    XCTAssertTrue(messages[0].hasPrefix("Recovery required for Meeting."))
    XCTAssertTrue(emptyLibrary.update(current: nil, saved: [recovered]).isEmpty)

    var movingRecovery = RuntimeCaptureAnnouncements()
    XCTAssertEqual(movingRecovery.update(current: recovered, saved: []).count, 1)
    XCTAssertTrue(movingRecovery.update(current: nil, saved: [recovered]).isEmpty)
  }

  func testRuntimeStoreDispatchesWithoutViewAndDoesNotAnnounceReadFailures() async {
    let native = NativeRuntimeSessionSnapshot(
      sessionId: "announcement-session", title: "Meeting", lifecycle: "recording",
      health: "healthy", elapsedSeconds: 1, journalDurable: true, mediaFilesOpen: true,
      interruptionReason: nil, recovered: false, hasCaptureTimeline: true,
      sources: [
        NativeRuntimeSourceSnapshot(
          kind: .microphone, displayName: "Mac microphone", lifecycle: "capturing"
        )
      ], playableMedia: nil
    )
    let failure = SnapshotFailureSwitch()
    var messages: [String] = []
    let store = RuntimeLibraryStore(
      snapshotProvider: {
        if failure.isEnabled() { throw CocoaError(.fileReadUnknown) }
        return NativeRuntimeLibrarySnapshot(currentSession: native, savedSessions: [])
      },
      announce: { messages.append($0) }, startsPolling: false
    )
    await assertEventually { store.currentSession?.isRecording == true }
    XCTAssertEqual(messages, ["Recording Mac microphone."])
    failure.enable()
    store.refresh()
    await assertEventually { store.isSnapshotStale }
    XCTAssertNil(store.currentSession)
    XCTAssertEqual(messages.count, 1)
  }

  func testRuntimeStoreSeedsEmptySnapshotBeforeNewRecoveryArrives() async {
    let partial = NativeRuntimeSessionSnapshot(
      sessionId: "partial-session", title: "Meeting", lifecycle: "ready_for_review",
      health: "degraded", elapsedSeconds: 5, journalDurable: true, mediaFilesOpen: false,
      interruptionReason: "capture_failed", recovered: true, hasCaptureTimeline: true,
      sources: [], playableMedia: nil
    )
    let counter = SnapshotInvocationCounter()
    var messages: [String] = []
    let store = RuntimeLibraryStore(
      snapshotProvider: {
        NativeRuntimeLibrarySnapshot(
          currentSession: nil, savedSessions: counter.next() == 1 ? [] : [partial]
        )
      },
      announce: { messages.append($0) }, startsPolling: false
    )
    store.refresh()
    await assertEventually { store.savedSessions.count == 1 }
    XCTAssertEqual(messages.count, 1)
    XCTAssertTrue(messages[0].hasPrefix("Recovery required for Meeting."))
  }

  func testPausedGlyphAgreesAcrossLiveMenuAndStatusItem() async {
    let paused = captureSession("paused")
    let native = NativeRuntimeSessionSnapshot(
      sessionId: paused.sessionId, title: paused.title, lifecycle: "paused", health: "healthy",
      elapsedSeconds: 1, journalDurable: true, mediaFilesOpen: true, interruptionReason: nil,
      recovered: false, hasCaptureTimeline: true, sources: [], playableMedia: nil
    )
    let store = RuntimeLibraryStore(
      snapshotProvider: { NativeRuntimeLibrarySnapshot(currentSession: native, savedSessions: []) },
      announce: { _ in }, startsPolling: false
    )
    await assertEventually { store.currentSession?.lifecycle == "paused" }
    let live = CompactLiveView(
      store: store, liveRecording: LiveMicrophoneRecordingController(managedRoot: nil)
    )
    let symbol = SymbolResolver.pausedCaptureSymbolName
    XCTAssertFalse(symbol.isEmpty)
    XCTAssertEqual(
      symbol, SymbolResolver.resolve(primary: "pause.circle.fill", fallback: "pause.fill"))
    XCTAssertEqual(live.statusSymbol, symbol)
    XCTAssertEqual(MenuBarContent.statusSymbol(for: paused), symbol)
    for current in [Optional(paused), nil] {
      XCTAssertEqual(
        MenuBarLabel.presentation(
          session: current, snapshotStale: false, livePhase: .paused, liveStatus: "Paused"
        ).symbolName, symbol
      )
    }
    let pausedWithElapsedTime = MenuBarLabel.presentation(
      session: captureSession("paused", seconds: 3661, sourceLifecycle: "paused"),
      snapshotStale: false, livePhase: .paused, liveStatus: "Paused"
    )
    XCTAssertEqual(pausedWithElapsedTime.text, "Paused · 01:01:01")
    XCTAssertEqual(pausedWithElapsedTime.accessibilityText, "Paused, 01:01:01")
    XCTAssertEqual(
      MenuBarContent.statusSymbol(for: captureSession("interrupted", health: "degraded")),
      SymbolResolver.captureSymbol(for: .recoveryRequired)
    )
  }

  func testCaptureSymbolsUseDocumentedFallbacksWithoutInventingGlyphs() {
    let contract: [(SymbolResolver.CaptureState, String, String)] = [
      (.idle, "waveform", "circle"),
      (.ready, "waveform.circle", "waveform"),
      (.starting, "ellipsis.circle", "ellipsis"),
      (.recording, "record.circle.fill", "circle.fill"),
      (.paused, "pause.circle.fill", "pause.fill"),
      (.degraded, "exclamationmark.triangle.fill", "exclamationmark.triangle"),
      (.recoveryRequired, "clock.arrow.circlepath", "clock"),
    ]
    XCTAssertEqual(contract.count, SymbolResolver.CaptureState.allCases.count)
    for (state, primary, fallback) in contract {
      XCTAssertEqual(SymbolResolver.captureSymbol(for: state, isAvailable: { _ in true }), primary)
      XCTAssertEqual(
        SymbolResolver.captureSymbol(for: state, isAvailable: { $0 == fallback }), fallback)
      XCTAssertEqual(SymbolResolver.captureSymbol(for: state, isAvailable: { _ in false }), "")
      XCTAssertFalse(SymbolResolver.captureSymbol(for: state).isEmpty)
    }
  }

  func testSessionAndControllerMenuSymbolsAgreeWithoutPrematureRecording() {
    let sessions: [(RuntimeSessionPresentation, SymbolResolver.CaptureState)] = [
      (captureSession("preparing"), .starting),
      (captureSession("recording", durable: false), .starting),
      (captureSession("recording"), .recording),
      (captureSession("paused"), .paused),
      (captureSession("recording", health: "degraded", microphoneFailed: true), .degraded),
      (captureSession("paused", health: "degraded", microphoneFailed: true), .degraded),
      (captureSession("interrupted", health: "degraded"), .recoveryRequired),
      (captureSession("ready_for_review", health: "degraded", recovered: true), .recoveryRequired),
    ]
    for (session, state) in sessions {
      let symbol = SymbolResolver.captureSymbol(for: state)
      XCTAssertEqual(MenuBarContent.statusSymbol(for: session), symbol)
      XCTAssertEqual(
        MenuBarLabel.presentation(
          session: session, snapshotStale: false, livePhase: .capturing, liveStatus: "Recording"
        ).symbolName, symbol)
    }
    for phase in [
      LiveMicrophoneRecordingPhase.requestingPermission, .preparing, .starting,
      .capturing, .pausing, .stopping,
    ] {
      XCTAssertEqual(
        MenuBarLabel.presentation(
          session: nil, snapshotStale: false, livePhase: phase, liveStatus: "Working…"
        ).symbolName, SymbolResolver.captureSymbol(for: .starting))
    }
    XCTAssertEqual(
      MenuBarLabel.presentation(
        session: nil, snapshotStale: false, livePhase: .idle, liveStatus: "Ready to record"
      ).symbolName, SymbolResolver.captureSymbol(for: .ready))
    XCTAssertEqual(
      MenuBarLabel.presentation(
        session: captureSession("recording"), snapshotStale: true,
        livePhase: .capturing, liveStatus: "Recording"
      ).accessibilityText, "Live recording state unavailable")
  }

  func testSourceSelectionPresentationNamesOnlyEligibleSources() {
    let microphoneOnly = RecorderSourceSelectionPresentation(
      selection: .microphoneOnly, microphoneRetired: false)
    XCTAssertEqual(microphoneOnly.summary, "Microphone only")
    XCTAssertNil(microphoneOnly.unavailableNotice)
    let retiredMicrophone = RecorderSourceSelectionPresentation(
      selection: .system, microphoneRetired: true)
    XCTAssertEqual(retiredMicrophone.summary, "Mac system audio")
    XCTAssertTrue(
      retiredMicrophone.unavailableNotice?.contains("Microphone stopped earlier") == true)
    XCTAssertFalse(retiredMicrophone.help.contains("Microphone audio is included"))
    XCTAssertEqual(retiredMicrophone.systemAudioOptionTitle, "All computer audio")
    let retiredAudio = RecorderSourceSelectionPresentation(
      selection: .system, microphoneRetired: false, selectedAudioRetired: true)
    XCTAssertEqual(retiredAudio.summary, "Microphone only")
    XCTAssertTrue(
      retiredAudio.unavailableNotice?.contains("Mac system audio stopped earlier") == true)
    let noSource = RecorderSourceSelectionPresentation(
      selection: .microphoneOnly, microphoneRetired: true)
    XCTAssertEqual(noSource.summary, "No available source for resume")
    let name = String(repeating: "音声 Åudio ", count: 15)
    let application = RecorderCaptureSelection(
      kind: .applicationAudio, identity: "presentation-only", name: name,
      filter: nil, processId: nil)
    XCTAssertEqual(
      RecorderSourceSelectionPresentation(selection: application, microphoneRetired: false).summary,
      "Microphone + \(name)")
    XCTAssertEqual(
      RecorderSourceSelectionPresentation(selection: application, microphoneRetired: true).summary,
      name)
  }

  private func captureSession(
    _ lifecycle: String, health: String = "healthy", durable: Bool = true,
    mediaOpen: Bool? = nil,
    seconds: UInt64 = 1, reason: String? = nil, microphoneFailed: Bool = false,
    recovered: Bool = false, sourceLifecycle: String = "capturing"
  ) -> RuntimeSessionPresentation {
    RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "announcement-session", title: "Meeting", lifecycle: lifecycle,
        health: health, elapsedSeconds: seconds, journalDurable: durable,
        mediaFilesOpen: mediaOpen ?? durable, interruptionReason: reason, recovered: recovered,
        hasCaptureTimeline: true,
        sources: [
          NativeRuntimeSourceSnapshot(
            kind: .microphone, displayName: "Mac microphone",
            lifecycle: microphoneFailed ? "failed" : sourceLifecycle
          ),
          NativeRuntimeSourceSnapshot(
            kind: .systemAudio, displayName: "Mac system audio", lifecycle: sourceLifecycle
          ),
        ], playableMedia: nil
      )
    )
  }

  func testMainWorkspacePrefersTheActiveConversation() {
    XCTAssertEqual(
      MainWorkspaceSelection.resolve(
        selectedSessionId: "saved-2",
        currentSessionId: "active",
        savedSessionIds: ["saved-1", "saved-2"],
        preferCurrentSession: true
      ),
      "active"
    )
  }

  func testMainWorkspaceKeepsAValidSavedSelectionAcrossLibraryRefresh() {
    XCTAssertEqual(
      MainWorkspaceSelection.resolve(
        selectedSessionId: "saved-2",
        currentSessionId: nil,
        savedSessionIds: ["saved-1", "saved-2"],
        preferCurrentSession: false
      ),
      "saved-2"
    )
  }

  func testMainWorkspaceKeepsAChosenSavedConversationWhenALiveSessionAppears() {
    XCTAssertEqual(
      MainWorkspaceSelection.resolve(
        selectedSessionId: "saved-2",
        currentSessionId: "active",
        savedSessionIds: ["saved-1", "saved-2"],
        preferCurrentSession: false
      ),
      "saved-2"
    )
  }

  func testMainWorkspaceFallsBackWhenTheSelectedConversationDisappears() {
    XCTAssertEqual(
      MainWorkspaceSelection.resolve(
        selectedSessionId: "missing",
        currentSessionId: nil,
        savedSessionIds: ["saved-1", "saved-2"],
        preferCurrentSession: false
      ),
      "saved-1"
    )
  }

  func testMainWorkspaceOpensTheExactConversationCreatedByImport() {
    XCTAssertEqual(
      MainWorkspaceSelection.reconcileImportedConversation(
        pendingImportedSessionId: "imported-session",
        selectedSessionId: "older-session",
        savedSessionIds: ["older-session", "imported-session"]
      ),
      MainWorkspaceSelection.ImportedConversationResolution(
        selectedSessionId: "imported-session",
        pendingImportedSessionId: nil
      )
    )
  }

  func testMainWorkspaceRetainsImportIntentUntilTheConversationIsVisible() {
    XCTAssertEqual(
      MainWorkspaceSelection.reconcileImportedConversation(
        pendingImportedSessionId: "imported-session",
        selectedSessionId: "older-session",
        savedSessionIds: ["older-session"]
      ),
      MainWorkspaceSelection.ImportedConversationResolution(
        selectedSessionId: "older-session",
        pendingImportedSessionId: "imported-session"
      )
    )
    XCTAssertEqual(
      MainWorkspaceSelection.reconcileImportedConversation(
        pendingImportedSessionId: nil,
        selectedSessionId: "older-session",
        savedSessionIds: ["older-session"]
      ),
      MainWorkspaceSelection.ImportedConversationResolution(
        selectedSessionId: "older-session",
        pendingImportedSessionId: nil
      )
    )
  }

  func testMainWorkspaceNavigationClearsPendingImportOnCancelOrFailure() {
    let navigation = MainWorkspaceNavigation()
    navigation.select("older-session")
    navigation.acceptImportedConversation(
      "imported-session",
      savedSessionIds: ["older-session"]
    )
    XCTAssertEqual(navigation.pendingImportedSessionId, "imported-session")

    navigation.acceptImportedConversation(nil, savedSessionIds: ["older-session"])

    XCTAssertEqual(navigation.selectedSessionId, "older-session")
    XCTAssertNil(navigation.pendingImportedSessionId)
  }

  func testPreservedAudioReviewKeepsExactDestinationAndCanBeRequestedAgain() {
    let navigation = MainWorkspaceNavigation()
    navigation.select("older-session")
    navigation.reviewPreservedAudio(sessionId: "recovered-session")
    let firstRequest = navigation.audioReviewRequest
    navigation.synchronize(
      currentSessionId: "live-session",
      savedSessionIds: ["older-session", "recovered-session"],
      preferCurrentSession: false
    )
    XCTAssertEqual(navigation.selectedSessionId, "recovered-session")
    XCTAssertEqual(navigation.audioReviewRequest?.sessionId, "recovered-session")
    navigation.reviewPreservedAudio(sessionId: "recovered-session")
    XCTAssertNotEqual(firstRequest, navigation.audioReviewRequest)
    navigation.select("older-session")
    XCTAssertNil(navigation.audioReviewRequest)
  }

  func testMenuRecoveryHandoffRequiresMediaForTheExactConversation() {
    let unavailable = recoveredSessionPresentation(sessionId: "unavailable-session")
    let preserved = recoveredSessionPresentation(sessionId: "preserved-session")
    let media = recoveredTrack(
      sessionId: preserved.sessionId, segmentId: "preserved-segment",
      sampleCount: 48_000, durationNanoseconds: 1_000_000_000, byteLength: 96_068
    )
    XCTAssertNil(MenuBarContent.preservedConversation(in: [unavailable], media: [media]))
    XCTAssertNil(MenuBarContent.preservedConversation(in: [preserved], media: []))
    XCTAssertEqual(
      MenuBarContent.preservedConversation(in: [unavailable, preserved], media: [media])?.sessionId,
      preserved.sessionId
    )
  }

  func testMainWorkspaceStopsPlaybackThatBelongsToAnotherConversation() {
    XCTAssertTrue(
      MainWorkspaceSelection.shouldStopDetachedPlayback(
        activePlaybackSessionId: "conversation-a",
        selectedSessionId: "conversation-b"
      )
    )
    XCTAssertFalse(
      MainWorkspaceSelection.shouldStopDetachedPlayback(
        activePlaybackSessionId: "conversation-a",
        selectedSessionId: "conversation-a"
      )
    )
    XCTAssertFalse(
      MainWorkspaceSelection.shouldStopDetachedPlayback(
        activePlaybackSessionId: nil,
        selectedSessionId: "conversation-b"
      )
    )
  }

  func testPlaybackControlActionDistinguishesPendingCancelFromPlayingStop() {
    XCTAssertEqual(PlaybackControlAction.resolve(isPending: false, isPlaying: false), .play)
    XCTAssertEqual(PlaybackControlAction.resolve(isPending: true, isPlaying: false), .cancel)
    XCTAssertEqual(PlaybackControlAction.resolve(isPending: false, isPlaying: true), .stop)
    XCTAssertEqual(PlaybackControlAction.resolve(isPending: true, isPlaying: true), .stop)
    XCTAssertTrue(PlaybackControlAction.play.isEnabled(hasActivePlayback: false))
    XCTAssertFalse(PlaybackControlAction.play.isEnabled(hasActivePlayback: true))
    XCTAssertTrue(PlaybackControlAction.cancel.isEnabled(hasActivePlayback: true))
    XCTAssertTrue(PlaybackControlAction.stop.isEnabled(hasActivePlayback: true))
  }

  func testRecordActionIsUnavailableEverywhereWhileImportOwnsTheFileFlow() {
    XCTAssertTrue(MainWorkspaceActions.canRecord(liveCanStart: true, importIsBusy: false))
    XCTAssertFalse(MainWorkspaceActions.canRecord(liveCanStart: true, importIsBusy: true))
    XCTAssertFalse(MainWorkspaceActions.canRecord(liveCanStart: false, importIsBusy: false))
  }

  func testPlaybackNoticeStaysWithItsConversation() {
    XCTAssertTrue(
      MainWorkspacePlaybackNotice.shouldPresent(
        errorSessionId: nil,
        selectedSessionId: "conversation-b"
      )
    )
    XCTAssertTrue(
      MainWorkspacePlaybackNotice.shouldPresent(
        errorSessionId: "conversation-a",
        selectedSessionId: "conversation-a"
      )
    )
    XCTAssertFalse(
      MainWorkspacePlaybackNotice.shouldPresent(
        errorSessionId: "conversation-a",
        selectedSessionId: "conversation-b"
      )
    )
  }

  func testImportedPlaybackEligibilityAllowsVerifiedLargeMedia() {
    func media(byteLength: UInt64) -> RuntimePlayableMediaPresentation {
      RuntimePlayableMediaPresentation(
        native: NativeRuntimePlayableMediaSnapshot(
          sourceDisplayName: "meeting.caf",
          availability: "available",
          absolutePath: "/managed/meeting.caf",
          durationNanoseconds: 1_000_000_000,
          sampleCount: 48_000,
          byteLength: byteLength
        )
      )
    }

    let exactCap = media(byteLength: 268_435_456)
    XCTAssertTrue(ImportedPlaybackEligibility.canPlay(exactCap))
    XCTAssertEqual(ImportedPlaybackEligibility.status(exactCap), "Ready to play")

    let overCap = media(byteLength: 268_435_457)
    XCTAssertTrue(ImportedPlaybackEligibility.canPlay(overCap))
    XCTAssertEqual(
      ImportedPlaybackEligibility.status(overCap),
      "Ready to play"
    )
  }

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

  func testMainAndMenuShareOneRustOwnedRuntimeLibrarySnapshot() async {
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
      hasCaptureTimeline: false,
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
      ],
      playableMedia: nil
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
      hasCaptureTimeline: false,
      sources: current.sources.map {
        NativeRuntimeSourceSnapshot(
          kind: $0.kind,
          displayName: $0.displayName,
          lifecycle: "sealed"
        )
      },
      playableMedia: nil
    )
    let store = RuntimeLibraryStore(
      snapshotProvider: {
        NativeRuntimeLibrarySnapshot(currentSession: current, savedSessions: [saved])
      },
      startsPolling: false
    )

    store.refresh()
    await assertEventually { store.currentSession?.sessionId == "session-live" }
    let importAuthority = ImportedMediaAuthorityAdapter(
      picker: { nil },
      importer: { _, _ in throw CocoaError(.fileReadUnknown) }
    )
    let menu = MenuBarContent(store: store, importedMediaAuthority: importAuthority)
    let live = CompactLiveView(
      store: store,
      liveRecording: LiveMicrophoneRecordingController(managedRoot: nil)
    )

    XCTAssertTrue(menu.store === live.store)
    XCTAssertEqual(store.currentSession?.sessionId, "session-live")
    XCTAssertEqual(store.currentSession?.timerText, "00:01:05")
    XCTAssertEqual(store.currentSession?.sources.map(\.stateText), ["Capturing", "Capturing"])
    XCTAssertEqual(store.savedSessions.map(\.sessionId), ["session-saved"])
    XCTAssertTrue(store.savedSessions[0].recovered)
  }

  func testMenuBarRecordIsUnavailableWhileImportChoosesAndImports() async {
    let store = RuntimeLibraryStore(
      snapshotProvider: {
        NativeRuntimeLibrarySnapshot(currentSession: nil, savedSessions: [])
      },
      startsPolling: false
    )
    let liveRecording = LiveMicrophoneRecordingController(managedRoot: nil)
    let recoveredSessions = RecoveredSessionController(managedRoot: nil)
    let gate = FixtureBlockingGate()
    let selectedURL = URL(fileURLWithPath: "/tmp/meeting.caf")
    let importAuthority = ImportedMediaAuthorityAdapter(
      picker: {
        return selectedURL
      },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: { _, _ in
        gate.enterAndWait()
        throw CocoaError(.fileReadCorruptFile)
      }
    )
    let menu = MenuBarContent(
      store: store,
      importedMediaAuthority: importAuthority,
      liveRecording: liveRecording,
      recoveredSessions: recoveredSessions
    )

    XCTAssertTrue(menu.recordActionEnabled)
    importAuthority.chooseAndImport()
    let importEntered = await waitUntil { gate.hasEntered }
    XCTAssertTrue(importEntered)

    XCTAssertFalse(menu.recordActionEnabled)
    XCTAssertEqual(importAuthority.phase, .importing)
    gate.release()
    await assertEventually { importAuthority.phase == .failed }
    XCTAssertEqual(importAuthority.phase, .failed)
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
        hasCaptureTimeline: false,
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
        ],
        playableMedia: nil
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

  func testDegradedRecordingOutranksHealthyRecordingForVisibleAndVoiceOverStatus() {
    let degraded = RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "session-degraded",
        title: "Degraded conversation",
        lifecycle: "recording",
        health: "degraded",
        elapsedSeconds: 42,
        journalDurable: true,
        mediaFilesOpen: true,
        interruptionReason: nil,
        recovered: false,
        hasCaptureTimeline: false,
        sources: [
          NativeRuntimeSourceSnapshot(
            kind: .microphone,
            displayName: "Mac microphone",
            lifecycle: "failed"
          ),
          NativeRuntimeSourceSnapshot(
            kind: .systemAudio,
            displayName: "Mac system audio",
            lifecycle: "capturing"
          ),
        ],
        playableMedia: nil
      )
    )

    XCTAssertTrue(degraded.isDegradedRecording)
    XCTAssertFalse(degraded.isRecording)
    XCTAssertTrue(degraded.needsAttention)
    XCTAssertEqual(degraded.statusText, "Recording — degraded")
    XCTAssertEqual(
      MenuBarLabel.accessibilityStatus(
        session: degraded,
        snapshotStale: false,
        livePhase: .capturing,
        liveStatus: "Recording microphone + system audio"
      ),
      "Recording — degraded"
    )
  }

  /// G7: VoiceOver names the sources this session captures, never system
  /// audio a microphone-and-application recording excluded.
  func testRecordingVoiceOverNamesOnlyTheCapturingSources() {
    let recording = RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "session-application",
        title: "Application call",
        lifecycle: "recording",
        health: "healthy",
        elapsedSeconds: 65,
        journalDurable: true,
        mediaFilesOpen: true,
        interruptionReason: nil,
        recovered: false,
        hasCaptureTimeline: true,
        sources: [
          NativeRuntimeSourceSnapshot(
            kind: .microphone,
            displayName: "Mac microphone",
            lifecycle: "capturing"
          ),
          NativeRuntimeSourceSnapshot(
            kind: .applicationAudio,
            displayName: "Example Call",
            lifecycle: "capturing"
          ),
          NativeRuntimeSourceSnapshot(
            kind: .systemAudio,
            displayName: "Mac system audio",
            lifecycle: "ended"
          ),
        ],
        playableMedia: nil
      )
    )

    XCTAssertTrue(recording.isRecording)
    let spoken = MenuBarLabel.accessibilityStatus(
      session: recording,
      snapshotStale: false,
      livePhase: .capturing,
      liveStatus: "Recording microphone + Example Call"
    )
    XCTAssertTrue(spoken.hasPrefix("Recording "), spoken)
    XCTAssertTrue(spoken.hasSuffix(", 00:01:05"), spoken)
    XCTAssertTrue(spoken.contains("Mac microphone"), spoken)
    XCTAssertTrue(spoken.contains("Example Call"), spoken)
    XCTAssertFalse(spoken.localizedCaseInsensitiveContains("system audio"), spoken)
  }

  /// A session a terminated process left recording is not live while launch
  /// recovery scans (capture waits for the scan), so it is never presented as
  /// the current recording until recovery has run.
  func testLaunchRecoveryHidesAnUnrecoveredCurrentSession() async {
    let leftover = NativeRuntimeSessionSnapshot(
      sessionId: "session-left-recording",
      title: "Interrupted conversation",
      lifecycle: "recording",
      health: "healthy",
      elapsedSeconds: 65,
      journalDurable: true,
      mediaFilesOpen: true,
      interruptionReason: nil,
      recovered: false,
      hasCaptureTimeline: true,
      sources: [
        NativeRuntimeSourceSnapshot(
          kind: .microphone,
          displayName: "Mac microphone",
          lifecycle: "capturing"
        )
      ],
      playableMedia: nil
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
      recovered: false,
      hasCaptureTimeline: false,
      sources: [],
      playableMedia: nil
    )
    let scan = RecoveryScanFlag()
    let store = RuntimeLibraryStore(
      snapshotProvider: {
        NativeRuntimeLibrarySnapshot(currentSession: leftover, savedSessions: [saved])
      },
      startsPolling: false
    )
    store.isLaunchRecoveryPending = { scan.pending }

    store.refresh()
    await assertEventually { store.savedSessions.map(\.sessionId) == ["session-saved"] }
    XCTAssertNil(store.currentSession, "an unrecovered session is not shown as live")

    scan.pending = false
    store.refresh()
    await assertEventually { store.currentSession?.sessionId == "session-left-recording" }
  }

  func testRecoveredPartialSessionRetainsAttentionTruthAndExactSourceDurations() {
    let partial = RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "session-partial",
        title: "Recovered meeting",
        lifecycle: "ready_for_review",
        health: "degraded",
        elapsedSeconds: 2_425,
        journalDurable: true,
        mediaFilesOpen: false,
        interruptionReason: "capture_failed",
        recovered: true,
        hasCaptureTimeline: false,
        sources: [
          NativeRuntimeSourceSnapshot(
            kind: .microphone,
            displayName: "Mac microphone",
            lifecycle: "sealed"
          ),
          NativeRuntimeSourceSnapshot(
            kind: .systemAudio,
            displayName: "Mac system audio",
            lifecycle: "sealed"
          ),
        ],
        playableMedia: nil
      )
    )
    let tracks = partial.recoveredTracks(from: [
      recoveredTrack(
        sessionId: partial.sessionId,
        segmentId: "microphone-segment",
        sourceId: "microphone-source",
        trackId: "microphone-track",
        sourceKind: .microphone,
        sourceDisplayName: "Mac microphone",
        sampleCount: 18_536_662,
        durationNanoseconds: 386_180_458_333,
        byteLength: 37_077_420
      ),
      recoveredTrack(
        sessionId: partial.sessionId,
        segmentId: "system-segment",
        sourceId: "system-source",
        trackId: "system-track",
        sourceKind: .systemAudio,
        sourceDisplayName: "Mac system audio",
        sampleCount: 116_433_600,
        durationNanoseconds: 2_425_700_000_000,
        byteLength: 232_871_296
      ),
    ])

    XCTAssertTrue(partial.needsAttention)
    XCTAssertEqual(partial.statusText, "Recovered partial recording")
    XCTAssertEqual(partial.recoveryText, "Recovered partial recording")
    XCTAssertEqual(partial.timerText, "00:40:25")
    XCTAssertEqual(tracks.map(\.source.name), ["Mac microphone", "Mac system audio"])
    XCTAssertEqual(tracks.map(\.durationText), ["00:06:26.180", "00:40:25.700"])
    XCTAssertEqual(
      partial.interruptionText,
      "A capture source failed; durable recovery state was preserved."
    )
  }

  func testRecoveredTrackIdentitySurvivesReversedEqualCountRecords() {
    let session = recoveredSessionPresentation(sessionId: "session-reversed")
    let tracks = session.recoveredTracks(from: [
      recoveredTrack(
        sessionId: session.sessionId,
        segmentId: "system-segment",
        sourceId: "system-source",
        trackId: "system-track",
        sourceKind: .systemAudio,
        sourceDisplayName: "Mac system audio",
        sampleCount: 48_000,
        durationNanoseconds: 1_000_000_000,
        byteLength: 96_068
      ),
      recoveredTrack(
        sessionId: session.sessionId,
        segmentId: "microphone-segment",
        sourceId: "microphone-source",
        trackId: "microphone-track",
        sourceKind: .microphone,
        sourceDisplayName: "Mac microphone",
        sampleCount: 48_000,
        durationNanoseconds: 1_000_000_000,
        byteLength: 96_068
      ),
    ])

    XCTAssertEqual(tracks.map(\.id), ["system-segment", "microphone-segment"])
    XCTAssertEqual(tracks.map(\.source.name), ["Mac system audio", "Mac microphone"])
    XCTAssertEqual(tracks.map(\.playableSession.sourceId), ["system-source", "microphone-source"])
    XCTAssertEqual(tracks.map(\.playableSession.trackId), ["system-track", "microphone-track"])
  }

  func testRecoveredTracksExcludeForeignSessionWithoutRelabelingIdentity() {
    let session = recoveredSessionPresentation(sessionId: "session-owned")
    let tracks = session.recoveredTracks(from: [
      recoveredTrack(
        sessionId: "session-foreign",
        segmentId: "foreign-segment",
        sourceDisplayName: "Foreign microphone",
        sampleCount: 48_000,
        durationNanoseconds: 1_000_000_000,
        byteLength: 96_068
      ),
      recoveredTrack(
        sessionId: session.sessionId,
        segmentId: "owned-segment",
        sourceId: "owned-source",
        trackId: "owned-track",
        sourceKind: .applicationAudio,
        sourceDisplayName: "Window audio",
        sampleCount: 48_000,
        durationNanoseconds: 1_000_000_000,
        byteLength: 96_068
      ),
    ])

    XCTAssertEqual(tracks.map(\.id), ["owned-segment"])
    XCTAssertEqual(tracks.map(\.source.name), ["Window audio"])
    XCTAssertEqual(tracks.map(\.playableSession.sourceId), ["owned-source"])
  }

  func testRecoveredTracksExposeMultipleSegmentsWithStableTrackIdentity() {
    let session = recoveredSessionPresentation(sessionId: "session-multiple")
    let tracks = session.recoveredTracks(from: [
      recoveredTrack(
        sessionId: session.sessionId,
        segmentId: "segment-1",
        sourceId: "microphone-source",
        trackId: "microphone-track",
        sourceDisplayName: "Mac microphone",
        sampleCount: 48_000,
        durationNanoseconds: 1_000_000_000,
        byteLength: 96_068
      ),
      recoveredTrack(
        sessionId: session.sessionId,
        segmentId: "segment-2",
        sourceId: "microphone-source",
        trackId: "microphone-track",
        sourceDisplayName: "Mac microphone",
        sampleCount: 96_000,
        durationNanoseconds: 2_000_000_000,
        byteLength: 192_068
      ),
    ])

    XCTAssertEqual(tracks.map(\.id), ["segment-1", "segment-2"])
    XCTAssertEqual(
      tracks.map(\.playableSession.sourceId),
      ["microphone-source", "microphone-source"]
    )
    XCTAssertEqual(tracks.map(\.playableSession.trackId), ["microphone-track", "microphone-track"])
  }

  func testCompleteHealthyRecoveryRemainsReadyWithoutAttentionWarning() {
    let healthy = RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "session-healthy",
        title: "Recovered conversation",
        lifecycle: "ready_for_review",
        health: "healthy",
        elapsedSeconds: 120,
        journalDurable: true,
        mediaFilesOpen: false,
        interruptionReason: nil,
        recovered: true,
        hasCaptureTimeline: false,
        sources: [
          NativeRuntimeSourceSnapshot(
            kind: .microphone,
            displayName: "Mac microphone",
            lifecycle: "sealed"
          )
        ],
        playableMedia: nil
      )
    )

    XCTAssertFalse(healthy.needsAttention)
    XCTAssertEqual(healthy.statusText, "Recovered and ready")
    XCTAssertEqual(healthy.recoveryText, "Recovered")
    XCTAssertNil(healthy.interruptionText)
  }

  func testSlowSnapshotIsPublishedDespiteRepeatedPolling() async {
    let firstRead = FixtureBlockingGate()
    let nextRead = FixtureBlockingGate()
    let counter = SnapshotInvocationCounter()
    defer {
      firstRead.release()
      nextRead.release()
    }
    let saved = recoveredSessionPresentation(sessionId: "slow-saved-session")
    let store = RuntimeLibraryStore(
      snapshotProvider: {
        let invocation = counter.next()
        (invocation == 1 ? firstRead : nextRead).enterAndWait()
        return NativeRuntimeLibrarySnapshot(
          currentSession: nil,
          savedSessions: [
            NativeRuntimeSessionSnapshot(
              sessionId: "slow-saved-session", title: "Slow saved meeting",
              lifecycle: "ready_for_review", health: "healthy", elapsedSeconds: 2,
              journalDurable: true, mediaFilesOpen: false, interruptionReason: nil,
              recovered: true, hasCaptureTimeline: false, sources: [], playableMedia: nil
            )
          ]
        )
      }
    )
    await assertEventually { firstRead.hasEntered }
    try? await Task.sleep(for: .milliseconds(2_200))
    firstRead.release()
    await assertEventually { nextRead.hasEntered }
    XCTAssertEqual(store.savedSessions.map(\.sessionId), [saved.sessionId])
    XCTAssertFalse(store.isSnapshotStale)
  }

  func testRuntimeSnapshotReadFailureInvalidatesLiveAuthorityButPreservesSavedLibrary() async {
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
      hasCaptureTimeline: false,
      sources: [
        NativeRuntimeSourceSnapshot(
          kind: .microphone,
          displayName: "Mac microphone",
          lifecycle: "capturing"
        )
      ],
      playableMedia: nil
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
      hasCaptureTimeline: false,
      sources: [
        NativeRuntimeSourceSnapshot(
          kind: .microphone,
          displayName: "Mac microphone",
          lifecycle: "sealed"
        )
      ],
      playableMedia: nil
    )
    let failure = SnapshotFailureSwitch()
    let store = RuntimeLibraryStore(
      snapshotProvider: {
        if failure.isEnabled() { throw CocoaError(.fileReadUnknown) }
        return NativeRuntimeLibrarySnapshot(currentSession: current, savedSessions: [saved])
      },
      startsPolling: false
    )
    await assertEventually { store.currentSession?.isRecording == true }

    failure.enable()
    store.refresh()
    await assertEventually { store.isSnapshotStale }

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

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    _ predicate: () -> Bool
  ) async -> Bool {
    let started = DispatchTime.now().uptimeNanoseconds
    while !predicate() {
      if DispatchTime.now().uptimeNanoseconds - started >= timeoutNanoseconds {
        return false
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
  }

  private func assertEventually(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: () -> Bool
  ) async {
    let observed = await waitUntil(predicate)
    XCTAssertTrue(observed, file: file, line: line)
  }

  private func recoveredSessionPresentation(sessionId: String) -> RuntimeSessionPresentation {
    RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: sessionId,
        title: "Recovered meeting",
        lifecycle: "ready_for_review",
        health: "degraded",
        elapsedSeconds: 2,
        journalDurable: true,
        mediaFilesOpen: false,
        interruptionReason: "capture_failed",
        recovered: true,
        hasCaptureTimeline: false,
        sources: [
          NativeRuntimeSourceSnapshot(
            kind: .microphone,
            displayName: "Mac microphone",
            lifecycle: "sealed"
          ),
          NativeRuntimeSourceSnapshot(
            kind: .systemAudio,
            displayName: "Mac system audio",
            lifecycle: "sealed"
          ),
        ],
        playableMedia: nil
      )
    )
  }

  private func recoveredTrack(
    sessionId: String,
    segmentId: String,
    sourceId: String? = nil,
    trackId: String? = nil,
    sourceKind: NativeMediaSourceKind = .microphone,
    sourceDisplayName: String = "Synthetic microphone",
    sampleCount: UInt64,
    durationNanoseconds: UInt64,
    byteLength: UInt64
  ) -> NativeRecoveredPlayableSession {
    NativeRecoveredPlayableSession(
      sessionId: sessionId,
      sourceId: sourceId ?? "source-\(segmentId)",
      trackId: trackId ?? "track-\(segmentId)",
      sourceKind: sourceKind,
      sourceDisplayName: sourceDisplayName,
      segmentId: segmentId,
      relativePath: "audio/\(segmentId).caf",
      sampleCount: sampleCount,
      durationNanoseconds: durationNanoseconds,
      byteLength: byteLength,
      digestSha256: String(repeating: "a", count: 64),
      mediaPreserved: true,
      readyForReview: true,
      recordingStarted: false,
      lastJournalSequence: 12
    )
  }
}

private final class SnapshotInvocationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func next() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
}

private final class FixtureBlockingGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var entered = false
  private var released = false

  var hasEntered: Bool {
    condition.lock()
    defer { condition.unlock() }
    return entered
  }

  func enterAndWait() {
    condition.lock()
    entered = true
    condition.broadcast()
    while !released { condition.wait() }
    condition.unlock()
  }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
}

/// Stands in for the launch recovery scan's phase.
@MainActor
private final class RecoveryScanFlag {
  var pending = true
}
