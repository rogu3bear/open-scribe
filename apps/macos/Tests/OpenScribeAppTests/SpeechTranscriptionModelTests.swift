import AppKit
import SwiftUI
import XCTest

@testable import OpenScribeApp

@MainActor
final class SpeechTranscriptionModelTests: XCTestCase {
  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  func testAFreshLibraryListsTheCatalogAndRefusesAWrongFile() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let speech = SpeechTranscriptionModel(managedRoot: root)
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
    let model = try XCTUnwrap(speech.models.first)
    let installed = await speech.install(model, from: URL(fileURLWithPath: modelPath))
    XCTAssertTrue(installed, speech.message ?? "")
    XCTAssertEqual(speech.installedModel?.modelId, "whisper-small.en-q5_1")

    let transcribed = await speech.transcribe(sessionId: session)
    XCTAssertTrue(transcribed, speech.message ?? "")
    XCTAssertFalse(speech.messageIsFailure)
    XCTAssertNil(speech.transcribingSessionId)

    let transcripts = TranscriptLibraryModel(managedRoot: root)
    transcripts.load(sessionId: session)
    XCTAssertEqual(transcripts.availability, .final)
    let text = transcripts.segments.map(\.effectiveText).joined(separator: " ").lowercased()
    XCTAssertTrue(text.contains("recording safe"), text)
    transcripts.search("transcript")
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
    func model(_ id: String, _ languages: [String], installed: Bool) -> NativeSpeechModel {
      NativeSpeechModel(
        modelId: id, profile: "balanced", languages: languages,
        fileName: "ggml-\(id.dropFirst(8)).bin", byteLength: 190_098_681,
        sha256: "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
        downloadOrigin: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861/ggml.bin",
        license: "MIT", engine: "whisper.cpp 1.8.3", installed: installed)
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
            session: session, transcripts: transcripts, speech: speech, canSeek: true,
            onSeek: { _ in })
        )
      )
    }
    views.append(
      (
        "speech-model-sheet",
        AnyView(SpeechModelSheet(speech: SpeechTranscriptionModel(preview: uninstalled)) {})
      ))
    XCTAssertEqual(states[2].1.progressFraction, 0.25)
    XCTAssertEqual(states[2].1.progressText, "Transcribing track 1 of 2…")
    for (name, content) in views {
      let view = content.padding(32).frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor))
      let size = NSHostingView(rootView: view).fittingSize
      XCTAssertLessThanOrEqual(size.width, 601, name)
      XCTAssertGreaterThan(size.height, 80, name)
      guard let directory = ProcessInfo.processInfo.environment["OPEN_SCRIBE_RENDER_DIR"] else {
        continue
      }
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      let image = try XCTUnwrap(renderer.cgImage)
      let png = try XCTUnwrap(
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
  }
}
