import CryptoKit
import Foundation

enum PolicyDocument: String, CaseIterable, Identifiable, Sendable {
  case privacy, terms, security, notices, license

  var id: String { rawValue }

  var title: String {
    switch self {
    case .privacy: "Privacy notice"
    case .terms: "Terms"
    case .security: "Security policy"
    case .notices: "Third-party notices"
    case .license: "MIT license"
    }
  }

  var qualificationNote: String? {
    switch self {
    case .privacy, .terms:
      "Draft. This document has not been adopted for a supported app release."
    case .security:
      "Private reporting is available. Response ownership and policy adoption remain release prerequisites."
    case .notices:
      "Development notices. Transitive component and redistribution review remains incomplete."
    case .license: nil
    }
  }

  static var resourceBundle: Bundle {
    #if SWIFT_PACKAGE
      Bundle.module
    #else
      Bundle.main
    #endif
  }

  func load(from bundle: Bundle = resourceBundle) throws -> String {
    guard let url = bundle.url(forResource: rawValue, withExtension: "md", subdirectory: "Policies")
    else { throw PolicyDocumentError.unavailable }
    return try validatedText(Data(contentsOf: url))
  }

  func validatedText(_ data: Data) throws -> String {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard let expected = PolicyDocumentDigests.sha256[rawValue], digest == expected,
      let text = String(data: data, encoding: .utf8), !text.isEmpty
    else { throw PolicyDocumentError.unavailable }
    return text
  }
}

enum PolicyDocumentError: Error {
  case unavailable
}
