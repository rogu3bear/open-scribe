import AVFoundation
import XCTest

@testable import OpenScribeApp

@MainActor
final class ConversationExportTests: XCTestCase {
  /// A saved synthetic two-track capture (microphone mono, system stereo,
  /// 31 seconds each, rotated into 30-second segments) exports every audio
  /// form, a session manifest, and a portable package that verifies.
  func testACapturedConversationExportsAudioManifestAndAVerifiedPackage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let output = root.appendingPathComponent("Exports", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = try TimelineRuntimeProof.capture(root: root)
    _ = try TimelineRuntimeProof.verify(root: root, sessionId: capture.sessionId)
    _ = try ValidatedMixdownBuilder.buildIfNeeded(
      preparation: capture.preparation, sessionId: capture.sessionId, storagePath: root.path)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let model = TranscriptLibraryModel(managedRoot: root)
    model.load(sessionId: capture.sessionId)
    let options = try XCTUnwrap(model.audioOptions)
    XCTAssertTrue(options.hasValidatedMix)
    XCTAssertNil(options.originalExtension, "a capture has no single original file")
    XCTAssertEqual(options.pcmTracks.count, 2)

    let mix = output.appendingPathComponent("Mix.m4a")
    let exportedMix = await model.export(.validatedMix, to: mix)
    XCTAssertTrue(exportedMix, model.message ?? "")
    XCTAssertEqual(try AVAudioFile(forReading: mix).fileFormat.channelCount, 2)

    let wav = output.appendingPathComponent("Mix.wav")
    let exportedWAV = await model.export(.mixWAV, to: wav)
    XCTAssertTrue(exportedWAV, model.message ?? "")
    let lossless = try AVAudioFile(forReading: wav)
    XCTAssertEqual(lossless.fileFormat.channelCount, 2)
    XCTAssertEqual(lossless.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
    XCTAssertGreaterThanOrEqual(lossless.length, 31 * 48_000)

    for track in options.pcmTracks {
      let file = output.appendingPathComponent("\(track).wav")
      let exported = await model.export(.track(track), to: file)
      XCTAssertTrue(exported, model.message ?? "")
      let decoded = try AVAudioFile(forReading: file)
      // Both tracks sit on the session timeline: the later start is padded.
      XCTAssertGreaterThanOrEqual(decoded.length, 31 * 48_000)
    }

    let manifestURL = output.appendingPathComponent("Session.json")
    let exportedManifest = await model.export(.sessionManifest, to: manifestURL)
    XCTAssertTrue(exportedManifest, model.message ?? "")
    let manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    XCTAssertEqual(manifest["schema"] as? String, "https://open-scribe.app/schema/session-manifest/v1")
    XCTAssertEqual((manifest["tracks"] as? [Any])?.count, 2)

    let package = output.appendingPathComponent("Synthetic.openscribe")
    let exportedPackage = await model.export(.portablePackage, to: package)
    XCTAssertTrue(exportedPackage, model.message ?? "")
    let summary = try verifyPortablePackage(packagePath: package.path)
    XCTAssertEqual(summary.sourceSessionId, capture.sessionId)
    // Session manifest, transcript, four source segments, and the verified mix.
    XCTAssertEqual(summary.files, 7)
    XCTAssertFalse(model.messageIsFailure)
    withExtendedLifetime(capture) {}
  }

  func testAnImportedConversationExportsItsOriginalAndRefusesAMix() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Memo.m4a")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    do {
      let file = try AVAudioFile(
        forWriting: source,
        settings: [
          AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      try file.write(from: buffer)
    }
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let evidence = try RuntimeLibraryStore(managedRoot: managedRoot)
      .importManagedAudio(title: "Memo", sourceURL: source)
    let model = TranscriptLibraryModel(managedRoot: managedRoot)
    model.load(sessionId: evidence.sessionId)
    let options = try XCTUnwrap(model.audioOptions)
    XCTAssertEqual(options.originalExtension, "m4a")
    XCTAssertFalse(options.hasValidatedMix)
    XCTAssertTrue(options.pcmTracks.isEmpty, "a compressed import has no PCM track")

    let original = root.appendingPathComponent("Exported.m4a")
    let exported = await model.export(.original, to: original)
    XCTAssertTrue(exported, model.message ?? "")
    XCTAssertEqual(
      try Data(contentsOf: original),
      try Data(contentsOf: managedRoot.appendingPathComponent("Sessions")
        .appendingPathComponent(evidence.sessionId).appendingPathComponent(evidence.relativePath)))

    let refused = await model.export(.validatedMix, to: root.appendingPathComponent("Mix.m4a"))
    XCTAssertFalse(refused)
    XCTAssertTrue(model.messageIsFailure)
  }
}
