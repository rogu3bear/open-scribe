import SwiftUI

struct PolicyDocumentsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selection: PolicyDocument = .privacy
  @State private var content: Content = .loading

  private enum Content {
    case loading
    case text(String)
    case unavailable
  }

  var body: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.standard) {
      HStack {
        Text("Policies and licenses").scribeSectionHeading(.title2.weight(.semibold))
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      Picker("Document", selection: $selection) {
        ForEach(PolicyDocument.allCases) { document in
          Text(document.title).tag(document)
        }
      }
      .pickerStyle(.menu)
      if let note = selection.qualificationNote {
        Text(note)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      switch content {
      case .loading:
        ProgressView("Loading document…").frame(maxWidth: .infinity, maxHeight: .infinity)
      case .text(let text):
        ScrollView {
          // Verbatim text keeps canonical wording and never fetches remote media.
          Text(verbatim: text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, ScribeSpacing.related)
        }
        .accessibilityLabel(selection.title)
      case .unavailable:
        Text(
          "This document could not be read from the app. Check the source build before relying on it."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .padding(ScribeSpacing.section)
    .frame(minWidth: 560, idealWidth: 660, minHeight: 420, idealHeight: 600)
    .task(id: selection) {
      content = .loading
      let document = selection
      let text = await Task.detached(priority: .utility) { try? document.load() }.value
      guard !Task.isCancelled, selection == document else { return }
      content = text.map(Content.text) ?? .unavailable
    }
  }
}
