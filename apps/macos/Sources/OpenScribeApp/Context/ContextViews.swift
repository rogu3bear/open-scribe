import AppKit
import Combine
import SwiftUI

/// The live scope inspector: summary, retention truth, and ordinary buttons
/// for Pause, Resume, Mark Now, Narrow Scope, and Revoke. None of these
/// depend on the overlay (ADR 0011).
struct ContextInspector: View {
  @ObservedObject var model: ContextScopeModel
  @State private var showsPreflight = false

  var body: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.related) {
      Text("Screen context").scribeSectionHeading()
      if let scope = model.current, model.isLive {
        Text("\(ContextScopeSummary.modeName(scope.request.mode)): \(ContextScopeSummary.target(scope.request))")
          .fixedSize(horizontal: false, vertical: true)
        Text(ContextScopeSummary.condition(scope))
          .foregroundStyle(.primary)
          .fontWeight(scope.condition == .active ? nil : .semibold)
        Text("\(model.detail?.acceptedEvents ?? 0) context events · \(ContextScopeSummary.retention)")
          .font(.callout).foregroundStyle(.secondary)
        ContextActionMount(model: model)
          .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        Button("Narrow Scope…") { showsPreflight = true }
      } else {
        if let scope = model.current {
          Text(ContextScopeSummary.condition(scope)).foregroundStyle(.secondary)
        } else {
          Text("Context is off. Open Scribe is not reading the screen.").foregroundStyle(.secondary)
        }
        Button("Add Screen Context…") { showsPreflight = true }
          .disabled(!model.canAuthorize)
      }
      if let message = model.message {
        CaptureIssueLabel(message: message).font(.callout)
      }
    }
    .accessibilityElement(children: .contain)
    .sheet(isPresented: $showsPreflight) {
      ContextScopeSheet(model: model) { showsPreflight = false }
    }
  }
}

/// Pause, Mark Now, Resume, and Revoke. Created with the first layout so a
/// hosted click reaches the same model methods the buttons call.
private struct ContextActionMount: NSViewRepresentable {
  @ObservedObject var model: ContextScopeModel

  func makeNSView(context: Context) -> ContextActionControl {
    let view = ContextActionControl()
    view.bind(model)
    return view
  }

  func updateNSView(_ view: ContextActionControl, context: Context) {
    view.bind(model)
  }
}

private final class ContextActionControl: NSView {
  private let pauseButton = NSButton(title: "Pause Context", target: nil, action: nil)
  private let markButton = NSButton(title: "Mark Now", target: nil, action: nil)
  private let resumeButton = NSButton(title: "Resume Context", target: nil, action: nil)
  private let revokeButton = NSButton(title: "Revoke", target: nil, action: nil)
  private var model: ContextScopeModel?
  private var subscribed = false
  private var cancellables: Set<AnyCancellable> = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Screen context actions")
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    for button in [pauseButton, markButton, resumeButton, revokeButton] {
      button.bezelStyle = .rounded
      button.setAccessibilityLabel(button.title)
      button.target = self
      button.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(button)
    }
    pauseButton.action = #selector(pauseContext)
    markButton.action = #selector(markContext)
    resumeButton.action = #selector(resumeContext)
    revokeButton.action = #selector(revokeContext)
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 28)
  }

  func bind(_ model: ContextScopeModel) {
    self.model = model
    if !subscribed {
      subscribed = true
      model.objectWillChange.sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }.store(in: &cancellables)
    }
    apply()
  }

  private func apply() {
    guard let model, let scope = model.current, model.isLive else {
      pauseButton.isHidden = true
      markButton.isHidden = true
      resumeButton.isHidden = true
      revokeButton.isHidden = true
      return
    }
    let active = scope.condition == .active
    pauseButton.isHidden = !active
    markButton.isHidden = !active
    resumeButton.isHidden = active || scope.reason == "topology_changed"
    revokeButton.isHidden = false
  }

  @objc private func pauseContext() {
    let model = model
    MainActor.assumeIsolated { model?.pause() }
  }

  @objc private func markContext() {
    let model = model
    MainActor.assumeIsolated { model?.markNow() }
  }

  @objc private func resumeContext() {
    let model = model
    MainActor.assumeIsolated { model?.resume() }
  }

  @objc private func revokeContext() {
    let model = model
    MainActor.assumeIsolated { model?.revoke() }
  }
}

/// Participant/topic preflight and explicit scope authorization. It states
/// the exact scope, permission, exclusions, and retention before anything
/// is observed.
struct ContextScopeSheet: View {
  @ObservedObject var model: ContextScopeModel
  let dismiss: () -> Void
  @State private var participants = ""
  @State private var topic = ""
  @State private var hovered: String?

