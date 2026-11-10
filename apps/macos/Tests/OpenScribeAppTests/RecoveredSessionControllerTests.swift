@preconcurrency import AVFoundation
import AppKit
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import XCTest

@testable import OpenScribeApp

private struct IdleClaimContextFrames: ContextFrameCapturing {
  func captureFrame(_ target: ContextCaptureTarget) async throws -> CGImage {
    throw CancellationError()
  }
}

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

  /// One conversation keeps a provisional passage beside a final passage and a
  /// user correction. Search opens the final and the correction. The timestamp
  /// control seeks the provisional interval. A hosted transcript row is not clicked.
  func testOneConversationSeeksProvisionalFinalAndCorrectedIntervals() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-mixed-transcript-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    let export = await exportMixedTranscriptLibrary(to: managed)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))

    let library = try NativeTranscriptLibrary.open(managedRoot: managed.path)
    let preparation = try NativeRecordingPreparation.open(managedRoot: managed.path)
    let native = try XCTUnwrap(
      try preparation.runtimeLibrarySnapshot().savedSessions.first)
    let session = RuntimeSessionPresentation(native: native)
    XCTAssertEqual(native.title, "Library claim fixture")
    XCTAssertFalse(session.hasCaptureTimeline)
    XCTAssertEqual(session.playableMedia?.isPlayable, true)
    XCTAssertEqual(try library.availability(sessionId: session.sessionId), .draft)

    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: session.sessionId)
    XCTAssertEqual(model.availability, .draft)
    XCTAssertEqual(
      model.availabilityText, "Draft — a Final transcript does not cover every range yet")
    XCTAssertEqual(model.segments.count, 3)
    let alpha = try XCTUnwrap(model.segments.first { $0.effectiveText == "alpha" })
    let bravo = try XCTUnwrap(model.segments.first { $0.effectiveText == "bravo corrected" })
    let cedar = try XCTUnwrap(model.segments.first { $0.effectiveText == "provisional cedar" })
    XCTAssertEqual(alpha.finality, "final")
    XCTAssertFalse(alpha.corrected)
    XCTAssertEqual(alpha.effectiveText, alpha.verbatimText)
    XCTAssertEqual(bravo.finality, "final")
    XCTAssertTrue(bravo.corrected)
    XCTAssertEqual(bravo.verbatimText, "bravo")
    XCTAssertNotEqual(bravo.effectiveText, bravo.verbatimText)
    XCTAssertEqual(cedar.finality, "draft")
    XCTAssertFalse(cedar.corrected)
    XCTAssertEqual(cedar.verbatimText, "provisional cedar")
    XCTAssertGreaterThan(bravo.startNanoseconds, alpha.endNanoseconds)
    XCTAssertGreaterThan(cedar.startNanoseconds, bravo.endNanoseconds)
    let alphaSpoken = ConversationControlLabels.passageAccessibility(
      speaker: alpha.speakerLabel, text: alpha.effectiveText, finality: alpha.finality,
      corrected: alpha.corrected, isPlaying: false, isCited: false)
    let bravoSpoken = ConversationControlLabels.passageAccessibility(
      speaker: bravo.speakerLabel, text: bravo.effectiveText, finality: bravo.finality,
      corrected: bravo.corrected, isPlaying: false, isCited: false)
    let cedarSpoken = ConversationControlLabels.passageAccessibility(
      speaker: cedar.speakerLabel, text: cedar.effectiveText, finality: cedar.finality,
      corrected: cedar.corrected, isPlaying: false, isCited: false)
    XCTAssertTrue(alphaSpoken.contains(alpha.effectiveText))
    XCTAssertTrue(alphaSpoken.contains(" Final."))
    XCTAssertFalse(alphaSpoken.contains("Draft"))
    XCTAssertFalse(alphaSpoken.contains("Corrected"))
    XCTAssertTrue(bravoSpoken.contains(bravo.effectiveText))
    XCTAssertTrue(bravoSpoken.contains(" Corrected."))
    XCTAssertFalse(bravoSpoken.contains("Draft"))
    XCTAssertFalse(bravoSpoken.contains("Final"))
    XCTAssertTrue(cedarSpoken.contains(cedar.effectiveText))
    XCTAssertTrue(cedarSpoken.hasSuffix(" Draft."))
    XCTAssertFalse(cedarSpoken.contains("Final"))
    XCTAssertFalse(cedarSpoken.contains("Corrected"))
    for passage in [alpha, bravo, cedar] {
      let stamp = TranscriptSection.timestamp(passage.startNanoseconds)
      XCTAssertEqual(
        ConversationControlLabels.seekAccessibility(stamp: stamp, canSeek: true),
        "Play from \(stamp)")
    }

    await model.search("provisional cedar")
    XCTAssertTrue(model.searchResults.isEmpty)
    XCTAssertNil(model.message)
    await model.search("cedar")
    XCTAssertTrue(model.searchResults.isEmpty)
    await model.search("alpha")
    XCTAssertEqual(model.searchResults.count, 1)
    let alphaHit = try XCTUnwrap(model.searchResults.first)
    XCTAssertEqual(alphaHit.sessionId, session.sessionId)
    XCTAssertEqual(alphaHit.startNanoseconds, alpha.startNanoseconds)
    XCTAssertEqual(alphaHit.endNanoseconds, alpha.endNanoseconds)
    XCTAssertEqual(alphaHit.effectiveText, "alpha")
    await model.search("bravo corrected")
    XCTAssertEqual(model.searchResults.count, 1)
    let bravoHit = try XCTUnwrap(model.searchResults.first)
    XCTAssertEqual(bravoHit.sessionId, session.sessionId)
    XCTAssertEqual(bravoHit.startNanoseconds, bravo.startNanoseconds)
    XCTAssertEqual(bravoHit.endNanoseconds, bravo.endNanoseconds)
    XCTAssertEqual(bravoHit.effectiveText, "bravo corrected")

    let media = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(media.count, 1)
    let mediaDigest = try digest(of: media[0])
    let head = try sample(
      preparation: preparation, sessionId: session.sessionId, startNanoseconds: 0)
    let atAlpha = try sample(
      preparation: preparation, sessionId: session.sessionId,
      startNanoseconds: alpha.startNanoseconds)
    let atBravo = try sample(
      preparation: preparation, sessionId: session.sessionId,
      startNanoseconds: bravo.startNanoseconds)
    let atCedar = try sample(
      preparation: preparation, sessionId: session.sessionId,
      startNanoseconds: cedar.startNanoseconds)
    XCTAssertNotEqual(head, atAlpha)
    XCTAssertNotEqual(atAlpha, atBravo)
    XCTAssertNotEqual(atBravo, atCedar)
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)

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
    controller.play(session, startNanoseconds: cedar.startNanoseconds)
    await assertEventually { controller.playingSessionId == session.sessionId }
    XCTAssertNil(controller.errorMessage)
    XCTAssertEqual(recorded.importedStartNanoseconds, cedar.startNanoseconds)
    XCTAssertGreaterThan(cedar.startNanoseconds, bravoHit.endNanoseconds)
    controller.stopPlayback()
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)
    withExtendedLifetime((library, preparation)) {}
  }

  /// The hosted transcript's own timestamp buttons seek a final passage, a
  /// corrected passage, and a draft. The test does not call `play` or
  /// `playTranscriptSearchHit`.
  func testHostedTranscriptTimestampsSeekFinalCorrectedAndDraftPassages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-hosted-transcript-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    let export = await exportMixedTranscriptLibrary(to: managed)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))
    let media = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(media.count, 1)
    let mediaDigest = try digest(of: media[0])

    let model = TranscriptLibraryModel(managedRoot: managed)
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil { !store.savedSessions.isEmpty }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let session = try XCTUnwrap(store.savedSessions.first)
    XCTAssertEqual(session.lifecycle, "ready_for_review")
    XCTAssertEqual(session.playableMedia?.isPlayable, true)
    XCTAssertFalse(session.hasCaptureTimeline)
    await model.load(sessionId: session.sessionId)
    let alpha = try XCTUnwrap(model.segments.first { $0.effectiveText == "alpha" })
    let bravo = try XCTUnwrap(model.segments.first { $0.effectiveText == "bravo corrected" })
    let cedar = try XCTUnwrap(model.segments.first { $0.effectiveText == "provisional cedar" })
    XCTAssertEqual(
      TranscriptReader.passageStateWord(finality: alpha.finality, corrected: alpha.corrected),
      "Final")
    XCTAssertEqual(
      TranscriptReader.passageStateWord(finality: bravo.finality, corrected: bravo.corrected),
      "Corrected")
    XCTAssertEqual(
      TranscriptReader.passageStateWord(finality: cedar.finality, corrected: cedar.corrected),
      "Draft")
    let alphaStamp = TranscriptSection.timestamp(alpha.startNanoseconds)
    let bravoStamp = TranscriptSection.timestamp(bravo.startNanoseconds)
    let cedarStamp = TranscriptSection.timestamp(cedar.startNanoseconds)
    let alphaLabel = "Play from \(alphaStamp), Final"
    let bravoLabel = "Play from \(bravoStamp), Corrected"
    let cedarLabel = "Play from \(cedarStamp), Draft"
    XCTAssertNotEqual(alpha.startNanoseconds, bravo.startNanoseconds)
    XCTAssertNotEqual(bravo.startNanoseconds, cedar.startNanoseconds)
    XCTAssertNotEqual(alphaLabel, bravoLabel)
    XCTAssertNotEqual(bravoLabel, cedarLabel)

    let navigation = MainWorkspaceNavigation()
    navigation.select(session.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: alphaLabel, in: host) != nil
        && self.claimButton(labeled: bravoLabel, in: host) != nil
        && self.claimButton(labeled: cedarLabel, in: host) != nil
        && self.passageStateField(labeled: "Final", in: host) != nil
        && self.passageStateField(labeled: "Corrected", in: host) != nil
        && self.passageStateField(labeled: "Draft", in: host) != nil
    }
    XCTAssertTrue(
      shown && window.contentView === host,
      "bounds=\(host.bounds) segments=\(model.segments.count) buttons=\(self.claimButtonProbe(in: host))"
    )
    let alphaButton = try XCTUnwrap(self.claimButton(labeled: alphaLabel, in: host))
    XCTAssertTrue(alphaButton.isDescendant(of: host))
    alphaButton.performClick(nil)
    await assertEventually {
      player.importedStartNanoseconds == alpha.startNanoseconds
        && playback.playingSessionId == session.sessionId
    }
    XCTAssertNil(playback.errorMessage)
    playback.stopPlayback()

    let bravoButton = try XCTUnwrap(self.claimButton(labeled: bravoLabel, in: host))
    XCTAssertTrue(bravoButton.isDescendant(of: host) && window.contentView === host)
    bravoButton.performClick(nil)
    await assertEventually {
      player.importedStartNanoseconds == bravo.startNanoseconds
        && playback.playingSessionId == session.sessionId
    }
    playback.stopPlayback()

    let cedarButton = try XCTUnwrap(self.claimButton(labeled: cedarLabel, in: host))
    XCTAssertTrue(cedarButton.isDescendant(of: host) && window.contentView === host)
    cedarButton.performClick(nil)
    await assertEventually {
      player.importedStartNanoseconds == cedar.startNanoseconds
        && playback.playingSessionId == session.sessionId
    }
    XCTAssertNil(playback.errorMessage)
    XCTAssertTrue(window.contentView === host)
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)
    withExtendedLifetime((store, live, playback, player, window, host)) {}
  }

  /// The transcript text-size menu is the shipped control. Choosing Largest
  /// renders the same final passage taller and keeps its spoken name. The
  /// test does not call `load` after the view is hosted and does not change
  /// the passage text.
  func testHostedTranscriptTextSizeRendersThePassageLarger() async throws {
    let suite = "OpenScribe.Proof.TextSize.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    preferences.set(TranscriptTextScale.standard.rawValue, forKey: TranscriptTextScale.storageKey)
    defer { preferences.removePersistentDomain(forName: suite) }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-text-size-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    let export = await exportMixedTranscriptLibrary(to: managed)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))
    let media = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(media.count, 1)
    let mediaDigest = try digest(of: media[0])

    let model = TranscriptLibraryModel(managedRoot: managed)
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil { !store.savedSessions.isEmpty }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let session = try XCTUnwrap(store.savedSessions.first)
    XCTAssertEqual(session.lifecycle, "ready_for_review")
    await model.load(sessionId: session.sessionId)
    XCTAssertEqual(model.segments.count, 3)
    let alpha = try XCTUnwrap(model.segments.first { $0.effectiveText == "alpha" })
    let spoken = ConversationControlLabels.passageAccessibility(
      speaker: alpha.speakerLabel, text: alpha.effectiveText, finality: alpha.finality,
      corrected: alpha.corrected, isPlaying: false, isCited: false)
    XCTAssertTrue(spoken.contains("alpha"))
    XCTAssertTrue(spoken.contains("Final"))
    let stamp = TranscriptSection.timestamp(alpha.startNanoseconds)
    let playLabel = "Play from \(stamp), Final"

    let navigation = MainWorkspaceNavigation()
    navigation.select(session.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    ).defaultAppStorage(preferences)
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedPopup(labeled: TranscriptTextScale.controlLabel, in: host) != nil
        && self.claimButton(labeled: playLabel, in: host) != nil
    }
    XCTAssertTrue(
      shown && window.contentView === host,
      "segments=\(model.segments.count) session=\(model.sessionId ?? "")\n\(self.hostedControlProbe(in: host))")
    let popup = try XCTUnwrap(self.hostedPopup(labeled: TranscriptTextScale.controlLabel, in: host))
    XCTAssertEqual(popup.titleOfSelectedItem, "Standard")
    XCTAssertEqual(popup.accessibilityValue() as? String, TranscriptTextScale.standard.spokenValue)
    XCTAssertTrue(popup.isDescendant(of: host))
    let playAtStandard = try XCTUnwrap(self.claimButton(labeled: playLabel, in: host))
    let standardRow = self.passageRowHeight(of: playAtStandard)
    let largestIndex = popup.indexOfItem(withTitle: "Largest")
    XCTAssertGreaterThanOrEqual(largestIndex, 0)
    popup.selectItem(at: largestIndex)
    XCTAssertEqual(popup.titleOfSelectedItem, "Largest")
    XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))

    let grew = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard popup.titleOfSelectedItem == "Largest",
        let play = self.claimButton(labeled: playLabel, in: host)
      else { return false }
      return self.passageRowHeight(of: play) > standardRow + 1
    }
    let playAtLargest = self.claimButton(labeled: playLabel, in: host)
    XCTAssertTrue(
      grew,
      "standardRow=\(standardRow) now=\(playAtLargest.map { self.passageRowHeight(of: $0) } ?? -1) selected=\(popup.titleOfSelectedItem ?? "") stored=\(preferences.string(forKey: TranscriptTextScale.storageKey) ?? "") ancestors=\(playAtLargest.map { self.ancestorHeights(of: $0) } ?? [])")
    XCTAssertEqual(
      preferences.string(forKey: TranscriptTextScale.storageKey),
      TranscriptTextScale.largest.rawValue)
    XCTAssertEqual(popup.accessibilityValue() as? String, TranscriptTextScale.largest.spokenValue)
    let largestRow = self.passageRowHeight(of: try XCTUnwrap(playAtLargest))
    XCTAssertGreaterThan(largestRow, standardRow)
    XCTAssertTrue(window.makeFirstResponder(popup))
    XCTAssertTrue(window.firstResponder === popup || popup.currentEditor() != nil)

    let play = try XCTUnwrap(self.claimButton(labeled: playLabel, in: host))
    XCTAssertTrue(play.isDescendant(of: host) && window.contentView === host)
    play.performClick(nil)
    await assertEventually {
      player.importedStartNanoseconds == alpha.startNanoseconds
        && playback.playingSessionId == session.sessionId
    }
    XCTAssertNil(playback.errorMessage)
    playback.stopPlayback()
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)
    XCTAssertEqual(model.segments.first { $0.id == alpha.id }?.effectiveText, "alpha")
    withExtendedLifetime((store, live, playback, player, window, host)) {}
  }

  /// Command-F on the transcript Find button focuses the search field. Typing
  /// the saved word narrows the visible passages and leaves the audio unchanged.
  func testHostedFindKeyEquivalentFocusesTheTranscriptSearch() async throws {
    let suite = "OpenScribe.Proof.Find.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-find-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    let export = await exportMixedTranscriptLibrary(to: managed)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))
    let media = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(media.count, 1)
    let mediaDigest = try digest(of: media[0])

    let model = TranscriptLibraryModel(managedRoot: managed)
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil { !store.savedSessions.isEmpty }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let session = try XCTUnwrap(store.savedSessions.first)
    await model.load(sessionId: session.sessionId)
    XCTAssertEqual(model.segments.count, 3)
    XCTAssertTrue(model.segments.contains { $0.effectiveText == "alpha" })

    let navigation = MainWorkspaceNavigation()
    navigation.select(session.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    ).defaultAppStorage(preferences)
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: ConversationControlLabels.findInTranscript, in: host) != nil
        && self.searchField(in: host) != nil
    }
    let find = try XCTUnwrap(
      self.claimButton(labeled: ConversationControlLabels.findInTranscript, in: host),
      self.hostedControlProbe(in: host))
    XCTAssertTrue(
      shown && window.contentView === host && find.isDescendant(of: host),
      self.textFieldProbe(in: host))
    XCTAssertEqual(find.accessibilityIdentifier(), "Find in transcript")
    XCTAssertEqual(find.keyEquivalent, "f")
    XCTAssertEqual(find.keyEquivalentModifierMask, .command)
    XCTAssertNotNil(self.searchField(in: host), self.textFieldProbe(in: host))
    XCTAssertTrue(window.makeFirstResponder(find))
    let resigned = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.searchField(in: host)?.currentEditor() == nil
    }
    XCTAssertTrue(
      resigned,
      "responder=\(String(describing: window.firstResponder)) editor=\(String(describing: self.searchField(in: host)?.currentEditor()))"
    )

    let other = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "g", charactersIgnoringModifiers: "g", isARepeat: false,
        keyCode: 5))
    XCTAssertFalse(find.performKeyEquivalent(with: other))
    XCTAssertNil(self.searchField(in: host)?.currentEditor())

    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false,
        keyCode: 3))
    XCTAssertTrue(
      find.performKeyEquivalent(with: event),
      "key=\(window.isKeyWindow) active=\(NSApp.isActive) equivalent=\(find.keyEquivalent)")
    let focused = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.searchField(in: host)?.currentEditor() != nil
    }
    let editor = try XCTUnwrap(
      self.searchField(in: host)?.currentEditor() as? NSTextView, "search field did not focus")
    XCTAssertTrue(focused)
    editor.selectAll(nil)
    editor.insertText("alpha", replacementRange: editor.selectedRange())
    let typedField = try XCTUnwrap(self.searchField(in: host))
    typedField.stringValue = editor.string
    let started = DispatchTime.now().uptimeNanoseconds
    var narrowed = false
    while DispatchTime.now().uptimeNanoseconds - started < 5_000_000_000 {
      let turned = expectation(description: "find query")
      DispatchQueue.main.async { turned.fulfill() }
      await fulfillment(of: [turned], timeout: 1)
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      if self.hostedString(containing: "1 matching passage", in: host) {
        narrowed = true
        break
      }
    }
    let typed = editor.string
    XCTAssertTrue(
      narrowed,
      "typed=\(typed) field=\(self.searchField(in: host)?.stringValue ?? "")\n\(self.textFieldProbe(in: host))\n\(self.hostedControlProbe(in: host))"
    )
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)
    XCTAssertEqual(model.segments.filter { $0.effectiveText == "alpha" }.count, 1)
    withExtendedLifetime((store, live, playback, player, window, host)) {}
  }

  /// The person menu keeps one named person's passage and hides the other.
  /// All speakers brings both back. The saved audio is unchanged.
  func testHostedPersonFilterShowsOnlyThatPersonsPassages() async throws {
    let suite = "OpenScribe.Proof.PersonFilter.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-person-filter-\(UUID().uuidString)", isDirectory: true)
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
    let stored = try library.document(sessionId: receipt.sessionId)
    let storedAlpha = try XCTUnwrap(stored.first { $0.sequence == 0 })
    let storedBravo = try XCTUnwrap(stored.first { $0.sequence == 1 })
    XCTAssertEqual(storedAlpha.effectiveText, "alpha")
    XCTAssertEqual(storedBravo.effectiveText, "bravo corrected")
    XCTAssertNil(storedAlpha.namedSpeakerId)
    XCTAssertNil(storedBravo.namedSpeakerId)
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    let mediaDigest = try digest(of: libraryMedia[0])
    XCTAssertEqual(mediaDigest, packageDigest)

    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.load(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(model.segments.first { $0.sequence == storedAlpha.sequence })
    let namedDana = await model.assignSpeaker(
      sessionId: receipt.sessionId, segment: alpha, assignment: .new(label: "Dana"))
    XCTAssertTrue(namedDana)
    let bravo = try XCTUnwrap(model.segments.first { $0.sequence == storedBravo.sequence })
    let namedMorgan = await model.assignSpeaker(
      sessionId: receipt.sessionId, segment: bravo, assignment: .new(label: "Morgan"))
    XCTAssertTrue(namedMorgan)
    let dana = try XCTUnwrap(model.namedSpeakers.first { $0.label == "Dana" })
    let morgan = try XCTUnwrap(model.namedSpeakers.first { $0.label == "Morgan" })
    XCTAssertEqual(dana.selectedTurns, 1)
    XCTAssertEqual(morgan.selectedTurns, 1)
    let danaSegment = try XCTUnwrap(model.segments.first { $0.namedSpeakerId == dana.id })
    let morganSegment = try XCTUnwrap(model.segments.first { $0.namedSpeakerId == morgan.id })
    func playLabel(_ segment: NativeTranscriptSegment) -> String {
      let stamp = TranscriptSection.timestamp(segment.startNanoseconds)
      let state = segment.corrected ? "Corrected" : "Final"
      let seek = ConversationControlLabels.seekAccessibility(stamp: stamp, canSeek: true)
      return "\(seek), \(state)"
    }
    let danaPlay = playLabel(danaSegment)
    let morganPlay = playLabel(morganSegment)
    XCTAssertNotEqual(danaPlay, morganPlay)
    let danaTitle = "\(dana.label) · \(dana.selectedTurns) passages"

    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(receipt.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    ).defaultAppStorage(preferences)
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedPopup(labeled: ConversationControlLabels.filterByPerson, in: host) != nil
        && self.claimButton(labeled: danaPlay, in: host) != nil
        && self.claimButton(labeled: morganPlay, in: host) != nil
    }
    let popup = try XCTUnwrap(
      self.hostedPopup(labeled: ConversationControlLabels.filterByPerson, in: host),
      self.hostedControlProbe(in: host))
    XCTAssertTrue(shown && window.contentView === host && popup.isDescendant(of: host))
    XCTAssertEqual(popup.titleOfSelectedItem, "All speakers")
    XCTAssertEqual(popup.accessibilityValue() as? String, "All speakers")
    XCTAssertGreaterThanOrEqual(popup.indexOfItem(withTitle: danaTitle), 0)

    func choose(_ title: String) {
      let index = popup.indexOfItem(withTitle: title)
      XCTAssertGreaterThanOrEqual(index, 0, "missing \(title)")
      popup.selectItem(at: index)
      XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
    }
    choose(danaTitle)
    let narrowed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return popup.titleOfSelectedItem == danaTitle
        && self.claimButton(labeled: danaPlay, in: host) != nil
        && self.claimButton(labeled: morganPlay, in: host) == nil
    }
    XCTAssertTrue(narrowed, self.hostedControlProbe(in: host))
    XCTAssertEqual(popup.accessibilityValue() as? String, danaTitle)
    XCTAssertFalse(
      self.hostedString(
        containing: "No passages are assigned to this person in the selected transcript.", in: host))

    choose("Unassigned passages")
    let unassigned = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: danaPlay, in: host) == nil
        && self.claimButton(labeled: morganPlay, in: host) == nil
        && self.hostedString(
          containing: "No passages are assigned to this person in the selected transcript.", in: host)
    }
    XCTAssertTrue(unassigned, self.hostedControlProbe(in: host))

    choose("All speakers")
    let restored = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: danaPlay, in: host) != nil
        && self.claimButton(labeled: morganPlay, in: host) != nil
        && !self.hostedString(
          containing: "No passages are assigned to this person in the selected transcript.", in: host)
    }
    XCTAssertTrue(restored, self.hostedControlProbe(in: host))
    XCTAssertEqual(try digest(of: libraryMedia[0]), mediaDigest)
    XCTAssertEqual(model.segments.first { $0.id == danaSegment.id }?.effectiveText, danaSegment.effectiveText)
    XCTAssertEqual(model.segments.first { $0.id == morganSegment.id }?.speakerLabel, "Morgan")
    withExtendedLifetime((store, live, playback, player, window, host)) {}
  }

  /// Clear removes the typed transcript query and restores the full passage count.
  /// The saved audio is unchanged.
  func testHostedClearTranscriptSearchRestoresTheFullReading() async throws {
    let suite = "OpenScribe.Proof.FindClear.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-find-clear-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    let export = await exportMixedTranscriptLibrary(to: managed)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))
    let media = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(media.count, 1)
    let mediaDigest = try digest(of: media[0])

    let model = TranscriptLibraryModel(managedRoot: managed)
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil { !store.savedSessions.isEmpty }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let session = try XCTUnwrap(store.savedSessions.first)
    await model.load(sessionId: session.sessionId)
    XCTAssertEqual(model.segments.filter { $0.effectiveText == "alpha" }.count, 1)

    let navigation = MainWorkspaceNavigation()
    navigation.select(session.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    ).defaultAppStorage(preferences)
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: ConversationControlLabels.findInTranscript, in: host) != nil
        && self.searchField(in: host) != nil
    }
    XCTAssertTrue(shown && window.contentView === host, self.hostedControlProbe(in: host))
    XCTAssertNil(
      self.claimButton(labeled: ConversationControlLabels.clearTranscriptSearch, in: host),
      self.hostedControlProbe(in: host))
    let find = try XCTUnwrap(
      self.claimButton(labeled: ConversationControlLabels.findInTranscript, in: host))
    XCTAssertTrue(window.makeFirstResponder(find))
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false,
        keyCode: 3))
    XCTAssertTrue(find.performKeyEquivalent(with: event))
    let focused = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.searchField(in: host)?.currentEditor() != nil
    }
    let editor = try XCTUnwrap(
      self.searchField(in: host)?.currentEditor() as? NSTextView, "search field did not focus")
    XCTAssertTrue(focused)
    editor.selectAll(nil)
    editor.insertText("alpha", replacementRange: editor.selectedRange())
    let typedField = try XCTUnwrap(self.searchField(in: host))
    typedField.stringValue = editor.string

    func pump(until predicate: () -> Bool) async -> Bool {
      let started = DispatchTime.now().uptimeNanoseconds
      while DispatchTime.now().uptimeNanoseconds - started < 5_000_000_000 {
        let turned = self.expectation(description: "clear search")
        DispatchQueue.main.async { turned.fulfill() }
        await self.fulfillment(of: [turned], timeout: 1)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if predicate() { return true }
      }
      return false
    }
    let narrowed = await pump {
      self.hostedString(containing: "1 matching passage", in: host)
        && self.claimButton(labeled: ConversationControlLabels.clearTranscriptSearch, in: host) != nil
    }
    XCTAssertTrue(narrowed, self.hostedControlProbe(in: host))
    let clear = try XCTUnwrap(
      self.claimButton(labeled: ConversationControlLabels.clearTranscriptSearch, in: host))
    XCTAssertTrue(clear.isDescendant(of: host) && window.contentView === host)
    clear.performClick(nil)
    let cleared = await pump {
      let field = self.searchField(in: host)
      return field?.stringValue.isEmpty == true
        && field?.currentEditor()?.string.isEmpty != false
        && !self.hostedString(containing: "1 matching passage", in: host)
        && self.claimButton(labeled: ConversationControlLabels.clearTranscriptSearch, in: host) == nil
    }
    XCTAssertTrue(
      cleared,
      "field=\(self.searchField(in: host)?.stringValue ?? "")\n\(self.hostedControlProbe(in: host))")
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)
    XCTAssertEqual(model.segments.filter { $0.effectiveText == "alpha" }.count, 1)
    withExtendedLifetime((store, live, playback, player, window, host)) {}
  }

  /// A corrected passage can show its stored machine reading and hide it again.
  /// The correction and the audio stay unchanged.
  func testHostedMachineReadingShowsTheStoredWords() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-machine-reading-\(UUID().uuidString)", isDirectory: true)
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
    let stored = try library.document(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(stored.first { $0.sequence == 0 })
    let bravo = try XCTUnwrap(stored.first { $0.sequence == 1 })
    XCTAssertFalse(alpha.corrected)
    XCTAssertTrue(bravo.corrected)
    XCTAssertEqual(bravo.effectiveText, "bravo corrected")
    XCTAssertNotEqual(bravo.verbatimText, bravo.effectiveText)
    let verbatim = bravo.verbatimText
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)

    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.load(sessionId: receipt.sessionId)
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(receipt.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: "Corrected · Show machine reading", in: host) != nil
    }
    XCTAssertTrue(shown && window.contentView === host, self.hostedControlProbe(in: host))
    XCTAssertNil(self.hostedField(labeled: "Machine reading", in: host))
    let show = try XCTUnwrap(
      self.claimButton(labeled: "Corrected · Show machine reading", in: host))
    XCTAssertTrue(show.isDescendant(of: host))
    XCTAssertEqual(show.accessibilityValue() as? String, "collapsed")
    show.performClick(nil)
    let opened = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedField(labeled: "Machine reading", in: host)?.stringValue == verbatim
    }
    XCTAssertTrue(opened, self.hostedControlProbe(in: host))
    XCTAssertEqual(show.accessibilityValue() as? String, "expanded")
    show.performClick(nil)
    let closed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedField(labeled: "Machine reading", in: host) == nil
        && (show.accessibilityValue() as? String) == "collapsed"
    }
    XCTAssertTrue(closed, self.hostedControlProbe(in: host))
    XCTAssertEqual(
      model.segments.first { $0.sequence == bravo.sequence }?.effectiveText, "bravo corrected")
    XCTAssertEqual(model.segments.first { $0.sequence == bravo.sequence }?.verbatimText, verbatim)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    withExtendedLifetime((store, live, playback, player, window, host)) {}
  }

  /// The speaker-review strip follows the person menu. Choosing one person
  /// leaves that passage's name and correction controls and removes the other.
  func testHostedSpeakerReviewListsOnlyTheSelectedPersonsPassages() async throws {
    let suite = "OpenScribe.Proof.ReviewStrip.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-review-strip-\(UUID().uuidString)", isDirectory: true)
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
    let stored = try library.document(sessionId: receipt.sessionId)
    let storedAlpha = try XCTUnwrap(stored.first { $0.sequence == 0 })
    let storedBravo = try XCTUnwrap(stored.first { $0.sequence == 1 })
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)

    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.load(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(model.segments.first { $0.sequence == storedAlpha.sequence })
    let namedDana = await model.assignSpeaker(
      sessionId: receipt.sessionId, segment: alpha, assignment: .new(label: "Dana"))
    XCTAssertTrue(namedDana)
    let bravo = try XCTUnwrap(model.segments.first { $0.sequence == storedBravo.sequence })
    let namedMorgan = await model.assignSpeaker(
      sessionId: receipt.sessionId, segment: bravo, assignment: .new(label: "Morgan"))
    XCTAssertTrue(namedMorgan)
    let dana = try XCTUnwrap(model.namedSpeakers.first { $0.label == "Dana" })
    let morgan = try XCTUnwrap(model.namedSpeakers.first { $0.label == "Morgan" })
    let danaSegment = try XCTUnwrap(model.segments.first { $0.namedSpeakerId == dana.id })
    let morganSegment = try XCTUnwrap(model.segments.first { $0.namedSpeakerId == morgan.id })
    func nameLabel(_ segment: NativeTranscriptSegment) -> String {
      ConversationControlLabels.nameSpeakerAccessibility(
        stamp: TranscriptSection.timestamp(segment.startNanoseconds), label: segment.speakerLabel)
    }
    func correctLabel(_ segment: NativeTranscriptSegment) -> String {
      ConversationControlLabels.correctAccessibility(
        stamp: TranscriptSection.timestamp(segment.startNanoseconds))
    }
    let danaName = nameLabel(danaSegment)
    let morganName = nameLabel(morganSegment)
    let danaCorrect = correctLabel(danaSegment)
    let morganCorrect = correctLabel(morganSegment)
    XCTAssertNotEqual(danaName, morganName)
    XCTAssertNotEqual(danaCorrect, morganCorrect)
    let danaTitle = "\(dana.label) · \(dana.selectedTurns) passages"

    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(receipt.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    ).defaultAppStorage(preferences)
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: danaName, in: host) != nil
        && self.claimButton(labeled: morganName, in: host) != nil
        && self.claimButton(labeled: danaCorrect, in: host) != nil
        && self.claimButton(labeled: morganCorrect, in: host) != nil
    }
    let popup = try XCTUnwrap(
      self.hostedPopup(labeled: ConversationControlLabels.filterByPerson, in: host),
      self.hostedControlProbe(in: host))
    XCTAssertTrue(shown && window.contentView === host && popup.isDescendant(of: host))
    XCTAssertEqual(popup.titleOfSelectedItem, "All speakers")

    func choose(_ title: String) {
      let index = popup.indexOfItem(withTitle: title)
      XCTAssertGreaterThanOrEqual(index, 0, "missing \(title)")
      popup.selectItem(at: index)
      XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
    }
    choose(danaTitle)
    let narrowed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: danaName, in: host) != nil
        && self.claimButton(labeled: danaCorrect, in: host) != nil
        && self.claimButton(labeled: morganName, in: host) == nil
        && self.claimButton(labeled: morganCorrect, in: host) == nil
    }
    XCTAssertTrue(narrowed, self.hostedControlProbe(in: host))

    choose("All speakers")
    let restored = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: danaName, in: host) != nil
        && self.claimButton(labeled: morganName, in: host) != nil
        && self.claimButton(labeled: danaCorrect, in: host) != nil
        && self.claimButton(labeled: morganCorrect, in: host) != nil
    }
    XCTAssertTrue(restored, self.hostedControlProbe(in: host))

    choose("Unassigned passages")
    let unassigned = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: danaName, in: host) == nil
        && self.claimButton(labeled: morganName, in: host) == nil
        && self.claimButton(labeled: danaCorrect, in: host) == nil
        && self.claimButton(labeled: morganCorrect, in: host) == nil
    }
    XCTAssertTrue(unassigned, self.hostedControlProbe(in: host))
    XCTAssertEqual(model.segments.first { $0.id == danaSegment.id }?.speakerLabel, "Dana")
    XCTAssertEqual(model.segments.first { $0.id == morganSegment.id }?.speakerLabel, "Morgan")
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    withExtendedLifetime((store, live, playback, player, window, host)) {}
  }

  /// Two restored conversations keep a final passage and a corrected passage.
  /// The library search the sidebar uses returns both, and each match opens
  /// at that passage's audio time.
  func testLibrarySearchOpensCorrectedRangesInTwoStoredConversations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-library-search-\(UUID().uuidString)", isDirectory: true)
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
    let first = try library.importPortablePackage(packagePath: package.path)
    let second = try library.importPortablePackage(packagePath: package.path)
    XCTAssertNotEqual(first.sessionId, second.sessionId)
    XCTAssertEqual(first.sourceSessionId, second.sourceSessionId)
    XCTAssertEqual(first.transcriptTracks, 1)
    XCTAssertEqual(second.transcriptTracks, 1)
    let sessions = [first.sessionId, second.sessionId]
    var alphaStart: Int64?
    var bravoStart: Int64?
    var bravoEnd: Int64?
    for sessionId in sessions {
      XCTAssertEqual(try library.availability(sessionId: sessionId), .final)
      let segments = try library.document(sessionId: sessionId)
      let alpha = try XCTUnwrap(segments.first { $0.sequence == 0 })
      let bravo = try XCTUnwrap(segments.first { $0.sequence == 1 })
      XCTAssertEqual(alpha.finality, "final")
      XCTAssertFalse(alpha.corrected)
      XCTAssertEqual(alpha.effectiveText, alpha.verbatimText)
      XCTAssertEqual(bravo.finality, "final")
      XCTAssertTrue(bravo.corrected)
      XCTAssertNotEqual(bravo.effectiveText, bravo.verbatimText)
      XCTAssertGreaterThan(bravo.startNanoseconds, alpha.endNanoseconds)
      if let alphaStart {
        XCTAssertEqual(alpha.startNanoseconds, alphaStart)
        XCTAssertEqual(bravo.startNanoseconds, bravoStart)
        XCTAssertEqual(bravo.endNanoseconds, bravoEnd)
      }
      alphaStart = alpha.startNanoseconds
      bravoStart = bravo.startNanoseconds
      bravoEnd = bravo.endNanoseconds
    }
    let alphaTime = try XCTUnwrap(alphaStart)
    let bravoTime = try XCTUnwrap(bravoStart)
    let bravoClose = try XCTUnwrap(bravoEnd)
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 2)
    for media in libraryMedia {
      XCTAssertEqual(try digest(of: media), packageDigest)
    }

    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.search("bravo corrected")
    XCTAssertNil(model.message)
    XCTAssertFalse(model.isSearching)
    XCTAssertEqual(model.searchResults.count, 2)
    XCTAssertEqual(Set(model.searchResults.map(\.sessionId)), Set(sessions))
    XCTAssertTrue(model.searchResults.allSatisfy {
      $0.sequence == 1 && $0.effectiveText == "bravo corrected"
        && $0.startNanoseconds == bravoTime && $0.endNanoseconds == bravoClose
    })
    let correctedHits = model.searchResults
    await model.search("alpha")
    XCTAssertEqual(model.searchResults.count, 2)
    XCTAssertEqual(Set(model.searchResults.map(\.sessionId)), Set(sessions))
    XCTAssertTrue(model.searchResults.allSatisfy {
      $0.sequence == 0 && $0.effectiveText == "alpha" && $0.startNanoseconds == alphaTime
        && $0.startNanoseconds < bravoTime
    })
    await model.search("memo")
    XCTAssertTrue(model.searchResults.isEmpty)
    XCTAssertNil(model.message)
    await model.search("  \n")
    XCTAssertTrue(model.searchResults.isEmpty)
    XCTAssertFalse(model.isSearching)

    let preparation = try NativeRecordingPreparation.open(managedRoot: managed.path)
    let saved = try preparation.runtimeLibrarySnapshot().savedSessions
      .filter { sessions.contains($0.sessionId) }
      .map(RuntimeSessionPresentation.init(native:))
    XCTAssertEqual(Set(saved.map(\.sessionId)), Set(sessions))
    XCTAssertTrue(saved.allSatisfy { !$0.hasCaptureTimeline && $0.playableMedia?.isPlayable == true })
    let navigation = MainWorkspaceNavigation()
    let recorded = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { sessionId in
        try preparation.leaseImportedPlayback(sessionId: sessionId)
      },
      player: recorded)
    let other = try XCTUnwrap(saved.first { $0.sessionId != correctedHits[0].sessionId })
    controller.playTranscriptSearchHit(correctedHits[0], in: other)
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(recorded.importedStartNanoseconds)
    XCTAssertNil(navigation.selectedSessionId)
    for hit in correctedHits {
      let session = try XCTUnwrap(saved.first { $0.sessionId == hit.sessionId })
      await model.load(sessionId: hit.sessionId)
      XCTAssertEqual(model.availability, .final)
      XCTAssertEqual(model.availabilityText, "Final transcript")
      let passage = try XCTUnwrap(model.segments.first { $0.sequence == hit.sequence })
      XCTAssertTrue(passage.corrected)
      XCTAssertEqual(passage.effectiveText, hit.effectiveText)
      XCTAssertEqual(passage.startNanoseconds, hit.startNanoseconds)
      XCTAssertNotEqual(passage.verbatimText, passage.effectiveText)
      navigation.select(hit.sessionId)
      XCTAssertEqual(navigation.selectedSessionId, hit.sessionId)
      controller.playTranscriptSearchHit(hit, in: session)
      await assertEventually { controller.playingSessionId == hit.sessionId }
      XCTAssertNil(controller.errorMessage)
      XCTAssertEqual(recorded.importedStartNanoseconds, hit.startNanoseconds)
      controller.stopPlayback()
    }
    for media in libraryMedia {
      XCTAssertEqual(try digest(of: media), packageDigest)
    }
    XCTAssertEqual(try digest(of: packageMedia[0]), packageDigest)
    withExtendedLifetime((library, preparation)) {}
  }

  /// Two stored conversations share a corrected passage. Typing in the hosted
  /// search field and pressing each match opens that conversation at the
  /// passage. The test does not call search or play on the model.
  func testHostedSearchResultOpensTheCorrectedPassage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-hosted-search-\(UUID().uuidString)", isDirectory: true)
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
    let first = try library.importPortablePackage(packagePath: package.path)
    let second = try library.importPortablePackage(packagePath: package.path)
    XCTAssertNotEqual(first.sessionId, second.sessionId)
    let sessions = [first.sessionId, second.sessionId]
    var bravoStart: Int64?
    for sessionId in sessions {
      let segments = try library.document(sessionId: sessionId)
      let alpha = try XCTUnwrap(segments.first { $0.sequence == 0 })
      let bravo = try XCTUnwrap(segments.first { $0.sequence == 1 })
      XCTAssertEqual(bravo.finality, "final")
      XCTAssertTrue(bravo.corrected)
      XCTAssertEqual(bravo.effectiveText, "bravo corrected")
      XCTAssertGreaterThan(bravo.startNanoseconds, alpha.endNanoseconds)
      if let bravoStart {
        XCTAssertEqual(bravo.startNanoseconds, bravoStart)
      }
      bravoStart = bravo.startNanoseconds
    }
    let bravoTime = try XCTUnwrap(bravoStart)
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 2)
    for media in libraryMedia {
      XCTAssertEqual(try digest(of: media), packageDigest)
    }

    let model = TranscriptLibraryModel(managedRoot: managed)
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      Set(store.savedSessions.map(\.sessionId)).isSuperset(of: sessions)
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(first.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    func sessionId(of button: NSButton) -> String {
      let raw = button.identifier?.rawValue ?? ""
      guard let hash = raw.lastIndex(of: "#") else { return raw }
      return String(raw[..<hash])
    }

    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let selected = navigation.selectedSessionId
      return self.hostedSearchField(in: host) != nil && sessions.contains(selected ?? "")
    }
    XCTAssertTrue(shown, self.hostedControlProbe(in: host))
    XCTAssertTrue(window.contentView === host)
    let field = try XCTUnwrap(self.hostedSearchField(in: host))
    XCTAssertTrue(field.isDescendant(of: host))
    field.stringValue = "bravo corrected"
    let matches = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedResultButtons(containing: "bravo corrected", in: host).count == 2
    }
    XCTAssertTrue(matches && window.contentView === host, self.hostedControlProbe(in: host))
    let buttons = self.hostedResultButtons(containing: "bravo corrected", in: host)
    XCTAssertEqual(Set(buttons.map { sessionId(of: $0) }), Set(sessions))
    XCTAssertTrue(buttons.allSatisfy { $0.identifier?.rawValue.hasSuffix("#1") == true })
    let away = try XCTUnwrap(buttons.first { sessionId(of: $0) != navigation.selectedSessionId })
    let awaySession = sessionId(of: away)
    XCTAssertTrue(away.isDescendant(of: host))
    away.performClick(nil)
    await assertEventually {
      navigation.selectedSessionId == awaySession && playback.playingSessionId == awaySession
        && player.importedStartNanoseconds == bravoTime
    }
    XCTAssertTrue(window.contentView === host)
    let home = try XCTUnwrap(
      self.hostedResultButtons(containing: "bravo corrected", in: host).first {
        sessionId(of: $0) != awaySession
      })
    let homeSession = sessionId(of: home)
    XCTAssertTrue(home.isDescendant(of: host))
    home.performClick(nil)
    await assertEventually {
      navigation.selectedSessionId == homeSession && playback.playingSessionId == homeSession
        && player.importedStartNanoseconds == bravoTime
    }
    XCTAssertNotEqual(homeSession, awaySession)
    XCTAssertTrue(window.contentView === host)

    field.stringValue = "memo"
    let empty = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedResultButtons(containing: "bravo corrected", in: host).isEmpty
        && self.hostedField(labeled: "No matching transcript text", in: host) != nil
    }
    XCTAssertTrue(empty && window.contentView === host, self.hostedControlProbe(in: host))
    for media in libraryMedia {
      XCTAssertEqual(try digest(of: media), packageDigest)
    }
    XCTAssertEqual(try digest(of: packageMedia[0]), packageDigest)
    withExtendedLifetime((store, live, playback, player, window, host, library)) {}
  }

  /// The pencil beside a stored passage opens the correction editor in the same
  /// host. Save replaces the reading, Cancel leaves it, and Restore returns the
  /// machine text. The test does not call correct.
  func testHostedTranscriptCorrectionSavesCancelsAndRestores() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-hosted-correction-\(UUID().uuidString)", isDirectory: true)
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
    let stored = try library.document(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(stored.first { $0.sequence == 0 })
    let bravo = try XCTUnwrap(stored.first { $0.sequence == 1 })
    XCTAssertEqual(alpha.finality, "final")
    XCTAssertFalse(alpha.corrected)
    XCTAssertEqual(alpha.effectiveText, alpha.verbatimText)
    XCTAssertEqual(bravo.finality, "final")
    XCTAssertTrue(bravo.corrected)
    XCTAssertEqual(bravo.effectiveText, "bravo corrected")
    XCTAssertNotEqual(bravo.effectiveText, bravo.verbatimText)
    XCTAssertGreaterThan(bravo.startNanoseconds, alpha.endNanoseconds)
    let alphaText = alpha.effectiveText
    let bravoVerbatim = bravo.verbatimText
    let bravoStamp = TranscriptSection.timestamp(bravo.startNanoseconds)
    let correctLabel = ConversationControlLabels.correctAccessibility(stamp: bravoStamp)
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)

    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.load(sessionId: receipt.sessionId)
    XCTAssertNil(model.message)
    XCTAssertEqual(model.segments.first { $0.sequence == bravo.sequence }?.effectiveText, "bravo corrected")
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(receipt.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: correctLabel, in: host) != nil
    }
    XCTAssertTrue(shown, self.hostedControlProbe(in: host))
    XCTAssertTrue(window.contentView === host)
    let pencil = try XCTUnwrap(self.claimButton(labeled: correctLabel, in: host))
    XCTAssertTrue(pencil.isDescendant(of: host))
    pencil.performClick(nil)
    let editor = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return self.hostedField(labeled: "Corrected text", in: host) != nil
        && self.claimButton(labeled: "Save correction", in: host) != nil
        && self.claimButton(labeled: "Cancel correction", in: host) != nil
        && self.claimButton(labeled: "Restore Machine Reading", in: host) != nil
    }
    XCTAssertTrue(editor && window.contentView === host, self.hostedControlProbe(in: host))
    let field = try XCTUnwrap(self.hostedField(labeled: "Corrected text", in: host))
    XCTAssertEqual(field.stringValue, "bravo corrected")
    XCTAssertTrue(
      self.hostedField(labeled: "Machine reading", in: host)?.stringValue.contains(bravoVerbatim)
        == true)
    field.stringValue = "   "
    let blocked = try XCTUnwrap(self.claimButton(labeled: "Save correction", in: host))
    XCTAssertFalse(blocked.isEnabled, self.hostedControlProbe(in: host))
    field.stringValue = "bravo revised"
    let save = try XCTUnwrap(self.claimButton(labeled: "Save correction", in: host))
    XCTAssertTrue(save.isEnabled && save.isDescendant(of: host))
    save.performClick(nil)
    let revised = "bravo revised"
    let saved = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      let passage = model.segments.first { $0.sequence == bravo.sequence }
      return passage?.effectiveText == revised && passage?.corrected == true
        && passage?.verbatimText == bravoVerbatim
        && self.hostedField(labeled: "Corrected text", in: host) == nil
    }
    XCTAssertTrue(saved && window.contentView === host, self.hostedControlProbe(in: host))
    XCTAssertEqual(model.segments.first { $0.sequence == alpha.sequence }?.effectiveText, alphaText)
    XCTAssertFalse(model.segments.first { $0.sequence == alpha.sequence }?.corrected ?? true)

    let again = try XCTUnwrap(self.claimButton(labeled: correctLabel, in: host))
    XCTAssertTrue(again.isDescendant(of: host))
    again.performClick(nil)
    let reopened = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      self.hostedField(labeled: "Corrected text", in: host)?.stringValue == revised
        && self.claimButton(labeled: "Cancel correction", in: host) != nil
    }
    XCTAssertTrue(reopened, self.hostedControlProbe(in: host))
    let dirty = try XCTUnwrap(self.hostedField(labeled: "Corrected text", in: host))
    dirty.stringValue = "bravo discarded"
    let cancel = try XCTUnwrap(self.claimButton(labeled: "Cancel correction", in: host))
    XCTAssertTrue(cancel.isEnabled && cancel.isDescendant(of: host))
    cancel.performClick(nil)
    let cancelled = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return self.hostedField(labeled: "Corrected text", in: host) == nil
        && model.segments.first { $0.sequence == bravo.sequence }?.effectiveText == revised
    }
    XCTAssertTrue(cancelled && window.contentView === host, self.hostedControlProbe(in: host))

    let restorePencil = try XCTUnwrap(self.claimButton(labeled: correctLabel, in: host))
    restorePencil.performClick(nil)
    let restoreShown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return self.claimButton(labeled: "Restore Machine Reading", in: host) != nil
    }
    XCTAssertTrue(restoreShown, self.hostedControlProbe(in: host))
    let restore = try XCTUnwrap(self.claimButton(labeled: "Restore Machine Reading", in: host))
    XCTAssertTrue(restore.isEnabled && restore.isDescendant(of: host))
    restore.performClick(nil)
    let restored = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      let passage = model.segments.first { $0.sequence == bravo.sequence }
      return passage?.effectiveText == bravoVerbatim && passage?.corrected == false
        && passage?.verbatimText == bravoVerbatim
        && self.hostedField(labeled: "Corrected text", in: host) == nil
    }
    XCTAssertTrue(restored && window.contentView === host, self.hostedControlProbe(in: host))
    for media in libraryMedia {
      XCTAssertEqual(try digest(of: media), packageDigest)
    }
    XCTAssertEqual(try digest(of: packageMedia[0]), packageDigest)
    withExtendedLifetime((store, live, playback, player, window, host, library)) {}
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

  /// The hosted claim row's own buttons open evidence, return, and review the
  /// claim. The test does not call `openClaimEvidence`, `returnToClaim`, or
  /// `adjudicateClaim`.
  func testHostedClaimButtonsSeekHighlightReturnAndAdjudicate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-claim-buttons-\(UUID().uuidString)", isDirectory: true)
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
    let supporting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: alpha.revisionId, sequence: alpha.sequence)
    let contradicting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: bravo.revisionId, sequence: bravo.sequence)
    try library.insertDerivedClaim(
      claimJson: citedClaimJSON(
        sessionId: receipt.sessionId, supporting: supporting, contradicting: contradicting))
    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.load(sessionId: receipt.sessionId)
    let claim = try XCTUnwrap(model.derivedClaims.first { $0.claimId == "claim-decision" })
    XCTAssertNil(claim.adjudication)
    XCTAssertEqual(claim.supportingCount, 1)
    XCTAssertEqual(claim.contradictingCount, 1)

    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(receipt.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: "Supporting evidence, 1", in: host) != nil
    }
    let supportButton = self.claimButton(labeled: "Supporting evidence, 1", in: host)
    XCTAssertTrue(
      shown && supportButton != nil && window.contentView === host,
      "bounds=\(host.bounds) claims=\(model.derivedClaims.count) buttons=\(self.claimButtonProbe(in: host))"
    )
    let support = try XCTUnwrap(supportButton)
    XCTAssertTrue(support.isDescendant(of: host))
    XCTAssertNil(self.claimButton(labeled: "Return to claim", in: host))
    let generation = model.claimFocusGeneration
    support.performClick(nil)
    await assertEventually {
      model.claimEvidenceOpen && model.claimHighlightSegmentId == alpha.id
        && player.importedStartNanoseconds == alpha.startNanoseconds
        && playback.playingSessionId == receipt.sessionId
    }
    XCTAssertEqual(model.focusedClaim?.claimId, claim.claimId)
    XCTAssertEqual(model.focusedClaim?.text, claim.text)
    XCTAssertNil(playback.errorMessage)
    let returned = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      self.claimButton(labeled: "Return to claim", in: host) != nil
    }
    let returnButton = try XCTUnwrap(self.claimButton(labeled: "Return to claim", in: host))
    XCTAssertTrue(returned && returnButton.isDescendant(of: host) && window.contentView === host)
    returnButton.performClick(nil)
    await assertEventually { !model.claimEvidenceOpen && model.claimHighlightSegmentId == nil }
    XCTAssertEqual(model.focusedClaim?.claimId, claim.claimId)
    XCTAssertEqual(model.claimFocusGeneration, generation + 1)
    XCTAssertNil(self.claimButton(labeled: "Return to claim", in: host))

    let contradict = try XCTUnwrap(self.claimButton(labeled: "Contradicting evidence, 1", in: host))
    XCTAssertTrue(contradict.isDescendant(of: host))
    contradict.performClick(nil)
    await assertEventually {
      model.claimHighlightSegmentId == bravo.id
        && player.importedStartNanoseconds == bravo.startNanoseconds
    }
    let returnAgain = try XCTUnwrap(self.claimButton(labeled: "Return to claim", in: host))
    returnAgain.performClick(nil)
    await assertEventually { !model.claimEvidenceOpen }

    let confirm = try XCTUnwrap(self.claimButton(labeled: "Confirm claim", in: host))
    confirm.performClick(nil)
    await assertEventually {
      model.derivedClaims.first { $0.claimId == claim.claimId }?.adjudication == "accepted"
    }
    let accepted = try XCTUnwrap(model.derivedClaims.first { $0.claimId == claim.claimId })
    XCTAssertEqual(accepted.text, claim.text)
    XCTAssertNotEqual(accepted.revisionId, "revision-a")

    let field = try XCTUnwrap(self.claimCorrectionField(in: host))
    let correctedText = "The team deferred the remote recorder."
    field.stringValue = correctedText
    let correct = try XCTUnwrap(self.claimButton(labeled: "Correct claim", in: host))
    correct.performClick(nil)
    await assertEventually {
      model.derivedClaims.first { $0.claimId == claim.claimId }?.text == correctedText
        && model.derivedClaims.first { $0.claimId == claim.claimId }?.adjudication == "corrected"
    }
    XCTAssertNotEqual(
      model.derivedClaims.first { $0.claimId == claim.claimId }?.revisionId, accepted.revisionId)

    let reject = try XCTUnwrap(self.claimButton(labeled: "Reject claim", in: host))
    reject.performClick(nil)
    await assertEventually {
      model.derivedClaims.first { $0.claimId == claim.claimId }?.adjudication == "rejected"
    }
    let rejected = try XCTUnwrap(model.derivedClaims.first { $0.claimId == claim.claimId })
    XCTAssertEqual(rejected.text, correctedText)
    XCTAssertTrue(window.contentView === host)
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    XCTAssertEqual(try digest(of: packageMedia[0]), packageDigest)
    withExtendedLifetime((store, live, playback, player, window, host)) {}
  }

  /// Supporting evidence re-reads the effective claims. A later revise of a
  /// rejected claim stays out of the review, and a different accepted claim
  /// appears only after that click. The test does not call `load` or
  /// `openClaimEvidence` after the later delta.
  func testHostedClaimEvidenceReloadsTheHumanClaimAfterALaterModelDelta() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-claim-reload-\(UUID().uuidString)", isDirectory: true)
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
    let supporting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: alpha.revisionId, sequence: alpha.sequence)
    let original = "The team agreed to ship the local recorder."
    let humanText = "The team deferred the remote recorder."
    let rejectedText = "The team agreed to upload every recording."
    let question = "Who owns the recorder?"
    let inputDigest = String(repeating: "b", count: 64)
    let proposed = """
      {"schema":"open-scribe.meeting-memory-delta/v1","model_run_id":"run-claim-1","input_manifest_digest":"\(inputDigest)","session_id":\(Self.jsonString(receipt.sessionId)),"base_revision":"0","operations":[{"op":"propose_claim","operation_id":"op-propose","kind":"decision","text":\(Self.jsonString(original)),"status":"agreed","supporting":[\(supporting)],"contradicting":[]}]}
      """
    let proposedReceipt = try library.ingestMeetingMemoryDelta(deltaJson: proposed)
    let proposedObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(proposedReceipt.utf8)) as? [String: Any])
    let proposedOperations = try XCTUnwrap(proposedObject["operations"] as? [[String: Any]])
    let proposedOperation = try XCTUnwrap(proposedOperations.first)
    XCTAssertEqual(proposedOperation["outcome"] as? String, "accepted", proposedReceipt)
    let claimId = try XCTUnwrap(proposedOperation["claim_id"] as? String)

    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: receipt.sessionId)
    XCTAssertEqual(model.derivedClaims.map(\.text), [original])
    XCTAssertNil(model.derivedClaims.first?.adjudication)

    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(receipt.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1200),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 1200))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let memory = self.readout(labeled: "Structured memory", in: host)?.stringValue ?? ""
      return self.claimButton(labeled: "Supporting evidence, 1", in: host) != nil
        && memory.contains("Decisions. \(original).")
        && self.readout(labeled: "Interpretation", in: host)?.stringValue == "Intelligence off"
    }
    XCTAssertTrue(
      shown && window.contentView === host,
      "memory=\(self.readout(labeled: "Structured memory", in: host)?.stringValue ?? "missing") buttons=\(self.claimButtonProbe(in: host))"
    )
    let field = try XCTUnwrap(self.claimCorrectionField(in: host))
    field.stringValue = humanText
    let correct = try XCTUnwrap(self.claimButton(labeled: "Correct claim", in: host))
    correct.performClick(nil)
    let corrected = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let memory = self.readout(labeled: "Structured memory", in: host)?.stringValue ?? ""
      return model.derivedClaims.first?.text == humanText
        && model.derivedClaims.first?.adjudication == "corrected"
        && memory.contains(humanText)
        && memory.contains("Adjudication corrected.")
    }
    XCTAssertTrue(
      corrected,
      self.readout(labeled: "Structured memory", in: host)?.stringValue ?? "missing memory")

    let reject = try XCTUnwrap(self.claimButton(labeled: "Reject claim", in: host))
    reject.performClick(nil)
    let rejected = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let memory = self.readout(labeled: "Structured memory", in: host)?.stringValue ?? ""
      return model.derivedClaims.first?.adjudication == "rejected"
        && model.derivedClaims.first?.text == humanText
        && memory.contains("Adjudication rejected.")
        && memory.contains(humanText)
    }
    XCTAssertTrue(
      rejected,
      self.readout(labeled: "Structured memory", in: host)?.stringValue ?? "missing memory")
    XCTAssertFalse(
      (self.readout(labeled: "Structured memory", in: host)?.stringValue ?? "").contains(question))

    let baseRevision = try library.meetingMemoryRevision(sessionId: receipt.sessionId)
    let laterDigest = String(repeating: "e", count: 64)
    let later = """
      {"schema":"open-scribe.meeting-memory-delta/v1","model_run_id":"run-later-1","input_manifest_digest":"\(laterDigest)","session_id":\(Self.jsonString(receipt.sessionId)),"base_revision":\(Self.jsonString(baseRevision)),"operations":[{"op":"revise_claim","operation_id":"op-revise","claim_id":\(Self.jsonString(claimId)),"kind":"decision","text":\(Self.jsonString(rejectedText)),"status":"agreed","supporting":[\(supporting)],"contradicting":[]},{"op":"propose_claim","operation_id":"op-other","kind":"question","text":\(Self.jsonString(question)),"status":"open","supporting":[\(supporting)],"contradicting":[]}]}
      """
    let laterReceipt = try library.ingestMeetingMemoryDelta(deltaJson: later)
    let laterObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(laterReceipt.utf8)) as? [String: Any])
    let laterOperations = try XCTUnwrap(laterObject["operations"] as? [[String: Any]])
    let revise = try XCTUnwrap(laterOperations.first { $0["operation_id"] as? String == "op-revise" })
    XCTAssertEqual(revise["outcome"] as? String, "rejected", laterReceipt)
    XCTAssertEqual(revise["reason"] as? String, "human adjudication stays in effect")
    let other = try XCTUnwrap(laterOperations.first { $0["operation_id"] as? String == "op-other" })
    XCTAssertEqual(other["outcome"] as? String, "accepted", laterReceipt)
    XCTAssertNotEqual(other["claim_id"] as? String, claimId)
    let appearedEarly = await waitUntil(timeoutNanoseconds: 400_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let memory = self.readout(labeled: "Structured memory", in: host)?.stringValue ?? ""
      return memory.contains(question) || model.derivedClaims.contains { $0.text == question }
    }
    XCTAssertFalse(
      appearedEarly,
      "the new claim appeared before Supporting evidence was clicked: \(self.readout(labeled: "Structured memory", in: host)?.stringValue ?? "")"
    )
    XCTAssertEqual(model.derivedClaims.map(\.text), [humanText])
    XCTAssertFalse(
      (self.readout(labeled: "Structured memory", in: host)?.stringValue ?? "").contains(rejectedText))
    let supportLabels = self.claimButtonProbe(in: host).filter {
      $0.contains("label=Supporting evidence, 1 ")
    }
    XCTAssertEqual(supportLabels.count, 1, supportLabels.joined(separator: "\n"))
    let support = try XCTUnwrap(self.claimButton(labeled: "Supporting evidence, 1", in: host))
    XCTAssertTrue(support.isDescendant(of: host))
    support.performClick(nil)
    let reloaded = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let memory = self.readout(labeled: "Structured memory", in: host)?.stringValue ?? ""
      let fields = self.claimCorrectionFields(in: host)
      return model.claimHighlightSegmentId == alpha.id
        && player.importedStartNanoseconds == alpha.startNanoseconds
        && playback.playingSessionId == receipt.sessionId
        && memory.contains(humanText)
        && memory.contains("Questions. \(question).")
        && !memory.contains(rejectedText)
        && fields.contains { $0.stringValue == humanText }
        && !fields.contains { $0.stringValue.contains(rejectedText) }
    }
    let memory = self.readout(labeled: "Structured memory", in: host)?.stringValue ?? "missing"
    XCTAssertTrue(reloaded, memory)
    XCTAssertEqual(model.focusedClaim?.claimId, claimId)
    XCTAssertEqual(model.focusedClaim?.text, humanText)
    XCTAssertEqual(model.focusedClaim?.adjudication, "rejected")
    XCTAssertEqual(self.readout(labeled: "Interpretation", in: host)?.stringValue, "Intelligence off")
    XCTAssertEqual(model.derivedClaims.map(\.text).sorted(), [humanText, question].sorted())
    XCTAssertFalse(model.derivedClaims.contains { $0.text == rejectedText })
    let refusal = model.refuseLocalIntelligence()
    XCTAssertEqual(refusal.readout, "Intelligence off")
    XCTAssertEqual(refusal.claimsWritten, 0)
    XCTAssertNil(refusal.engine)
    XCTAssertEqual(model.derivedClaims.count, 2)
    XCTAssertTrue(window.contentView === host)
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    XCTAssertEqual(try digest(of: packageMedia[0]), packageDigest)
    withExtendedLifetime((store, live, playback, player, window, host)) {}
  }

  /// Speaker assignment and a stored model claim show their own runs. The test
  /// reads those fields. It cites a selected final. It does not call `load`
  /// or the provenance formatters.
  func testHostedReviewReadsSpeakerAssignmentAndDerivedItemProvenance() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-speaker-derived-\(UUID().uuidString)", isDirectory: true)
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
    let imported = try library.importPortablePackage(packagePath: package.path)
    let segments = try library.document(sessionId: imported.sessionId)
    let alpha = try XCTUnwrap(segments.first { $0.sequence == 0 })
    XCTAssertEqual(alpha.finality, "final")
    let supporting = try library.citeTranscriptSegment(
      sessionId: imported.sessionId, revisionId: alpha.revisionId, sequence: alpha.sequence)
    let history = try library.speakerLabelHistory(sessionId: imported.sessionId)
    XCTAssertFalse(history.isEmpty)
    let inputDigest = String(repeating: "c", count: 64)
    let claimText = "The team agreed to keep the recorder local."
    let delta = """
      {"schema":"open-scribe.meeting-memory-delta/v1","model_run_id":"run-local-1","input_manifest_digest":"\(inputDigest)","session_id":"\(imported.sessionId)","base_revision":"0","operations":[{"op":"propose_claim","operation_id":"op-propose","kind":"decision","text":"\(claimText)","status":"agreed","supporting":[\(supporting)],"contradicting":[]}]}
      """
    let receipt = try library.ingestMeetingMemoryDelta(deltaJson: delta)
    let receiptObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(receipt.utf8)) as? [String: Any])
    let operations = try XCTUnwrap(receiptObject["operations"] as? [[String: Any]])
    let operation = try XCTUnwrap(operations.first)
    XCTAssertEqual(operation["outcome"] as? String, "accepted", receipt)
    XCTAssertEqual(receiptObject["model_run_id"] as? String, "run-local-1")
    let revisionId = try XCTUnwrap(operation["revision_id"] as? String)

    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == imported.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let presentation = try XCTUnwrap(
      store.savedSessions.first { $0.sessionId == imported.sessionId })
    XCTAssertNil(presentation.transcriptionUnavailableReason)

    let model = TranscriptLibraryModel(library: library)
    let section = TranscriptSection(
      session: presentation,
      transcripts: model,
      speech: SpeechTranscriptionModel(preview: []),
      scheduler: TranscriptionScheduler.inert(),
      canSeek: false,
      onSeek: { _ in }
    ).frame(width: 720, height: 640)
    let host = NSHostingView(rootView: section)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 720, height: 640))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard let speakers = self.readout(labeled: "Speaker assignment", in: host),
        let derived = self.readout(labeled: "Derived item provenance", in: host)
      else { return false }
      return !speakers.isHidden && speakers.frame.height > 1 && speakers.isDescendant(of: host)
        && speakers.stringValue.contains("Source default:")
        && !derived.isHidden && derived.frame.height > 1 && derived.isDescendant(of: host)
        && derived.stringValue.contains("run-local-1")
    }
    XCTAssertTrue(
      shown && window.contentView === host,
      self.hostedControlProbe(in: host))
    let speakers = try XCTUnwrap(self.readout(labeled: "Speaker assignment", in: host))
    let derived = try XCTUnwrap(self.readout(labeled: "Derived item provenance", in: host))
    let speakerText = speakers.stringValue
    XCTAssertTrue(
      speakerText.contains(
        "Speakers follow the audio source. Voice diarization is unavailable without a calibrated model."
      ))
    for item in history {
      XCTAssertTrue(speakerText.contains("Source default: \(item.sourceDefaultLabel)"))
    }
    XCTAssertFalse(speakerText.localizedCaseInsensitiveContains("identical"))
    XCTAssertFalse(speakerText.localizedCaseInsensitiveContains("deterministic"))
    XCTAssertFalse(speakerText.contains(alpha.effectiveText))
    XCTAssertFalse(speakerText.contains(claimText))
    let derivedText = derived.stringValue
    XCTAssertTrue(derivedText.contains("Model run run-local-1."))
    XCTAssertTrue(derivedText.contains("Input \(inputDigest)."))
    XCTAssertTrue(derivedText.contains("Revision \(revisionId)."))
    XCTAssertTrue(
      derivedText.contains(
        "Evidence supporting \(alpha.startNanoseconds)-\(alpha.endNanoseconds) ns."))
    XCTAssertTrue(
      derivedText.hasSuffix(
        "Open Scribe does not claim that running this model again produces the same words."))
    XCTAssertFalse(derivedText.localizedCaseInsensitiveContains("identical"))
    XCTAssertFalse(derivedText.localizedCaseInsensitiveContains("deterministic"))
    XCTAssertFalse(derivedText.contains(alpha.effectiveText))
    XCTAssertFalse(derivedText.contains(claimText))
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    XCTAssertEqual(try digest(of: packageMedia[0]), packageDigest)
    withExtendedLifetime((model, store, library)) {}
  }

  /// A stored decision appears under Decisions. Intelligence stays off and
  /// writes nothing, so no Loose End is invented.
  func testHostedStructuredMemoryShowsTheStoredDecisionWhileIntelligenceIsOff() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-structured-memory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Stored.openscribe")
    let export = await exportStoredFinalPackage(to: package)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))

    let managed = root.appendingPathComponent("Library", isDirectory: true)
    let library = try NativeTranscriptLibrary.open(managedRoot: managed.path)
    let imported = try library.importPortablePackage(packagePath: package.path)
    let segments = try library.document(sessionId: imported.sessionId)
    let alpha = try XCTUnwrap(segments.first { $0.sequence == 0 })
    XCTAssertEqual(alpha.finality, "final")
    let supporting = try library.citeTranscriptSegment(
      sessionId: imported.sessionId, revisionId: alpha.revisionId, sequence: alpha.sequence)
    let inputDigest = String(repeating: "d", count: 64)
    let claimText = "The team kept the recorder on this machine."
    let delta = """
      {"schema":"open-scribe.meeting-memory-delta/v1","model_run_id":"run-memory-1","input_manifest_digest":"\(inputDigest)","session_id":"\(imported.sessionId)","base_revision":"0","operations":[{"op":"propose_claim","operation_id":"op-memory","kind":"decision","text":"\(claimText)","status":"agreed","supporting":[\(supporting)],"contradicting":[]}]}
      """
    let receipt = try library.ingestMeetingMemoryDelta(deltaJson: delta)
    let receiptObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(receipt.utf8)) as? [String: Any])
    let operations = try XCTUnwrap(receiptObject["operations"] as? [[String: Any]])
    let operation = try XCTUnwrap(operations.first)
    XCTAssertEqual(operation["outcome"] as? String, "accepted", receipt)
    let claimId = try XCTUnwrap(operation["claim_id"] as? String)

    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == imported.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let presentation = try XCTUnwrap(
      store.savedSessions.first { $0.sessionId == imported.sessionId })
    XCTAssertNil(presentation.transcriptionUnavailableReason)

    let model = TranscriptLibraryModel(library: library)
    let review = VStack(alignment: .leading, spacing: 12) {
      TranscriptSection(
        session: presentation,
        transcripts: model,
        speech: SpeechTranscriptionModel(preview: []),
        scheduler: TranscriptionScheduler.inert(),
        canSeek: false,
        onSeek: { _ in }
      )
      InterpretationSection(transcripts: model)
    }.frame(width: 720, height: 820)
    let host = NSHostingView(rootView: review)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 820),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 720, height: 820))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard let interpretation = self.readout(labeled: "Interpretation", in: host),
        let memory = self.readout(labeled: "Structured memory", in: host)
      else { return false }
      return interpretation.stringValue == "Intelligence off"
        && !memory.isHidden && memory.frame.height > 1 && memory.isDescendant(of: host)
        && memory.stringValue.contains("Decisions. \(claimText).")
    }
    XCTAssertTrue(shown && window.contentView === host, self.hostedControlProbe(in: host))
    let interpretation = try XCTUnwrap(self.readout(labeled: "Interpretation", in: host))
    let memory = try XCTUnwrap(self.readout(labeled: "Structured memory", in: host))
    XCTAssertEqual(interpretation.stringValue, "Intelligence off")
    let memoryText = memory.stringValue
    XCTAssertTrue(memoryText.contains("Decisions. \(claimText)."))
    XCTAssertTrue(memoryText.contains("Status agreed."))
    XCTAssertTrue(memoryText.contains("Producer model run."))
    XCTAssertTrue(memoryText.contains("Model run run-memory-1."))
    XCTAssertTrue(memoryText.contains("Evidence supporting 1, contradicting 0."))
    XCTAssertTrue(memoryText.contains("Id \(claimId)."))
    XCTAssertFalse(memoryText.contains("Loose End"))
    XCTAssertFalse(memoryText.contains("Open loops"))
    XCTAssertFalse(memoryText.contains("People"))
    XCTAssertEqual(model.derivedClaims.count, 1)
    XCTAssertEqual(model.derivedClaims.first?.text, claimText)
    let refusal = model.refuseLocalIntelligence()
    XCTAssertEqual(refusal.readout, interpretation.stringValue)
    XCTAssertEqual(refusal.mode, "disabled")
    XCTAssertEqual(refusal.claimsWritten, 0)
    XCTAssertNil(refusal.engine)
    XCTAssertEqual(model.derivedClaims.count, 1)
    XCTAssertEqual(StructuredMemory.text(for: model.derivedClaims), memoryText)
    withExtendedLifetime((model, store, library)) {}
  }

  private func readout(labeled label: String, in root: NSView) -> NSTextField? {
    if let field = root as? NSTextField, field.accessibilityLabel() == label {
      return field
    }
    for subview in root.subviews {
      if let found = readout(labeled: label, in: subview) { return found }
    }
    return nil
  }

  private func textFieldProbe(in root: NSView) -> String {
    var lines: [String] = []
    func walk(_ view: NSView) {
      if let field = view as? NSTextField {
        lines.append(
          "field label=\(field.accessibilityLabel() ?? "") placeholder=\(field.placeholderString ?? "") id=\(field.accessibilityIdentifier() ?? "") value=\(field.stringValue) hidden=\(field.isHidden)"
        )
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return lines.joined(separator: "\n")
  }

  private func searchField(in root: NSView) -> NSTextField? {
    var matched: NSTextField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSTextField, !(field is NSTextView),
        field.isHidden == false,
        field.isHiddenOrHasHiddenAncestor == false,
        field.accessibilityLabel() == ConversationControlLabels.findInTranscript
          || field.placeholderString == ConversationControlLabels.findInTranscript
      {
        matched = field
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func hostedString(containing needle: String, in root: NSView) -> Bool {
    var found = false
    func walk(_ view: NSView) {
      if found { return }
      if let field = view as? NSTextField, field.stringValue.contains(needle) {
        found = true
      }
      if let text = view as? NSTextView, text.string.contains(needle) {
        found = true
      }
      if let label = view.accessibilityLabel(), label.contains(needle) {
        found = true
      }
      if let value = view.accessibilityValue() as? String, value.contains(needle) {
        found = true
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return found
  }

  private func claimButton(labeled label: String, in root: NSView) -> NSButton? {
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton,
        button.accessibilityLabel() == label,
        button.isHidden == false,
        button.isHiddenOrHasHiddenAncestor == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func passageStateField(labeled label: String, in root: NSView) -> NSTextField? {
    var matched: NSTextField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSTextField,
        field.accessibilityLabel() == label,
        field.stringValue == label,
        field.isHidden == false,
        field.isHiddenOrHasHiddenAncestor == false,
        field.frame.width > 1,
        field.frame.height > 1
      {
        matched = field
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func claimCorrectionFields(in root: NSView) -> [NSTextField] {
    var fields: [NSTextField] = []
    func walk(_ view: NSView) {
      if let field = view as? NSTextField, field.accessibilityLabel() == "Corrected claim text" {
        fields.append(field)
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return fields
  }

  private func claimCorrectionField(in root: NSView) -> NSTextField? {
    var matched: NSTextField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSTextField, field.accessibilityLabel() == "Corrected claim text",
        field.isHidden == false
      {
        matched = field
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func hostedSearchField(in root: NSView) -> NSSearchField? {
    var matched: NSSearchField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSSearchField {
        let label = field.accessibilityLabel() ?? ""
        let placeholder = field.placeholderString ?? ""
        let identifier = field.accessibilityIdentifier() ?? ""
        let named =
          label == "Search transcripts" || placeholder == "Search transcripts"
          || identifier == "Search transcripts"
        if named, field.isHidden == false, field.isHiddenOrHasHiddenAncestor == false,
          field.frame.width > 1, field.frame.height > 1
        {
          matched = field
        }
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func hostedResultButtons(containing text: String, in root: NSView) -> [NSButton] {
    var matched: [NSButton] = []
    func walk(_ view: NSView) {
      if let button = view as? NSButton, !(button is NSPopUpButton) {
        let label = button.accessibilityLabel() ?? ""
        let visible =
          button.isHidden == false && button.isHiddenOrHasHiddenAncestor == false
          && button.frame.width > 1 && button.frame.height > 1
        if visible, button.title.contains(text) || label.contains(text) {
          matched.append(button)
        }
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func hostedField(labeled label: String, in root: NSView) -> NSTextField? {
    var matched: NSTextField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSTextField,
        field.accessibilityLabel() == label,
        field.isHidden == false,
        field.isHiddenOrHasHiddenAncestor == false,
        field.frame.width > 1,
        field.frame.height > 1
      {
        matched = field
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  /// The passage row is the first ancestor taller than the timestamp button
  /// and still shorter than the whole transcript column.
  private func passageRowHeight(of button: NSButton) -> CGFloat {
    var view = button.superview
    var steps = 0
    while let current = view, steps < 12 {
      let height = current.frame.height
      if height > button.frame.height + 4, height < 180 { return height }
      view = current.superview
      steps += 1
    }
    return button.frame.height
  }

  private func ancestorHeights(of button: NSButton) -> [CGFloat] {
    var heights: [CGFloat] = [button.frame.height]
    var view = button.superview
    var steps = 0
    while let current = view, steps < 8 {
      heights.append(current.frame.height)
      view = current.superview
      steps += 1
    }
    return heights
  }

  private func hostedPopup(labeled label: String, in root: NSView) -> NSPopUpButton? {
    var matched: NSPopUpButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let popup = view as? NSPopUpButton,
        popup.accessibilityLabel() == label || popup.accessibilityIdentifier() == label,
        popup.isHidden == false,
        popup.isHiddenOrHasHiddenAncestor == false,
        popup.frame.width > 1,
        popup.frame.height > 1
      {
        matched = popup
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func hostedControlProbe(in root: NSView) -> String {
    var lines: [String] = []
    func walk(_ view: NSView) {
      if let button = view as? NSButton {
        lines.append(
          "button label=\(button.accessibilityLabel() ?? "") title=\(button.title) frame=\(button.frame) hidden=\(button.isHidden) ancestor=\(button.isHiddenOrHasHiddenAncestor) enabled=\(button.isEnabled)"
        )
      } else if let field = view as? NSTextField {
        lines.append(
          "field label=\(field.accessibilityLabel() ?? "") value=\(field.stringValue) frame=\(field.frame) hidden=\(field.isHidden) ancestor=\(field.isHiddenOrHasHiddenAncestor)"
        )
      }
      if view.accessibilityIdentifier() == "Speaker review" {
        lines.append("banner frame=\(view.frame) hidden=\(view.isHidden)")
      }
      if view.accessibilityIdentifier() == "Transcript matches" {
        lines.append("matches frame=\(view.frame) hidden=\(view.isHidden)")
      }
      if view.accessibilityIdentifier() == "Correct transcript text" {
        lines.append("correction frame=\(view.frame) hidden=\(view.isHidden)")
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return lines.joined(separator: "\n")
  }

  private func claimButtonProbe(in root: NSView) -> [String] {
    var lines: [String] = []
    func walk(_ view: NSView) {
      if let button = view as? NSButton {
        lines.append(
          "\(button.title) label=\(button.accessibilityLabel() ?? "") frame=\(button.frame) hidden=\(button.isHidden)"
        )
      }
      if view.accessibilityIdentifier() == "Claim actions" {
        lines.append("banner frame=\(view.frame) hidden=\(view.isHidden)")
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return lines
  }

  /// An imported stored final, including its stored correction, receives named
  /// people. Merge, split, rename, and restoring the source name keep the
  /// earlier assignments and leave the audio and transcript text unchanged.
  func testNamedSpeakersMergeAndSplitOnAStoredFinalAndKeepTheCorrection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-speaker-merge-\(UUID().uuidString)", isDirectory: true)
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
    let stored = try library.document(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(stored.first { $0.sequence == 0 })
    let bravo = try XCTUnwrap(stored.first { $0.sequence == 1 })
    XCTAssertEqual(alpha.finality, "final")
    XCTAssertFalse(alpha.corrected)
    XCTAssertEqual(bravo.finality, "final")
    XCTAssertTrue(bravo.corrected)
    XCTAssertNotEqual(bravo.effectiveText, bravo.verbatimText)
    XCTAssertGreaterThan(bravo.startNanoseconds, alpha.endNanoseconds)
    XCTAssertEqual(alpha.speakerLabel, "Unknown speaker")
    XCTAssertEqual(bravo.speakerLabel, "Unknown speaker")
    XCTAssertNil(alpha.namedSpeakerId)
    XCTAssertNil(bravo.namedSpeakerId)
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    let before = try library.prepareSpeakerDiarization(sessionId: receipt.sessionId)
    XCTAssertEqual(before.algorithmId, "topology-before-clustering-v1")
    XCTAssertEqual(before.clusteringState, "unavailable")
    XCTAssertEqual(before.reason, "no calibrated diarization model")

    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.load(sessionId: receipt.sessionId)
    XCTAssertNil(model.message)
    XCTAssertEqual(
      model.speakerDiarizationText,
      "Speakers follow the audio source. Voice diarization is unavailable without a calibrated model."
    )
    let loadedAlpha = try XCTUnwrap(model.segments.first { $0.sequence == alpha.sequence })
    let loadedBravo = try XCTUnwrap(model.segments.first { $0.sequence == bravo.sequence })
    let namedDana = await model.assignSpeaker(
      sessionId: receipt.sessionId, segment: loadedAlpha, assignment: .new(label: "Dana"))
    XCTAssertTrue(namedDana, model.message ?? "")
    let namedMorgan = await model.assignSpeaker(
      sessionId: receipt.sessionId, segment: loadedBravo, assignment: .new(label: "Morgan"))
    XCTAssertTrue(namedMorgan, model.message ?? "")
    let dana = try XCTUnwrap(model.namedSpeakers.first { $0.label == "Dana" })
    let morgan = try XCTUnwrap(model.namedSpeakers.first { $0.label == "Morgan" })
    XCTAssertEqual(dana.selectedTurns, 1)
    XCTAssertEqual(morgan.selectedTurns, 1)
    let assignedAlpha = try XCTUnwrap(model.segments.first { $0.sequence == alpha.sequence })
    let assignedBravo = try XCTUnwrap(model.segments.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(assignedAlpha.speakerLabel, "Dana")
    XCTAssertEqual(assignedAlpha.namedSpeakerId, dana.id)
    XCTAssertEqual(assignedBravo.speakerLabel, "Morgan")
    XCTAssertEqual(assignedBravo.namedSpeakerId, morgan.id)
    XCTAssertEqual(assignedAlpha.effectiveText, alpha.effectiveText)
    XCTAssertEqual(assignedBravo.verbatimText, bravo.verbatimText)
    XCTAssertEqual(assignedBravo.effectiveText, bravo.effectiveText)
    XCTAssertTrue(assignedBravo.corrected)

    let merged = await model.mergeNamedSpeakers(
      sessionId: receipt.sessionId, keepId: dana.id, absorbId: morgan.id)
    XCTAssertTrue(merged, model.message ?? "")
    XCTAssertEqual(
      try library.mergeNamedSpeakers(
        sessionId: receipt.sessionId, keepId: dana.id, absorbId: morgan.id),
      0)
    XCTAssertEqual(model.segments.map(\.speakerLabel), ["Dana", "Dana"])
    XCTAssertEqual(model.namedSpeakers.first { $0.id == dana.id }?.selectedTurns, 2)
    XCTAssertEqual(model.namedSpeakers.first { $0.id == morgan.id }?.selectedTurns, 0)
    let mergedHistory = try XCTUnwrap(
      model.namedSpeakerTurnHistory.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(mergedHistory.sourceDefaultLabel, "Unknown speaker")
    XCTAssertEqual(mergedHistory.revisions.map(\.label), ["Morgan", "Dana"])
    XCTAssertEqual(mergedHistory.revisions.map(\.origin), [.human, .human])
    XCTAssertEqual(
      TranscriptLibraryModel.namedSpeakerTurnHistoryText(for: mergedHistory),
      """
      Source default: Unknown speaker
      Morgan, named by you
      Dana, named by you
      """)

    let renamed = await model.renameNamedSpeaker(
      sessionId: receipt.sessionId, speakerId: dana.id, label: "D. Morgan")
    XCTAssertTrue(renamed, model.message ?? "")
    XCTAssertEqual(model.segments.map(\.speakerLabel), ["D. Morgan", "D. Morgan"])
    let renamedHistory = try XCTUnwrap(
      model.namedSpeakerTurnHistory.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(renamedHistory.revisions.map(\.label), ["Morgan", "Dana"])

    let turns = [assignedAlpha, assignedBravo].map {
      NativeNamedSpeakerTurn(revisionId: $0.revisionId, sequence: $0.sequence)
    }
    XCTAssertThrowsError(
      try library.splitNamedSpeaker(
        sessionId: receipt.sessionId, speakerId: dana.id, turns: [], label: "Mina")
    ) { error in
      XCTAssertEqual(error as? NativeStorageError, .InvalidRequest)
    }
    XCTAssertThrowsError(
      try library.splitNamedSpeaker(
        sessionId: receipt.sessionId, speakerId: dana.id, turns: turns, label: "Noah")
    ) { error in
      XCTAssertEqual(error as? NativeStorageError, .InvalidRequest)
    }
    let currentBravo = try XCTUnwrap(model.segments.first { $0.sequence == bravo.sequence })
    let split = await model.splitNamedSpeaker(
      sessionId: receipt.sessionId, speakerId: dana.id, segment: currentBravo, label: "Mina")
    XCTAssertTrue(split, model.message ?? "")
    let splitAlpha = try XCTUnwrap(model.segments.first { $0.sequence == alpha.sequence })
    let splitBravo = try XCTUnwrap(model.segments.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(splitAlpha.speakerLabel, "D. Morgan")
    XCTAssertEqual(splitAlpha.namedSpeakerId, dana.id)
    XCTAssertEqual(splitBravo.speakerLabel, "Mina")
    XCTAssertNotEqual(splitBravo.namedSpeakerId, dana.id)
    XCTAssertEqual(splitAlpha.effectiveText, alpha.effectiveText)
    XCTAssertEqual(splitAlpha.startNanoseconds, alpha.startNanoseconds)
    XCTAssertEqual(splitBravo.verbatimText, bravo.verbatimText)
    XCTAssertEqual(splitBravo.effectiveText, bravo.effectiveText)
    XCTAssertTrue(splitBravo.corrected)
    XCTAssertEqual(splitBravo.startNanoseconds, bravo.startNanoseconds)
    let grown = try XCTUnwrap(
      model.namedSpeakerTurnHistory.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(grown.revisions.map(\.label), ["Morgan", "Dana", "Mina"])
    XCTAssertEqual(
      TranscriptLibraryModel.namedSpeakerTurnHistoryText(for: grown),
      """
      Source default: Unknown speaker
      Morgan, named by you
      Dana, named by you
      Mina, named by you
      """)
    XCTAssertEqual(model.namedSpeakers.first { $0.id == dana.id }?.selectedTurns, 1)
    XCTAssertEqual(model.namedSpeakers.first { $0.id == morgan.id }?.selectedTurns, 0)
    XCTAssertEqual(model.namedSpeakers.first { $0.label == "Mina" }?.selectedTurns, 1)

    let restored = await model.assignSpeaker(
      sessionId: receipt.sessionId, segment: splitAlpha, assignment: .source)
    XCTAssertTrue(restored, model.message ?? "")
    let restoredAlpha = try XCTUnwrap(model.segments.first { $0.sequence == alpha.sequence })
    let restoredBravo = try XCTUnwrap(model.segments.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(restoredAlpha.speakerLabel, "Unknown speaker")
    XCTAssertNil(restoredAlpha.namedSpeakerId)
    XCTAssertEqual(restoredBravo.speakerLabel, "Mina")
    XCTAssertEqual(restoredBravo.effectiveText, bravo.effectiveText)
    let restoredHistory = try XCTUnwrap(
      model.namedSpeakerTurnHistory.first { $0.sequence == alpha.sequence })
    XCTAssertEqual(restoredHistory.revisions.map(\.label), ["Dana", "Unknown speaker"])
    XCTAssertEqual(restoredHistory.revisions.map(\.origin), [.human, .sourceDefault])
    XCTAssertEqual(
      TranscriptLibraryModel.namedSpeakerTurnHistoryText(for: restoredHistory),
      """
      Source default: Unknown speaker
      Dana, named by you
      Unknown speaker, source name
      """)
    let bravoHistory = try XCTUnwrap(
      model.namedSpeakerTurnHistory.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(bravoHistory.revisions.map(\.label), ["Morgan", "Dana", "Mina"])

    let reread = try library.document(sessionId: receipt.sessionId)
    let rereadAlpha = try XCTUnwrap(reread.first { $0.sequence == alpha.sequence })
    let rereadBravo = try XCTUnwrap(reread.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(rereadAlpha.speakerLabel, "Unknown speaker")
    XCTAssertEqual(rereadAlpha.verbatimText, alpha.verbatimText)
    XCTAssertEqual(rereadBravo.speakerLabel, "Mina")
    XCTAssertEqual(rereadBravo.verbatimText, bravo.verbatimText)
    XCTAssertEqual(rereadBravo.effectiveText, bravo.effectiveText)
    XCTAssertTrue(rereadBravo.corrected)
    let tracks = try library.speakers(sessionId: receipt.sessionId)
    XCTAssertEqual(tracks.map(\.label), ["Unknown speaker"])
    XCTAssertEqual(tracks.map(\.namedByUser), [false])
    let after = try library.prepareSpeakerDiarization(sessionId: receipt.sessionId)
    XCTAssertFalse(after.inserted)
    XCTAssertEqual(after.runId, before.runId)
    XCTAssertEqual(after.algorithmId, before.algorithmId)
    XCTAssertEqual(after.clusteringState, "unavailable")
    XCTAssertEqual(after.reason, before.reason)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    XCTAssertEqual(try digest(of: packageMedia[0]), packageDigest)
    XCTAssertNil(model.message)
    withExtendedLifetime(library) {}
  }

  /// The hosted reader names two stored passages, merges the second person
  /// into the first, renames, splits one passage, and restores the source
  /// label. The clicks are the shipped controls. The correction and audio stay.
  func testHostedSpeakerReviewAssignsMergesRenamesSplitsAndRestores() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-hosted-speaker-\(UUID().uuidString)", isDirectory: true)
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
    let stored = try library.document(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(stored.first { $0.sequence == 0 })
    let bravo = try XCTUnwrap(stored.first { $0.sequence == 1 })
    XCTAssertEqual(alpha.finality, "final")
    XCTAssertFalse(alpha.corrected)
    XCTAssertEqual(bravo.finality, "final")
    XCTAssertTrue(bravo.corrected)
    XCTAssertGreaterThan(bravo.startNanoseconds, alpha.endNanoseconds)
    XCTAssertEqual(alpha.speakerLabel, "Unknown speaker")
    XCTAssertEqual(bravo.speakerLabel, "Unknown speaker")
    XCTAssertNil(alpha.namedSpeakerId)
    XCTAssertNil(bravo.namedSpeakerId)
    let alphaText = alpha.effectiveText
    let bravoText = bravo.effectiveText
    let bravoVerbatim = bravo.verbatimText
    let libraryMedia = try regularFiles(under: managed.appendingPathComponent("Sessions"))
      .filter { $0.pathExtension == "caf" }
    XCTAssertEqual(libraryMedia.count, 1)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)

    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.load(sessionId: receipt.sessionId)
    XCTAssertNil(model.message)
    XCTAssertEqual(
      model.speakerDiarizationText,
      "Speakers follow the audio source. Voice diarization is unavailable without a calibrated model."
    )
    let alphaStamp = TranscriptSection.timestamp(alpha.startNanoseconds)
    let bravoStamp = TranscriptSection.timestamp(bravo.startNanoseconds)
    XCTAssertEqual(alphaStamp, "0:00")
    XCTAssertEqual(bravoStamp, "0:02")
    func speakerControl(_ stamp: String, _ label: String) -> String {
      ConversationControlLabels.nameSpeakerAccessibility(stamp: stamp, label: label)
    }
    let alphaUnknown = speakerControl(alphaStamp, "Unknown speaker")
    let bravoUnknown = speakerControl(bravoStamp, "Unknown speaker")
    XCTAssertNotEqual(alphaUnknown, bravoUnknown)

    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(receipt.sessionId)
    let player = RecoveredAudioPlayerFake()
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.claimButton(labeled: alphaUnknown, in: host) != nil
        && self.claimButton(labeled: bravoUnknown, in: host) != nil
    }
    XCTAssertTrue(shown, self.hostedControlProbe(in: host))
    XCTAssertTrue(window.contentView === host)
    let alphaButton = try XCTUnwrap(self.claimButton(labeled: alphaUnknown, in: host))
    XCTAssertTrue(alphaButton.isDescendant(of: host))
    alphaButton.performClick(nil)
    let danaFieldShown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      self.hostedField(labeled: "Person's name", in: host) != nil
        && self.claimButton(labeled: "Save speaker", in: host) != nil
    }
    XCTAssertTrue(danaFieldShown && window.contentView === host, self.hostedControlProbe(in: host))
    let danaField = try XCTUnwrap(self.hostedField(labeled: "Person's name", in: host))
    danaField.stringValue = "Dana"
    let saveDana = try XCTUnwrap(self.claimButton(labeled: "Save speaker", in: host))
    XCTAssertTrue(saveDana.isEnabled, self.hostedControlProbe(in: host))
    saveDana.performClick(nil)
    await assertEventually {
      model.segments.first { $0.sequence == alpha.sequence }?.speakerLabel == "Dana"
    }

    let bravoButton = try XCTUnwrap(self.claimButton(labeled: bravoUnknown, in: host))
    XCTAssertTrue(bravoButton.isDescendant(of: host) && window.contentView === host)
    bravoButton.performClick(nil)
    let morganFieldShown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      self.hostedField(labeled: "Person's name", in: host) != nil
    }
    XCTAssertTrue(morganFieldShown, self.hostedControlProbe(in: host))
    let morganField = try XCTUnwrap(self.hostedField(labeled: "Person's name", in: host))
    morganField.stringValue = "Morgan"
    let saveMorgan = try XCTUnwrap(self.claimButton(labeled: "Save speaker", in: host))
    XCTAssertTrue(saveMorgan.isEnabled)
    saveMorgan.performClick(nil)
    let named = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return model.segments.first { $0.sequence == bravo.sequence }?.speakerLabel == "Morgan"
        && self.claimButton(labeled: "Rename Morgan", in: host) != nil
        && self.claimButton(labeled: "Rename Dana", in: host) != nil
    }
    XCTAssertTrue(named && window.contentView === host, self.hostedControlProbe(in: host))

    // Morgan is the person being edited, so merge absorbs Morgan and keeps Dana.
    let renameMorgan = try XCTUnwrap(self.claimButton(labeled: "Rename Morgan", in: host))
    XCTAssertTrue(renameMorgan.isDescendant(of: host))
    renameMorgan.performClick(nil)
    let mergeShown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return self.hostedPopup(labeled: "Merge into", in: host) != nil
        && self.claimButton(labeled: "Merge speakers", in: host) != nil
    }
    XCTAssertTrue(mergeShown, self.hostedControlProbe(in: host))
    let popup = try XCTUnwrap(self.hostedPopup(labeled: "Merge into", in: host))
    popup.selectItem(withTitle: "Dana")
    XCTAssertEqual(popup.selectedItem?.title, "Dana")
    let merge = try XCTUnwrap(self.claimButton(labeled: "Merge speakers", in: host))
    XCTAssertTrue(merge.isEnabled && merge.isDescendant(of: host), self.hostedControlProbe(in: host))
    merge.performClick(nil)
    await assertEventually {
      model.segments.map(\.speakerLabel) == ["Dana", "Dana"]
        && model.namedSpeakerTurnHistory.first { $0.sequence == bravo.sequence }?.revisions.map(
          \.label) == ["Morgan", "Dana"]
    }
    let mergedHistory = try XCTUnwrap(
      model.namedSpeakerTurnHistory.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(mergedHistory.revisions.map(\.origin), [.human, .human])
    XCTAssertEqual(model.namedSpeakers.first { $0.label == "Dana" }?.selectedTurns, 2)
    XCTAssertEqual(
      TranscriptLibraryModel.namedSpeakerTurnHistoryText(for: mergedHistory),
      """
      Source default: Unknown speaker
      Morgan, named by you
      Dana, named by you
      """)

    let renameDana = try XCTUnwrap(self.claimButton(labeled: "Rename Dana", in: host))
    XCTAssertTrue(renameDana.isDescendant(of: host) && window.contentView === host)
    renameDana.performClick(nil)
    let renameShown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      self.hostedField(labeled: "Person's name", in: host)?.stringValue == "Dana"
    }
    XCTAssertTrue(renameShown, self.hostedControlProbe(in: host))
    let renameField = try XCTUnwrap(self.hostedField(labeled: "Person's name", in: host))
    renameField.stringValue = "D. Morgan"
    let saveRename = try XCTUnwrap(self.claimButton(labeled: "Save speaker", in: host))
    XCTAssertTrue(saveRename.isEnabled)
    saveRename.performClick(nil)
    let renamedLabel = speakerControl(bravoStamp, "D. Morgan")
    let renamed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return model.segments.map(\.speakerLabel) == ["D. Morgan", "D. Morgan"]
        && self.claimButton(labeled: renamedLabel, in: host) != nil
    }
    XCTAssertTrue(renamed, self.hostedControlProbe(in: host))
    let renamedHistory = try XCTUnwrap(
      model.namedSpeakerTurnHistory.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(renamedHistory.revisions.map(\.label), ["Morgan", "Dana"])

    let splitPassage = try XCTUnwrap(self.claimButton(labeled: renamedLabel, in: host))
    XCTAssertTrue(splitPassage.isDescendant(of: host) && window.contentView === host)
    splitPassage.performClick(nil)
    let splitShown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return self.hostedField(labeled: "Name for the split passage", in: host) != nil
        && self.claimButton(labeled: "Split this passage", in: host) != nil
    }
    XCTAssertTrue(splitShown, self.hostedControlProbe(in: host))
    let splitField = try XCTUnwrap(self.hostedField(labeled: "Name for the split passage", in: host))
    splitField.stringValue = "Mina"
    let split = try XCTUnwrap(self.claimButton(labeled: "Split this passage", in: host))
    XCTAssertTrue(split.isEnabled && split.isDescendant(of: host), self.hostedControlProbe(in: host))
    split.performClick(nil)
    let minaLabel = speakerControl(bravoStamp, "Mina")
    let splitDone = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return model.segments.first { $0.sequence == bravo.sequence }?.speakerLabel == "Mina"
        && model.segments.first { $0.sequence == alpha.sequence }?.speakerLabel == "D. Morgan"
        && self.claimButton(labeled: minaLabel, in: host) != nil
    }
    XCTAssertTrue(splitDone && window.contentView === host, self.hostedControlProbe(in: host))
    let grown = try XCTUnwrap(
      model.namedSpeakerTurnHistory.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(grown.revisions.map(\.label), ["Morgan", "Dana", "Mina"])
    XCTAssertEqual(
      TranscriptLibraryModel.namedSpeakerTurnHistoryText(for: grown),
      """
      Source default: Unknown speaker
      Morgan, named by you
      Dana, named by you
      Mina, named by you
      """)
    XCTAssertEqual(model.namedSpeakers.first { $0.label == "D. Morgan" }?.selectedTurns, 1)
    XCTAssertEqual(model.namedSpeakers.first { $0.label == "Mina" }?.selectedTurns, 1)

    let restoreLabel = speakerControl(alphaStamp, "D. Morgan")
    let restorePassage = try XCTUnwrap(self.claimButton(labeled: restoreLabel, in: host))
    XCTAssertTrue(restorePassage.isDescendant(of: host))
    restorePassage.performClick(nil)
    let sourceShown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return self.claimButton(labeled: "Use audio source label", in: host) != nil
    }
    XCTAssertTrue(sourceShown, self.hostedControlProbe(in: host))
    let source = try XCTUnwrap(self.claimButton(labeled: "Use audio source label", in: host))
    XCTAssertTrue(source.isEnabled && source.isDescendant(of: host))
    source.performClick(nil)
    await assertEventually {
      model.segments.first { $0.sequence == alpha.sequence }?.speakerLabel == "Unknown speaker"
        && model.segments.first { $0.sequence == alpha.sequence }?.namedSpeakerId == nil
        && model.segments.first { $0.sequence == bravo.sequence }?.speakerLabel == "Mina"
    }
    let restoredHistory = try XCTUnwrap(
      model.namedSpeakerTurnHistory.first { $0.sequence == alpha.sequence })
    XCTAssertEqual(restoredHistory.revisions.map(\.label), ["Dana", "Unknown speaker"])
    XCTAssertEqual(restoredHistory.revisions.map(\.origin), [.human, .sourceDefault])
    XCTAssertEqual(
      TranscriptLibraryModel.namedSpeakerTurnHistoryText(for: restoredHistory),
      """
      Source default: Unknown speaker
      Dana, named by you
      Unknown speaker, source name
      """)
    let bravoHistory = try XCTUnwrap(
      model.namedSpeakerTurnHistory.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(bravoHistory.revisions.map(\.label), ["Morgan", "Dana", "Mina"])

    let reread = try library.document(sessionId: receipt.sessionId)
    let rereadAlpha = try XCTUnwrap(reread.first { $0.sequence == alpha.sequence })
    let rereadBravo = try XCTUnwrap(reread.first { $0.sequence == bravo.sequence })
    XCTAssertEqual(rereadAlpha.speakerLabel, "Unknown speaker")
    XCTAssertEqual(rereadAlpha.effectiveText, alphaText)
    XCTAssertEqual(rereadAlpha.verbatimText, alpha.verbatimText)
    XCTAssertEqual(rereadBravo.speakerLabel, "Mina")
    XCTAssertEqual(rereadBravo.verbatimText, bravoVerbatim)
    XCTAssertEqual(rereadBravo.effectiveText, bravoText)
    XCTAssertTrue(rereadBravo.corrected)
    XCTAssertEqual(rereadBravo.startNanoseconds, bravo.startNanoseconds)
    XCTAssertEqual(rereadAlpha.startNanoseconds, alpha.startNanoseconds)
    let tracks = try library.speakers(sessionId: receipt.sessionId)
    XCTAssertEqual(tracks.map(\.label), ["Unknown speaker"])
    XCTAssertEqual(tracks.map(\.namedByUser), [false])
    XCTAssertEqual(
      model.speakerDiarizationText,
      "Speakers follow the audio source. Voice diarization is unavailable without a calibrated model."
    )
    XCTAssertNil(model.message)
    XCTAssertTrue(window.contentView === host)
    XCTAssertEqual(try digest(of: libraryMedia[0]), packageDigest)
    XCTAssertEqual(try digest(of: packageMedia[0]), packageDigest)
    withExtendedLifetime((store, live, playback, player, window, host, library)) {}
  }

  /// A stored final with a correction, one derived claim, and an in-session
  /// export states that scope before anything is removed. Cancel leaves it.
  /// Confirm moves the directory and drops the claim.
  func testDeletionStatesTheDerivedItemBeforeTrash() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-deletion-derived-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Stored.openscribe")
    let export = await exportStoredFinalPackage(to: package)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))

    let managed = root.appendingPathComponent("Library", isDirectory: true)
    let library = try NativeTranscriptLibrary.open(managedRoot: managed.path)
    let receipt = try library.importPortablePackage(packagePath: package.path)
    let segments = try library.document(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(segments.first { $0.sequence == 0 })
    let bravo = try XCTUnwrap(segments.first { $0.sequence == 1 })
    let supporting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: alpha.revisionId, sequence: alpha.sequence)
    let contradicting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: bravo.revisionId, sequence: bravo.sequence)
    try library.insertDerivedClaim(
      claimJson: citedClaimJSON(
        sessionId: receipt.sessionId, supporting: supporting, contradicting: contradicting))
    let sessionDirectory = managed.appendingPathComponent("Sessions", isDirectory: true)
      .appendingPathComponent(receipt.sessionId, isDirectory: true)
    let exports = sessionDirectory.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    let exportedNote = Data("exported".utf8)
    try exportedNote.write(to: exports.appendingPathComponent("notes.txt"))
    let media = try regularFiles(under: sessionDirectory).filter { $0.pathExtension == "caf" }
    XCTAssertEqual(media.count, 1)
    let mediaDigest = try digest(of: media[0])

    let trash = root.appendingPathComponent("Trash", isDirectory: true)
    let model = TranscriptLibraryModel(library: library) { directory in
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      let destination = trash.appendingPathComponent(directory.lastPathComponent)
      try FileManager.default.moveItem(at: directory, to: destination)
      return destination
    }
    await model.load(sessionId: receipt.sessionId)
    XCTAssertEqual(
      model.derivedClaims.first?.text, "The team agreed to ship the local recorder.")

    await model.requestDeletion(sessionId: receipt.sessionId)
    let inventory = try XCTUnwrap(model.pendingDeletion)
    XCTAssertEqual(inventory.derivedItems, 1)
    XCTAssertGreaterThan(inventory.transcriptRevisions, 0)
    XCTAssertGreaterThan(inventory.humanCorrections, 0)
    XCTAssertEqual(inventory.exportFiles, 1)
    XCTAssertEqual(inventory.exportBytes, 8)
    XCTAssertGreaterThan(inventory.mediaFiles, 0)
    let summary = SessionDeletionSummary.text(inventory)
    XCTAssertTrue(summary.contains("1 derived item"))
    XCTAssertTrue(summary.contains("correction"))
    XCTAssertTrue(summary.contains("file exported inside the conversation"))
    XCTAssertTrue(summary.contains("will be moved to Trash"))
    XCTAssertTrue(summary.contains("Files you exported elsewhere"))
    XCTAssertTrue(summary.contains("Time Machine or other backups"))
    XCTAssertTrue(summary.contains("does not restore the deleted review database"))
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)
    XCTAssertEqual(try Data(contentsOf: exports.appendingPathComponent("notes.txt")), exportedNote)

    await model.cancelDeletion()
    XCTAssertNil(model.pendingDeletion)
    await model.load(sessionId: receipt.sessionId)
    XCTAssertEqual(
      model.derivedClaims.first?.text, "The team agreed to ship the local recorder.")
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)

    await model.requestDeletion(sessionId: receipt.sessionId)
    XCTAssertEqual(model.pendingDeletion?.derivedItems, 1)
    let deleted = await model.confirmDeletion()
    XCTAssertTrue(deleted, model.message ?? "deletion did not finish")
    XCTAssertFalse(model.messageIsFailure, model.message ?? "deletion did not finish")
    XCTAssertTrue(model.message?.contains("was moved to Trash") == true)
    XCTAssertTrue(model.derivedClaims.isEmpty)
    let preparation = try NativeRecordingPreparation.open(managedRoot: managed.path)
    XCTAssertFalse(
      try preparation.runtimeLibrarySnapshot().savedSessions.contains {
        $0.sessionId == receipt.sessionId
      })
    XCTAssertFalse(FileManager.default.fileExists(atPath: media[0].path))
    let trashedMedia = try regularFiles(under: trash).filter { $0.pathExtension == "caf" }
    XCTAssertEqual(trashedMedia.count, 1)
    XCTAssertEqual(try digest(of: trashedMedia[0]), mediaDigest)
    let trashedNote = trash.appendingPathComponent(receipt.sessionId)
      .appendingPathComponent("exports").appendingPathComponent("notes.txt")
    XCTAssertEqual(try Data(contentsOf: trashedNote), exportedNote)
  }

  /// The hosted Trash button asks, and Cancel on that same banner leaves the
  /// conversation. The test does not call `requestDeletion`, `cancelDeletion`,
  /// or `confirmDeletion`.
  func testHostedDeletionCancelLeavesTheConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-hosted-delete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Stored.openscribe")
    let export = await exportStoredFinalPackage(to: package)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))

    let managed = root.appendingPathComponent("Library", isDirectory: true)
    let library = try NativeTranscriptLibrary.open(managedRoot: managed.path)
    let receipt = try library.importPortablePackage(packagePath: package.path)
    let segments = try library.document(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(segments.first { $0.sequence == 0 })
    let bravo = try XCTUnwrap(segments.first { $0.sequence == 1 })
    let supporting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: alpha.revisionId, sequence: alpha.sequence)
    let contradicting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: bravo.revisionId, sequence: bravo.sequence)
    try library.insertDerivedClaim(
      claimJson: citedClaimJSON(
        sessionId: receipt.sessionId, supporting: supporting, contradicting: contradicting))
    let sessionDirectory = managed.appendingPathComponent("Sessions", isDirectory: true)
      .appendingPathComponent(receipt.sessionId, isDirectory: true)
    let exports = sessionDirectory.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    let exportedNote = Data("exported".utf8)
    try exportedNote.write(to: exports.appendingPathComponent("notes.txt"))
    let media = try regularFiles(under: sessionDirectory).filter { $0.pathExtension == "caf" }
    XCTAssertEqual(media.count, 1)
    let mediaDigest = try digest(of: media[0])
    let bravoText = bravo.effectiveText

    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.load(sessionId: receipt.sessionId)
    XCTAssertEqual(
      model.derivedClaims.first?.text, "The team agreed to ship the local recorder.")
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(receipt.sessionId)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: RecoveredAudioPlayerFake())
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let offered = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.deletionButton(labeled: "Move the selected conversation to Trash", in: host) != nil
    }
    let request = self.deletionButton(labeled: "Move the selected conversation to Trash", in: host)
    XCTAssertTrue(
      offered && request != nil && window.contentView === host,
      self.deletionProbe(in: host).joined(separator: "\n"))
    let trash = try XCTUnwrap(request)
    XCTAssertTrue(trash.isDescendant(of: host))
    XCTAssertNil(model.pendingDeletion)
    trash.performClick(nil)

    let asked = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return model.pendingDeletion?.sessionId == receipt.sessionId
        && self.deletionButton(labeled: "Cancel deletion", in: host) != nil
        && self.deletionSummary(in: host) != nil
    }
    XCTAssertTrue(
      asked && window.contentView === host,
      "\(model.pendingDeletion?.sessionId ?? "nil")\n"
        + self.deletionProbe(in: host).joined(separator: "\n"))
    let inventory = try XCTUnwrap(model.pendingDeletion)
    let summary = try XCTUnwrap(self.deletionSummary(in: host))
    XCTAssertEqual(summary.stringValue, SessionDeletionSummary.text(inventory))
    XCTAssertTrue(summary.stringValue.contains("will be moved to Trash"))
    XCTAssertTrue(summary.stringValue.contains("1 derived item"))
    XCTAssertTrue(summary.stringValue.contains("correction"))
    XCTAssertTrue(summary.stringValue.contains("file exported inside the conversation"))
    XCTAssertTrue(summary.stringValue.contains("Files you exported elsewhere"))
    XCTAssertTrue(summary.stringValue.contains("Time Machine or other backups"))
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)
    XCTAssertTrue(store.savedSessions.contains { $0.sessionId == receipt.sessionId })
    let cancel = try XCTUnwrap(self.deletionButton(labeled: "Cancel deletion", in: host))
    XCTAssertTrue(cancel.isDescendant(of: host))
    cancel.performClick(nil)

    let cleared = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return model.pendingDeletion == nil
        && self.deletionButton(labeled: "Cancel deletion", in: host) == nil
        && self.deletionSummary(in: host) == nil
    }
    XCTAssertTrue(cleared && window.contentView === host, model.message ?? "nil")
    store.refresh()
    let stillListed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(stillListed)
    await model.load(sessionId: receipt.sessionId)
    XCTAssertEqual(
      model.derivedClaims.first?.text, "The team agreed to ship the local recorder.")
    let reread = try library.document(sessionId: receipt.sessionId)
    let rereadBravo = try XCTUnwrap(reread.first { $0.sequence == 1 })
    XCTAssertEqual(rereadBravo.effectiveText, bravoText)
    XCTAssertEqual(rereadBravo.corrected, bravo.corrected)
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)
    XCTAssertEqual(try Data(contentsOf: exports.appendingPathComponent("notes.txt")), exportedNote)
    XCTAssertTrue(FileManager.default.fileExists(atPath: media[0].path))
    XCTAssertNil(self.deletionButton(labeled: "Confirm move to Trash", in: host))
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime((store, live, playback, window, host, library, model)) {}
  }

  /// The same hosted banner's Move to Trash control removes the conversation.
  /// The test does not call `requestDeletion` or `confirmDeletion`. Trash is a
  /// directory in the test root, not the operator's Trash.
  func testHostedDeletionConfirmMovesTheConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-hosted-delete-confirm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Stored.openscribe")
    let export = await exportStoredFinalPackage(to: package)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))

    let managed = root.appendingPathComponent("Library", isDirectory: true)
    let library = try NativeTranscriptLibrary.open(managedRoot: managed.path)
    let receipt = try library.importPortablePackage(packagePath: package.path)
    let segments = try library.document(sessionId: receipt.sessionId)
    let alpha = try XCTUnwrap(segments.first { $0.sequence == 0 })
    let bravo = try XCTUnwrap(segments.first { $0.sequence == 1 })
    let supporting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: alpha.revisionId, sequence: alpha.sequence)
    let contradicting = try library.citeTranscriptSegment(
      sessionId: receipt.sessionId, revisionId: bravo.revisionId, sequence: bravo.sequence)
    try library.insertDerivedClaim(
      claimJson: citedClaimJSON(
        sessionId: receipt.sessionId, supporting: supporting, contradicting: contradicting))
    let sessionDirectory = managed.appendingPathComponent("Sessions", isDirectory: true)
      .appendingPathComponent(receipt.sessionId, isDirectory: true)
    let exports = sessionDirectory.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    let exportedNote = Data("exported".utf8)
    try exportedNote.write(to: exports.appendingPathComponent("notes.txt"))
    let media = try regularFiles(under: sessionDirectory).filter { $0.pathExtension == "caf" }
    XCTAssertEqual(media.count, 1)
    let mediaDigest = try digest(of: media[0])
    let mediaPath = media[0].path

    let trash = root.appendingPathComponent("Trash", isDirectory: true)
    let model = TranscriptLibraryModel(library: library) { directory in
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      let destination = trash.appendingPathComponent(directory.lastPathComponent)
      try FileManager.default.moveItem(at: directory, to: destination)
      return destination
    }
    await model.load(sessionId: receipt.sessionId)
    XCTAssertEqual(
      model.derivedClaims.first?.text, "The team agreed to ship the local recorder.")
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(receipt.sessionId)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: RecoveredAudioPlayerFake())
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let offered = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.deletionButton(labeled: "Move the selected conversation to Trash", in: host) != nil
    }
    let request = try XCTUnwrap(
      self.deletionButton(labeled: "Move the selected conversation to Trash", in: host))
    XCTAssertTrue(offered && request.isDescendant(of: host) && window.contentView === host)
    request.performClick(nil)
    let asked = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.deletionButton(labeled: "Confirm move to Trash", in: host) != nil
        && self.deletionSummary(in: host) != nil
    }
    let summary = try XCTUnwrap(self.deletionSummary(in: host))
    XCTAssertTrue(asked && window.contentView === host, summary.stringValue)
    XCTAssertEqual(summary.stringValue, SessionDeletionSummary.text(try XCTUnwrap(model.pendingDeletion)))
    XCTAssertTrue(summary.stringValue.contains("will be moved to Trash"))
    XCTAssertTrue(summary.stringValue.contains("1 derived item"))
    XCTAssertTrue(summary.stringValue.contains("correction"))
    XCTAssertEqual(try digest(of: URL(fileURLWithPath: mediaPath)), mediaDigest)
    let confirm = try XCTUnwrap(self.deletionButton(labeled: "Confirm move to Trash", in: host))
    XCTAssertTrue(confirm.isDescendant(of: host))
    confirm.performClick(nil)

    let removed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return model.pendingDeletion == nil
        && model.message?.contains("was moved to Trash") == true
        && self.deletionButton(labeled: "Confirm move to Trash", in: host) == nil
    }
    XCTAssertTrue(removed && window.contentView === host, model.message ?? "nil")
    XCTAssertFalse(model.messageIsFailure, model.message ?? "deletion did not finish")
    XCTAssertTrue(model.derivedClaims.isEmpty)
    store.refresh()
    let unlisted = await waitUntil {
      !store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(unlisted, "saved=\(store.savedSessions.map(\.sessionId))")
    XCTAssertFalse(FileManager.default.fileExists(atPath: mediaPath))
    let trashedMedia = try regularFiles(under: trash).filter { $0.pathExtension == "caf" }
    XCTAssertEqual(trashedMedia.count, 1)
    XCTAssertEqual(try digest(of: trashedMedia[0]), mediaDigest)
    let trashedNote = trash.appendingPathComponent(receipt.sessionId)
      .appendingPathComponent("exports").appendingPathComponent("notes.txt")
    XCTAssertEqual(try Data(contentsOf: trashedNote), exportedNote)
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime((store, live, playback, window, host, library, model)) {}
  }

  /// Confirm on the hosted banner uses `TranscriptLibraryModel.systemTrash`.
  /// The test does not call `requestDeletion`, `confirmDeletion`, or `systemTrash`.
  /// The moved directory is removed after its digest is checked. The Trash
  /// folder itself is not removed.
  func testHostedDeletionConfirmUsesSystemTrash() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-system-trash-host-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let package = root.appendingPathComponent("Stored.openscribe")
    let export = await exportStoredFinalPackage(to: package)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))

    let managed = root.appendingPathComponent("Library", isDirectory: true)
    let library = try NativeTranscriptLibrary.open(managedRoot: managed.path)
    let receipt = try library.importPortablePackage(packagePath: package.path)
    let sessionId = receipt.sessionId
    var trashedSession: URL?
    defer {
      if let trashedSession, self.isRemovableSystemTrashChild(trashedSession, sessionId: sessionId) {
        try? FileManager.default.removeItem(at: trashedSession)
      }
      try? FileManager.default.removeItem(at: root)
    }
    let segments = try library.document(sessionId: sessionId)
    let alpha = try XCTUnwrap(segments.first { $0.sequence == 0 })
    let bravo = try XCTUnwrap(segments.first { $0.sequence == 1 })
    let supporting = try library.citeTranscriptSegment(
      sessionId: sessionId, revisionId: alpha.revisionId, sequence: alpha.sequence)
    let contradicting = try library.citeTranscriptSegment(
      sessionId: sessionId, revisionId: bravo.revisionId, sequence: bravo.sequence)
    try library.insertDerivedClaim(
      claimJson: citedClaimJSON(
        sessionId: sessionId, supporting: supporting, contradicting: contradicting))
    let sessionDirectory = managed.appendingPathComponent("Sessions", isDirectory: true)
      .appendingPathComponent(sessionId, isDirectory: true)
    let exports = sessionDirectory.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    let exportedNote = Data("exported".utf8)
    try exportedNote.write(to: exports.appendingPathComponent("notes.txt"))
    let media = try regularFiles(under: sessionDirectory).filter { $0.pathExtension == "caf" }
    XCTAssertEqual(media.count, 1)
    let mediaDigest = try digest(of: media[0])
    let mediaPath = media[0].path

    let model = TranscriptLibraryModel(managedRoot: managed)
    await model.load(sessionId: sessionId)
    XCTAssertEqual(
      model.derivedClaims.first?.text, "The team agreed to ship the local recorder.")
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let navigation = MainWorkspaceNavigation()
    navigation.select(sessionId)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: RecoveredAudioPlayerFake())
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let offered = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.deletionButton(labeled: "Move the selected conversation to Trash", in: host) != nil
    }
    let request = try XCTUnwrap(
      self.deletionButton(labeled: "Move the selected conversation to Trash", in: host))
    XCTAssertTrue(offered && request.isDescendant(of: host) && window.contentView === host)
    request.performClick(nil)
    let asked = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.deletionButton(labeled: "Confirm move to Trash", in: host) != nil
    }
    XCTAssertTrue(asked && window.contentView === host, model.message ?? "nil")
    let summary = try XCTUnwrap(self.deletionSummary(in: host))
    XCTAssertTrue(summary.stringValue.contains("will be moved to Trash"))
    XCTAssertTrue(summary.stringValue.contains("audio stays in Trash"))
    XCTAssertEqual(try digest(of: URL(fileURLWithPath: mediaPath)), mediaDigest)
    let confirm = try XCTUnwrap(self.deletionButton(labeled: "Confirm move to Trash", in: host))
    XCTAssertTrue(confirm.isDescendant(of: host))
    confirm.performClick(nil)

    let removed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return model.pendingDeletion == nil
        && model.message?.contains("was moved to Trash") == true
        && model.messageIsFailure == false
    }
    XCTAssertTrue(removed && window.contentView === host, model.message ?? "nil")
    XCTAssertFalse(FileManager.default.fileExists(atPath: mediaPath))
    store.refresh()
    let unlisted = await waitUntil {
      !store.savedSessions.contains { $0.sessionId == sessionId }
    }
    XCTAssertTrue(unlisted, "saved=\(store.savedSessions.map(\.sessionId))")
    let moved = try XCTUnwrap(
      self.systemTrashChild(managedRoot: managed, sessionId: sessionId, mediaDigest: mediaDigest),
      "session \(sessionId) was not found from the deletion receipt")
    trashedSession = moved
    XCTAssertTrue(self.isRemovableSystemTrashChild(moved, sessionId: sessionId))
    XCTAssertFalse(moved.path.hasPrefix(root.path))
    let trashedMedia = try regularFiles(under: moved).filter { $0.pathExtension == "caf" }
    XCTAssertEqual(trashedMedia.count, 1)
    XCTAssertEqual(try digest(of: trashedMedia[0]), mediaDigest)
    let trashedNote = moved.appendingPathComponent("exports").appendingPathComponent("notes.txt")
    XCTAssertEqual(try Data(contentsOf: trashedNote), exportedNote)
    try FileManager.default.removeItem(at: moved)
    trashedSession = nil
    XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime((store, live, playback, window, host, library, model)) {}
  }

  /// The hosted title editor cancels without writing, then stores a new name.
  /// The test does not call `beginRename`, `cancelRename`, or `rename`.
  func testHostedRenameCancelLeavesTheTitleThenConfirmKeepsTheRecording() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-hosted-rename-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Stored.openscribe")
    let export = await exportStoredFinalPackage(to: package)
    XCTAssertEqual(export.status, 0, String(export.log.suffix(2_000)))

    let managed = root.appendingPathComponent("Library", isDirectory: true)
    let library = try NativeTranscriptLibrary.open(managedRoot: managed.path)
    let receipt = try library.importPortablePackage(packagePath: package.path)
    let segments = try library.document(sessionId: receipt.sessionId)
    let bravo = try XCTUnwrap(segments.first { $0.sequence == 1 })
    let bravoText = bravo.effectiveText
    let sessionDirectory = managed.appendingPathComponent("Sessions", isDirectory: true)
      .appendingPathComponent(receipt.sessionId, isDirectory: true)
    let media = try regularFiles(under: sessionDirectory).filter { $0.pathExtension == "caf" }
    XCTAssertEqual(media.count, 1)
    let mediaDigest = try digest(of: media[0])

    let model = TranscriptLibraryModel(managedRoot: managed)
    let store = RuntimeLibraryStore(managedRoot: managed, refreshesImmediately: false)
    store.refresh()
    let listed = await waitUntil {
      store.savedSessions.contains { $0.sessionId == receipt.sessionId }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let original = try XCTUnwrap(
      store.savedSessions.first { $0.sessionId == receipt.sessionId })
    let originalTitle = original.title
    let navigation = MainWorkspaceNavigation()
    navigation.select(receipt.sessionId)
    let live = LiveMicrophoneRecordingController(managedRoot: managed)
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managed.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: managed.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: RecoveredAudioPlayerFake())
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: { _, _ in throw NativeStorageError.InvalidRequest }
      ),
      liveRecording: live,
      recoveredSessions: playback,
      transcripts: model,
      speech: SpeechTranscriptionModel(managedRoot: managed),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: managed, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleClaimContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let offered = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.deletionButton(labeled: "Rename the selected conversation", in: host) != nil
    }
    let request = self.deletionButton(labeled: "Rename the selected conversation", in: host)
    XCTAssertTrue(
      offered && request != nil && window.contentView === host,
      self.deletionProbe(in: host).joined(separator: "\n"))
    let rename = try XCTUnwrap(request)
    XCTAssertTrue(rename.isDescendant(of: host))
    XCTAssertNil(store.pendingRename)
    rename.performClick(nil)

    let asked = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return store.pendingRename?.sessionId == receipt.sessionId
        && self.renameTitleField(in: host) != nil
        && self.deletionButton(labeled: "Cancel rename", in: host) != nil
    }
    XCTAssertTrue(asked && window.contentView === host, store.pendingRename?.sessionId ?? "nil")
    let field = try XCTUnwrap(self.renameTitleField(in: host))
    XCTAssertEqual(field.stringValue, ConversationIdentityPresentation.title(originalTitle))
    let summary = try XCTUnwrap(self.renameSummary(in: host))
    XCTAssertTrue(summary.stringValue.contains("recording and its transcript are unchanged"))
    self.replaceTitle("Cancelled name", in: field)
    let cancel = try XCTUnwrap(self.deletionButton(labeled: "Cancel rename", in: host))
    XCTAssertTrue(cancel.isDescendant(of: host))
    cancel.performClick(nil)

    let cleared = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return store.pendingRename == nil && self.renameTitleField(in: host) == nil
    }
    XCTAssertTrue(cleared && window.contentView === host)
    store.refresh()
    let unchanged = await waitUntil {
      store.savedSessions.contains {
        $0.sessionId == receipt.sessionId && $0.title == originalTitle
      }
    }
    XCTAssertTrue(unchanged, "saved=\(store.savedSessions.map { "\($0.sessionId) \($0.title)" })")
    let displayed = try XCTUnwrap(self.conversationName(in: host))
    XCTAssertEqual(displayed.stringValue, ConversationIdentityPresentation.title(originalTitle))

    let again = try XCTUnwrap(
      self.deletionButton(labeled: "Rename the selected conversation", in: host))
    again.performClick(nil)
    let reopened = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.renameTitleField(in: host) != nil
        && self.deletionButton(labeled: "Save conversation name", in: host) != nil
    }
    XCTAssertTrue(reopened && window.contentView === host)
    let editor = try XCTUnwrap(self.renameTitleField(in: host))
    self.replaceTitle("   ", in: editor)
    let blocked = try XCTUnwrap(self.deletionButton(labeled: "Save conversation name", in: host))
    XCTAssertFalse(blocked.isEnabled)
    let renamedTitle = "Local recorder notes"
    self.replaceTitle(renamedTitle, in: editor)
    XCTAssertTrue(blocked.isEnabled)
    blocked.performClick(nil)

    let saved = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return store.pendingRename == nil
        && self.renameTitleField(in: host) == nil
        && store.savedSessions.contains {
          $0.sessionId == receipt.sessionId && $0.title == renamedTitle
        }
    }
    XCTAssertTrue(
      saved && window.contentView === host,
      "pending=\(store.pendingRename?.sessionId ?? "nil") edit=\(store.editMessage ?? "nil") "
        + "saved=\(store.savedSessions.map { "\($0.sessionId) \($0.title)" })")
    let displayedName = try XCTUnwrap(self.conversationName(in: host))
    XCTAssertEqual(displayedName.stringValue, renamedTitle)
    XCTAssertTrue(displayedName.isDescendant(of: host))
    let reread = try library.document(sessionId: receipt.sessionId)
    let rereadBravo = try XCTUnwrap(reread.first { $0.sequence == 1 })
    XCTAssertEqual(rereadBravo.effectiveText, bravoText)
    XCTAssertEqual(rereadBravo.corrected, bravo.corrected)
    XCTAssertEqual(rereadBravo.revisionId, bravo.revisionId)
    XCTAssertEqual(try digest(of: media[0]), mediaDigest)
    XCTAssertEqual(
      store.savedSessions.first { $0.sessionId == receipt.sessionId }?.sessionId,
      receipt.sessionId)
    XCTAssertNil(self.renameTitleField(in: host))
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime((store, live, playback, window, host, library, model)) {}
  }

  private func replaceTitle(_ title: String, in field: NSTextField) {
    XCTAssertEqual(field.window?.makeFirstResponder(field), true)
    let editor = field.currentEditor() as? NSTextView
    XCTAssertNotNil(editor)
    editor?.string = title
    editor?.didChangeText()
  }

  private func renameTitleField(in root: NSView) -> NSTextField? {
    var matched: NSTextField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSTextField,
        field.accessibilityLabel() == "Conversation title",
        field.isEditable,
        field.isHidden == false,
        field.isHiddenOrHasHiddenAncestor == false,
        field.frame.width > 1,
        field.frame.height > 1
      {
        matched = field
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func renameSummary(in root: NSView) -> NSTextField? {
    var matched: NSTextField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSTextField,
        field.accessibilityLabel() == "Rename summary",
        field.isHidden == false,
        field.isHiddenOrHasHiddenAncestor == false,
        field.frame.width > 1,
        field.frame.height > 1
      {
        matched = field
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func conversationName(in root: NSView) -> NSTextField? {
    var matched: NSTextField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSTextField,
        field.accessibilityLabel() == "Conversation name",
        field.isEditable == false,
        field.isHidden == false,
        field.isHiddenOrHasHiddenAncestor == false,
        field.frame.width > 1,
        field.frame.height > 1
      {
        matched = field
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  /// The deletion receipt records the URL `systemTrash` returned. Listing the
  /// Trash directory is not permitted, so the test opens that stored URL.
  private func systemTrashChild(managedRoot: URL, sessionId: String, mediaDigest: String) -> URL? {
    let candidates = [
      storedTrashReference(managedRoot: managedRoot, sessionId: sessionId),
      URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent(".Trash", isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true),
    ]
    for candidate in candidates.compactMap({ $0 }) {
      let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
      guard isRemovableSystemTrashChild(resolved, sessionId: sessionId) else { continue }
      let media = (try? regularFiles(under: resolved))?.filter { $0.pathExtension == "caf" } ?? []
      guard media.count == 1, (try? digest(of: media[0])) == mediaDigest else { continue }
      return resolved
    }
    return nil
  }

  private func storedTrashReference(managedRoot: URL, sessionId: String) -> URL? {
    let database = managedRoot.appendingPathComponent("Library.sqlite3")
    guard FileManager.default.fileExists(atPath: database.path) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
      database.path,
      "SELECT ifnull(trash_reference,'') FROM deletion_receipts WHERE session_id = '\(sessionId)';",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard text.isEmpty == false else { return nil }
    if let url = URL(string: text), url.isFileURL { return url }
    return URL(fileURLWithPath: text)
  }

  private func isRemovableSystemTrashChild(_ url: URL, sessionId: String) -> Bool {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    let name = resolved.lastPathComponent
    guard name == sessionId || name.hasPrefix("\(sessionId) ") else { return false }
    guard name != ".Trash", name != "Trash" else { return false }
    guard resolved.deletingLastPathComponent().lastPathComponent == ".Trash" else { return false }
    return FileManager.default.fileExists(atPath: resolved.path)
  }

  private func deletionButton(labeled label: String, in root: NSView) -> NSButton? {
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton, !(button is NSPopUpButton),
        button.accessibilityLabel() == label,
        button.isHidden == false,
        button.isHiddenOrHasHiddenAncestor == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func deletionSummary(in root: NSView) -> NSTextField? {
    var matched: NSTextField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSTextField,
        field.accessibilityLabel() == "Deletion summary",
        field.isHidden == false,
        field.isHiddenOrHasHiddenAncestor == false,
        field.frame.width > 1,
        field.frame.height > 1
      {
        matched = field
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func deletionProbe(in root: NSView) -> [String] {
    var lines = [String]()
    func walk(_ view: NSView) {
      if let button = view as? NSButton, !(button is NSPopUpButton) {
        lines.append(
          "button \(button.accessibilityLabel() ?? button.title) hidden=\(button.isHidden) frame=\(button.frame)"
        )
      }
      if let field = view as? NSTextField, field.accessibilityLabel() == "Deletion summary" {
        lines.append("summary hidden=\(field.isHidden) frame=\(field.frame)")
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return lines
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

  private func exportMixedTranscriptLibrary(to managedRoot: URL) async -> (status: Int32, log: String) {
    let libraryPath = managedRoot.path
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
          "a_provisional_passage_stays_beside_a_final_and_a_correction", "--", "--exact",
          "transcript_library_tests::a_provisional_passage_stays_beside_a_final_and_a_correction",
        ]
        var environment = ProcessInfo.processInfo.environment
        let cargoBin = (cargo as NSString).deletingLastPathComponent
        let path = environment["PATH"] ?? ""
        if !path.split(separator: ":").contains(Substring(cargoBin)) {
          environment["PATH"] = "\(cargoBin):\(path)"
        }
        environment["OPEN_SCRIBE_MIXED_TRANSCRIPT_LIBRARY"] = libraryPath
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
