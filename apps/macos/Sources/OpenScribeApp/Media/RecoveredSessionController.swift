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
  func play(url: URL, retaining lease: AnyObject?, generation: UUID) throws
  func playImported(receipt: String, retaining lease: AnyObject, generation: UUID) async throws
  func setPlaybackTerminationHandler(
    _ handler: @escaping @Sendable (PlaybackTermination) -> Void
  )
  func stop()
}

enum PlaybackTerminationOutcome: Sendable {
  case finished
  case failed
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
  case recoveredCompletionReceived(UUID)
  case recoveredCompletionDelivered(UUID)
  case playerStopped(UUID?)
  case engineStopped(UUID?)
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

enum ImportedPlaybackAudioFileOperation: String, Equatable, Sendable {
  case openCallbacks
  case wrapAudioFile
  case readFileDataFormat
  case setClientDataFormat
  case readFrames
}

struct ImportedPlaybackAudioFormatSummary: Equatable, Sendable {
  let sampleRate: Double
  let formatID: UInt32
  let formatFlags: UInt32
  let bytesPerPacket: UInt32
  let framesPerPacket: UInt32
  let bytesPerFrame: UInt32
  let channelsPerFrame: UInt32
  let bitsPerChannel: UInt32

  init(_ format: AudioStreamBasicDescription) {
    sampleRate = format.mSampleRate
    formatID = format.mFormatID
    formatFlags = format.mFormatFlags
    bytesPerPacket = format.mBytesPerPacket
    framesPerPacket = format.mFramesPerPacket
    bytesPerFrame = format.mBytesPerFrame
    channelsPerFrame = format.mChannelsPerFrame
    bitsPerChannel = format.mBitsPerChannel
  }
}

struct ImportedPlaybackAudioFileLayoutSummary: Equatable, Sendable {
  let audioDataByteCountStatus: OSStatus
  let audioDataByteCount: UInt64?
  let audioDataPacketCountStatus: OSStatus
  let audioDataPacketCount: UInt64?
  let dataOffsetStatus: OSStatus
  let dataOffset: Int64?
  let fileLengthFramesStatus: OSStatus
  let fileLengthFrames: Int64?
  let initialFramePositionStatus: OSStatus
  let initialFramePosition: Int64?
  let finalFramePositionStatus: OSStatus
  let finalFramePosition: Int64?

  static func observe(
    audioFile: AudioFileID,
    extendedAudioFile: ExtAudioFileRef,
    initialFramePositionStatus: OSStatus,
    initialFramePosition: Int64?
  ) -> Self {
    var audioDataByteCount: UInt64 = 0
    var propertySize = UInt32(MemoryLayout<UInt64>.size)
    let audioDataByteCountStatus = AudioFileGetProperty(
      audioFile,
      kAudioFilePropertyAudioDataByteCount,
      &propertySize,
      &audioDataByteCount
    )

    var audioDataPacketCount: UInt64 = 0
    propertySize = UInt32(MemoryLayout<UInt64>.size)
    let audioDataPacketCountStatus = AudioFileGetProperty(
      audioFile,
      kAudioFilePropertyAudioDataPacketCount,
      &propertySize,
      &audioDataPacketCount
    )

    var dataOffset: Int64 = 0
    propertySize = UInt32(MemoryLayout<Int64>.size)
    let dataOffsetStatus = AudioFileGetProperty(
      audioFile,
      kAudioFilePropertyDataOffset,
      &propertySize,
      &dataOffset
    )

    var fileLengthFrames: Int64 = 0
    propertySize = UInt32(MemoryLayout<Int64>.size)
    let fileLengthFramesStatus = ExtAudioFileGetProperty(
      extendedAudioFile,
      kExtAudioFileProperty_FileLengthFrames,
      &propertySize,
      &fileLengthFrames
    )

    var finalFramePosition: Int64 = 0
    let finalFramePositionStatus = ExtAudioFileTell(
      extendedAudioFile,
      &finalFramePosition
    )

    return Self(
      audioDataByteCountStatus: audioDataByteCountStatus,
      audioDataByteCount: audioDataByteCountStatus == noErr ? audioDataByteCount : nil,
      audioDataPacketCountStatus: audioDataPacketCountStatus,
      audioDataPacketCount: audioDataPacketCountStatus == noErr ? audioDataPacketCount : nil,
      dataOffsetStatus: dataOffsetStatus,
      dataOffset: dataOffsetStatus == noErr ? dataOffset : nil,
      fileLengthFramesStatus: fileLengthFramesStatus,
      fileLengthFrames: fileLengthFramesStatus == noErr ? fileLengthFrames : nil,
      initialFramePositionStatus: initialFramePositionStatus,
      initialFramePosition: initialFramePosition,
      finalFramePositionStatus: finalFramePositionStatus,
      finalFramePosition: finalFramePositionStatus == noErr ? finalFramePosition : nil
    )
  }
}

enum ImportedPlaybackFormatFailure: Equatable, Sendable {
  case invalidFileDataFormat(ImportedPlaybackAudioFormatSummary)
  case clientFormatUnavailable(ImportedPlaybackAudioFormatSummary)
  case decoderUnavailable
  case clientBufferUnavailable(ImportedPlaybackAudioFormatSummary)
  case emptyInitialRead(
    file: ImportedPlaybackAudioFormatSummary,
    client: ImportedPlaybackAudioFormatSummary,
    layout: ImportedPlaybackAudioFileLayoutSummary,
    requestedFrames: UInt32,
    producedFrames: UInt32
  )
  case emptyPrime
}

enum ImportedPlaybackError: Error, Equatable {
  case invalidDescriptorReceipt
  case unsupportedByteLength
  case anonymousAllocationFailed
  case anonymousProtectionFailed
  case incompleteSnapshot
  case changedSnapshot
  case audioFile(operation: ImportedPlaybackAudioFileOperation, status: OSStatus)
  case unsupportedAudioFormat(ImportedPlaybackFormatFailure)
}

struct ImportedPlaybackDescriptorReceipt: Equatable, Sendable {
  let fileDescriptor: Int32
  let byteLength: UInt64
  let digestSha256: String
  let maximumByteLength: UInt64

