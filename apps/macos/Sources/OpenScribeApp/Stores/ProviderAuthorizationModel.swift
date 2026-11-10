import CryptoKit
import Foundation

/// Settings and review call this model. It asks Rust which categories a
/// provider may see. Configuration grants nothing, and this build sends nothing.
@MainActor
final class ProviderAuthorizationModel: ObservableObject {
  struct CategoryChoice: Identifiable {
    let category: NativeContentCategory
    let title: String
    var id: String { title }
  }

  static let choices: [CategoryChoice] = [
    CategoryChoice(category: .finalTranscript, title: "Final transcript"),
    CategoryChoice(category: .draftTranscript, title: "Draft transcript"),
    CategoryChoice(category: .contextText, title: "Context text"),
    CategoryChoice(category: .userNotes, title: "Notes"),
    CategoryChoice(category: .participantTopic, title: "Participant and topic"),
    CategoryChoice(category: .humanCorrections, title: "Corrections"),
    CategoryChoice(category: .existingDerivedClaims, title: "Existing derived claims"),
  ]

  static let unavailableNotice = "Audio and snapshots are unavailable to remote review."
  static let refusalNotice =
    "That provider change was refused. No conversation content was sent."

  @Published private(set) var notice: String
  @Published private(set) var configuration: NativeProviderConfiguration?
  @Published var grants: Set<NativeContentCategory> = []
  @Published private(set) var prepareNotice: String?
  @Published private(set) var outboundRequest = false
  @Published private(set) var networkUsed = false
  @Published private(set) var includedCategories: [String] = []
  @Published private(set) var includedTexts: [String] = []
  @Published private(set) var receiptRecord = ""
  @Published private(set) var failure: String?

  init() {
    notice = providerUnconfiguredNotice()
  }

  var configured: Bool { configuration != nil }

  func configureRemote(
    providerId: String, modelId: String, origin: String, credentialFingerprint: String?
  ) throws {
    let configuration = try configureContentProvider(
      providerId: providerId, modelId: modelId, execution: .remote, origin: origin,
      credentialFingerprint: credentialFingerprint)
    store(configuration)
  }

  func configureLocal(providerId: String, modelId: String) throws {
    let configuration = try configureContentProvider(
      providerId: providerId, modelId: modelId, execution: .local, origin: nil,
      credentialFingerprint: nil)
    store(configuration)
  }

  func record(category: NativeContentCategory, recordId: String, revisionId: String, text: String)
    -> NativeProviderOfferedRecord
  {
    let bytes = Data(text.utf8)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return NativeProviderOfferedRecord(
      category: category, recordId: recordId, revisionId: revisionId, contentDigest: digest,
      byteCount: UInt64(bytes.count), text: text)
  }

  /// Configuration has no granted category, so Rust refuses before a review exists.
  func sendConfiguredProvider(offered: [NativeProviderOfferedRecord]) throws {
    guard let configuration else {
      failure = notice
      throw NativeProviderError.NoCategoryGranted
    }
    do {
      _ = try outboundFromContentProviderConfiguration(
        configuration: configuration, offered: offered)
    } catch {
      failure = Self.refusalNotice
      throw error
    }
  }

  @discardableResult
  func prepare(sessionId: String, offered: [NativeProviderOfferedRecord]) throws
    -> NativePreparedReview
  {
    guard let configuration else {
      failure = notice
      throw NativeProviderError.NoCategoryGranted
    }
    do {
      let review = try materializeContentProviderReview(
        configuration: configuration, authorizationId: "review-1", sessionId: sessionId,
        granted: Array(grants), offered: offered)
      prepareNotice = review.notice
      outboundRequest = review.outboundRequest
      networkUsed = review.networkUsed
      includedCategories = review.receipt.categories
      includedTexts = review.parts.map(\.text)
      receiptRecord = review.receipt.publicRecord
      failure = nil
      return review
    } catch {
      failure = Self.refusalNotice
      throw error
    }
  }

  func retargetRemote(sessionId: String, origin: String) throws {
    guard let configuration else {
      failure = notice
      throw NativeProviderError.NoCategoryGranted
    }
    do {
      try retargetContentProviderRemote(
        configuration: configuration, authorizationId: "review-1", sessionId: sessionId,
        granted: Array(grants), origin: origin)
    } catch {
      failure = Self.refusalNotice
      throw error
    }
  }

  func noteFailure() {
    failure = Self.refusalNotice
  }

  private func store(_ configuration: NativeProviderConfiguration) {
    self.configuration = configuration
    notice = configuration.notice
    grants = []
    prepareNotice = nil
    outboundRequest = false
    networkUsed = false
    includedCategories = []
    includedTexts = []
    receiptRecord = ""
    failure = nil
  }
}
