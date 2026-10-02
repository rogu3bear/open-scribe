import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Installs a local speech model from a file the user downloaded. Open Scribe
/// makes no network request: the published file is checked against the
/// manifest's exact size and SHA-256, then test-run, before it is installed.
struct SpeechModelSheet: View {
  @ObservedObject var speech: SpeechTranscriptionModel
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Local Speech Model")
        .font(.headline)
      Text(
        "Transcription runs on this Mac with a model you download yourself. Open Scribe never downloads; the file you choose is checked against the size and SHA-256 below, then test-run, before it is used."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      ForEach(speech.models, id: \.modelId) { model in
        modelDetail(model)
      }
      if let message = speech.message {
        Label(
          message,
          systemImage: speech.messageIsFailure ? "exclamationmark.triangle" : "checkmark.circle"
        )
        .font(.callout)
        .foregroundStyle(speech.messageIsFailure ? Color.red : Color.secondary)
      }
      HStack {
        Spacer()
        Button("Done", action: onClose)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 520)
  }

  private func modelDetail(_ model: NativeSpeechModel) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(Self.title(model))
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(model.installed ? "Installed" : "Not installed")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Group {
        Text(
          "\(model.fileName), \(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.byteLength), countStyle: .file))"
        )
        Text("SHA-256 \(model.sha256)")
          .font(.caption.monospaced())
        Text("Weights: \(model.license) license. Engine: \(model.engine), MIT license.")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
      HStack(spacing: 12) {
        if let origin = URL(string: model.downloadOrigin) {
          Link("Get the File in Your Browser", destination: origin)
            .help(model.downloadOrigin)
        }
        Spacer()
        if speech.isInstalling {
          ProgressView().controlSize(.small)
          Text("Checking…").font(.caption)
        } else if !model.installed {
          Button("Install from File…") { choose(model) }
        }
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
  }

  private func choose(_ model: NativeSpeechModel) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose \(model.fileName)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await speech.install(model, from: url) }
  }

  static func title(_ model: NativeSpeechModel) -> String {
    model.languages == ["en"] ? "English (small, q5_1)" : "Multilingual (small, q5_1)"
  }
}
