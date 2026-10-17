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

  private func session(_ id: String, title: String, lifecycle: String)
    -> RuntimeSessionPresentation
  {
    RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: id, title: title, lifecycle: lifecycle,
        health: lifecycle == "interrupted" ? "degraded" : "healthy",
        elapsedSeconds: 125, journalDurable: true,
        mediaFilesOpen: lifecycle == "recording", interruptionReason: nil,
        recovered: false, hasCaptureTimeline: false, sources: [], playableMedia: nil,
        transcript: NativeRuntimeTranscriptSnapshot(
          document: .final, replacementResumable: false, state: .final,
          selectedRevisionIds: ["reviewed-final"], documentVersion: "visual-fixture",
          attempt: .complete, attemptFailure: nil, totalTracks: 1, finalTracks: 1,
          completedChunks: 1, totalChunks: 1, failureClass: nil)
      ))
  }
}