  init(serialized: String) throws {
    let parts = serialized.split(separator: ";", omittingEmptySubsequences: false)
    guard parts.first == "v1" else {
      throw ImportedPlaybackError.invalidDescriptorReceipt
    }
    var fields: [String: String] = [:]
    for part in parts.dropFirst() {
      let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2, fields[String(pair[0])] == nil else {
        throw ImportedPlaybackError.invalidDescriptorReceipt
      }
      fields[String(pair[0])] = String(pair[1])
    }
    guard
      fields.count == 4,
      let descriptorText = fields["fd"],
      let descriptor = Int32(descriptorText),
      descriptor >= 0,
      let byteLengthText = fields["byte_length"],
      let byteLength = UInt64(byteLengthText),
      byteLength > 0,
      let digest = fields["sha256"],
      digest.count == 64,
      digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
      let maximumText = fields["max_byte_length"],
      let maximum = UInt64(maximumText),
      maximum > 0
    else {
      throw ImportedPlaybackError.invalidDescriptorReceipt
    }
    fileDescriptor = descriptor
    self.byteLength = byteLength
    digestSha256 = digest
    maximumByteLength = maximum
  }
}

enum ImportedPlaybackMemoryPolicy {
  static let maximumSnapshotByteLength: UInt64 = 256 * 1024 * 1024

  static func validate(_ receipt: ImportedPlaybackDescriptorReceipt) throws {
    guard
      receipt.maximumByteLength == maximumSnapshotByteLength,
      receipt.byteLength <= maximumSnapshotByteLength,
      receipt.byteLength <= UInt64(Int.max)
    else {
      throw ImportedPlaybackError.unsupportedByteLength
    }
  }
}

final class AnonymousPlaybackRegion: @unchecked Sendable {
  typealias Allocator = (_ byteCount: Int) -> UnsafeMutableRawPointer?
  typealias Deallocator = (_ baseAddress: UnsafeMutableRawPointer, _ byteCount: Int) -> Void
  typealias Protector = (_ baseAddress: UnsafeMutableRawPointer, _ byteCount: Int) -> Bool

  let byteCount: Int
  fileprivate let baseAddress: UnsafeMutableRawPointer

  private let deallocator: Deallocator
  private let onRelease: @Sendable () -> Void
  private let protector: Protector
  private var isProtected = false

