import Foundation

/// Swift consumer of Rust's local speech-model and transcription authority.
/// Rust verifies, installs, reverifies, and runs the model and commits every
/// transcript; this model routes intent, polls coarse progress, and renders
/// the outcome. Open Scribe itself never downloads a model.
@MainActor
final class SpeechTranscriptionModel: ObservableObject {
  @Published private(set) var models: [NativeSpeechModel] = []
  @Published private(set) var isInstalling = false
  @Published private(set) var transcribingSessionId: String?
  @Published private(set) var progress: NativeTranscriptionProgress?
  @Published private(set) var message: String?
  @Published private(set) var messageIsFailure = false

  private let speech: NativeSpeechModels?
  private var loggedCatalogSummary = ""
  /// Leases a compressed import's verified bytes for companion decoding.
  private let preparation: NativeRecordingPreparation?
  private var job: NativeTranscriptionJob?

  init(speech: NativeSpeechModels?, preparation: NativeRecordingPreparation? = nil) {
    self.speech = speech
    self.preparation = preparation
    refresh()
  }

  convenience init(managedRoot: URL?) {
    self.init(
      speech: try? managedRoot.map { try NativeSpeechModels.open(managedRoot: $0.path) },
      preparation: try? managedRoot.map { try NativeRecordingPreparation.open(managedRoot: $0.path) }
    )
  }

  #if DEBUG
    /// Fixed values for rendered inspection: no library and no effects.
    convenience init(
      preview models: [NativeSpeechModel], transcribing sessionId: String? = nil,
      progress: NativeTranscriptionProgress? = nil
    ) {
      self.init(speech: nil)
      self.models = models
      self.transcribingSessionId = sessionId
      self.progress = progress
    }
  #endif

  var installedModel: NativeSpeechModel? { models.first(where: \.installed) }

  func refresh() {
    guard let speech else {
      models = []
      return
    }
    // The catalog is part of the model's observable state, so callers can
    // read it when this returns. The Rust read itself stays off the main
    // thread; only the finished list is published here.
    let loaded = DispatchQueue.global(qos: .utility).sync {
      speech.models()
    }
    models = loaded
    let summary = "count=\(loaded.count) installed=\(loaded.filter(\.installed).count)"
    guard summary != loggedCatalogSummary else { return }
    loggedCatalogSummary = summary
    AppTelemetry.libraryNote(stage: "speech-catalog", detail: summary)
  }

  /// Copies, verifies, self-tests, and installs the chosen file off the main
  /// actor. The chosen file is not changed; a rejected file installs nothing.
  @discardableResult
  func install(_ model: NativeSpeechModel, from url: URL) async -> Bool {
    guard let speech, !isInstalling else { return false }
    isInstalling = true
    report(nil)
    defer {
      isInstalling = false
      refresh()
    }
    let modelId = model.modelId
    let modelToken = DiagnosticPrivacy.token(modelId)
    let path = url.path
    do {
      try await Task.detached(priority: .utility) {
        try speech.installFromFile(modelId: modelId, sourcePath: path)
      }.value
      report("\(model.fileName) verified and installed.")
      AppTelemetry.libraryNote(
        stage: "speech-install", detail: "model=\(modelToken) result=installed")
      return true
    } catch {
      report(Self.describe(error), failure: true)
      AppTelemetry.libraryNote(
        stage: "speech-install",
        detail: "model=\(modelToken) result=rejected code=\(Self.speechCode(error))"
      )
      return false
    }
  }

