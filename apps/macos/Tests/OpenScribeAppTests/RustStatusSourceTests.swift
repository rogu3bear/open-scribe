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

  /// Settings calls `ReleaseCapabilityClaims.load`. This build has no signed release,
  /// so none of the checked capabilities are Available.
  func testUnprovedCapabilitiesStayExcludedWithoutASignedRelease() {
    let release = ReleaseCapabilityClaims.load()

    XCTAssertEqual(release.noPublicRelease, "No public release is available.")
    XCTAssertEqual(release.capabilities.count, 8)
    XCTAssertTrue(
      release.capabilities.allSatisfy {
        $0.maturity != "Available" && $0.publicLabel != "Available"
      })
    let transcript = release.capabilities.first { $0.id == "local-transcription" }
    XCTAssertEqual(transcript?.terminology, "Transcript")
    XCTAssertEqual(transcript?.maturity, "Unavailable")
    XCTAssertEqual(transcript?.publicLabel, "Unavailable")
    let recording = release.capabilities.first { $0.id == "multi-source-recording" }
    XCTAssertEqual(recording?.publicLabel, "Development fixture — not available to users")
    let insight = release.capabilities.first { $0.id == "optional-intelligence" }
    XCTAssertEqual(insight?.terminology, "Derived insight")
    XCTAssertEqual(insight?.publicLabel, "Unavailable")
  }
}
