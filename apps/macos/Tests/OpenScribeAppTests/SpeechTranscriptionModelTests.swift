import AVFoundation
import AppKit
import SwiftUI
import XCTest

@testable import OpenScribeApp

@MainActor
final class SpeechTranscriptionModelTests: XCTestCase {
  func testSpeechDiagnosticsUseTypedErrorsInsteadOfReflectedDescriptions() {
    struct ForgedDescription: Error, CustomStringConvertible {
      var description: String { "ModelNotInstalled" }
    }
    XCTAssertEqual(SpeechTranscriptionModel.speechCode(ForgedDescription()), "unavailable")
    XCTAssertEqual(
      SpeechTranscriptionModel.speechCode(
        NativeSpeechError.ModelRejected(reason: "FICTIONAL_PRIVATE_CANARY_6C27")),
      "ModelRejected")
    XCTAssertEqual(SpeechTranscriptionModel.speechCode(CancellationError()), "cancelled")
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  func testAFreshLibraryListsTheCatalogAndRefusesAWrongFile() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let speech = SpeechTranscriptionModel(managedRoot: root)
    XCTAssertTrue(
      speech.isRefreshing, "discovery returns before native catalog verification completes")
    for _ in 0..<100 where speech.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(speech.models.map(\.modelId), ["whisper-small.en-q5_1", "whisper-small-q5_1"])
    XCTAssertTrue(speech.models.allSatisfy { !$0.installed && $0.engine == "whisper.cpp 1.8.3" })
    XCTAssertNil(speech.installedModel)

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let wrong = root.appendingPathComponent("ggml-small.en-q5_1.bin")
    try Data("not the model".utf8).write(to: wrong)
    let installed = await speech.install(try XCTUnwrap(speech.models.first), from: wrong)
    XCTAssertFalse(installed)
    XCTAssertTrue(speech.messageIsFailure)
    XCTAssertEqual(
      speech.message, "The model file was not installed: it is shorter than the published file.")
    XCTAssertNil(speech.installedModel)
    XCTAssertEqual(try Data(contentsOf: wrong), Data("not the model".utf8))

    let transcribed = await speech.transcribe(sessionId: "any")
    XCTAssertFalse(transcribed, "nothing runs without a verified model")
    XCTAssertNil(speech.transcribingSessionId)
  }

  func testSuccessfulInstallAndRepairPublishReadinessBeforeReturning() async throws {
    let readinesses: [NativeModelReadiness] = [.absent, .invalid]
    for initial in readinesses {
      let native = DelayedInstalledCatalog(initial: initial)
      let speech = SpeechTranscriptionModel(speech: native)
      for _ in 0..<500 where speech.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
      let record = try XCTUnwrap(speech.models.first)
      var returned = false
      let installing = Task {
        let success = await speech.install(
          record, from: URL(fileURLWithPath: "/unused-fixture.bin"))
        returned = true
        return success
      }
      let verifying = await Task.detached {
        native.waitForVerification()
      }.value
      XCTAssertTrue(verifying)
      XCTAssertFalse(returned, "success must wait for the installed catalog result to be published")
      XCTAssertTrue(speech.isInstalling)
      native.releaseVerification.signal()
      let installed = await installing.value
      XCTAssertTrue(installed)
      XCTAssertEqual(speech.installedModel?.modelId, record.modelId)
      XCTAssertEqual(speech.readiness, .ready)
      XCTAssertFalse(speech.isInstalling)
      XCTAssertFalse(speech.isRefreshing)
      let outcome = await speech.process(sessionId: "fixture", intent: .resumeIncomplete)
      XCTAssertEqual(outcome, .completed)
      XCTAssertEqual(
        native.transcribedModelId, record.modelId,
        "an immediate caller never passes an empty model id")
    }
  }

