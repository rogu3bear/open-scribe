@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import OpenScribeApp

final class RecoveryPreparationFake: NativeRecordingPreparation, @unchecked Sendable {
  var recovered: [NativeRecoveredPlayableSession] = []
  var recoveryError: Error?
  private let lock = NSLock()
  private var mainThreadObservation: Bool?

  init() {
    super.init(noHandle: NoHandle())
  }

  required init(unsafeFromHandle handle: UInt64) {
    super.init(unsafeFromHandle: handle)
  }

  /// Whether the last scan ran on the main thread; nil before any scan.
  var recoveredOnMainThread: Bool? {
    lock.withLock { mainThreadObservation }
  }

  override func recoverPlayableSessions() throws -> [NativeRecoveredPlayableSession] {
    lock.withLock { mainThreadObservation = Thread.isMainThread }
    if let recoveryError {
      throw recoveryError
    }
    return recovered
  }
}

@MainActor
final class RecoveredAudioPlayerFake: RecoveredAudioPlaying {
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

func recoveredDescriptorReceipt(
  fileDescriptor: Int32 = 44,
  byteLength: UInt64 = 100_000,
  digest: String = String(repeating: "a", count: 64)
) -> String {
  "v2;fd=\(fileDescriptor);byte_length=\(byteLength);sha256=\(digest);chunk_byte_length=65536"
}

final class ImportedPlaybackLeaseFake: ImportedPlaybackLeaseHolding, @unchecked Sendable {
  let path: String

  init(path: String) {
    self.path = path
  }

  func playbackPath() -> String { path }
}

final class ReleasingPlaybackLeaseProbe: ImportedPlaybackLeaseHolding, @unchecked Sendable {
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

final class BlockingRecoveredPlaybackLeaseProvider: @unchecked Sendable {
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

final class SendableFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false

  var value: Bool {
    lock.withLock { storage }
  }

  func set() {
    lock.withLock { storage = true }
  }
}

final class DescriptorBytesFake: @unchecked Sendable {
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

final class DescriptorPlaybackLeaseProbe: ImportedPlaybackLeaseHolding,
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

final class PlaybackLifetimeProbe: @unchecked Sendable {
  private let released: SendableFlag

  init(released: SendableFlag) {
    self.released = released
  }

  deinit {
    released.set()
  }
}

final class PlaybackTerminationRecorder: @unchecked Sendable {
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

final class PlaybackTerminationDecisionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [UUID: Bool] = [:]

  func record(generation: UUID, isActive: Bool) {
    lock.withLock { storage[generation] = isActive }
  }

  func decision(for generation: UUID) -> Bool? {
    lock.withLock { storage[generation] }
  }
}

final class NativePlaybackLifecycleRecorder: @unchecked Sendable {
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

final class NativePlaybackCompletionGate: @unchecked Sendable {
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

final class SnapshotReadGate: @unchecked Sendable {
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

final class ImportedPlaybackLeaseSelection: @unchecked Sendable {
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
class RecoveredSessionTestCase: XCTestCase {
  func nativePlaybackCAF(frameCount: AVAudioFrameCount) throws -> URL {
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
  final func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    _ predicate: @escaping () -> Bool
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
  final func assertEventually(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @escaping () -> Bool
  ) async {
    let observed = await waitUntil(predicate)
    XCTAssertTrue(observed, file: file, line: line)
  }
  func recoveredSession(
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
  func savedSession(
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
        hasCaptureTimeline: false,
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

func descriptorReceipt(
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
