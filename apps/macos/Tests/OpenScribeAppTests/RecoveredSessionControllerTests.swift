@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Darwin
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

@MainActor
private final class RecoveredAudioPlayerFake: RecoveredAudioPlaying {
  private(set) var recoveredReceipt: String?
  private(set) var importedReceipt: String?
  private(set) var retainedLease: AnyObject?
  private(set) var importedGeneration: UUID?
  private(set) var stopCount = 0
  var playError: Error?
  var holdRecoveredPlayback = false
  var holdImportedPlayback = false
  private var recoveredContinuation: CheckedContinuation<Void, Never>?
  private var importedContinuation: CheckedContinuation<Void, Never>?
  private var terminationHandler: (@Sendable (PlaybackTermination) -> Void)?

  func playRecovered(
    receipt: String,
    retaining lease: AnyObject,
    generation: UUID
  ) async throws {
    if let playError { throw playError }
    recoveredReceipt = receipt
    retainedLease = lease
    importedGeneration = generation
    if holdRecoveredPlayback {
      await withCheckedContinuation { continuation in
        recoveredContinuation = continuation
      }
    }
  }

  func playImported(
    receipt: String,
    retaining lease: AnyObject,
    generation: UUID
  ) async throws {
    if let playError { throw playError }
    importedReceipt = receipt
    retainedLease = lease
    importedGeneration = generation
    if holdImportedPlayback {
      await withCheckedContinuation { continuation in
        importedContinuation = continuation
      }
    }
  }

  func releaseImportedPlayback() {
    importedContinuation?.resume()
    importedContinuation = nil
  }

  func releaseRecoveredPlayback() {
    recoveredContinuation?.resume()
    recoveredContinuation = nil
  }

  func setPlaybackTerminationHandler(
    _ handler: @escaping @Sendable (PlaybackTermination) -> Void
  ) {
    terminationHandler = handler
  }

  func terminate(
    generation: UUID,
    outcome: PlaybackTerminationOutcome
  ) {
    guard importedGeneration == generation else { return }
    let handler = terminationHandler
    stop()
    handler?(PlaybackTermination(generation: generation, outcome: outcome))
  }

  func deliverTermination(
    generation: UUID,
    outcome: PlaybackTerminationOutcome
  ) {
    terminationHandler?(PlaybackTermination(generation: generation, outcome: outcome))
  }

  func stop() {
    stopCount += 1
    recoveredReceipt = nil
    importedReceipt = nil
    importedGeneration = nil
    retainedLease = nil
  }
}

private func recoveredDescriptorReceipt(
  fileDescriptor: Int32 = 44,
  byteLength: UInt64 = 100_000,
  digest: String = String(repeating: "a", count: 64)
) -> String {
  "v2;fd=\(fileDescriptor);byte_length=\(byteLength);sha256=\(digest);chunk_byte_length=65536"
}

private final class ImportedPlaybackLeaseFake: ImportedPlaybackLeaseHolding, @unchecked Sendable {
  let path: String

  init(path: String) {
    self.path = path
  }

  func playbackPath() -> String { path }
}

private final class ReleasingPlaybackLeaseProbe: ImportedPlaybackLeaseHolding, @unchecked Sendable {
  private let path: String
  private let released: SendableFlag

  init(path: String, released: SendableFlag) {
    self.path = path
    self.released = released
  }

  func playbackPath() -> String { path }

  deinit {
    released.set()
  }
}

private final class BlockingRecoveredPlaybackLeaseProvider: @unchecked Sendable {
  private let blockedSessionId: String
  private let entered = SendableFlag()
  private let semaphore = DispatchSemaphore(value: 0)
  private let makeLease: @Sendable (RecoveredPlaybackMediaIdentity) -> ImportedPlaybackLeaseHolding

  init(
    blockedSessionId: String,
    makeLease: @escaping @Sendable (RecoveredPlaybackMediaIdentity) -> ImportedPlaybackLeaseHolding
  ) {
    self.blockedSessionId = blockedSessionId
    self.makeLease = makeLease
  }

  var hasEntered: Bool { entered.value }

  func lease(identity: RecoveredPlaybackMediaIdentity) throws -> ImportedPlaybackLeaseHolding {
    if identity.sessionId == blockedSessionId {
      entered.set()
      semaphore.wait()
    }
    return makeLease(identity)
  }

  func release() {
    semaphore.signal()
  }
}

private final class SendableFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false

  var value: Bool {
    lock.withLock { storage }
  }

  func set() {
    lock.withLock { storage = true }
  }
}

private final class DescriptorBytesFake: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data
  private var identity: PlaybackDescriptorIdentity

  init(bytes: Data, device: UInt64 = 7, inode: UInt64 = 11) {
    self.bytes = bytes
    identity = PlaybackDescriptorIdentity(
      device: device,
      inode: inode,
      byteLength: UInt64(bytes.count)
    )
  }

  func inspect(_: Int32) throws -> PlaybackDescriptorIdentity {
    lock.withLock { identity }
  }

  func read(
    _: Int32,
    offset: UInt64,
    buffer: UnsafeMutableRawBufferPointer
  ) throws -> Int {
    lock.withLock {
      let start = Int(offset)
      guard start < bytes.count else { return 0 }
      let count = min(buffer.count, bytes.count - start)
      bytes.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: start..<(start + count))
      return count
    }
  }

  func mutateByte(at offset: Int) {
    lock.withLock { bytes[offset] ^= 0xff }
  }

  func replaceIdentity(device: UInt64, inode: UInt64, byteLength: UInt64) {
    lock.withLock {
      identity = PlaybackDescriptorIdentity(
        device: device,
        inode: inode,
        byteLength: byteLength
      )
    }
  }
}

private final class DescriptorPlaybackLeaseProbe: ImportedPlaybackLeaseHolding,
  @unchecked Sendable
{
  let fileDescriptor: Int32

  private let byteLength: Int
  private let digestSha256: String
  private let released: SendableFlag
  private let recovered: Bool

  init(url: URL, released: SendableFlag, recovered: Bool = false) throws {
    let bytes = try Data(contentsOf: url)
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    fileDescriptor = descriptor
    byteLength = bytes.count
    digestSha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    self.released = released
    self.recovered = recovered
  }

  func playbackPath() -> String {
    recovered
      ? "v2;fd=\(fileDescriptor);byte_length=\(byteLength);sha256=\(digestSha256);chunk_byte_length=65536"
      : "v1;fd=\(fileDescriptor);byte_length=\(byteLength);sha256=\(digestSha256);max_byte_length=268435456"
  }

  deinit {
    _ = close(fileDescriptor)
    released.set()
  }
}

