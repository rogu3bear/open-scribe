import Foundation

/// Swift consumer of Rust's local speech-model and transcription authority.
/// Rust verifies, installs, reverifies, and runs the model and commits every
/// transcript; this model routes intent, polls coarse progress, and renders
/// the outcome. An explicit Download fetches one catalog file into the
/// managed partial. Recording does not download a model.
@MainActor
final class SpeechTranscriptionModel: ObservableObject {
  @Published private(set) var models: [NativeSpeechModel] = []
  @Published private(set) var isInstalling = false
  @Published private(set) var isRemoving = false
  @Published private(set) var isDownloading = false
  @Published private(set) var isRefreshing = false
  @Published private(set) var catalogWarning: String?
  @Published private(set) var transcribingSessionId: String?
  @Published private(set) var progress: NativeTranscriptionProgress?
  @Published private(set) var message: String?
  @Published private(set) var messageIsFailure = false

  private let speech: NativeSpeechModels?
  private var loggedCatalogSummary = ""
  /// Leases a compressed import's verified bytes for companion decoding.
  private let preparation: NativeRecordingPreparation?
  private var job: NativeTranscriptionJob?
  private var refreshGeneration: UInt64 = 0
  private var refreshTask: Task<Void, Never>?

  init(speech: NativeSpeechModels?, preparation: NativeRecordingPreparation? = nil) {
    self.speech = speech
    self.preparation = preparation
    refresh()
  }

