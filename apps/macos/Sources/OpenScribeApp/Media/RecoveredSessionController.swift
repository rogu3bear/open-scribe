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
  func playImported(receipt: String, retaining lease: AnyObject, generation: UUID) async throws
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

struct RecoveredPlaybackDescriptorReceipt: Equatable, Sendable {
  static let chunkByteLength: UInt64 = 64 * 1024

  let fileDescriptor: Int32
  let byteLength: UInt64
  let digestSha256: String

  init(serialized: String) throws {
    let parts = serialized.split(separator: ";", omittingEmptySubsequences: false)
    guard parts.first == "v2" else {
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
      byteLength <= UInt64(Int64.max),
      let digest = fields["sha256"],
      digest.count == 64,
      digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
      fields["chunk_byte_length"] == String(Self.chunkByteLength)
    else {
      throw ImportedPlaybackError.invalidDescriptorReceipt
    }
    fileDescriptor = descriptor
    self.byteLength = byteLength
    digestSha256 = digest
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

protocol CallbackAudioByteSource: AnyObject, Sendable {
  var callbackByteCount: Int64 { get }
  func copyBytes(
    position: Int64,
    requestedCount: UInt32,
    buffer: UnsafeMutableRawPointer,
    actualCount: UnsafeMutablePointer<UInt32>
  ) -> OSStatus
}

final class AnonymousPlaybackRegion: CallbackAudioByteSource, @unchecked Sendable {
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

  var callbackByteCount: Int64 { Int64(byteCount) }

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

struct PlaybackDescriptorIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let byteLength: UInt64
}

final class VerifiedDescriptorPlaybackSource: CallbackAudioByteSource, @unchecked Sendable {
  typealias Inspector = @Sendable (Int32) throws -> PlaybackDescriptorIdentity
  typealias PositionalRead =
    @Sendable (
      _ descriptor: Int32,
      _ offset: UInt64,
      _ buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int

  static let maximumBufferedByteCount = Int(RecoveredPlaybackDescriptorReceipt.chunkByteLength)

  let callbackByteCount: Int64

  private let descriptor: Int32
  private let identity: PlaybackDescriptorIdentity
  private let chunkDigests: [Data]
  private let inspect: Inspector
  private let readAt: PositionalRead

  static func prepare(
    receipt: RecoveredPlaybackDescriptorReceipt,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> VerifiedDescriptorPlaybackSource {
    try prepare(
      receipt: receipt,
      inspect: systemInspect,
      readAt: systemRead,
      isCancelled: isCancelled
    )
  }

  static func prepare(
    receipt: RecoveredPlaybackDescriptorReceipt,
    inspect: @escaping Inspector,
    readAt: @escaping PositionalRead,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> VerifiedDescriptorPlaybackSource {
    let initialIdentity = try inspect(receipt.fileDescriptor)
    guard initialIdentity.byteLength == receipt.byteLength else {
      throw ImportedPlaybackError.changedSnapshot
    }
    var fullHasher = SHA256()
    var chunkDigests: [Data] = []
    var offset: UInt64 = 0
    while offset < receipt.byteLength {
      if isCancelled() { throw CancellationError() }
      let requested = Int(
        min(RecoveredPlaybackDescriptorReceipt.chunkByteLength, receipt.byteLength - offset)
      )
      var chunk = Data(count: requested)
      let count = try chunk.withUnsafeMutableBytes { buffer in
        try readAt(receipt.fileDescriptor, offset, buffer)
      }
      guard count == requested else { throw ImportedPlaybackError.incompleteSnapshot }
      fullHasher.update(data: chunk)
      chunkDigests.append(Data(SHA256.hash(data: chunk)))
      offset += UInt64(count)
    }
    var trailingByte: UInt8 = 0
    let trailingCount = try withUnsafeMutableBytes(of: &trailingByte) { buffer in
      try readAt(receipt.fileDescriptor, receipt.byteLength, buffer)
    }
    let finalIdentity = try inspect(receipt.fileDescriptor)
    let digest = fullHasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard
      trailingCount == 0,
      finalIdentity == initialIdentity,
      digest == receipt.digestSha256
    else {
      throw ImportedPlaybackError.changedSnapshot
    }
    return VerifiedDescriptorPlaybackSource(
      receipt: receipt,
      identity: initialIdentity,
      chunkDigests: chunkDigests,
      inspect: inspect,
      readAt: readAt
    )
  }

  init(
    receipt: RecoveredPlaybackDescriptorReceipt,
    identity: PlaybackDescriptorIdentity,
    chunkDigests: [Data],
    inspect: @escaping Inspector,
    readAt: @escaping PositionalRead
  ) {
    descriptor = receipt.fileDescriptor
    self.identity = identity
    self.chunkDigests = chunkDigests
    self.inspect = inspect
    self.readAt = readAt
    callbackByteCount = Int64(receipt.byteLength)
  }

  func copyBytes(
    position: Int64,
    requestedCount: UInt32,
    buffer: UnsafeMutableRawPointer,
    actualCount: UnsafeMutablePointer<UInt32>
  ) -> OSStatus {
    guard position >= 0 else { return kAudioFilePositionError }
    let start = UInt64(position)
    let byteLength = UInt64(callbackByteCount)
    guard start <= byteLength else { return kAudioFilePositionError }
    let requested = min(UInt64(requestedCount), byteLength - start)
    guard requested > 0 else {
      actualCount.pointee = 0
      return noErr
    }
    do {
      guard try inspect(descriptor) == identity else {
        throw ImportedPlaybackError.changedSnapshot
      }
      var copied: UInt64 = 0
      while copied < requested {
        let absoluteOffset = start + copied
        let chunkIndex = Int(absoluteOffset / RecoveredPlaybackDescriptorReceipt.chunkByteLength)
        let chunkStart = UInt64(chunkIndex) * RecoveredPlaybackDescriptorReceipt.chunkByteLength
        let chunkLength = Int(
          min(RecoveredPlaybackDescriptorReceipt.chunkByteLength, byteLength - chunkStart)
        )
        guard chunkDigests.indices.contains(chunkIndex) else {
          throw ImportedPlaybackError.changedSnapshot
        }
        var chunk = Data(count: chunkLength)
        let count = try chunk.withUnsafeMutableBytes { bytes in
          try readAt(descriptor, chunkStart, bytes)
        }
        guard count == chunkLength, Data(SHA256.hash(data: chunk)) == chunkDigests[chunkIndex]
        else {
          throw ImportedPlaybackError.changedSnapshot
        }
        let offsetInChunk = Int(absoluteOffset - chunkStart)
        let copyCount = min(Int(requested - copied), chunkLength - offsetInChunk)
        chunk.withUnsafeBytes { bytes in
          buffer.advanced(by: Int(copied)).copyMemory(
            from: bytes.baseAddress!.advanced(by: offsetInChunk),
            byteCount: copyCount
          )
        }
        copied += UInt64(copyCount)
      }
      guard try inspect(descriptor) == identity else {
        throw ImportedPlaybackError.changedSnapshot
      }
      actualCount.pointee = UInt32(copied)
      return noErr
    } catch {
      actualCount.pointee = 0
      return kAudioFilePositionError
    }
  }

  private static func systemInspect(_ descriptor: Int32) throws -> PlaybackDescriptorIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
      throw ImportedPlaybackError.changedSnapshot
    }
    guard metadata.st_size >= 0 else { throw ImportedPlaybackError.changedSnapshot }
    return PlaybackDescriptorIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      byteLength: UInt64(metadata.st_size)
    )
  }

  private static func systemRead(
    descriptor: Int32,
    offset: UInt64,
    buffer: UnsafeMutableRawBufferPointer
  ) throws -> Int {
    guard let baseAddress = buffer.baseAddress else { return 0 }
    while true {
      let count = pread(descriptor, baseAddress, buffer.count, off_t(offset))
      if count >= 0 { return count }
      if errno != EINTR {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
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

final class CallbackAudioFileContext: @unchecked Sendable {
  let source: any CallbackAudioByteSource

  init(source: any CallbackAudioByteSource) {
    self.source = source
  }

  func read(
    position: Int64,
    requestedCount: UInt32,
    buffer: UnsafeMutableRawPointer,
    actualCount: UnsafeMutablePointer<UInt32>
  ) -> OSStatus {
    source.copyBytes(
      position: position,
      requestedCount: requestedCount,
      buffer: buffer,
      actualCount: actualCount
    )
  }
}

private let callbackAudioFileRead: AudioFile_ReadProc = {
  clientData, position, requestedCount, buffer, actualCount in
  let context = Unmanaged<CallbackAudioFileContext>.fromOpaque(clientData)
    .takeUnretainedValue()
  return context.read(
    position: position,
    requestedCount: requestedCount,
    buffer: buffer,
    actualCount: actualCount
  )
}

private let callbackAudioFileSize: AudioFile_GetSizeProc = { clientData in
  let context = Unmanaged<CallbackAudioFileContext>.fromOpaque(clientData)
    .takeUnretainedValue()
  return context.source.callbackByteCount
}

final class CallbackCAFDecoder: @unchecked Sendable {
  let processingFormat: AVAudioFormat

  private let context: CallbackAudioFileContext
  private let fileFormatSummary: ImportedPlaybackAudioFormatSummary
  private let clientFormatSummary: ImportedPlaybackAudioFormatSummary
  private let initialFramePositionStatus: OSStatus
  private let initialFramePosition: Int64?
  private let onClose: @Sendable () -> Void
  private var audioFile: AudioFileID?
  private var extendedAudioFile: ExtAudioFileRef?
  private var hasProducedFrames = false

  init(
    source: any CallbackAudioByteSource,
    onClose: @escaping @Sendable () -> Void
  ) throws {
    let context = CallbackAudioFileContext(source: source)
    var openedAudioFile: AudioFileID?
    var status = AudioFileOpenWithCallbacks(
      Unmanaged.passUnretained(context).toOpaque(),
      callbackAudioFileRead,
      nil,
      callbackAudioFileSize,
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
    kind: CallbackPlaybackKind,
    generation: UUID,
    lifecycle: NativePlaybackLifecycleHooks,
    termination: @escaping @Sendable (PlaybackTermination) -> Void
  ) throws {
    self.generation = generation
    self.kind = kind
    self.lifecycle = lifecycle
    self.termination = termination
    decoder = try CallbackCAFDecoder(
      source: source,
      onClose: {
        lifecycle.observe(
          kind == .imported
            ? .importedDecoderClosed(generation)
            : .recoveredDecoderClosed(generation)
        )
      }
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
    generation: UUID
  ) async throws {
    try Task.checkCancellation()
    releasePlaybackResources()
    activeGeneration = generation
    generationCell.set(generation)
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
      try beginCallbackPlayback(
        source: snapshot.region,
        kind: .imported,
        retaining: lease,
        generation: generation
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
    kind: CallbackPlaybackKind,
    retaining lease: AnyObject,
    generation: UUID
  ) throws {
    let playback = try BoundedCallbackPlaybackSession(
      source: source,
      kind: kind,
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

enum RecoveredSessionPhase: Equatable, Sendable {
  case scanning
  case none
  case available
  case failed
}

enum RecoveredPlaybackStartupState: Equatable, Sendable {
  case pending
  case playing
  case failed
  case superseded
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

private struct RecoveredPlaybackStartupRecord {
  let identity: RecoveredPlaybackMediaIdentity
  var state: RecoveredPlaybackStartupState
}

private enum RecoveredSessionError: Error {
  case managedRootUnavailable
  case invalidEvidence
}

@MainActor
final class RecoveredSessionController: ObservableObject {
  private static let maximumRecoveredPlaybackStartupRecords = 8

  typealias RecoveryFactory = @Sendable () throws -> PlayableSessionRecovering
  typealias ImportedPlaybackLeaseProvider =
    @Sendable (String) throws -> ImportedPlaybackLeaseHolding
  typealias RecoveredPlaybackLeaseProvider =
    @Sendable (RecoveredPlaybackMediaIdentity) throws -> ImportedPlaybackLeaseHolding
  typealias PlaybackTerminationDecisionObserver = @Sendable (UUID, Bool) -> Void

  @Published private(set) var phase: RecoveredSessionPhase = .scanning
  @Published private(set) var sessions: [NativeRecoveredPlayableSession] = []
  @Published private(set) var activePlaybackSessionId: String?
  @Published private(set) var playingSessionId: String?
  @Published private(set) var timelineClockAdjustmentNanoseconds: Int64 = 0
  @Published private(set) var pendingRecoveredMediaIdentity: RecoveredPlaybackMediaIdentity?
  @Published private(set) var playingRecoveredMediaIdentity: RecoveredPlaybackMediaIdentity?
  @Published private(set) var errorMessage: String?
  @Published private(set) var errorSessionId: String?
  @Published private(set) var errorRecoveredMediaIdentity: RecoveredPlaybackMediaIdentity?

  private let recoveryFactory: RecoveryFactory
  private let importedPlaybackLeaseProvider: ImportedPlaybackLeaseProvider
  private let recoveredPlaybackLeaseProvider: RecoveredPlaybackLeaseProvider
  private let player: RecoveredAudioPlaying
  private let timelineProvider: (@Sendable (String) throws -> [NativeTimelineSegment])?
  private let timelinePlayer = TimelineAudioPlayer()
  private let playbackTerminationDecisionObserver: PlaybackTerminationDecisionObserver
  private var playbackTask: Task<Void, Never>?
  private var activePlaybackGeneration: UUID?
  private var recoveredPlaybackStartupRecords: [UUID: RecoveredPlaybackStartupRecord] = [:]
  private var recoveredPlaybackStartupOrder: [UUID] = []

  init(
    recoveryFactory: @escaping RecoveryFactory,
    importedPlaybackLeaseProvider: @escaping ImportedPlaybackLeaseProvider = { _ in
      throw RecoveredSessionError.managedRootUnavailable
    },
    recoveredPlaybackLeaseProvider: @escaping RecoveredPlaybackLeaseProvider = { _ in
      throw RecoveredSessionError.managedRootUnavailable
    },
    player: RecoveredAudioPlaying,
    timelineProvider: (@Sendable (String) throws -> [NativeTimelineSegment])? = nil,
    playbackTerminationDecisionObserver: @escaping PlaybackTerminationDecisionObserver = { _, _ in }
  ) {
    self.recoveryFactory = recoveryFactory
    self.importedPlaybackLeaseProvider = importedPlaybackLeaseProvider
    self.recoveredPlaybackLeaseProvider = recoveredPlaybackLeaseProvider
    self.player = player
    self.timelineProvider = timelineProvider
    self.playbackTerminationDecisionObserver = playbackTerminationDecisionObserver
    player.setPlaybackTerminationHandler { [weak self] termination in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let isActive = self.activePlaybackGeneration == termination.generation
        self.playbackTerminationDecisionObserver(termination.generation, isActive)
        guard isActive else { return }
        let failedSessionId = self.activePlaybackSessionId
        let failedRecoveredIdentity =
          self.playingRecoveredMediaIdentity ?? self.pendingRecoveredMediaIdentity
        let startupState: RecoveredPlaybackStartupState =
          switch termination.outcome {
          case .finished: .playing
          case .failed, .outputRouteChanged: .failed
          }
        self.settleRecoveredPlaybackStartup(
          generation: termination.generation,
          state: startupState
        )
        self.activePlaybackGeneration = nil
        self.playbackTask = nil
        self.activePlaybackSessionId = nil
        self.playingSessionId = nil
        self.pendingRecoveredMediaIdentity = nil
        self.playingRecoveredMediaIdentity = nil
        if termination.outcome != .finished {
          let playbackErrorMessage =
            switch termination.outcome {
            case .finished:
              ""
            case .failed:
              failedRecoveredIdentity == nil
                ? "Saved audio playback stopped because decoding failed."
                : "Recovered audio playback stopped because decoding failed."
            case .outputRouteChanged:
              "Playback stopped because the audio output changed. Press Play to restart."
            }
          self.setPlaybackError(
            playbackErrorMessage,
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
      recoveredPlaybackLeaseProvider: { identity in
        guard let managedRoot else {
          throw RecoveredSessionError.managedRootUnavailable
        }
        let preparation = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
        return try preparation.leaseRecoveredPlayback(
          sessionId: identity.sessionId,
          sourceId: identity.sourceId,
          trackId: identity.trackId,
          segmentId: identity.segmentId
        )
      },
      player: RecoveredAudioPlayer(),
      timelineProvider: { sessionId in
        guard let managedRoot else { throw RecoveredSessionError.managedRootUnavailable }
        return try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
          .playbackTimeline(sessionId: sessionId)
      }
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

  @discardableResult
  func play(_ session: NativeRecoveredPlayableSession) -> UUID? {
    guard session.readyForReview, session.mediaPreserved, !session.recordingStarted else {
      return nil
    }
    stopPlayback()
    let identity = RecoveredPlaybackMediaIdentity(session)
    let generation = UUID()
    beginRecoveredPlaybackStartup(generation: generation, identity: identity)
    activePlaybackGeneration = generation
    activePlaybackSessionId = session.sessionId
    pendingRecoveredMediaIdentity = identity
    clearPlaybackError()
    let leaseProvider = recoveredPlaybackLeaseProvider
    playbackTask = Task { [weak self] in
      guard let self else { return }
      do {
        let lease = try await StructuredImportedPlaybackCopy.run { isCancelled in
          if isCancelled() { throw CancellationError() }
          let lease = try leaseProvider(identity)
          if isCancelled() { throw CancellationError() }
          return lease
        }
        try Task.checkCancellation()
        guard self.activePlaybackGeneration == generation else { return }
        try await self.player.playRecovered(
          receipt: lease.playbackPath(),
          retaining: lease,
          generation: generation
        )
        guard self.activePlaybackGeneration == generation else { return }
        self.settleRecoveredPlaybackStartup(generation: generation, state: .playing)
        self.playbackTask = nil
        self.playingSessionId = session.sessionId
        self.pendingRecoveredMediaIdentity = nil
        self.playingRecoveredMediaIdentity = identity
        self.clearPlaybackError()
      } catch is CancellationError {
        self.finishCancelledPlayback(generation: generation)
      } catch {
        guard self.activePlaybackGeneration == generation else { return }
        self.settleRecoveredPlaybackStartup(generation: generation, state: .failed)
        self.player.stop()
        self.activePlaybackGeneration = nil
        self.playbackTask = nil
        self.activePlaybackSessionId = nil
        self.playingSessionId = nil
        self.pendingRecoveredMediaIdentity = nil
        self.playingRecoveredMediaIdentity = nil
        self.setPlaybackError(
          "Recovered audio could not be opened for playback.",
          sessionId: session.sessionId,
          recoveredMediaIdentity: identity
        )
      }
    }
    return generation
  }

  func playbackStartupState(
    generation: UUID,
    identity: RecoveredPlaybackMediaIdentity
  ) -> RecoveredPlaybackStartupState? {
    guard let record = recoveredPlaybackStartupRecords[generation], record.identity == identity
    else {
      return nil
    }
    return record.state
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
          ? "Saved audio appears corrupt and was not opened."
          : "Saved audio is unavailable and was not opened.",
        sessionId: session.sessionId
      )
      return
    }
    guard media.byteLength <= ImportedPlaybackMemoryPolicy.maximumSnapshotByteLength else {
      setPlaybackError(
        "Saved audio is too large for safe playback on this version of Open Scribe.",
        sessionId: session.sessionId
      )
      return
    }
    do {
      let lease = try importedPlaybackLeaseProvider(session.sessionId)
      let generation = UUID()
      activePlaybackGeneration = generation
      activePlaybackSessionId = session.sessionId
      playbackTask = Task { [weak self] in
        guard let self else { return }
        do {
          try await self.player.playImported(
            receipt: lease.playbackPath(),
            retaining: lease,
            generation: generation
          )
          guard self.activePlaybackGeneration == generation else { return }
          self.playbackTask = nil
          self.playingSessionId = session.sessionId
          self.clearPlaybackError()
        } catch is CancellationError {
          guard self.activePlaybackGeneration == generation else { return }
          self.finishCancelledPlayback(generation: generation)
        } catch ImportedPlaybackError.unsupportedByteLength {
          guard self.activePlaybackGeneration == generation else { return }
          self.player.stop()
          self.activePlaybackGeneration = nil
          self.playbackTask = nil
          self.activePlaybackSessionId = nil
          self.playingSessionId = nil
          self.pendingRecoveredMediaIdentity = nil
          self.playingRecoveredMediaIdentity = nil
          self.setPlaybackError(
            "Saved audio is too large for safe playback on this version of Open Scribe.",
            sessionId: session.sessionId
          )
        } catch {
          guard self.activePlaybackGeneration == generation else { return }
          self.player.stop()
          self.activePlaybackGeneration = nil
          self.playbackTask = nil
          self.activePlaybackSessionId = nil
          self.playingSessionId = nil
          self.pendingRecoveredMediaIdentity = nil
          self.playingRecoveredMediaIdentity = nil
          self.setPlaybackError(
            "Saved audio could not be opened for playback.",
            sessionId: session.sessionId
          )
        }
      }
    } catch {
      setPlaybackError(
        "Saved audio could not be opened for playback.",
        sessionId: session.sessionId
      )
    }
  }

  func playSynchronized(sessionId: String) {
    stopPlayback()
    clearPlaybackError()
    guard let timelineProvider else {
      setPlaybackError("Synchronized playback is unavailable.", sessionId: sessionId)
      return
    }
    let generation = UUID()
    activePlaybackGeneration = generation
    activePlaybackSessionId = sessionId
    playbackTask = Task { [weak self] in
      guard let self else { return }
      do {
        let segments = try await StructuredImportedPlaybackCopy.run { isCancelled in
          if isCancelled() { throw CancellationError() }
          let result = try timelineProvider(sessionId)
          if isCancelled() { throw CancellationError() }
          return result
        }
        try Task.checkCancellation()
        guard self.activePlaybackGeneration == generation else { return }
        try self.timelinePlayer.play(segments: segments, generation: generation) {
          [weak self] termination in
          Task { @MainActor [weak self] in
            guard let self, self.activePlaybackGeneration == termination.generation else { return }
            self.stopPlayback(generation: termination.generation)
            if termination.outcome != .finished {
              self.setPlaybackError(
                "Synchronized playback stopped. Check the audio output and try again.",
                sessionId: sessionId)
            }
          }
        }
        self.timelineClockAdjustmentNanoseconds =
          segments.map(\.clockAdjustmentNanoseconds).max() ?? 0
        self.playingSessionId = sessionId
        self.playbackTask = nil
      } catch {
        guard self.activePlaybackGeneration == generation else { return }
        self.stopPlayback(generation: generation)
        if !(error is CancellationError) {
          self.setPlaybackError(
            "A synchronized timeline could not be verified. Older recordings may have no shared clock.",
            sessionId: sessionId)
        }
      }
    }
  }

  func stopPlayback(generation: UUID? = nil) {
    if let generation, activePlaybackGeneration != generation { return }
    if let activePlaybackGeneration {
      settleRecoveredPlaybackStartup(
        generation: activePlaybackGeneration,
        state: .superseded
      )
    }
    playbackTask?.cancel()
    playbackTask = nil
    activePlaybackGeneration = nil
    activePlaybackSessionId = nil
    pendingRecoveredMediaIdentity = nil
    playingRecoveredMediaIdentity = nil
    player.stop()
    timelinePlayer.stop()
    timelineClockAdjustmentNanoseconds = 0
    playingSessionId = nil
  }

  private func finishCancelledPlayback(generation: UUID) {
    guard activePlaybackGeneration == generation else { return }
    settleRecoveredPlaybackStartup(generation: generation, state: .superseded)
    player.stop()
    activePlaybackGeneration = nil
    playbackTask = nil
    activePlaybackSessionId = nil
    playingSessionId = nil
    pendingRecoveredMediaIdentity = nil
    playingRecoveredMediaIdentity = nil
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

  private func beginRecoveredPlaybackStartup(
    generation: UUID,
    identity: RecoveredPlaybackMediaIdentity
  ) {
    recoveredPlaybackStartupRecords[generation] = RecoveredPlaybackStartupRecord(
      identity: identity,
      state: .pending
    )
    recoveredPlaybackStartupOrder.append(generation)
    while recoveredPlaybackStartupOrder.count > Self.maximumRecoveredPlaybackStartupRecords {
      let evicted = recoveredPlaybackStartupOrder.removeFirst()
      recoveredPlaybackStartupRecords.removeValue(forKey: evicted)
    }
  }

  private func settleRecoveredPlaybackStartup(
    generation: UUID,
    state: RecoveredPlaybackStartupState
  ) {
    guard var record = recoveredPlaybackStartupRecords[generation], record.state == .pending else {
      return
    }
    record.state = state
    recoveredPlaybackStartupRecords[generation] = record
  }
}
