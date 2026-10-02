@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Darwin
import Foundation

protocol PlayableSessionRecovering: AnyObject, Sendable {
  func recoverPlayableSessions() throws -> [NativeRecoveredPlayableSession]
}

extension NativeRecordingPreparation: PlayableSessionRecovering {}

protocol ImportedPlaybackLeaseHolding: AnyObject, Sendable {
  func playbackPath() -> String
}

extension NativeImportedPlaybackLease: ImportedPlaybackLeaseHolding {}

@MainActor
protocol RecoveredAudioPlaying: AnyObject {
  func playRecovered(receipt: String, retaining lease: AnyObject, generation: UUID) async throws
  /// `startNanoseconds` is a position in the imported media, from its start.
  func playImported(
    receipt: String, retaining lease: AnyObject, generation: UUID, startNanoseconds: Int64
  ) async throws
  func setPlaybackTerminationHandler(
    _ handler: @escaping @Sendable (PlaybackTermination) -> Void
  )
  func stop()
}

enum PlaybackTerminationOutcome: Equatable, Sendable {
  case finished
  case failed
  case outputRouteChanged
}

enum PlaybackOutputMode: Equatable, Sendable {
  case system
  /// Keeps lifecycle playback running without sending test audio to the system output.
  case silent
}

struct PlaybackTermination: Sendable {
  let generation: UUID
  let outcome: PlaybackTerminationOutcome
}

enum NativePlaybackLifecycleEvent: Equatable, Sendable {
  case importedCompletionReceived(UUID)
  case importedCompletionDelivered(UUID)
  case importedSessionDeactivated(UUID)
  case importedDecoderClosed(UUID)
  case anonymousRegionReleased(UUID)
  case recoveredSessionDeactivated(UUID)
  case recoveredDecoderClosed(UUID)
  case recoveredCompletionReceived(UUID)
  case recoveredCompletionDelivered(UUID)
  case playerStopped(UUID?)
  case engineStopped(UUID?)
  case outputConfigurationChanged(UUID)
}

private final class PlaybackGenerationCell: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UUID?

  func set(_ generation: UUID?) {
    lock.lock()
    self.generation = generation
    lock.unlock()
  }

  func snapshot() -> UUID? {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }
}

private final class PlaybackEngineConfigurationObserver: @unchecked Sendable {
  private let center: NotificationCenter
  private var token: NSObjectProtocol?

  init(
    center: NotificationCenter,
    engine: AVAudioEngine,
    handler: @escaping @Sendable () -> Void
  ) {
    self.center = center
    token = center.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { _ in
      handler()
    }
  }

  deinit {
    if let token {
      center.removeObserver(token)
    }
  }
}

final class NativePlaybackLifecycleHooks: @unchecked Sendable {
  static let production = NativePlaybackLifecycleHooks()

  private let observer: @Sendable (NativePlaybackLifecycleEvent) -> Void
  private let importedCompletionDelivery: @Sendable (@escaping @Sendable () -> Void) -> Void
  private let recoveredCompletionDelivery: @Sendable (@escaping @Sendable () -> Void) -> Void

  init(
    observer: @escaping @Sendable (NativePlaybackLifecycleEvent) -> Void = { _ in },
    importedCompletionDelivery:
      @escaping @Sendable (
        @escaping @Sendable () -> Void
      ) -> Void = { completion in completion() },
    recoveredCompletionDelivery:
      @escaping @Sendable (
        @escaping @Sendable () -> Void
      ) -> Void = { completion in completion() }
  ) {
    self.observer = observer
    self.importedCompletionDelivery = importedCompletionDelivery
    self.recoveredCompletionDelivery = recoveredCompletionDelivery
  }

  func observe(_ event: NativePlaybackLifecycleEvent) {
    observer(event)
  }

  func deliverImportedCompletion(_ completion: @escaping @Sendable () -> Void) {
    importedCompletionDelivery(completion)
  }

  func deliverRecoveredCompletion(_ completion: @escaping @Sendable () -> Void) {
    recoveredCompletionDelivery(completion)
  }
}

