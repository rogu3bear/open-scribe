import Foundation
import XCTest

@testable import OpenScribeApp

final class SingleInstanceGuardTests: XCTestCase {
  func testOnlyAnOccupiedLockActivatesAnExistingInstance() {
    XCTAssertTrue(SingleInstanceGuardError.alreadyRunning.shouldActivateExistingInstance)
    XCTAssertFalse(SingleInstanceGuardError.cannotOpen(EACCES).shouldActivateExistingInstance)
  }

  func testOnlyOneGuardOwnsTheLockUntilItReleases() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let lockFile = root.appendingPathComponent("open-scribe-instance.lock")

    let first = try SingleInstanceGuard(lockFileURL: lockFile)
    XCTAssertThrowsError(try SingleInstanceGuard(lockFileURL: lockFile)) { error in
      XCTAssertEqual(error as? SingleInstanceGuardError, .alreadyRunning)
    }

    first.release()
    XCTAssertNoThrow(try SingleInstanceGuard(lockFileURL: lockFile))
  }
}
