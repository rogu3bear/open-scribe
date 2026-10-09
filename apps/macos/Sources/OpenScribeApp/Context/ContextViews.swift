import AppKit
import SwiftUI

/// The live scope inspector: summary, retention truth, and ordinary buttons
/// for Pause, Resume, Mark Now, Narrow Scope, and Revoke. None of these
/// depend on the overlay (ADR 0011).
struct ContextInspector: View {
  @ObservedObject var model: ContextScopeModel
  @State private var showsPreflight = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Screen context").font(.headline).accessibilityAddTraits(.isHeader)
      if let scope = model.current, model.isLive {
        Text("\(ContextScopeSummary.modeName(scope.request.mode)): \(ContextScopeSummary.target(scope.request))")
          .fixedSize(horizontal: false, vertical: true)
        Text(ContextScopeSummary.condition(scope))
          .foregroundStyle(.primary)
          .fontWeight(scope.condition == .active ? nil : .semibold)
        Text("\(model.detail?.acceptedEvents ?? 0) context events · \(ContextScopeSummary.retention)")
          .font(.callout).foregroundStyle(.secondary)
        HStack {
          if scope.condition == .active {
            Button("Pause Context") { model.pause() }
            Button("Mark Now") { model.markNow() }
          } else if scope.reason != "topology_changed" {
            Button("Resume Context") { model.resume() }
          }
          Button("Narrow Scope…") { showsPreflight = true }
          Button("Revoke", role: .destructive) { model.revoke() }
        }
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
    VStack(alignment: .leading, spacing: 16) {
      Text("Add Screen Context").font(.headline)
      Form {
        Section("Meeting (optional)") {
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
      VStack(alignment: .leading, spacing: 4) {
        Text("Before you authorize").font(.headline).accessibilityAddTraits(.isHeader)
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
    .padding(16)
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
  @State private var dragOrigin: CGPoint?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
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
          DragGesture(minimumDistance: 1).onChanged { value in
            let origin = dragOrigin ?? model.selection.region.origin
            dragOrigin = origin
            move(
              to: CGPoint(
                x: origin.x + value.translation.width / size.width,
                y: origin.y + value.translation.height / size.height))
          }.onEnded { _ in dragOrigin = nil })
      }
      .aspectRatio(16 / 10, contentMode: .fit)
      .focusable()
      .focused($focused)
      .onMoveCommand { direction in nudge(direction) }
      .accessibilityElement()
      .accessibilityLabel("Region on \(displayName)")
      .accessibilityValue(ContextScopeSummary.target(boundsRequest))
      HStack {
        percentField("X", \.origin.x)
        percentField("Y", \.origin.y)
        percentField("Width", \.size.width)
        percentField("Height", \.size.height)
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

  var body: some View {
    if let detail, !detail.scopes.isEmpty || !detail.declaration.participants.isEmpty
      || detail.declaration.topic != nil
    {
      VStack(alignment: .leading, spacing: 10) {
        Text("Screen context").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
        if let topic = detail.declaration.topic { Text("Topic: \(topic)") }
        if !detail.declaration.participants.isEmpty {
          Text("Participants: \(ListFormatter.localizedString(byJoining: detail.declaration.participants))")
        }
        ForEach(Array(detail.scopes.enumerated()), id: \.offset) { _, scope in
          Text("\(ContextScopeSummary.modeName(scope.request.mode)) — \(ContextScopeSummary.target(scope.request)): \(ContextScopeSummary.condition(scope))")
            .font(.callout).foregroundStyle(.secondary)
        }
        Text(ContextScopeSummary.retention).font(.caption).foregroundStyle(.secondary)
        ForEach(events, id: \.eventId) { event in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
              Text(TranscriptSection.timestamp(event.startNs)).monospacedDigit().foregroundStyle(.secondary)
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
              .lineLimit(8)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
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
