@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Darwin
import Foundation

// Descriptor-verified byte sources and the callback decoder that bounded
// imported and recovered playback read from. Nothing here owns durable state.

enum ImportedPlaybackAudioFileOperation: String, Equatable, Sendable {
  case openCallbacks
  case wrapAudioFile
  case readFileDataFormat
  case setClientDataFormat
  case readFrames
  case seekFrames
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
  let fileTypeHint: AudioFileTypeID

  init(serialized: String) throws {
    let parts = serialized.split(separator: ";", omittingEmptySubsequences: false)
    guard parts.first == "v2" || parts.first == "v3" else {
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
      fields.count == (parts.first == "v3" ? 5 : 4),
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
      fields["chunk_byte_length"] == String(Self.chunkByteLength),
      parts.first == "v3" ? fields["format"] == "m4a" : fields["format"] == nil
    else {
      throw ImportedPlaybackError.invalidDescriptorReceipt
    }
    fileDescriptor = descriptor
    self.byteLength = byteLength
    digestSha256 = digest
    fileTypeHint = parts.first == "v3" ? kAudioFileM4AType : kAudioFileCAFType
    if parts.first == "v3", byteLength > nativeImportPolicy().maximumSourceBytes {
      throw ImportedPlaybackError.unsupportedByteLength
    }
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
      let chunkDigest = try autoreleasepool {
        var chunk = Data(count: requested)
        let count = try chunk.withUnsafeMutableBytes { buffer in
          try readAt(receipt.fileDescriptor, offset, buffer)
        }
        guard count == requested else { throw ImportedPlaybackError.incompleteSnapshot }
        fullHasher.update(data: chunk)
        return Data(SHA256.hash(data: chunk))
      }
      chunkDigests.append(chunkDigest)
      offset += UInt64(requested)
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
    fileTypeHint: AudioFileTypeID = kAudioFileCAFType,
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
      fileTypeHint,
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

  func seek(toFrame frame: Int64) throws {
    guard frame >= 0, let extendedAudioFile else {
      throw ImportedPlaybackError.unsupportedAudioFormat(.decoderUnavailable)
    }
    let status = ExtAudioFileSeek(extendedAudioFile, frame)
    guard status == noErr else {
      throw ImportedPlaybackError.audioFile(operation: .seekFrames, status: status)
    }
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
