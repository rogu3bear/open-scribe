import AppKit
import SwiftUI

// Hosted controls: the AppKit views the window, the menu bar and the
// document use for anything a hosted proof must find, press or read.
//
// A SwiftUI `Text` or `Button` publishes no AppKit view that a hosted XCTest
// can find by identifier or label, and a row SwiftUI inserts after the first
// layout may not be in the hosting view yet when the proof looks. So each
// control here is created with its SwiftUI parent's first layout and only
// updated afterwards: a later state change reveals or refills it in place.
//
// Each control sizes itself. SwiftUI asks `sizeThatFits` with the width it
// offers; a button answers its fitting size, text its wrapped height at that
// width, a list or panel the height of its content. A hidden control answers
// 0×0, so it takes no space and its parent needs no fixed frame, no minimum
// height formula, and no reserved row.

extension NSEvent.ModifierFlags {
  /// The AppKit mask for a SwiftUI shortcut's modifiers.
  init(_ modifiers: EventModifiers) {
    self = []
    if modifiers.contains(.command) { insert(.command) }
    if modifiers.contains(.shift) { insert(.shift) }
    if modifiers.contains(.option) { insert(.option) }
    if modifiers.contains(.control) { insert(.control) }
  }
}

extension NSButton {
  /// The key equivalent of one of the conversation shortcuts, or none.
  func setShortcut(_ shortcut: ConversationShortcut?) {
    keyEquivalent = shortcut.map { String($0.key.character) } ?? ""
    keyEquivalentModifierMask = shortcut.map { NSEvent.ModifierFlags($0.modifiers) } ?? []
  }
}

extension NSFont {
  /// New York at `size`, the title face of the Interview Page.
  static func interviewTitle(_ size: CGFloat = 30) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .semibold)
    return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
      ?? base
  }
}

/// The width SwiftUI offered, when it is a real width.
private func offeredWidth(_ width: CGFloat?) -> CGFloat? {
  guard let width, width.isFinite, width > 0 else { return nil }
  return width
}

// MARK: - Button

/// One AppKit button. The title stays on the button even when only its
/// symbol shows, so menus and VoiceOver read the same words.
struct HostedButton: NSViewRepresentable {
  enum Style: Equatable {
    /// A standard push button.
    case push
    /// A push button at the large control size, for the document's action row.
    case large
    /// Record: a record symbol before a semibold title.
    case record
    /// A borderless symbol at `pointSize`, in secondary ink.
    case symbol(pointSize: CGFloat)
    /// A timestamp in the shoulder: borderless monospaced digits, accent and
    /// semibold while that moment plays.
    case stamp(isPlaying: Bool)
  }

  let title: String
  var symbol: String?
  var identifier: String?
  /// What VoiceOver and hosted proofs read; the title when nil.
  var label: String?
  var shortcut: ConversationShortcut?
  var help: String?
  var style: Style = .push
  var minimumSize: CGSize = .zero
  var isEnabled = true
  var isHidden = false
  let action: @MainActor () -> Void

  func makeNSView(context: Context) -> HostedButtonView {
    let button = HostedButtonView()
    button.apply(self)
    return button
  }

  func updateNSView(_ button: HostedButtonView, context: Context) {
    button.apply(self)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: HostedButtonView, context: Context)
    -> CGSize?
  {
    nsView.hostedSize
  }
}

final class HostedButtonView: NSButton {
  private var handler: (@MainActor () -> Void)?
  private var appliedStyle: HostedButton.Style?
  private var appliedSymbol: String?
  private var minimumSize: CGSize = .zero

  init() {
    super.init(frame: .zero)
    setButtonType(.momentaryPushIn)
    bezelStyle = .rounded
    target = self
    action = #selector(activate)
  }

  required init?(coder: NSCoder) { nil }

  var hostedSize: CGSize {
    guard !isHidden else { return .zero }
    let natural = intrinsicContentSize
    return CGSize(
      width: ceil(max(natural.width, minimumSize.width)),
      height: ceil(max(natural.height, minimumSize.height)))
  }