private enum CallbackPlaybackKind: Equatable, Sendable {
  case imported
  case recovered
}

private final class BoundedCallbackPlaybackSession: @unchecked Sendable {
  private static let framesPerBuffer: AVAudioFrameCount = 16_384
  private static let scheduledBufferLimit = 2

  let processingFormat: AVAudioFormat

  private let decoder: CallbackCAFDecoder
  private let kind: CallbackPlaybackKind
  private let generation: UUID
  private let lifecycle: NativePlaybackLifecycleHooks
  private let termination: @Sendable (PlaybackTermination) -> Void
  private let queue = DispatchQueue(label: "app.open-scribe.imported-playback")
  private var scheduledBuffers: [UUID: AVAudioPCMBuffer] = [:]
  private var reachedEnd = false
  private var active = true

  init(
    source: any CallbackAudioByteSource,
    fileTypeHint: AudioFileTypeID = kAudioFileCAFType,
    kind: CallbackPlaybackKind,
    generation: UUID,
    startNanoseconds: Int64 = 0,
    lifecycle: NativePlaybackLifecycleHooks,
    termination: @escaping @Sendable (PlaybackTermination) -> Void
  ) throws {
    self.generation = generation
    self.kind = kind
    self.lifecycle = lifecycle
    self.termination = termination
    decoder = try CallbackCAFDecoder(
      source: source,
      fileTypeHint: fileTypeHint,
      onClose: {
        lifecycle.observe(
          kind == .imported
            ? .importedDecoderClosed(generation)
            : .recoveredDecoderClosed(generation)
        )
      }
    )
    processingFormat = decoder.processingFormat
    if startNanoseconds > 0 {
      // Frames at the decoded rate, which is the imported file's own rate.
      let frame = Double(startNanoseconds) / 1_000_000_000 * processingFormat.sampleRate
      try decoder.seek(toFrame: Int64(frame.rounded(.down)))
    }
  }

  func prime(player: AVAudioPlayerNode) throws {
    try queue.sync {
      var scheduled = 0
      while scheduled < Self.scheduledBufferLimit, try scheduleNext(on: player) {
        scheduled += 1
      }
      guard scheduled > 0 else {
        throw ImportedPlaybackError.unsupportedAudioFormat(.emptyPrime)
      }
    }
  }

  func stop() {
    queue.sync {
      active = false
      lifecycle.observe(
        kind == .imported
          ? .importedSessionDeactivated(generation)
          : .recoveredSessionDeactivated(generation)
      )
      scheduledBuffers.removeAll()
      decoder.close()
    }
  }

  private func scheduleNext(on player: AVAudioPlayerNode) throws -> Bool {
    guard active, !reachedEnd else { return false }
    guard let buffer = try decoder.read(maximumFrames: Self.framesPerBuffer) else {
      reachedEnd = true
      return false
    }
    let identifier = UUID()
    scheduledBuffers[identifier] = buffer
    let generation = generation
    let lifecycle = lifecycle
    let playbackKind = kind
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
      [weak self, weak player] _ in
      lifecycle.observe(
        playbackKind == .imported
          ? .importedCompletionReceived(generation)
          : .recoveredCompletionReceived(generation)
      )
      let delivery: @Sendable () -> Void = { [weak self, weak player] in
        lifecycle.observe(
          playbackKind == .imported
            ? .importedCompletionDelivered(generation)
            : .recoveredCompletionDelivered(generation)
        )
        guard let self, let player else { return }
        self.queue.async {
          self.bufferFinished(identifier, player: player)
        }
      }
      if playbackKind == .imported {
        lifecycle.deliverImportedCompletion(delivery)
      } else {
        lifecycle.deliverRecoveredCompletion(delivery)
      }
    }
    return true
  }

  private func bufferFinished(_ identifier: UUID, player: AVAudioPlayerNode) {
    scheduledBuffers.removeValue(forKey: identifier)
    guard active else { return }
    do {
      _ = try scheduleNext(on: player)
      if reachedEnd, scheduledBuffers.isEmpty {
        active = false
        decoder.close()
        termination(
          PlaybackTermination(generation: generation, outcome: .finished)
        )
      }
    } catch {
      active = false
      scheduledBuffers.removeAll()
      decoder.close()
      termination(
        PlaybackTermination(generation: generation, outcome: .failed)
      )
    }
  }
}

