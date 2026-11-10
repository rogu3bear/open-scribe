@preconcurrency import AVFoundation
import Darwin
import Foundation
import XCTest

@testable import OpenScribeApp

@MainActor
final class ImportedMediaAuthorityAdapterTests: XCTestCase {
  func testBatchImportsInOrderKeepsAcceptedFilesAndReportsEachFailureWithoutSelecting() async {
    let events = ImportEventRecorder()
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { url in
        events.append("open:\(url.lastPathComponent)")
        return true
      },
      stopSecurityScope: { events.append("close:\($0.lastPathComponent)") },
      importer: { title, _ in
        events.append("import:\(title)")
        if title == "Second" { throw NativeStorageError.InvalidRequest }
        return acceptedEvidence()
      },
      batchPicker: {
        ["First", "Second", "Third"].map { URL(fileURLWithPath: "/tmp/\($0).caf") }
      }
    )

    adapter.chooseAndImport()
    await assertEventually { adapter.phase == .failed && !adapter.hasPendingAudioImports }

    XCTAssertEqual(adapter.importedSessionIds.count, 2)
    XCTAssertNil(
      adapter.importedSessionId, "A batch must not repeatedly change the selected document")
    XCTAssertEqual(adapter.failedImports.map(\.fileName), ["Second.caf"])
    XCTAssertEqual(
      events.snapshot(),
      [
        "open:First.caf", "import:First", "close:First.caf",
        "open:Second.caf", "import:Second", "close:Second.caf",
        "open:Third.caf", "import:Third", "close:Third.caf",
      ])
  }

  func testStoppingABatchDuringImportRetainsCommittedWorkAndDoesNotStartTheNextFile() async {
    let gate = BlockingImportGate()
    defer { gate.release() }
    let events = ImportEventRecorder()
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: {
        events.append("open:\($0.lastPathComponent)")
        return true
      },
      stopSecurityScope: { events.append("close:\($0.lastPathComponent)") },
      importer: { title, _ in
        events.append("import:\(title)")
        gate.enterAndWait()
        return acceptedEvidence()
      },
      batchPicker: { ["First", "Second"].map { URL(fileURLWithPath: "/tmp/\($0).caf") } }
    )

    adapter.chooseAndImport()
    await assertEventually { gate.hasEntered }
    adapter.cancelImport()
    gate.release()
    await assertEventually { !adapter.hasPendingAudioImports }

    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertEqual(adapter.importedSessionIds, ["imported-session"])
    XCTAssertTrue(adapter.statusMessage?.contains("Stopped after importing 1 of 2") == true)
    XCTAssertEqual(events.snapshot(), ["open:First.caf", "import:First", "close:First.caf"])
  }

  func testBatchPauseClosesTheCurrentScopeAndResumesOnlyOnRequest() async {
    let gate = BlockingImportGate()
    defer { gate.release() }
    let events = ImportEventRecorder()
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: {
        events.append("open:\($0.lastPathComponent)")
        return true
      },
      stopSecurityScope: { events.append("close:\($0.lastPathComponent)") },
      importer: { title, _ in
        events.append("import:\(title)")
        if title == "First" { gate.enterAndWait() }
        return acceptedEvidence()
      },
      batchPicker: { ["First", "Second"].map { URL(fileURLWithPath: "/tmp/\($0).caf") } }
    )

    adapter.chooseAndImport()
    await assertEventually { gate.hasEntered }
    adapter.pauseImports()
    gate.release()
    await assertEventually { adapter.phase == .paused }
    XCTAssertEqual(events.snapshot(), ["open:First.caf", "import:First", "close:First.caf"])
    XCTAssertTrue(adapter.hasPendingAudioImports)
    XCTAssertTrue(adapter.pauseRequested)

    adapter.resumeImports()
    await assertEventually { adapter.phase == .succeeded && !adapter.hasPendingAudioImports }
    XCTAssertEqual(adapter.importedSessionIds.count, 2)
  }

  func testBatchRechecksCaptureAdmissionBetweenFilesAndDoesNotResumeThroughAHold() async {
    let gate = BlockingImportGate()
    defer { gate.release() }
    let admission = BatchImportAdmission()
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true }, stopSecurityScope: { _ in },
      canBeginImport: { admission.allowsImport },
      importer: { title, _ in
        if title == "First" { gate.enterAndWait() }
        return acceptedEvidence()
      },
      batchPicker: { ["First", "Second"].map { URL(fileURLWithPath: "/tmp/\($0).caf") } }
    )

    adapter.chooseAndImport()
    await assertEventually { gate.hasEntered }
    admission.allowsImport = false
    gate.release()
    await assertEventually { adapter.phase == .paused }
    adapter.resumeImports()
    XCTAssertEqual(adapter.phase, .paused)
    XCTAssertEqual(adapter.importedSessionIds.count, 1)

    admission.allowsImport = true
    await assertEventually { adapter.phase == .succeeded && !adapter.hasPendingAudioImports }
    XCTAssertEqual(adapter.importedSessionIds.count, 2)
  }

  func testOversizedM4AIsRejectedBeforeDecodeOrLibraryMutation() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-import-bounds-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("large.m4a")
    _ = FileManager.default.createFile(atPath: source.path, contents: nil)
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: nativeImportPolicy().maximumSourceBytes + 1)
    try handle.close()

    XCTAssertThrowsError(
      try BoundedAudioImport.prepare(sourceURL: source, policy: nativeImportPolicy())
    ) { error in
      XCTAssertEqual(
        error as? BoundedAudioImportError,
        .sourceTooLarge(
          actual: nativeImportPolicy().maximumSourceBytes + 1,
          maximum: nativeImportPolicy().maximumSourceBytes
        )
      )
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
  }

  func testUnsupportedTruncatedAndCorruptImportsAddNoConversation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "open-scribe-import-reject-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let runtime = RuntimeLibraryStore(managedRoot: managedRoot)
    let unsupportedMessage =
      "This file is not supported. Choose a PCM CAF or a single-track AAC or Apple Lossless M4A. Nothing was added."
    let unreadableAudioMessage =
      "This file is not a supported PCM CAF or 48 kHz mono/stereo M4A. Nothing was added."
    var corrupt = Data([0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00])
    corrupt.append(contentsOf: "desc".utf8)
    corrupt.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 32])
    corrupt.append(Data(count: 32))
    let cases: [(String, Data, String)] = [
      ("Meeting.wav", Data("RIFF....WAVE".utf8), unsupportedMessage),
      (
        "Cut Off.caf",
        Data([0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00]),
        unreadableAudioMessage
      ),
      ("Damaged.caf", corrupt, unreadableAudioMessage),
    ]

    for (name, bytes, message) in cases {
      let source = root.appendingPathComponent(name)
      try bytes.write(to: source, options: .atomic)
      let adapter = ImportedMediaAuthorityAdapter(
        picker: { source },
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        importer: runtime.importManagedAudio
      )
      adapter.chooseAndImport()
      await assertEventually { adapter.phase == .failed }
      XCTAssertEqual(adapter.statusMessage, message, name)
      XCTAssertNil(adapter.importedSessionId, name)
      XCTAssertTrue(adapter.importedSessionIds.isEmpty, name)
      XCTAssertEqual(try Data(contentsOf: source), bytes, name)
      let snapshot = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
        .runtimeLibrarySnapshot()
      XCTAssertNil(snapshot.currentSession, name)
      XCTAssertTrue(snapshot.savedSessions.isEmpty, name)
    }
  }

  func testSymlinkedImportAddsNoConversationAndLeavesTheTarget() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "open-scribe-import-symlink-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("Interview.caf")
    let bytes = Data("caff-target".utf8)
    try bytes.write(to: target, options: .atomic)
    let link = root.appendingPathComponent("Linked.caf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let runtime = RuntimeLibraryStore(managedRoot: managedRoot)
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { link },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: runtime.importManagedAudio
    )

    adapter.chooseAndImport()
    await assertEventually { adapter.phase == .failed }

    XCTAssertEqual(
      adapter.statusMessage,
      "The selected audio could not be read safely. Nothing was added."
    )
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertTrue(adapter.importedSessionIds.isEmpty)
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    XCTAssertEqual(
      try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
    let snapshot = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
      .runtimeLibrarySnapshot()
    XCTAssertNil(snapshot.currentSession)
    XCTAssertTrue(snapshot.savedSessions.isEmpty)
  }

  func testCapturePriorityRejectsImportBeforePicker() {
    var picked = false
    let adapter = ImportedMediaAuthorityAdapter(
      picker: {
        picked = true
        return nil
      },
      canBeginImport: { false },
      importer: { _, _ in acceptedEvidence() }
    )
    adapter.chooseAndImport()
    XCTAssertFalse(picked)
    XCTAssertEqual(adapter.phase, .failed)
    XCTAssertTrue(adapter.statusMessage?.contains("Finish the current recording") == true)
  }

  func testMonoM4ARetainsOriginalAcrossReopenExportAndTranscriptionDecode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-import-m4a-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let originalURL = root.appendingPathComponent("Short Voice Memo.m4a")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100.0,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]
    do {
      let file = try AVAudioFile(forWriting: originalURL, settings: settings)
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100)
      )
      let samples = try XCTUnwrap(buffer.floatChannelData?[0])
      buffer.frameLength = 44_100
      for frame in 0..<44_100 {
        samples[frame] = Float(frame % 64) / 128.0
      }
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: originalURL)
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let runtime = RuntimeLibraryStore(managedRoot: managedRoot)
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { originalURL },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: runtime.importManagedAudio
    )
    adapter.chooseAndImport()
    await assertEventually { adapter.phase == .succeeded || adapter.phase == .failed }
    XCTAssertEqual(adapter.phase, .succeeded, adapter.statusMessage ?? "no import status")
    XCTAssertEqual(try Data(contentsOf: originalURL), original)
    await assertEventually { runtime.savedSessions.count == 1 }
    let saved = try XCTUnwrap(runtime.savedSessions.first)
    XCTAssertEqual(saved.playableMedia?.sourceDisplayName, "Short Voice Memo.m4a")
    XCTAssertTrue(saved.playableMedia?.isPlayable == true)
    // Losing access to the selected file cannot lose the original evidence.
    let movedOriginal = root.appendingPathComponent("Moved original.m4a")
    try FileManager.default.moveItem(at: originalURL, to: movedOriginal)
    let controller = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
    let lease = try controller.leaseImportedPlayback(sessionId: saved.sessionId)
    let library = try NativeTranscriptLibrary.open(managedRoot: managedRoot.path)
    XCTAssertEqual(
      try library.audioExportOptions(sessionId: saved.sessionId).originalExtension, "m4a")
    let exported = root.appendingPathComponent("Original export.m4a")
    _ = try library.exportOriginalMedia(sessionId: saved.sessionId, destinationPath: exported.path)
    XCTAssertEqual(try Data(contentsOf: exported), original)
    XCTAssertEqual(try Data(contentsOf: movedOriginal), original)
    let companion = root.appendingPathComponent("transcription.caf")
    try TranscriptionCompanionDecoder.decode(lease: lease, to: companion, isCancelled: { false })
    let decoded = try AVAudioFile(forReading: companion)
    XCTAssertEqual(decoded.fileFormat.sampleRate, 48_000)
    XCTAssertEqual(decoded.fileFormat.channelCount, 1)
    let prepared = try BoundedAudioImport.prepare(
      sourceURL: movedOriginal, policy: nativeImportPolicy())
    defer { prepared.removeTemporaryCopy() }
    XCTAssertEqual(UInt64(decoded.length), prepared.compressed?.sampleCount)
    XCTAssertEqual(prepared.compressed?.original.sampleRateHz, 44_100)
    XCTAssertFalse(runtime.isSnapshotStale)

    let policy = nativeImportPolicy()
    XCTAssertThrowsError(
      try BoundedAudioImport.prepare(
        sourceURL: movedOriginal,
        policy: NativeImportPolicy(
          maximumSourceBytes: policy.maximumSourceBytes,
          maximumManagedBytes: policy.maximumManagedBytes,
          maximumDurationNanoseconds: 1,
          maximumManagedSamples: policy.maximumManagedSamples
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? BoundedAudioImportError,
        .durationTooLong(maximumNanoseconds: 1)
      )
    }
    // The managed source remains compressed; a small PCM budget cannot force
    // the import to discard its original in favor of a normalized file.
    let compressed = try BoundedAudioImport.prepare(
      sourceURL: movedOriginal,
      policy: NativeImportPolicy(
        maximumSourceBytes: policy.maximumSourceBytes,
        maximumManagedBytes: 8_192,
        maximumDurationNanoseconds: policy.maximumDurationNanoseconds,
        maximumManagedSamples: policy.maximumManagedSamples
      )
    )
    defer { compressed.removeTemporaryCopy() }
    XCTAssertNotNil(compressed.compressed)
    XCTAssertEqual(try Data(contentsOf: compressed.cafURL), original)
  }

  func testPortablePackagesNeedTheirExtensionIdleCaptureAndVerification() async {
    let opener = PackageOpenerStub()
    var selection = URL(fileURLWithPath: "/tmp/Call.zip")
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      canBeginImport: { !opener.isRecording },
      importer: { _, _ in acceptedEvidence() },
      packagePicker: { selection },
      packageOpener: { _ in try opener.open() }
    )
    adapter.chooseAndOpenPackage()
    XCTAssertEqual(adapter.phase, .failed)
    XCTAssertTrue(adapter.statusMessage?.contains("Finish the current recording") == true)

    opener.finishRecording()
    adapter.chooseAndOpenPackage()
    XCTAssertEqual(adapter.phase, .failed)
    XCTAssertTrue(adapter.statusMessage?.contains("ends in .openscribe") == true)
    XCTAssertEqual(opener.count, 0)

    selection = URL(fileURLWithPath: "/tmp/Call.openscribe", isDirectory: true)
    adapter.chooseAndOpenPackage()
    await assertEventually { adapter.phase == .failed }
    XCTAssertEqual(opener.count, 1)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertTrue(adapter.statusMessage?.contains("did not verify") == true)

    opener.fail(with: NativeStorageError.InvalidRequest)
    adapter.chooseAndOpenPackage()
    await assertEventually { adapter.phase == .failed && opener.count == 2 }
    XCTAssertTrue(adapter.statusMessage?.contains("do not match its audio") == true)
    XCTAssertEqual(
      ImportedMediaAuthorityAdapter.packageSuccessMessage(
        NativePackageImportReceipt(
          sessionId: "restored", sourceSessionId: "source", title: "Planning",
          mediaFiles: 3, transcriptTracks: 1, markers: 2)),
      "Opened Planning from a portable package with 3 audio files and a transcript. It is a separate conversation on this Mac."
    )
  }

  func testSizeFailureExplainsPolicyWithoutAddingASession() async {
    let maximum = nativeImportPolicy().maximumSourceBytes
    let actual = maximum + (512 * 1_048_576)
    let expectedActualMiB = String(format: "%.1f", Double(actual) / 1_048_576) + " MiB"
    let expectedLimitMiB = "\(maximum / 1_048_576) MiB"
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { URL(fileURLWithPath: "/tmp/large.m4a") },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: { _, _ in
        throw BoundedAudioImportError.sourceTooLarge(
          actual: actual,
          maximum: maximum
        )
      }
    )
    adapter.chooseAndImport()
    await assertEventually { adapter.phase == .failed }
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertTrue(adapter.statusMessage?.contains(expectedActualMiB) == true)
    XCTAssertTrue(adapter.statusMessage?.contains(expectedLimitMiB) == true)
    XCTAssertTrue(adapter.statusMessage?.contains("Nothing was added") == true)
  }

  func testStereoLosslessM4AKeepsCompressedBytesAndDecodesAfterReopeningLibrary() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-stereo-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Stereo memo.m4a")
    do {
      let file = try AVAudioFile(
        forWriting: source,
        settings: [
          AVFormatIDKey: kAudioFormatAppleLossless,
          AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 2,
          AVEncoderBitDepthHintKey: 16,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let channels = try XCTUnwrap(buffer.floatChannelData)
      for frame in 0..<48_000 {
        channels[0][frame] = 0.25
        channels[1][frame] = -0.125
      }
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: source)
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let runtime = RuntimeLibraryStore(managedRoot: managedRoot)
    let evidence = try runtime.importManagedAudio(title: "Stereo memo", sourceURL: source)
    XCTAssertTrue(evidence.relativePath.hasSuffix(".m4a"))
    XCTAssertEqual(evidence.byteLength, UInt64(original.count))
    XCTAssertEqual(try Data(contentsOf: source), original)
    let reopened = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
    let saved = try XCTUnwrap(try reopened.runtimeLibrarySnapshot().savedSessions.first)
    XCTAssertEqual(saved.playableMedia?.availability, "available")
    let lease = try reopened.leaseImportedPlayback(sessionId: evidence.sessionId)
    XCTAssertTrue(lease.playbackPath().hasPrefix("v3;"))
    let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: lease.playbackPath())
    let bytes = try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt)
    let decoder = try CallbackCAFDecoder(
      source: bytes, fileTypeHint: receipt.fileTypeHint, onClose: {})
    defer { decoder.close() }
    let decoded = try XCTUnwrap(decoder.read(maximumFrames: 4_096))
    XCTAssertEqual(decoded.format.channelCount, 2)
    XCTAssertEqual(decoded.floatChannelData?[0][0] ?? 0, 0.25, accuracy: 0.001)
    XCTAssertEqual(decoded.floatChannelData?[1][0] ?? 0, -0.125, accuracy: 0.001)
    XCTAssertLessThanOrEqual(VerifiedDescriptorPlaybackSource.maximumBufferedByteCount, 64 * 1024)
    withExtendedLifetime(lease) {}
  }

  func testRepeatedImportKeepsASeparateConversationAndLeavesTheFirstUnchanged() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "open-scribe-repeated-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Stereo memo.m4a")
    do {
      let file = try AVAudioFile(
        forWriting: source,
        settings: [
          AVFormatIDKey: kAudioFormatAppleLossless,
          AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 2,
          AVEncoderBitDepthHintKey: 16,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let channels = try XCTUnwrap(buffer.floatChannelData)
      for frame in 0..<48_000 {
        channels[0][frame] = 0.25
        channels[1][frame] = -0.125
      }
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: source)
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let runtime = RuntimeLibraryStore(managedRoot: managedRoot)
    let first = try runtime.importManagedAudio(title: "Stereo memo", sourceURL: source)
    XCTAssertFalse(first.repeatedSource)
    XCTAssertNil(runtime.editMessage)
    let second = try runtime.importManagedAudio(title: "Stereo memo again", sourceURL: source)
    XCTAssertTrue(second.repeatedSource)
    XCTAssertNotEqual(first.sessionId, second.sessionId)
    XCTAssertEqual(first.digestSha256, second.digestSha256)
    XCTAssertEqual(try Data(contentsOf: source), original)

    let reopened = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
    let snapshot = try reopened.runtimeLibrarySnapshot()
    XCTAssertEqual(snapshot.savedSessions.count, 2)
    let firstSaved = try XCTUnwrap(
      snapshot.savedSessions.first { $0.sessionId == first.sessionId })
    let secondSaved = try XCTUnwrap(
      snapshot.savedSessions.first { $0.sessionId == second.sessionId })
    XCTAssertEqual(firstSaved.title, "Stereo memo")
    XCTAssertEqual(secondSaved.title, "Stereo memo again")
    XCTAssertEqual(firstSaved.lifecycle, "ready_for_review")
    XCTAssertEqual(secondSaved.lifecycle, "ready_for_review")
    XCTAssertEqual(firstSaved.playableMedia?.availability, "available")
    XCTAssertEqual(secondSaved.playableMedia?.availability, "available")
    for sessionId in [first.sessionId, second.sessionId] {
      let lease = try reopened.leaseImportedPlayback(sessionId: sessionId)
      let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: lease.playbackPath())
      let decoder = try CallbackCAFDecoder(
        source: try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt),
        fileTypeHint: receipt.fileTypeHint, onClose: {})
      defer { decoder.close() }
      let decoded = try XCTUnwrap(decoder.read(maximumFrames: 4_096))
      XCTAssertEqual(decoded.format.channelCount, 2)
      XCTAssertEqual(decoded.floatChannelData?[0][0] ?? 0, 0.25, accuracy: 0.001)
      XCTAssertEqual(decoded.floatChannelData?[1][0] ?? 0, -0.125, accuracy: 0.001)
      withExtendedLifetime(lease) {}
    }

    await assertEventually {
      runtime.editMessage
        == "This audio is already in the library. Open Scribe saved a separate conversation and left the existing one unchanged."
    }
    XCTAssertFalse(runtime.editMessageIsFailure)
  }

  /// Imported audio seeks inside the compressed media: a position in the
  /// second half decodes the second half's samples.
  func testImportedCompressedAudioSeeksToAPositionInTheMedia() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-imported-seek-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Two halves.m4a")
    do {
      let file = try AVAudioFile(
        forWriting: source,
        settings: [
          AVFormatIDKey: kAudioFormatAppleLossless,
          AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 2,
          AVEncoderBitDepthHintKey: 16,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96_000))
      buffer.frameLength = 96_000
      let channels = try XCTUnwrap(buffer.floatChannelData)
      for frame in 0..<96_000 {
        channels[0][frame] = frame < 48_000 ? 0.25 : -0.5
        channels[1][frame] = channels[0][frame]
      }
      try file.write(from: buffer)
    }
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let evidence = try RuntimeLibraryStore(managedRoot: managedRoot)
      .importManagedAudio(title: "Two halves", sourceURL: source)
    XCTAssertTrue(evidence.relativePath.hasSuffix(".m4a"))
    let lease = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
      .leaseImportedPlayback(sessionId: evidence.sessionId)
    let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: lease.playbackPath())
    let decoder = try CallbackCAFDecoder(
      source: try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt),
      fileTypeHint: receipt.fileTypeHint, onClose: {})
    defer { decoder.close() }
    try decoder.seek(toFrame: 60_000)
    let decoded = try XCTUnwrap(decoder.read(maximumFrames: 1_024))
    XCTAssertEqual(decoded.floatChannelData?[0][0] ?? 0, -0.5, accuracy: 0.001)
    withExtendedLifetime(lease) {}
  }

  func testOperatorSelectedLargeM4AImportsAndDecodesBeginningAndEnd() async throws {
    guard let path = ProcessInfo.processInfo.environment["OPEN_SCRIBE_LARGE_IMPORT_SAMPLE"] else {
      throw XCTSkip(
        "Set OPEN_SCRIBE_LARGE_IMPORT_SAMPLE to qualify an operator-selected local file.")
    }
    let baselineMemory = peakResidentBytes()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-large-import-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = URL(fileURLWithPath: path)
    let (evidence, metadata) = try await StructuredNativeIO.mutation {
      let prepared = try BoundedAudioImport.prepare(sourceURL: source, policy: nativeImportPolicy())
      defer { prepared.removeTemporaryCopy() }
      let metadata = try XCTUnwrap(prepared.compressed)
      let controller = try NativeRecordingPreparation.open(managedRoot: root.path)
      let evidence = try controller.importCompressedM4a(
        title: source.deletingPathExtension().lastPathComponent,
        sourcePath: prepared.cafURL.path,
        metadata: metadata
      )
      return (evidence, metadata)
    }
    XCTAssertGreaterThan(
      evidence.byteLength, ImportedPlaybackMemoryPolicy.maximumSnapshotByteLength)
    XCTAssertEqual(evidence.byteLength, metadata.original.byteLength)
    let controller = try NativeRecordingPreparation.open(managedRoot: root.path)
    let snapshot = try controller.runtimeLibrarySnapshot()
    XCTAssertEqual(snapshot.savedSessions.first?.playableMedia?.availability, "available")
    let lease = try controller.leaseImportedPlayback(sessionId: evidence.sessionId)
    let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: lease.playbackPath())
    let bytes = try await StructuredNativeIO.read {
      try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt)
    }
    let decoder = try CallbackCAFDecoder(
      source: bytes, fileTypeHint: receipt.fileTypeHint, onClose: {})
    defer { decoder.close() }
    XCTAssertEqual(
      try XCTUnwrap(decoder.read(maximumFrames: 4_096)).format.channelCount,
      metadata.original.channelCount)
    try decoder.seek(toFrame: Int64(metadata.sampleCount) - 4_096)
    XCTAssertGreaterThan(try XCTUnwrap(decoder.read(maximumFrames: 4_096)).frameLength, 0)
    let player = RecoveredAudioPlayer(outputMode: .silent)
    try await player.playImported(
      receipt: lease.playbackPath(), retaining: lease, generation: UUID())
    player.stop()
    let memoryGrowth = max(0, peakResidentBytes() - baselineMemory)
    XCTAssertLessThan(
      memoryGrowth, 256 * 1024 * 1024, "Large import must not retain a whole-file snapshot.")
    print(
      "LARGE_IMPORT_GREEN bytes=\(evidence.byteLength) frames=\(metadata.sampleCount) channels=\(metadata.original.channelCount) digest=\(evidence.digestSha256) descriptor_buffer=\(VerifiedDescriptorPlaybackSource.maximumBufferedByteCount) resident_peak_growth=\(memoryGrowth)"
    )
    withExtendedLifetime(lease) {}
  }

  /// An imported file stays unchanged and follows the same untranscribed review
  /// posture as a saved microphone recording. No speech model is installed.
  func testAnImportedFileKeepsTheOriginalAndMatchesAnUntranscribedRecording() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-import-journey-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Two halves.m4a")
    do {
      let file = try AVAudioFile(
        forWriting: source,
        settings: [
          AVFormatIDKey: kAudioFormatAppleLossless,
          AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 2,
          AVEncoderBitDepthHintKey: 16,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96_000))
      buffer.frameLength = 96_000
      let channels = try XCTUnwrap(buffer.floatChannelData)
      for frame in 0..<96_000 {
        channels[0][frame] = frame < 48_000 ? 0.25 : -0.5
        channels[1][frame] = channels[0][frame]
      }
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: source)
    let importRoot = root.appendingPathComponent("Imported", isDirectory: true)
    let evidence = try RuntimeLibraryStore(managedRoot: importRoot)
      .importManagedAudio(title: "Two halves", sourceURL: source)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let importedLibrary = try NativeTranscriptLibrary.open(managedRoot: importRoot.path)
    let imported = TranscriptLibraryModel(library: importedLibrary)
    await imported.load(sessionId: evidence.sessionId)

    XCTAssertEqual(imported.availability, .unavailable)
    XCTAssertEqual(imported.availabilityText, "No transcript yet.")
    XCTAssertEqual(
      imported.availabilityText, TranscriptLibraryModel.text(for: .unavailable))
    XCTAssertEqual(imported.segments, [])
    XCTAssertEqual(
      RuntimeTranscriptPresentation.failureText("model_unavailable"),
      "The speech model is not installed.")
    XCTAssertEqual(
      imported.speakerDiarizationText,
      "Speakers follow the audio source. Voice diarization is unavailable without a calibrated model."
    )
    let importedDecision = try importedLibrary.prepareSpeakerDiarization(
      sessionId: evidence.sessionId)
    XCTAssertEqual(importedDecision.clusteringState, "unavailable")
    XCTAssertEqual(importedDecision.reason, "no calibrated diarization model")
    XCTAssertEqual(importedDecision.algorithmId, "topology-before-clustering-v1")
    XCTAssertEqual(imported.speakers.first?.label, "Unknown speaker")
    XCTAssertEqual(imported.speakers.first?.namedByUser, false)
    let hits = try importedLibrary.search(query: "brook", sessionId: evidence.sessionId, limit: 20)
    XCTAssertTrue(hits.isEmpty)
    XCTAssertNotEqual(
      correctionRefusal(importedLibrary, sessionId: evidence.sessionId), "accepted")

    let importedTrack = try XCTUnwrap(imported.speakers.first?.trackId)
    let renamed = await imported.renameSpeaker(trackId: importedTrack, label: " Dana ")
    XCTAssertTrue(renamed)
    XCTAssertEqual(imported.speakers.first?.label, "Dana")
    let restoredName = await imported.renameSpeaker(trackId: importedTrack, label: nil)
    XCTAssertTrue(restoredName)
    XCTAssertEqual(imported.speakers.first?.label, "Unknown speaker")
    XCTAssertEqual(imported.speakers.first?.namedByUser, false)
    let restored = try importedLibrary.prepareSpeakerDiarization(sessionId: evidence.sessionId)
    XCTAssertEqual(restored.tracks.first?.labelOrigin, "source_default")
    XCTAssertEqual(restored.clusteringState, "unavailable")
    XCTAssertEqual(imported.segments, [])

    let lease = try NativeRecordingPreparation.open(managedRoot: importRoot.path)
      .leaseImportedPlayback(sessionId: evidence.sessionId)
    let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: lease.playbackPath())
    let decoder = try CallbackCAFDecoder(
      source: try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt),
      fileTypeHint: receipt.fileTypeHint, onClose: {})
    defer { decoder.close() }
    let beginning = try XCTUnwrap(decoder.read(maximumFrames: 1))
    XCTAssertEqual(beginning.floatChannelData?[0][0] ?? 0, 0.25, accuracy: 0.001)
    try decoder.seek(toFrame: 60_000)
    let later = try XCTUnwrap(decoder.read(maximumFrames: 1))
    XCTAssertEqual(later.floatChannelData?[0][0] ?? 0, -0.5, accuracy: 0.001)
    withExtendedLifetime(lease) {}

    let exported = root.appendingPathComponent("Exported.m4a")
    let exportedOriginal = await imported.export(.original, to: exported)
    XCTAssertTrue(exportedOriginal, imported.message ?? "")
    let managedCopy = importRoot.appendingPathComponent("Sessions")
      .appendingPathComponent(evidence.sessionId)
      .appendingPathComponent(evidence.relativePath)
    XCTAssertEqual(try Data(contentsOf: exported), try Data(contentsOf: managedCopy))
    let refusedMix = await imported.export(.validatedMix, to: root.appendingPathComponent("Mix.m4a"))
    XCTAssertFalse(refusedMix)
    XCTAssertTrue(imported.messageIsFailure)
    let markdown = root.appendingPathComponent("Imported.md")
    let wroteTranscript = await imported.export(format: .markdown, to: markdown)
    XCTAssertTrue(wroteTranscript, imported.message ?? "")
    XCTAssertFalse(imported.messageIsFailure)
    XCTAssertGreaterThan(try Data(contentsOf: markdown).count, 0)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  private func correctionRefusal(_ library: NativeTranscriptLibrary, sessionId: String) -> String {
    do {
      _ = try library.correctSegment(
        sessionId: sessionId, revisionId: "missing-revision", sequence: 0, text: "changed words")
      return "accepted"
    } catch {
      return String(describing: type(of: error))
    }
  }

  private func peakResidentBytes() -> Int64 {
    var usage = rusage()
    XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
    return Int64(usage.ru_maxrss)
  }

  func testSecurityScopeStaysOpenThroughImportAndClosesAfterSuccess() async {
    let selectedURL = URL(fileURLWithPath: "/tmp/Interview.caf")
    let events = ImportEventRecorder()
    let adapter = ImportedMediaAuthorityAdapter(
      picker: {
        events.append("pick")
        return selectedURL
      },
      startSecurityScope: { url in
        XCTAssertEqual(url, selectedURL)
        events.append("start")
        return true
      },
      stopSecurityScope: { url in
        XCTAssertEqual(url, selectedURL)
        events.append("stop")
      },
      importer: { title, url in
        events.append("import")
        events.recordImport(title: title, url: url)
        return acceptedEvidence()
      }
    )

    adapter.chooseAndImport()
    await assertEventually { adapter.phase == .succeeded }

    XCTAssertEqual(events.snapshot(), ["pick", "start", "import", "stop"])
    XCTAssertEqual(events.importTitle, "Interview")
    XCTAssertEqual(events.importURL, selectedURL)
    XCTAssertEqual(adapter.phase, .succeeded)
    XCTAssertEqual(adapter.importedSessionId, "imported-session")
    XCTAssertEqual(
      adapter.statusMessage,
      "Imported Interview into the local conversation library."
    )
  }

  func testScopeDenialFailsClosedWithoutCallingRustOrStoppingUnopenedScope() {
    let importCalled = ImportFlag()
    var stopCalled = false
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { URL(fileURLWithPath: "/tmp/Denied.caf") },
      startSecurityScope: { _ in false },
      stopSecurityScope: { _ in stopCalled = true },
      importer: { _, _ in
        importCalled.set()
        return acceptedEvidence()
      }
    )

    adapter.chooseAndImport()

    XCTAssertEqual(adapter.phase, .failed)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertFalse(importCalled.value)
    XCTAssertFalse(stopCalled)
    XCTAssertTrue(adapter.statusMessage?.contains("Nothing was added") == true)
  }

  func testRustFailureClosesScopeAndReportsNoLibraryAddition() async {
    var stopCalled = false
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { URL(fileURLWithPath: "/tmp/Unsupported.wav") },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in stopCalled = true },
      importer: { _, _ in throw CocoaError(.fileReadCorruptFile) }
    )

    adapter.chooseAndImport()
    await assertEventually { adapter.phase == .failed }

    XCTAssertTrue(stopCalled)
    XCTAssertEqual(adapter.phase, .failed)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertTrue(adapter.statusMessage?.contains("could not be imported") == true)
    XCTAssertTrue(adapter.statusMessage?.contains("Nothing was added") == true)
  }

  func testStartingAnotherChoiceClearsThePreviousImportedIdentity() async {
    let selectedURL = URL(fileURLWithPath: "/tmp/First.caf")
    var selections: [URL?] = [selectedURL, nil]
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { selections.removeFirst() },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: { _, _ in acceptedEvidence() }
    )

    adapter.chooseAndImport()
    await assertEventually { adapter.phase == .succeeded }
    XCTAssertEqual(adapter.importedSessionId, "imported-session")

    adapter.chooseAndImport()
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertNil(adapter.statusMessage)
  }

  func testTerminalPhaseCannotReenterBeforeSecurityScopeCleanupFinishes() async {
    let selectedURL = URL(fileURLWithPath: "/tmp/Interview.caf")
    var pickerCount = 0
    var stopCount = 0
    var adapter: ImportedMediaAuthorityAdapter!
    adapter = ImportedMediaAuthorityAdapter(
      picker: {
        pickerCount += 1
        return selectedURL
      },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in
        stopCount += 1
        adapter.chooseAndImport()
      },
      importer: { _, _ in acceptedEvidence() }
    )

    adapter.chooseAndImport()
    await assertEventually { adapter.phase == .succeeded }

    XCTAssertEqual(pickerCount, 1)
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(adapter.phase, .succeeded)
    XCTAssertEqual(adapter.importedSessionId, "imported-session")
  }

  func testRuntimeStoreRefreshesTheExistingLibraryAfterAcceptedImport() async throws {
    let fixture = ImportRuntimeFixture()
    let store = RuntimeLibraryStore(
      snapshotProvider: { fixture.snapshot() },
      importProvider: { title, sourcePath in
        fixture.importMedia(title: title, sourcePath: sourcePath)
      },
      startsPolling: false
    )
    XCTAssertTrue(store.savedSessions.isEmpty)

    let evidence = try await StructuredNativeIO.mutation {
      try store.importManagedCaf(
        title: "Customer interview",
        sourceURL: URL(fileURLWithPath: "/tmp/customer.caf")
      )
    }
    await assertEventually { store.savedSessions.count == 1 }

    XCTAssertTrue(evidence.readyForReview)
    XCTAssertEqual(store.savedSessions.map(\.sessionId), ["imported-session"])
    XCTAssertEqual(store.savedSessions.map(\.title), ["Customer interview"])
    XCTAssertEqual(store.savedSessions[0].playableMedia?.sourceDisplayName, "customer.caf")
    XCTAssertEqual(store.savedSessions[0].playableMedia?.durationText, "00:00:01")
    XCTAssertEqual(store.savedSessions[0].statusText, "Ready to play")
    XCTAssertTrue(store.savedSessions[0].playableMedia?.isPlayable == true)
    XCTAssertFalse(store.isSnapshotStale)
  }

  func testAcceptedImportSelectsAfterATransientLibraryProjectionFailure() async {
    let fixture = DelayedImportProjectionFixture()
    let store = RuntimeLibraryStore(
      snapshotProvider: { try fixture.snapshot() },
      importProvider: { title, sourcePath in
        fixture.importMedia(title: title, sourcePath: sourcePath)
      },
      startsPolling: false
    )
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { URL(fileURLWithPath: "/tmp/customer.caf") },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: store.importManagedCaf
    )
    await assertEventually { store.savedSessions.map(\.sessionId) == ["older-session"] }

    adapter.chooseAndImport()
    await assertEventually { adapter.phase == .succeeded && store.isSnapshotStale }

    XCTAssertEqual(adapter.phase, .succeeded)
    XCTAssertEqual(adapter.importedSessionId, "imported-session")
    XCTAssertEqual(store.savedSessions.map(\.sessionId), ["older-session"])
    XCTAssertTrue(store.isSnapshotStale)
    let navigation = MainWorkspaceNavigation()
    navigation.select("older-session")
    navigation.acceptImportedConversation(
      adapter.importedSessionId,
      savedSessionIds: store.savedSessions.map(\.sessionId)
    )
    XCTAssertEqual(navigation.pendingImportedSessionId, "imported-session")
    XCTAssertEqual(navigation.selectedSessionId, "older-session")

    store.refresh()
    await assertEventually { fixture.snapshotFailureCount == 2 }
    navigation.synchronize(
      currentSessionId: store.currentSession?.sessionId,
      savedSessionIds: store.savedSessions.map(\.sessionId),
      preferCurrentSession: false
    )
    XCTAssertEqual(store.savedSessions.map(\.sessionId), ["older-session"])
    XCTAssertTrue(store.isSnapshotStale)
    XCTAssertEqual(navigation.pendingImportedSessionId, "imported-session")
    XCTAssertEqual(navigation.selectedSessionId, "older-session")

    store.refresh()
    await assertEventually {
      store.savedSessions.map(\.sessionId) == ["older-session", "imported-session"]
    }
    navigation.synchronize(
      currentSessionId: store.currentSession?.sessionId,
      savedSessionIds: store.savedSessions.map(\.sessionId),
      preferCurrentSession: false
    )
    XCTAssertEqual(
      store.savedSessions.map(\.sessionId),
      ["older-session", "imported-session"]
    )
    XCTAssertEqual(navigation.selectedSessionId, "imported-session")
    XCTAssertNil(navigation.pendingImportedSessionId)
    XCTAssertFalse(store.isSnapshotStale)
  }

  func testImportWorkerLeavesMainActorResponsiveWhileNativeImportIsBlocked() async {
    let gate = BlockingImportGate()
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { URL(fileURLWithPath: "/tmp/blocked.caf") },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in gate.recordScopeClosed() },
      importer: { _, _ in
        gate.enterAndWait()
        return acceptedEvidence()
      }
    )

    adapter.chooseAndImport()
    let entered = await waitUntil { gate.hasEntered }
    XCTAssertTrue(entered)
    XCTAssertEqual(adapter.phase, .importing)
    XCTAssertFalse(gate.scopeClosed)
    var mainActorHeartbeat = false
    mainActorHeartbeat = true
    XCTAssertTrue(mainActorHeartbeat)

    gate.release()
    await assertEventually { adapter.phase == .succeeded }
    XCTAssertTrue(gate.scopeClosed)
  }

  /// A drop is not an import. Cancel and an unsupported file add nothing.
  func testADropWaitsForConfirmationAndACancelAddsNothing() async {
    let events = ImportEventRecorder()
    var allowScope = false
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in
        if !allowScope {
          XCTFail("a drop must not open the file before confirmation")
        }
        return allowScope
      },
      importer: { _, _ in
        events.append("import")
        return acceptedEvidence()
      }
    )
    let audio = URL(fileURLWithPath: "/tmp/open-scribe-drop-\(UUID().uuidString).caf")
    adapter.stageDroppedAudio([audio])
    XCTAssertEqual(adapter.pendingAudioImport?.urls, [audio])
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertEqual(
      adapter.statusMessage, ImportedMediaAuthorityAdapter.dropConfirmationMessage(urls: [audio]))
    XCTAssertEqual(events.snapshot(), [])

    adapter.cancelPendingAudioImport()
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertEqual(adapter.statusMessage, "Import cancelled. No conversation was added.")
    XCTAssertEqual(events.snapshot(), [])

    adapter.stageDroppedAudio([URL(fileURLWithPath: "/tmp/notes.txt")])
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertEqual(
      adapter.statusMessage,
      "Drop a PCM CAF or an AAC or Apple Lossless M4A file. Nothing was added.")
    XCTAssertEqual(events.snapshot(), [])

    let blockedEvents = ImportEventRecorder()
    let blocked = ImportedMediaAuthorityAdapter(
      canBeginImport: { false },
      importer: { _, _ in
        blockedEvents.append("import")
        return acceptedEvidence()
      }
    )
    blocked.stageDroppedAudio([audio])
    XCTAssertNil(blocked.pendingAudioImport)
    XCTAssertEqual(
      blocked.statusMessage,
      "Finish the current recording before importing audio. Nothing was added.")
    XCTAssertEqual(blockedEvents.snapshot(), [])

    allowScope = true
    adapter.stageDroppedAudio([audio])
    adapter.confirmPendingAudioImport()
    await assertEventually { adapter.phase == .succeeded }
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertEqual(events.snapshot(), ["import"])
    XCTAssertEqual(adapter.importedSessionId, acceptedEvidence().sessionId)
  }

  func testAFileDropProviderKeepsTheAudioURL() async {
    let source = URL(fileURLWithPath: "/tmp/Dropped memo.m4a")
    let provider = NSItemProvider(object: source as NSURL)
    let urls = await ImportedMediaAuthorityAdapter.fileURLs(from: [provider])
    XCTAssertEqual(urls, [source])
  }

  /// The library drop copies a supported file only after confirmation.
  /// No speech model is installed, so the new item is untranscribed.
  func testADroppedAudioFileImportsOnlyAfterConfirmationAndLeavesTheOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Dropped memo.m4a")
    do {
      let file = try AVAudioFile(
        forWriting: source,
        settings: [
          AVFormatIDKey: kAudioFormatAppleLossless,
          AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitDepthHintKey: 16,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let channel = try XCTUnwrap(buffer.floatChannelData?[0])
      for frame in 0..<48_000 {
        channel[frame] = frame < 24_000 ? 0.25 : -0.5
      }
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: source)
    let importRoot = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: false)
    let store = RuntimeLibraryStore(managedRoot: importRoot, refreshesImmediately: false)
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )

    adapter.stageDroppedAudio([source])
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertEqual(adapter.pendingAudioImport?.urls, [source])
    XCTAssertEqual(
      adapter.statusMessage, "Import Dropped memo.m4a? The original file stays where it is.")
    XCTAssertEqual(try Data(contentsOf: source), original)
    let preparation = try NativeRecordingPreparation.open(managedRoot: importRoot.path)
    XCTAssertTrue(try preparation.runtimeLibrarySnapshot().savedSessions.isEmpty)

    adapter.confirmPendingAudioImport()
    await assertEventually { adapter.phase == .succeeded }
    XCTAssertNil(adapter.pendingAudioImport)
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    XCTAssertEqual(
      adapter.statusMessage, "Imported Dropped memo into the local conversation library.")
    XCTAssertEqual(try Data(contentsOf: source), original)

    let library = try NativeTranscriptLibrary.open(managedRoot: importRoot.path)
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: sessionId)
    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertEqual(model.availabilityText, "No transcript yet.")
    XCTAssertEqual(model.segments, [])
    XCTAssertEqual(model.speakers.first?.label, "Unknown speaker")
    XCTAssertEqual(
      model.speakerDiarizationText,
      "Speakers follow the audio source. Voice diarization is unavailable without a calibrated model."
    )
    XCTAssertTrue(try library.search(query: "memo", sessionId: sessionId, limit: 20).isEmpty)
    XCTAssertNotEqual(correctionRefusal(library, sessionId: sessionId), "accepted")
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  /// After confirmation, the dropped file follows the untranscribed playback,
  /// speaker, search, correction, and export journey. No speech model is installed.
  func testAConfirmedDropPlaysRenamesAndExportsWithoutChangingTheOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-journey-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Dropped memo.m4a")
    do {
      let file = try AVAudioFile(
        forWriting: source,
        settings: [
          AVFormatIDKey: kAudioFormatAppleLossless,
          AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitDepthHintKey: 16,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let channel = try XCTUnwrap(buffer.floatChannelData?[0])
      for frame in 0..<48_000 {
        channel[frame] = frame < 24_000 ? 0.25 : -0.5
      }
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: source)
    let importRoot = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: false)
    let store = RuntimeLibraryStore(managedRoot: importRoot, refreshesImmediately: false)
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let preparation = try NativeRecordingPreparation.open(managedRoot: importRoot.path)
    adapter.stageDroppedAudio([source])
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertTrue(try preparation.runtimeLibrarySnapshot().savedSessions.isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), original)

    adapter.confirmPendingAudioImport()
    await assertEventually { adapter.phase == .succeeded }
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let native = try XCTUnwrap(
      try preparation.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let session = RuntimeSessionPresentation(native: native)
    XCTAssertFalse(session.hasCaptureTimeline)
    XCTAssertEqual(session.playableMedia?.isPlayable, true)

    let library = try NativeTranscriptLibrary.open(managedRoot: importRoot.path)
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: sessionId)
    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertEqual(model.availabilityText, "No transcript yet.")
    XCTAssertEqual(model.segments, [])
    XCTAssertEqual(model.speakers.first?.label, "Unknown speaker")
    XCTAssertEqual(model.speakers.first?.namedByUser, false)
    let trackId = try XCTUnwrap(model.speakers.first?.trackId)
    let renamed = await model.renameSpeaker(trackId: trackId, label: " Dana ")
    XCTAssertTrue(renamed, model.message ?? "")
    XCTAssertEqual(model.speakers.first?.label, "Dana")
    let restoredName = await model.renameSpeaker(trackId: trackId, label: nil)
    XCTAssertTrue(restoredName, model.message ?? "")
    XCTAssertEqual(model.speakers.first?.label, "Unknown speaker")
    XCTAssertEqual(model.speakers.first?.namedByUser, false)
    let decision = try library.prepareSpeakerDiarization(sessionId: sessionId)
    XCTAssertEqual(decision.clusteringState, "unavailable")
    XCTAssertEqual(decision.reason, "no calibrated diarization model")
    XCTAssertEqual(decision.tracks.first?.labelOrigin, "source_default")
    XCTAssertTrue(try library.search(query: "memo", sessionId: sessionId, limit: 20).isEmpty)
    XCTAssertNotEqual(correctionRefusal(library, sessionId: sessionId), "accepted")
    XCTAssertEqual(model.segments, [])

    let later: Int64 = 500_000_000
    let player = RecoveredAudioPlayer(outputMode: .silent)
    for start in [Int64(0), later] {
      let lease = try preparation.leaseImportedPlayback(sessionId: sessionId)
      try await player.playImported(
        receipt: lease.playbackPath(), retaining: lease, generation: UUID(),
        startNanoseconds: start)
      player.stop()
      withExtendedLifetime(lease) {}
    }
    let beginningSample: Float
    let laterSample: Float
    do {
      let lease = try preparation.leaseImportedPlayback(sessionId: sessionId)
      let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: lease.playbackPath())
      let decoder = try CallbackCAFDecoder(
        source: try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt),
        fileTypeHint: receipt.fileTypeHint, onClose: {})
      let beginning = try XCTUnwrap(decoder.read(maximumFrames: 1))
      beginningSample = beginning.floatChannelData?[0][0] ?? 0
      try decoder.seek(toFrame: 24_000)
      let secondHalf = try XCTUnwrap(decoder.read(maximumFrames: 1))
      laterSample = secondHalf.floatChannelData?[0][0] ?? 0
      decoder.close()
      withExtendedLifetime(lease) {}
    }
    XCTAssertEqual(beginningSample, 0.25, accuracy: 0.001)
    XCTAssertEqual(laterSample, -0.5, accuracy: 0.001)
    let recorded = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { id in
        try preparation.leaseImportedPlayback(sessionId: id)
      },
      player: recorded)
    controller.play(session, startNanoseconds: later)
    await assertEventually { controller.playingSessionId == session.sessionId }
    XCTAssertNil(controller.errorMessage)
    XCTAssertEqual(recorded.importedStartNanoseconds, later)
    controller.stopPlayback()

    let managedCopy = try XCTUnwrap(importedAudioFile(under: importRoot))
    let exported = root.appendingPathComponent("Exported.m4a")
    let exportedOriginal = await model.export(.original, to: exported)
    XCTAssertTrue(exportedOriginal, model.message ?? "")
    XCTAssertEqual(try Data(contentsOf: exported), try Data(contentsOf: managedCopy))
    let refusedMix = await model.export(.validatedMix, to: root.appendingPathComponent("Mix.m4a"))
    XCTAssertFalse(refusedMix)
    XCTAssertTrue(model.messageIsFailure)
    let markdown = root.appendingPathComponent("Dropped.md")
    let wroteTranscript = await model.export(format: .markdown, to: markdown)
    XCTAssertTrue(wroteTranscript, model.message ?? "")
    XCTAssertFalse(model.messageIsFailure)
    XCTAssertGreaterThan(try Data(contentsOf: markdown).count, 0)
    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertEqual(try Data(contentsOf: source), original)
    withExtendedLifetime(preparation) {}
  }

  /// Confirmation puts the dropped file on the same transcription entry a
  /// recording uses. No speech model is installed, so that entry prepares the
  /// compressed audio and stops without writing a transcript.
  func testAConfirmedDropStopsTranscriptionWithoutASpeechModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-transcribe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Dropped memo.m4a")
    do {
      let file = try AVAudioFile(
        forWriting: source,
        settings: [
          AVFormatIDKey: kAudioFormatAppleLossless,
          AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitDepthHintKey: 16,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let channel = try XCTUnwrap(buffer.floatChannelData?[0])
      for frame in 0..<48_000 {
        channel[frame] = frame < 24_000 ? 0.25 : -0.5
      }
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: source)
    let importRoot = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: false)
    let store = RuntimeLibraryStore(managedRoot: importRoot, refreshesImmediately: false)
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let preparation = try NativeRecordingPreparation.open(managedRoot: importRoot.path)
    adapter.stageDroppedAudio([source])
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertTrue(try preparation.runtimeLibrarySnapshot().savedSessions.isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), original)

    adapter.confirmPendingAudioImport()
    await assertEventually { adapter.phase == .succeeded }
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let native = try XCTUnwrap(
      try preparation.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let session = RuntimeSessionPresentation(native: native)
    XCTAssertNil(session.transcriptionUnavailableReason)
    XCTAssertEqual(session.transcript.state, .none)

    let speech = SpeechTranscriptionModel(managedRoot: importRoot)
    await speech.refreshAndWait()
    XCTAssertEqual(
      speech.models.map(\.modelId), ["whisper-small.en-q5_1", "whisper-small-q5_1"])
    XCTAssertTrue(speech.models.allSatisfy { !$0.installed })
    XCTAssertNil(speech.installedModel)
    let library = try NativeTranscriptLibrary.open(managedRoot: importRoot.path)
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: sessionId)
    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertTrue(
      TranscriptSection.showsInstallSpeechModel(session: session, speech: speech))
    XCTAssertEqual(
      TranscriptSection.statusLine(session: session, transcripts: model, speech: speech),
      TranscriptSection.speechModelUnavailableStatus)
    let speechNative = try NativeSpeechModels.open(managedRoot: importRoot.path)
    XCTAssertTrue(try speechNative.needsDecodedCompanion(sessionId: sessionId))
    XCTAssertTrue(
      try speechNative.needsDecodedCompanionForIntent(
        sessionId: sessionId, intent: .resumeIncomplete))
    let managedCopy = try XCTUnwrap(importedAudioFile(under: importRoot))
    let managedBefore = try Data(contentsOf: managedCopy)

    let transcribed = await speech.transcribe(sessionId: sessionId)
    XCTAssertFalse(transcribed)
    XCTAssertEqual(speech.message, "No verified speech model is installed.")
    XCTAssertFalse(speech.messageIsFailure)
    XCTAssertNil(speech.transcribingSessionId)
    XCTAssertNil(speech.installedModel)
    await model.load(sessionId: sessionId)
    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertEqual(model.availabilityText, "No transcript yet.")
    XCTAssertEqual(model.segments, [])
    let after = try XCTUnwrap(
      try preparation.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let afterSession = RuntimeSessionPresentation(native: after)
    XCTAssertEqual(afterSession.transcript.state, .none)
    XCTAssertNil(afterSession.transcriptionUnavailableReason)
    XCTAssertEqual(
      TranscriptSection.statusLine(session: afterSession, transcripts: model, speech: speech),
      TranscriptSection.speechModelUnavailableStatus)
    XCTAssertEqual(try Data(contentsOf: managedCopy), managedBefore)
    XCTAssertEqual(try Data(contentsOf: source), original)
    withExtendedLifetime(preparation) {}
  }

  /// Confirmation puts the dropped file on the automatic transcription queue
  /// a saved recording uses. No speech model is installed, so that queue waits
  /// and does not start a run.
  func testAConfirmedDropWaitsOnTheAutomaticTranscriptionQueueWithoutASpeechModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-queue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Dropped memo.m4a")
    do {
      let file = try AVAudioFile(
        forWriting: source,
        settings: [
          AVFormatIDKey: kAudioFormatAppleLossless,
          AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitDepthHintKey: 16,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let channel = try XCTUnwrap(buffer.floatChannelData?[0])
      for frame in 0..<48_000 {
        channel[frame] = frame < 24_000 ? 0.25 : -0.5
      }
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: source)
    let importRoot = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: false)
    let recovery = RecoveredSessionController(managedRoot: importRoot)
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    live.isLaunchRecoveryPending = { !recovery.captureSafetyComplete }
    let store = RuntimeLibraryStore(
      managedRoot: importRoot,
      isLaunchRecoveryPending: { !recovery.captureSafetyComplete })
    let speech = SpeechTranscriptionModel(managedRoot: importRoot)
    let pressure = SystemPressureMonitor(libraryRoot: importRoot)
    let defaults = UserDefaults(
      suiteName: "OpenScribe.Proof.DropQueue.\(UUID().uuidString)")!
    let scheduler = TranscriptionScheduler(
      managedRoot: importRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    XCTAssertTrue(live.canStart)
    await speech.refreshAndWait()
    XCTAssertEqual(
      speech.models.map(\.modelId), ["whisper-small.en-q5_1", "whisper-small-q5_1"])
    XCTAssertTrue(speech.models.allSatisfy { !$0.installed && $0.readiness == .absent })
    XCTAssertNil(speech.installedModel)
    XCTAssertEqual(speech.readiness, .absent)
    scheduler.reconsider()
    let idle = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      scheduler.queue.isEmpty && scheduler.runningSessionId == nil && scheduler.hold == nil
    }
    XCTAssertTrue(idle, "queue=\(scheduler.queue) hold=\(String(describing: scheduler.hold))")
    XCTAssertTrue(store.savedSessions.isEmpty)

    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      canBeginImport: { live.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    adapter.stageDroppedAudio([source])
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertEqual(try Data(contentsOf: source), original)
    adapter.confirmPendingAudioImport()
    await assertEventually { adapter.phase == .succeeded }
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let queued = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      scheduler.queue.map(\.sessionId) == [sessionId]
        && scheduler.hold == .noSpeechModel
        && scheduler.runningSessionId == nil
        && speech.transcribingSessionId == nil
    }
    XCTAssertTrue(
      queued,
      "queue=\(scheduler.queue.map(\.sessionId)) hold=\(String(describing: scheduler.hold)) running=\(String(describing: scheduler.runningSessionId))"
    )
    XCTAssertEqual(scheduler.queue.first?.requestedByUser, false)
    XCTAssertTrue(scheduler.canPrioritize(sessionId: sessionId))
    XCTAssertEqual(
      scheduler.summaryText(titles: [sessionId: "Dropped memo"], progress: nil),
      "1 conversation waiting for a transcript. Waiting for a speech model to be installed."
    )
    let saved = try XCTUnwrap(store.savedSessions.first { $0.sessionId == sessionId })
    XCTAssertEqual(saved.transcript.state, .none)
    XCTAssertNil(saved.transcriptionUnavailableReason)
    let library = try NativeTranscriptLibrary.open(managedRoot: importRoot.path)
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: sessionId)
    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertEqual(model.segments, [])
    XCTAssertEqual(
      TranscriptSection.statusLine(session: saved, transcripts: model, speech: speech),
      TranscriptSection.speechModelUnavailableStatus)
    XCTAssertEqual(try Data(contentsOf: source), original)
    withExtendedLifetime(scheduler) {}
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(speech) {}
    withExtendedLifetime(pressure) {}
  }

  /// The same confirmed drop waits with no model, then the automatic queue
  /// transcribes it after the pinned model is installed. The test does not
  /// call `transcribe` itself. Set `OPEN_SCRIBE_WHISPER_MODEL` and
  /// `OPEN_SCRIBE_WHISPER_SPEECH_M4A` (`TEST_RUNNER_` prefix under xcodebuild).
  func testAConfirmedDropTranscribesAfterThePinnedModelIsInstalled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_M4A"]
    else {
      throw XCTSkip(
        "Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_M4A for the queued import.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-queue-words-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Dropped memo.m4a")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: source)
    let original = try Data(contentsOf: source)
    let stagedModel = try Data(contentsOf: URL(fileURLWithPath: modelPath))
    let importRoot = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: false)
    let recovery = RecoveredSessionController(managedRoot: importRoot)
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    live.isLaunchRecoveryPending = { !recovery.captureSafetyComplete }
    let store = RuntimeLibraryStore(
      managedRoot: importRoot,
      isLaunchRecoveryPending: { !recovery.captureSafetyComplete })
    let speech = SpeechTranscriptionModel(managedRoot: importRoot)
    let pressure = SystemPressureMonitor(libraryRoot: importRoot)
    let defaults = UserDefaults(
      suiteName: "OpenScribe.Proof.DropQueueWords.\(UUID().uuidString)")!
    let scheduler = TranscriptionScheduler(
      managedRoot: importRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    await speech.refreshAndWait()
    XCTAssertNil(speech.installedModel)
    XCTAssertEqual(speech.readiness, .absent)
    scheduler.reconsider()
    let idle = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      scheduler.queue.isEmpty && scheduler.runningSessionId == nil && scheduler.hold == nil
    }
    XCTAssertTrue(idle, "queue=\(scheduler.queue) hold=\(String(describing: scheduler.hold))")

    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      canBeginImport: { live.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    adapter.stageDroppedAudio([source])
    adapter.confirmPendingAudioImport()
    await assertEventually { adapter.phase == .succeeded }
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let queued = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      scheduler.queue.map(\.sessionId) == [sessionId]
        && scheduler.hold == .noSpeechModel
        && scheduler.runningSessionId == nil
        && speech.transcribingSessionId == nil
    }
    XCTAssertTrue(
      queued,
      "queue=\(scheduler.queue.map(\.sessionId)) hold=\(String(describing: scheduler.hold))"
    )
    XCTAssertEqual(scheduler.queue.first?.requestedByUser, false)
    let managedCopy = try XCTUnwrap(importedAudioFile(under: importRoot))
    let managedBefore = try Data(contentsOf: managedCopy)

    let record = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await speech.install(record, from: URL(fileURLWithPath: modelPath))
    XCTAssertTrue(installed, speech.message ?? "")
    XCTAssertEqual(speech.installedModel?.modelId, "whisper-small.en-q5_1")
    let finished = await waitUntil(timeoutNanoseconds: 180_000_000_000) {
      if case .finished = scheduler.state(for: sessionId) { return true }
      return false
    }
    XCTAssertTrue(
      finished,
      "state=\(String(describing: scheduler.state(for: sessionId))) hold=\(String(describing: scheduler.hold)) running=\(String(describing: scheduler.runningSessionId)) message=\(speech.message ?? "")"
    )
    XCTAssertNil(scheduler.runningSessionId)
    XCTAssertFalse(scheduler.queue.contains { $0.sessionId == sessionId })
    XCTAssertNil(speech.transcribingSessionId)

    let transcripts = TranscriptLibraryModel(managedRoot: importRoot)
    await transcripts.load(sessionId: sessionId)
    XCTAssertEqual(transcripts.availability, .final)
    let text = transcripts.segments.map(\.effectiveText).joined(separator: " ").lowercased()
    XCTAssertTrue(text.contains("recording safe"), text)
    XCTAssertEqual(try Data(contentsOf: managedCopy), managedBefore)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: modelPath)), stagedModel)
    withExtendedLifetime(scheduler) {}
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(speech) {}
    withExtendedLifetime(pressure) {}
  }

  private func importedAudioFile(under root: URL) throws -> URL? {
    let sessions = root.appendingPathComponent("Sessions")
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessions, includingPropertiesForKeys: [.isRegularFileKey])
    else { return nil }
    for case let url as URL in enumerator {
      guard url.pathExtension == "m4a" else { continue }
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        return url
      }
    }
    return nil
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    _ predicate: () -> Bool
  ) async -> Bool {
    let started = DispatchTime.now().uptimeNanoseconds
    while !predicate() {
      if DispatchTime.now().uptimeNanoseconds - started >= timeoutNanoseconds {
        return false
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
  }

  private func assertEventually(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: () -> Bool
  ) async {
    let observed = await waitUntil(predicate)
    XCTAssertTrue(observed, file: file, line: line)
  }
}

@MainActor
private final class BatchImportAdmission {
  var allowsImport = true
}

private func acceptedEvidence() -> NativeImportedMediaEvidence {
  NativeImportedMediaEvidence(
    sessionId: "imported-session",
    relativePath: "audio/imported/000000-import.caf",
    byteLength: 128,
    sampleCount: 42,
    digestSha256: String(repeating: "a", count: 64),
    journalVersion: 1,
    lastJournalSequence: 5,
    originalUntouched: true,
    readyForReview: true,
    repeatedSource: false
  )
}

private final class ImportRuntimeFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var importedTitle: String?

  func importMedia(title: String, sourcePath: String) -> NativeImportedMediaEvidence {
    lock.withLock {
      XCTAssertEqual(sourcePath, "/tmp/customer.caf")
      importedTitle = title
    }
    return acceptedEvidence()
  }

  func snapshot() -> NativeRuntimeLibrarySnapshot {
    let title = lock.withLock { importedTitle }
    let saved = title.map {
      NativeRuntimeSessionSnapshot(
        sessionId: "imported-session",
        title: $0,
        lifecycle: "ready_for_review",
        health: "healthy",
        elapsedSeconds: 0,
        journalDurable: true,
        mediaFilesOpen: false,
        interruptionReason: nil,
        recovered: false,
        hasCaptureTimeline: false,
        sources: [],
        playableMedia: NativeRuntimePlayableMediaSnapshot(
          sourceDisplayName: "customer.caf",
          availability: "available",
          absolutePath: "/managed/customer.caf",
          durationNanoseconds: 1_000_000_000,
          sampleCount: 48_000,
          byteLength: 96_068
        )
      )
    }
    return NativeRuntimeLibrarySnapshot(
      currentSession: nil, savedSessions: saved.map { [$0] } ?? [])
  }
}

