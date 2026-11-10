@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import OpenScribeApp

@MainActor
final class RecoveredSessionControllerTests: RecoveredSessionTestCase {
  func testImportedSearchHitSeeksTheVerifiedImportAndRejectsAnotherSession() async {
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in ImportedPlaybackLeaseFake(path: "/owned/fixture") },
      player: player)
    let session = savedSession(availability: "available", absolutePath: "/owned/fixture")
    let hit = NativeTranscriptSearchHit(
      sessionId: session.sessionId, sessionTitle: "Fixture", revisionId: "selected",
      trackId: "track",
      sequence: 1, startNanoseconds: 750_000_000, endNanoseconds: 1_000_000_000,
      effectiveText: "Passage")
    controller.playTranscriptSearchHit(
      hit, in: savedSession(sessionId: "another", availability: "available", absolutePath: "/other")
    )
    XCTAssertNil(controller.activePlaybackSessionId)
    controller.playTranscriptSearchHit(hit, in: session)
    await assertEventually { controller.playingSessionId == session.sessionId }
    XCTAssertEqual(player.importedStartNanoseconds, hit.startNanoseconds)
    XCTAssertEqual(player.importedReceipt, "/owned/fixture")
    controller.stopPlayback()
  }

  func testTranscriptClockIsBoundToThePlayingSessionAndClearsOnStopOrReplacement() async {
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in ImportedPlaybackLeaseFake(path: "/owned/fixture") },
      player: player)
    let first = savedSession(availability: "available", absolutePath: "/owned/fixture")
    XCTAssertNil(controller.transcriptPlaybackPosition(sessionId: first.sessionId))
    controller.play(first, startNanoseconds: 750_000_000)
    await assertEventually { controller.playingSessionId == first.sessionId }
    XCTAssertNil(controller.transcriptPlaybackPosition(sessionId: first.sessionId))
    player.transcriptPositionNanoseconds = 900_000_000
    let original = controller.transcriptPlaybackPosition(sessionId: first.sessionId)
    XCTAssertEqual(original?.nanoseconds, 900_000_000)
    XCTAssertNil(controller.transcriptPlaybackPosition(sessionId: "wrong-session"))

    let second = savedSession(
      sessionId: "replacement", availability: "available", absolutePath: "/owned/fixture")
    controller.play(second)
    XCTAssertNil(controller.transcriptPlaybackPosition(sessionId: first.sessionId))
    await assertEventually { controller.playingSessionId == second.sessionId }
    XCTAssertNotEqual(
      controller.transcriptPlaybackPosition(sessionId: second.sessionId)?.generation,
      original?.generation)
    controller.stopPlayback()
    XCTAssertNil(controller.transcriptPlaybackPosition(sessionId: second.sessionId))
  }

  func testCaptureSearchHitUsesTheTimelineAuthorityInsteadOfImportedPlayback() async {
    let requestedTimeline = SendableFlag()
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() }, player: player,
      timelineProvider: { _ in
        requestedTimeline.set()
        throw NativeStorageError.InvalidState
      })
    let capture = RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "capture", title: "Capture", lifecycle: "ready_for_review", health: "healthy",
        elapsedSeconds: 1, journalDurable: true, mediaFilesOpen: false, interruptionReason: nil,
        recovered: false, hasCaptureTimeline: true, sources: [], playableMedia: nil))
    let hit = NativeTranscriptSearchHit(
      sessionId: capture.sessionId, sessionTitle: capture.title, revisionId: "revision",
      trackId: "track",
      sequence: 0, startNanoseconds: 500_000_000, endNanoseconds: 1_000_000_000,
      effectiveText: "Captured passage")
    controller.playTranscriptSearchHit(hit, in: capture)
    await assertEventually { controller.errorMessage != nil }
    XCTAssertTrue(requestedTimeline.value)
    XCTAssertNil(player.importedReceipt)
    XCTAssertEqual(controller.errorSessionId, capture.sessionId)
  }

  func testMixdownPlaybackNeverSuppliesAConversationTranscriptClock() async {
    let player = RecoveredAudioPlayerFake()
    player.transcriptPositionNanoseconds = 500_000_000
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      mixdownLeaseProvider: { _ in ImportedPlaybackLeaseFake(path: "/owned/mixdown") },
      player: player)
    controller.playMixdown(sessionId: "mixdown")
    await assertEventually { controller.playingSessionId == "mixdown" }
    XCTAssertFalse(controller.canFollowTranscriptPlayback(sessionId: "mixdown"))
    XCTAssertNil(controller.transcriptPlaybackPosition(sessionId: "mixdown"))
    controller.stopPlayback()
  }

  func testRecoveredPartialPlaybackNeverSuppliesAConversationTranscriptClock() async {
    let player = RecoveredAudioPlayerFake()
    player.transcriptPositionNanoseconds = 500_000_000
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      recoveredPlaybackLeaseProvider: { _ in
        ImportedPlaybackLeaseFake(path: recoveredDescriptorReceipt())
      },
      player: player)
    let partial = recoveredSession()
    controller.play(partial)
    await assertEventually { controller.playingSessionId == partial.sessionId }
    XCTAssertFalse(controller.canFollowTranscriptPlayback(sessionId: partial.sessionId))
    XCTAssertNil(controller.transcriptPlaybackPosition(sessionId: partial.sessionId))
    controller.stopPlayback()
  }

  func testRecoveredSessionBecomesAvailableAndOpensNativePlayback() async throws {
    let preparation = RecoveryPreparationFake()
    let recovered = recoveredSession()
    preparation.recovered = [recovered]
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { preparation },
      recoveredPlaybackLeaseProvider: { _ in
        ImportedPlaybackLeaseFake(path: recoveredDescriptorReceipt())
      },
      player: player
    )

    controller.recoverOnLaunch()

    await assertEventually { controller.phase == .available }
    XCTAssertEqual(controller.sessions.map(\.sessionId), [recovered.sessionId])
    let generation = try XCTUnwrap(controller.play(recovered))
    XCTAssertEqual(
      controller.playbackStartupState(
        generation: generation,
        identity: RecoveredPlaybackMediaIdentity(recovered)
      ),
      .pending
    )
    await assertEventually { controller.playingSessionId == recovered.sessionId }
    XCTAssertEqual(
      controller.playbackStartupState(
        generation: generation,
        identity: RecoveredPlaybackMediaIdentity(recovered)
      ),
      .playing
    )
    XCTAssertEqual(controller.activePlaybackSessionId, recovered.sessionId)
    XCTAssertEqual(controller.playingSessionId, recovered.sessionId)
    XCTAssertEqual(
      controller.playingRecoveredMediaIdentity,
      RecoveredPlaybackMediaIdentity(recovered)
    )
    XCTAssertEqual(player.recoveredReceipt, recoveredDescriptorReceipt())

    controller.stopPlayback()
    XCTAssertNil(controller.activePlaybackSessionId)
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(controller.playingRecoveredMediaIdentity)
    XCTAssertEqual(player.stopCount, 2)
  }

  func testRecoveredStartupSuccessRemainsLatchedAfterNaturalEOF() async throws {
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      recoveredPlaybackLeaseProvider: { _ in
        ImportedPlaybackLeaseFake(path: recoveredDescriptorReceipt())
      },
      player: player
    )
    let recovered = recoveredSession(sessionId: "short-recovered")

    let generation = try XCTUnwrap(controller.play(recovered))
    await assertEventually { controller.playingSessionId == recovered.sessionId }
    player.terminate(generation: generation, outcome: .finished)
    await assertEventually { controller.activePlaybackSessionId == nil }

    XCTAssertEqual(
      controller.playbackStartupState(
        generation: generation,
        identity: RecoveredPlaybackMediaIdentity(recovered)
      ),
      .playing
    )
  }

  func testRecoveredStartupFailureBindsPendingIdentityAndRemainsLatched() async throws {
    let player = RecoveredAudioPlayerFake()
    player.holdRecoveredPlayback = true
    let preparation = RecoveryPreparationFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { preparation },
      recoveredPlaybackLeaseProvider: { _ in
        ImportedPlaybackLeaseFake(path: recoveredDescriptorReceipt())
      },
      player: player
    )
    let recovered = recoveredSession(sessionId: "early-failed-recovered")
    let identity = RecoveredPlaybackMediaIdentity(recovered)

    let generation = try XCTUnwrap(controller.play(recovered))
    await assertEventually { player.importedGeneration == generation }
    XCTAssertEqual(
      controller.playbackStartupState(generation: generation, identity: identity),
      .pending
    )

    player.terminate(generation: generation, outcome: .failed)
    await assertEventually { controller.errorMessage != nil }
    player.releaseRecoveredPlayback()
    XCTAssertEqual(
      controller.errorMessage,
      "Recovered audio playback stopped because decoding failed."
    )
    XCTAssertEqual(controller.errorRecoveredMediaIdentity, identity)
    XCTAssertEqual(
      controller.playbackStartupState(generation: generation, identity: identity),
      .failed
    )

    controller.recoverOnLaunch()
    XCTAssertEqual(
      controller.playbackStartupState(generation: generation, identity: identity),
      .failed
    )
  }

  func testGenerationBoundStopCannotStopReplacementPlayback() async throws {
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      recoveredPlaybackLeaseProvider: { identity in
        ImportedPlaybackLeaseFake(
          path: recoveredDescriptorReceipt(
            fileDescriptor: identity.sessionId == "first-recovered" ? 44 : 45
          )
        )
      },
      player: player
    )
    let first = recoveredSession(sessionId: "first-recovered")
    let replacement = recoveredSession(sessionId: "replacement-recovered")
    let replacementIdentity = RecoveredPlaybackMediaIdentity(replacement)

    let firstGeneration = try XCTUnwrap(controller.play(first))
    await assertEventually { controller.playingSessionId == first.sessionId }
    let replacementGeneration = try XCTUnwrap(controller.play(replacement))
    await assertEventually { controller.playingSessionId == replacement.sessionId }

    controller.stopPlayback(generation: firstGeneration)

    XCTAssertEqual(controller.activePlaybackSessionId, replacement.sessionId)
    XCTAssertEqual(controller.playingSessionId, replacement.sessionId)
    XCTAssertEqual(controller.playingRecoveredMediaIdentity, replacementIdentity)
    XCTAssertEqual(player.importedGeneration, replacementGeneration)
    XCTAssertEqual(
      controller.playbackStartupState(
        generation: replacementGeneration,
        identity: replacementIdentity
      ),
      .playing
    )

    controller.stopPlayback(generation: replacementGeneration)
  }

  func testRecoveredEOFAndStaleCompletionAreGenerationBound() async {
    let player = RecoveredAudioPlayerFake()
    let decisions = PlaybackTerminationDecisionRecorder()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      recoveredPlaybackLeaseProvider: { _ in
        ImportedPlaybackLeaseFake(path: recoveredDescriptorReceipt())
      },
      player: player,
      playbackTerminationDecisionObserver: decisions.record
    )
    let first = recoveredSession(sessionId: "recovered-first", path: "/tmp/first.caf")
    let second = recoveredSession(sessionId: "recovered-second", path: "/tmp/second.caf")

    controller.play(first)
    await assertEventually { player.importedGeneration != nil }
    let firstGeneration = player.importedGeneration!
    controller.play(second)
    await assertEventually {
      player.importedGeneration != nil && player.importedGeneration != firstGeneration
    }
    let secondGeneration = player.importedGeneration!

    player.deliverTermination(generation: firstGeneration, outcome: .finished)
    await assertEventually { decisions.decision(for: firstGeneration) == false }
    XCTAssertEqual(controller.playingSessionId, second.sessionId)
    XCTAssertEqual(
      controller.playingRecoveredMediaIdentity,
      RecoveredPlaybackMediaIdentity(second)
    )
    XCTAssertEqual(player.importedGeneration, secondGeneration)
    XCTAssertEqual(player.recoveredReceipt, recoveredDescriptorReceipt())

    player.terminate(generation: secondGeneration, outcome: .finished)
    await assertEventually { controller.playingSessionId == nil }
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(controller.playingRecoveredMediaIdentity)
    XCTAssertNil(player.recoveredReceipt)
  }

  func testRecoveredStopCancelsBlockedLeaseValidationWithoutPublishingPlayback() async throws {
    let leaseReleased = SendableFlag()
    let gate = BlockingRecoveredPlaybackLeaseProvider(
      blockedSessionId: "blocked-recovered"
    ) { _ in
      ReleasingPlaybackLeaseProbe(
        path: recoveredDescriptorReceipt(),
        released: leaseReleased
      )
    }
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      recoveredPlaybackLeaseProvider: gate.lease,
      player: player
    )
    let recovered = recoveredSession(sessionId: "blocked-recovered")

    let generation = try XCTUnwrap(controller.play(recovered))
    await assertEventually { gate.hasEntered }
    XCTAssertEqual(controller.activePlaybackSessionId, recovered.sessionId)
    XCTAssertEqual(
      controller.playbackStartupState(
        generation: generation,
        identity: RecoveredPlaybackMediaIdentity(recovered)
      ),
      .pending
    )

    controller.stopPlayback()
    XCTAssertNil(controller.activePlaybackSessionId)
    XCTAssertNil(controller.playingSessionId)
    XCTAssertEqual(
      controller.playbackStartupState(
        generation: generation,
        identity: RecoveredPlaybackMediaIdentity(recovered)
      ),
      .superseded
    )
    gate.release()

    await assertEventually { leaseReleased.value }
    XCTAssertNil(player.recoveredReceipt)
    XCTAssertNil(player.retainedLease)
    XCTAssertNil(controller.errorMessage)
  }

  func testRecoveredReplacementSupersedesBlockedLeaseValidationAndReleasesStaleLease() async {
    let staleLeaseReleased = SendableFlag()
    let replacementLease = ImportedPlaybackLeaseFake(
      path: recoveredDescriptorReceipt(fileDescriptor: 45)
    )
    let gate = BlockingRecoveredPlaybackLeaseProvider(
      blockedSessionId: "blocked-recovered"
    ) { identity in
      if identity.sessionId == "blocked-recovered" {
        return ReleasingPlaybackLeaseProbe(
          path: recoveredDescriptorReceipt(fileDescriptor: 44),
          released: staleLeaseReleased
        )
      }
      return replacementLease
    }
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      recoveredPlaybackLeaseProvider: gate.lease,
      player: player
    )
    let blocked = recoveredSession(sessionId: "blocked-recovered")
    let replacement = recoveredSession(sessionId: "replacement-recovered")

    controller.play(blocked)
    await assertEventually { gate.hasEntered }
    controller.play(replacement)
    await assertEventually { controller.playingSessionId == replacement.sessionId }
    gate.release()

    await assertEventually { staleLeaseReleased.value }
    XCTAssertEqual(controller.activePlaybackSessionId, replacement.sessionId)
    XCTAssertEqual(controller.playingSessionId, replacement.sessionId)
    XCTAssertEqual(
      controller.playingRecoveredMediaIdentity,
      RecoveredPlaybackMediaIdentity(replacement)
    )
    XCTAssertTrue(player.retainedLease === replacementLease)
    XCTAssertNil(controller.errorMessage)
  }

  func testRecoveredRecordsInOneSessionPublishExactIdentityAcrossReplacementAndStop() async {
    let player = RecoveredAudioPlayerFake()
    let decisions = PlaybackTerminationDecisionRecorder()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      recoveredPlaybackLeaseProvider: { identity in
        ImportedPlaybackLeaseFake(
          path: recoveredDescriptorReceipt(
            fileDescriptor: identity.sourceId == "microphone-source" ? 44 : 45
          )
        )
      },
      player: player,
      playbackTerminationDecisionObserver: decisions.record
    )
    let microphone = recoveredSession(
      sessionId: "shared-session",
      sourceId: "microphone-source",
      trackId: "microphone-track",
      segmentId: "microphone-segment",
      path: "/tmp/microphone.caf"
    )
    let systemAudio = recoveredSession(
      sessionId: "shared-session",
      sourceId: "system-source",
      trackId: "system-track",
      segmentId: "system-segment",
      path: "/tmp/system.caf"
    )

    controller.play(microphone)
    await assertEventually {
      controller.playingRecoveredMediaIdentity == RecoveredPlaybackMediaIdentity(microphone)
    }
    let microphoneGeneration = player.importedGeneration!
    XCTAssertEqual(
      controller.playingRecoveredMediaIdentity,
      RecoveredPlaybackMediaIdentity(microphone)
    )
    XCTAssertNotEqual(
      controller.playingRecoveredMediaIdentity,
      RecoveredPlaybackMediaIdentity(systemAudio)
    )

    controller.play(systemAudio)
    await assertEventually {
      controller.playingRecoveredMediaIdentity == RecoveredPlaybackMediaIdentity(systemAudio)
    }
    let systemGeneration = player.importedGeneration!
    XCTAssertEqual(controller.playingSessionId, "shared-session")
    XCTAssertEqual(
      controller.playingRecoveredMediaIdentity,
      RecoveredPlaybackMediaIdentity(systemAudio)
    )
    XCTAssertNotEqual(
      controller.playingRecoveredMediaIdentity,
      RecoveredPlaybackMediaIdentity(microphone)
    )

    player.deliverTermination(generation: microphoneGeneration, outcome: .finished)
    await assertEventually { decisions.decision(for: microphoneGeneration) == false }
    XCTAssertEqual(controller.playingSessionId, "shared-session")
    XCTAssertEqual(
      controller.playingRecoveredMediaIdentity,
      RecoveredPlaybackMediaIdentity(systemAudio)
    )
    XCTAssertEqual(player.importedGeneration, systemGeneration)

    controller.stopPlayback()
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(controller.playingRecoveredMediaIdentity)
  }

  func testNoRecoveryCandidateRemainsQuietlyEmpty() async {
    let preparation = RecoveryPreparationFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { preparation },
      player: RecoveredAudioPlayerFake()
    )

    controller.recoverOnLaunch()

    await assertEventually { controller.phase == .none }
    XCTAssertTrue(controller.sessions.isEmpty)
    XCTAssertNil(controller.errorMessage)
  }

  func testUnconfirmedRecoveryNeverBecomesPlayable() async {
    let preparation = RecoveryPreparationFake()
    preparation.recovered = [recoveredSession(mediaPreserved: false)]
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { preparation },
      player: player
    )

    controller.recoverOnLaunch()

    await assertEventually { controller.phase == .failed }
    XCTAssertTrue(controller.sessions.isEmpty)
    XCTAssertNil(player.recoveredReceipt)
    XCTAssertTrue(controller.errorMessage?.contains("Original files were not changed") == true)
  }

  /// F15: launch recovery leaves the main actor free. The call returns while the
  /// phase is still `.scanning`; the scan runs off the main thread and publishes.
  func testLaunchRecoveryRunsOffTheMainActorAndPublishesWhenDone() async {
    let preparation = RecoveryPreparationFake()
    let recovered = recoveredSession()
    preparation.recovered = [recovered]
    let controller = RecoveredSessionController(
      recoveryFactory: { preparation },
      player: RecoveredAudioPlayerFake()
    )

    controller.recoverOnLaunch()

    XCTAssertEqual(controller.phase, .scanning, "the call returns before the scan finishes")
    await assertEventually { controller.phase == .available }
    XCTAssertEqual(controller.sessions.map(\.sessionId), [recovered.sessionId])
    XCTAssertEqual(preparation.recoveredOnMainThread, false)
    XCTAssertTrue(
      DiagnosticJournal.shared.recent().contains {
        $0.message.contains("stage=scan-finished") && $0.message.contains("count=1")
      })
  }

  func testCancelledRecoveryScanDoesNotClaimMediaFailure() async {
    DiagnosticJournal.shared.resetForTest()
    let preparation = RecoveryPreparationFake()
    preparation.recoveryError = CancellationError()
    let controller = RecoveredSessionController(
      recoveryFactory: { preparation },
      player: RecoveredAudioPlayerFake()
    )

    controller.recoverOnLaunch()

    await assertEventually { controller.phase == .none }
    XCTAssertTrue(controller.sessions.isEmpty)
    XCTAssertNil(controller.errorMessage)
    XCTAssertTrue(
      DiagnosticJournal.shared.recent().contains {
        $0.category == "RecoveryProof" && $0.message.contains("stage=scan-cancelled")
      })
    XCTAssertFalse(
      DiagnosticJournal.shared.recent().contains { $0.message.contains("scan-failed") })
  }

  /// F4: a recording killed right after both sources reserved and opened a
  /// successor and sealed their first segment. Relaunch lists two recovered
  /// segments. The menu bar's "Play Recovered Audio" and every segment row go
  /// through the same lease, which must admit each listed row.
  func testKilledAfterSuccessorReservationPlaysEveryRecoveredRow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-recovered-controller-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = try Self.captureKilledAfterSuccessorReservation(root: root)

    let reopened = try NativeRecordingPreparation.open(managedRoot: root.path)
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { reopened },
      recoveredPlaybackLeaseProvider: { identity in
        try reopened.leaseRecoveredPlayback(
          sessionId: identity.sessionId,
          sourceId: identity.sourceId,
          trackId: identity.trackId,
          segmentId: identity.segmentId
        )
      },
      player: player,
      timelineProvider: { try reopened.playbackTimeline(sessionId: $0) }
    )

    controller.recoverOnLaunch()
    await assertEventually { controller.phase != .scanning }
    XCTAssertEqual(controller.phase, .available)
    XCTAssertNil(controller.errorMessage)
    let rows = controller.sessions
    XCTAssertEqual(rows.map(\.sessionId), [sessionId, sessionId])
    XCTAssertEqual(Set(rows.map(\.sourceKind)), [.microphone, .systemAudio])

    for row in rows {
      let identity = RecoveredPlaybackMediaIdentity(row)
      let generation = try XCTUnwrap(controller.play(row))
      await assertEventually {
        controller.playbackStartupState(generation: generation, identity: identity) != .pending
      }
      XCTAssertEqual(
        controller.playbackStartupState(generation: generation, identity: identity), .playing)
      XCTAssertNil(controller.errorMessage)
      XCTAssertEqual(controller.playingRecoveredMediaIdentity, identity)
      XCTAssertNotNil(player.recoveredReceipt)
      controller.stopPlayback()
    }
    XCTAssertEqual(try reopened.playbackTimeline(sessionId: sessionId).count, 2)
  }

  /// Two sources capture one second each; each then reserves and opens its
  /// successor and seals its first segment. The process ends before any
  /// successor receives a sample, so the successors become gaps on relaunch.
  private static func captureKilledAfterSuccessorReservation(root: URL) throws -> String {
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    let session = try preparation.prepareSessionWithRequiredSources(
      title: "Killed after successor reservation", requiredSources: [.microphone, .systemAudio])
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS else {
      throw ManagedCAFWriterError.unsupportedAuthorization
    }
    let anchor = mach_absolute_time()
    try preparation.anchorCaptureClock(
      sessionId: session.sessionId, hostAnchor: anchor,
      numerator: timebase.numer, denominator: timebase.denom)
    // Every required source opens before any first sample, as live capture does.
    var writers: [ManagedCAFWriter] = []
    for kind in [NativeMediaSourceKind.microphone, .systemAudio] {
      let authorization = try preparation.authorizeInitialMedia(
        sessionId: session.sessionId, sourceKind: kind, sourceDisplayName: "Synthetic \(kind)")
      let writer = try ManagedCAFWriter(authorization: authorization)
      try writer.writeDeterministicFrames(480)
      _ = try preparation.acceptMediaOpen(receipt: writer.receipt())
      writers.append(writer)
    }
    for writer in writers {
      try writer.writeDeterministicFrames(47_520)
      _ = try preparation.acceptFirstSample(
        receipt: writer.firstSampleReceipt(
          hostTime: anchor + AVAudioTime.hostTime(forSeconds: 1), frameCount: 48_000))
    }
    _ = try preparation.confirmRecording(sessionId: session.sessionId)
    var successors: [ManagedCAFWriter] = []
    for writer in writers {
      let successor = try preparation.authorizeNextSegment(
        sessionId: session.sessionId, previousSegmentId: writer.authorization.segmentId)
      let successorWriter = try ManagedCAFWriter(authorization: successor)
      try successorWriter.writeDeterministicFrames(480)
      _ = try preparation.acceptMediaOpen(receipt: successorWriter.receipt())
      successors.append(successorWriter)
      _ = try preparation.sealSegment(
        receipt: writer.sealSegmentReceipt(
          finalSampleHostTime: anchor + AVAudioTime.hostTime(forSeconds: 2)))
    }
    withExtendedLifetime((preparation, writers, successors)) {}
    return session.sessionId
  }

  func testRecoveredIdentityAndBoundErrorPublishOnlyAfterOpenOutcome() async {
    let player = RecoveredAudioPlayerFake()
    player.playError = CocoaError(.fileReadCorruptFile)
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      recoveredPlaybackLeaseProvider: { _ in
        ImportedPlaybackLeaseFake(path: recoveredDescriptorReceipt())
      },
      player: player
    )
    let recovered = recoveredSession(sessionId: "recovered-failure")

    controller.play(recovered)
    await assertEventually { controller.errorMessage != nil }

    XCTAssertNil(controller.activePlaybackSessionId)
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(controller.playingRecoveredMediaIdentity)
    XCTAssertEqual(controller.errorSessionId, recovered.sessionId)
    XCTAssertEqual(
      controller.errorRecoveredMediaIdentity,
      RecoveredPlaybackMediaIdentity(recovered)
    )
    XCTAssertEqual(controller.errorMessage, "Recovered audio could not be opened for playback.")
  }

  /// A stored final and a stored correction are imported from the portable
  /// package, then the player opens at each passage's audio interval.
  func testAStoredFinalOpensThePlayerAtItsAudioIntervalAndSaysFinalOrCorrected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-stored-final-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Stored.openscribe")
    let export = await exportStoredFinalPackage(to: package)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))
    let packageMedia = try regularFiles(under: package.appendingPathComponent("media"))
    XCTAssertEqual(packageMedia.count, 1)
    let packageDigest = try digest(of: packageMedia[0])

    let managed = root.appendingPathComponent("Library", isDirectory: true)
    let library = try NativeTranscriptLibrary.open(managedRoot: managed.path)
    let receipt = try library.importPortablePackage(packagePath: package.path)
    XCTAssertEqual(receipt.mediaFiles, 1)
    XCTAssertEqual(receipt.transcriptTracks, 1)
    XCTAssertEqual(try library.availability(sessionId: receipt.sessionId), .final)
    let segments = try library.document(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(segments.first { $0.sequence == 0 })
    let bravo = try XCTUnwrap(segments.first { $0.sequence == 1 })
    XCTAssertEqual(alpha.finality, "final")
    XCTAssertFalse(alpha.corrected)
    XCTAssertEqual(alpha.effectiveText, alpha.verbatimText)
    XCTAssertEqual(bravo.finality, "final")
    XCTAssertTrue(bravo.corrected)
    XCTAssertNotEqual(bravo.effectiveText, bravo.verbatimText)
    XCTAssertGreaterThan(bravo.startNanoseconds, alpha.endNanoseconds)
    let alphaSpoken = ConversationControlLabels.passageAccessibility(
      speaker: alpha.speakerLabel, text: alpha.effectiveText, finality: alpha.finality,
      corrected: alpha.corrected, isPlaying: false, isCited: false)
    let bravoSpoken = ConversationControlLabels.passageAccessibility(
      speaker: bravo.speakerLabel, text: bravo.effectiveText, finality: bravo.finality,
      corrected: bravo.corrected, isPlaying: false, isCited: false)
    XCTAssertTrue(alphaSpoken.contains(alpha.effectiveText))
    XCTAssertTrue(alphaSpoken.contains(" Final."))
    XCTAssertFalse(alphaSpoken.contains("Draft"))
    XCTAssertFalse(alphaSpoken.contains("Corrected"))
    XCTAssertTrue(bravoSpoken.contains(bravo.effectiveText))
    XCTAssertTrue(bravoSpoken.contains(" Corrected."))
    XCTAssertFalse(bravoSpoken.contains("Draft"))
    XCTAssertFalse(bravoSpoken.contains("Final"))
    let alphaHit = try XCTUnwrap(
      try library.search(query: alpha.effectiveText, sessionId: receipt.sessionId, limit: 10)
        .first { $0.sequence == alpha.sequence })
    let bravoHit = try XCTUnwrap(
      try library.search(query: bravo.effectiveText, sessionId: receipt.sessionId, limit: 10)
        .first { $0.sequence == bravo.sequence })
    XCTAssertEqual(alphaHit.sessionId, receipt.sessionId)
    XCTAssertEqual(alphaHit.startNanoseconds, alpha.startNanoseconds)
    XCTAssertEqual(alphaHit.endNanoseconds, alpha.endNanoseconds)
    XCTAssertEqual(bravoHit.startNanoseconds, bravo.startNanoseconds)
    XCTAssertEqual(bravoHit.endNanoseconds, bravo.endNanoseconds)
    XCTAssertEqual(bravoHit.effectiveText, bravo.effectiveText)

    let preparation = try NativeRecordingPreparation.open(managedRoot: managed.path)
    let native = try XCTUnwrap(
      try preparation.runtimeLibrarySnapshot().savedSessions.first {
        $0.sessionId == receipt.sessionId
      })
    let session = RuntimeSessionPresentation(native: native)
    XCTAssertFalse(session.hasCaptureTimeline)
    XCTAssertEqual(session.playableMedia?.isPlayable, true)
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)

    let player = RecoveredAudioPlayer(outputMode: .silent)
    for start in [alpha.startNanoseconds, bravo.startNanoseconds] {
      let lease = try preparation.leaseImportedPlayback(sessionId: receipt.sessionId)
      try await player.playImported(
        receipt: lease.playbackPath(), retaining: lease, generation: UUID(),
        startNanoseconds: start)
      player.stop()
      withExtendedLifetime(lease) {}
    }

    let head = try sample(
      preparation: preparation, sessionId: receipt.sessionId, startNanoseconds: 0)
    let atAlpha = try sample(
      preparation: preparation, sessionId: receipt.sessionId,
      startNanoseconds: alpha.startNanoseconds)
    let atBravo = try sample(
      preparation: preparation, sessionId: receipt.sessionId,
      startNanoseconds: bravo.startNanoseconds)
    XCTAssertNotEqual(head, atAlpha)
    XCTAssertNotEqual(atAlpha, atBravo)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    XCTAssertEqual(try digest(of: packageMedia[0]), packageDigest)

    let recorded = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { sessionId in
        try preparation.leaseImportedPlayback(sessionId: sessionId)
      },
      player: recorded)
    controller.playTranscriptSearchHit(alphaHit, in: session)
    await assertEventually { controller.playingSessionId == session.sessionId }
    XCTAssertNil(controller.errorMessage)
    XCTAssertEqual(recorded.importedStartNanoseconds, alphaHit.startNanoseconds)
    controller.stopPlayback()
    controller.playTranscriptSearchHit(bravoHit, in: session)
    await assertEventually { controller.playingSessionId == session.sessionId }
    XCTAssertNil(controller.errorMessage)
    XCTAssertEqual(recorded.importedStartNanoseconds, bravoHit.startNanoseconds)
    XCTAssertGreaterThan(bravoHit.startNanoseconds, alphaHit.startNanoseconds)
    controller.stopPlayback()
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    withExtendedLifetime(preparation) {}
  }

  /// A stored final is cited after import. Opening that evidence highlights the
  /// loaded passage, and the imported player seeks to its audio interval.
  /// Confirm, correct, and reject write a review. Leaving the claim unresolved
  /// does not.
  func testClaimEvidenceOnAStoredFinalSeeksHighlightsAndReturnsFocus() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-claim-evidence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Stored.openscribe")
    let export = await exportStoredFinalPackage(to: package)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))
    let packageMedia = try regularFiles(under: package.appendingPathComponent("media"))
    XCTAssertEqual(packageMedia.count, 1)
    let packageDigest = try digest(of: packageMedia[0])

    let managed = root.appendingPathComponent("Library", isDirectory: true)
    let library = try NativeTranscriptLibrary.open(managedRoot: managed.path)
    let receipt = try library.importPortablePackage(packagePath: package.path)
    let segments = try library.document(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(segments.first { $0.sequence == 0 })
    let bravo = try XCTUnwrap(segments.first { $0.sequence == 1 })
    XCTAssertEqual(alpha.finality, "final")
    XCTAssertGreaterThan(alpha.startNanoseconds, 0)
    XCTAssertGreaterThan(bravo.startNanoseconds, alpha.endNanoseconds)
    let supporting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: alpha.revisionId, sequence: alpha.sequence)
    let contradicting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: bravo.revisionId, sequence: bravo.sequence)
    try library.insertDerivedClaim(
      claimJson: citedClaimJSON(
        sessionId: receipt.sessionId, supporting: supporting, contradicting: contradicting))

    let preparation = try NativeRecordingPreparation.open(managedRoot: managed.path)
    let native = try XCTUnwrap(
      try preparation.runtimeLibrarySnapshot().savedSessions.first {
        $0.sessionId == receipt.sessionId
      })
    let session = RuntimeSessionPresentation(native: native)
    XCTAssertEqual(session.lifecycle, "ready_for_review")
    XCTAssertFalse(session.hasCaptureTimeline)
    XCTAssertEqual(session.playableMedia?.isPlayable, true)
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)

    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.load(sessionId: receipt.sessionId)
    XCTAssertNil(model.message)
    XCTAssertEqual(model.availability, .final)
    let claim = try XCTUnwrap(model.derivedClaims.first { $0.claimId == "claim-decision" })
    XCTAssertEqual(claim.revisionId, "revision-a")
    XCTAssertNil(claim.adjudication)
    XCTAssertEqual(claim.supportingCount, 1)
    XCTAssertEqual(claim.contradictingCount, 1)
    XCTAssertEqual(claim.text, "The team agreed to ship the local recorder.")
    let loadedAlpha = try XCTUnwrap(model.segments.first { $0.sequence == alpha.sequence })
    let loadedBravo = try XCTUnwrap(model.segments.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(loadedAlpha.id, alpha.id)
    XCTAssertEqual(loadedAlpha.startNanoseconds, alpha.startNanoseconds)
    XCTAssertEqual(loadedBravo.id, bravo.id)

    let supportingOpened = await model.openClaimEvidence(
      claimId: claim.claimId, side: "supporting")
    let supportingStart = try XCTUnwrap(supportingOpened)
    XCTAssertEqual(supportingStart, alpha.startNanoseconds)
    XCTAssertEqual(model.claimHighlightSegmentId, alpha.id)
    XCTAssertTrue(model.claimEvidenceOpen)
    XCTAssertEqual(model.focusedClaim?.claimId, claim.claimId)
    XCTAssertEqual(model.focusedClaim?.revisionId, "revision-a")
    XCTAssertEqual(model.focusedClaim?.text, claim.text)
    XCTAssertNil(model.message)
    let generation = model.claimFocusGeneration
    model.returnToClaim()
    XCTAssertFalse(model.claimEvidenceOpen)
    XCTAssertNil(model.claimHighlightSegmentId)
    XCTAssertEqual(model.focusedClaim?.claimId, claim.claimId)
    XCTAssertEqual(model.claimFocusGeneration, generation + 1)

    let contradictingOpened = await model.openClaimEvidence(
      claimId: claim.claimId, side: "contradicting")
    let contradictingStart = try XCTUnwrap(contradictingOpened)
    XCTAssertEqual(contradictingStart, bravo.startNanoseconds)
    XCTAssertEqual(model.claimHighlightSegmentId, bravo.id)
    XCTAssertTrue(model.claimEvidenceOpen)
    XCTAssertNil(model.message)
    model.returnToClaim()
    XCTAssertFalse(model.claimEvidenceOpen)
    XCTAssertEqual(model.focusedClaim?.claimId, claim.claimId)

    let player = RecoveredAudioPlayer(outputMode: .silent)
    for start in [supportingStart, contradictingStart] {
      let lease = try preparation.leaseImportedPlayback(sessionId: receipt.sessionId)
      try await player.playImported(
        receipt: lease.playbackPath(), retaining: lease, generation: UUID(),
        startNanoseconds: start)
      player.stop()
      withExtendedLifetime(lease) {}
    }
    let head = try sample(
      preparation: preparation, sessionId: receipt.sessionId, startNanoseconds: 0)
    let atAlpha = try sample(
      preparation: preparation, sessionId: receipt.sessionId,
      startNanoseconds: supportingStart)
    let atBravo = try sample(
      preparation: preparation, sessionId: receipt.sessionId,
      startNanoseconds: contradictingStart)
    XCTAssertNotEqual(head, atAlpha)
    XCTAssertNotEqual(atAlpha, atBravo)

    let recorded = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { sessionId in
        try preparation.leaseImportedPlayback(sessionId: sessionId)
      },
      player: recorded)
    await seekImported(
      controller: controller, player: recorded, session: session,
      startNanoseconds: supportingStart)
    await seekImported(
      controller: controller, player: recorded, session: session,
      startNanoseconds: contradictingStart)

    let accepted = await model.adjudicateClaim(
      claimId: claim.claimId, action: "accepted", text: nil)
    XCTAssertTrue(accepted)
    let acceptedClaim = try XCTUnwrap(
      model.derivedClaims.first { $0.claimId == claim.claimId })
    XCTAssertEqual(acceptedClaim.adjudication, "accepted")
    XCTAssertEqual(acceptedClaim.text, claim.text)
    XCTAssertNotEqual(acceptedClaim.revisionId, "revision-a")
    let acceptedOpened = await model.openClaimEvidence(
      claimId: claim.claimId, side: "supporting")
    let acceptedStart = try XCTUnwrap(acceptedOpened)
    XCTAssertEqual(acceptedStart, alpha.startNanoseconds)
    XCTAssertEqual(model.claimHighlightSegmentId, alpha.id)
    model.returnToClaim()

    let correctedText = "The team deferred the remote recorder."
    let corrected = await model.adjudicateClaim(
      claimId: claim.claimId, action: "corrected", text: correctedText)
    XCTAssertTrue(corrected)
    XCTAssertEqual(model.derivedClaims.first?.text, correctedText)
    XCTAssertEqual(model.derivedClaims.first?.adjudication, "corrected")
    XCTAssertNotEqual(model.derivedClaims.first?.revisionId, acceptedClaim.revisionId)
    let correctedOpened = await model.openClaimEvidence(
      claimId: claim.claimId, side: "supporting")
    let correctedStart = try XCTUnwrap(correctedOpened)
    XCTAssertEqual(correctedStart, alpha.startNanoseconds)
    XCTAssertEqual(model.claimHighlightSegmentId, alpha.id)
    XCTAssertEqual(model.focusedClaim?.text, correctedText)
    await seekImported(
      controller: controller, player: recorded, session: session,
      startNanoseconds: correctedStart)
    model.returnToClaim()

    let rejected = await model.adjudicateClaim(
      claimId: claim.claimId, action: "rejected", text: nil)
    XCTAssertTrue(rejected)
    let rejectedClaim = try XCTUnwrap(
      model.derivedClaims.first { $0.claimId == claim.claimId })
    XCTAssertEqual(rejectedClaim.adjudication, "rejected")
    XCTAssertEqual(rejectedClaim.text, correctedText)
    XCTAssertNotEqual(rejectedClaim.revisionId, acceptedClaim.revisionId)
    let leftUnresolved = await model.adjudicateClaim(
      claimId: claim.claimId, action: "unresolved", text: nil)
    XCTAssertFalse(leftUnresolved)
    XCTAssertEqual(model.derivedClaims.first?.revisionId, rejectedClaim.revisionId)
    XCTAssertEqual(model.derivedClaims.first?.text, correctedText)
    XCTAssertEqual(model.derivedClaims.first?.adjudication, "rejected")
    XCTAssertNil(model.message)

    let stored = try library.document(sessionId: receipt.sessionId)
    let storedAlpha = try XCTUnwrap(stored.first { $0.sequence == 0 })
    let storedBravo = try XCTUnwrap(stored.first { $0.sequence == 1 })
    XCTAssertEqual(storedAlpha.effectiveText, alpha.effectiveText)
    XCTAssertEqual(storedAlpha.startNanoseconds, alpha.startNanoseconds)
    XCTAssertFalse(storedAlpha.corrected)
    XCTAssertEqual(storedBravo.effectiveText, bravo.effectiveText)
    XCTAssertEqual(storedBravo.startNanoseconds, bravo.startNanoseconds)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    XCTAssertEqual(try digest(of: packageMedia[0]), packageDigest)
    withExtendedLifetime((preparation, library, model)) {}
  }

  /// Imports have no capture timeline, so claim evidence seeks with
  /// `play(_:startNanoseconds:)`.
  private func seekImported(
    controller: RecoveredSessionController, player: RecoveredAudioPlayerFake,
    session: RuntimeSessionPresentation, startNanoseconds: Int64
  ) async {
    controller.play(session, startNanoseconds: startNanoseconds)
    await assertEventually { controller.playingSessionId == session.sessionId }
    XCTAssertNil(controller.errorMessage)
    XCTAssertEqual(player.importedStartNanoseconds, startNanoseconds)
    controller.stopPlayback()
  }

  private func citedClaimJSON(
    sessionId: String, supporting: String, contradicting: String
  ) -> String {
    let session = Self.jsonString(sessionId)
    let text = Self.jsonString("The team agreed to ship the local recorder.")
    return
      "{\"schema\":\"open-scribe.derived-claim/v1\",\"claim_id\":\"claim-decision\",\"revision_id\":\"revision-a\",\"session_id\":\(session),\"kind\":\"decision\",\"text\":\(text),\"status\":\"agreed\",\"supporting\":[\(supporting)],\"contradicting\":[\(contradicting)],\"producer\":\"model_run\"}"
  }

  private static func jsonString(_ value: String) -> String {
    let escaped =
      value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  private func sample(
    preparation: NativeRecordingPreparation, sessionId: String, startNanoseconds: Int64
  ) throws -> Float {
    let lease = try preparation.leaseImportedPlayback(sessionId: sessionId)
    let serialized = lease.playbackPath()
    let decoder: CallbackCAFDecoder
    let retained: AnyObject
    if serialized.hasPrefix("v2;") || serialized.hasPrefix("v3;") {
      let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: serialized)
      let source = try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt)
      decoder = try CallbackCAFDecoder(
        source: source, fileTypeHint: receipt.fileTypeHint, onClose: {})
      retained = source
    } else {
      let receipt = try ImportedPlaybackDescriptorReceipt(serialized: serialized)
      let snapshot = try AnonymousImportedPlaybackSnapshot.copy(from: receipt)
      decoder = try CallbackCAFDecoder(
        source: snapshot.region, fileTypeHint: kAudioFileCAFType, onClose: {})
      retained = snapshot.region
    }
    defer {
      decoder.close()
      withExtendedLifetime((lease, retained)) {}
    }
    let rate = decoder.processingFormat.sampleRate
    XCTAssertEqual(rate, 48_000, accuracy: 0)
    if startNanoseconds > 0 {
      let frame = try XCTUnwrap(
        TranscriptPlaybackProjection.frame(nanoseconds: startNanoseconds, sampleRate: rate))
      XCTAssertGreaterThan(frame, 0)
      try decoder.seek(toFrame: frame)
    }
    let decoded = try XCTUnwrap(decoder.read(maximumFrames: 1))
    XCTAssertGreaterThan(decoded.frameLength, 0)
    let channels = try XCTUnwrap(decoded.floatChannelData)
    return channels[0][0]
  }

  private func exportStoredFinalPackage(to package: URL) async -> (status: Int32, log: String) {
    let packagePath = package.path
    let cargo = cargoExecutable()
    let repo = repositoryRoot()
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        guard let cargo, let repo else {
          continuation.resume(returning: (-1, "cargo or the workspace root is unavailable"))
          return
        }
        let process = Process()
        process.currentDirectoryURL = repo
        process.executableURL = URL(fileURLWithPath: cargo)
        process.arguments = [
          "test", "--locked", "--offline", "-p", "open-scribe-core", "--lib",
          "stored_final_exports_a_package_the_player_can_import", "--", "--exact",
          "transcript_library_tests::stored_final_exports_a_package_the_player_can_import",
        ]
        var environment = ProcessInfo.processInfo.environment
        let cargoBin = (cargo as NSString).deletingLastPathComponent
        let path = environment["PATH"] ?? ""
        if !path.split(separator: ":").contains(Substring(cargoBin)) {
          environment["PATH"] = "\(cargoBin):\(path)"
        }
        environment["OPEN_SCRIBE_STORED_FINAL_PACKAGE"] = packagePath
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
          try process.run()
        } catch {
          continuation.resume(returning: (-1, "\(error)"))
          return
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        continuation.resume(
          returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
      }
    }
  }

  private func cargoExecutable() -> String? {
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    which.arguments = ["cargo"]
    let pipe = Pipe()
    which.standardOutput = pipe
    which.standardError = Pipe()
    if (try? which.run()) != nil {
      which.waitUntilExit()
      if which.terminationStatus == 0 {
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if FileManager.default.isExecutableFile(atPath: path) { return path }
      }
    }
    let fallback = NSHomeDirectory() + "/.cargo/bin/cargo"
    return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
  }

  private func repositoryRoot() -> URL? {
    var url = URL(filePath: #filePath)
    while url.path != "/" {
      url.deleteLastPathComponent()
      let manifest = url.appendingPathComponent("Cargo.toml")
      guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
      if text.contains("[workspace]") { return url }
    }
    return nil
  }

  private func regularFiles(under root: URL) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        files.append(url)
      }
    }
    return files.sorted { $0.path < $1.path }
  }

  private func digest(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }
}
