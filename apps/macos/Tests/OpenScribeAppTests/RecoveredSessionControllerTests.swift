import Foundation
import XCTest

@testable import OpenScribeApp

private final class RecoveryPreparationFake: NativeRecordingPreparation, @unchecked Sendable {
  var recovered: [NativeRecoveredPlayableSession] = []
  var recoveryError: Error?

  init() {
    super.init(noHandle: NoHandle())
  }

  required init(unsafeFromHandle handle: UInt64) {
    super.init(unsafeFromHandle: handle)
  }

  override func recoverPlayableSessions() throws -> [NativeRecoveredPlayableSession] {
    if let recoveryError {
      throw recoveryError
    }
    return recovered
  }
}

private final class RecoveredAudioPlayerFake: RecoveredAudioPlaying, @unchecked Sendable {
  private(set) var playedURL: URL?
  private(set) var stopCount = 0

  func play(url: URL) throws {
    playedURL = url
  }

  func stop() {
    stopCount += 1
  }
}

@MainActor
final class RecoveredSessionControllerTests: XCTestCase {
  func testRecoveredSessionBecomesAvailableAndOpensNativePlayback() {
    let preparation = RecoveryPreparationFake()
    let recovered = recoveredSession()
    preparation.recovered = [recovered]
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { preparation },
      player: player
    )

    controller.recoverOnLaunch()

    XCTAssertEqual(controller.phase, .available)
    XCTAssertEqual(controller.sessions.map(\.sessionId), [recovered.sessionId])
    controller.play(recovered)
    XCTAssertEqual(controller.playingSessionId, recovered.sessionId)
    XCTAssertEqual(player.playedURL?.path, recovered.absolutePath)

    controller.stopPlayback()
    XCTAssertNil(controller.playingSessionId)
    XCTAssertEqual(player.stopCount, 1)
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
    XCTAssertNil(player.playedURL)
    XCTAssertTrue(controller.errorMessage?.contains("Original files were not changed") == true)
  }

  private func recoveredSession(
    mediaPreserved: Bool = true
  ) -> NativeRecoveredPlayableSession {
    NativeRecoveredPlayableSession(
      sessionId: "session-recovered",
      segmentId: "segment-recovered",
      relativePath: "audio/track/segment.caf",
      absolutePath: "/tmp/recovered.caf",
      sampleCount: 48_000,
      durationNanoseconds: 1_000_000_000,
      byteLength: 100_000,
      digestSha256: String(repeating: "a", count: 64),
      mediaPreserved: mediaPreserved,
      readyForReview: true,
      recordingStarted: false,
      lastJournalSequence: 5
    )
  }
}
