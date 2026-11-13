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

  private struct PlayableImport: Equatable {
    let byteLength: UInt64
    let digestSha256: String
  }

  private func playableImport(
    _ preparation: NativeRecordingPreparation, sessionId: String
  ) throws -> PlayableImport {
    let lease = try preparation.leaseImportedPlayback(sessionId: sessionId)
    let receipt = try ImportedPlaybackDescriptorReceipt(serialized: lease.playbackPath())
    _ = try AnonymousImportedPlaybackSnapshot.copy(from: receipt)
    return PlayableImport(byteLength: receipt.byteLength, digestSha256: receipt.digestSha256)
  }

  private func writeRecoverableCaf(frames: Int) throws -> Data {
    var data = Data()
    data.append(contentsOf: [0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00])
    data.append(contentsOf: Array("desc".utf8))
    appendBig(Int64(32), to: &data)
    appendBig(Double(48_000).bitPattern, to: &data)
    data.append(contentsOf: Array("lpcm".utf8))
    for value in [UInt32(2), 2, 1, 1, 16] {
      appendBig(value, to: &data)
    }
    data.append(contentsOf: Array("data".utf8))
    appendBig(Int64(-1), to: &data)
    appendBig(UInt32(0), to: &data)
    for frame in 0..<frames {
      let sample = Int16(((frame % 997) - 498) * 31)
      appendLittle(sample, to: &data)
    }
    return data
  }

  private func appendBig(_ value: some FixedWidthInteger, to data: inout Data) {
    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
  }

  private func appendLittle(_ value: some FixedWidthInteger, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
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

  func testOpeningAPlayableConversationWithoutASpeechModelKeepsPlayback() async throws {
    let root = temporaryRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Interview.caf")
    let original = try writeRecoverableCaf(frames: 960)
    try original.write(to: source, options: .atomic)
    let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
    let preparation = try NativeRecordingPreparation.open(managedRoot: libraryRoot.path)
    let imported = try preparation.importRecoverableCaf(
      title: "Interview", sourcePath: source.path)
    let playback = try playableImport(preparation, sessionId: imported.sessionId)
    XCTAssertGreaterThan(playback.byteLength, 0)

    let speech = SpeechTranscriptionModel(managedRoot: libraryRoot)
    await speech.refreshAndWait()
    XCTAssertEqual(
      speech.models.map(\.modelId), ["whisper-small.en-q5_1", "whisper-small-q5_1"])
    XCTAssertTrue(speech.models.allSatisfy { !$0.installed })
    XCTAssertNil(speech.installedModel)

    let saved = try XCTUnwrap(
      preparation.runtimeLibrarySnapshot().savedSessions.first {
        $0.sessionId == imported.sessionId
      })
    let session = RuntimeSessionPresentation(native: saved)
    XCTAssertEqual(session.lifecycle, "ready_for_review")
    XCTAssertNil(session.transcriptionUnavailableReason)
    XCTAssertNil(session.deletionUnavailableReason)
    let transcripts = TranscriptLibraryModel(managedRoot: libraryRoot)
    await transcripts.load(session: session)
    XCTAssertEqual(transcripts.availability, .unavailable)
    XCTAssertTrue(transcripts.segments.isEmpty)
    XCTAssertTrue(
      TranscriptSection.showsInstallSpeechModel(session: session, speech: speech))
    XCTAssertEqual(
      TranscriptSection.statusLine(session: session, transcripts: transcripts, speech: speech),
      TranscriptSection.speechModelUnavailableStatus)
    XCTAssertEqual(TranscriptSection.installSpeechModelTitle, "Set Up Transcription…")

    let library = RuntimeLibraryStore(managedRoot: libraryRoot)
    let renamed = await library.rename(sessionId: imported.sessionId, title: "Interview notes")
    XCTAssertEqual(renamed, "Interview notes")
    let renamedSession = try XCTUnwrap(
      NativeRecordingPreparation.open(managedRoot: libraryRoot.path).runtimeLibrarySnapshot()
        .savedSessions.first { $0.sessionId == imported.sessionId })
    XCTAssertEqual(renamedSession.title, "Interview notes")

    let refused = await speech.transcribe(sessionId: imported.sessionId)
    XCTAssertFalse(refused)
    XCTAssertEqual(speech.message, "No verified speech model is installed.")
    XCTAssertNil(speech.installedModel)
    await transcripts.load(session: session)
    XCTAssertEqual(transcripts.availability, .unavailable)
    XCTAssertTrue(transcripts.segments.isEmpty)
    XCTAssertEqual(try playableImport(preparation, sessionId: imported.sessionId), playback)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  /// Network is denied. Import, recovery, playback, speaker review, search,
  /// correction, and export stay on this Mac. No speech model is installed,
  /// so transcription does not start and no catalog host is contacted.
  func testADeniedNetworkKeepsTheLocalJourneyOffTheNetworkWithoutAnAccount() async throws {
    DeniedNetwork.reset()
    XCTAssertTrue(URLProtocol.registerClass(DeniedNetwork.self))
    defer { URLProtocol.unregisterClass(DeniedNetwork.self) }

    let root = temporaryRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Interview.caf")
    let original = try writeRecoverableCaf(frames: 48_000)
    try original.write(to: source, options: .atomic)
    let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
    let store = RuntimeLibraryStore(managedRoot: libraryRoot, refreshesImmediately: false)
    let evidence = try store.importManagedAudio(title: "Interview", sourceURL: source)
    XCTAssertTrue(evidence.originalUntouched)
    XCTAssertTrue(evidence.readyForReview)
    XCTAssertEqual(try Data(contentsOf: source), original)

    let recovery = RecoveredSessionController(managedRoot: libraryRoot)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    let preparation = try NativeRecordingPreparation.open(managedRoot: libraryRoot.path)
    let saved = try XCTUnwrap(
      try preparation.runtimeLibrarySnapshot().savedSessions.first {
        $0.sessionId == evidence.sessionId
      })
    let session = RuntimeSessionPresentation(native: saved)
    XCTAssertEqual(session.lifecycle, "ready_for_review")
    XCTAssertTrue(session.playableMedia?.isPlayable == true)

    let player = RecoveredAudioPlayer(outputMode: .silent)
    let lease = try preparation.leaseImportedPlayback(sessionId: evidence.sessionId)
    try await player.playImported(
      receipt: lease.playbackPath(), retaining: lease, generation: UUID(), startNanoseconds: 0)
    player.stop()
    let laterLease = try preparation.leaseImportedPlayback(sessionId: evidence.sessionId)
    try await player.playImported(
      receipt: laterLease.playbackPath(), retaining: laterLease, generation: UUID(),
      startNanoseconds: 500_000_000)
    player.stop()
    let beginningSample: Float
    let laterSample: Float
    do {
      let sampleLease = try preparation.leaseImportedPlayback(sessionId: evidence.sessionId)
      let receipt = try ImportedPlaybackDescriptorReceipt(serialized: sampleLease.playbackPath())
      let snapshot = try AnonymousImportedPlaybackSnapshot.copy(from: receipt)
      let decoder = try CallbackCAFDecoder(source: snapshot.region, onClose: {})
      let beginning = try XCTUnwrap(decoder.read(maximumFrames: 1))
      beginningSample = beginning.floatChannelData?[0][0] ?? 0
      try decoder.seek(toFrame: 24_000)
      let later = try XCTUnwrap(decoder.read(maximumFrames: 1))
      laterSample = later.floatChannelData?[0][0] ?? 0
      decoder.close()
      withExtendedLifetime(snapshot) {}
      withExtendedLifetime(sampleLease) {}
    }
    XCTAssertNotEqual(beginningSample, laterSample)
    withExtendedLifetime(lease) {}
    withExtendedLifetime(laterLease) {}

    let library = try NativeTranscriptLibrary.open(managedRoot: libraryRoot.path)
    let transcripts = TranscriptLibraryModel(library: library)
    await transcripts.load(sessionId: evidence.sessionId)
    XCTAssertEqual(transcripts.availability, .unavailable)
    XCTAssertTrue(transcripts.segments.isEmpty)
    let trackId = try XCTUnwrap(transcripts.speakers.first?.trackId)
    let renamed = await transcripts.renameSpeaker(trackId: trackId, label: " Dana ")
    XCTAssertTrue(renamed)
    XCTAssertEqual(transcripts.speakers.first?.label, "Dana")
    let restored = await transcripts.renameSpeaker(trackId: trackId, label: nil)
    XCTAssertTrue(restored)
    XCTAssertEqual(transcripts.speakers.first?.label, "Speaker")
    XCTAssertTrue(try library.search(query: "interview", sessionId: evidence.sessionId, limit: 20).isEmpty)
    XCTAssertThrowsError(
      try library.correctSegment(
        sessionId: evidence.sessionId, revisionId: "missing-revision", sequence: 0,
        text: "changed words"))

    let speech = SpeechTranscriptionModel(managedRoot: libraryRoot)
    await speech.refreshAndWait()
    XCTAssertTrue(speech.models.allSatisfy { !$0.installed })
    XCTAssertNil(speech.installedModel)
    XCTAssertFalse(speech.isDownloading)
    let transcribed = await speech.transcribe(sessionId: evidence.sessionId)
    XCTAssertFalse(transcribed)
    XCTAssertEqual(speech.message, "No verified speech model is installed.")
    XCTAssertFalse(speech.messageIsFailure)
    await transcripts.load(sessionId: evidence.sessionId)
    XCTAssertTrue(transcripts.segments.isEmpty)

    let exported = root.appendingPathComponent("Interview.md")
    let wrote = await transcripts.export(format: .markdown, to: exported)
    XCTAssertTrue(wrote, transcripts.message ?? "")
    XCTAssertGreaterThan(try Data(contentsOf: exported).count, 0)
    XCTAssertEqual(try Data(contentsOf: source), original)

    let account = ProviderAuthorizationModel()
    XCTAssertFalse(account.configured)
    XCTAssertTrue(account.grants.isEmpty)
    XCTAssertFalse(account.outboundRequest)
    XCTAssertFalse(account.networkUsed)
    XCTAssertEqual(account.notice, providerUnconfiguredNotice())
    let requests = DeniedNetwork.requests
    XCTAssertEqual(requests, [], "outbound requests: \(requests.joined(separator: " "))")
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(store) {}
  }

  func testAnExplicitDownloadRefusesAShortCatalogFileAndLeavesARecording() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sibling = root.appendingPathComponent("Sessions/s/audio/keep.caf")
    try FileManager.default.createDirectory(
      at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
    let siblingBytes = Data("recording-bytes".utf8)
    try siblingBytes.write(to: sibling)
    let speech = SpeechTranscriptionModel(managedRoot: root)
    await speech.refreshAndWait()
    let model = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let native = try NativeSpeechModels.open(managedRoot: root.path)
    let plan = try native.planModelDownload(modelId: model.modelId)
    XCTAssertEqual(plan.url, model.downloadOrigin)
    XCTAssertEqual(plan.resumeOffset, 0)
    XCTAssertEqual(plan.expectedLength, model.byteLength)
    XCTAssertTrue(plan.url.hasPrefix("https://"))

    let downloaded = await speech.download(model, protocolClasses: [ShortCatalogDownload.self])
    XCTAssertFalse(downloaded)
    XCTAssertTrue(speech.messageIsFailure)
    XCTAssertEqual(
      speech.message, "The model file was not installed: it is shorter than the published file.")
    XCTAssertNil(speech.installedModel)
    XCTAssertFalse(speech.isDownloading)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: plan.partialPath)), ShortCatalogDownload.body)
    XCTAssertEqual(try Data(contentsOf: sibling), siblingBytes)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(
          "Models/whisper-small.en-q5_1/1.0.0/ggml-small.en-q5_1.bin"
        ).path))
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

  /// The installed speech model writes the transcript. The section shows that
  /// run's engine, model revision, input, and evidence. The test does not
  /// call `load` or `provenanceText`.
  func testHostedReviewReadsTheInstalledModelRun() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_M4A"]
    else {
      return XCTFail("OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_M4A are required")
    }
    let root = temporaryRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Spoken.m4a")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: source)
    let original = try Data(contentsOf: source)
    let modelURL = URL(fileURLWithPath: modelPath)
    let modelBytes = try XCTUnwrap(modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let evidence = try RuntimeLibraryStore(managedRoot: managedRoot)
      .importManagedAudio(title: "Spoken", sourceURL: source)
    let speech = SpeechTranscriptionModel(managedRoot: managedRoot)
    await speech.refreshAndWait()
    let record = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await speech.install(record, from: modelURL)
    XCTAssertTrue(installed, speech.message ?? "")
    let installedModel = try XCTUnwrap(speech.installedModel)
    let transcribed = await speech.transcribe(sessionId: evidence.sessionId)
    XCTAssertTrue(transcribed, speech.message ?? "")

    let preparation = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
    let saved = try XCTUnwrap(
      try preparation.runtimeLibrarySnapshot().savedSessions.first {
        $0.sessionId == evidence.sessionId
      })
    let presentation = RuntimeSessionPresentation(native: saved)
    XCTAssertNil(presentation.transcriptionUnavailableReason)
    let library = try NativeTranscriptLibrary.open(managedRoot: managedRoot.path)
    let inspected = try library.inspectProvenance(sessionId: evidence.sessionId)
    let item = try XCTUnwrap(inspected.first)
    let range = try XCTUnwrap(item.ranges.first)
    XCTAssertEqual(item.engine, "whisper.cpp")
    XCTAssertEqual(item.engineVersion, "1.8.3")
    XCTAssertEqual(installedModel.engine, "\(item.engine) \(item.engineVersion)")
    XCTAssertEqual(item.modelId, installedModel.modelId)
    XCTAssertEqual(item.modelSha256, installedModel.sha256)
    XCTAssertEqual(item.modelSha256.count, 64)
    XCTAssertFalse(item.engine.isEmpty)
    XCTAssertNotEqual(item.engine, "fixture-engine")
    XCTAssertEqual(item.runState, "complete")
    XCTAssertEqual(item.finality, "final")
    XCTAssertFalse(item.inputDigest.isEmpty)

    let model = TranscriptLibraryModel(library: library)
    let section = TranscriptSection(
      session: presentation,
      transcripts: model,
      speech: SpeechTranscriptionModel(preview: []),
      scheduler: TranscriptionScheduler.inert(),
      canSeek: false,
      onSeek: { _ in }
    ).frame(width: 720, height: 640)
    let host = NSHostingView(rootView: section)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 720, height: 640))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard let field = self.provenanceField(in: host) else { return false }
      return !field.isHidden && field.frame.width > 1 && field.frame.height > 1
        && field.stringValue.contains("does not claim")
        && field.isDescendant(of: host)
    }
    let field = try XCTUnwrap(self.provenanceField(in: host))
    XCTAssertTrue(shown && window.contentView === host && field.isDescendant(of: host))
    let visible = field.stringValue
    XCTAssertTrue(visible.contains("Engine \(item.engine) \(item.engineVersion)."), visible)
    XCTAssertTrue(
      visible.contains("Model \(item.modelId), revision \(item.modelSha256)."), visible)
    XCTAssertTrue(visible.contains("Input \(item.inputDigest)."), visible)
    XCTAssertTrue(visible.contains("Run \(item.runState)."), visible)
    XCTAssertTrue(visible.contains("Finality \(item.finality)."), visible)
    XCTAssertTrue(
      visible.contains("Evidence \(range.startNanoseconds)-\(range.endNanoseconds) ns."), visible)
    XCTAssertTrue(
      visible.hasSuffix(
        "Open Scribe does not claim that running this model again produces the same words."),
      visible)
    XCTAssertFalse(visible.localizedCaseInsensitiveContains("identical"))
    XCTAssertFalse(visible.localizedCaseInsensitiveContains("deterministic"))
    XCTAssertFalse(visible.localizedCaseInsensitiveContains("recording safe"))
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, modelBytes)
    withExtendedLifetime(model) {}
    withExtendedLifetime(speech) {}
  }

  /// A final transcript is already selected. The hosted reprocess button asks,
  /// then starts a replacement. The original revision text and the source audio
  /// stay in place while that replacement is created.
  func testHostedReprocessKeepsTheSelectedTranscriptAndTheSourceAudio() async throws {
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
    let original = try Data(contentsOf: source)
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let recovery = RecoveredSessionController(
      recoveryFactory: {
        try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
          .leaseImportedPlayback(sessionId: sessionId)
      },
      player: RecoveredAudioPlayerFake()
    )
    let live = LiveMicrophoneRecordingController(managedRoot: managedRoot)
    live.isLaunchRecoveryPending = { !recovery.captureSafetyComplete }
    let store = RuntimeLibraryStore(
      managedRoot: managedRoot, isLaunchRecoveryPending: { !recovery.captureSafetyComplete })
    let speech = SpeechTranscriptionModel(managedRoot: managedRoot)
    let pressure = SystemPressureMonitor(libraryRoot: managedRoot, samplesAutomatically: false)
    let defaults = UserDefaults(suiteName: "OpenScribe.Proof.Reprocess.\(UUID().uuidString)")!
    let scheduler = TranscriptionScheduler(
      managedRoot: managedRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    await speech.refreshAndWait()
    let evidence = try store.importManagedAudio(title: "Spoken", sourceURL: source)
    let sessionId = evidence.sessionId
    let record = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await speech.install(record, from: URL(fileURLWithPath: modelPath))
    XCTAssertTrue(installed, speech.message ?? "")
    let transcribed = await waitUntil(timeoutNanoseconds: 180_000_000_000) {
      store.refresh()
      guard let session = store.savedSessions.first(where: { $0.sessionId == sessionId }) else {
        return false
      }
      return session.transcript.documentAvailability == .final
        && session.transcript.selectedRevisionIds.isEmpty == false
        && scheduler.runningSessionId == nil
        && scheduler.queue.isEmpty
    }
    XCTAssertTrue(
      transcribed,
      "state=\(String(describing: scheduler.state(for: sessionId))) hold=\(String(describing: scheduler.hold)) message=\(speech.message ?? "")"
    )
    store.refresh()
    let session = try XCTUnwrap(store.savedSessions.first { $0.sessionId == sessionId })
    let mediaBefore = try audioFiles(under: managedRoot)
    XCTAssertFalse(mediaBefore.isEmpty)
    let before = try storedRevisions(managedRoot: managedRoot, sessionId: sessionId)
    let selected = try XCTUnwrap(
      before.first { $0.selected },
      "session=\(sessionId) revisions=\(before) snapshot=\(session.transcript.selectedRevisionIds)"
    )
    XCTAssertFalse(selected.text.isEmpty, before.map(\.text).joined(separator: " | "))
    let beforeIds = Set(before.map(\.id))
    let section = TranscriptSection(
      session: session, transcripts: TranscriptLibraryModel(managedRoot: managedRoot),
      speech: speech, scheduler: scheduler, canSeek: false, onSeek: { _ in }
    ).frame(width: 720, height: 900)
    let host = NSHostingView(rootView: section)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 720, height: 900))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let asked = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedButton(labeled: "Reprocess All Tracks…", in: host) != nil
    }
    XCTAssertTrue(asked && window.contentView === host, self.buttonProbe(in: host))
    let request = try XCTUnwrap(self.hostedButton(labeled: "Reprocess All Tracks…", in: host))
    XCTAssertTrue(request.isDescendant(of: host))
    request.performClick(nil)
    let confirmed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      guard let field = self.hostedField(labeled: "Replacement revisions", in: host),
        let confirm = self.hostedButton(labeled: "Reprocess All Tracks", in: host)
      else { return false }
      return field.stringValue.contains(
        "Earlier revisions and their corrections remain in history.")
        && confirm.isEnabled
    }
    XCTAssertTrue(confirmed && window.contentView === host, self.buttonProbe(in: host))
    let stillSelected = try storedRevisions(managedRoot: managedRoot, sessionId: sessionId)
    XCTAssertEqual(stillSelected, before)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let confirm = try XCTUnwrap(self.hostedButton(labeled: "Reprocess All Tracks", in: host))
    XCTAssertTrue(confirm.isDescendant(of: host))
    confirm.performClick(nil)
    var originalMissing = false
    let replaced = await waitUntil(timeoutNanoseconds: 180_000_000_000) {
      host.layoutSubtreeIfNeeded()
      guard let rows = try? self.storedRevisions(managedRoot: managedRoot, sessionId: sessionId)
      else { return false }
      if rows.contains(where: { $0.id == selected.id && $0.text == selected.text }) == false {
        originalMissing = true
      }
      let ids = Set(rows.map(\.id))
      return ids.isSuperset(of: beforeIds) && ids.count > beforeIds.count
        && scheduler.runningSessionId == nil
        && scheduler.queue.isEmpty
    }
    XCTAssertFalse(originalMissing)
    XCTAssertTrue(
      replaced,
      "state=\(String(describing: scheduler.state(for: sessionId))) hold=\(String(describing: scheduler.hold)) message=\(speech.message ?? "") rows=\(String(describing: try? storedRevisions(managedRoot: managedRoot, sessionId: sessionId)))"
    )
    let after = try storedRevisions(managedRoot: managedRoot, sessionId: sessionId)
    let kept = try XCTUnwrap(after.first { $0.id == selected.id })
    XCTAssertEqual(kept.text, selected.text)
    XCTAssertGreaterThan(Set(after.map(\.id)).subtracting(beforeIds).count, 0)
    XCTAssertEqual(try audioFiles(under: managedRoot), mediaBefore)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let library = try NativeTranscriptLibrary.open(managedRoot: managedRoot.path)
    let document = try library.document(sessionId: sessionId)
    XCTAssertFalse(document.isEmpty)
    withExtendedLifetime(scheduler) {}
    withExtendedLifetime(speech) {}
  }

  private func audioFiles(under root: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    let sessions = root.appendingPathComponent("Sessions")
    guard let enumerator = FileManager.default.enumerator(
      at: sessions, includingPropertiesForKeys: [.isRegularFileKey])
    else { return files }
    for case let url as URL in enumerator {
      guard ["m4a", "caf", "wav", "aac"].contains(url.pathExtension.lowercased()) else { continue }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      let base = sessions.standardizedFileURL.path
      let full = url.standardizedFileURL.path
      let prefix = base.hasSuffix("/") ? base : base + "/"
      guard full.hasPrefix(prefix) else { continue }
      files[String(full.dropFirst(prefix.count))] = try Data(contentsOf: url)
    }
    return files
  }

  private struct StoredRevision: Equatable {
    let id: String
    let selected: Bool
    let text: String
  }

  private func storedRevisions(managedRoot: URL, sessionId: String) throws -> [StoredRevision] {
    let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
    guard sessionId.count == 36, sessionId.unicodeScalars.allSatisfy(allowed.contains) else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let database = managedRoot.appendingPathComponent("Library.sqlite3")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
      "-cmd", ".timeout 2000",
      database.path,
      """
      SELECT revisions.id || '|' || \
      EXISTS(SELECT 1 FROM transcript_selections WHERE revision_id = revisions.id) || '|' || \
      ifnull(segments.sequence, -1) || '|' || \
      hex(ifnull(segments.text, ''))
      FROM transcript_revisions AS revisions
      LEFT JOIN transcript_segments AS segments ON segments.revision_id = revisions.id
      WHERE revisions.session_id = '\(sessionId)'
      ORDER BY revisions.created_at_ms, revisions.id, segments.sequence;
      """,
    ]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw NSError(
        domain: "OpenScribeTest", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "revision query failed: \(detail.prefix(400))"])
    }
    var grouped: [String: (selected: Bool, parts: [(Int, String)])] = [:]
    var order: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 4, let sequence = Int(fields[2]), let segment = decodeHex(fields[3])
      else { continue }
      if grouped[fields[0]] == nil { order.append(fields[0]) }
      var entry = grouped[fields[0]] ?? (fields[1] == "1", [])
      entry.selected = fields[1] == "1"
      if sequence >= 0 { entry.parts.append((sequence, segment)) }
      grouped[fields[0]] = entry
    }
    if order.isEmpty, text.isEmpty == false {
      throw NSError(
        domain: "OpenScribeTest", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "unparsed revisions: \(text.prefix(400))"])
    }
    return order.map { id in
      let entry = grouped[id] ?? (false, [])
      let joined = entry.parts.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
      return StoredRevision(id: id, selected: entry.selected, text: joined)
    }
  }

  private func decodeHex(_ hex: String) -> String? {
    guard hex.count.isMultiple(of: 2) else { return nil }
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      data.append(byte)
      index = next
    }
    return String(data: data, encoding: .utf8)
  }

  private func hostedButton(labeled label: String, in root: NSView) -> NSButton? {
    if let button = root as? NSButton, !(button is NSPopUpButton),
      button.accessibilityLabel() == label,
      button.isHidden == false,
      button.isHiddenOrHasHiddenAncestor == false,
      button.frame.width > 1,
      button.frame.height > 1
    {
      return button
    }
    for subview in root.subviews {
      if let found = hostedButton(labeled: label, in: subview) { return found }
    }
    return nil
  }

  private func hostedField(labeled label: String, in root: NSView) -> NSTextField? {
    if let field = root as? NSTextField,
      field.accessibilityLabel() == label,
      field.isHidden == false,
      field.isHiddenOrHasHiddenAncestor == false,
      field.frame.width > 1,
      field.frame.height > 1
    {
      return field
    }
    for subview in root.subviews {
      if let found = hostedField(labeled: label, in: subview) { return found }
    }
    return nil
  }

  private func buttonProbe(in root: NSView) -> String {
    var lines: [String] = []
    func walk(_ view: NSView) {
      if let button = view as? NSButton, !(button is NSPopUpButton) {
        lines.append(
          "button=\(button.accessibilityLabel() ?? button.title) hidden=\(button.isHidden) frame=\(button.frame)"
        )
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return lines.joined(separator: "\n")
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000, _ body: () -> Bool
  ) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if body() { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return body()
  }

  private func provenanceField(in root: NSView) -> NSTextField? {
    if let field = root as? NSTextField, field.accessibilityLabel() == "Model provenance" {
      return field
    }
    for subview in root.subviews {
      if let found = provenanceField(in: subview) { return found }
    }
    return nil
  }
}

/// Refuses every web request. The local journey must not reach `startLoading`.
final class DeniedNetwork: URLProtocol {
  static func reset() { DeniedNetworkLog.shared.reset() }
  static var requests: [String] { DeniedNetworkLog.shared.requests() }

  override class func canInit(with request: URLRequest) -> Bool {
    guard let scheme = request.url?.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    DeniedNetworkLog.shared.append(request.url?.absoluteString ?? "")
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }

  override func stopLoading() {}
}

private final class DeniedNetworkLog: @unchecked Sendable {
  static let shared = DeniedNetworkLog()
  private let lock = NSLock()
  private var seen: [String] = []

  func reset() {
    lock.lock()
    seen = []
    lock.unlock()
  }

  func append(_ url: String) {
    lock.lock()
    seen.append(url)
    lock.unlock()
  }

  func requests() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }
}

/// Answers the catalog URL with a few bytes. The production session is not involved.
final class ShortCatalogDownload: URLProtocol {
  static let body = Data("partial-model".utf8)
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let client else { return }
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: [
        "Content-Type": "application/octet-stream",
        "Content-Length": "\(Self.body.count)",
      ])!
    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client.urlProtocol(self, didLoad: Self.body)
    client.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

/// Coarse native adapter only: no file access, weights, or ASR.
/// Download planning stays on the real native class. This double refuses it.
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
  override func planModelDownload(modelId: String) throws -> NativeModelDownloadPlan {
    throw NativeSpeechError.ModelRejected(reason: "not_regular_file")
  }
  override func finishModelDownload(modelId: String) throws {
    throw NativeSpeechError.ModelRejected(reason: "not_regular_file")
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
