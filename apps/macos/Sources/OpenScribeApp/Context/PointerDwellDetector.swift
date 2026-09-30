import CoreGraphics
import Foundation

/// One in-memory pointer observation. Samples are never persisted and never
/// cross UniFFI (ADR 0011, Follow Pointer).
struct PointerSample: Equatable, Sendable {
  let time: TimeInterval
  let point: CGPoint
  /// The eligible surface under the pointer, or `nil` when it is filtered
  /// (Dock, menu bar, Open Scribe, a denylisted or unknown surface).
  let surface: String?
  let inScope: Bool
}

/// A capture candidate: the pointer rested on one surface long enough.
/// It is not a context event and triggers no attention treatment.
struct DwellCandidate: Equatable, Sendable {
  let surface: String
  let point: CGPoint
  let time: TimeInterval
}

/// Follow Pointer attention approximation, acceptance parameters v1: the
/// pointer stays within 16 points on the same eligible surface for 600 ms.
/// A surface change, faster than 600 points per second movement, or leaving
/// the authorized scope cancels the candidate.
struct PointerDwellDetector: Sendable {
  static let parametersRevision = "dwell-16pt-600ms-600ptps-v1"
  static let sampleInterval: TimeInterval = 1.0 / 30.0
  let radius: CGFloat = 16
  let dwell: TimeInterval = 0.6
  let maximumSpeed: CGFloat = 600

  private var anchor: PointerSample?
  private var previous: PointerSample?
  private var emitted = false

  mutating func reset() {
    anchor = nil
    previous = nil
    emitted = false
  }

  mutating func observe(_ sample: PointerSample) -> DwellCandidate? {
    defer { previous = sample }
    guard sample.inScope, let surface = sample.surface else {
      anchor = nil
      return nil
    }
    if let previous, sample.time > previous.time {
      let speed =
        hypot(sample.point.x - previous.point.x, sample.point.y - previous.point.y)
        / CGFloat(sample.time - previous.time)
      if speed > maximumSpeed {
        anchor = nil
        return nil
      }
    }
    guard let current = anchor, current.surface == surface,
      hypot(sample.point.x - current.point.x, sample.point.y - current.point.y) <= radius
    else {
      anchor = sample
      emitted = false
      return nil
    }
    guard !emitted, sample.time - current.time >= dwell else { return nil }
    emitted = true
    return DwellCandidate(surface: surface, point: sample.point, time: sample.time)
  }
}