private final class PlaybackLifetimeProbe: @unchecked Sendable {
  private let released: SendableFlag

  init(released: SendableFlag) {
    self.released = released
  }

  deinit {
    released.set()
  }
}

private final class PlaybackTerminationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [PlaybackTermination] = []

  func record(_ termination: PlaybackTermination) {
    lock.withLock { storage.append(termination) }
  }

  func contains(generation: UUID) -> Bool {
    lock.withLock { storage.contains { $0.generation == generation } }
  }

  func finished(generation: UUID) -> Bool {
    lock.withLock {
      storage.contains {
        guard $0.generation == generation else { return false }
        if case .finished = $0.outcome { return true }
        return false
      }
    }
  }

  func contains(generation: UUID, outcome: PlaybackTerminationOutcome) -> Bool {
    lock.withLock {
      storage.contains { $0.generation == generation && $0.outcome == outcome }
    }
  }
}

private final class PlaybackTerminationDecisionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [UUID: Bool] = [:]

  func record(generation: UUID, isActive: Bool) {
    lock.withLock { storage[generation] = isActive }
  }

  func decision(for generation: UUID) -> Bool? {
    lock.withLock { storage[generation] }
  }
}

private final class NativePlaybackLifecycleRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [NativePlaybackLifecycleEvent] = []

  func record(_ event: NativePlaybackLifecycleEvent) {
    lock.withLock { storage.append(event) }
  }

  func contains(_ event: NativePlaybackLifecycleEvent) -> Bool {
    lock.withLock { storage.contains(event) }
  }

  func occursInOrder(_ expected: [NativePlaybackLifecycleEvent]) -> Bool {
    lock.withLock {
      var searchStart = storage.startIndex
      for event in expected {
        guard let match = storage[searchStart...].firstIndex(of: event) else { return false }
        searchStart = storage.index(after: match)
      }
      return true
    }
  }
}

private final class NativePlaybackCompletionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var heldCompletion: (@Sendable () -> Void)?
  private var heldOnce = false

  var isHoldingCompletion: Bool {
    lock.withLock { heldCompletion != nil }
  }

  func deliver(_ completion: @escaping @Sendable () -> Void) {
    let runImmediately: (@Sendable () -> Void)? = lock.withLock {
      if heldOnce { return completion }
      heldOnce = true
      heldCompletion = completion
      return nil
    }
    runImmediately?()
  }

  func release() {
    let completion: (@Sendable () -> Void)? = lock.withLock {
      defer { heldCompletion = nil }
      return heldCompletion
    }
    completion?()
  }
}

private final class SnapshotReadGate: @unchecked Sendable {
  private let entered = SendableFlag()
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var firstRead = true

  var hasEntered: Bool { entered.value }

  func read(
    offset _: UInt64,
    buffer: UnsafeMutableRawBufferPointer
  ) -> Int {
    let shouldBlock = lock.withLock {
      defer { firstRead = false }
      return firstRead
    }
    if shouldBlock {
      entered.set()
      semaphore.wait()
    }
    buffer.initializeMemory(as: UInt8.self, repeating: 0)
    return buffer.count
  }

  func release() {
    semaphore.signal()
  }
}

private final class ImportedPlaybackLeaseSelection: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: ImportedPlaybackLeaseHolding

  init(_ lease: ImportedPlaybackLeaseHolding) {
    storage = lease
  }

  var lease: ImportedPlaybackLeaseHolding {
    lock.withLock { storage }
  }

  func select(_ lease: ImportedPlaybackLeaseHolding) {
    lock.withLock { storage = lease }
  }
}

@MainActor
final class RecoveredSessionControllerTests: XCTestCase {
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

  func testImportedTeardownDrainsSchedulingBeforeFinalPlayerStop() {
    var importedSchedulingActive = true
    var staleBufferScheduled = false
    var events: [String] = []

    PlaybackTeardownOrder.release(
      deactivateAndDrainImportedPlayback: {
        events.append("imported-inactive")
        importedSchedulingActive = false
      },
      stopPlayer: {
        events.append("player-stop-completion")
        if importedSchedulingActive {
          staleBufferScheduled = true
        }
      },
      stopEngine: { events.append("engine-stop") }
    )

    XCTAssertEqual(events, ["imported-inactive", "player-stop-completion", "engine-stop"])
    XCTAssertFalse(staleBufferScheduled)
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

  func testAvailableImportedSessionUsesTheExistingNativeAudioPlayer() async {
    let player = RecoveredAudioPlayerFake()
    let lease = ImportedPlaybackLeaseFake(path: descriptorReceipt())
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in lease },
      player: player
    )
    let imported = savedSession(availability: "available", absolutePath: "/tmp/imported.caf")

    controller.play(imported)
    await assertEventually { controller.playingSessionId == imported.sessionId }