  /// Transcribes every recorded track below capture priority. Returns whether
  /// Rust committed a transcript; failure or cancellation leaves audio as-is.
  @discardableResult
  func transcribe(sessionId: String) async -> Bool {
    guard let speech, let model = installedModel, transcribingSessionId == nil else { return false }
    let job = NativeTranscriptionJob()
    self.job = job
    transcribingSessionId = sessionId
    progress = job.progress()
    report(nil)
    defer {
      self.job = nil
      transcribingSessionId = nil
      progress = nil
    }
    let modelId = model.modelId
    let sessionToken = DiagnosticPrivacy.token(sessionId)
    let modelToken = DiagnosticPrivacy.token(modelId)
    AppTelemetry.libraryNote(
      stage: "transcription", detail: "started session=\(sessionToken) model=\(modelToken)")
    let preparation = preparation
    let work = Task.detached(priority: .utility) {
      try Self.run(
        speech: speech, preparation: preparation, modelId: modelId, sessionId: sessionId,
        job: job)
    }
    // Progress is polled from Rust's job, never pushed per chunk.
    let poll = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        self?.progress = job.progress()
      }
    }
    defer { poll.cancel() }
    do {
      let summary = try await work.value
      let tracks = summary.tracks == 1 ? "1 track" : "\(summary.tracks) tracks"
      let segments = summary.segments == 1 ? "1 segment" : "\(summary.segments) segments"
      report("Transcribed \(tracks) on this Mac: \(segments).")
      AppTelemetry.libraryNote(
        stage: "transcription",
        detail: "committed session=\(sessionToken) tracks=\(summary.tracks) segments=\(summary.segments)"
      )
      return true
    } catch {
      report(Self.describe(error), failure: true)
      let code = error is CancellationError ? "cancelled" : Self.speechCode(error)
      AppTelemetry.libraryNote(
        stage: "transcription", detail: "failed session=\(sessionToken) code=\(code)")
      return false
    }
  }

  func cancel() {
    job?.cancel()
  }

  /// A compressed import is first decoded, from its leased bytes, into a
  /// temporary PCM companion that Rust validates and reads; it is removed after.
  nonisolated private static func run(
    speech: NativeSpeechModels, preparation: NativeRecordingPreparation?, modelId: String,
    sessionId: String, job: NativeTranscriptionJob
  ) throws -> NativeTranscriptionSummary {
    guard try speech.needsDecodedCompanion(sessionId: sessionId) else {
      return try speech.transcribeSession(
        modelId: modelId, sessionId: sessionId, decodedCompanionPath: nil, job: job)
    }
    guard let preparation else { throw NativeSpeechError.StorageFailure }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-companion-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let companion = directory.appendingPathComponent("decoded.caf")
    do {
      try TranscriptionCompanionDecoder.decode(
        lease: try preparation.leaseImportedPlayback(sessionId: sessionId), to: companion,
        isCancelled: { job.isCancelled() })
    } catch is CancellationError {
      throw NativeSpeechError.Cancelled
    }
    return try speech.transcribeSession(
      modelId: modelId, sessionId: sessionId, decodedCompanionPath: companion.path, job: job)
  }

  func dismissMessage() {
    report(nil)
  }

  /// Completed fraction of all tracks' verified audio.
  var progressFraction: Double? {
    guard let progress, progress.trackCount > 0, progress.requiredNanoseconds > 0 else {
      return nil
    }
    let track = Double(progress.completedNanoseconds) / Double(progress.requiredNanoseconds)
    return (Double(progress.trackIndex) + min(1, track)) / Double(progress.trackCount)
  }

  var progressText: String {
    guard let progress, progress.trackCount > 0 else { return "Preparing transcription…" }
    let track = "track \(progress.trackIndex + 1) of \(progress.trackCount)"
    switch progress.stage {
    case .waiting, .decoding: return "Reading audio, \(track)…"
    case .transcribing: return "Transcribing \(track)…"
    case .reconciling: return "Assembling \(track)…"
    }
  }

  private func report(_ text: String?, failure: Bool = false) {
    message = text
    messageIsFailure = text != nil && failure
  }

  nonisolated private static func speechCode(_ error: Error) -> String {
    let described = String(describing: error)
    let leaf = described.split(separator: ".").last.map(String.init) ?? "unavailable"
    let name = leaf.split(separator: "(").first.map(String.init) ?? "unavailable"
    return DiagnosticPrivacy.token(name)
  }

  nonisolated static func describe(_ error: Error) -> String {
    switch error as? NativeSpeechError {
    case .ModelNotInstalled:
      return "No verified speech model is installed."
    case .ModelRejected(let reason):
      return "The model file was not installed: \(rejection(reason))."
    case .NoTranscribableAudio:
      return "This conversation has no recorded audio to transcribe."
    case .DecodedAudioRejected:
      return "The imported audio could not be decoded consistently, so nothing was transcribed."
    case .Cancelled:
      return "Transcription was cancelled. The recorded audio is unchanged."
    case .TranscriptionFailed:
      return "Transcription stopped before it finished. The recorded audio is unchanged."
    case .StorageFailure, .none:
      return "Open Scribe could not reach the conversation library."
    }
  }

  nonisolated static func rejection(_ reason: String) -> String {
    switch reason {
    case "truncated": "it is shorter than the published file"
    case "oversized": "it is longer than the published file"
    case "digest_mismatch": "its SHA-256 does not match the published file"
    case "not_ggml", "wrong_model": "it is not the listed model"
    case "incompatible_engine", "engine_version": "it does not match this build's speech engine"
    case "model_rejected", "self_test_failed": "the speech engine could not run it"
    default: "it could not be read and checked"
    }
  }
}