  func testCommittedInstallDoesNotClaimReadinessWhenReverificationRejectsIt() async throws {
    let native = DelayedInstalledCatalog(initial: .absent, afterInstall: .invalid)
    let speech = SpeechTranscriptionModel(speech: native)
    await speech.refreshAndWait()
    let record = try XCTUnwrap(speech.models.first)
    let installing = Task {
      await speech.install(record, from: URL(fileURLWithPath: "/unused-fixture.bin"))
    }
    let verifying = await Task.detached { native.waitForVerification() }.value
    XCTAssertTrue(verifying)
    native.releaseVerification.signal()
    let installed = await installing.value
    XCTAssertFalse(installed)
    XCTAssertNil(speech.installedModel)
    XCTAssertEqual(speech.readiness, .invalid)
    XCTAssertTrue(speech.messageIsFailure)
    XCTAssertTrue(speech.message?.contains("was installed") == true)
    XCTAssertTrue(speech.message?.contains("readiness could not be confirmed") == true)
    XCTAssertFalse(speech.isInstalling)
  }

  /// The complete consumer path on the real pinned model: install from the
  /// chosen file, transcribe an imported conversation, then review and
  /// search it. Set `OPEN_SCRIBE_WHISPER_MODEL` and
  /// `OPEN_SCRIBE_WHISPER_SPEECH_CAF` (`TEST_RUNNER_` prefix under xcodebuild).
  func testThePinnedModelInstallsAndTranscribesAConversation() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_CAF"]
    else {
      throw XCTSkip(
        "Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_CAF for the real-model path.")
    }
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    let session = try preparation.importRecoverableCaf(title: "Spoken", sourcePath: speechPath)
      .sessionId

    let speech = SpeechTranscriptionModel(managedRoot: root)
    await speech.refreshAndWait()
    let model = try XCTUnwrap(speech.models.first)
    let installed = await speech.install(model, from: URL(fileURLWithPath: modelPath))
    XCTAssertTrue(installed, speech.message ?? "")
    XCTAssertEqual(speech.installedModel?.modelId, "whisper-small.en-q5_1")

    let transcribed = await speech.transcribe(sessionId: session)
    XCTAssertTrue(transcribed, speech.message ?? "")
    XCTAssertFalse(speech.messageIsFailure)
    XCTAssertNil(speech.transcribingSessionId)

