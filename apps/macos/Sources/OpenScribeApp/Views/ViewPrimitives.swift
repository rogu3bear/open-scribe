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

extension Text {
  /// A section label with the existing native type and VoiceOver heading trait.
  /// Apply only to section headings, not titles or ordinary emphasized text.
  func scribeSectionHeading() -> some View {
    font(.headline)
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
