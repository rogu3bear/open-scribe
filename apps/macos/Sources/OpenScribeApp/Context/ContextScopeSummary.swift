import Foundation

/// The inspected scope and retention truth, worded once for every surface:
/// preflight, menu bar, live window, and saved review (ADR 0011).
enum ContextScopeSummary {
  static func modeName(_ mode: NativeContextMode) -> String {
    switch mode {
    case .followPointer: "Follow Pointer"
    case .watchDisplay: "Watch Display"
    case .watchWindow: "Watch Window"
    case .watchRegion: "Watch Region"
    case .addCurrentWindow: "Add Current Window"
    }
  }

  static func modeExplanation(_ mode: NativeContextMode) -> String {
    switch mode {
    case .followPointer:
      "Reads the window under the pointer after it rests there for about half a second. Moving across the screen records nothing."
    case .watchDisplay: "Reads one display about once a second while its text changes."
    case .watchWindow: "Reads one window about once a second while its text changes."
    case .watchRegion: "Reads one area of a display about once a second while its text changes."
    case .addCurrentWindow: "Reads one window once now, and again only when you choose Mark Now."
    }
  }

  static func target(_ request: NativeContextScopeRequest) -> String {
    guard let first = request.targets.first else { return "Nothing" }
    var text = first.description
    if request.targets.count > 1 {
      text += " and \(request.targets.count - 1) more display\(request.targets.count == 2 ? "" : "s")"
    }
    if let bounds = request.bounds {
      text += String(
        format: ", area at %.0f%%, %.0f%% sized %.0f%% × %.0f%%", bounds.x * 100, bounds.y * 100,
        bounds.width * 100, bounds.height * 100)
    }
    return text
  }

  static func condition(_ scope: NativeContextScope) -> String {
    switch scope.condition {
    case .active: "Active"
    case .paused:
      switch scope.reason {
      case "screen_locked": "Paused while the screen was locked"
      case "topology_changed": "Paused: the display arrangement changed"
      default: "Paused"
      }
    case .revoked: "Stopped"
    case .failed:
      switch scope.reason {
      case "permission_lost": "Stopped: Screen Recording permission was turned off"
      case "display_removed": "Stopped: a watched display was disconnected"
      default: "Stopped: the observed content became unavailable"
      }
    case .superseded: "Replaced by a newer scope"
    case .ended: "Ended with the recording"
    }
  }

  static let retention = "No screen images are kept. Only recognized text is saved."

  static func exclusions(_ exclusions: [String]) -> String {
    let names: [String: String] = [
      "open_scribe": "Open Scribe", "dock": "the Dock", "menu_bar": "the menu bar",
      "notifications": "notifications", "password_managers": "known password managers",
      "private_windows": "private browsing windows",
    ]
    let listed = exclusions.compactMap { names[$0] }
    var text = "Excluded where possible: " + ListFormatter.localizedString(byJoining: listed) + "."
    if exclusions.contains("lock_screen") { text += " Context pauses when the screen locks." }
    return text
  }

  static func permission(_ permission: NativeScreenPermission) -> String {
    permission == .granted
      ? "Screen Recording permission is on."
      : "Screen Recording permission is off. Open Scribe will ask when you authorize."
  }

  /// One line for compact surfaces, such as the menu bar.
  static func line(_ scope: NativeContextScope, events: UInt32) -> String {
    "\(modeName(scope.request.mode)): \(condition(scope)) · \(events) context event\(events == 1 ? "" : "s")"
  }
}