  convenience init(managedRoot: URL?) {
    self.init(
      speech: try? managedRoot.map { try NativeSpeechModels.open(managedRoot: $0.path) },
      preparation: try? managedRoot.map {
        try NativeRecordingPreparation.open(managedRoot: $0.path)
      }
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
      self.catalogWarning = nil
      self.transcribingSessionId = sessionId
      self.progress = progress
    }
  #endif

  var installedModel: NativeSpeechModel? { models.first(where: \.installed) }
  var readiness: NativeModelReadiness {
    if isRefreshing { return .verifying }
    return installedModel?.readiness ?? models.first(where: { $0.readiness != .absent })?.readiness
      ?? .absent
  }

  func refresh() {
    refreshGeneration &+= 1
    let generation = refreshGeneration
    refreshTask?.cancel()
    guard let speech else {
      models = []
      catalogWarning = "The local speech catalog is unavailable."
      isRefreshing = false
      return
    }
    isRefreshing = true
    refreshTask = Task {
      do {
        let loaded = try await StructuredNativeIO.read { speech.models() }
        guard generation == refreshGeneration else { return }
        models = loaded
        catalogWarning = nil
        isRefreshing = false
        let summary = "count=\(loaded.count) ready=\(loaded.filter(\.installed).count)"
        if summary != loggedCatalogSummary {
          loggedCatalogSummary = summary
          AppTelemetry.libraryNote(stage: "speech-catalog", detail: summary)
        }
      } catch {
        guard generation == refreshGeneration else { return }
        isRefreshing = false
        catalogWarning = "Speech model discovery could not finish. Refresh to try again."
      }
    }
  }

  /// Join the latest catalog publication, including a refresh that supersedes
  /// this one while native verification is in progress. Waiting yields the actor.
  func refreshAndWait() async {
    refresh()
    while isRefreshing, let current = refreshTask {
      await current.value
    }
  }

  /// Fetches the catalog origin into the managed partial, then runs the same
  /// verification and self-test as a chosen file. `protocolClasses` is how a
  /// test answers that exact URL. The production call leaves it empty.
  /// A rejected partial stays uninstalled.
  @discardableResult
  func download(_ model: NativeSpeechModel, protocolClasses: [AnyClass] = []) async -> Bool {
    guard let speech, !isInstalling, !isRemoving, !isDownloading else { return false }
    isDownloading = true
    report(nil)
    defer { isDownloading = false }
    let modelId = model.modelId
    let modelToken = DiagnosticPrivacy.token(modelId)
    let fileName = model.fileName
    do {
      let plan = try await Task.detached(priority: .utility) {
        try speech.planModelDownload(modelId: modelId)
      }.value
      guard let origin = URL(string: plan.url), origin.scheme == "https" else {
        throw CatalogTransferError.refused
      }
      try await CatalogOriginTransfer.copy(
        origin: origin, partialPath: plan.partialPath, expectedLength: plan.expectedLength,
        resumeOffset: plan.resumeOffset, protocolClasses: protocolClasses)
      isInstalling = true
      defer { isInstalling = false }
      try await Task.detached(priority: .utility) {
        try speech.finishModelDownload(modelId: modelId)
      }.value
      await refreshAndWait()
      guard catalogWarning == nil,
        models.contains(where: { $0.modelId == modelId && $0.installed && $0.readiness == .ready })
      else {
        report(
          "\(fileName) was installed, but its readiness could not be confirmed. Refresh the model catalog to check it again.",
          failure: true)
        return false
      }
      report("\(fileName) verified and installed.")
      AppTelemetry.libraryNote(
        stage: "speech-download", detail: "model=\(modelToken) result=installed")
      return true
    } catch {
      refresh()
      report(Self.describe(error), failure: true)
      AppTelemetry.libraryNote(
        stage: "speech-download",
        detail: "model=\(modelToken) result=rejected code=\(Self.speechCode(error))"
      )
      return false
    }
  }

  /// Copies, verifies, self-tests, and installs the chosen file off the main
  /// actor. Success also requires the current catalog to publish readiness.
  /// The chosen source file is not changed; rejected bytes install nothing.
  @discardableResult
  func install(_ model: NativeSpeechModel, from url: URL) async -> Bool {
    guard let speech, !isInstalling, !isRemoving else { return false }
    isInstalling = true
    report(nil)
    defer { isInstalling = false }
    let modelId = model.modelId
    let modelToken = DiagnosticPrivacy.token(modelId)
    let path = url.path
    do {
      try await Task.detached(priority: .utility) {
        if model.readiness == .invalid {
          try speech.repairFromFile(modelId: modelId, sourcePath: path)
        } else {
          try speech.installFromFile(modelId: modelId, sourcePath: path)
        }
      }.value
      await refreshAndWait()
      guard catalogWarning == nil,
        models.contains(where: { $0.modelId == modelId && $0.installed && $0.readiness == .ready })
      else {
        report(
          "\(model.fileName) was installed, but its readiness could not be confirmed. Refresh the model catalog to check it again.",
          failure: true)
        AppTelemetry.libraryNote(
          stage: "speech-install", detail: "model=\(modelToken) result=readiness_unavailable")
        return false
      }
      report("\(model.fileName) verified and installed.")
      AppTelemetry.libraryNote(
        stage: "speech-install", detail: "model=\(modelToken) result=installed")
      return true
    } catch {
      refresh()
      report(Self.describe(error), failure: true)
      AppTelemetry.libraryNote(
        stage: "speech-install",
        detail: "model=\(modelToken) result=rejected code=\(Self.speechCode(error))"
      )
      return false
    }
  }

  /// Moves one installed version out of the loadable path, then to Trash.
  /// An active transcription is asked to stop; this wait does not run on the
  /// capture path. The model bytes stay on disk until Trash accepts them.
  @discardableResult
  func remove(_ model: NativeSpeechModel) async -> Bool {
    guard let speech, !isInstalling, !isRemoving else { return false }
    isRemoving = true
    report(nil)
    defer { isRemoving = false }
    let modelId = model.modelId
    let modelToken = DiagnosticPrivacy.token(modelId)
    let fileName = model.fileName
    do {
      let quarantined = try await Task.detached(priority: .utility) {
        var pending = 0
        while true {
          do {
            return try speech.removeInstalled(modelId: modelId, cancelActiveRuns: true)
          } catch let error as NativeSpeechError {
            if case .ModelRejected(let reason) = error, reason == "active_run", pending < 50 {
              pending += 1
              try await Task.sleep(for: .milliseconds(200))
              continue
            }
            throw error
          }
        }
      }.value
      var trashed = false
      if FileManager.default.fileExists(atPath: quarantined) {
        do {
          try FileManager.default.trashItem(
            at: URL(fileURLWithPath: quarantined, isDirectory: true), resultingItemURL: nil)
          trashed = true
        } catch {
          trashed = false
        }
      }
      await refreshAndWait()
      if trashed {
        report("\(fileName) was removed.")
      } else {
        report(
          "\(fileName) was removed from transcription. The file is still on this Mac.",
          failure: true)
      }
      AppTelemetry.libraryNote(
        stage: "speech-install", detail: "model=\(modelToken) result=deleted")
      return true
    } catch {
      refresh()
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
    await process(sessionId: sessionId, intent: .resumeIncomplete) == .completed
  }

  func process(sessionId: String, intent: NativeTranscriptionIntent, admission: String? = nil) async
    -> NativeWorkOutcome
  {
    await processResult(sessionId: sessionId, intent: intent, admission: admission).outcome
  }

  /// Preserve the typed result for the scheduler's session-bound presentation.
  func processResult(sessionId: String, intent: NativeTranscriptionIntent, admission: String? = nil)
    async -> NativeTranscriptionResult
  {
    guard let speech, transcribingSessionId == nil else {
      return NativeTranscriptionResult(outcome: .deferred, summary: nil, reason: nil, failure: nil)
    }
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
    let modelId = installedModel?.modelId ?? ""
    let sessionToken = DiagnosticPrivacy.token(sessionId)
    let modelToken = DiagnosticPrivacy.token(modelId)
    AppTelemetry.libraryNote(
      stage: "transcription", detail: "started session=\(sessionToken) model=\(modelToken)")
    let preparation = preparation
    let work = Task.detached(priority: .utility) {
      try Self.run(
        speech: speech, preparation: preparation, modelId: modelId, sessionId: sessionId,
        intent: intent, admission: admission, job: job)
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
      let result = try await work.value
      guard result.outcome == .completed, let summary = result.summary else {
        report(SpeechFailurePresentation.text(for: result), failure: result.outcome == .failed)
        if let failure = result.failure {
          AppTelemetry.libraryNote(
            stage: "transcription",
            detail:
              "ended session=\(sessionToken) code=\(SpeechFailurePresentation.diagnostic(failure))")
        }
        if result.outcome == .failed || result.outcome == .deferred { refresh() }
        return result
      }
      let tracks = summary.tracks == 1 ? "1 track" : "\(summary.tracks) tracks"
      let segments = summary.segments == 1 ? "1 segment" : "\(summary.segments) segments"
      report("Transcribed \(tracks) on this Mac: \(segments).")
      AppTelemetry.libraryNote(
        stage: "transcription",
        detail:
          "committed session=\(sessionToken) tracks=\(summary.tracks) segments=\(summary.segments)"
      )
      return result
    } catch {
      let cancelled = (error as? NativeSpeechError) == .Cancelled || error is CancellationError
      let outcome = job.stopOutcome() ?? (cancelled ? .userCancelled : .failed)
      report(
        outcome == .failed ? Self.describe(error) : Self.outcomeText(outcome),
        failure: outcome == .failed)
      let code = error is CancellationError ? "cancelled" : Self.speechCode(error)
      AppTelemetry.libraryNote(
        stage: "transcription", detail: "failed session=\(sessionToken) code=\(code)")
      return NativeTranscriptionResult(
        outcome: outcome, summary: nil, reason: nil, failure: error as? NativeSpeechError)
    }
  }

  func cancel() {
    job?.cancel()
  }
  func preemptForCapture() { job?.preemptForCapture() }

  private static func outcomeText(_ outcome: NativeWorkOutcome) -> String {
    SpeechFailurePresentation.outcomeText(outcome)
  }

  /// A compressed import is first decoded, from its leased bytes, into a
  /// temporary PCM companion that Rust validates and reads; it is removed after.
  nonisolated private static func run(
    speech: NativeSpeechModels, preparation: NativeRecordingPreparation?, modelId: String,
    sessionId: String, intent: NativeTranscriptionIntent, admission: String?,
    job: NativeTranscriptionJob
  ) throws -> NativeTranscriptionResult {
    if intent == .reconcileRetained {
      return speech.transcribeWithIntent(
        modelId: modelId, sessionId: sessionId, intent: intent, admission: admission,
        decodedCompanionPath: nil, job: job)
    }
    guard try speech.needsDecodedCompanionForIntent(sessionId: sessionId, intent: intent) else {
      return speech.transcribeWithIntent(
        modelId: modelId, sessionId: sessionId, intent: intent, admission: admission,
        decodedCompanionPath: nil, job: job)
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
    return speech.transcribeWithIntent(
      modelId: modelId, sessionId: sessionId, intent: intent, admission: admission,
      decodedCompanionPath: companion.path, job: job)
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

  nonisolated static func speechCode(_ error: Error) -> String {
    SpeechFailurePresentation.code(error)
  }

  nonisolated static func describe(_ error: Error) -> String {
    SpeechFailurePresentation.describe(error)
  }

  nonisolated static func rejection(_ reason: String) -> String {
    SpeechFailurePresentation.rejection(reason)
  }
}

private enum CatalogTransferError: Error {
  case refused
}

/// Writes one catalog response into the managed partial and stops one byte
/// past the published length. A redirect to any other URL is refused.
private final class CatalogOriginTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let origin: URL
  private let room: UInt64
  private let handle: FileHandle
  private var written: UInt64 = 0
  private var hitLimit = false
  private var failure: Error?
  private var continuation: CheckedContinuation<Void, Error>?
  private var resumed = false

  static func copy(
    origin: URL, partialPath: String, expectedLength: UInt64, resumeOffset: UInt64,
    protocolClasses: [AnyClass]
  ) async throws {
    let partial = URL(fileURLWithPath: partialPath)
    let values = try partial.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .linkCountKey,
    ])
    guard origin.scheme == "https", resumeOffset <= expectedLength,
      values.isSymbolicLink != true, values.isRegularFile == true, (values.linkCount ?? 0) <= 1,
      UInt64(values.fileSize ?? 0) == resumeOffset
    else { throw CatalogTransferError.refused }
    let handle = try FileHandle(forWritingTo: partial)
    if resumeOffset > 0 { try handle.seek(toOffset: resumeOffset) }
    let transfer = CatalogOriginTransfer(
      origin: origin, room: (expectedLength &+ 1) &- resumeOffset, handle: handle)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.waitsForConnectivity = false
    if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: queue)
    defer { session.finishTasksAndInvalidate() }
    try await transfer.run(session)
  }

  private init(origin: URL, room: UInt64, handle: FileHandle) {
    self.origin = origin
    self.room = room
    self.handle = handle
  }

  private func run(_ session: URLSession) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      session.dataTask(with: origin).resume()
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      dataTask.originalRequest?.url == origin
    else {
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(request.url == origin ? request : nil)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let remaining = room &- written
    guard remaining > 0 else {
      hitLimit = true
      dataTask.cancel()
      return
    }
    let chunk = data.prefix(Int(min(UInt64(data.count), remaining)))
    do {
      try handle.write(contentsOf: chunk)
      written &+= UInt64(chunk.count)
      if written >= room {
        hitLimit = true
        dataTask.cancel()
      }
    } catch {
      failure = error
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    try? handle.synchronize()
    if let failure {
      finish(.failure(failure))
    } else if error == nil || hitLimit {
      finish(written > 0 ? .success(()) : .failure(CatalogTransferError.refused))
    } else {
      finish(.failure(error ?? CatalogTransferError.refused))
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    guard !resumed else { return }
    resumed = true
    try? handle.close()
    continuation?.resume(with: result)
    continuation = nil
  }
}
