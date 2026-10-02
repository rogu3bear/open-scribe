@preconcurrency import AVFoundation
import AppKit
import Darwin
import Foundation

/// Explicit process proofs. Synthetic mode never opens a device; live recovery
/// renders recovered PCM before the separately authorized brief native playback.
enum TimelineRuntimeProof {
  struct Capture {
    let sessionId: String
    let writers: [SegmentedCAFWriter]
    let preparation: NativeRecordingPreparation
  }

  static func capture(root: URL) throws -> Capture {
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    let session = try preparation.prepareSessionWithRequiredSources(
      title: "Synthetic dual-source timeline proof", requiredSources: [.microphone, .systemAudio]
    )
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS else {
      throw TimelinePlaybackError.invalidPlan
    }
    let anchor = mach_absolute_time()
    try preparation.anchorCaptureClock(
      sessionId: session.sessionId, hostAnchor: anchor,
      numerator: timebase.numer, denominator: timebase.denom)
    var writers: [SegmentedCAFWriter] = []
    for source in [NativeMediaSourceKind.microphone, .systemAudio] {
      let authorization = try preparation.authorizeInitialMedia(
        sessionId: session.sessionId,
        sourceKind: source, sourceDisplayName: "Synthetic \(source)")
      let file = try ManagedCAFWriter(authorization: authorization)
      _ = try preparation.acceptMediaOpen(receipt: file.receipt())
      writers.append(SegmentedCAFWriter(current: file, preparation: preparation))
    }
    let starts = [1.0, 1.25]
    let values: [Int16] = [8192, 16384]
    for index in writers.indices {
      _ = try writers[index].writeCapturedBuffer(
        buffer(frames: 480, value: values[index], channels: writers[index].authorization.channels,
          rightValue: index == 1 ? -8192 : nil),
        hostTime: anchor + AVAudioTime.hostTime(forSeconds: starts[index]))
    }
    _ = try preparation.confirmRecording(sessionId: session.sessionId)
    for index in writers.indices {
      var written: UInt64 = 480
      while written < 31 * 48_000 {
        let count = AVAudioFrameCount(min(48_000, 31 * 48_000 - written))
        _ = try writers[index].writeCapturedBuffer(
          buffer(frames: count, value: values[index], channels: writers[index].authorization.channels,
            rightValue: index == 1 ? -8192 : nil),
          hostTime: anchor
            + AVAudioTime.hostTime(forSeconds: starts[index] + Double(written) / 48_000))
        written += UInt64(count)
      }
    }
    return Capture(sessionId: session.sessionId, writers: writers, preparation: preparation)
  }

  static func buffer(
    frames: AVAudioFrameCount, value: Int16, channels: UInt16 = 1, rightValue: Int16? = nil
  ) throws -> AVAudioPCMBuffer {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 48_000,
        channels: AVAudioChannelCount(channels), interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      let samples = buffer.int16ChannelData
    else { throw TimelinePlaybackError.invalidPlan }
    buffer.frameLength = frames
    samples[0].update(repeating: value, count: Int(frames))
    if channels == 2 {
      samples[1].update(repeating: rightValue ?? value, count: Int(frames))
    }
    return buffer
  }

  static func verify(root: URL, sessionId: String) throws -> [String: Int] {
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    let recovered = try preparation.recoverPlayableSessions()
    guard recovered.filter({ $0.sessionId == sessionId }).count == 4 else {
      throw TimelinePlaybackError.invalidPlan
    }
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    guard plan.count == 4, Set(plan.map(\.trackId)).count == 2,
      plan.filter({ $0.sequence == 0 }).allSatisfy({ $0.sampleCount == 1_440_000 }),
      plan.filter({ $0.sequence == 1 }).allSatisfy({ $0.sampleCount == 48_000 })
    else { throw TimelinePlaybackError.invalidPlan }
    let reader = try TimelinePCMReader(segments: plan)
    defer { reader.close() }
    let probes: [Int64: (Float, Float)] = [
      0: (0, 0), 52_800: (0.125, 0.125), 62_400: (0.375, 0),
      1_540_800: (0.25, -0.125),
    ]
    var position: Int64 = 0
    var checked = 0
    while let buffer = try reader.read(maximumFrames: 16_384) {
      for (frame, expected) in probes
      where frame >= position && frame < position + Int64(buffer.frameLength) {
        guard let samples = buffer.floatChannelData,
          abs(samples[0][Int(frame - position)] - expected.0) < 0.0001,
          abs(samples[1][Int(frame - position)] - expected.1) < 0.0001
        else {
          throw TimelinePlaybackError.incompleteSegment
        }
        checked += 1
      }
      position += Int64(buffer.frameLength)
    }
    guard checked == probes.count, position == 1_548_000 else {
      throw TimelinePlaybackError.invalidPlan
    }
    return [
      "tracks": 2, "segments": 4, "rendered_frames": Int(position), "verified_probes": checked,
    ]
  }