enum PlaybackTeardownOrder {
  static func release(
    deactivateAndDrainImportedPlayback: () -> Void,
    stopPlayer: () -> Void,
    stopEngine: () -> Void
  ) {
    deactivateAndDrainImportedPlayback()
    stopPlayer()
    stopEngine()
  }
}

enum StructuredImportedPlaybackCopy {
  static func run<Result: Sendable>(
    operation:
      @escaping @Sendable (
        _ isCancelled: @escaping @Sendable () -> Bool
      ) throws -> Result
  ) async throws -> Result {
    try await withThrowingTaskGroup(of: Result.self) { group in
      group.addTask(priority: .userInitiated) {
        try operation { Task.isCancelled }
      }
      guard let result = try await group.next() else {
        throw CancellationError()
      }
      return result
    }
  }
}

@MainActor
final class RecoveredAudioPlayer: RecoveredAudioPlaying {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var callbackPlayback: BoundedCallbackPlaybackSession?
  private var playbackLease: AnyObject?
  private var activeGeneration: UUID?
  private var terminationHandler: (@Sendable (PlaybackTermination) -> Void)?
  private let lifecycle: NativePlaybackLifecycleHooks
  private let notificationCenter: NotificationCenter
  private let outputMode: PlaybackOutputMode
  private let generationCell = PlaybackGenerationCell()
  private var configurationObserver: PlaybackEngineConfigurationObserver?

  init(
    lifecycle: NativePlaybackLifecycleHooks = .production,
    outputMode: PlaybackOutputMode = .system,
    notificationCenter: NotificationCenter = .default
  ) {
    self.lifecycle = lifecycle
    self.notificationCenter = notificationCenter
    self.outputMode = outputMode
  }

