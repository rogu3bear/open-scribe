import XCTest

@testable import OpenScribeApp

@MainActor
final class ProviderAuthorizationTests: XCTestCase {
  private let digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  func testConfiguringAProviderAuthorizesNoCategoryAndSendsNothing() throws {
    let model = ProviderAuthorizationModel()
    XCTAssertEqual(model.notice, providerUnconfiguredNotice())
    XCTAssertFalse(model.configured)
    XCTAssertFalse(model.outboundRequest)
    XCTAssertFalse(model.networkUsed)

    let secret = "sk-live-example-secret"
    XCTAssertThrowsError(try refuseContentProviderSecret(material: secret)) { error in
      XCTAssertEqual(error as? NativeProviderError, .SecretMaterialRefused)
      XCTAssertFalse(String(reflecting: error).contains(secret))
    }
    XCTAssertThrowsError(try grantContentCategory(name: "audio")) { error in
      XCTAssertEqual(error as? NativeProviderError, .CategoryUnavailable)
    }
    XCTAssertThrowsError(try grantContentCategory(name: "snapshots")) { error in
      XCTAssertEqual(error as? NativeProviderError, .CategoryUnavailable)
    }
    XCTAssertEqual(try grantContentCategory(name: "final_transcript"), .finalTranscript)

    try model.configureRemote(
      providerId: "example", modelId: "review", origin: "https://api.example.com/v1",
      credentialFingerprint: digest)
    XCTAssertEqual(model.notice, providerConfiguredNotice())
    XCTAssertEqual(model.notice, "Provider configured — no conversation content authorized")
    XCTAssertTrue(model.grants.isEmpty)

    let draft = "unrelated draft stays out"
    let finalText = "The decision was to ship."
    let offered = [
      model.record(
        category: .draftTranscript, recordId: "draft-1", revisionId: "revision-1", text: draft),
      model.record(
        category: .finalTranscript, recordId: "final-1", revisionId: "revision-1", text: finalText),
    ]
    XCTAssertThrowsError(try model.sendConfiguredProvider(offered: offered)) { error in
      XCTAssertEqual(error as? NativeProviderError, .NoCategoryGranted)
      XCTAssertFalse(model.receiptRecord.contains(draft))
      XCTAssertFalse(String(reflecting: error).contains(draft))
      XCTAssertFalse(String(reflecting: error).contains(secret))
    }

    model.grants = [.finalTranscript]
    let review = try model.prepare(sessionId: "session-1", offered: offered)
    XCTAssertFalse(review.outboundRequest)
    XCTAssertFalse(review.networkUsed)
    XCTAssertEqual(review.notice, providerNoOutboundNotice())
    XCTAssertEqual(review.parts.map(\.category), [.finalTranscript])
    XCTAssertEqual(review.parts.map(\.text), [finalText])
    XCTAssertEqual(model.includedTexts, [finalText])
    XCTAssertEqual(model.includedCategories, ["final_transcript"])
    XCTAssertFalse(model.receiptRecord.contains(draft))
    XCTAssertFalse(model.receiptRecord.contains(finalText))
    XCTAssertFalse(model.receiptRecord.contains(secret))
    XCTAssertTrue(model.receiptRecord.contains("network_used=false"))
    XCTAssertTrue(model.receiptRecord.contains("outbound_request=false"))
  }

  func testALocalGrantCannotAuthorizeARemoteOrigin() throws {
    let model = ProviderAuthorizationModel()
    try model.configureLocal(providerId: "example", modelId: "review")
    XCTAssertEqual(model.notice, providerConfiguredNotice())
    model.grants = [.userNotes]
    XCTAssertThrowsError(
      try model.retargetRemote(sessionId: "session-1", origin: "https://api.example.com")
    ) { error in
      XCTAssertEqual(error as? NativeProviderError, .LocalGrantDoesNotAuthorizeRemote)
    }
    XCTAssertThrowsError(
      try model.configureRemote(
        providerId: "example", modelId: "review", origin: "https://127.0.0.1/v1",
        credentialFingerprint: nil)
    ) { error in
      XCTAssertEqual(error as? NativeProviderError, .OriginRefused)
    }
    XCTAssertThrowsError(
      try model.configureRemote(
        providerId: "example", modelId: "review", origin: "https://api.example.com",
        credentialFingerprint: "sk-live-example-secret")
    ) { error in
      XCTAssertEqual(error as? NativeProviderError, .FingerprintRefused)
      XCTAssertFalse(String(reflecting: error).contains("sk-live-example-secret"))
    }
  }
}
