import AppKit
import SwiftUI
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

  /// The hosted Settings control configures a provider, refuses a non-digest
  /// fingerprint, and prepares a review only after a category is turned on.
  /// The test does not call `configureRemote`, `prepare`, or `noteFailure`.
  func testHostedProviderConfigurationAuthorizesNoCategoryUntilTheUserGrantsOne() async throws {
    let secret = "sk-live-example-secret"
    let view = SettingsView(
      status: AppStatus(
        productName: "Open Scribe", coreVersion: "fixture", persistence: "local",
        capture: "fixture", intelligence: "Not implemented"),
      speech: SpeechTranscriptionModel(preview: []),
      library: RuntimeLibraryStore(managedRoot: nil, refreshesImmediately: false),
      recovery: RecoveredSessionController(managedRoot: nil),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: nil, samplesAutomatically: false)
    ).frame(width: 520, height: 1400)
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 1400),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 520, height: 1400))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let appeared = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard let review = self.view(identified: "Remote review", in: host),
        let status = self.field(labeled: "Provider authorization", in: review)
      else { return false }
      return status.stringValue == providerUnconfiguredNotice()
    }
    let review = try XCTUnwrap(self.view(identified: "Remote review", in: host))
    XCTAssertTrue(appeared && review.isDescendant(of: host) && window.contentView === host)
    let status = try XCTUnwrap(self.field(labeled: "Provider authorization", in: review))
    let outcome = try XCTUnwrap(self.field(labeled: "Provider authorization outcome", in: review))
    XCTAssertEqual(status.stringValue, providerUnconfiguredNotice())
    XCTAssertEqual(outcome.stringValue, "")
    let configure = try XCTUnwrap(self.button(titled: "Configure provider", in: review))
    let prepare = try XCTUnwrap(self.button(titled: "Prepare review", in: review))
    XCTAssertGreaterThan(configure.frame.width, 1)
    XCTAssertGreaterThan(configure.frame.height, 1)
    XCTAssertFalse(configure.isEnabled)
    XCTAssertFalse(prepare.isEnabled)
    for choice in ProviderAuthorizationModel.choices {
      let category = try XCTUnwrap(self.button(titled: choice.title, in: review))
      XCTAssertFalse(category.isEnabled)
      XCTAssertEqual(category.state, .off)
    }
    XCTAssertNil(self.button(titled: "Audio", in: review))
    XCTAssertNil(self.button(titled: "Snapshots", in: review))
    let limits = try XCTUnwrap(self.field(labeled: "Remote review limits", in: review))
    XCTAssertEqual(limits.stringValue, ProviderAuthorizationModel.unavailableNotice)

    self.replaceText(try XCTUnwrap(self.field(labeled: "Provider", in: review)), with: "example")
    self.replaceText(try XCTUnwrap(self.field(labeled: "Model", in: review)), with: "review")
    self.replaceText(
      try XCTUnwrap(self.field(labeled: "HTTPS origin", in: review)),
      with: "https://api.example.com/v1")
    self.replaceText(
      try XCTUnwrap(self.field(labeled: "Credential fingerprint", in: review)), with: secret)
    let configureReady = await waitUntil {
      host.layoutSubtreeIfNeeded()
      return configure.isEnabled
    }
    XCTAssertTrue(configureReady && window.contentView === host)
    configure.performClick(nil)
    let refused = await waitUntil {
      host.layoutSubtreeIfNeeded()
      return outcome.stringValue == ProviderAuthorizationModel.refusalNotice
        && self.field(labeled: "Credential fingerprint", in: review)?.stringValue.isEmpty == true
    }
    XCTAssertTrue(refused, outcome.stringValue)
    XCTAssertEqual(status.stringValue, providerUnconfiguredNotice())
    XCTAssertFalse(prepare.isEnabled)
    for choice in ProviderAuthorizationModel.choices {
      XCTAssertFalse(try XCTUnwrap(self.button(titled: choice.title, in: review)).isEnabled)
    }
    self.assertSecretAbsent(secret, in: host)

    self.replaceText(
      try XCTUnwrap(self.field(labeled: "Credential fingerprint", in: review)), with: digest)
    configure.performClick(nil)
    let configured = await waitUntil {
      host.layoutSubtreeIfNeeded()
      return status.stringValue == providerConfiguredNotice() && outcome.stringValue.isEmpty
    }
    XCTAssertTrue(configured, "\(status.stringValue) \(outcome.stringValue)")
    XCTAssertEqual(status.stringValue, "Provider configured — no conversation content authorized")
    XCTAssertFalse(prepare.isEnabled)
    for choice in ProviderAuthorizationModel.choices {
      let category = try XCTUnwrap(self.button(titled: choice.title, in: review))
      XCTAssertTrue(category.isEnabled)
      XCTAssertEqual(category.state, .off)
      XCTAssertGreaterThan(category.frame.height, 1)
    }
    let finalTranscript = try XCTUnwrap(self.button(titled: "Final transcript", in: review))
    finalTranscript.performClick(nil)
    let granted = await waitUntil { prepare.isEnabled && finalTranscript.state == .on }
    XCTAssertTrue(granted)
    for choice in ProviderAuthorizationModel.choices where choice.title != "Final transcript" {
      XCTAssertEqual(try XCTUnwrap(self.button(titled: choice.title, in: review)).state, .off)
    }
    prepare.performClick(nil)
    let prepared = await waitUntil {
      host.layoutSubtreeIfNeeded()
      return outcome.stringValue == providerNoOutboundNotice()
    }
    XCTAssertTrue(prepared, outcome.stringValue)
    XCTAssertEqual(outcome.stringValue, "No outbound request was made.")
    XCTAssertEqual(status.stringValue, providerConfiguredNotice())
    self.assertSecretAbsent(secret, in: host)
    XCTAssertTrue(window.contentView === host)
  }

  private func view(identified identifier: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == identifier { return root }
    for subview in root.subviews {
      if let found = view(identified: identifier, in: subview) { return found }
    }
    return nil
  }

  private func button(titled title: String, in root: NSView) -> NSButton? {
    if let button = root as? NSButton, button.title == title { return button }
    for subview in root.subviews {
      if let found = button(titled: title, in: subview) { return found }
    }
    return nil
  }

  private func field(labeled label: String, in root: NSView) -> NSTextField? {
    if let field = root as? NSTextField, field.accessibilityLabel() == label { return field }
    for subview in root.subviews {
      if let found = field(labeled: label, in: subview) { return found }
    }
    return nil
  }

  private func textFields(in root: NSView) -> [NSTextField] {
    var found: [NSTextField] = []
    if let field = root as? NSTextField { found.append(field) }
    for subview in root.subviews {
      found.append(contentsOf: textFields(in: subview))
    }
    return found
  }

  private func replaceText(_ field: NSTextField, with value: String) {
    XCTAssertNotNil(field.window)
    field.window?.makeFirstResponder(field)
    if let editor = field.currentEditor() as? NSTextView {
      editor.selectAll(nil)
      editor.insertText(value, replacementRange: editor.selectedRange())
      return
    }
    field.stringValue = value
    field.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: field))
  }

  private func assertSecretAbsent(
    _ secret: String, in root: NSView, file: StaticString = #filePath, line: UInt = #line
  ) {
    for field in textFields(in: root) {
      XCTAssertFalse(
        field.stringValue.contains(secret), "visible text includes the refused fingerprint",
        file: file, line: line)
    }
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    _ predicate: () -> Bool
  ) async -> Bool {
    let started = DispatchTime.now().uptimeNanoseconds
    while !predicate() {
      if DispatchTime.now().uptimeNanoseconds - started >= timeoutNanoseconds {
        return false
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
  }
}