  func apply(_ button: HostedButton) {
    handler = button.action
    minimumSize = button.minimumSize
    let titleChanged = title != button.title
    if case .stamp(let isPlaying) = button.style {
      let color: NSColor =
        isPlaying
        ? NSColor(Interview.accent) : button.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
      attributedTitle = NSAttributedString(
        string: button.title,
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: isPlaying ? .semibold : .regular),
          .foregroundColor: color,
        ])
    } else if titleChanged {
      title = button.title
    }
    // AppKit turns an image-only button into an image-over-title one when its
    // title is set, so the style goes on after the title, every time it changes.
    if titleChanged || appliedStyle != button.style || appliedSymbol != button.symbol {
      applyStyle(button.style, symbol: button.symbol)
      appliedStyle = button.style
      appliedSymbol = button.symbol
      invalidateIntrinsicContentSize()
    }
    setAccessibilityLabel(button.label ?? button.title)
    if let identifier = button.identifier { setAccessibilityIdentifier(identifier) }
    setShortcut(button.shortcut)
    toolTip = button.help
    isEnabled = button.isEnabled
    if isHidden != button.isHidden {
      isHidden = button.isHidden
      invalidateIntrinsicContentSize()
    }
  }

  private func applyStyle(_ style: HostedButton.Style, symbol: String?) {
    let template = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    switch style {
    case .push, .large:
      isBordered = true
      bezelStyle = .rounded
      controlSize = style == .large ? .large : .regular
      image = template
      imagePosition = template == nil ? .noImage : .imageLeading
    case .record:
      isBordered = true
      bezelStyle = .rounded
      controlSize = .regular
      font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
      // Red means a recording is running (DESIGN.md section 6), so the idle
      // Record control draws its symbol in label ink.
      let configuration = NSImage.SymbolConfiguration(
        pointSize: NSFont.systemFontSize, weight: .semibold
      ).applying(NSImage.SymbolConfiguration(hierarchicalColor: .labelColor))
      image = NSImage(
        systemSymbolName: symbol ?? "record.circle", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
      imagePosition = .imageLeading
      imageHugsTitle = true
    case .symbol(let pointSize):
      isBordered = false
      bezelStyle = .smallSquare
      image = template?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
      imagePosition = .imageOnly
      contentTintColor = .secondaryLabelColor
    case .stamp:
      isBordered = false
      bezelStyle = .inline
      alignment = .right
      image = nil
      imagePosition = .noImage
    }
  }

  @objc private func activate() {
    guard isEnabled, !isHidden else { return }
    handler?()
  }
}

// MARK: - Text

/// One AppKit text field: a notice, a readout, or a title. Empty text hides
/// it, and a hidden field takes no space.
struct HostedText: NSViewRepresentable {
  let text: String?
  var identifier: String?
  /// What VoiceOver and hosted proofs read; the text when nil.
  var label: String?
  var font: NSFont = .systemFont(ofSize: 13)
  var color: NSColor = .labelColor
  var maximumLines = 0
  var isSelectable = false
  var help: String?
  var onDoubleClick: (@MainActor () -> Void)?

  func makeNSView(context: Context) -> HostedTextView {
    let field = HostedTextView()
    field.apply(self)
    return field
  }

  func updateNSView(_ field: HostedTextView, context: Context) {
    field.apply(self)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: HostedTextView, context: Context)
    -> CGSize?
  {
    nsView.hostedSize(width: proposal.width)
  }
}

final class HostedTextView: NSTextField {
  private var onDoubleClick: (@MainActor () -> Void)?

