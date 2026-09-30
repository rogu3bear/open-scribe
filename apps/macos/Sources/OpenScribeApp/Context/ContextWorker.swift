import CoreGraphics
import Foundation

/// What one frame request observes.
enum ContextCaptureTarget: Equatable, Sendable {
  /// A display, optionally cropped to normalized top-left-origin bounds.
  case display(CGDirectDisplayID, region: CGRect?)
  case window(CGWindowID)
}

/// The scope epoch a request was made under.
struct ContextEpochToken: Equatable, Sendable {
  let scopeId: String
  let epoch: UInt32
}

struct ContextCaptureRequest: Equatable, Sendable {
  let token: ContextEpochToken
  let reason: NativeContextEventReason
  let target: ContextCaptureTarget
  let source: NativeContextSource
  let bounds: NativeContextBounds?
}

protocol ContextFrameCapturing: Sendable {
  /// Captures exactly one frame of the authorized target.
  func captureFrame(_ target: ContextCaptureTarget) async throws -> CGImage
}

enum ContextOutcome: Equatable, Sendable {
  /// Below the change threshold: no OCR ran.
  case unchanged
  /// Changed, but no text was recognized; nothing was proposed.
  case noText
  /// Rust accepted the event; only this may trigger Active attention.
  case accepted(eventId: String, startNanoseconds: Int64)
  case rejected(NativeContextRejection)
  /// The epoch ended locally before the work could be proposed.
  case invalidated
  case failed
}

/// The single context worker (ADR 0012, Isolation and bounded sampling). It
/// holds at most one pending candidate: a newer one replaces it and a
/// counter advances. It runs at utility priority on its own task and shares
/// nothing with audio capture. The local epoch token is checked after every
/// suspension, so revocation stops work before Rust records it.
final class ContextWorker: @unchecked Sendable {
  typealias Propose = @Sendable (NativeContextProposal) throws -> NativeContextDecision
  typealias Recognize = @Sendable (CGImage) throws -> [NativeContextTextBlock]
  typealias Outcome = @Sendable (ContextCaptureRequest, ContextOutcome) -> Void

  private let frames: ContextFrameCapturing
  private let propose: Propose
  private let recognize: Recognize
  private let hostTime: @Sendable () -> UInt64
  private let wallTime: @Sendable () -> Int64
  private let lock = NSLock()
  private var token: ContextEpochToken?
  private var pending: ContextCaptureRequest?
  private var running = false
  private var lastFingerprint: ContextFingerprint?
  private var dropped = 0
  private var outcome: Outcome = { _, _ in }

  init(
    frames: ContextFrameCapturing,
    propose: @escaping Propose,
    recognize: @escaping Recognize = { try ContextReducer.recognize($0) },
    hostTime: @escaping @Sendable () -> UInt64 = { mach_absolute_time() },
    wallTime: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
  ) {
    self.frames = frames
    self.propose = propose
    self.recognize = recognize
    self.hostTime = hostTime
    self.wallTime = wallTime
  }

  var droppedCandidates: Int { lock.withLock { dropped } }
  var isIdle: Bool { lock.withLock { !running && pending == nil } }

  func onOutcome(_ handler: @escaping Outcome) {
    lock.withLock { outcome = handler }
  }

  /// Accepts requests for this epoch only; a new epoch starts with no
  /// previous fingerprint.
  func activate(_ token: ContextEpochToken) {
    lock.withLock {
      self.token = token
      pending = nil
      lastFingerprint = nil
    }
  }

  /// Stops accepting work immediately and clears the pending slot.
  func invalidate() {
    lock.withLock {
      token = nil
      pending = nil
      lastFingerprint = nil
    }
  }

  func offer(_ request: ContextCaptureRequest) {
    let start: Bool = lock.withLock {
      guard token == request.token else { return false }
      if pending != nil { dropped += 1 }
      pending = request
      guard !running else { return false }
      running = true
      return true
    }
    guard start else { return }
    Task.detached(priority: .utility) { [self] in await drain() }
  }

  private func drain() async {
    while let next = takePending() {
      let result = await process(next)
      let handler = lock.withLock { outcome }
      handler(next, result)
    }
  }

  private func takePending() -> ContextCaptureRequest? {
    lock.withLock {
      let next = pending
      pending = nil
      if next == nil { running = false }
      return next
    }
  }

  private func isLive(_ request: ContextCaptureRequest) -> Bool {
    lock.withLock { token == request.token }
  }

  func process(_ request: ContextCaptureRequest) async -> ContextOutcome {
    guard isLive(request) else { return .invalidated }
    let start = hostTime()
    guard let image = try? await frames.captureFrame(request.target) else { return .failed }
    let end = hostTime()
    // The frame is released when this call returns; nothing retains it.
    guard isLive(request), let fingerprint = try? ContextReducer.fingerprint(image) else {
      return isLive(request) ? .failed : .invalidated
    }
    let previous: ContextFingerprint? = lock.withLock {
      defer { lastFingerprint = fingerprint }
      return lastFingerprint
    }
    let marked = request.reason == .userMarked
    if !marked && !ContextReducer.changed(fingerprint, from: previous) { return .unchanged }
    guard let blocks = try? recognize(image) else { return .failed }
    if blocks.isEmpty && !marked { return .noText }
    guard isLive(request) else { return .invalidated }
    let proposal = NativeContextProposal(
      scopeId: request.token.scopeId, epoch: request.token.epoch, reason: request.reason,
      startHostTime: start, endHostTime: max(start, end), observedAtMs: wallTime(),
      source: request.source, bounds: request.bounds,
      reducerRevision: ContextReducer.revision, visionRevision: ContextReducer.visionRevision,
      languages: ContextReducer.languages, blocks: blocks)
    do {
      switch try propose(proposal) {
      case .accepted(let eventId, let startNs, _, _):
        return .accepted(eventId: eventId, startNanoseconds: startNs)
      case .rejected(let reason):
        return .rejected(reason)
      }
    } catch {
      return .failed
    }
  }
}
