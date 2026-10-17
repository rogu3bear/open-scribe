import SwiftUI

/// Each explicit opening owns one sheet, including another opening for the
/// same conversation while a prior durable save is still completing.
struct ConversationMetadataPresentation: Identifiable {
  let id = UUID()
  let session: RuntimeSessionPresentation

  func close(_ active: inout ConversationMetadataPresentation?) {
    guard active?.id == id else { return }
    active = nil
  }
}

/// Renames a saved or interrupted conversation. The stored title is what
/// exports, packages, and search show; the session identity never changes.
struct ConversationRenameSheet: View {
  let session: RuntimeSessionPresentation
  @ObservedObject var store: RuntimeLibraryStore
  let onClose: () -> Void

  @State private var draftTitle: String
  @State private var isSaving = false
  @FocusState private var titleFocused: Bool

  init(
    session: RuntimeSessionPresentation, store: RuntimeLibraryStore, onClose: @escaping () -> Void
  ) {
    self.session = session
    self.store = store
    self.onClose = onClose
    _draftTitle = State(initialValue: ConversationIdentityPresentation.title(session.title))
  }

  private var trimmedTitle: String {
    draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename Conversation")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text(
        "The new name is used in the library, exports, and portable packages. The recording and its transcript are unchanged."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      TextField("Title", text: $draftTitle)
        .textFieldStyle(.roundedBorder)
        .focused($titleFocused)
        .onSubmit(save)
        .accessibilityLabel("Conversation title")
      if store.editMessageIsFailure, let message = store.editMessage {
        CaptureIssueLabel(message: message, isFailure: true).font(.callout)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onClose)
          .keyboardShortcut(.cancelAction)
        Button("Rename", action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedTitle.isEmpty || isSaving)
      }
    }
    .padding(16)
    .frame(width: 420)
    .onAppear {
      store.dismissEditMessage()
      titleFocused = true
    }
  }

  private func save() {
    guard !trimmedTitle.isEmpty, !isSaving else { return }
    isSaving = true
    Task {
      let renamed = await store.rename(sessionId: session.sessionId, title: trimmedTitle)
      isSaving = false
      if renamed != nil { onClose() }
    }
  }
}

/// Records who took part and what the conversation was about. Declaring
/// names grants no screen access and never identifies voices.
struct ConversationDetailsSheet: View {
  let session: RuntimeSessionPresentation
  let declaration: NativeSessionDeclaration?
  @ObservedObject var store: RuntimeLibraryStore
  let onSaved: () -> Void
  let onClose: () -> Void

  @State private var participants: String
  @State private var topic: String
  @State private var isSaving = false

  init(
    session: RuntimeSessionPresentation, declaration: NativeSessionDeclaration?,
    store: RuntimeLibraryStore, onSaved: @escaping () -> Void, onClose: @escaping () -> Void
  ) {
    self.session = session
    self.declaration = declaration
    self.store = store
    self.onSaved = onSaved
    self.onClose = onClose
    _participants = State(initialValue: declaration?.participants.joined(separator: ", ") ?? "")
    _topic = State(initialValue: declaration?.topic ?? "")
  }

  static func names(from text: String) -> [String] {
    text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Conversation Details")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text(
        "Participants and the topic are saved with the conversation's record. They do not identify individual voices in the transcript."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      TextField("Participants, separated by commas", text: $participants)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Participants")
      TextField("Topic", text: $topic)
        .textFieldStyle(.roundedBorder)
        .onSubmit(save)
        .accessibilityLabel("Topic")
      if store.editMessageIsFailure, let message = store.editMessage {
        CaptureIssueLabel(message: message, isFailure: true).font(.callout)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onClose)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving)
      }
    }
    .padding(16)
    .frame(width: 460)
    .onAppear { store.dismissEditMessage() }
  }

  private func save() {
    guard !isSaving else { return }
    isSaving = true
    let names = Self.names(from: participants)
    let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
    Task {
      let saved = await store.declare(
        sessionId: session.sessionId, participants: names,
        topic: trimmedTopic.isEmpty ? nil : trimmedTopic)
      isSaving = false
      if saved {
        onSaved()
        onClose()
      }
    }
  }
}