  init() {
    super.init(frame: .zero)
    isEditable = false
    isSelectable = false
    isBezeled = false
    isBordered = false
    drawsBackground = false
    lineBreakMode = .byWordWrapping
    cell?.wraps = true
    cell?.isScrollable = false
    cell?.truncatesLastVisibleLine = true
    setAccessibilityRole(.staticText)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  required init?(coder: NSCoder) { nil }

  func apply(_ text: HostedText) {
    let value = text.text ?? ""
    if stringValue != value { stringValue = value }
    if font != text.font { font = text.font }
    if textColor != text.color { textColor = text.color }
    maximumNumberOfLines = text.maximumLines
    isSelectable = text.isSelectable
    toolTip = text.help
    onDoubleClick = text.onDoubleClick
    if let identifier = text.identifier { setAccessibilityIdentifier(identifier) }
    setAccessibilityLabel(text.label ?? value)
    let hidden = value.isEmpty
    if isHidden != hidden {
      isHidden = hidden
      invalidateIntrinsicContentSize()
    }
  }

  /// The wrapped size at the offered width; one line's width when none is offered.
  func hostedSize(width: CGFloat?) -> CGSize {
    guard !isHidden else { return .zero }
    let measure = offeredWidth(width) ?? Interview.measure
    if preferredMaxLayoutWidth != measure { preferredMaxLayoutWidth = measure }
    let natural = intrinsicContentSize
    return CGSize(
      width: offeredWidth(width) ?? ceil(min(natural.width, measure)),
      height: ceil(max(natural.height, 0)))
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2, let onDoubleClick {
      onDoubleClick()
    } else {
      super.mouseDown(with: event)
    }
  }
}

// MARK: - List

/// One row of a hosted list: a lead control (a timestamp or a whole-row
/// button) and optional text after it.
struct HostedListRow: Equatable {
  let id: String
  let lead: String
  var detail: String?
  /// What VoiceOver and hosted proofs read for the lead control.
  let label: String
  var isEnabled = true
}

/// One AppKit list: markers, search matches. Rows are rebuilt only when
/// their content changes; an empty list without an empty sentence is hidden.
struct HostedList: NSViewRepresentable {
  enum Lead: Equatable {
    /// A timestamp button that plays from that moment.
    case stampButton
    /// A timestamp that only names the moment.
    case stampText
    /// A whole-row button.
    case button
  }

  var heading: String?
  let identifier: String
  let rows: [HostedListRow]
  let lead: Lead
  /// Shown, instead of hiding the list, when there are no rows.
  var emptyText: String?
  var maximumHeight: CGFloat?
  var onSelect: (@MainActor (String) -> Void)?

  func makeNSView(context: Context) -> HostedListView {
    let view = HostedListView()
    view.apply(self)
    return view
  }

  func updateNSView(_ view: HostedListView, context: Context) {
    view.apply(self)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: HostedListView, context: Context)
    -> CGSize?
  {
    nsView.hostedSize(width: proposal.width)
  }
}

final class HostedListView: HostedPanel {
  private let heading = NSTextField(labelWithString: "")
  private let empty = NSTextField(wrappingLabelWithString: "")
  private let rows = NSStackView()
  private var signature: [String] = []
  private var maximumHeight: CGFloat?
  private var onSelect: (@MainActor (String) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    heading.font = .systemFont(ofSize: 11, weight: .semibold)
    heading.textColor = .secondaryLabelColor
    empty.font = .preferredFont(forTextStyle: .callout)
    empty.textColor = .secondaryLabelColor
    empty.maximumNumberOfLines = 2
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 4
    content.addArrangedSubview(heading)
    content.addArrangedSubview(empty)
    content.addArrangedSubview(rows)
    content.spacing = 4
  }

  required init?(coder: NSCoder) { nil }

  override var isShowingContent: Bool {
    !isHidden && (!rows.arrangedSubviews.isEmpty || !empty.isHidden)
  }

  override func prepareLayout(width: CGFloat) {
    empty.preferredMaxLayoutWidth = width
  }

  override func hostedSize(width: CGFloat?) -> CGSize {
    let size = super.hostedSize(width: width)
    guard let maximumHeight else { return size }
    return CGSize(width: size.width, height: min(size.height, maximumHeight))
  }

