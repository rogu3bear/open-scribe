@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// A buffer handed from the writer's queue to the caption queue and never
/// touched again by the sender.
private struct OwnedBuffer: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
  init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Live captions for one capture track with Apple's on-device speech
/// transcriber. Audio arrives already written; it is copied, converted off the
/// writer queue, and streamed to the analyzer with session-timeline times from
/// the track's clock. Nothing here can slow or stop capture: when the input
/// queue is full the newest caption audio is dropped and the next buffer
/// carries its own time, and recognizer errors end captions only.
@available(macOS 26.0, *)
final class LiveCaptionTranscriber: LiveAudioListening, @unchecked Sendable {
  enum Failure: Error {
    case noCompatibleFormat
  }

  /// Names the configuration in the Draft engine identity: volatile results
  /// biased for speed, with word time ranges.
  static let presetName = "timeIndexedFastProgressiveTranscription"

  let track: LiveCaptionTrack
  private let analyzer: SpeechAnalyzer
  private let transcriber: SpeechTranscriber
  private let targetFormat: AVAudioFormat
  private let continuation: AsyncStream<AnalyzerInput>.Continuation
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var accepting = true
  private var converter: AVAudioConverter?
  private var converterSource: AVAudioFormat?
  /// Where the analyzer's own timeline ends; nil until a buffer is sent or
  /// after one is dropped, so the next buffer states its time.
  private var analyzerEnd: Int64?
  private var resultsTask: Task<Void, Never>?
  /// Line identities stay unique when a resumed span reuses the track.
  private let spanToken = UUID().uuidString.prefix(8)
  /// A gap longer than this between consecutive buffers is stated explicitly.
  static let discontinuityNanoseconds: Int64 = 50_000_000

  /// The installed recognizer locale closest to `locale`, or nil when live
  /// captions cannot run without a download or on this Mac.
  static func installedLocale(closestTo locale: Locale) async -> Locale? {
    guard SpeechTranscriber.isAvailable else { return nil }
    let installed = await SpeechTranscriber.installedLocales
    if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
      installed.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) })
    {
      return supported
    }
    let language = locale.language.languageCode?.identifier
    return installed.first { $0.language.languageCode?.identifier == language }
  }

  static func make(
    track: LiveCaptionTrack, locale: Locale,
    onEvent: @escaping @Sendable (LiveCaptionTranscriberEvent) -> Void
  ) async throws -> LiveCaptionTranscriber {
    // Words appear as they are heard: volatile results biased for speed.
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [],
      reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    else { throw Failure.noCompatibleFormat }
    // The model stays loaded, so Resume and the next recording start at once.
    let analyzer = SpeechAnalyzer(
      modules: [transcriber],
      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
    try await analyzer.prepareToAnalyze(in: format)
    // Room for the audio held while the recognizer loaded plus normal flow.
    // When full, the newest is refused and reported, so the transcriber
    // knows to restate the next time.
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
      bufferingPolicy: .bufferingOldest(4_000))
    let instance = LiveCaptionTranscriber(
      track: track, analyzer: analyzer, transcriber: transcriber, targetFormat: format,
      continuation: continuation)
    instance.startResults(onEvent)
    try await analyzer.start(inputSequence: stream)
    return instance
  }

  private init(
    track: LiveCaptionTrack, analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber,
    targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation
  ) {
    self.track = track
    self.analyzer = analyzer
    self.transcriber = transcriber
    self.targetFormat = targetFormat
    self.continuation = continuation
    queue = DispatchQueue(
      label: "app.open-scribe.live-captions.\(track.source.rawValue)", qos: .userInitiated)
  }

  func receive(_ buffer: AVAudioPCMBuffer, writtenFrames: AVAudioFrameCount, hostTime: UInt64) {
    // Writers write whole buffers; `writtenFrames` counts output-format frames.
    guard lock.withLock({ accepting }),
      let start = track.clock.sessionNanoseconds(hostTime: hostTime),
      let copy = buffer.deepCopy()
    else { return }
    // The copy is owned by this hop alone; nothing else holds it.
    let owned = OwnedBuffer(copy)
    queue.async { [self] in convertAndYield(owned.buffer, start: start) }
  }

  /// Stops listening, settles the last phrase, and waits for its result.
  func finish() async {
    lock.withLock { accepting = false }
    await withCheckedContinuation { done in queue.async { done.resume() } }
    continuation.finish()
    do {
      try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
      await analyzer.cancelAndFinishNow()
    }
    await resultsTask?.value
  }

  func cancel() async {
    lock.withLock { accepting = false }
    continuation.finish()
    await analyzer.cancelAndFinishNow()
    resultsTask?.cancel()
  }

  private func convertAndYield(_ buffer: AVAudioPCMBuffer, start: Int64) {
    if converterSource != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: targetFormat)
      converterSource = buffer.format
    }
    guard let converter else { return }
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
      return
    }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, output.frameLength > 0 else { return }
    let duration = Int64(
      (Double(output.frameLength) / targetFormat.sampleRate * 1_000_000_000).rounded())
    // Contiguous audio continues the analyzer's timeline; the first buffer and
    // any buffer after a gap state their session time. Small clock jitter, or
    // a start before the analyzer's end, continues contiguously.
    let input: AnalyzerInput
    let begins: Int64
    if let end = analyzerEnd, start - end <= Self.discontinuityNanoseconds {
      input = AnalyzerInput(buffer: output)
      begins = end
    } else {
      input = AnalyzerInput(
        buffer: output, bufferStartTime: CMTime(value: start, timescale: 1_000_000_000))
      begins = start
    }
    if case .dropped = continuation.yield(input) {
      analyzerEnd = nil
    } else {
      analyzerEnd = begins + duration
    }
  }

  private func startResults(_ onEvent: @escaping @Sendable (LiveCaptionTranscriberEvent) -> Void) {
    let track = track
    let transcriber = transcriber
    resultsTask = Task {
      var settledCount = 0
      do {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { continue }
          let start = Self.nanoseconds(result.range.start)
          let end = max(start + 1, Self.nanoseconds(result.range.end))
          if result.isFinal {
            settledCount += 1
            let line = LiveCaptionLine(
              id: "\(track.trackId)-\(spanToken)-\(settledCount)", source: track.source,
              speaker: track.speaker, text: text, startNanoseconds: start,
              endNanoseconds: end, isFinal: true)
            let phrase = LiveCaptionPhrase(
              text: text, startNanoseconds: start, endNanoseconds: end,
              words: Self.words(in: result.text))
            onEvent(.settled(line, phrase))
          } else {
            onEvent(
              .volatile(
                LiveCaptionLine(
                  id: "\(track.trackId)-current", source: track.source, speaker: track.speaker,
                  text: text, startNanoseconds: start, endNanoseconds: end, isFinal: false)))
          }
        }
      } catch {
        // Captions end; the recording and its saved audio are unaffected.
      }
    }
  }

  static func words(in text: AttributedString) -> [LiveCaptionPhrase.Word] {
    var words: [LiveCaptionPhrase.Word] = []
    for run in text.runs {
      guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else {
        continue
      }
      let piece = String(text[run.range].characters)
      guard !piece.isEmpty else { continue }
      words.append(
        .init(
          text: piece, startNanoseconds: nanoseconds(range.start),
          endNanoseconds: nanoseconds(range.end)))
    }
    return words
  }

  static func nanoseconds(_ time: CMTime) -> Int64 {
    guard time.isValid, time.isNumeric else { return 0 }
    return Int64((time.seconds * 1_000_000_000).rounded())
  }
}