  init(
    byteCount: Int,
    allocator: Allocator = AnonymousPlaybackRegion.systemAllocate,
    deallocator: @escaping Deallocator = AnonymousPlaybackRegion.systemDeallocate,
    protector: @escaping Protector = AnonymousPlaybackRegion.systemProtect,
    onRelease: @escaping @Sendable () -> Void = {}
  ) throws {
    guard byteCount > 0, let baseAddress = allocator(byteCount) else {
      throw ImportedPlaybackError.anonymousAllocationFailed
    }
    self.byteCount = byteCount
    self.baseAddress = baseAddress
    self.deallocator = deallocator
    self.onRelease = onRelease
    self.protector = protector
  }

  func protectReadOnly() throws {
    guard !isProtected else { return }
    guard protector(baseAddress, byteCount) else {
      throw ImportedPlaybackError.anonymousProtectionFailed
    }
    isProtected = true
  }

  func copyBytes(
    position: Int64,
    requestedCount: UInt32,
    buffer: UnsafeMutableRawPointer,
    actualCount: UnsafeMutablePointer<UInt32>
  ) -> OSStatus {
    guard position >= 0 else { return kAudioFilePositionError }
    let offset = UInt64(position)
    guard offset <= UInt64(byteCount) else { return kAudioFilePositionError }
    let count = min(Int(requestedCount), byteCount - Int(offset))
    if count > 0 {
      buffer.copyMemory(from: baseAddress.advanced(by: Int(offset)), byteCount: count)
    }
    actualCount.pointee = UInt32(count)
    return noErr
  }

  deinit {
    deallocator(baseAddress, byteCount)
    onRelease()
  }

  static func systemAllocate(byteCount: Int) -> UnsafeMutableRawPointer? {
    let mapped = mmap(
      nil,
      byteCount,
      PROT_READ | PROT_WRITE,
      MAP_PRIVATE | MAP_ANON,
      -1,
      0
    )
    guard mapped != MAP_FAILED else { return nil }
    return mapped
  }

  static func systemDeallocate(
    baseAddress: UnsafeMutableRawPointer,
    byteCount: Int
  ) {
    _ = munmap(baseAddress, byteCount)
  }

  static func systemProtect(
    baseAddress: UnsafeMutableRawPointer,
    byteCount: Int
  ) -> Bool {
    mprotect(baseAddress, byteCount, PROT_READ) == 0
  }
}

struct AnonymousImportedPlaybackSnapshot: Sendable {
  typealias PositionalRead =
    (_ offset: UInt64, _ buffer: UnsafeMutableRawBufferPointer) throws -> Int

  let region: AnonymousPlaybackRegion