private final class DelayedImportProjectionFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var importedTitle: String?
  private var snapshotFailuresRemaining = 0
  private var observedSnapshotFailures = 0

  var snapshotFailureCount: Int {
    lock.withLock { observedSnapshotFailures }
  }

  func importMedia(title: String, sourcePath: String) -> NativeImportedMediaEvidence {
    lock.withLock {
      XCTAssertEqual(sourcePath, "/tmp/customer.caf")
      importedTitle = title
      snapshotFailuresRemaining = 2
    }
    return acceptedEvidence()
  }

  func snapshot() throws -> NativeRuntimeLibrarySnapshot {
    let projectedTitle: String? = try lock.withLock {
      if snapshotFailuresRemaining > 0 {
        snapshotFailuresRemaining -= 1
        observedSnapshotFailures += 1
        throw CocoaError(.fileReadUnknown)
      }
      return self.importedTitle
    }
    let older = NativeRuntimeSessionSnapshot(
      sessionId: "older-session",
      title: "Older conversation",
      lifecycle: "ready_for_review",
      health: "healthy",
      elapsedSeconds: 60,
      journalDurable: true,
      mediaFilesOpen: false,
      interruptionReason: nil,
      recovered: false,
      hasCaptureTimeline: false,
      sources: [],
      playableMedia: nil
    )
    let imported = projectedTitle.map {
      NativeRuntimeSessionSnapshot(
        sessionId: "imported-session",
        title: $0,
        lifecycle: "ready_for_review",
        health: "healthy",
        elapsedSeconds: 0,
        journalDurable: true,
        mediaFilesOpen: false,
        interruptionReason: nil,
        recovered: false,
        hasCaptureTimeline: false,
        sources: [],
        playableMedia: NativeRuntimePlayableMediaSnapshot(
          sourceDisplayName: "customer.caf",
          availability: "available",
          absolutePath: "/managed/customer.caf",
          durationNanoseconds: 1_000_000_000,
          sampleCount: 48_000,
          byteLength: 96_068
        )
      )
    }
    return NativeRuntimeLibrarySnapshot(
      currentSession: nil,
      savedSessions: [older] + (imported.map { [$0] } ?? [])
    )
  }
}

