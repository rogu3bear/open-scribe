import Darwin
import Foundation

enum SingleInstanceGuardError: Error, Equatable {
  case alreadyRunning
  case cannotOpen(Int32)

  var shouldActivateExistingInstance: Bool {
    self == .alreadyRunning
  }
}

final class SingleInstanceGuard {
  private var fileDescriptor: Int32?

  init(lockFileURL: URL) throws {
    try FileManager.default.createDirectory(
      at: lockFileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let descriptor = lockFileURL.path.withCString { path in
      Darwin.open(
        path,
        O_CREAT | O_RDWR | O_CLOEXEC | O_EXLOCK | O_NONBLOCK,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      let openError = errno
      if openError == EWOULDBLOCK || openError == EAGAIN {
        throw SingleInstanceGuardError.alreadyRunning
      }
      throw SingleInstanceGuardError.cannotOpen(openError)
    }
    fileDescriptor = descriptor
  }

  static func acquireDefault() throws -> SingleInstanceGuard {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let lockFile =
      applicationSupport
      .appendingPathComponent("Open Scribe", isDirectory: true)
      .appendingPathComponent("open-scribe-instance.lock")
    return try SingleInstanceGuard(lockFileURL: lockFile)
  }

  func release() {
    guard let descriptor = fileDescriptor else { return }
    Darwin.close(descriptor)
    fileDescriptor = nil
  }

  deinit {
    release()
  }
}
