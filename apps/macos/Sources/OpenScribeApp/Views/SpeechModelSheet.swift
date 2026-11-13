import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The windows that present the speech-model sheet.
enum SpeechModelSheetHost: Equatable, Sendable {
  case conversation
  case settings
}

extension View {
  /// Presents the speech-model sheet while `speech` has it open in `host`.
  func speechModelSheet(_ speech: SpeechTranscriptionModel, in host: SpeechModelSheetHost)
    -> some View
  {
    sheet(
      isPresented: Binding(
        get: { speech.modelSheet == host },
        set: { if !$0, speech.modelSheet == host { speech.closeModels() } })
    ) {
      SpeechModelSheet(speech: speech) { speech.closeModels() }
    }
  }
}

/// Installs a local speech model. Download fetches the published catalog file
/// into managed staging. Install from File uses a file the user already has.
/// Either way the file is checked against the manifest, then test-run, before
/// it is installed. Recording does not download a model.
struct SpeechModelSheet: View {
  @ObservedObject var speech: SpeechTranscriptionModel
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.standard) {
      Text("Speech Models")
        .scribeSectionHeading(.title2.weight(.semibold))
      Text(
        "Download the published file, or choose one you already have. Open Scribe checks its size, SHA-256, and a short engine test before transcribing on this Mac. Recording does not use the network. These models are still pending release review."
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
      if speech.isRefreshing { ProgressView("Checking the model files…") }
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
          .font(.headline)
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
      DisclosureGroup("File details") {
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
          Link("Open Download Page", destination: origin)
            .help(model.downloadOrigin)
            .accessibilityLabel("Open the download page for \(Self.title(model))")
        }
        Spacer()
        if speech.isInstalling || speech.isRemoving || speech.isDownloading {
          ProgressView().controlSize(.small)
          Text(
            speech.isRemoving ? "Removing…" : speech.isDownloading ? "Downloading…" : "Checking…"
          ).font(.caption)
        } else if !model.installed {
          Button("Download") { Task { await speech.download(model) } }
            .accessibilityLabel("Download \(Self.title(model)) speech model")
          Button(model.readiness == .invalid ? "Repair from File…" : "Install from File…") {
            choose(model)
          }
          .buttonStyle(.borderedProminent)
          .accessibilityLabel(
            "\(model.readiness == .invalid ? "Repair" : "Install") \(Self.title(model)) speech model from file"
          )
        }
        if model.readiness != .absent && !speech.isInstalling && !speech.isRemoving
          && !speech.isDownloading
        {
          Button("Remove", role: .destructive) {
            Task { await speech.remove(model) }
          }
          .accessibilityLabel("Remove \(Self.title(model)) speech model")
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
    case .presentUnverified: "Installed, not checked yet"
    case .verifying: "Checking…"
    case .ready: "Ready"
    case .invalid: "Damaged — choose a replacement"
    case .incompatible: "Incompatible with this engine"
    }
  }
}
