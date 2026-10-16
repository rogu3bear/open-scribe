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
        O_CREAT | O_RDWR | O_CLOEXEC | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW,
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

  func release() {
    guard let descriptor = fileDescriptor else { return }
    Darwin.close(descriptor)
    fileDescriptor = nil
  }

  deinit {
    release()
  }
}
