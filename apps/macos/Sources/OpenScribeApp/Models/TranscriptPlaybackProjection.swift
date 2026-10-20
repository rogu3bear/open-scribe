import Foundation

/// Display only: the actual native renderer's position on the verified
/// media timeline. It never starts playback or establishes capture truth.
struct TranscriptPlaybackPosition: Equatable, Sendable {
  let sessionId: String
  let generation: UUID
  let nanoseconds: Int64
}

enum TranscriptPlaybackProjection {
  static func frame(nanoseconds: Int64, sampleRate: Double) -> Int64? {
    guard nanoseconds >= 0, sampleRate.isFinite, sampleRate > 0 else { return nil }
    let frame = Double(nanoseconds) / 1_000_000_000 * sampleRate
    guard frame.isFinite, frame >= 0, frame < Double(Int64.max) else { return nil }
    return Int64(frame.rounded(.down))
  }

  static func position(
    start: Int64, end: Int64, renderedFrames: Int64, sampleRate: Double
  ) -> Int64? {
    guard end >= start, renderedFrames >= 0, sampleRate.isFinite, sampleRate > 0 else {
      return nil
    }
    let offset = Double(renderedFrames) / sampleRate * 1_000_000_000
    guard offset.isFinite, offset >= 0, offset < Double(Int64.max) else { return nil }
    let (position, overflow) = start.addingReportingOverflow(Int64(offset.rounded(.down)))
    return overflow ? nil : min(position, end)
  }
}

struct TranscriptPlaybackRange: Equatable, Sendable {
  let id: String
  let start: Int64
  let end: Int64
}

/// Built when the document/filter changes, not on each clock tick. Prefix
/// ends retain simultaneous turns and avoid scanning long silent history.
struct TranscriptPlaybackIndex: Sendable {
  private let ranges: [TranscriptPlaybackRange]
  private let prefixEnds: [Int64]

  init(_ input: [TranscriptPlaybackRange]) {
    ranges = input.enumerated().filter { $0.element.end > $0.element.start }
      .sorted {
        $0.element.start == $1.element.start
          ? $0.offset < $1.offset : $0.element.start < $1.element.start
      }.map(\.element)
    var maximum = Int64.min
    prefixEnds = ranges.map {
      maximum = max(maximum, $0.end)
      return maximum
    }
  }

  func activeTurnIds(at position: Int64) -> [String] {
    var lower = 0
    var upper = ranges.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if ranges[middle].start <= position { lower = middle + 1 } else { upper = middle }
    }
    var index = lower
    var result: [String] = []
    while index > 0 {
      index -= 1
      if prefixEnds[index] <= position { break }
      if ranges[index].end > position { result.append(ranges[index].id) }
    }
    return Array(result.reversed())
  }
}
