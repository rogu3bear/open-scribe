import AppKit
import SwiftUI
import XCTest

@testable import OpenScribeApp

@MainActor
final class ConversationSidebarRowTests: XCTestCase {
  /// Mount the production row in a real sidebar List. Optional PNGs are
  /// in-process renders for visual inspection, not screen-capture evidence.
  func testTwoLineRowsMountInLightAndDarkSidebars() async throws {
    let sessions = [
      session("reviewed", title: "Reviewed agreement", lifecycle: "ready_for_review"),
      session("recording", title: "Deliberate recording", lifecycle: "recording"),
      session("interrupted", title: "Interrupted conversation", lifecycle: "interrupted"),
      session(
        "unavailable", title: "Missing source audio", lifecycle: "ready_for_review",
        media: unavailableMedia("unavailable")),
      session(
        "corrupt", title: "Damaged source audio", lifecycle: "ready_for_review",
        media: unavailableMedia("corrupt")),
    ]
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      for selected in sessions {
        let view = List(selection: Binding<String?>.constant(selected.sessionId)) {
          ForEach(sessions) { session in
            ConversationSidebarRow(
              session: session, reference: "a1b2c3",
              isSelected: selected.sessionId == session.sessionId
            ).tag(session.sessionId)
          }
        }
        .listStyle(.sidebar)
        .frame(width: 340, height: 300)
        .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, 340, accuracy: 1)
        XCTAssertEqual(host.bounds.height, 300, accuracy: 1)
        if let directory = ProcessInfo.processInfo.environment["OPEN_SCRIBE_RENDER_DIR"] {
          let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: image)
          let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
          let mode = appearance == .aqua ? "light" : "dark"
          try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(
              "sidebar-\(mode)-\(selected.sessionId).png"))
        }
      }
    }
  }

  func testUnavailableAudioTakesPriorityOverTranscriptPosture() {
    for availability in ["unavailable", "corrupt"] {
      for state in [NativeRuntimeTranscriptState.none, .final] {
        let saved = session(
          "unreadable", title: "Preserved import", lifecycle: "ready_for_review",
          media: unavailableMedia(availability), transcriptState: state)
        XCTAssertFalse(
          saved.needsAttention, "capture health and media availability are independent")
        XCTAssertTrue(saved.transcript.hasTranscribableAudio, "sealed track metadata survives")
        let row = ConversationSidebarRow(session: saved, reference: nil, isSelected: true)
        XCTAssertEqual(row.detailStatusText, saved.statusText)
        XCTAssertEqual(row.statusSymbolName, "exclamationmark.triangle")
        XCTAssertEqual(
          row.detailStatusText,
          availability == "corrupt" ? "Audio appears corrupt" : "Audio unavailable")
      }
    }
  }

  func testReplacementFailureKeepsAVisibleWarningWithoutAddingRoutineIcons() {
    let failed = session(
      "failed-replacement", title: "Reviewed agreement", lifecycle: "ready_for_review",
      attempt: .failed)
    let failedRow = ConversationSidebarRow(session: failed, reference: nil, isSelected: true)
    XCTAssertEqual(failedRow.detailStatusText, "Transcript ready · replacement failed")
    XCTAssertEqual(failedRow.statusSymbolName, "exclamationmark.circle")
    let complete = session(
      "reviewed", title: "Reviewed agreement", lifecycle: "ready_for_review")
    let completeRow = ConversationSidebarRow(session: complete, reference: nil, isSelected: false)
    XCTAssertEqual(completeRow.detailStatusText, "Transcript ready")
    XCTAssertNil(completeRow.statusSymbolName)
  }

  /// Use actual first-responder and key-window transitions. Injecting a SwiftUI
  /// controlActiveState does not change AppKit's List highlight and is not this test.
  func testSelectedRowAcrossNativeFocusAndWindowTransitions() async throws {
    let saved = session(
      "failed-replacement", title: "Reviewed agreement", lifecycle: "ready_for_review",
      attempt: .failed)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      for width in [220.0, 260.0] {
        let host = NSHostingView(
          rootView: List(selection: Binding<String?>.constant(saved.sessionId)) {
            ConversationSidebarRow(session: saved, reference: "a1b2c3", isSelected: true)
              .tag(saved.sessionId)
          }
          .listStyle(.sidebar)
          .frame(width: width, height: 240)
          .environment(\.colorScheme, appearance == .aqua ? .light : .dark))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width + 360, height: 240))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 240)
        content.addSubview(host)
        let editor = NSTextField(string: "Review editor")
        editor.frame = NSRect(x: width + 24, y: 140, width: 300, height: 30)
        content.addSubview(editor)
        let window = NSWindow(
          contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = content
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        try await makeKeyWhenActive(window)
        let table = try XCTUnwrap(findTable(in: host))
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertTrue(NSApp.isActive)
        XCTAssertTrue(window.isKeyWindow)
        try await captureFocus(
          host, window: window, expectedKeyWindow: window,
          appearance: appearance, width: width, phase: "list")
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertNotNil(editor.currentEditor())
        XCTAssertTrue(window.isKeyWindow)
        try await captureFocus(
          host, window: window, expectedKeyWindow: window,
          appearance: appearance, width: width, phase: "editor")
        let other = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
          styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        try await makeKeyWhenActive(other)
        XCTAssertTrue(other.isKeyWindow)
        XCTAssertFalse(window.isKeyWindow)
        try await captureFocus(
          host, window: window, expectedKeyWindow: other,
          appearance: appearance, width: width, phase: "inactive")
      }
    }
  }

  private func unavailableMedia(_ availability: String) -> NativeRuntimePlayableMediaSnapshot {
    NativeRuntimePlayableMediaSnapshot(
      sourceDisplayName: "Fixture import", availability: availability, absolutePath: nil,
      durationNanoseconds: 125_000_000_000, sampleCount: 6_000_000, byteLength: 12_000_068)
  }

  private func findTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    return view.subviews.lazy.compactMap { self.findTable(in: $0) }.first
  }

  private func makeKeyWhenActive(_ window: NSWindow) async throws {
    // Activation and launch/window restoration are asynchronous. A fixed sleep
    // does not establish the AppKit state required by the contrast test.
    let deadline = ContinuousClock.now + .seconds(3)
    repeat {
      NSApp.activate(ignoringOtherApps: true)
      NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
      window.makeKeyAndOrderFront(nil)
      if NSApp.isActive && window.isKeyWindow { return }
      try await Task.sleep(for: .milliseconds(25))
    } while ContinuousClock.now < deadline
    XCTFail("The native focus fixture did not become the active key window within three seconds.")
  }

  private func captureFocus<V: View>(
    _ host: NSHostingView<V>, window: NSWindow, expectedKeyWindow: NSWindow,
    appearance: NSAppearance.Name,
    width: Double, phase: String
  ) async throws {
    try await Task.sleep(for: .milliseconds(150))
    // Activation may change while layout settles. Establish the real AppKit
    // state after that yield, then assert and render without another suspension.
    try await makeKeyWhenActive(expectedKeyWindow)
    XCTAssertTrue(NSApp.isActive)
    XCTAssertTrue(expectedKeyWindow.isKeyWindow)
    XCTAssertTrue(NSApp.keyWindow === expectedKeyWindow)
    XCTAssertEqual(window.isKeyWindow, phase != "inactive", "native state at the actual capture")
    host.layoutSubtreeIfNeeded()
    let mode = appearance == .aqua ? "light" : "dark"
    let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
    print(
      "SIDEBAR_FOCUS mode=\(mode) width=\(width) phase=\(phase) key=\(window.isKeyWindow) main=\(window.isMainWindow) appActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) canKey=\(window.canBecomeKey) running=\(NSApp.isRunning) responder=\(responder)"
    )
    if let directory = ProcessInfo.processInfo.environment["OPEN_SCRIBE_RENDER_DIR"] {
      let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: image)
      let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent(
          "focus-\(mode)-\(Int(width))-\(phase).png"))
    }
  }

  private func session(
    _ id: String, title: String, lifecycle: String,
    media: NativeRuntimePlayableMediaSnapshot? = nil,
    transcriptState: NativeRuntimeTranscriptState = .final, attempt: NativeAttemptState = .complete
  )
    -> RuntimeSessionPresentation
  {
    RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: id, title: title, lifecycle: lifecycle,
        health: lifecycle == "interrupted" ? "degraded" : "healthy",
        elapsedSeconds: 125, journalDurable: true,
        mediaFilesOpen: lifecycle == "recording", interruptionReason: nil,
        recovered: false, hasCaptureTimeline: false, sources: [], playableMedia: media,
        transcript: NativeRuntimeTranscriptSnapshot(
          document: transcriptState == .final ? .final : .none, replacementResumable: false,
          state: transcriptState,
          selectedRevisionIds: transcriptState == .final ? ["reviewed-final"] : [],
          documentVersion: "visual-fixture",
          attempt: attempt, attemptFailure: attempt == .failed ? "engine_error" : nil,
          totalTracks: 1, finalTracks: transcriptState == .final ? 1 : 0,
          completedChunks: 1, totalChunks: 1, failureClass: nil)
      ))
  }
}
