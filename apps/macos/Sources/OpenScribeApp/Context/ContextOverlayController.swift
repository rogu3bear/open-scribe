import AppKit
import QuartzCore

/// Perimeter treatment states (ADR 0011, Exact overlay projection). The
/// overlay shows scope and attention only; it never represents retention,
/// and a revoked or failed scope has no halo at all.
enum ContextOverlayState: Equatable, Sendable {
  case eligible
  case hover
  case selected
  case active
  case paused
}

struct PerimeterStyle: Equatable, Sendable {
  let lineWidth: CGFloat
  let opacity: Float
  let bloomRadius: CGFloat
  let bloomOpacity: Float
  /// Increase Contrast: a 1-point black outer keyline.
  let keyline: Bool

  static func style(for state: ContextOverlayState, increaseContrast: Bool) -> PerimeterStyle {
    if increaseContrast {
      return PerimeterStyle(lineWidth: 2, opacity: 1, bloomRadius: 0, bloomOpacity: 0, keyline: true)
    }
    switch state {
    case .eligible:
      return PerimeterStyle(lineWidth: 1, opacity: 0.10, bloomRadius: 0, bloomOpacity: 0, keyline: false)
    case .hover:
      return PerimeterStyle(lineWidth: 1, opacity: 0.55, bloomRadius: 8, bloomOpacity: 0.20, keyline: false)
    case .selected:
      return PerimeterStyle(lineWidth: 2, opacity: 0.70, bloomRadius: 12, bloomOpacity: 0.25, keyline: false)
    case .active:
      return PerimeterStyle(lineWidth: 2, opacity: 0.90, bloomRadius: 16, bloomOpacity: 0.35, keyline: false)
    case .paused:
      return PerimeterStyle(lineWidth: 1, opacity: 0.30, bloomRadius: 0, bloomOpacity: 0, keyline: false)
    }
  }

  /// Luminance changes take 160 ms and depth changes 200 ms, ease-out;
  /// Reduce Motion caps every change at 100 ms of opacity only.
  static func transition(reduceMotion: Bool) -> (luminance: CFTimeInterval, depth: CFTimeInterval) {
    reduceMotion ? (0.1, 0) : (0.16, 0.2)
  }
}

/// Borderless, nonactivating, pointer-transparent panels that draw the
/// perimeter. They are not accessibility elements and are excluded from
/// every capture; the controlling SwiftUI surface carries names and actions.
@MainActor
final class ContextOverlayController {
  static let margin: CGFloat = 24
  private var panels: [String: NSPanel] = [:]

  /// Shows one perimeter per rectangle (global Core Graphics points).
  func show(_ rectangles: [String: CGRect], state: ContextOverlayState) {
    show(rectangles.mapValues { ($0, state) })
  }

  /// Shows each perimeter in its own state and removes any other.
  func show(_ perimeters: [String: (frame: CGRect, state: ContextOverlayState)]) {
    for key in Array(panels.keys) where perimeters[key] == nil {
      panels.removeValue(forKey: key)?.orderOut(nil)
    }
    for (key, perimeter) in perimeters {
      let panel = panels[key] ?? makePanel()
      panels[key] = panel
      panel.setFrame(
        Self.cocoaFrame(perimeter.frame).insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
      (panel.contentView as? PerimeterView)?.apply(perimeter.state)
      panel.orderFrontRegardless()
    }
  }

  /// One Active rise that returns to Selected; skipped under Reduce Motion.
  func pulse() {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    for panel in panels.values {
      guard let view = panel.contentView as? PerimeterView else { continue }
      view.apply(.active)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { view.apply(.selected) }
    }
  }

  func hide() {
    panels.values.forEach { $0.orderOut(nil) }
    panels.removeAll()
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .statusBar
    panel.sharingType = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
    panel.setAccessibilityElement(false)
    panel.contentView = PerimeterView()
    return panel
  }

  /// Converts top-left-origin global points to AppKit screen coordinates.
  static func cocoaFrame(_ rectangle: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? rectangle.maxY
    return CGRect(
      x: rectangle.minX, y: primaryHeight - rectangle.maxY,
      width: rectangle.width, height: rectangle.height)
  }
}

private final class PerimeterView: NSView {
  private let line = CAShapeLayer()
  private let keyline = CAShapeLayer()
  /// Keeps the bloom outside the perimeter.
  private let outside = CAShapeLayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for layer in [keyline, line] {
      layer.fillColor = nil
      layer.shadowOffset = .zero
      self.layer?.addSublayer(layer)
    }
    line.strokeColor = NSColor.white.cgColor
    line.shadowColor = NSColor.white.cgColor
    keyline.strokeColor = NSColor.black.cgColor
    outside.fillRule = .evenOdd
    line.mask = outside
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    let inner = bounds.insetBy(dx: ContextOverlayController.margin, dy: ContextOverlayController.margin)
    line.path = CGPath(rect: inner, transform: nil)
    keyline.path = CGPath(rect: inner.insetBy(dx: -1.5, dy: -1.5), transform: nil)
    line.frame = bounds
    keyline.frame = bounds
    let hole = CGMutablePath()
    hole.addRect(bounds)
    hole.addRect(inner.insetBy(dx: line.lineWidth / 2 + 0.5, dy: line.lineWidth / 2 + 0.5))
    outside.path = hole
    outside.frame = bounds
  }

  func apply(_ state: ContextOverlayState) {
    let workspace = NSWorkspace.shared
    let style = PerimeterStyle.style(
      for: state, increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    let timing = PerimeterStyle.transition(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
    CATransaction.begin()
    CATransaction.setAnimationDuration(timing.luminance)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
    line.lineWidth = style.lineWidth
    line.opacity = style.opacity
    line.shadowRadius = style.bloomRadius
    line.shadowOpacity = style.bloomOpacity
    keyline.lineWidth = style.keyline ? 1 : 0
    keyline.opacity = style.keyline ? 1 : 0
    CATransaction.commit()
    needsLayout = true
  }
}
