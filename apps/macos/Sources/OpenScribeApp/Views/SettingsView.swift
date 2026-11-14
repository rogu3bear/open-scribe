import AppKit
import Combine
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  let status: AppStatus
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var library: RuntimeLibraryStore
  @ObservedObject var recovery: RecoveredSessionController
  @ObservedObject var scheduler: TranscriptionScheduler
  @ObservedObject var pressure: SystemPressureMonitor
  @ObservedObject var liveCaptions = LiveCaptionModel()
  var diagnosticsDestination: @MainActor () -> URL? = SettingsView.chooseDiagnosticsDestination
  @State private var showingPolicies = false
  /// The embedded Rust registry's release sentence and capability rows.
  private let release = nativeReleaseClaims()
  @StateObject private var authorization = ProviderAuthorizationModel()
  @ObservedObject private var diagnosticLog = DiagnosticLog.shared
  @State private var signature = "checking"

  var body: some View {
    Form {
      Section("Release") {
        Text(release.noPublicRelease)
          .font(.callout)
        ForEach(release.capabilities, id: \.id) { claim in
          LabeledContent(claim.terminology, value: claim.publicLabel)
        }
      }
      Section("Transcription") {
        Toggle("Transcribe new recordings automatically", isOn: $scheduler.isAutomatic)
        Toggle("Pause automatic transcription", isOn: $scheduler.isPaused)
          .disabled(!scheduler.isAutomatic)
        Button("Speech Models…") { speech.showModels(in: .settings) }
        LabeledContent("Queue", value: queueLabel)
        if let hold = scheduler.hold {
          Text(hold.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(
          "Runs on this Mac, one conversation at a time, after recording stops. Manual requests still work when automatic transcription is paused."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Section("While Recording") {
        Toggle("Show a live transcript", isOn: $liveCaptions.isEnabled)
        Text(
          "Apple's on-device speech recognizer writes a draft while people talk. It stays on this Mac and never delays the recording. The final transcript replaces the draft after you stop."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          "Conversation titles and name suggestions come from the transcript, using Apple Intelligence on this Mac when it is available. A title you type is never replaced."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Section("Advanced") {
        if let warning = recovery.transcriptMaintenanceWarning {
          CaptureIssueLabel(message: warning).font(.callout)
        }
        DiagnosticsExportMount(report: { currentReport() }, destination: diagnosticsDestination)
          .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        DisclosureGroup("System information") {
          LabeledContent("Library disk", value: pressure.reading.diskText)
          LabeledContent("Memory", value: pressure.reading.memoryText)
          LabeledContent("Thermal", value: pressure.reading.thermalText)
          if let processText = pressure.reading.processText {
            LabeledContent("This app", value: processText)
          }
          Text(
            "Measured by macOS: the space the library volume can still give this app, the kernel's memory-pressure level and free pages, the thermal state, and this process's own CPU time and resident memory. Transcription waits below \(SystemPressureReading.bytes(SystemPressureReading.minimumDiskBytesForTranscription)) of free disk, under critical memory pressure, or in a critical thermal state."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        DisclosureGroup("Diagnostics") {
          LabeledContent("Microphone", value: microphoneLabel)
          LabeledContent("Screen Recording", value: screenCaptureLabel)
          LabeledContent("Signature", value: signature)
          LabeledContent("Recovery", value: recoveryLabel)
          if !recovery.recoveryFindings.isEmpty {
            Text(
              "\(recovery.recoveryFindings.count) per-conversation recovery findings retained for inspection."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          LabeledContent("Library", value: libraryLabel)
          LabeledContent(
            "Models",
            value: "\(speech.models.filter(\.installed).count) installed of \(speech.models.count)")
          Text(
            "Recent notes stay on this Mac. They omit titles, transcript text, and file paths. The crash annotation in an export is content-free."
          )
            .font(.caption)
            .foregroundStyle(.secondary)
          if diagnosticLog.events.isEmpty {
            Text("No notes yet.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(diagnosticLog.events.suffix(12)) { event in
              Text(
                "\(event.recordedAt.formatted(.dateTime.hour().minute().second()))  \(event.category)  \(event.message)"
              )
              .font(.caption.monospaced())
              .textSelection(.enabled)
            }
          }
        }
      }
      Section("Remote review") {
        RemoteReviewMount(authorization: authorization)
          .frame(maxWidth: .infinity, minHeight: 500, alignment: .topLeading)
      }
      Section("Help and policies") {
        Link(
          "Review Guide (online)",
          destination: URL(
            string: "https://github.com/rogu3bear/open-scribe/blob/main/docs/REVIEW_GUIDE.md")!)
        Button("Read Policies and Licenses…") { showingPolicies = true }
        Text("Policies are available offline. Privacy and terms remain drafts.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 460, minHeight: 320)
    .speechModelSheet(speech, in: .settings)
    .sheet(isPresented: $showingPolicies) {
      PolicyDocumentsView()
    }
    .onAppear {
      AppTelemetry.sceneAppeared("settings", status: status)
      speech.refresh()
      diagnosticLog.replace(DiagnosticJournal.shared.recent())
      Task { @MainActor in
        let status = await Task.detached(priority: .utility) {
          DiagnosticsSignature.current()
        }.value
        signature = status
      }
    }
  }

  /// The user chooses where the local diagnostics file is written. Cancel
  /// returns nil and writes nothing.
  static func chooseDiagnosticsDestination() -> URL? {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.plainText]
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = "Open Scribe Diagnostics.txt"
    panel.prompt = "Export"
    panel.title = "Export Diagnostics"
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  private var queueLabel: String {
    var parts: [String] = []
    if let running = scheduler.runningSessionId {
      let title = library.library.titles[running] ?? "1 conversation"
      parts.append("Transcribing “\(title)”")
    }
    let waiting = scheduler.queue.count
    if waiting > 0 {
      parts.append(waiting == 1 ? "1 waiting" : "\(waiting) waiting")
    }
    return parts.isEmpty ? "Nothing waiting" : parts.joined(separator: ", ")
  }

  private var recoveryLabel: String {
    switch recovery.phase {
    case .scanning: "Scanning"
    case .none: "Nothing to recover"
    case .available: "\(recovery.sessions.count) playable"
    case .failed: "Needs attention"
    }
  }

  private var libraryLabel: String {
    let count = library.library.conversationCount
    return count == 1 ? "1 conversation" : "\(count) conversations"
  }

  private var sessionLines: [DiagnosticsReport.SessionLine] {
    let sessions = [library.currentSession].compactMap { $0 } + library.savedSessions
    return sessions.map {
      DiagnosticsReport.SessionLine(
        sessionId: $0.sessionId,
        lifecycle: $0.lifecycle.description,
        health: $0.health.description,
        recovered: $0.recovered,
        journalDurable: $0.journalDurable,
        mediaFilesOpen: $0.mediaFilesOpen
      )
    }
  }

  private var architecture: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unknown"
    #endif
  }

  private var microphoneLabel: String {
    AVFoundationMicrophonePermissionAuthority().currentState.rawValue
  }

  private var screenCaptureLabel: String {
    CGPreflightScreenCaptureAccess() ? "authorized" : "not_authorized"
  }

  private func currentReport() -> String {
    DiagnosticsReport.text(
      product: status.productName,
      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.0.0",
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: architecture,
      bundleIdentifier: AppTelemetry.bundleIdentifier,
      microphone: microphoneLabel,
      screenCapture: screenCaptureLabel,
      signature: signature,
      recoveryPhase: recovery.phase.diagnosticName,
      recoveredCount: recovery.sessions.count,
      sessions: sessionLines,
      models: speech.models.map {
        DiagnosticsReport.ModelLine(
          modelId: $0.modelId, fileName: $0.fileName, installed: $0.installed)
      },
      events: DiagnosticJournal.shared.recent()
    )
  }
}

/// Writes the same diagnostics report Settings shows. The button exists on the
/// first layout. The default destination is the save panel.
private struct DiagnosticsExportMount: NSViewRepresentable {
  let report: @MainActor () -> String
  let destination: @MainActor () -> URL?

  func makeNSView(context: Context) -> DiagnosticsExportControl {
    let view = DiagnosticsExportControl()
    view.bind(report: report, destination: destination)
    return view
  }

  func updateNSView(_ view: DiagnosticsExportControl, context: Context) {
    view.bind(report: report, destination: destination)
  }
}

private final class DiagnosticsExportControl: NSView {
  private let exportButton = NSButton(title: "Export Diagnostics…", target: nil, action: nil)
  private var report: (@MainActor () -> String)?
  private var destination: (@MainActor () -> URL?)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Export diagnostics")
    exportButton.bezelStyle = .rounded
    exportButton.setAccessibilityLabel("Export Diagnostics…")
    exportButton.target = self
    exportButton.action = #selector(exportDiagnostics)
    exportButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(exportButton)
    NSLayoutConstraint.activate([
      exportButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      exportButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      exportButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 28)
  }

  func bind(report: @escaping @MainActor () -> String, destination: @escaping @MainActor () -> URL?) {
    self.report = report
    self.destination = destination
  }

  @objc private func exportDiagnostics() {
    let report = report
    let destination = destination
    MainActor.assumeIsolated {
      guard let report, let destination, let url = destination() else { return }
      let text = report()
      do {
        try Data(text.utf8).write(to: url, options: .atomic)
        AppTelemetry.commandInvoked("export-diagnostics")
      } catch {
        AppTelemetry.commandInvoked("export-diagnostics-failed")
      }
    }
  }
}

/// Configuration names a provider. It does not grant a category, and a refused
/// fingerprint is cleared so the secret does not remain in the field.
private struct RemoteReviewMount: NSViewRepresentable {
  @ObservedObject var authorization: ProviderAuthorizationModel

  func makeNSView(context: Context) -> RemoteReviewControl {
    let view = RemoteReviewControl()
    view.bind(authorization)
    return view
  }

  func updateNSView(_ view: RemoteReviewControl, context: Context) {
    view.bind(authorization)
  }
}

private final class RemoteReviewControl: NSView, NSTextFieldDelegate {
  private let providerField = RemoteReviewControl.field("Provider")
  private let modelField = RemoteReviewControl.field("Model")
  private let originField = RemoteReviewControl.field("HTTPS origin")
  private let fingerprintField = RemoteReviewControl.field("Credential fingerprint")
  private let fingerprintRule = RemoteReviewControl.caption(
    "The fingerprint is a SHA-256 digest. The secret stays out of Open Scribe.",
    label: "Credential fingerprint rule")
  private let configureButton = NSButton(title: "Configure provider", target: nil, action: nil)
  private let limits = RemoteReviewControl.caption(
    ProviderAuthorizationModel.unavailableNotice, label: "Remote review limits")
  private let prepareButton = NSButton(title: "Prepare review", target: nil, action: nil)
  private let statusField = RemoteReviewControl.caption("", label: "Provider authorization")
  private let outcomeField = RemoteReviewControl.caption("", label: "Provider authorization outcome")
  private var categoryButtons: [(NativeContentCategory, NSButton)] = []
  private var subscriptions: [AnyCancellable] = []
  private var authorization: ProviderAuthorizationModel?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Remote review")
    configureButton.bezelStyle = .rounded
    configureButton.setAccessibilityLabel("Configure provider")
    configureButton.target = self
    configureButton.action = #selector(configureProvider)
    configureButton.isEnabled = false
    prepareButton.bezelStyle = .rounded
    prepareButton.setAccessibilityLabel("Prepare review")
    prepareButton.target = self
    prepareButton.action = #selector(prepareReview)
    prepareButton.isEnabled = false
    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 6
    column.translatesAutoresizingMaskIntoConstraints = false
    column.detachesHiddenViews = false
    addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.trailingAnchor.constraint(equalTo: trailingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    for field in [providerField, modelField, originField, fingerprintField] {
      field.delegate = self
      column.addArrangedSubview(field)
      field.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    column.addArrangedSubview(fingerprintRule)
    column.addArrangedSubview(configureButton)
    column.addArrangedSubview(limits)
    for choice in ProviderAuthorizationModel.choices {
      let button = NSButton(
        checkboxWithTitle: choice.title, target: self, action: #selector(toggleCategory(_:)))
      button.setAccessibilityLabel(choice.title)
      button.isEnabled = false
      categoryButtons.append((choice.category, button))
      column.addArrangedSubview(button)
    }
    column.addArrangedSubview(prepareButton)
    column.addArrangedSubview(statusField)
    column.addArrangedSubview(outcomeField)
    for caption in [fingerprintRule, limits, statusField, outcomeField] {
      caption.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 500)
  }

  func bind(_ authorization: ProviderAuthorizationModel) {
    let same = self.authorization === authorization
    self.authorization = authorization
    if !same {
      subscriptions.removeAll()
      authorization.objectWillChange.map { _ in () }.eraseToAnyPublisher().sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }.store(in: &subscriptions)
    }
    apply()
  }

  func controlTextDidChange(_ notification: Notification) {
    apply()
  }

  private static func field(_ label: String) -> NSTextField {
    let field = NSTextField(string: "")
    field.placeholderString = label
    field.setAccessibilityLabel(label)
    field.bezelStyle = .roundedBezel
    field.translatesAutoresizingMaskIntoConstraints = false
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    return field
  }

  private static func caption(_ text: String, label: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.setAccessibilityLabel(label)
    field.translatesAutoresizingMaskIntoConstraints = false
    field.preferredMaxLayoutWidth = 420
    field.maximumNumberOfLines = 3
    return field
  }

  private func trimmed(_ field: NSTextField) -> String {
    field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func apply() {
    let ready =
      !trimmed(providerField).isEmpty && !trimmed(modelField).isEmpty
      && !trimmed(originField).isEmpty
    configureButton.isEnabled = ready
    let configured = authorization?.configured == true
    for (category, button) in categoryButtons {
      button.isEnabled = configured
      let granted = authorization?.grants.contains(category) == true
      button.state = granted ? .on : .off
    }
    prepareButton.isEnabled = configured && authorization?.grants.isEmpty == false
    statusField.stringValue = authorization?.notice ?? ""
    outcomeField.stringValue = authorization?.failure ?? authorization?.prepareNotice ?? ""
    layoutSubtreeIfNeeded()
  }

  @objc private func configureProvider() {
    MainActor.assumeIsolated {
      let providerId = trimmed(providerField)
      let modelId = trimmed(modelField)
      let origin = trimmed(originField)
      guard !providerId.isEmpty, !modelId.isEmpty, !origin.isEmpty, let authorization else {
        return
      }
      let fingerprint = trimmed(fingerprintField)
      do {
        try authorization.configureRemote(
          providerId: providerId, modelId: modelId, origin: origin,
          credentialFingerprint: fingerprint.isEmpty ? nil : fingerprint)
      } catch let error as NativeProviderError where error == .FingerprintRefused {
        fingerprintField.stringValue = ""
        authorization.noteFailure()
      } catch {
        authorization.noteFailure()
      }
      apply()
    }
  }

  @objc private func toggleCategory(_ sender: NSButton) {
    MainActor.assumeIsolated {
      guard let authorization, authorization.configured,
        let category = categoryButtons.first(where: { $0.1 === sender })?.0
      else {
        sender.state = .off
        return
      }
      if sender.state == .on {
        authorization.grants.insert(category)
      } else {
        authorization.grants.remove(category)
      }
      apply()
    }
  }

  @objc private func prepareReview() {
    MainActor.assumeIsolated {
      guard let authorization, authorization.configured, !authorization.grants.isEmpty else {
        return
      }
      do {
        try authorization.prepare(sessionId: "settings-session", offered: [])
      } catch {
        authorization.noteFailure()
      }
      apply()
    }
  }
}