  func playRecovered(
    receipt serializedReceipt: String,
    retaining lease: AnyObject,
    generation: UUID
  ) async throws {
    try Task.checkCancellation()
    releasePlaybackResources()
    activeGeneration = generation
    generationCell.set(generation)
    do {
      let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: serializedReceipt)
      let source = try await StructuredImportedPlaybackCopy.run { isCancelled in
        try VerifiedDescriptorPlaybackSource.prepare(
          receipt: receipt,
          isCancelled: isCancelled
        )
      }
      try Task.checkCancellation()
      guard activeGeneration == generation else { throw CancellationError() }
      try beginCallbackPlayback(
        source: source,
        kind: .recovered,
        retaining: lease,
        generation: generation
      )
    } catch {
      releasePlaybackResources(generation: generation)
      throw error
    }
  }

  func playImported(
    receipt serializedReceipt: String,
    retaining lease: AnyObject,
    generation: UUID,
    startNanoseconds: Int64
  ) async throws {
    try Task.checkCancellation()
    releasePlaybackResources()
    activeGeneration = generation
    generationCell.set(generation)
    do {
      if serializedReceipt.hasPrefix("v3;") {
        let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: serializedReceipt)
        let source = try await StructuredImportedPlaybackCopy.run { isCancelled in
          try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt, isCancelled: isCancelled)
        }
        try Task.checkCancellation()
        guard activeGeneration == generation else { throw CancellationError() }
        try beginCallbackPlayback(
          source: source, fileTypeHint: receipt.fileTypeHint, kind: .imported,
          retaining: lease, generation: generation, startNanoseconds: startNanoseconds
        )
        return
      }
      let receipt = try ImportedPlaybackDescriptorReceipt(serialized: serializedReceipt)
      try ImportedPlaybackMemoryPolicy.validate(receipt)
      let lifecycle = lifecycle
      let snapshot = try await StructuredImportedPlaybackCopy.run { isCancelled in
        try AnonymousImportedPlaybackSnapshot.copy(
          from: receipt,
          isCancelled: isCancelled,
          onRegionRelease: {
            lifecycle.observe(.anonymousRegionReleased(generation))
          }
        )
      }
      try Task.checkCancellation()
      guard activeGeneration == generation else { throw CancellationError() }
      try beginCallbackPlayback(
        source: snapshot.region,
        kind: .imported,
        retaining: lease,
        generation: generation,
        startNanoseconds: startNanoseconds
      )
    } catch {
      releasePlaybackResources(generation: generation)
      throw error
    }
  }

  func setPlaybackTerminationHandler(
    _ handler: @escaping @Sendable (PlaybackTermination) -> Void
  ) {
    terminationHandler = handler
  }

  func stop() {
    releasePlaybackResources()
  }

  func handleOutputConfigurationChange(generation: UUID? = nil) {
    guard let generation = generation ?? generationCell.snapshot(), activeGeneration == generation
    else { return }
    lifecycle.observe(.outputConfigurationChanged(generation))
    releasePlaybackResources(generation: generation)
    terminationHandler?(
      PlaybackTermination(generation: generation, outcome: .outputRouteChanged)
    )
  }

  private func beginCallbackPlayback(
    source: any CallbackAudioByteSource,
    fileTypeHint: AudioFileTypeID = kAudioFileCAFType,
    kind: CallbackPlaybackKind,
    retaining lease: AnyObject,
    generation: UUID,
    startNanoseconds: Int64 = 0
  ) throws {
    let playback = try BoundedCallbackPlaybackSession(
      source: source,
      fileTypeHint: fileTypeHint,
      kind: kind,
      generation: generation,
      startNanoseconds: startNanoseconds,
      lifecycle: lifecycle,
      termination: { [weak self] termination in
        Task { @MainActor [weak self] in
          guard let self, self.activeGeneration == termination.generation else { return }
          self.releasePlaybackResources(generation: termination.generation)
          self.terminationHandler?(termination)
        }
      }
    )
    let (engine, player) = prepareEngineIfNeeded()
    engine.disconnectNodeOutput(player)
    engine.connect(player, to: engine.mainMixerNode, format: playback.processingFormat)
    if outputMode == .silent {
      player.volume = 0
      engine.mainMixerNode.outputVolume = 0
    }
    try playback.prime(player: player)
    try engine.start()
    player.play()
    callbackPlayback = playback
    playbackLease = lease
  }

  private func prepareEngineIfNeeded() -> (engine: AVAudioEngine, player: AVAudioPlayerNode) {
    if let engine, let player {
      return (engine, player)
    }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    self.engine = engine
    self.player = player
    let generationCell = generationCell
    configurationObserver = PlaybackEngineConfigurationObserver(
      center: notificationCenter,
      engine: engine
    ) { [weak self] in
      guard let generation = generationCell.snapshot() else { return }
      Task { @MainActor [weak self] in
        self?.handleOutputConfigurationChange(generation: generation)
      }
    }
    return (engine, player)
  }

  private func releasePlaybackResources(generation: UUID? = nil) {
    if let generation, activeGeneration != generation { return }
    let releasingGeneration = activeGeneration
    activeGeneration = nil
    generationCell.set(nil)
    let playback = callbackPlayback
    callbackPlayback = nil
    let engine = self.engine
    let player = self.player
    PlaybackTeardownOrder.release(
      deactivateAndDrainImportedPlayback: { playback?.stop() },
      stopPlayer: {
        player?.stop()
        lifecycle.observe(.playerStopped(releasingGeneration))
      },
      stopEngine: {
        engine?.stop()
        lifecycle.observe(.engineStopped(releasingGeneration))
      }
    )
    playbackLease = nil
    configurationObserver = nil
    self.player = nil
    self.engine = nil
  }
}

extension RecoveredAudioPlaying {
  func playImported(receipt: String, retaining lease: AnyObject, generation: UUID) async throws {
    try await playImported(
      receipt: receipt, retaining: lease, generation: generation, startNanoseconds: 0)
  }
}
