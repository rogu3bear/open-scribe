import Foundation

enum StructuredNativeIO {
  static func read<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    try await run(operation, checksCancellationAfterOperation: true)
  }

  static func mutation<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    try await run(operation, checksCancellationAfterOperation: false)
  }

  private static func run<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result,
    checksCancellationAfterOperation: Bool
  ) async throws -> Result {
    try await withThrowingTaskGroup(of: Result.self) { group in
      group.addTask(priority: checksCancellationAfterOperation ? .utility : .userInitiated) {
        try Task.checkCancellation()
        let result = try operation()
        if checksCancellationAfterOperation {
          try Task.checkCancellation()
        }
        return result
      }
      guard let result = try await group.next() else {
        throw CancellationError()
      }
      return result
    }
  }
}
