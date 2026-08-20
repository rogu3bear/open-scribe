import XCTest
@testable import OpenScribeApp

final class RustStatusSourceTests: XCTestCase {
    func testRustStatusSourceLoadsTruthfulUnavailableState() {
        let status = RustStatusSource.load()

        XCTAssertEqual(status.productName, "Open Scribe")
        XCTAssertEqual(status.coreVersion, "0.0.0")
        XCTAssertEqual(status.persistence, "Not implemented")
        XCTAssertEqual(status.capture, "Not implemented")
        XCTAssertEqual(status.intelligence, "Not implemented")
    }
}
