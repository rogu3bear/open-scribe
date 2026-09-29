@preconcurrency import AVFoundation
import Foundation

enum TimelinePlaybackError: Error { case invalidPlan, incompleteSegment }

/// Bounded PCM rendering is shared by native output and device-free proof.
/// Rust's leased, validated source files remain authoritative; gaps render as silence.
final class TimelinePCMReader: @unchecked Sendable {
  static let sampleRate = 48_000.0
  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
  let totalFrames: Int64
  private struct Entry {
    let segment: NativeTimelineSegment
    let start: Int64
    let end: Int64
    var decoder: CallbackCAFDecoder?
    var lease: NativeImportedPlaybackLease?
  }
  private var entries: [Entry]
  private var position: Int64 = 0
  private let gain: Float

  init(segments: [NativeTimelineSegment]) throws {
    guard !segments.isEmpty else { throw TimelinePlaybackError.invalidPlan }
    let origin = min(0, segments.map(\.startNanoseconds).min()!)
    entries = try segments.map { segment in
      let startSeconds = (Double(segment.startNanoseconds) - Double(origin)) / 1_000_000_000
      guard startSeconds.isFinite, startSeconds >= 0, startSeconds < Double(Int64.max / 48_000),
        segment.sampleCount > 0, segment.sampleCount < UInt64(Int64.max / 2),
        segment.channels == 1 || segment.channels == 2
      else { throw TimelinePlaybackError.invalidPlan }
      let start = Int64((startSeconds * Self.sampleRate).rounded())
      let (end, overflow) = start.addingReportingOverflow(Int64(segment.sampleCount))
      guard !overflow else { throw TimelinePlaybackError.invalidPlan }
      return Entry(segment: segment, start: start, end: end)
    }
    totalFrames = entries.map(\.end).max()!
    gain = 1 / Float(Set(segments.map(\.trackId)).count)
  }

  func read(maximumFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
    guard position < totalFrames else { return nil }
    let count = AVAudioFrameCount(min(Int64(maximumFrames), totalFrames - position))
    guard count > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
      let samples = output.floatChannelData
    else { throw TimelinePlaybackError.invalidPlan }
    output.frameLength = count
    for channel in 0..<2 { samples[channel].update(repeating: 0, count: Int(count)) }
    let end = position + Int64(count)
    for index in entries.indices {
      let lower = max(position, entries[index].start)
      let upper = min(end, entries[index].end)
      guard lower < upper else { continue }
      if entries[index].decoder == nil {
        let lease = try entries[index].segment.media.lease()
        entries[index].lease = lease
        let receipt = try RecoveredPlaybackDescriptorReceipt(
          serialized: lease.playbackPath())
        let source = try VerifiedDescriptorPlaybackSource.prepare(
          receipt: receipt, isCancelled: { false })
        entries[index].decoder = try CallbackCAFDecoder(source: source, onClose: {})
      }
      guard let decoder = entries[index].decoder,
        decoder.processingFormat.sampleRate == Self.sampleRate,
        decoder.processingFormat.channelCount == AVAudioChannelCount(entries[index].segment.channels),
        let input = try decoder.read(maximumFrames: AVAudioFrameCount(upper - lower)),
        input.frameLength == AVAudioFrameCount(upper - lower),
        let source = input.floatChannelData
      else { throw TimelinePlaybackError.incompleteSegment }
      for frame in 0..<Int(input.frameLength) {
        let destination = Int(lower - position) + frame
        samples[0][destination] += source[0][frame] * gain
        samples[1][destination] += source[entries[index].segment.channels == 1 ? 0 : 1][frame] * gain
      }
      if upper == entries[index].end {
        decoder.close()
        entries[index].decoder = nil
        entries[index].lease = nil
      }
    }
    position = end
    return output
  }

  func close() {
    for entry in entries { entry.decoder?.close() }
    entries.removeAll()
    position = totalFrames
  }
  deinit { close() }
}

private final class TimelineBufferScheduler: @unchecked Sendable {
  private let queue = DispatchQueue(label: "app.open-scribe.timeline-playback")
  private let reader: TimelinePCMReader
  private let completion: @Sendable (PlaybackTerminationOutcome) -> Void
  private var buffers: [UUID: AVAudioPCMBuffer] = [:]
  private var active = true
  private var exhausted = false

  init(
    reader: TimelinePCMReader, completion: @escaping @Sendable (PlaybackTerminationOutcome) -> Void
  ) {
    self.reader = reader
    self.completion = completion
  }

  func prime(_ player: AVAudioPlayerNode) throws {
    try queue.sync {
      for _ in 0..<2 { _ = try schedule(player) }
      guard !buffers.isEmpty else { throw TimelinePlaybackError.invalidPlan }
    }
  }

  private func schedule(_ player: AVAudioPlayerNode) throws -> Bool {
    guard active, !exhausted else { return false }
    guard let buffer = try reader.read(maximumFrames: 16_384) else {
      exhausted = true
      return false
    }
    let id = UUID()
    buffers[id] = buffer
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
      [weak self, weak player] _ in
      guard let self, let player else { return }
      self.queue.async {
        guard self.active else { return }
        self.buffers.removeValue(forKey: id)
        do {
          _ = try self.schedule(player)
          if self.exhausted && self.buffers.isEmpty {
            self.active = false
            self.reader.close()
            self.completion(.finished)
          }
        } catch {
          self.active = false
          self.reader.close()
          self.completion(.failed)
        }
      }
    }
    return true
  }

  func stop() {
    queue.sync {
      active = false
      buffers.removeAll()
      reader.close()
    }
  }
}

@MainActor
final class TimelineAudioPlayer {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var scheduler: TimelineBufferScheduler?
  private var observer: NSObjectProtocol?
  private var generation: UUID?

  var isPlaying: Bool { player?.isPlaying == true && engine?.isRunning == true }

  func play(
    segments: [NativeTimelineSegment], generation: UUID,
    completion: @escaping @Sendable (PlaybackTermination) -> Void
  ) throws {
    stop()
    let reader = try TimelinePCMReader(segments: segments)
    let scheduler = TimelineBufferScheduler(reader: reader) { outcome in
      completion(PlaybackTermination(generation: generation, outcome: outcome))
    }
    // Hardware is opened only in this explicit Play path.
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: reader.format)
    self.engine = engine
    self.player = player
    self.scheduler = scheduler
    self.generation = generation
    do {
      try scheduler.prime(player)
      engine.prepare()
      try engine.start()
      observer = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: engine, queue: nil
      ) { _ in
        completion(PlaybackTermination(generation: generation, outcome: .outputRouteChanged))
      }
      player.play()
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    scheduler?.stop()
    player?.stop()
    engine?.stop()
    scheduler = nil
    player = nil
    engine = nil
    generation = nil
  }
}
