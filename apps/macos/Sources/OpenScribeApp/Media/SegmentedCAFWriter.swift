@preconcurrency import AVFoundation
import Darwin
import Foundation

/// One serial source writer. Conversion state survives file boundaries; only
/// segment open/first-sample/seal receipts cross the Rust boundary.
///
/// Threading: `writeCapturedBuffer` and `rotate` run on the adapter's serial
/// writer queue. The main actor reads `authorization`, `receipt()`,
/// `firstSampleReceipt`, and `sealSegmentReceipt` (storage watch, health
/// observations, stop), so the published segment identity, the accepted
/// first-sample receipts, and the last written host time live behind
/// `publishedLock`. Conversion and segment-fill counters stay queue-only.
final class SegmentedCAFWriter: ManagedSegmentWriting, @unchecked Sendable {
  static let segmentFrames: UInt64 = 30 * 48_000
  private let preparation: NativeRecordingPreparationProtocol
  private let makeSuccessor: @Sendable (NativeMediaOpenAuthorization) throws -> ManagedCAFWriter
  private let publishedLock = NSLock()
  private var current: ManagedCAFWriter
  private var acceptedFirstSamples: [NativeFirstSampleReceipt] = []
  private var acceptedFirstSampleEvidence: [String: NativeFirstSampleEvidence] = [:]
  private var lastEndHostTime: UInt64 = 0
  private var converter: AVAudioConverter?
  private let format = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false
  )!
  private var frames: UInt64 = 0
  private var currentHasFirstSample = false
  private var lastInputFormat: AVAudioFormat?

  var authorization: NativeMediaOpenAuthorization {
    publishedLock.withLock { current.authorization }
  }

  init(
    current: ManagedCAFWriter,
    preparation: NativeRecordingPreparationProtocol,
    makeSuccessor: @escaping @Sendable (NativeMediaOpenAuthorization) throws -> ManagedCAFWriter = {
      try ManagedCAFWriter(authorization: $0)
    }
  ) {
    self.current = current
    self.preparation = preparation
    self.makeSuccessor = makeSuccessor
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

  func receipt() throws -> NativeMediaOpenReceipt { try currentWriter().receipt() }

  /// The receipt of the segment whose accepted first sample begins at or before
  /// `hostTime`; a host time before every accepted sample names the first
  /// segment. Rust accepted every receipt here before it was published, and a
  /// receipt is never rewritten after a rotation.
  func firstSampleReceipt(hostTime: UInt64, frameCount: UInt64) throws -> NativeFirstSampleReceipt {
    let receipt = publishedLock.withLock {
      acceptedFirstSamples.last { $0.firstSampleHostTime <= hostTime } ?? acceptedFirstSamples.first
    }
    guard let receipt else { throw ManagedCAFWriterError.mediaAttributesUnavailable }
    return receipt
  }

  func acceptedFirstSampleEvidence(segmentId: String) -> NativeFirstSampleEvidence? {
    publishedLock.withLock { acceptedFirstSampleEvidence[segmentId] }
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
      let lastEnd = publishedLock.withLock { lastEndHostTime }
      if hostTime < lastEnd && lastEnd - hostTime > tolerance {
        throw ManagedCAFWriterError.unsupportedAuthorization
      }
      if (hostTime > lastEnd && hostTime - lastEnd > tolerance)
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
      let writer = currentWriter()
      let count = min(buffer.frameLength - offset, AVAudioFrameCount(Self.segmentFrames - frames))
      guard let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
        let destination = piece.int16ChannelData?[0], let source = buffer.int16ChannelData?[0]
      else { throw ManagedCAFWriterError.bufferAllocationFailed }
      piece.frameLength = count
      destination.update(from: source.advanced(by: Int(offset)), count: Int(count))
      let pieceHost = hostTime + AVAudioTime.hostTime(forSeconds: Double(offset) / 48_000)
      let written = try writer.writeCapturedBuffer(piece)
      frames += UInt64(written)
      let pieceEnd = pieceHost + AVAudioTime.hostTime(forSeconds: Double(written) / 48_000)
      publishedLock.withLock { lastEndHostTime = pieceEnd }
      if !currentHasFirstSample {
        let receipt = try writer.firstSampleReceipt(
          hostTime: pieceHost, frameCount: UInt64(written))
        let evidence = try preparation.acceptFirstSample(receipt: receipt)
        currentHasFirstSample = true
        publishedLock.withLock {
          acceptedFirstSamples.append(receipt)
          acceptedFirstSampleEvidence[receipt.segmentId] = evidence
        }
      }
      offset += count
    }
    return buffer.frameLength
  }

  func sealSegmentReceipt(finalSampleHostTime: UInt64) throws -> NativeSealSegmentReceipt {
    let (writer, end) = publishedLock.withLock { (current, lastEndHostTime) }
    return try writer.sealSegmentReceipt(finalSampleHostTime: end)
  }

  private func currentWriter() -> ManagedCAFWriter {
    publishedLock.withLock { current }
  }

  private func rotate() throws {
    let predecessor = currentWriter()
    let authorization = predecessor.authorization
    let storage = try preparation.recorderAction(sessionId: authorization.sessionId,
      action: .observeStorage(availableBytes: RecorderStorage.availableBytes(at: authorization.absolutePath)))
    guard storage.storageLevel != "critical" else { throw ManagedCAFWriterError.storagePressure }
    // Reserve/open successor first. A crash at any following step leaves an
    // independently journaled predecessor and an explicit successor identity.
    let next = try preparation.authorizeNextSegment(
      sessionId: authorization.sessionId, previousSegmentId: authorization.segmentId
    )
    do {
      let successor = try makeSuccessor(next)
      _ = try preparation.acceptMediaOpen(receipt: successor.receipt())
      let end = publishedLock.withLock { lastEndHostTime }
      let seal = try predecessor.sealSegmentReceipt(finalSampleHostTime: end)
      _ = try preparation.sealSegment(receipt: seal)
      publishedLock.withLock { current = successor }
      frames = 0
      currentHasFirstSample = false
    } catch {
      // The successor was reserved but never became a real segment. Abandon it
      // durably so the predecessor stays the active segment and a later seal can
      // finalize the session. Rust owns the lifecycle; the original error still
      // degrades or stops this source.
      try? preparation.abandonReservedSegment(
        sessionId: authorization.sessionId, segmentId: next.segmentId)
      throw error
    }
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
  func abandonReservedSegment(sessionId: String, segmentId: String) throws {
    throw ManagedCAFWriterError.unsupportedAuthorization
  }
}
