import Foundation

/// A deadline belongs to one restore attempt. Cancellation suppresses a late
/// timeout even when an injected or platform wait does not cooperate with it.
@MainActor
final class MicrophoneRestoreMonitor {
  typealias Wait = @Sendable (ContinuousClock.Instant) async throws -> Void
  private let wait: Wait
  private var task: Task<Void, Never>?

  init(wait: @escaping Wait) { self.wait = wait }

  nonisolated static func waitForTimeout(_ deadline: ContinuousClock.Instant) async throws {
    try await ContinuousClock().sleep(until: deadline)
  }

  func start(
    deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: .seconds(10)),
    onTimeout: @escaping @MainActor () async -> Void
  ) {
    cancel()
    let wait = wait
    task = Task {
      do { try await wait(deadline) } catch { return }
      guard !Task.isCancelled else { return }
      await onTimeout()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  deinit { task?.cancel() }
}

@MainActor
final class RestoreSampleGate {
  private var continuation: CheckedContinuation<Bool, Never>?
  private var result: Bool?

  func resume(_ value: Bool) {
    guard result == nil else { return }
    result = value
    let pending = continuation
    continuation = nil
    pending?.resume(returning: value)
  }

  func wait() async -> Bool {
    if let result { return result }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }
}