    XCTAssertEqual(controller.playingSessionId, imported.sessionId)
    XCTAssertEqual(controller.activePlaybackSessionId, imported.sessionId)
    XCTAssertEqual(player.importedReceipt, descriptorReceipt())
    XCTAssertNil(player.recoveredReceipt)
    XCTAssertTrue(player.retainedLease === lease)
    XCTAssertNil(controller.errorMessage)
  }

  func testPendingImportedPlaybackIsSelectionBoundAndCannotStartAfterDetachment() async {
    let player = RecoveredAudioPlayerFake()
    player.holdImportedPlayback = true
    let pendingLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 42))
    let replacementLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 43))
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { sessionId in
        sessionId == "pending-import" ? pendingLease : replacementLease
      },
      player: player
    )
    let imported = savedSession(
      sessionId: "pending-import",
      availability: "available",
      absolutePath: "/tmp/pending.caf"
    )

    controller.play(imported)
    await assertEventually { player.importedReceipt != nil }

    XCTAssertEqual(controller.activePlaybackSessionId, imported.sessionId)
    XCTAssertNil(controller.playingSessionId)
    XCTAssertTrue(
      MainWorkspaceSelection.shouldStopDetachedPlayback(
        activePlaybackSessionId: controller.activePlaybackSessionId,
        selectedSessionId: "another-conversation"
      )
    )

    controller.stopPlayback()
    player.holdImportedPlayback = false
    let replacement = savedSession(
      sessionId: "replacement-import",
      availability: "available",
      absolutePath: "/tmp/replacement.caf"
    )
    controller.play(replacement)
    await assertEventually { controller.playingSessionId == replacement.sessionId }
    player.releaseImportedPlayback()
    await assertEventually { player.retainedLease === replacementLease }

    XCTAssertEqual(controller.activePlaybackSessionId, replacement.sessionId)
    XCTAssertEqual(controller.playingSessionId, replacement.sessionId)
    XCTAssertTrue(player.retainedLease === replacementLease)
  }

  func testStructuredImportedCopyCancellationAfterReadReturnsReleasesRegionAndLease() async throws {
    let bytes = Data(repeating: 0, count: 128 * 1024)
    let receipt = try ImportedPlaybackDescriptorReceipt(
      serialized: descriptorReceipt(bytes: bytes)
    )
    let readGate = SnapshotReadGate()
    let cancellationObserved = SendableFlag()
    let regionReleased = SendableFlag()
    let leaseReleased = SendableFlag()
    let finished = SendableFlag()
    let copy = Task<Void, Error> {
      defer { finished.set() }
      let lease = PlaybackLifetimeProbe(released: leaseReleased)
      let snapshot = try await StructuredImportedPlaybackCopy.run { isCancelled in
        try AnonymousImportedPlaybackSnapshot.copy(
          from: receipt,
          isCancelled: {
            let cancelled = isCancelled()
            if cancelled { cancellationObserved.set() }
            return cancelled
          },
          onRegionRelease: regionReleased.set,
          readAt: readGate.read
        )
      }
      try Task.checkCancellation()
      try withExtendedLifetime((snapshot, lease)) {
        if Task.isCancelled {
          throw CancellationError()
        }
      }
    }

    await assertEventually { readGate.hasEntered }
    copy.cancel()
    readGate.release()

    let completed = await waitUntil {
      finished.value && regionReleased.value && leaseReleased.value
    }
    XCTAssertTrue(completed)
    guard completed else { return }
    XCTAssertTrue(cancellationObserved.value)
    XCTAssertTrue(regionReleased.value)
    XCTAssertTrue(leaseReleased.value)
    do {
      try await copy.value
      XCTFail("cancelled snapshot copy unexpectedly completed")
    } catch is CancellationError {
      // Expected after the structured child observes cancellation.
    } catch {
      XCTFail("unexpected snapshot copy error: \(error)")
    }
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

  func testUnavailableAndCorruptCapturedSessionsUseNeutralSavedAudioMessaging() {
    for availability in ["unavailable", "corrupt"] {
      let player = RecoveredAudioPlayerFake()
      let leaseRequested = SendableFlag()
      let controller = RecoveredSessionController(
        recoveryFactory: { RecoveryPreparationFake() },
        importedPlaybackLeaseProvider: { _ in
          leaseRequested.set()
          return ImportedPlaybackLeaseFake(path: descriptorReceipt())
        },
        player: player
      )

      let captured = savedSession(sessionId: "session-captured", availability: availability, absolutePath: nil, sourceDisplayName: "Mac microphone")
      controller.play(captured)

      XCTAssertNil(controller.playingSessionId)
      XCTAssertNil(controller.activePlaybackSessionId)
      XCTAssertNil(player.recoveredReceipt)
      XCTAssertEqual(player.stopCount, 1)
      XCTAssertFalse(leaseRequested.value)
      XCTAssertEqual(controller.errorMessage, availability == "corrupt" ? "Saved audio appears corrupt and was not opened." : "Saved audio is unavailable and was not opened.")
      XCTAssertEqual(controller.errorSessionId, captured.sessionId)
    }
  }

  func testCapturedPlaybackOpenFailureUsesNeutralSavedAudioMessaging() {
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in throw CocoaError(.fileReadCorruptFile) },
      player: player
    )

    controller.play(savedSession(sessionId: "session-captured", availability: "available", absolutePath: nil, sourceDisplayName: "Mac microphone"))

    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.recoveredReceipt)
    XCTAssertEqual(player.stopCount, 1)
    XCTAssertEqual(controller.errorMessage, "Saved audio could not be opened for playback.")
    XCTAssertEqual(controller.errorSessionId, "session-captured")
  }

  func testFailedImportedReplacementReleasesThePriorLeaseAndPlayingState() async {
    let player = RecoveredAudioPlayerFake()
    let firstLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 42))
    let replacementLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 43))
    let selectedLease = ImportedPlaybackLeaseSelection(firstLease)
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in selectedLease.lease },
      player: player
    )
    let first = savedSession(availability: "available", absolutePath: "/tmp/first.caf")
    controller.play(first)
    await assertEventually { controller.playingSessionId == first.sessionId }
    XCTAssertTrue(player.retainedLease === firstLease)

    selectedLease.select(replacementLease)
    player.playError = CocoaError(.fileReadCorruptFile)
    let replacement = RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "session-replacement",
        title: "Replacement",
        lifecycle: "ready_for_review",
        health: "healthy",
        elapsedSeconds: 2,
        journalDurable: true,
        mediaFilesOpen: false,
        interruptionReason: nil,
        recovered: false,
        sources: [],
        playableMedia: NativeRuntimePlayableMediaSnapshot(
          sourceDisplayName: "replacement.caf",
          availability: "available",
          absolutePath: "/tmp/replacement.caf",
          durationNanoseconds: 2_000_000_000,
          sampleCount: 96_000,
          byteLength: 192_068
        )
      )
    )

    controller.play(replacement)
    await assertEventually { controller.errorMessage != nil }

    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.recoveredReceipt)
    XCTAssertNil(player.retainedLease)
    XCTAssertEqual(controller.errorMessage, "Saved audio could not be opened for playback.")
  }

  func testAnonymousSnapshotAcceptsOnlyTheCompleteAdmittedDigest() throws {
    let accepted = Data("accepted CAF bytes".utf8)
    let receipt = try ImportedPlaybackDescriptorReceipt(
      serialized: descriptorReceipt(bytes: accepted)
    )

    let snapshot = try AnonymousImportedPlaybackSnapshot.copy(from: receipt) {
      offset, buffer in
      let start = Int(offset)
      guard start < accepted.count else { return 0 }
      let count = min(buffer.count, accepted.count - start)
      accepted.copyBytes(
        to: buffer.bindMemory(to: UInt8.self),
        from: start..<(start + count)
      )
      return count
    }

    let context = CallbackAudioFileContext(source: snapshot.region)
    var copied = [UInt8](repeating: 0, count: accepted.count)
    var copiedCount: UInt32 = 0
    let copyStatus = copied.withUnsafeMutableBytes { buffer in
      context.read(
        position: 0,
        requestedCount: UInt32(accepted.count),
        buffer: buffer.baseAddress!,
        actualCount: &copiedCount
      )
    }
    XCTAssertEqual(copyStatus, noErr)
    XCTAssertEqual(copiedCount, UInt32(accepted.count))
    XCTAssertEqual(Data(copied), accepted)

    XCTAssertThrowsError(
      try AnonymousImportedPlaybackSnapshot.copy(from: receipt) { offset, buffer in
        let start = Int(offset)
        guard start < accepted.count - 1 else { return 0 }
        let count = min(buffer.count, accepted.count - 1 - start)
        accepted.copyBytes(
          to: buffer.bindMemory(to: UInt8.self),
          from: start..<(start + count)
        )
        return count
      }
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .incompleteSnapshot)
    }

    let changedReceipt = try ImportedPlaybackDescriptorReceipt(
      serialized: descriptorReceipt(bytes: accepted, digest: String(repeating: "0", count: 64))
    )
    XCTAssertThrowsError(
      try AnonymousImportedPlaybackSnapshot.copy(from: changedReceipt) { offset, buffer in
        let start = Int(offset)
        guard start < accepted.count else { return 0 }
        let count = min(buffer.count, accepted.count - start)
        accepted.copyBytes(
          to: buffer.bindMemory(to: UInt8.self),
          from: start..<(start + count)
        )
        return count
      }
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .changedSnapshot)
    }
  }

  func testAnonymousSnapshotRejectsAbovePlaybackCapBeforeAllocationOrRead() throws {
    let receipt = try ImportedPlaybackDescriptorReceipt(
      serialized:
        "v1;fd=42;byte_length=268435457;sha256=\(String(repeating: "a", count: 64));max_byte_length=268435456"
    )
    var allocationCalled = false
    var readCalled = false

    XCTAssertThrowsError(
      try AnonymousImportedPlaybackSnapshot.copy(
        from: receipt,
        allocator: { _ in
          allocationCalled = true
          return nil
        },
        deallocator: { _, _ in },
        protector: { _, _ in true }
      ) { _, _ in
        readCalled = true
        return 0
      }
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .unsupportedByteLength)
    }
    XCTAssertFalse(allocationCalled)
    XCTAssertFalse(readCalled)
  }

  func testAnonymousSnapshotReportsAllocationFailureBeforeRead() throws {
    let accepted = Data("accepted CAF bytes".utf8)
    let receipt = try ImportedPlaybackDescriptorReceipt(
      serialized: descriptorReceipt(bytes: accepted)
    )
    var readCalled = false

    XCTAssertThrowsError(
      try AnonymousImportedPlaybackSnapshot.copy(
        from: receipt,
        allocator: { _ in nil },
        deallocator: { _, _ in },
        protector: { _, _ in true }
      ) { _, _ in
        readCalled = true
        return 0
      }
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .anonymousAllocationFailed)
    }
    XCTAssertFalse(readCalled)
  }

  func testExactPlaybackCapIsEligibleWithoutAllocatingTheBoundary() throws {
    let receipt = try ImportedPlaybackDescriptorReceipt(
      serialized:
        "v1;fd=42;byte_length=268435456;sha256=\(String(repeating: "a", count: 64));max_byte_length=268435456"
    )

    XCTAssertNoThrow(try ImportedPlaybackMemoryPolicy.validate(receipt))
  }

  func testAudioFileCallbackReadsOnlyWithinTheAnonymousSnapshot() {
    let accepted = Data([10, 20, 30, 40])
    let receipt = try! ImportedPlaybackDescriptorReceipt(
      serialized: descriptorReceipt(bytes: accepted)
    )
    let snapshot = try! AnonymousImportedPlaybackSnapshot.copy(from: receipt) {
      offset, buffer in
      let start = Int(offset)
      guard start < accepted.count else { return 0 }
      let count = min(buffer.count, accepted.count - start)
      accepted.copyBytes(
        to: buffer.bindMemory(to: UInt8.self),
        from: start..<(start + count)
      )
      return count
    }
    let context = CallbackAudioFileContext(source: snapshot.region)
    var output = [UInt8](repeating: 0, count: 4)
    var actualCount: UInt32 = 0
    let status = output.withUnsafeMutableBytes { buffer in
      context.read(
        position: 2,
        requestedCount: 4,
        buffer: buffer.baseAddress!,
        actualCount: &actualCount
      )
    }

    XCTAssertEqual(status, noErr)
    XCTAssertEqual(actualCount, 2)
    XCTAssertEqual(Array(output.prefix(2)), [30, 40])
    let invalidStatus = output.withUnsafeMutableBytes { buffer in
      context.read(
        position: -1,
        requestedCount: 1,
        buffer: buffer.baseAddress!,
        actualCount: &actualCount
      )
    }
    XCTAssertEqual(invalidStatus, kAudioFilePositionError)
  }

  func testRecoveredDescriptorPlaybackRetainsLeasedObjectAcrossPathReplacement() throws {
    let mediaURL = try nativePlaybackCAF(frameCount: 2_400)
    defer { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
    let original = try Data(contentsOf: mediaURL)
    let leaseReleased = SendableFlag()
    var lease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: mediaURL,
      released: leaseReleased,
      recovered: true
    )
    let receipt = try RecoveredPlaybackDescriptorReceipt(
      serialized: try XCTUnwrap(lease?.playbackPath())
    )

    try FileManager.default.removeItem(at: mediaURL)
    let replacement = Data(repeating: 0xff, count: original.count)
    try replacement.write(to: mediaURL, options: .withoutOverwriting)
    let source = try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt)
    var copied = Data(count: original.count)
    var actualCount: UInt32 = 0
    let status = copied.withUnsafeMutableBytes { buffer in
      source.copyBytes(
        position: 0,
        requestedCount: UInt32(buffer.count),
        buffer: buffer.baseAddress!,
        actualCount: &actualCount
      )
    }

    XCTAssertEqual(status, noErr)
    XCTAssertEqual(actualCount, UInt32(original.count))
    XCTAssertEqual(copied, original)
    XCTAssertNotEqual(try Data(contentsOf: mediaURL), original)
    withExtendedLifetime(lease) {}
    lease = nil
    XCTAssertTrue(leaseReleased.value)
  }

  func testRecoveredDescriptorPreparationRejectsPartialCopyAndHashMismatch() throws {
    let accepted = Data((0..<70_000).map { UInt8($0 % 251) })
    let digest = SHA256.hash(data: accepted).map { String(format: "%02x", $0) }.joined()
    let receipt = try RecoveredPlaybackDescriptorReceipt(
      serialized: recoveredDescriptorReceipt(byteLength: UInt64(accepted.count), digest: digest)
    )
    let backing = DescriptorBytesFake(bytes: accepted)

    XCTAssertThrowsError(
      try VerifiedDescriptorPlaybackSource.prepare(
        receipt: receipt,
        inspect: backing.inspect,
        readAt: { descriptor, offset, buffer in
          let count = try backing.read(descriptor, offset: offset, buffer: buffer)
          return offset == 0 ? count - 1 : count
        }
      )
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .incompleteSnapshot)
    }

    let mismatchedReceipt = try RecoveredPlaybackDescriptorReceipt(
      serialized: recoveredDescriptorReceipt(
        byteLength: UInt64(accepted.count),
        digest: String(repeating: "0", count: 64)
      )
    )
    XCTAssertThrowsError(
      try VerifiedDescriptorPlaybackSource.prepare(
        receipt: mismatchedReceipt,
        inspect: backing.inspect,
        readAt: backing.read
      )
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .changedSnapshot)
    }
  }

  func testRecoveredDescriptorPlaybackRejectsSameInodeMutationAndIdentityDrift() throws {
    let accepted = Data((0..<70_000).map { UInt8($0 % 251) })
    let digest = SHA256.hash(data: accepted).map { String(format: "%02x", $0) }.joined()
    let receipt = try RecoveredPlaybackDescriptorReceipt(
      serialized: recoveredDescriptorReceipt(byteLength: UInt64(accepted.count), digest: digest)
    )
    let backing = DescriptorBytesFake(bytes: accepted)
    let source = try VerifiedDescriptorPlaybackSource.prepare(
      receipt: receipt,
      inspect: backing.inspect,
      readAt: backing.read
    )
    var output = [UInt8](repeating: 0, count: 32)
    var actualCount: UInt32 = 0

    backing.mutateByte(at: 5)
    let mutationStatus = output.withUnsafeMutableBytes { buffer in
      source.copyBytes(
        position: 0,
        requestedCount: UInt32(buffer.count),
        buffer: buffer.baseAddress!,
        actualCount: &actualCount
      )
    }
    XCTAssertNotEqual(mutationStatus, noErr)
    XCTAssertEqual(actualCount, 0)

    backing.replaceIdentity(device: 7, inode: 12, byteLength: UInt64(accepted.count))
    let replacementStatus = output.withUnsafeMutableBytes { buffer in
      source.copyBytes(
        position: 65_536,
        requestedCount: UInt32(buffer.count),
        buffer: buffer.baseAddress!,
        actualCount: &actualCount
      )
    }
    XCTAssertNotEqual(replacementStatus, noErr)
    XCTAssertEqual(actualCount, 0)
  }

  func testRecoveredDescriptorPlaybackHasNoImportedSnapshotCapOrWholeFileBuffer() throws {
    let byteLength: UInt64 = 268_435_457
    let receipt = try RecoveredPlaybackDescriptorReceipt(
      serialized: recoveredDescriptorReceipt(byteLength: byteLength)
    )
    let source = VerifiedDescriptorPlaybackSource(
      receipt: receipt,
      identity: PlaybackDescriptorIdentity(device: 7, inode: 11, byteLength: byteLength),
      chunkDigests: [],
      inspect: { _ in
        PlaybackDescriptorIdentity(device: 7, inode: 11, byteLength: byteLength)
      },
      readAt: { _, _, _ in 0 }
    )

    XCTAssertEqual(source.callbackByteCount, Int64(byteLength))
    XCTAssertEqual(VerifiedDescriptorPlaybackSource.maximumBufferedByteCount, 65_536)
  }

  func testNativeImportedCallbacksReachNaturalEOFAndReleaseLeaseDescriptor() async throws {
    let mediaURL = try nativePlaybackCAF(frameCount: 2_400)
    defer { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
    let leaseReleased = SendableFlag()
    var lease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: mediaURL,
      released: leaseReleased
    )
    let descriptor = try XCTUnwrap(lease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(observer: lifecycle.record)
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let generation = UUID()

    try await player.playImported(
      receipt: try XCTUnwrap(lease).playbackPath(),
      retaining: try XCTUnwrap(lease),
      generation: generation
    )
    lease = nil

    let reachedEOF = await waitUntil { termination.finished(generation: generation) }
    let releasedLease = await waitUntil { leaseReleased.value }
    let releasedRegion = await waitUntil {
      lifecycle.contains(.anonymousRegionReleased(generation))
    }
    XCTAssertTrue(reachedEOF)
    XCTAssertTrue(releasedLease)
    XCTAssertTrue(releasedRegion)
    XCTAssertTrue(lifecycle.contains(.importedDecoderClosed(generation)))
    XCTAssertTrue(lifecycle.contains(.playerStopped(generation)))
    XCTAssertTrue(lifecycle.contains(.engineStopped(generation)))
    errno = 0
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    XCTAssertEqual(errno, EBADF)
  }

  func testNativeImportedReplacementIgnoresOldQueuedCompletion() async throws {
    let firstURL = try nativePlaybackCAF(frameCount: 2_400)
    let secondURL = try nativePlaybackCAF(frameCount: 24_000)
    defer {
      try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
    }
    let firstReleased = SendableFlag()
    let secondReleased = SendableFlag()
    var firstLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: firstURL,
      released: firstReleased
    )
    var secondLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: secondURL,
      released: secondReleased
    )
    let firstDescriptor = try XCTUnwrap(firstLease?.fileDescriptor)
    let secondDescriptor = try XCTUnwrap(secondLease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let completionGate = NativePlaybackCompletionGate()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(
        observer: lifecycle.record,
        importedCompletionDelivery: completionGate.deliver
      )
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let firstGeneration = UUID()
    let secondGeneration = UUID()

    try await player.playImported(
      receipt: try XCTUnwrap(firstLease).playbackPath(),
      retaining: try XCTUnwrap(firstLease),
      generation: firstGeneration
    )
    firstLease = nil
    let receivedOldCompletion = await waitUntil { completionGate.isHoldingCompletion }
    XCTAssertTrue(receivedOldCompletion)
    try await player.playImported(
      receipt: try XCTUnwrap(secondLease).playbackPath(),
      retaining: try XCTUnwrap(secondLease),
      generation: secondGeneration
    )
    secondLease = nil
    completionGate.release()

    let releasedFirstLease = await waitUntil { firstReleased.value }
    let deliveredOldCompletion = await waitUntil {
      lifecycle.contains(.importedCompletionDelivered(firstGeneration))
    }
    XCTAssertTrue(releasedFirstLease)
    XCTAssertTrue(deliveredOldCompletion)
    XCTAssertEqual(fcntl(firstDescriptor, F_GETFD), -1)
    XCTAssertFalse(termination.contains(generation: firstGeneration))
    let reachedSecondEOF = await waitUntil { termination.finished(generation: secondGeneration) }
    let releasedSecondLease = await waitUntil { secondReleased.value }
    XCTAssertTrue(reachedSecondEOF)
    XCTAssertTrue(releasedSecondLease)
    XCTAssertEqual(fcntl(secondDescriptor, F_GETFD), -1)
  }

  func testNativeImportedStopDrainsQueuedCompletionAndReleasesLease() async throws {
    let mediaURL = try nativePlaybackCAF(frameCount: 24_000)
    defer { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
    let leaseReleased = SendableFlag()
    var lease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: mediaURL,
      released: leaseReleased
    )
    let descriptor = try XCTUnwrap(lease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(observer: lifecycle.record)
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let generation = UUID()

    try await player.playImported(
      receipt: try XCTUnwrap(lease).playbackPath(),
      retaining: try XCTUnwrap(lease),
      generation: generation
    )
    lease = nil
    player.stop()

    let releasedLease = await waitUntil { leaseReleased.value }
    let releasedRegion = await waitUntil {
      lifecycle.contains(.anonymousRegionReleased(generation))
    }
    XCTAssertTrue(releasedLease)
    XCTAssertTrue(releasedRegion)
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    XCTAssertTrue(
      lifecycle.occursInOrder([
        .importedSessionDeactivated(generation),
        .importedDecoderClosed(generation),
        .playerStopped(generation),
        .engineStopped(generation),
        .anonymousRegionReleased(generation),
      ])
    )
    XCTAssertFalse(termination.contains(generation: generation))
  }

  func testNativeRecoveredReplacementIgnoresOldEOFAndReleasesActiveLease() async throws {
    let firstURL = try nativePlaybackCAF(frameCount: 2_400)
    let secondURL = try nativePlaybackCAF(frameCount: 24_000)
    defer {
      try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
    }
    let firstReleased = SendableFlag()
    let secondReleased = SendableFlag()
    var firstLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: firstURL,
      released: firstReleased,
      recovered: true
    )
    var secondLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: secondURL,
      released: secondReleased,
      recovered: true
    )
    let lifecycle = NativePlaybackLifecycleRecorder()
    let completionGate = NativePlaybackCompletionGate()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(
        observer: lifecycle.record,
        recoveredCompletionDelivery: completionGate.deliver
      )
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let firstGeneration = UUID()
    let secondGeneration = UUID()

    try await player.playRecovered(
      receipt: try XCTUnwrap(firstLease?.playbackPath()),
      retaining: try XCTUnwrap(firstLease),
      generation: firstGeneration
    )
    firstLease = nil
    let receivedOldCompletion = await waitUntil { completionGate.isHoldingCompletion }
    XCTAssertTrue(receivedOldCompletion)
    try await player.playRecovered(
      receipt: try XCTUnwrap(secondLease?.playbackPath()),
      retaining: try XCTUnwrap(secondLease),
      generation: secondGeneration
    )
    secondLease = nil
    completionGate.release()

    let releasedFirstLease = await waitUntil { firstReleased.value }
    let deliveredOldCompletion = await waitUntil {
      lifecycle.contains(.recoveredCompletionDelivered(firstGeneration))
    }
    XCTAssertTrue(releasedFirstLease)
    XCTAssertTrue(deliveredOldCompletion)
    XCTAssertFalse(termination.contains(generation: firstGeneration))
    let reachedSecondEOF = await waitUntil { termination.finished(generation: secondGeneration) }
    let releasedSecondLease = await waitUntil { secondReleased.value }
    XCTAssertTrue(reachedSecondEOF)
    XCTAssertTrue(releasedSecondLease)
  }

  func testNativeRecoveredFailedReplacementReleasesPriorAndReplacementLeases() async throws {
    let firstURL = try nativePlaybackCAF(frameCount: 24_000)
    let replacementURL = try nativePlaybackCAF(frameCount: 24_000)
    defer {
      try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: replacementURL.deletingLastPathComponent())
    }
    let firstReleased = SendableFlag()
    let replacementReleased = SendableFlag()
    var firstLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: firstURL,
      released: firstReleased,
      recovered: true
    )
    var replacementLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: replacementURL,
      released: replacementReleased,
      recovered: true
    )
    let firstDescriptor = try XCTUnwrap(firstLease?.fileDescriptor)
    let replacementDescriptor = try XCTUnwrap(replacementLease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(observer: lifecycle.record)
    )
    let firstGeneration = UUID()
    let replacementGeneration = UUID()

    try await player.playRecovered(
      receipt: try XCTUnwrap(firstLease?.playbackPath()),
      retaining: try XCTUnwrap(firstLease),
      generation: firstGeneration
    )
    firstLease = nil

    let replacementBytes = try Data(contentsOf: replacementURL)
    let mutationDescriptor = open(replacementURL.path, O_WRONLY | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(mutationDescriptor, 0)
    guard mutationDescriptor >= 0 else { return }
    var changedByte = (try XCTUnwrap(replacementBytes.last)) ^ 0xff
    XCTAssertEqual(
      pwrite(
        mutationDescriptor,
        &changedByte,
        1,
        off_t(replacementBytes.count - 1)
      ),
      1
    )
    XCTAssertEqual(fsync(mutationDescriptor), 0)
    XCTAssertEqual(close(mutationDescriptor), 0)

    do {
      try await player.playRecovered(
        receipt: try XCTUnwrap(replacementLease?.playbackPath()),
        retaining: try XCTUnwrap(replacementLease),
        generation: replacementGeneration
      )
      XCTFail("mutated replacement unexpectedly opened")
    } catch {
      XCTAssertEqual(error as? ImportedPlaybackError, .changedSnapshot)
    }

    let releasedPrior = await waitUntil { firstReleased.value }
    XCTAssertTrue(releasedPrior)
    XCTAssertEqual(fcntl(firstDescriptor, F_GETFD), -1)
    replacementLease = nil
    let releasedReplacement = await waitUntil { replacementReleased.value }
    XCTAssertTrue(releasedReplacement)
    XCTAssertEqual(fcntl(replacementDescriptor, F_GETFD), -1)
    XCTAssertTrue(
      lifecycle.occursInOrder([
        .recoveredSessionDeactivated(firstGeneration),
        .recoveredDecoderClosed(firstGeneration),
        .playerStopped(firstGeneration),
        .engineStopped(firstGeneration),
      ])
    )
  }

  func testNativeRecoveredStopReleasesLeaseDescriptor() async throws {
    let mediaURL = try nativePlaybackCAF(frameCount: 24_000)
    defer { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
    let leaseReleased = SendableFlag()
    var lease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: mediaURL,
      released: leaseReleased,
      recovered: true
    )
    let descriptor = try XCTUnwrap(lease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(observer: lifecycle.record)
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let generation = UUID()

    try await player.playRecovered(
      receipt: try XCTUnwrap(lease?.playbackPath()),
      retaining: try XCTUnwrap(lease),
      generation: generation
    )
    lease = nil
    player.stop()

    let releasedLease = await waitUntil { leaseReleased.value }
    XCTAssertTrue(releasedLease)
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    XCTAssertTrue(
      lifecycle.occursInOrder([
        .recoveredSessionDeactivated(generation),
        .recoveredDecoderClosed(generation),
        .playerStopped(generation),
        .engineStopped(generation),
      ])
    )
    XCTAssertFalse(termination.contains(generation: generation))
  }

  func testNativeOutputConfigurationChangeTerminatesAndReleasesImportedLease() async throws {
    let mediaURL = try nativePlaybackCAF(frameCount: 24_000)
    defer { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
    let leaseReleased = SendableFlag()
    var lease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: mediaURL,
      released: leaseReleased
    )
    let descriptor = try XCTUnwrap(lease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(observer: lifecycle.record)
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let generation = UUID()

    try await player.playImported(
      receipt: try XCTUnwrap(lease?.playbackPath()),
      retaining: try XCTUnwrap(lease),
      generation: generation
    )
    lease = nil
    player.handleOutputConfigurationChange(generation: generation)

    let terminated = await waitUntil {
      termination.contains(generation: generation, outcome: .outputRouteChanged)
    }
    XCTAssertTrue(terminated)
    let released = await waitUntil { leaseReleased.value }
    XCTAssertTrue(released)
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    XCTAssertTrue(
      lifecycle.occursInOrder([
        .outputConfigurationChanged(generation),
        .importedSessionDeactivated(generation),
        .importedDecoderClosed(generation),
        .playerStopped(generation),
        .engineStopped(generation),
        .anonymousRegionReleased(generation),
      ])
    )

    player.handleOutputConfigurationChange(generation: generation)
    XCTAssertTrue(
      termination.contains(generation: generation, outcome: .outputRouteChanged)
    )
  }

  func testRecoveryAndAsyncDecodeFailureReleaseImportedPlayingTruth() async {
    let player = RecoveredAudioPlayerFake()
    let lease = ImportedPlaybackLeaseFake(path: descriptorReceipt())
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in lease },
      player: player
    )
    let imported = savedSession(availability: "available", absolutePath: "/tmp/imported.caf")

    controller.play(imported)
    await assertEventually { controller.playingSessionId == imported.sessionId }
    controller.recoverOnLaunch()
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.retainedLease)

    controller.play(imported)
    await assertEventually { controller.playingSessionId == imported.sessionId }
    let generation = player.importedGeneration!
    player.terminate(generation: generation, outcome: .failed)
    await assertEventually { controller.errorMessage != nil }
    XCTAssertNil(controller.playingSessionId)
    XCTAssertEqual(
      controller.errorMessage,
      "Saved audio playback stopped because decoding failed."
    )
  }

  func testOutputRouteTerminationClearsPlayingTruthAndReportsRestartAction() async {
    let player = RecoveredAudioPlayerFake()
    let lease = ImportedPlaybackLeaseFake(path: descriptorReceipt())
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in lease },
      player: player
    )
    let imported = savedSession(availability: "available", absolutePath: nil)

    controller.play(imported)
    await assertEventually { controller.playingSessionId == imported.sessionId }
    let generation = player.importedGeneration!
    player.terminate(generation: generation, outcome: .outputRouteChanged)

    await assertEventually { controller.errorMessage != nil }
    XCTAssertNil(controller.activePlaybackSessionId)
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.retainedLease)
    XCTAssertEqual(
      controller.errorMessage,
      "Playback stopped because the audio output changed. Press Play to restart."
    )
  }

  func testOldCompletionAfterReplacementCannotMutateCurrentPlaybackTruth() async {
    let player = RecoveredAudioPlayerFake()
    let decisions = PlaybackTerminationDecisionRecorder()
    let firstLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 42))
    let secondLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 43))
    let selectedLease = ImportedPlaybackLeaseSelection(firstLease)
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in selectedLease.lease },
      player: player,
      playbackTerminationDecisionObserver: decisions.record
    )
    let first = savedSession(
      sessionId: "session-first",
      availability: "available",
      absolutePath: "/tmp/first.caf"
    )
    let second = savedSession(
      sessionId: "session-second",
      availability: "available",
      absolutePath: "/tmp/second.caf"
    )

    controller.play(first)
    await assertEventually { controller.playingSessionId == first.sessionId }
    let firstGeneration = player.importedGeneration!

    selectedLease.select(secondLease)
    controller.play(second)
    await assertEventually { controller.playingSessionId == second.sessionId }
    let secondGeneration = player.importedGeneration!
    XCTAssertEqual(controller.playingSessionId, second.sessionId)
    XCTAssertTrue(player.retainedLease === secondLease)

    player.deliverTermination(generation: firstGeneration, outcome: .failed)
    await assertEventually { decisions.decision(for: firstGeneration) == false }

    XCTAssertEqual(controller.playingSessionId, second.sessionId)
    XCTAssertEqual(player.importedGeneration, secondGeneration)
    XCTAssertTrue(player.retainedLease === secondLease)
    XCTAssertNil(controller.errorMessage)

    controller.stopPlayback()
    player.terminate(generation: secondGeneration, outcome: .finished)
    await assertEventually { controller.playingSessionId == nil }
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.retainedLease)
    XCTAssertNil(controller.errorMessage)
  }

  func testPlaybackAboveSafeCapReportsTruthWithoutChangingLibrarySession() async {
    let player = RecoveredAudioPlayerFake()
    let leaseRequested = SendableFlag()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in
        leaseRequested.set()
        return ImportedPlaybackLeaseFake(path: descriptorReceipt())
      },
      player: player
    )
    let captured = savedSession(
      sessionId: "session-captured",
      availability: "available",
      absolutePath: "/managed/large.caf",
      byteLength: 268_435_457,
      sourceDisplayName: "Mac microphone"
    )

    controller.play(captured)

    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.retainedLease)
    XCTAssertFalse(leaseRequested.value)
    XCTAssertEqual(
      controller.errorMessage,
      "Saved audio is too large for safe playback on this version of Open Scribe."
    )
    XCTAssertEqual(captured.playableMedia?.sourceDisplayName, "Mac microphone")
    XCTAssertTrue(captured.playableMedia?.isPlayable == true)
  }

  private func nativePlaybackCAF(frameCount: AVAudioFrameCount) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-native-playback-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("playback.caf", isDirectory: false)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: true,
    ]
    var file: AVAudioFile? = try AVAudioFile(
      forWriting: url,
      settings: settings,
      commonFormat: .pcmFormatInt16,
      interleaved: false
    )
    let generatedFileFormat = try XCTUnwrap(file?.fileFormat.streamDescription).pointee
    XCTAssertEqual(generatedFileFormat.mSampleRate, 48_000)
    XCTAssertEqual(generatedFileFormat.mFormatID, kAudioFormatLinearPCM)
    XCTAssertEqual(generatedFileFormat.mBytesPerPacket, 2)
    XCTAssertEqual(generatedFileFormat.mFramesPerPacket, 1)
    XCTAssertEqual(generatedFileFormat.mChannelsPerFrame, 1)
    XCTAssertEqual(generatedFileFormat.mBitsPerChannel, 16)
    let processingFormat = try XCTUnwrap(file?.processingFormat)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount)
    )
    buffer.frameLength = frameCount
    let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
    for frame in 0..<Int(frameCount) {
      samples[frame] = Int16((frame % 64) * 512)
    }
    try file?.write(from: buffer)
    file = nil
    let finalizedFile = try AVAudioFile(forReading: url)
    XCTAssertEqual(finalizedFile.length, AVAudioFramePosition(frameCount))
    return url
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

  private func recoveredSession(
    sessionId: String = "session-recovered",
    sourceId: String = "source-recovered",
    trackId: String = "track-recovered",
    segmentId: String = "segment-recovered",
    path: String = "/tmp/recovered.caf",
    mediaPreserved: Bool = true
  ) -> NativeRecoveredPlayableSession {
    NativeRecoveredPlayableSession(
      sessionId: sessionId,
      sourceId: sourceId,
      trackId: trackId,
      sourceKind: .microphone,
      sourceDisplayName: "Synthetic microphone",
      segmentId: segmentId,
      relativePath: "audio/track/segment.caf",
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

  private func savedSession(
    sessionId: String = "session-imported", availability: String, absolutePath: String?,
    byteLength: UInt64 = 192_068, sourceDisplayName: String = "interview.caf"
  ) -> RuntimeSessionPresentation {
    RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: sessionId,
        title: "Saved conversation",
        lifecycle: "ready_for_review",
        health: "healthy",
        elapsedSeconds: 2,
        journalDurable: true,
        mediaFilesOpen: false,
        interruptionReason: nil,
        recovered: false,
        sources: [],
        playableMedia: NativeRuntimePlayableMediaSnapshot(
          sourceDisplayName: sourceDisplayName,
          availability: availability,
          absolutePath: absolutePath,
          durationNanoseconds: 2_000_000_000,
          sampleCount: 96_000,
          byteLength: byteLength
        )
      )
    )
  }
}

private func descriptorReceipt(
  fileDescriptor: Int32 = 42,
  bytes: Data = Data(repeating: 0, count: 192_068),
  digest: String? = nil
) -> String {
  let acceptedDigest =
    digest
    ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  return
    "v1;fd=\(fileDescriptor);byte_length=\(bytes.count);sha256=\(acceptedDigest);max_byte_length=268435456"
}
