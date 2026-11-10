import SwiftUI

/// The established spacing scale in docs/design/DESIGN.md, expressed in points.
/// Native control defaults and feature-specific geometry stay with their owners.
enum ScribeSpacing {
  static let tight: CGFloat = 4
  static let related: CGFloat = 8
  static let compact: CGFloat = 12
  static let standard: CGFloat = 16
  static let section: CGFloat = 24
}

struct ConversationShortcut {
  let key: KeyEquivalent
  let modifiers: EventModifiers
}

/// Worded labels and shortcuts the conversation controls speak. Views call these
/// so a test reads the same words the control uses.
enum ConversationControlLabels {
  static let record = "Record"
  static let stopAndSave = "Stop and Save"
  static let pause = "Pause"
  static let resume = "Resume"
  static let addMarker = "Add Marker"
  static let reviewPreservedAudio = "Review Preserved Audio"
  static let findInTranscript = "Find in this transcript"
  static let searchTranscripts = "Search transcripts"
  static let clearTranscriptSearch = "Clear transcript search"
  static let filterByPerson = "Filter transcript by person"
  static let exportTranscript = "Export Transcript…"
  static let draftState = "Draft"

  static let recordShortcut = ConversationShortcut(key: "r", modifiers: [.command, .shift])
  static let stopShortcut = ConversationShortcut(key: "s", modifiers: [.command, .shift])
  static let pauseShortcut = ConversationShortcut(key: "p", modifiers: [.command, .shift])
  static let markerShortcut = ConversationShortcut(key: "m", modifiers: [.command, .shift])
  static let findShortcut = ConversationShortcut(key: "f", modifiers: [.command])

  static func playConversationAudio(_ action: PlaybackControlAction) -> String {
    "\(action.title) conversation audio"
  }

  static func recoveredSegment(
    _ action: PlaybackControlAction, name: String, segment: String
  ) -> String {
    "\(action.title) \(name), segment \(segment)"
  }

  static func seekAccessibility(stamp: String, canSeek: Bool) -> String {
    canSeek ? "Play from \(stamp)" : stamp
  }

  static func correctAccessibility(stamp: String) -> String {
    "Correct the text at \(stamp)"
  }

  static func nameSpeakerAccessibility(stamp: String, label: String) -> String {
    "Name the speaker at \(stamp): \(label)"
  }

  /// Names provisional, final, and corrected text in words. A corrected final
  /// says Corrected; an uncorrected final says Final; a draft says Draft.
  static func passageAccessibility(
    speaker: String, text: String, finality: String, corrected: Bool, isPlaying: Bool,
    isCited: Bool
  ) -> String {
    let provisional = finality == "draft"
    let final = finality == "final" && !corrected
    return "\(speaker). \(text)"
      + (provisional ? " Draft." : "")
      + (final ? " Final." : "")
      + (isPlaying ? " Playing." : "")
      + (isCited ? " Cited evidence." : "")
      + (corrected ? " Corrected." : "")
  }
}

extension Text {
  /// A native heading with the VoiceOver heading trait. Sections default to
  /// headline; primary dialog headings can use a larger semantic text style.
  func scribeSectionHeading(_ style: Font = .headline) -> some View {
    font(style)
      .accessibilityAddTraits(.isHeader)
  }
}

/// The owning sheet supplies layout, draft validation, and save/dismiss actions.
/// This pair preserves native Cancel/Return behavior without owning edit state.
struct SheetActionButtons: View {
  let confirmTitle: LocalizedStringKey
  var isConfirmationDisabled = false
  let cancel: () -> Void
  let confirm: () -> Void

  var body: some View {
    Button("Cancel", role: .cancel, action: cancel)
      .keyboardShortcut(.cancelAction)
    Button(confirmTitle, action: confirm)
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(isConfirmationDisabled)
  }
}

/// Status color stays on the glyph; body text uses the native readable foreground.
struct CaptureIssueLabel: View {
  let message: String
  var isFailure = false

  var body: some View {
    Label {
      Text(message)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: isFailure ? "exclamationmark.circle" : "exclamationmark.triangle")
        .foregroundStyle(isFailure ? Color.red : Color.orange)
    }
    .accessibilityElement(children: .combine)
  }
}
