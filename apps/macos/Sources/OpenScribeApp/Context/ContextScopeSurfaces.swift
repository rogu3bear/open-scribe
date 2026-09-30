import AppKit

extension ContextScopeModel {
  /// Optional participants and topic. Declaring them grants no screen access.
  @discardableResult
  func declare(participants: String, topic: String) -> Bool {
    guard let binding = self.binding() else { return false }
    let names = participants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    do {
      _ = try binding.preparation.declareSession(
        sessionId: binding.sessionId,
        declaration: NativeSessionDeclaration(
          participants: names, topic: topic.isEmpty ? nil : topic))
      refreshDetail()
      return true
    } catch {
      return false
    }
  }

  /// The perimeter for the current scope: Selected while active, Paused
  /// while paused, and nothing once it stopped or ended.
  func updateOverlay() {
    guard let scope = current else {
      overlay.hide()
      return
    }
    switch scope.condition {
    case .active: overlay.show(rectangles(for: scope.request), state: .selected)
    case .paused: overlay.show(rectangles(for: scope.request), state: .paused)
    case .revoked, .failed, .superseded, .ended: overlay.hide()
    }
  }

  /// While choosing: every eligible choice faintly, the hovered one brighter.
  func previewOverlay(hovered: String?) {
    var perimeters: [String: (frame: CGRect, state: ContextOverlayState)] = [:]
    for choice in choices where (choice.kind == .window) == needsWindow {
      perimeters[choice.id] =
        choice.id == hovered ? (previewFrame(choice), .hover) : (choice.frame, .eligible)
    }
    overlay.show(perimeters)
  }

  func endPreview() { updateOverlay() }

  private func previewFrame(_ choice: ContextChoice) -> CGRect {
    guard selection.mode == .watchRegion, choice.kind == .display else { return choice.frame }
    return Self.regionFrame(selection.region, in: choice.frame)
  }

  static func regionFrame(_ region: CGRect, in display: CGRect) -> CGRect {
    CGRect(
      x: display.minX + region.minX * display.width, y: display.minY + region.minY * display.height,
      width: region.width * display.width, height: region.height * display.height)
  }

  func rectangles(for request: NativeContextScopeRequest) -> [String: CGRect] {
    let displays = Dictionary(
      ContextTopology.current().map { (String($0.id), $0.frame) }, uniquingKeysWith: { a, _ in a })
    var result: [String: CGRect] = [:]
    for target in request.targets {
      switch target.kind {
      case .display:
        guard let frame = displays[target.platformId] else { continue }
        if let bounds = request.bounds {
          result[target.platformId] = Self.regionFrame(
            CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height), in: frame)
        } else {
          result[target.platformId] = frame
        }
      case .window:
        if let id = CGWindowID(target.platformId), let frame = ContextWindowLocator.frame(of: id) {
          result[target.platformId] = frame
        }
      }
    }
    return result
  }
}

extension ContextWindowLocator {
  /// The window's current frame in global points, if it is still on screen.
  static func frame(of id: CGWindowID) -> CGRect? {
    guard
      let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
      let info = list.first,
      let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary
    else { return nil }
    return CGRect(dictionaryRepresentation: boundsInfo)
  }
}
