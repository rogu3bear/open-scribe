@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import OpenScribeApp

@MainActor
final class RecoveredSessionControllerTests: RecoveredSessionTestCase {
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

    XCTAssertEqual(controller.phase, .available)
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

  func testNoRecoveryCandidateRemainsQuietlyEmpty() {
    let preparation = RecoveryPreparationFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { preparation },
      player: RecoveredAudioPlayerFake()
    )

    controller.recoverOnLaunch()

    XCTAssertEqual(controller.phase, .none)
    XCTAssertTrue(controller.sessions.isEmpty)
    XCTAssertNil(controller.errorMessage)
  }

  func testUnconfirmedRecoveryNeverBecomesPlayable() {
    let preparation = RecoveryPreparationFake()
    preparation.recovered = [recoveredSession(mediaPreserved: false)]
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { preparation },
      player: player
    )

    controller.recoverOnLaunch()

    XCTAssertEqual(controller.phase, .failed)
    XCTAssertTrue(controller.sessions.isEmpty)
    XCTAssertNil(player.recoveredReceipt)
    XCTAssertTrue(controller.errorMessage?.contains("Original files were not changed") == true)
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
}
