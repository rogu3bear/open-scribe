import XCTest

@testable import OpenScribeApp

final class RustStatusSourceTests: XCTestCase {
  func testRustStatusSourceReportsPreparationWithoutCapture() {
    let status = RustStatusSource.load()

    XCTAssertEqual(status.productName, "Open Scribe")
    XCTAssertEqual(status.coreVersion, "0.0.0")
    XCTAssertEqual(status.persistence, "Durable preparation only")
    XCTAssertEqual(status.capture, "Not implemented")
    XCTAssertEqual(status.intelligence, "Not implemented")
  }
}
