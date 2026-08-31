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

  func testImportedPlaybackEligibilityShowsTheHardCapBeforeTheUserPressesPlay() {
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
    XCTAssertFalse(ImportedPlaybackEligibility.canPlay(overCap))
    XCTAssertEqual(
      ImportedPlaybackEligibility.status(overCap),
      "Too large for safe playback"
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
