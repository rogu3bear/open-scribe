import AppKit
import SwiftUI
import XCTest

@testable import OpenScribeApp

/// Renders the main window in representative states for design review.
///
/// Runs only when the test runner supplies `OPEN_SCRIBE_SNAPSHOT_DIR`
/// (`TEST_RUNNER_OPEN_SCRIBE_SNAPSHOT_DIR` for xcodebuild). The transcript
/// state also needs `OPEN_SCRIBE_WHISPER_MODEL` and
/// `OPEN_SCRIBE_SNAPSHOT_CONVERSATION` (a synthetic M4A conversation).
/// The images are review evidence, not assertions about product behavior.
@MainActor
final class DesignSnapshotTests: XCTestCase {
  private static let windowSize = NSSize(width: 1180, height: 780)

  private func outputDirectory() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["OPEN_SCRIBE_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set OPEN_SCRIBE_SNAPSHOT_DIR to render design snapshots.")
    }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testRenderEmptyLibrary() async throws {
    let output = try outputDirectory()
    let root = try Self.temporaryRoot("empty")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await SnapshotFixture(managedRoot: root)
    for dark in [false, true] {
      try await render(
        fixture.contentView(), named: "empty", dark: dark, output: output)
    }
    withExtendedLifetime(fixture) {}
  }

  func testRenderTranscribedConversation() async throws {
    let output = try outputDirectory()
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let conversationPath = environment["OPEN_SCRIBE_SNAPSHOT_CONVERSATION"]
    else {
      throw XCTSkip("Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_SNAPSHOT_CONVERSATION.")
    }
    let root = try Self.temporaryRoot("library")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await SnapshotFixture(managedRoot: root.appendingPathComponent("Library"))
    let titles = [
      "Conversation 2026-11-10T15:02:11Z",
      "Conversation 2026-11-11T18:40:37Z",
      "Conversation 2026-11-12T19:30:05Z",
    ]
    var sessionIds: [String] = []
    for (index, title) in titles.enumerated() {
      let copy = root.appendingPathComponent("conversation-\(index).m4a")
      try FileManager.default.copyItem(at: URL(fileURLWithPath: conversationPath), to: copy)
      sessionIds.append(try fixture.store.importManagedAudio(title: title, sourceURL: copy).sessionId)
    }
    await fixture.speech.refreshAndWait()
    let record = try XCTUnwrap(fixture.speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await fixture.speech.install(record, from: URL(fileURLWithPath: modelPath))
    XCTAssertTrue(installed, fixture.speech.message ?? "")
    let transcribed = await Self.waitUntil(timeoutNanoseconds: 300_000_000_000) {
      fixture.store.refresh()
      return sessionIds.allSatisfy { id in
        fixture.store.savedSessions.first { $0.sessionId == id }?.transcript.documentAvailability
          == .final
      } && fixture.scheduler.runningSessionId == nil
    }
    XCTAssertTrue(transcribed, "transcription did not finish")
    // Titles come from the real suggester: Apple Intelligence on this Mac
    // when it is available, otherwise names and words in the transcript.
    fixture.suggestions.considerLibrary(fixture.store.savedSessions)
    let suggested = await Self.waitUntil(timeoutNanoseconds: 120_000_000_000) {
      fixture.store.refresh()
      return fixture.store.savedSessions.filter { $0.titleSource == "suggested" }.count
        == sessionIds.count
    }
    print(
      "DESIGN_SNAPSHOT_TITLES suggested=\(suggested) "
        + fixture.store.savedSessions.map { "\($0.titleSource):\($0.displayTitle)" }
        .joined(separator: " | "))
    fixture.navigation.select(sessionIds.last)
    let preferences = UserDefaults(suiteName: "OpenScribe.Proof.SnapshotView.\(UUID().uuidString)")!
    for dark in [false, true] {
      try await render(
        fixture.contentView().defaultAppStorage(preferences), named: "conversation", dark: dark,
        output: output, settle: 3_000_000_000)
    }
    preferences.set(true, forKey: ConversationWorkspaceView.detailsDefaultsKey)
    try await render(
      fixture.contentView().defaultAppStorage(preferences), named: "conversation-details",
      dark: false, output: output, settle: 3_000_000_000)
    withExtendedLifetime(fixture) {}
  }

  func testRenderLiveRecording() async throws {
    let output = try outputDirectory()
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    harness.storage.set(64 * 1024 * 1024 * 1024)
    let fixture = try await SnapshotFixture(
      managedRoot: harness.root, liveRecording: harness.controller)
    await harness.controller.start()
    let started = await Self.waitUntil(timeoutNanoseconds: 8_000_000_000) {
      harness.captures.microphones.last?.didStart == true
        && harness.captures.systems.last?.didStart == true
    }
    XCTAssertTrue(started)
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    try microphone.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    _ = await Self.waitUntil(timeoutNanoseconds: 8_000_000_000) {
      fixture.store.refresh()
      return harness.controller.phase == .capturing && fixture.store.currentSession != nil
    }
    fixture.navigation.select(fixture.store.currentSession?.sessionId)
    for dark in [false, true] {
      try await render(fixture.contentView(), named: "live", dark: dark, output: output)
    }
    await harness.controller.stop()
    withExtendedLifetime(fixture) {}
  }

  // MARK: - Rendering

  private func render(
    _ view: some View, named name: String, dark: Bool, output: URL,
    settle: UInt64 = 1_500_000_000
  ) async throws {
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.windowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Open Scribe"
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    window.setContentSize(Self.windowSize)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let deadline = DispatchTime.now().uptimeNanoseconds + settle
    while DispatchTime.now().uptimeNanoseconds < deadline {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    let file = output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    try? FileManager.default.removeItem(at: file)
    if !dark {
      var lines: [String] = []
      Self.describe(host, depth: 0, into: &lines, in: host)
      try lines.joined(separator: "\n").write(
        to: output.appendingPathComponent("\(name)-tree.txt"), atomically: true, encoding: .utf8)
    }
    // A watcher outside the test process captures exactly this window with
    // `screencapture -l`, which records the composited pixels SwiftUI draws.
    let request = output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").request")
    try "\(window.windowNumber)\n".write(to: request, atomically: true, encoding: .utf8)
    let captured = await Self.waitUntil(timeoutNanoseconds: 1_000_000_000) {
      window.displayIfNeeded()
      return FileManager.default.fileExists(atPath: file.path)
        && !FileManager.default.fileExists(atPath: request.path)
    }
    if !captured {
      try? FileManager.default.removeItem(at: request)
      let frameView = window.contentView?.superview ?? host
      guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
        XCTFail("no bitmap for \(name)")
        return
      }
      frameView.cacheDisplay(in: frameView.bounds, to: rep)
      let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      try data.write(to: file)
      print("DESIGN_SNAPSHOT_FALLBACK \(file.path)")
    } else {
      print("DESIGN_SNAPSHOT \(file.path)")
    }
  }

  private static func describe(_ view: NSView, depth: Int, into lines: inout [String], in root: NSView) {
    guard depth < 40 else { return }
    let frame = view.convert(view.bounds, to: root)
    let kind = String(describing: type(of: view))
    var detail = ""
    if let field = view as? NSTextField { detail = " text=\"\(field.stringValue.prefix(60))\"" }
    if let button = view as? NSButton { detail = " button=\"\(button.title.prefix(40))\"" }
    if let layer = view.layer, let color = layer.backgroundColor, color.alpha > 0 {
      detail += " bg=\(color.alpha)"
    }
    if view.isOpaque { detail += " opaque" }
    let shown = view.isHiddenOrHasHiddenAncestor ? "hidden" : "shown"
    let line =
      String(repeating: " ", count: depth)
      + "\(kind) [\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))] \(shown)\(detail)"
    lines.append(line)
    for child in view.subviews { describe(child, depth: depth + 1, into: &lines, in: root) }
  }

  private static func temporaryRoot(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-snapshot-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func waitUntil(
    timeoutNanoseconds: UInt64, _ predicate: @escaping @MainActor () -> Bool
  ) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    return predicate()
  }
}