    let transcripts = TranscriptLibraryModel(managedRoot: root)
    await transcripts.load(sessionId: session)
    XCTAssertEqual(transcripts.availability, .final)
    let text = transcripts.segments.map(\.effectiveText).joined(separator: " ").lowercased()
    XCTAssertTrue(text.contains("recording safe"), text)
    await transcripts.search("transcript")
    XCTAssertEqual(transcripts.searchResults.count, 1)
  }

  /// Renders the no-model, installed, and in-progress transcript states and
  /// the model sheet. Set OPEN_SCRIBE_RENDER_DIR (TEST_RUNNER_ prefix under
  /// xcodebuild) to keep PNGs.
  func testTranscriptionStatesAndModelSheetRender() throws {
    let session = RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "session", title: "Weekly planning", lifecycle: "ready_for_review",
        health: "healthy", elapsedSeconds: 3_900, journalDurable: true, mediaFilesOpen: false,
        interruptionReason: nil, recovered: false, hasCaptureTimeline: true, sources: [],
        playableMedia: nil))
    func model(
      _ id: String, _ languages: [String], installed: Bool, readiness: NativeModelReadiness? = nil
    ) -> NativeSpeechModel {
      NativeSpeechModel(
        modelId: id, profile: "balanced", languages: languages,
        fileName: "ggml-\(id.dropFirst(8)).bin", byteLength: 190_098_681,
        sha256: "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
        downloadOrigin: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861/ggml.bin",
        license: "MIT", engine: "whisper.cpp 1.8.3", installed: installed,
        readiness: readiness ?? (installed ? .ready : .absent),
        diagnostic: readiness == .invalid ? "digest mismatch" : nil)
    }
    let uninstalled = [
      model("whisper-small.en-q5_1", ["en"], installed: false),
      model("whisper-small-q5_1", ["en", "de"], installed: false),
    ]
    let installed = [model("whisper-small.en-q5_1", ["en"], installed: true)]
    let progress = NativeTranscriptionProgress(
      stage: .transcribing, trackIndex: 0, trackCount: 2, completedNanoseconds: 30_000_000_000,
      requiredNanoseconds: 60_000_000_000)
    let states: [(String, SpeechTranscriptionModel)] = [
      ("transcription-no-model", SpeechTranscriptionModel(preview: uninstalled)),
      ("transcription-ready", SpeechTranscriptionModel(preview: installed)),
      (
        "transcription-progress",
        SpeechTranscriptionModel(preview: installed, transcribing: "session", progress: progress)
      ),
    ]
    let transcripts = TranscriptLibraryModel(preview: .unavailable, segments: [], speakers: [])
    var views: [(String, AnyView)] = states.map { name, speech in
      (
        name,
        AnyView(
          TranscriptSection(
            session: session, transcripts: transcripts, speech: speech,
            scheduler: TranscriptionScheduler.inert(), canSeek: true, onSeek: { _ in })
        )
      )
    }
    views.append(
      (
        "speech-model-sheet",
        AnyView(SpeechModelSheet(speech: SpeechTranscriptionModel(preview: uninstalled)) {})
      ))
    views.append(
      (
        "speech-model-repair",
        AnyView(
          SpeechModelSheet(
            speech: SpeechTranscriptionModel(preview: [
              model("whisper-small.en-q5_1", ["en"], installed: false, readiness: .invalid)
            ])
          ) {})
      ))
    views.append(
      (
        "settings",
        AnyView(
          SettingsView(
            status: AppStatus(
              productName: "Open Scribe", coreVersion: "fixture", persistence: "local",
              capture: "fixture", intelligence: "off"),
            speech: SpeechTranscriptionModel(preview: installed),
            library: RuntimeLibraryStore(managedRoot: nil, refreshesImmediately: false),
            recovery: RecoveredSessionController(managedRoot: nil),
            scheduler: TranscriptionScheduler.inert(),
            pressure: SystemPressureMonitor(libraryRoot: nil, samplesAutomatically: false)
          ).frame(height: 500))
      ))
    XCTAssertEqual(states[2].1.progressFraction, 0.25)
    XCTAssertEqual(states[2].1.progressText, "Transcribing track 1 of 2…")
    for (name, content) in views {
      let view = content.padding(32).frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
      let host = NSHostingView(rootView: view)
      let size = host.fittingSize
      XCTAssertLessThanOrEqual(size.width, 601, name)
      XCTAssertGreaterThan(size.height, 80, name)
      guard let directory = ProcessInfo.processInfo.environment["OPEN_SCRIBE_RENDER_DIR"] else {
        continue
      }
      let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .aqua)
      window.contentView = host
      host.setFrameSize(size)
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      window.close()
      try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
  }

  /// A compressed import needs a decoded companion; the platform decode from
  /// its leased bytes is 48 kHz 16-bit PCM with the import's exact frames.
  func testACompressedImportDecodesToAnExactPCMCompanion() throws {
    let root = temporaryRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Stereo memo.m4a")
    do {
      let file = try AVAudioFile(
        forWriting: source,
        settings: [
          AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96_000))
      buffer.frameLength = 96_000
      let channels = try XCTUnwrap(buffer.floatChannelData)
      for frame in 0..<96_000 {
        channels[0][frame] = 0.25
        channels[1][frame] = -0.25
      }
      try file.write(from: buffer)
    }
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let evidence = try RuntimeLibraryStore(managedRoot: managedRoot)
      .importManagedAudio(title: "Stereo memo", sourceURL: source)
    XCTAssertTrue(evidence.relativePath.hasSuffix(".m4a"))
    let speech = try NativeSpeechModels.open(managedRoot: managedRoot.path)
    XCTAssertTrue(try speech.needsDecodedCompanion(sessionId: evidence.sessionId))

    let companion = root.appendingPathComponent("decoded.caf")
    let lease = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
      .leaseImportedPlayback(sessionId: evidence.sessionId)
    try TranscriptionCompanionDecoder.decode(lease: lease, to: companion, isCancelled: { false })
    let decoded = try AVAudioFile(forReading: companion)
    XCTAssertEqual(decoded.length, 96_000)
    XCTAssertEqual(decoded.fileFormat.channelCount, 2)
    XCTAssertEqual(decoded.fileFormat.sampleRate, 48_000)
    XCTAssertEqual(decoded.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
    XCTAssertEqual(decoded.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatLinearPCM)

    let cancelled = root.appendingPathComponent("cancelled.caf")
    XCTAssertThrowsError(
      try TranscriptionCompanionDecoder.decode(lease: lease, to: cancelled, isCancelled: { true }))
  }

  /// The real model on a compressed stereo AAC import: the app decodes the
  /// companion, Rust validates it, and the transcript reads back. Set
  /// `OPEN_SCRIBE_WHISPER_MODEL` and `OPEN_SCRIBE_WHISPER_SPEECH_M4A`.
  func testThePinnedModelTranscribesACompressedImport() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_M4A"]
    else {
      throw XCTSkip("Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_M4A.")
    }
    let root = temporaryRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Spoken.m4a")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: source)
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let evidence = try RuntimeLibraryStore(managedRoot: managedRoot)
      .importManagedAudio(title: "Spoken", sourceURL: source)
    XCTAssertTrue(evidence.relativePath.hasSuffix(".m4a"), "kept compressed")

    let speech = SpeechTranscriptionModel(managedRoot: managedRoot)
    await speech.refreshAndWait()
    let installed = await speech.install(
      try XCTUnwrap(speech.models.first), from: URL(fileURLWithPath: modelPath))
    XCTAssertTrue(installed, speech.message ?? "")
    let transcribed = await speech.transcribe(sessionId: evidence.sessionId)
    XCTAssertTrue(transcribed, speech.message ?? "")

    let transcripts = TranscriptLibraryModel(managedRoot: managedRoot)
    await transcripts.load(sessionId: evidence.sessionId)
    XCTAssertEqual(transcripts.availability, .final)
    let text = transcripts.segments.map(\.effectiveText).joined(separator: " ").lowercased()
    XCTAssertTrue(text.contains("recording safe"), text)
  }
}