private final class ImportEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []
  private var recordedTitle: String?
  private var recordedURL: URL?

  func append(_ event: String) {
    lock.withLock { events.append(event) }
  }

  func recordImport(title: String, url: URL) {
    lock.withLock {
      recordedTitle = title
      recordedURL = url
    }
  }

  func snapshot() -> [String] { lock.withLock { events } }
  var importTitle: String? { lock.withLock { recordedTitle } }
  var importURL: URL? { lock.withLock { recordedURL } }
}

private final class ImportFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue = false
  func set() { lock.withLock { storedValue = true } }
  var value: Bool { lock.withLock { storedValue } }
}

private final class BlockingImportGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var entered = false
  private var released = false
  private var didCloseScope = false

  var hasEntered: Bool { condition.withLock { entered } }
  var scopeClosed: Bool { condition.withLock { didCloseScope } }

  func enterAndWait() {
    condition.lock()
    entered = true
    condition.broadcast()
    while !released { condition.wait() }
    condition.unlock()
  }

  func release() {
    condition.withLock {
      released = true
      condition.broadcast()
    }
  }

  func recordScopeClosed() {
    condition.withLock { didCloseScope = true }
  }
}

private final class PackageOpenerStub: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  private var recording = true
  private var failure: Error = NativeStorageError.IntegrityMismatch
  var count: Int { lock.withLock { calls } }
  var isRecording: Bool { lock.withLock { recording } }
  func finishRecording() { lock.withLock { recording = false } }
  func fail(with error: Error) { lock.withLock { failure = error } }
  func open() throws -> NativePackageImportReceipt {
    let error = lock.withLock {
      calls += 1
      return failure
    }
    throw error
  }
}