/// The production object graph over an isolated library, with fakes only for
/// playback, screen context, and capture permission.
@MainActor
private final class SnapshotFixture {
  let store: RuntimeLibraryStore
  let liveRecording: LiveMicrophoneRecordingController
  let recovery: RecoveredSessionController
  let transcripts: TranscriptLibraryModel
  let speech: SpeechTranscriptionModel
  let scheduler: TranscriptionScheduler
  let pressure: SystemPressureMonitor
  let context: ContextScopeModel
  let navigation = MainWorkspaceNavigation()
  let importAuthority: ImportedMediaAuthorityAdapter
  let suggestions: ConversationSuggestionModel

  init(managedRoot: URL, liveRecording: LiveMicrophoneRecordingController? = nil) async throws {
    try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
    let recovery = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: managedRoot.path) },
      importedPlaybackLeaseProvider: { sessionId in
        try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
          .leaseImportedPlayback(sessionId: sessionId)
      },
      player: RecoveredAudioPlayerFake()
    )
    self.recovery = recovery
    let live = liveRecording ?? LiveMicrophoneRecordingController(managedRoot: managedRoot)
    live.isLaunchRecoveryPending = { !recovery.captureSafetyComplete }
    self.liveRecording = live
    let store = RuntimeLibraryStore(
      managedRoot: managedRoot, isLaunchRecoveryPending: { !recovery.captureSafetyComplete })
    self.store = store
    importAuthority = ImportedMediaAuthorityAdapter(
      canBeginImport: { live.canStart },
      importer: { title, url in try store.importManagedAudio(title: title, sourceURL: url) })
    let transcripts = TranscriptLibraryModel(managedRoot: managedRoot)
    self.transcripts = transcripts
    suggestions = ConversationSuggestionModel(library: { try await transcripts.connectedLibrary() })
    let speech = SpeechTranscriptionModel(managedRoot: managedRoot)
    self.speech = speech
    let pressure = SystemPressureMonitor(libraryRoot: managedRoot, samplesAutomatically: false)
    self.pressure = pressure
    let defaults = UserDefaults(suiteName: "OpenScribe.Proof.Snapshot.\(UUID().uuidString)")!
    scheduler = TranscriptionScheduler(
      managedRoot: managedRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    context = ContextScopeModel(
      binding: { nil }, frames: SnapshotIdleFrames(), permissionCheck: { .denied },
      permissionRequest: { .denied }, topology: { [] })
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    store.refresh()
  }

  func contentView() -> ContentView {
    ContentView(
      store: store, importedMediaAuthority: importAuthority, liveRecording: liveRecording,
      recoveredSessions: recovery, transcripts: transcripts, speech: speech,
      scheduler: scheduler, pressure: pressure, context: context, navigation: navigation,
      suggestions: suggestions)
  }
}

private struct SnapshotIdleFrames: ContextFrameCapturing {
  func captureFrame(_ target: ContextCaptureTarget) async throws -> CGImage {
    throw CancellationError()
  }
}