  static func copy(
    from receipt: ImportedPlaybackDescriptorReceipt,
    isCancelled: @escaping () -> Bool = { false },
    onRegionRelease: @escaping @Sendable () -> Void = {}
  ) throws -> Self {
    try copy(
      from: receipt,
      isCancelled: isCancelled,
      onRegionRelease: onRegionRelease
    ) { offset, buffer in
      guard let baseAddress = buffer.baseAddress else { return 0 }
      while true {
        let count = pread(
          receipt.fileDescriptor,
          baseAddress,
          buffer.count,
          off_t(offset)
        )
        if count >= 0 { return count }
        if errno != EINTR {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
    }
  }

  static func copy(
    from receipt: ImportedPlaybackDescriptorReceipt,
    allocator: AnonymousPlaybackRegion.Allocator = AnonymousPlaybackRegion.systemAllocate,
    deallocator: @escaping AnonymousPlaybackRegion.Deallocator =
      AnonymousPlaybackRegion.systemDeallocate,
    protector: @escaping AnonymousPlaybackRegion.Protector =
      AnonymousPlaybackRegion.systemProtect,
    isCancelled: () -> Bool = { false },
    onRegionRelease: @escaping @Sendable () -> Void = {},
    readAt: PositionalRead
  ) throws -> Self {
    try ImportedPlaybackMemoryPolicy.validate(receipt)
    let region = try AnonymousPlaybackRegion(
      byteCount: Int(receipt.byteLength),
      allocator: allocator,
      deallocator: deallocator,
      protector: protector,
      onRelease: onRegionRelease
    )
    var hasher = SHA256()
    var offset: UInt64 = 0

    while offset < receipt.byteLength {
      if isCancelled() { throw CancellationError() }
      let remaining = receipt.byteLength - offset
      let requested = min(64 * 1024, Int(remaining))
      let destination = UnsafeMutableRawBufferPointer(
        start: region.baseAddress.advanced(by: Int(offset)),
        count: requested
      )
      let read = try readAt(offset, destination)
      guard read > 0, read <= requested else {
        throw ImportedPlaybackError.incompleteSnapshot
      }
      hasher.update(
        data: Data(bytes: destination.baseAddress!, count: read)
      )
      offset += UInt64(read)
    }

    var trailingByte: UInt8 = 0
    let trailingCount = try withUnsafeMutableBytes(of: &trailingByte) { rawBuffer in
      try readAt(receipt.byteLength, rawBuffer)
    }
    guard trailingCount == 0 else {
      throw ImportedPlaybackError.changedSnapshot
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == receipt.digestSha256 else {
      throw ImportedPlaybackError.changedSnapshot
    }
    try region.protectReadOnly()
    return Self(region: region)
  }
}

final class AnonymousAudioFileContext: @unchecked Sendable {
  let region: AnonymousPlaybackRegion

  init(region: AnonymousPlaybackRegion) {
    self.region = region
  }

  func read(
    position: Int64,
    requestedCount: UInt32,
    buffer: UnsafeMutableRawPointer,
    actualCount: UnsafeMutablePointer<UInt32>
  ) -> OSStatus {
    region.copyBytes(
      position: position,
      requestedCount: requestedCount,
      buffer: buffer,
      actualCount: actualCount
    )
  }
}

private let anonymousAudioFileRead: AudioFile_ReadProc = {
  clientData, position, requestedCount, buffer, actualCount in
  let context = Unmanaged<AnonymousAudioFileContext>.fromOpaque(clientData)
    .takeUnretainedValue()
  return context.read(
    position: position,
    requestedCount: requestedCount,
    buffer: buffer,
    actualCount: actualCount
  )
}

private let anonymousAudioFileSize: AudioFile_GetSizeProc = { clientData in
  let context = Unmanaged<AnonymousAudioFileContext>.fromOpaque(clientData)
    .takeUnretainedValue()
  return Int64(context.region.byteCount)
}

private final class AnonymousCAFDecoder: @unchecked Sendable {
  let processingFormat: AVAudioFormat

  private let context: AnonymousAudioFileContext
  private let fileFormatSummary: ImportedPlaybackAudioFormatSummary
  private let clientFormatSummary: ImportedPlaybackAudioFormatSummary
  private let initialFramePositionStatus: OSStatus
  private let initialFramePosition: Int64?
  private let onClose: @Sendable () -> Void
  private var audioFile: AudioFileID?
  private var extendedAudioFile: ExtAudioFileRef?
  private var hasProducedFrames = false

  init(
    snapshot: AnonymousImportedPlaybackSnapshot,
    onClose: @escaping @Sendable () -> Void
  ) throws {
    let context = AnonymousAudioFileContext(region: snapshot.region)
    var openedAudioFile: AudioFileID?
    var status = AudioFileOpenWithCallbacks(
      Unmanaged.passUnretained(context).toOpaque(),
      anonymousAudioFileRead,
      nil,
      anonymousAudioFileSize,
      nil,
      kAudioFileCAFType,
      &openedAudioFile
    )
    guard status == noErr, let openedAudioFile else {
      throw ImportedPlaybackError.audioFile(operation: .openCallbacks, status: status)
    }

    var wrappedAudioFile: ExtAudioFileRef?
    status = ExtAudioFileWrapAudioFileID(openedAudioFile, false, &wrappedAudioFile)
    guard status == noErr, let wrappedAudioFile else {
      AudioFileClose(openedAudioFile)
      throw ImportedPlaybackError.audioFile(operation: .wrapAudioFile, status: status)
    }

    var fileFormat = AudioStreamBasicDescription()
    var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    status = ExtAudioFileGetProperty(
      wrappedAudioFile,
      kExtAudioFileProperty_FileDataFormat,
      &propertySize,
      &fileFormat
    )
    guard status == noErr else {
      ExtAudioFileDispose(wrappedAudioFile)
      AudioFileClose(openedAudioFile)
      throw ImportedPlaybackError.audioFile(operation: .readFileDataFormat, status: status)
    }
    let fileFormatSummary = ImportedPlaybackAudioFormatSummary(fileFormat)
    guard fileFormat.mSampleRate > 0, fileFormat.mChannelsPerFrame > 0 else {
      ExtAudioFileDispose(wrappedAudioFile)
      AudioFileClose(openedAudioFile)
      throw ImportedPlaybackError.unsupportedAudioFormat(
        .invalidFileDataFormat(fileFormatSummary)
      )
    }
    guard
      let processingFormat = AVAudioFormat(
        standardFormatWithSampleRate: fileFormat.mSampleRate,
        channels: fileFormat.mChannelsPerFrame
      )
    else {
      ExtAudioFileDispose(wrappedAudioFile)
      AudioFileClose(openedAudioFile)
      throw ImportedPlaybackError.unsupportedAudioFormat(
        .clientFormatUnavailable(fileFormatSummary)
      )
    }

    var clientFormat = processingFormat.streamDescription.pointee
    let clientFormatSummary = ImportedPlaybackAudioFormatSummary(clientFormat)
    status = ExtAudioFileSetProperty(
      wrappedAudioFile,
      kExtAudioFileProperty_ClientDataFormat,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
      &clientFormat
    )
    guard status == noErr else {
      ExtAudioFileDispose(wrappedAudioFile)
      AudioFileClose(openedAudioFile)
      throw ImportedPlaybackError.audioFile(operation: .setClientDataFormat, status: status)
    }
    var initialFramePosition: Int64 = 0
    let initialFramePositionStatus = ExtAudioFileTell(
      wrappedAudioFile,
      &initialFramePosition
    )

    self.context = context
    self.fileFormatSummary = fileFormatSummary
    self.clientFormatSummary = clientFormatSummary
    self.initialFramePositionStatus = initialFramePositionStatus
    self.initialFramePosition =
      initialFramePositionStatus == noErr ? initialFramePosition : nil
    self.onClose = onClose
    audioFile = openedAudioFile
    extendedAudioFile = wrappedAudioFile
    self.processingFormat = processingFormat
  }

  func read(maximumFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
    guard let audioFile, let extendedAudioFile else {
      throw ImportedPlaybackError.unsupportedAudioFormat(.decoderUnavailable)
    }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: processingFormat,
        frameCapacity: maximumFrames
      )
    else {
      throw ImportedPlaybackError.unsupportedAudioFormat(
        .clientBufferUnavailable(clientFormatSummary)
      )
    }
    buffer.frameLength = maximumFrames
    var frames = maximumFrames
    let status = ExtAudioFileRead(extendedAudioFile, &frames, buffer.mutableAudioBufferList)
    guard status == noErr else {
      throw ImportedPlaybackError.audioFile(operation: .readFrames, status: status)
    }
    guard frames > 0 else {
      if !hasProducedFrames {
        let layout = ImportedPlaybackAudioFileLayoutSummary.observe(
          audioFile: audioFile,
          extendedAudioFile: extendedAudioFile,
          initialFramePositionStatus: initialFramePositionStatus,
          initialFramePosition: initialFramePosition
        )
        throw ImportedPlaybackError.unsupportedAudioFormat(
          .emptyInitialRead(
            file: fileFormatSummary,
            client: clientFormatSummary,
            layout: layout,
            requestedFrames: maximumFrames,
            producedFrames: frames
          )
        )
      }
      return nil
    }
    hasProducedFrames = true
    buffer.frameLength = frames
    return buffer
  }

  func close() {
    let wasOpen = extendedAudioFile != nil || audioFile != nil
    if let extendedAudioFile {
      ExtAudioFileDispose(extendedAudioFile)
      self.extendedAudioFile = nil
    }
    if let audioFile {
      AudioFileClose(audioFile)
      self.audioFile = nil
    }
    if wasOpen {
      onClose()
    }
  }

  deinit {
    close()
  }
}

private final class BoundedImportedPlaybackSession: @unchecked Sendable {
  private static let framesPerBuffer: AVAudioFrameCount = 16_384
  private static let scheduledBufferLimit = 2

  let processingFormat: AVAudioFormat

  private let decoder: AnonymousCAFDecoder
  private let generation: UUID
  private let lifecycle: NativePlaybackLifecycleHooks
  private let termination: @Sendable (PlaybackTermination) -> Void
  private let queue = DispatchQueue(label: "app.open-scribe.imported-playback")
  private var scheduledBuffers: [UUID: AVAudioPCMBuffer] = [:]
  private var reachedEnd = false
  private var active = true

  init(
    snapshot: AnonymousImportedPlaybackSnapshot,
    generation: UUID,
    lifecycle: NativePlaybackLifecycleHooks,
    termination: @escaping @Sendable (PlaybackTermination) -> Void
  ) throws {
    self.generation = generation
    self.lifecycle = lifecycle
    self.termination = termination
    decoder = try AnonymousCAFDecoder(
      snapshot: snapshot,
      onClose: { lifecycle.observe(.importedDecoderClosed(generation)) }
    )
    processingFormat = decoder.processingFormat
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
      lifecycle.observe(.importedSessionDeactivated(generation))
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
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
      [weak self, weak player] _ in
      lifecycle.observe(.importedCompletionReceived(generation))
      lifecycle.deliverImportedCompletion { [weak self, weak player] in
        lifecycle.observe(.importedCompletionDelivered(generation))
        guard let self, let player else { return }
        self.queue.async {
          self.bufferFinished(identifier, player: player)
        }
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
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var file: AVAudioFile?
  private var importedPlayback: BoundedImportedPlaybackSession?
  private var playbackLease: AnyObject?
  private var activeGeneration: UUID?
  private var terminationHandler: (@Sendable (PlaybackTermination) -> Void)?
  private let lifecycle: NativePlaybackLifecycleHooks

  init(lifecycle: NativePlaybackLifecycleHooks = .production) {
    self.lifecycle = lifecycle
    engine.attach(player)
  }

  func play(url: URL, retaining lease: AnyObject?, generation: UUID) throws {
    releasePlaybackResources()
    activeGeneration = generation
    do {
      let file = try AVAudioFile(forReading: url)
      engine.disconnectNodeOutput(player)
      engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
      player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) {
        [weak self] _ in
        guard let self else { return }
        self.lifecycle.observe(.recoveredCompletionReceived(generation))
        self.lifecycle.deliverRecoveredCompletion { [weak self] in
          Task { @MainActor [weak self] in
            guard let self else { return }
            self.lifecycle.observe(.recoveredCompletionDelivered(generation))
            guard self.activeGeneration == generation else { return }
            self.releasePlaybackResources(generation: generation)
            self.terminationHandler?(
              PlaybackTermination(generation: generation, outcome: .finished)
            )
          }
        }
      }
      try engine.start()
      player.play()
      self.file = file
      playbackLease = lease
    } catch {
      releasePlaybackResources(generation: generation)
      throw error
    }
  }

  func playImported(
    receipt serializedReceipt: String,
    retaining lease: AnyObject,
    generation: UUID
  ) async throws {
    try Task.checkCancellation()
    releasePlaybackResources()
    activeGeneration = generation
    do {
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
      let playback = try BoundedImportedPlaybackSession(
        snapshot: snapshot,
        generation: generation,
        lifecycle: lifecycle,
        termination: { [weak self] termination in
          Task { @MainActor [weak self] in
            guard let self, self.activeGeneration == termination.generation else { return }
            self.releasePlaybackResources(generation: termination.generation)
            self.terminationHandler?(termination)
          }
        }
      )
      engine.disconnectNodeOutput(player)
      engine.connect(player, to: engine.mainMixerNode, format: playback.processingFormat)
      try playback.prime(player: player)
      try engine.start()
      player.play()
      importedPlayback = playback
      playbackLease = lease
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

  private func releasePlaybackResources(generation: UUID? = nil) {
    if let generation, activeGeneration != generation { return }
    let releasingGeneration = activeGeneration
    activeGeneration = nil
    let playback = importedPlayback
    importedPlayback = nil
    PlaybackTeardownOrder.release(
      deactivateAndDrainImportedPlayback: { playback?.stop() },
      stopPlayer: {
        player.stop()
        lifecycle.observe(.playerStopped(releasingGeneration))
      },
      stopEngine: {
        engine.stop()
        lifecycle.observe(.engineStopped(releasingGeneration))
      }
    )
    file = nil
    playbackLease = nil
  }
}

enum RecoveredSessionPhase: Equatable, Sendable {
  case scanning
  case none
  case available
  case failed
}

struct RecoveredPlaybackMediaIdentity: Equatable, Sendable {
  let sessionId: String
  let sourceId: String
  let trackId: String
  let segmentId: String

  init(_ session: NativeRecoveredPlayableSession) {
    sessionId = session.sessionId
    sourceId = session.sourceId
    trackId = session.trackId
    segmentId = session.segmentId
  }
}

private enum RecoveredSessionError: Error {
  case managedRootUnavailable
  case invalidEvidence
}

@MainActor
final class RecoveredSessionController: ObservableObject {
  typealias RecoveryFactory = @Sendable () throws -> PlayableSessionRecovering
  typealias ImportedPlaybackLeaseProvider =
    @Sendable (String) throws -> ImportedPlaybackLeaseHolding
  typealias PlaybackTerminationDecisionObserver = @Sendable (UUID, Bool) -> Void

  @Published private(set) var phase: RecoveredSessionPhase = .scanning
  @Published private(set) var sessions: [NativeRecoveredPlayableSession] = []
  @Published private(set) var activePlaybackSessionId: String?
  @Published private(set) var playingSessionId: String?
  @Published private(set) var playingRecoveredMediaIdentity: RecoveredPlaybackMediaIdentity?
  @Published private(set) var errorMessage: String?
  @Published private(set) var errorSessionId: String?
  @Published private(set) var errorRecoveredMediaIdentity: RecoveredPlaybackMediaIdentity?

  private let recoveryFactory: RecoveryFactory
  private let importedPlaybackLeaseProvider: ImportedPlaybackLeaseProvider
  private let player: RecoveredAudioPlaying
  private let playbackTerminationDecisionObserver: PlaybackTerminationDecisionObserver
  private var importedPlaybackTask: Task<Void, Never>?
  private var activePlaybackGeneration: UUID?

  init(
    recoveryFactory: @escaping RecoveryFactory,
    importedPlaybackLeaseProvider: @escaping ImportedPlaybackLeaseProvider = { _ in
      throw RecoveredSessionError.managedRootUnavailable
    },
    player: RecoveredAudioPlaying,
    playbackTerminationDecisionObserver: @escaping PlaybackTerminationDecisionObserver = { _, _ in }
  ) {
    self.recoveryFactory = recoveryFactory
    self.importedPlaybackLeaseProvider = importedPlaybackLeaseProvider
    self.player = player
    self.playbackTerminationDecisionObserver = playbackTerminationDecisionObserver
    player.setPlaybackTerminationHandler { [weak self] termination in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let isActive = self.activePlaybackGeneration == termination.generation
        self.playbackTerminationDecisionObserver(termination.generation, isActive)
        guard isActive else { return }
        let failedSessionId = self.activePlaybackSessionId
        let failedRecoveredIdentity = self.playingRecoveredMediaIdentity
        self.activePlaybackGeneration = nil
        self.importedPlaybackTask = nil
        self.activePlaybackSessionId = nil
        self.playingSessionId = nil
        self.playingRecoveredMediaIdentity = nil
        if case .failed = termination.outcome {
          self.setPlaybackError(
            failedRecoveredIdentity == nil
              ? "Imported audio playback stopped because decoding failed."
              : "Recovered audio playback stopped because decoding failed.",
            sessionId: failedSessionId,
            recoveredMediaIdentity: failedRecoveredIdentity
          )
        }
      }
    }
  }

  convenience init(managedRoot: URL?) {
    self.init(
      recoveryFactory: {
        guard let managedRoot else {
          throw RecoveredSessionError.managedRootUnavailable
        }
        return try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        guard let managedRoot else {
          throw RecoveredSessionError.managedRootUnavailable
        }
        let preparation = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
        return try preparation.leaseImportedPlayback(sessionId: sessionId)
      },
      player: RecoveredAudioPlayer()
    )
  }

  func recoverOnLaunch() {
    if playingSessionId != nil || activePlaybackGeneration != nil {
      stopPlayback()
    }
    phase = .scanning
    clearPlaybackError()
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
      errorSessionId = nil
      errorRecoveredMediaIdentity = nil
      phase = .failed
    }
  }

  func play(_ session: NativeRecoveredPlayableSession) {
    guard session.readyForReview, session.mediaPreserved, !session.recordingStarted else { return }
    stopPlayback()
    let generation = UUID()
    activePlaybackGeneration = generation
    activePlaybackSessionId = session.sessionId
    clearPlaybackError()
    do {
      try player.play(
        url: URL(fileURLWithPath: session.absolutePath, isDirectory: false),
        retaining: nil,
        generation: generation
      )
      playingSessionId = session.sessionId
      playingRecoveredMediaIdentity = RecoveredPlaybackMediaIdentity(session)
    } catch {
      guard activePlaybackGeneration == generation else { return }
      activePlaybackGeneration = nil
      activePlaybackSessionId = nil
      playingSessionId = nil
      playingRecoveredMediaIdentity = nil
      setPlaybackError(
        "Recovered audio could not be opened for playback.",
        sessionId: session.sessionId,
        recoveredMediaIdentity: RecoveredPlaybackMediaIdentity(session)
      )
    }
  }

  func play(_ session: RuntimeSessionPresentation) {
    stopPlayback()
    clearPlaybackError()
    guard let media = session.playableMedia else {
      setPlaybackError(
        "This saved conversation has no confirmed playable local audio.",
        sessionId: session.sessionId
      )
      return
    }
    guard media.isPlayable else {
      setPlaybackError(
        media.availability == "corrupt"
          ? "Imported audio appears corrupt and was not opened."
          : "Imported audio is unavailable and was not opened.",
        sessionId: session.sessionId
      )
      return
    }
    guard media.byteLength <= ImportedPlaybackMemoryPolicy.maximumSnapshotByteLength else {
      setPlaybackError(
        "Imported audio is too large for safe playback on this version of Open Scribe.",
        sessionId: session.sessionId
      )
      return
    }
    do {
      let lease = try importedPlaybackLeaseProvider(session.sessionId)
      let generation = UUID()
      activePlaybackGeneration = generation
      activePlaybackSessionId = session.sessionId
      importedPlaybackTask = Task { [weak self] in
        guard let self else { return }
        do {
          try await self.player.playImported(
            receipt: lease.playbackPath(),
            retaining: lease,
            generation: generation
          )
          guard self.activePlaybackGeneration == generation else { return }
          self.importedPlaybackTask = nil
          self.playingSessionId = session.sessionId
          self.clearPlaybackError()
        } catch is CancellationError {
          guard self.activePlaybackGeneration == generation else { return }
          self.player.stop()
          self.activePlaybackGeneration = nil
          self.importedPlaybackTask = nil
          self.activePlaybackSessionId = nil
          self.playingSessionId = nil
          self.playingRecoveredMediaIdentity = nil
        } catch ImportedPlaybackError.unsupportedByteLength {
          guard self.activePlaybackGeneration == generation else { return }
          self.player.stop()
          self.activePlaybackGeneration = nil
          self.importedPlaybackTask = nil
          self.activePlaybackSessionId = nil
          self.playingSessionId = nil
          self.playingRecoveredMediaIdentity = nil
          self.setPlaybackError(
            "Imported audio is too large for safe playback on this version of Open Scribe.",
            sessionId: session.sessionId
          )
        } catch {
          guard self.activePlaybackGeneration == generation else { return }
          self.player.stop()
          self.activePlaybackGeneration = nil
          self.importedPlaybackTask = nil
          self.activePlaybackSessionId = nil
          self.playingSessionId = nil
          self.playingRecoveredMediaIdentity = nil
          self.setPlaybackError(
            "Imported audio could not be opened for playback.",
            sessionId: session.sessionId
          )
        }
      }
    } catch {
      setPlaybackError(
        "Imported audio could not be opened for playback.",
        sessionId: session.sessionId
      )
    }
  }

  func stopPlayback() {
    importedPlaybackTask?.cancel()
    importedPlaybackTask = nil
    activePlaybackGeneration = nil
    activePlaybackSessionId = nil
    playingRecoveredMediaIdentity = nil
    player.stop()
    playingSessionId = nil
  }

  private func setPlaybackError(
    _ message: String,
    sessionId: String?,
    recoveredMediaIdentity: RecoveredPlaybackMediaIdentity? = nil
  ) {
    errorMessage = message
    errorSessionId = sessionId
    errorRecoveredMediaIdentity = recoveredMediaIdentity
  }

  private func clearPlaybackError() {
    errorMessage = nil
    errorSessionId = nil
    errorRecoveredMediaIdentity = nil
  }
}