/// Coarse native adapter only: no file access, weights, ASR, or downloads.
/// Holds post-install discovery so the production model's return ordering is deterministic.
private final class DelayedInstalledCatalog: NativeSpeechModels, @unchecked Sendable {
  let verificationEntered = DispatchSemaphore(value: 0)
  let releaseVerification = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private let initial: NativeModelReadiness
  private let afterInstall: NativeModelReadiness
  private var installed = false
  private var processedModelId: String?
  var transcribedModelId: String? { lock.withLock { processedModelId } }
  func waitForVerification() -> Bool {
    verificationEntered.wait(timeout: .now() + 5) == .success
  }

  init(initial: NativeModelReadiness, afterInstall: NativeModelReadiness = .ready) {
    self.initial = initial
    self.afterInstall = afterInstall
    super.init(noHandle: NoHandle())
  }
  required init(unsafeFromHandle handle: UInt64) {
    initial = .absent
    afterInstall = .ready
    super.init(unsafeFromHandle: handle)
  }
  override func models() -> [NativeSpeechModel] {
    let ready = lock.withLock { installed }
    if ready {
      verificationEntered.signal()
      _ = releaseVerification.wait(timeout: .now() + 5)
    }
    return [
      NativeSpeechModel(
        modelId: "whisper-small.en-q5_1", profile: "fixture", languages: ["en"],
        fileName: "fixture.bin", byteLength: 10, sha256: String(repeating: "a", count: 64),
        downloadOrigin: "https://example.invalid/fixture", license: "MIT", engine: "fixture",
        installed: ready && afterInstall == .ready,
        readiness: ready ? afterInstall : initial, diagnostic: nil)
    ]
  }
  override func installFromFile(modelId: String, sourcePath: String) throws {
    lock.withLock { installed = true }
  }
  override func repairFromFile(modelId: String, sourcePath: String) throws {
    lock.withLock { installed = true }
  }
  override func needsDecodedCompanionForIntent(sessionId: String, intent: NativeTranscriptionIntent)
    throws -> Bool
  { false }
  override func transcribeWithIntent(
    modelId: String, sessionId: String, intent: NativeTranscriptionIntent, admission: String?,
    decodedCompanionPath: String?, job: NativeTranscriptionJob
  ) -> NativeTranscriptionResult {
    lock.withLock { processedModelId = modelId }
    return NativeTranscriptionResult(
      outcome: .completed,
      summary: NativeTranscriptionSummary(
        tracks: 1, segments: 0, transcribedChunks: 1, reusedChunks: 0),
      reason: nil, failure: nil)
  }
}