  var body: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.standard) {
      Text("Add Screen Context").scribeSectionHeading(.title2.weight(.semibold))
      Form {
        DisclosureGroup("Conversation details (optional)") {
          TextField("Participants, separated by commas", text: $participants)
          TextField("Topic", text: $topic)
          Text("These names help you review later. They grant no screen access.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("What to read") {
          Picker("Mode", selection: $model.selection.mode) {
            ForEach(
              [NativeContextMode.watchWindow, .addCurrentWindow, .watchDisplay, .watchRegion, .followPointer],
              id: \.self
            ) { mode in
              Text(ContextScopeSummary.modeName(mode)).tag(mode)
            }
          }
          .pickerStyle(.radioGroup)
          Text(ContextScopeSummary.modeExplanation(model.selection.mode))
            .font(.caption).foregroundStyle(.secondary)
          if model.selection.mode != .followPointer { choiceList }
          if model.selection.mode == .watchRegion { RegionEditor(model: model) }
        }
      }
      .formStyle(.grouped)
      // Always visible beside the action: what is read, what is excluded,
      // what is kept, and the permission posture.
      VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
        Text("Before you authorize").scribeSectionHeading()
        Text(scopeStatement)
        Text(ContextScopeSummary.exclusions(ContextScopeModel.exclusions(for: model.selection.mode)))
        Text(ContextScopeSummary.retention)
        Text(ContextScopeSummary.permission(model.permission))
      }
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .combine)
      if let message = model.message {
        CaptureIssueLabel(message: message)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(model.isLive ? "Replace Scope" : "Authorize") {
          if !participants.isEmpty || !topic.isEmpty {
            model.declare(participants: participants, topic: topic)
          }
          if model.authorize() { dismiss() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canAuthorize)
      }
    }
    .padding(ScribeSpacing.standard)
    .frame(width: 580, height: 720)
    .task { await model.refreshChoices() }
    .onChange(of: model.selection) { _ in model.previewOverlay(hovered: hovered) }
    .onChange(of: hovered) { _ in model.previewOverlay(hovered: hovered) }
    .onDisappear { model.endPreview() }
  }

  private var canAuthorize: Bool {
    model.canAuthorize && (model.selection.mode == .followPointer || model.selection.choiceId != nil)
  }

  private var scopeStatement: String {
    if model.selection.mode == .followPointer {
      return "Open Scribe will read windows you rest the pointer on, on every connected display."
    }
    guard let choice = model.choices.first(where: { $0.id == model.selection.choiceId }) else {
      return "Choose what Open Scribe may read."
    }
    let region = model.selection.region
    let area =
      model.selection.mode == .watchRegion
      ? String(
        format: " (the area at %.0f%%, %.0f%%, sized %.0f%% × %.0f%%)", region.minX * 100,
        region.minY * 100, region.width * 100, region.height * 100)
      : ""
    return "Open Scribe will read \(choice.description)\(area) and nothing else."
  }

  @ViewBuilder private var choiceList: some View {
    let wanted: ContextChoice.Kind = model.needsWindow ? .window : .display
    let items = model.choices.filter { $0.kind == wanted }
    if wanted == .window && model.windowsNeedPermission {
      Text("Windows appear here after you allow Screen Recording for Open Scribe.")
        .font(.caption).foregroundStyle(.secondary)
    }
    Picker(wanted == .window ? "Window" : "Display", selection: $model.selection.choiceId) {
      ForEach(items) { choice in
        Text(choice.description).tag(Optional(choice.id))
          .onHover { inside in hovered = inside ? choice.id : (hovered == choice.id ? nil : hovered) }
      }
    }
    .pickerStyle(.inline)
  }
}

/// Region bounds on a named display: drag the rectangle, use the arrow keys
/// to move it (Shift-arrow resizes), or edit the percentages directly.
struct RegionEditor: View {
  @ObservedObject var model: ContextScopeModel
  @FocusState private var focused: Bool
  @GestureState private var dragOrigin: CGPoint?

