import XCTest

@testable import OpenScribeApp

final class RustStatusSourceTests: XCTestCase {
  func testRustStatusSourceReportsBoundedCaptureWithoutIntelligence() {
    let status = RustStatusSource.load()

    XCTAssertEqual(status.productName, "Open Scribe")
    XCTAssertEqual(status.coreVersion, "0.0.0")
    XCTAssertEqual(status.persistence, "Durable local audio and recovery")
    XCTAssertEqual(status.capture, "Development microphone + system audio")
    XCTAssertEqual(status.intelligence, "Not implemented")
  }
}
