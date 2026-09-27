@preconcurrency import AVFoundation
import Darwin
import Foundation

/// One serial source writer. Conversion state survives file boundaries; only
/// segment open/first-sample/seal receipts cross the Rust boundary.
final class SegmentedCAFWriter: ManagedSegmentWriting, @unchecked Sendable {
  static let segmentFrames: UInt64 = 30 * 48_000
  private let preparation: NativeRecordingPreparationProtocol
  private var current: ManagedCAFWriter
  private var converter: AVAudioConverter?
  private let format = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false
  )!
  private var frames: UInt64 = 0
  private var firstReceipt: NativeFirstSampleReceipt?
  private var lastEndHostTime: UInt64 = 0
  private var currentHasFirstSample = false
  private var lastInputFormat: AVAudioFormat?

  var authorization: NativeMediaOpenAuthorization { current.authorization }

  init(current: ManagedCAFWriter, preparation: NativeRecordingPreparationProtocol) {
    self.current = current
    self.preparation = preparation
  }

  static func anchor(
    preparation: NativeRecordingPreparationProtocol, sessionId: String,
    hostAnchor: UInt64 = mach_absolute_time()
  ) throws {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS else {
      throw ManagedCAFWriterError.unsupportedAuthorization
    }
    try preparation.anchorCaptureClock(
      sessionId: sessionId, hostAnchor: hostAnchor,
      numerator: info.numer, denominator: info.denom
    )
  }

  func receipt() throws -> NativeMediaOpenReceipt { try current.receipt() }

  func firstSampleReceipt(hostTime: UInt64, frameCount: UInt64) throws -> NativeFirstSampleReceipt {
    guard let firstReceipt else { throw ManagedCAFWriterError.mediaAttributesUnavailable }
    return firstReceipt
  }

  func writeCapturedBuffer(_ input: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
    // Timestamp-free writes would silently destroy synchronization.
    throw ManagedCAFWriterError.unsupportedAuthorization
  }

  func writeCapturedBuffer(_ input: AVAudioPCMBuffer, hostTime: UInt64) throws -> AVAudioFrameCount
  {
    guard hostTime > 0 else { throw ManagedCAFWriterError.unsupportedAuthorization }
    if frames > 0 {
      let tolerance = AVAudioTime.hostTime(forSeconds: 0.002)
      if hostTime < lastEndHostTime && lastEndHostTime - hostTime > tolerance {
        throw ManagedCAFWriterError.unsupportedAuthorization
      }
      if (hostTime > lastEndHostTime && hostTime - lastEndHostTime > tolerance)
        || lastInputFormat != input.format
      {
        try rotate()
      }
    }
    lastInputFormat = input.format
    let buffer = try normalize(input)
    guard buffer.frameLength > 0 else { return 0 }
    var offset: AVAudioFrameCount = 0
    while offset < buffer.frameLength {
      if frames == Self.segmentFrames { try rotate() }
      let count = min(buffer.frameLength - offset, AVAudioFrameCount(Self.segmentFrames - frames))
      guard let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
        let destination = piece.int16ChannelData?[0], let source = buffer.int16ChannelData?[0]
      else { throw ManagedCAFWriterError.bufferAllocationFailed }
      piece.frameLength = count
      destination.update(from: source.advanced(by: Int(offset)), count: Int(count))
      let pieceHost = hostTime + AVAudioTime.hostTime(forSeconds: Double(offset) / 48_000)
      let written = try current.writeCapturedBuffer(piece)
      frames += UInt64(written)
      lastEndHostTime = pieceHost + AVAudioTime.hostTime(forSeconds: Double(written) / 48_000)
      if !currentHasFirstSample {
        let receipt = try current.firstSampleReceipt(
          hostTime: pieceHost, frameCount: UInt64(written))
        _ = try preparation.acceptFirstSample(receipt: receipt)
        currentHasFirstSample = true
        if firstReceipt == nil { firstReceipt = receipt }
      }
      offset += count
    }
    return buffer.frameLength
  }

  func sealSegmentReceipt(finalSampleHostTime: UInt64) throws -> NativeSealSegmentReceipt {
    try current.sealSegmentReceipt(finalSampleHostTime: lastEndHostTime)
  }

  private func rotate() throws {
    let storage = try preparation.recorderAction(sessionId: authorization.sessionId,
      action: .observeStorage(availableBytes: RecorderStorage.availableBytes(at: authorization.absolutePath)))
    guard storage.storageLevel != "critical" else { throw ManagedCAFWriterError.storagePressure }
    // Reserve/open successor first. A crash at any following step leaves an
    // independently journaled predecessor and an explicit successor identity.
    let next = try preparation.authorizeNextSegment(
      sessionId: authorization.sessionId, previousSegmentId: authorization.segmentId
    )
    let successor = try ManagedCAFWriter(authorization: next)
    _ = try preparation.acceptMediaOpen(receipt: successor.receipt())
    let seal = try current.sealSegmentReceipt(finalSampleHostTime: lastEndHostTime)
    _ = try preparation.sealSegment(receipt: seal)
    current = successor
    frames = 0
    currentHasFirstSample = false
  }

  private func normalize(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    if input.format == format { return input }
    if converter?.inputFormat != input.format {
      converter = AVAudioConverter(from: input.format, to: format)
      converter?.primeMethod = .none
    }
    guard let converter,
      let output = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(
          ceil(Double(input.frameLength) * 48_000 / input.format.sampleRate)) + 1)
    else { throw ManagedCAFWriterError.conversionFailed }
    let supply = SegmentConverterInput(buffer: input)
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, state in supply.next(state) }
    guard error == nil, status == .haveData || status == .inputRanDry else {
      throw error ?? ManagedCAFWriterError.conversionFailed
    }
    return output
  }
}

private final class SegmentConverterInput: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
  private var supplied = false
  init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
  func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    guard !supplied else {
      state.pointee = .noDataNow
      return nil
    }
    supplied = true
    state.pointee = .haveData
    return buffer
  }
}

// Existing test doubles that exercise preparation alone deliberately have no
// clock/rotation authority. Production uses the generated concrete methods.
extension NativeRecordingPreparationProtocol {
  func anchorCaptureClock(
    sessionId: String, hostAnchor: UInt64, numerator: UInt32, denominator: UInt32
  ) throws {
    throw ManagedCAFWriterError.unsupportedAuthorization
  }
  func authorizeNextSegment(sessionId: String, previousSegmentId: String) throws
    -> NativeMediaOpenAuthorization
  {
    throw ManagedCAFWriterError.unsupportedAuthorization
  }
  func playbackTimeline(sessionId: String) throws -> [NativeTimelineSegment] {
    throw ManagedCAFWriterError.unsupportedAuthorization
  }
}
