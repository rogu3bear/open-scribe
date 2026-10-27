import SwiftUI

struct TranscriptSpeakerPresentation: Identifiable {
  enum Subject {
    case passage(NativeTranscriptSegment)
    case person(NativeNamedTranscriptSpeaker)
  }
  let id = UUID()
  let sessionId: String
  let subject: Subject
}

/// An explicit human assertion about one passage or an already named
/// person. Declared participants are suggestions, never voice identities.
struct TranscriptSpeakerReview: View {
  let presentation: TranscriptSpeakerPresentation
  @ObservedObject var transcripts: TranscriptLibraryModel
  let onClose: () -> Void
  @State private var selected: String
  @State private var name: String
  @State private var isSaving = false

  init(
    presentation: TranscriptSpeakerPresentation, transcripts: TranscriptLibraryModel,
    onClose: @escaping () -> Void
  ) {
    self.presentation = presentation
    self.transcripts = transcripts
    self.onClose = onClose
    switch presentation.subject {
    case .passage(let segment):
      _selected = State(initialValue: segment.namedSpeakerId ?? "new")
      _name = State(initialValue: "")
    case .person(let speaker):
      _selected = State(initialValue: speaker.id)
      _name = State(initialValue: speaker.label)
    }
  }

  private var isPassage: Bool {
    if case .passage = presentation.subject { return true }
    return false
  }

  private var needsName: Bool { !isPassage || selected == "new" }
  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var validName: Bool {
    !trimmedName.isEmpty && trimmedName.utf8.count <= 128
      && !trimmedName.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.standard) {
      Text(isPassage ? "Who is speaking?" : "Rename Person")
        .scribeSectionHeading(.title2.weight(.semibold))
      if case .passage(let segment) = presentation.subject {
        Text(segment.effectiveText)
          .font(.callout)
          .lineLimit(4)
          .textSelection(.enabled)
        Text("Your choice applies to this passage. Other voices keep their own names.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Picker("Speaker", selection: $selected) {
          Text("Add a person…").tag("new")
          ForEach(transcripts.namedSpeakers, id: \.id) { person in
            Text(person.label).tag(person.id)
          }
          Text("Use audio source label").tag("source")
        }
        .pickerStyle(.menu)
      } else {
        Text("This updates the name on this person's assigned passages in this conversation.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if needsName {
        TextField("Name", text: $name)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Person's name")
          .onSubmit(save)
        let participants = transcripts.contextDetail?.declaration.participants ?? []
        if !participants.isEmpty {
          Menu("Use a participant name") {
            ForEach(Array(participants.enumerated()), id: \.offset) { _, participant in
              Button(participant) { name = participant }
            }
          }
          .menuStyle(.borderlessButton)
          .help("Choose a declared participant only after confirming this is their voice")
        }
        if !trimmedName.isEmpty, !validName {
          Text("Use a shorter name without control characters.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if transcripts.sessionId != presentation.sessionId {
        Text("The conversation changed. Close this sheet and reopen the passage.")
          .font(.callout)
      } else if let message = transcripts.editingFailureMessage {
        CaptureIssueLabel(message: message, isFailure: true).font(.callout)
      }
      HStack {
        Spacer()
        SheetActionButtons(
          confirmTitle: "Save",
          isConfirmationDisabled: isSaving || transcripts.isEditing
            || transcripts.sessionId != presentation.sessionId
            || (needsName && !validName),
          cancel: onClose, confirm: save)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private func save() {
    guard !isSaving, transcripts.sessionId == presentation.sessionId,
      !needsName || validName
    else { return }
    isSaving = true
    Task {
      let saved: Bool
      switch presentation.subject {
      case .person(let person):
        saved = await transcripts.renameNamedSpeaker(
          sessionId: presentation.sessionId, speakerId: person.id, label: trimmedName)
      case .passage(let segment):
        let assignment: NativeTranscriptSpeakerAssignment =
          selected == "new"
          ? .new(label: trimmedName)
          : selected == "source" ? .source : .existing(speakerId: selected)
        saved = await transcripts.assignSpeaker(
          sessionId: presentation.sessionId, segment: segment, assignment: assignment)
      }
      isSaving = false
      if saved { onClose() }
    }
  }
}
