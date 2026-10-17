import XCTest

@testable import OpenScribeApp

final class PolicyDocumentTests: XCTestCase {
  func testEveryBundledDocumentMatchesItsCanonicalSource() throws {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let paths: [PolicyDocument: String] = [
      .privacy: "docs/legal/privacy.md", .terms: "docs/legal/terms.md", .security: "SECURITY.md",
      .notices: "THIRD_PARTY_NOTICES.md", .license: "LICENSE",
    ]
    for document in PolicyDocument.allCases {
      let canonical = try String(
        contentsOf: source.appendingPathComponent(paths[document]!), encoding: .utf8)
      XCTAssertEqual(try document.load(), canonical, document.title)
    }
  }

  func testAbsentResourcesAreAnError() {
    // Foundation's own bundle cannot supply app policy files.
    XCTAssertThrowsError(try PolicyDocument.privacy.load(from: Bundle(for: NSObject.self)))
  }

  func testReplacedResourceCannotChangeTheCompiledPolicy() {
    XCTAssertThrowsError(
      try PolicyDocument.privacy.validatedText(Data("replacement privacy notice".utf8)))
  }

  func testDraftAndIncompleteStatusesRemainVisible() {
    XCTAssertTrue(PolicyDocument.privacy.qualificationNote?.contains("Draft") == true)
    XCTAssertTrue(PolicyDocument.terms.qualificationNote?.contains("Draft") == true)
    XCTAssertTrue(PolicyDocument.notices.qualificationNote?.contains("incomplete") == true)
    XCTAssertNil(PolicyDocument.license.qualificationNote)
  }
}