  @MainActor
  static func verifyLive(root: URL) async {
    let player = TimelineAudioPlayer()
    defer { player.stop() }
    do {
      let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
      let recovered = try preparation.recoverPlayableSessions()
      guard let sessionId = recovered.first?.sessionId else {
        throw TimelinePlaybackError.invalidPlan
      }
      let plan = try preparation.playbackTimeline(sessionId: sessionId)
      let tracks = Dictionary(grouping: plan, by: \.trackId)
      guard tracks.count == 2,
        tracks.values.allSatisfy({ segments in
          segments.count >= 2
            && segments.allSatisfy { $0.sampleCount > 0 && $0.sampleCount <= 1_440_000 }
            && segments.reduce(0) { $0 + $1.sampleCount } >= 1_440_000
        })
      else { throw TimelinePlaybackError.invalidPlan }
      let drift = plan.filter { $0.sequence > 0 }.map { abs($0.gapNanoseconds) }.max() ?? 0
      let adjustment = plan.map(\.clockAdjustmentNanoseconds).max() ?? 0
      guard drift <= 50_000_000 else { throw TimelinePlaybackError.invalidPlan }
      // Decode the complete recovered plan, including every segment boundary,
      // without sending it to the output device. Audible verification is bounded.
      let reader = try TimelinePCMReader(segments: plan)
      defer { reader.close() }
      var renderedFrames: Int64 = 0
      while let buffer = try reader.read(maximumFrames: 16_384) {
        renderedFrames += Int64(buffer.frameLength)
      }
      guard renderedFrames == reader.totalFrames else {
        throw TimelinePlaybackError.incompleteSegment
      }
      reader.close()
      try player.play(segments: plan, generation: UUID(), completion: { _ in })
      try await Task.sleep(for: .milliseconds(1_250))
      guard player.isPlaying else { throw TimelinePlaybackError.incompleteSegment }
      player.stop()
      let report: [String: Any] = [
        "tracks": tracks.count, "segments": plan.count,
        "maximum_boundary_gap_nanoseconds": drift, "native_playback_opened": true,
        "maximum_clock_adjustment_nanoseconds": adjustment,
        "rendered_frames": renderedFrames,
        "playback_milliseconds": 1_250,
      ]
      try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        .write(to: root.appendingPathComponent("recovery-verified.json"), options: .atomic)
    } catch {
      try? String(describing: error).write(
        to: root.appendingPathComponent("proof-error"), atomically: true, encoding: .utf8)
    }
    NSApp.terminate(nil)
  }

  @MainActor
  static func run(root: URL, captureMode: Bool) async {
    do {
      if captureMode {
        let capture = try capture(root: root)
        try capture.sessionId.write(
          to: root.appendingPathComponent("capture-ready"), atomically: true, encoding: .utf8)
        // Keep AVAudioFiles open until the harness delivers SIGKILL.
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(1))
          withExtendedLifetime(capture) {}
        }
      } else {
        let id = try String(
          contentsOf: root.appendingPathComponent("capture-ready"), encoding: .utf8)
        let report = try verify(root: root, sessionId: id)
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
          .write(to: root.appendingPathComponent("recovery-verified.json"), options: .atomic)
        NSApp.terminate(nil)
      }
    } catch {
      try? String(describing: error).write(
        to: root.appendingPathComponent("proof-error"), atomically: true, encoding: .utf8)
      NSApp.terminate(nil)
    }
  }
}
