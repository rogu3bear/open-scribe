import XCTest

@testable import OpenScribeApp

final class RustStatusSourceTests: XCTestCase {
  func testRustStatusSourceReportsBoundedCaptureWithoutIntelligence() {
    let status = AppStatus.load()

    XCTAssertEqual(status.productName, "Open Scribe")
    XCTAssertEqual(status.coreVersion, "0.0.0")
    XCTAssertEqual(status.persistence, "Durable local audio and recovery")
    XCTAssertEqual(status.capture, "Development microphone + system audio")
    XCTAssertEqual(status.intelligence, "Not implemented")
  }

  /// Settings reads `nativeReleaseClaims`. This build has no signed release,
  /// so none of the checked capabilities are Available.
  func testUnprovedCapabilitiesStayExcludedWithoutASignedRelease() {
    let release = nativeReleaseClaims()

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

  /// Settings renders these rows. The words come from the shared maturity label.
  func testSettingsReleaseRowsUseTheSharedExclusionLabels() {
    let release = nativeReleaseClaims()
    XCTAssertEqual(release.noPublicRelease, "No public release is available.")
    XCTAssertEqual(release.capabilities.count, 8)
    var seen: Set<String> = []
    for claim in release.capabilities {
      XCTAssertTrue(seen.insert(claim.id).inserted, claim.id)
      XCTAssertFalse(claim.terminology.isEmpty)
      switch claim.maturity {
      case "Fixture":
        XCTAssertEqual(claim.publicLabel, "Development fixture — not available to users")
      case "Unavailable":
        XCTAssertEqual(claim.publicLabel, "Unavailable")
      default:
        XCTFail("unexpected maturity \(claim.maturity) for \(claim.id)")
      }
      XCTAssertNotEqual(claim.publicLabel, "Available")
    }
  }
}