  func apply(_ list: HostedList) {
    onSelect = list.onSelect
    maximumHeight = list.maximumHeight
    setAccessibilityIdentifier(list.identifier)
    heading.stringValue = list.heading ?? ""
    heading.setAccessibilityLabel(list.heading)
    heading.setAccessibilityIdentifier(list.heading)
    heading.isHidden = list.heading == nil || list.rows.isEmpty
    let emptyText = list.rows.isEmpty ? list.emptyText : nil
    empty.stringValue = emptyText ?? ""
    empty.setAccessibilityLabel(list.emptyText)
    empty.isHidden = emptyText == nil
    rows.isHidden = list.rows.isEmpty
    let next = list.rows.map {
      "\($0.id)\n\($0.lead)\n\($0.detail ?? "")\n\($0.label)\n\($0.isEnabled)"
    }
    if next != signature {
      signature = next
      for view in rows.arrangedSubviews {
        rows.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      for row in list.rows {
        rows.addArrangedSubview(view(for: row, lead: list.lead))
      }
    }
    invalidateIntrinsicContentSize()
  }

  private func view(for row: HostedListRow, lead: HostedList.Lead) -> NSView {
    let control: NSControl
    switch lead {
    case .stampButton, .button:
      let button = NSButton(title: row.lead, target: self, action: #selector(select(_:)))
      if lead == .stampButton {
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        button.contentTintColor = NSColor(Interview.accent)
      } else {
        button.bezelStyle = .rounded
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      }
      button.isEnabled = row.isEnabled
      button.identifier = NSUserInterfaceItemIdentifier(row.id)
      control = button
    case .stampText:
      let stamp = NSTextField(labelWithString: row.lead)
      stamp.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      stamp.textColor = .secondaryLabelColor
      stamp.setAccessibilityRole(.staticText)
      control = stamp
    }
    control.setAccessibilityLabel(row.label)
    control.setAccessibilityIdentifier(row.id)
    control.setContentCompressionResistancePriority(.required, for: .vertical)
    guard let detail = row.detail else { return control }
    let text = NSTextField(labelWithString: detail)
    text.font = .systemFont(ofSize: 13)
    text.textColor = .labelColor
    text.setAccessibilityLabel(detail)
    text.setAccessibilityRole(.staticText)
    text.lineBreakMode = .byTruncatingTail
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let line = NSStackView(views: [control, text])
    line.orientation = .horizontal
    line.alignment = .firstBaseline
    line.spacing = ScribeSpacing.related
    return line
  }

  @objc private func select(_ sender: NSButton) {
    guard sender.isEnabled, let id = sender.identifier?.rawValue else { return }
    onSelect?(id)
  }
}

// MARK: - Panel

/// The base of every composite hosted control: content in one vertical
/// stack, measured at the offered width. While it shows nothing it is 0×0.
class HostedPanel: NSView {
  let content = NSStackView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = ScribeSpacing.related
    content.detachesHiddenViews = true
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
      content.topAnchor.constraint(equalTo: topAnchor),
      content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// False while the control shows nothing.
  var isShowingContent: Bool { !isHidden }

  /// Sets the measure of wrapping labels before the panel is measured.
  func prepareLayout(width: CGFloat) {}

  func hostedSize(width: CGFloat?) -> CGSize {
    guard isShowingContent else { return .zero }
    let offered = offeredWidth(width)
    if let offered { prepareLayout(width: offered) }
    let fitting = content.fittingSize
    return CGSize(width: offered ?? ceil(fitting.width), height: ceil(fitting.height))
  }

  override var intrinsicContentSize: NSSize {
    NSSize(
      width: NSView.noIntrinsicMetric,
      height: isShowingContent ? ceil(content.fittingSize.height) : 0)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isShowingContent else { return nil }
    let hit = super.hitTest(point)
    return hit === self || hit === content ? nil : hit
  }
}