  var body: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.related) {
      GeometryReader { proxy in
        let size = proxy.size
        let region = model.selection.region
        ZStack(alignment: .topLeading) {
          Rectangle().stroke(Color.secondary)
          Rectangle()
            .stroke(Color.accentColor, lineWidth: focused ? 3 : 2)
            .frame(width: region.width * size.width, height: region.height * size.height)
            .offset(x: region.minX * size.width, y: region.minY * size.height)
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 1)
          .updating($dragOrigin) { _, origin, _ in
            if origin == nil { origin = model.selection.region.origin }
          }
          .onChanged { value in
            let origin = dragOrigin ?? model.selection.region.origin
            move(
              to: CGPoint(
                x: origin.x + value.translation.width / size.width,
                y: origin.y + value.translation.height / size.height))
          })
      }
      .aspectRatio(16 / 10, contentMode: .fit)
      .frame(maxHeight: 160)
      .frame(maxWidth: .infinity, alignment: .leading)
      .focusable()
      .focused($focused)
      .onMoveCommand { direction in nudge(direction) }
      .accessibilityElement()
      .accessibilityLabel("Region on \(displayName)")
      .accessibilityValue(ContextScopeSummary.target(boundsRequest))
      .help("Drag to move the region. Arrow keys move it; Shift-arrow keys resize it.")
      DisclosureGroup("Position and size") {
        HStack {
          percentField("X", \.origin.x)
          percentField("Y", \.origin.y)
          percentField("Width", \.size.width)
          percentField("Height", \.size.height)
        }
      }
    }
  }

  private var displayName: String {
    model.choices.first { $0.id == model.selection.choiceId }?.name ?? "the chosen display"
  }

  private var boundsRequest: NativeContextScopeRequest {
    let region = model.selection.region
    return NativeContextScopeRequest(
      mode: .watchRegion,
      targets: [NativeContextTarget(kind: .display, platformId: "", name: displayName, application: nil, description: displayName)],
      bounds: NativeContextBounds(displayId: "", x: region.minX, y: region.minY, width: region.width, height: region.height),
      topology: [], exclusions: [], permission: .granted, retention: .noPixels)
  }

  private func percentField(_ label: String, _ path: WritableKeyPath<CGRect, CGFloat>) -> some View {
    TextField(
      label,
      value: Binding(
        get: { Double(model.selection.region[keyPath: path] * 100).rounded() },
        set: { value in
          var region = model.selection.region
          region[keyPath: path] = CGFloat(value / 100)
          model.selection.region = Self.clamped(region)
        }),
      format: .number
    )
    .frame(width: 64)
    .accessibilityLabel("\(label) percent")
  }

  private func move(to origin: CGPoint) {
    var region = model.selection.region
    region.origin = origin
    model.selection.region = Self.clamped(region)
  }

  private func nudge(_ direction: MoveCommandDirection) {
    let step: CGFloat = 0.01
    var region = model.selection.region
    let resizing = NSEvent.modifierFlags.contains(.shift)
    switch (direction, resizing) {
    case (.left, false): region.origin.x -= step
    case (.right, false): region.origin.x += step
    case (.up, false): region.origin.y -= step
    case (.down, false): region.origin.y += step
    case (.left, true): region.size.width -= step
    case (.right, true): region.size.width += step
    case (.up, true): region.size.height -= step
    case (.down, true): region.size.height += step
    @unknown default: break
    }
    model.selection.region = Self.clamped(region)
  }

  /// Keeps the region inside its display with a minimum 5% size.
  static func clamped(_ region: CGRect) -> CGRect {
    let width = min(max(region.width, 0.05), 1)
    let height = min(max(region.height, 0.05), 1)
    return CGRect(
      x: min(max(region.minX, 0), 1 - width), y: min(max(region.minY, 0), 1 - height),
      width: width, height: height)
  }
}

/// Saved review of accepted context: what was read, when, and under which
/// scope. Only recognized text exists; no screen image was kept.
struct ContextEventsSection: View {
  let detail: NativeContextDetail?
  let events: [NativeContextEvent]
  var canSeek = false
  var onSeek: (NativeContextEvent) -> Void = { _ in }

  static func hasHistory(_ detail: NativeContextDetail?) -> Bool {
    guard let detail else { return false }
    return !detail.scopes.isEmpty || detail.acceptedEvents > 0
  }

  var body: some View {
    if let detail, Self.hasHistory(detail) {
      LazyVStack(alignment: .leading, spacing: 10) {
        Text("Screen context").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
        ForEach(Array(detail.scopes.enumerated()), id: \.offset) { _, scope in
          Text("\(ContextScopeSummary.modeName(scope.request.mode)) — \(ContextScopeSummary.target(scope.request)): \(ContextScopeSummary.condition(scope))")
            .font(.callout).foregroundStyle(.secondary)
        }
        Text(ContextScopeSummary.retention).font(.caption).foregroundStyle(.secondary)
        ForEach(events, id: \.eventId) { event in
          ContextEventRow(event: event, canSeek: canSeek, onSeek: onSeek)
        }
      }
    }
  }
}

/// The complete accepted text remains readable inside a lazy history list.
struct ContextEventRow: View {
  let event: NativeContextEvent
  let canSeek: Bool
  let onSeek: (NativeContextEvent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
      HStack(alignment: .firstTextBaseline) {
        Text(TranscriptSection.timestamp(event.startNs))
          .monospacedDigit().foregroundStyle(.secondary)
        Text(event.application.map { "\($0) — \(event.sourceName)" } ?? event.sourceName)
          .font(.headline)
        if event.reason == .userMarked { Text("Marked").font(.caption).foregroundStyle(.secondary) }
        if canSeek {
          Spacer()
          Button("Play from \(TranscriptSection.timestamp(event.startNs))") { onSeek(event) }
            .buttonStyle(.link)
        }
      }
      Text(event.text.isEmpty ? "No text was recognized." : event.text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Menu bar scope summary and controls; Revoke is always one click away.
struct ContextMenuSection: View {
  @ObservedObject var model: ContextScopeModel

  var body: some View {
    if let scope = model.current, model.isLive {
      Divider()
      Text(ContextScopeSummary.line(scope, events: model.detail?.acceptedEvents ?? 0))
      if scope.condition == .active {
        Button("Pause Context") { model.pause() }
        Button("Mark Now") { model.markNow() }
      } else if scope.reason != "topology_changed" {
        Button("Resume Context") { model.resume() }
      }
      Button("Revoke Context") { model.revoke() }
    }
  }
}
