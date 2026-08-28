@preconcurrency import AVFoundation
import Foundation

protocol PlayableSessionRecovering: AnyObject, Sendable {
  func recoverPlayableSessions() throws -> [NativeRecoveredPlayableSession]
}

extension NativeRecordingPreparation: PlayableSessionRecovering {}

protocol RecoveredAudioPlaying: AnyObject, Sendable {
  func play(url: URL) throws
  func stop()
}

final class RecoveredAudioPlayer: RecoveredAudioPlaying, @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var file: AVAudioFile?

  init() {
    engine.attach(player)
  }

  func play(url: URL) throws {
    player.stop()
    engine.stop()
    let file = try AVAudioFile(forReading: url)
    engine.disconnectNodeOutput(player)
    engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    player.scheduleFile(file, at: nil)
    try engine.start()
    player.play()
    self.file = file
  }

  func stop() {
    player.stop()
    engine.stop()
    file = nil
  }
}

enum RecoveredSessionPhase: Equatable, Sendable {
  case scanning
  case none
  case available
  case failed
}

private enum RecoveredSessionError: Error {
  case managedRootUnavailable
  case invalidEvidence
}

@MainActor
final class RecoveredSessionController: ObservableObject {
  typealias RecoveryFactory = @Sendable () throws -> PlayableSessionRecovering

  @Published private(set) var phase: RecoveredSessionPhase = .scanning
  @Published private(set) var sessions: [NativeRecoveredPlayableSession] = []
  @Published private(set) var playingSessionId: String?
  @Published private(set) var errorMessage: String?

  private let recoveryFactory: RecoveryFactory
  private let player: RecoveredAudioPlaying

  init(
    recoveryFactory: @escaping RecoveryFactory,
    player: RecoveredAudioPlaying
  ) {
    self.recoveryFactory = recoveryFactory
    self.player = player
  }

  convenience init(managedRoot: URL?) {
    self.init(
      recoveryFactory: {
        guard let managedRoot else {
          throw RecoveredSessionError.managedRootUnavailable
        }
        return try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
      },
      player: RecoveredAudioPlayer()
    )
  }

  func recoverOnLaunch() {
    phase = .scanning
    errorMessage = nil
    do {
      let recovered = try recoveryFactory().recoverPlayableSessions()
      guard
        recovered.allSatisfy({
          $0.mediaPreserved && $0.readyForReview && !$0.recordingStarted
            && $0.sampleCount > 0 && $0.byteLength > 0
        })
      else {
        throw RecoveredSessionError.invalidEvidence
      }
      sessions = recovered
      phase = recovered.isEmpty ? .none : .available
    } catch {
      sessions = []
      errorMessage =
        "Recovery could not confirm playable local media. Original files were not changed."
      phase = .failed
    }
  }

  func play(_ session: NativeRecoveredPlayableSession) {
    guard session.readyForReview, session.mediaPreserved, !session.recordingStarted else { return }
    do {
      try player.play(url: URL(fileURLWithPath: session.absolutePath, isDirectory: false))
      playingSessionId = session.sessionId
      errorMessage = nil
    } catch {
      playingSessionId = nil
      errorMessage = "Recovered audio could not be opened for playback."
    }
  }

  func stopPlayback() {
    player.stop()
    playingSessionId = nil
  }
}
