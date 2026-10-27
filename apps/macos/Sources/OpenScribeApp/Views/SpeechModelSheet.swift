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
    VStack(alignment: .leading, spacing: ScribeSpacing.standard) {
      Text("Speech Models")
        .font(.headline)
      Text(
        "Download a model, then install its file. Open Scribe verifies it before transcribing on this Mac."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if let model = speech.installedModel {
        Text("Transcription uses \(Self.title(model)).")
          .font(.callout)
      }
      ForEach(speech.models, id: \.modelId) { model in
        modelDetail(model)
      }
      if speech.isRefreshing { ProgressView("Verifying local model files…") }
      if let warning = speech.catalogWarning {
        Text(warning).foregroundStyle(.secondary)
        Button("Refresh") { speech.refresh() }
      }
      if let message = speech.message {
        if speech.messageIsFailure {
          CaptureIssueLabel(message: message, isFailure: true).font(.callout)
        } else {
          Label(message, systemImage: "checkmark.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      HStack {
        Spacer()
        Button("Done", action: onClose)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(ScribeSpacing.standard)
    .frame(width: 520)
  }

  private func modelDetail(_ model: NativeSpeechModel) -> some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.related) {
      HStack(alignment: .firstTextBaseline) {
        Text(Self.title(model))
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(Self.readinessText(model.readiness))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(
        ByteCountFormatter.string(
          fromByteCount: Int64(clamping: model.byteLength), countStyle: .file)
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      DisclosureGroup("Verification details") {
        VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
          Text(model.fileName)
          Text("SHA-256 \(model.sha256)")
            .font(.caption.monospaced())
          Text("Weights: \(model.license) license. Engine: \(model.engine), MIT license.")
        }
        .textSelection(.enabled)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack(spacing: ScribeSpacing.compact) {
        if let origin = URL(string: model.downloadOrigin) {
          Link("Download File", destination: origin)
            .help(model.downloadOrigin)
        }
        Spacer()
        if speech.isInstalling {
          ProgressView().controlSize(.small)
          Text("Checking…").font(.caption)
        } else if !model.installed {
          Button(model.readiness == .invalid ? "Repair from File…" : "Install from File…") {
            choose(model)
          }
        }
      }
    }
    .padding(.vertical, ScribeSpacing.related)
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
    model.languages == ["en"] ? "English" : "Multilingual"
  }
  static func readinessText(_ state: NativeModelReadiness) -> String {
    switch state {
    case .absent: "Not installed"
    case .presentUnverified: "Present, verification unavailable"
    case .verifying: "Verifying"
    case .ready: "Verified and ready"
    case .invalid: "Invalid — repair required"
    case .incompatible: "Incompatible with this engine"
    }
  }
}
