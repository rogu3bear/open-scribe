import Foundation

/// The Rust media-protocol steps of a capture span: authorize and open a
/// source's writer, then seal or abandon its segment. Each step checks Rust's
/// evidence before the recorder trusts the writer.
@MainActor
struct RecordingSpan {
  let preparation: NativeRecordingPreparationProtocol
  let environment: CaptureEnvironment

  /// The first segment of `source`, or the segment after `previous`.
  func authorize(
    _ source: NativeMediaSourceKind, sessionId: String, after previous: ManagedSegmentWriting?,
    displayName: String
  ) throws -> NativeMediaOpenAuthorization {
    if let previous {
      return try preparation.authorizeNextSegment(
        sessionId: sessionId, previousSegmentId: previous.authorization.segmentId)
    }
    return try preparation.authorizeInitialMedia(
      sessionId: sessionId, sourceKind: source, sourceDisplayName: displayName)
  }

  /// Opens the writer Rust authorized and accepts its media-open receipt.
  /// `allMediaOpen`, when given, is what Rust must report about the session's
  /// media once this writer is open.
  func openWriter(
    _ authorization: NativeMediaOpenAuthorization, allMediaOpen: Bool? = nil
  ) throws -> ManagedSegmentWriting {
    let writer = try environment.writerFactory(authorization)
    let mediaOpen = try preparation.acceptMediaOpen(receipt: writer.receipt())
    guard mediaOpen.journalDurable, !mediaOpen.recordingStarted,
      allMediaOpen.map({ mediaOpen.mediaFilesOpen == $0 }) ?? true
    else {
      throw LiveMicrophoneRecordingError.invalidMediaOpen
    }
    guard environment.segmentedCapture else { return writer }
    guard let nativeWriter = writer as? ManagedCAFWriter else {
      throw LiveMicrophoneRecordingError.invalidMediaOpen
    }
    return SegmentedCAFWriter(
      current: nativeWriter, preparation: preparation,
      makeSuccessor: environment.successorWriterFactory)
  }

  /// Seals `writer`'s current segment and checks that Rust closed it without
  /// starting a recording.
  func seal(
    _ writer: ManagedSegmentWriting, finalSampleHostTime: UInt64,
    reportsBoundary: Bool = false
  ) throws {
    let receipt = try writer.sealSegmentReceipt(finalSampleHostTime: finalSampleHostTime)
    if reportsBoundary {
      environment.observer?.recording(reached: .seal, sessionId: receipt.sessionId)
    }
    let evidence = try preparation.sealSegment(receipt: receipt)
    guard evidence.segmentSealed, !evidence.recordingStarted else {
      throw LiveMicrophoneRecordingError.invalidSegmentSeal
    }
  }

  /// Rust drops a reserved segment that never received a first sample; the
  /// source stays on its sealed media.
  func abandon(segmentId: String, sessionId: String) throws {
    try preparation.abandonReservedSegment(sessionId: sessionId, segmentId: segmentId)
  }
}
