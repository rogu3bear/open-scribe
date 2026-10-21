@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Exercises the production import, descriptor decoder and Rust input validator.
/// All audio is generated here; no app, device, model or user library is opened.
@main
struct ImportedAudioRoundTrip {
  static func main() {
    do {
      try run()
    } catch {
      FileHandle.standardError.write(Data("IMPORTED_AUDIO_ROUND_TRIP_RED: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func run() throws {
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("/") else {
      throw Failure(message: "expected a new proof directory and the Rust validator")
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    // mkdir is exclusive, unlike FileManager.createDirectory, which succeeds
    // for an existing directory. Refuse before adding a marker or opening Rust.
    guard directory.path.withCString({ Darwin.mkdir($0, 0o700) }) == 0 else {
      throw Failure(message: "proof directory must be new and exclusively owned")
    }
    try Data("open-scribe-synthetic-codec-proof\n".utf8).write(
      to: directory.appendingPathComponent(".codec-proof"), options: .withoutOverwriting)
    let root = directory.appendingPathComponent("Library", isDirectory: true)
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    try checkFailurePresentation()
    var failures = 0
    for (name, codec, frames, checkFailureTransport) in [
      ("aac-partial-packet", kAudioFormatMPEG4AAC, 48_017, true),
      ("aac-whole-second", kAudioFormatMPEG4AAC, 96_000, false),
      ("alac-partial-packet", kAudioFormatAppleLossless, 48_017, false),
    ] {
      do {
        try roundTrip(
          name: name, codec: codec, frames: frames, directory: directory,
          preparation: preparation, validator: CommandLine.arguments[2], root: root,
          checkFailureTransport: checkFailureTransport)
      } catch {
        failures += 1
        print("CODEC_CASE_RED \(name): \(error)")
      }
    }
    guard failures == 0 else { throw Failure(message: "\(failures) codec cases failed") }
    print("IMPORTED_AUDIO_ROUND_TRIP_GREEN cases=3")
  }

  private static func roundTrip(
    name: String, codec: AudioFormatID, frames: Int, directory: URL,
    preparation: NativeRecordingPreparation, validator: String, root: URL,
    checkFailureTransport: Bool
  ) throws {
    let original = directory.appendingPathComponent("\(name).m4a")
    try synthesize(to: original, codec: codec, frames: frames)
    let originalDigest = try digest(original)
    let prepared = try BoundedAudioImport.prepare(sourceURL: original, policy: nativeImportPolicy())
    defer { prepared.removeTemporaryCopy() }
    guard let metadata = prepared.compressed else {
      throw Failure(message: "stereo input did not retain its compressed original")
    }
    guard metadata.sampleCount == UInt64(frames) else {
      throw Failure(message: "the generated source timeline changed during import")
    }
    let imported = try preparation.importCompressedM4a(
      title: name, sourcePath: prepared.cafURL.path, metadata: metadata)
    let companion = directory.appendingPathComponent("\(name).caf")
    try TranscriptionCompanionDecoder.decode(
      lease: preparation.leaseImportedPlayback(sessionId: imported.sessionId),
      to: companion, isCancelled: { false })
    guard try digest(original) == originalDigest else {
      throw Failure(message: "original source changed")
    }
    if checkFailureTransport {
      // A deferred explicit request remains queued by design. Exercise transport
      // once so it cannot hold admission ahead of the next independent fixture.
      let speech = try NativeSpeechModels.open(managedRoot: root.path)
      let result = speech.transcribeWithIntent(
        modelId: "whisper-small-q5_1", sessionId: imported.sessionId,
        intent: .resumeIncomplete, admission: nil, decodedCompanionPath: companion.path,
        job: NativeTranscriptionJob())
      guard result.outcome == .deferred, case .ModelNotInstalled? = result.failure else {
        throw Failure(message: "typed missing-model result was lost at the native boundary")
      }
      guard SpeechFailurePresentation.text(for: result) == "No verified speech model is installed."
      else { throw Failure(message: "missing-model result was hidden by generic wording") }
    }
    print("CODEC_CASE \(name) source_frames=\(frames) import_frames=\(metadata.sampleCount)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: validator)
    process.arguments = [root.path, imported.sessionId, companion.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw Failure(message: "Rust rejected the production decoder output")
    }
  }

  private static func synthesize(to url: URL, codec: AudioFormatID, frames: Int) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
      let channels = buffer.floatChannelData
    else { throw Failure(message: "synthetic format unavailable") }
    buffer.frameLength = AVAudioFrameCount(frames)
    for frame in 0..<frames {
      channels[0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.1)
      channels[1][frame] = Float(sin(Double(frame) * 2 * .pi * 660 / 48_000) * 0.1)
    }
    let file = try AVAudioFile(
      forWriting: url,
      settings: [AVFormatIDKey: codec, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2],
      commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
  }

  private static func digest(_ url: URL) throws -> SHA256.Digest {
    SHA256.hash(data: try Data(contentsOf: url))
  }

  private static func checkFailurePresentation() throws {
    let failures: [(NativeSpeechError, String)] = [
      (.DecodedAudioFormatRejected, "unsupported format"),
      (.DecodedAudioChannelsMismatch(expected: 2, actual: 1), "number of channels"),
      (.DecodedAudioLengthMismatch(expected: 48_000, actual: 47_999), "length does not match"),
      (.TranscriptionFailed(reason: "transcript_validation"), "transcript could not be assembled"),
      (.EvidenceChanged, "no longer matches"),
    ]
    for (failure, fragment) in failures {
      let result = NativeTranscriptionResult(
        outcome: .failed, summary: nil, reason: "PRIVATE_PATH_CANARY", failure: failure)
      let message = SpeechFailurePresentation.text(for: result)
      guard message.contains(fragment), !message.contains("PRIVATE_PATH_CANARY"),
        !message.contains("nothing was transcribed")
      else { throw Failure(message: "typed failure presentation lost its meaning") }
      let safe = "stage=transcription code=\(SpeechFailurePresentation.diagnostic(failure))"
      guard DiagnosticPrivacy.sanitize(category: "Library", message: safe).message == safe else {
        throw Failure(message: "typed failure diagnostic was redacted")
      }
      let cancelled = NativeTranscriptionResult(
        outcome: .userCancelled, summary: nil, reason: nil, failure: failure)
      guard SpeechFailurePresentation.text(for: cancelled).contains("cancelled") else {
        throw Failure(message: "user cancellation was replaced by a failure")
      }
    }
    let diagnostic = SpeechFailurePresentation.diagnostic(
      .DecodedAudioLengthMismatch(expected: 48_000, actual: 47_999))
    guard diagnostic == "DecodedAudioLengthMismatch expected_frames=48000 actual_frames=47999"
    else {
      throw Failure(message: "frame count diagnostic is incomplete")
    }
    for invalid in ["-1", "PRIVATE_PATH_CANARY", "18446744073709551616", "/private/audio"] {
      let unsafe = "code=DecodedAudioLengthMismatch expected_frames=\(invalid)"
      guard DiagnosticPrivacy.isPrivate(unsafe) else {
        throw Failure(message: "invalid diagnostic value was admitted")
      }
    }
    print("SPEECH_FAILURE_PRESENTATION_GREEN message_cases=11 redaction_cases=9")
  }

  private struct Failure: Error { let message: String }
}
