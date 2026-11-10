import AppKit
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
  static let audioFiles = "Audio Files…"
  static let portablePackage = "Portable Package…"
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

  /// A saved marker keeps its own words. The stamp is the session time, and
  /// the label distinguishes it from a transcript passage at the same minute.
  static func markerAccessibility(stamp: String, label: String, canSeek: Bool) -> String {
    let name = label.isEmpty ? "Marker" : "Marker, \(label)"
    let seek = canSeek ? "Play from \(stamp)" : stamp
    return "\(seek), \(name)"
  }

  /// A marker on the live surface names the stored session time. It does not
  /// offer playback while capture still has the file open.
  static func liveMarkerAccessibility(stamp: String, label: String) -> String {
    let name = label.isEmpty ? "Marker" : "Marker, \(label)"
    return "\(name) at \(stamp)"
  }

  static func correctAccessibility(stamp: String) -> String {
    "Correct the text at \(stamp)"
  }

  static func nameSpeakerAccessibility(stamp: String, label: String) -> String {
    "Name the speaker at \(stamp): \(label)"
  }

  /// Names provisional, final, and corrected text in words. A corrected final
  /// says Corrected; an uncorrected final says Final; a draft says Draft.
  /// Search matches are named too, so the hit is not carried by color alone.
  static func passageAccessibility(
    speaker: String, text: String, finality: String, corrected: Bool, isPlaying: Bool,
    isCited: Bool, matches: [String] = []
  ) -> String {
    let provisional = finality == "draft"
    let final = finality == "final" && !corrected
    return "\(speaker). \(text)"
      + (provisional ? " Draft." : "")
      + (final ? " Final." : "")
      + (isPlaying ? " Playing." : "")
      + (isCited ? " Cited evidence." : "")
      + (corrected ? " Corrected." : "")
      + (matches.isEmpty ? "" : " Matches \(matches.joined(separator: ", ")).")
  }
}

/// Transcript text size. The reader stores `rawValue` under `storageKey` in the
/// scene's app storage. Standard, Larger, and Largest use semantic text styles,
/// so the system text size and this control both apply. The spoken value is the
/// non-color signal.
enum TranscriptTextScale: String, CaseIterable, Identifiable, Sendable {
  case standard
  case larger
  case largest

  static let storageKey = "transcriptTextScale"
  static let controlLabel = "Transcript text size"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: "Standard"
    case .larger: "Larger"
    case .largest: "Largest"
    }
  }

  var spokenValue: String {
    switch self {
    case .standard: "Standard text"
    case .larger: "Larger text"
    case .largest: "Largest text"
    }
  }

  /// AppKit style measured for the SwiftUI font this step applies.
  /// Standard is body, Larger is title2, and Largest is title.
  var textStyle: NSFont.TextStyle {
    switch self {
    case .standard: .body
    case .larger: .title2
    case .largest: .title1
    }
  }

  var passageFont: Font {
    switch self {
    case .standard: .body
    case .larger: .title2
    case .largest: .title
    }
  }

  var emphasisFont: Font {
    switch self {
    case .standard: .body.weight(.semibold)
    case .larger: .title2.weight(.semibold)
    case .largest: .title.weight(.semibold)
    }
  }

  var pointSize: CGFloat {
    NSFont.preferredFont(forTextStyle: textStyle).pointSize
  }

  static func resolve(_ stored: String?) -> TranscriptTextScale {
    guard let stored, let scale = TranscriptTextScale(rawValue: stored) else { return .standard }
    return scale
  }
}

/// The passage text and spoken label the reader shows for one segment.
struct TranscriptPassagePresentation {
  let text: AttributedString
  let spoken: String

  static func make(
    speaker: String, text: String, finality: String, corrected: Bool, isPlaying: Bool,
    isCited: Bool, query: String, scale: TranscriptTextScale
  ) -> TranscriptPassagePresentation {
    let matches = TranscriptSearch.ranges(in: text, query: query).map { String(text[$0]) }
    var attributed = AttributedString(text)
    for match in TranscriptSearch.ranges(in: text, query: query) {
      guard let range = Range(match, in: attributed) else { continue }
      attributed[range].backgroundColor = Color.yellow.opacity(0.25)
      attributed[range].font = scale.emphasisFont
      attributed[range].underlineStyle = .single
    }
    return TranscriptPassagePresentation(
      text: attributed,
      spoken: ConversationControlLabels.passageAccessibility(
        speaker: speaker, text: text, finality: finality, corrected: corrected,
        isPlaying: isPlaying, isCited: isCited, matches: matches))
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
