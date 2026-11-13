import AppKit
import SwiftUI

/// The Interview Page design system: a conversation typeset like a published
/// interview. Apple's New York serif carries titles and speech; the system sans
/// carries controls and facts; one ink blue marks the primary action, the
/// playing passage, and links. Surfaces stay native; nothing here is a card.
enum Interview {
  // MARK: Color

  /// The reading surface.
  static let paper = Color(light: 0xFBFBF8, dark: 0x1C1C1B)
  /// Speech and titles.
  static let ink = Color(light: 0x141414, dark: 0xECECEA)
  /// Facts, timestamps, and Draft words. Contrast on paper is at least 4.5:1.
  static let quiet = Color(light: 0x6E6E73, dark: 0xA1A1A6)
  /// The primary action, the playing passage, and links.
  static let accent = Color(light: 0x1F3A93, dark: 0x8FA8F0)
  /// Hairline rules between regions.
  static let rule = Color(light: 0xE4E3DE, dark: 0x343432)
  /// The quiet fill behind the passage that is playing or found.
  static let wash = Color(light: 0xE9EDF8, dark: 0x262C3D)
  /// Recording state; always paired with the word "Recording".
  static let recording = Color(nsColor: .systemRed)

  // MARK: Type

  static func title(_ size: CGFloat = 30) -> Font {
    .system(size: size, weight: .semibold, design: .serif)
  }

  static func speech(_ scale: TranscriptTextScale = .standard) -> Font {
    .system(size: 17 * scale.multiplier, design: .serif)
  }

  /// Run-in speaker names: small caps, bold, slightly tracked.
  static let speaker = Font.system(size: 12, weight: .bold).smallCaps()
  static let meta = Font.system(size: 13)
  static let stamp = Font.system(size: 11).monospacedDigit()
  static let sectionLabel = Font.system(size: 11, weight: .semibold)

  // MARK: Measure

  /// About 68 characters of 17-point New York.
  static let measure: CGFloat = 640
  /// The left margin that holds timestamps beside the column.
  static let shoulder: CGFloat = 60
  /// The right margin that holds a passage's Name and Correct controls.
  static let gutter: CGFloat = 60
  /// The document's whole width: shoulder, measure, and gutter.
  static let documentWidth: CGFloat = shoulder + measure + gutter
  static let speechLineSpacing: CGFloat = 5
  static let turnSpacing: CGFloat = 18
}

extension TranscriptTextScale {
  /// The reader's size steps over the 17-point standard.
  var multiplier: CGFloat {
    switch self {
    case .standard: 1
    case .larger: 1.15
    case .largest: 1.32
    }
  }
}

extension Color {
  /// An appearance-adaptive color from two sRGB hex values.
  init(light: UInt32, dark: UInt32) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(hex: isDark ? dark : light)
      })
  }
}

extension NSColor {
  convenience init(hex: UInt32) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}

/// A full-width hairline.
struct InterviewRule: View {
  var body: some View {
    Rectangle()
      .fill(Interview.rule)
      .frame(height: 1)
      .accessibilityHidden(true)
  }
}

/// Centers document content at the interview width, leaving the shoulder on
/// the left for timestamps.
struct InterviewColumn<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    content
      .frame(maxWidth: Interview.documentWidth, alignment: .leading)
      .padding(.horizontal, 28)
      .frame(maxWidth: .infinity, alignment: .center)
  }
}

/// Facts set as one quiet line, separated by middle dots.
struct InterviewFacts: View {
  let items: [String]

  var body: some View {
    Text(items.filter { !$0.isEmpty }.joined(separator: "  ·  "))
      .font(Interview.meta)
      .foregroundStyle(Interview.quiet)
      .lineLimit(2)
      .textSelection(.enabled)
  }
}

/// A one-line notice in the document's own voice. Failures carry an icon and
/// the word "Problem" for VoiceOver; color is never the only signal.
struct InterviewNotice: View {
  let message: String
  var isProblem = false
  var actions: [(String, () -> Void)] = []

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: isProblem ? "exclamationmark.triangle.fill" : "info.circle")
        .foregroundStyle(isProblem ? Color(nsColor: .systemOrange) : Interview.quiet)
        .accessibilityHidden(true)
      Text(message)
        .font(Interview.meta)
        .foregroundStyle(isProblem ? Interview.ink : Interview.quiet)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
        Button(action.0, action: action.1)
          .buttonStyle(.link)
          .font(Interview.meta)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(isProblem ? "Problem" : "Note"): \(message)")
  }
}

enum InterviewTime {
  /// `m:ss` under an hour, `h:mm:ss` from an hour; the transcript's own format.
  static func stamp(_ nanoseconds: Int64) -> String {
    TranscriptSection.timestamp(nanoseconds)
  }

  /// "12 min", "1 hr 4 min", "40 sec".
  static func length(seconds: UInt64) -> String {
    ConversationClipboard.duration(nanoseconds: Int64(seconds) * 1_000_000_000)
  }
}
