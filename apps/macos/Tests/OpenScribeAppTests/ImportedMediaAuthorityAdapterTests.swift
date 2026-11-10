@preconcurrency import AVFoundation
import Darwin
import Foundation
import ObjectiveC
import SwiftUI
import XCTest

@_silgen_name("sandbox_init")
fileprivate func openScribeProofSandboxInit(
  _ profile: UnsafePointer<CChar>,
  _ flags: UInt64,
  _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("sandbox_free_error")
fileprivate func openScribeProofSandboxFreeError(_ errorbuf: UnsafeMutablePointer<CChar>?)

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

  /// The same file dropped twice is confirmed from the hosted banner. The
  /// second confirm keeps a separate conversation and shows the existing-source
  /// warning. The test does not call `importManagedAudio` or
  /// `confirmPendingAudioImport`.
  func testHostedRepeatedFinderDropKeepsBothConversations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-finder-repeat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Finder repeat.m4a")
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
    let recovery = RecoveredSessionController(
      recoveryFactory: {
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
          .leaseImportedPlayback(sessionId: sessionId)
      },
      player: RecoveredAudioPlayerFake()
    )
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      canBeginImport: { live.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: TranscriptLibraryModel(managedRoot: importRoot),
      speech: SpeechTranscriptionModel(managedRoot: importRoot),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let warning =
      "This audio is already in the library. Open Scribe saved a separate conversation and left the existing one unchanged."

    func deliverDrop() async throws {
      let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return self.dropDestination(in: host) != nil && self.bannerImportButton(in: host) == nil
      }
      let destination = try XCTUnwrap(self.dropDestination(in: host))
      XCTAssertTrue(ready && window.contentView === host)
      let location = destination.convert(
        NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
      let drag = FinderFileDrag(fileURL: source, window: window, location: location)
      defer { drag.draggingPasteboard.releaseGlobally() }
      XCTAssertTrue(drag.wroteFileURL)
      XCTAssertFalse(drag.didEnumerateItems)
      let entered = destinationDragOperation("draggingEntered:", on: destination, info: drag)
      let updated = destinationDragOperation("draggingUpdated:", on: destination, info: drag)
      let prepared = destinationDragAccepted("prepareForDragOperation:", on: destination, info: drag)
      let performed = destinationDragAccepted("performDragOperation:", on: destination, info: drag)
      destinationDragEnded("concludeDragOperation:", on: destination, info: drag)
      destinationDragEnded("draggingEnded:", on: destination, info: drag)
      XCTAssertFalse(drag.didEnumerateItems)
      XCTAssertNotEqual(updated == 0 ? entered : updated, 0)
      XCTAssertTrue(prepared && performed)
      let staged = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return adapter.pendingAudioImport?.urls == [source]
          && self.bannerImportButton(in: host) != nil
      }
      XCTAssertTrue(staged && window.contentView === host, adapter.statusMessage ?? "nil")
      let confirm = try XCTUnwrap(self.bannerImportButton(in: host))
      confirm.performClick(nil)
    }

    try await deliverDrop()
    let firstImported = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return adapter.phase == .succeeded && store.savedSessions.count == 1
        && self.bannerImportButton(in: host) == nil
    }
    XCTAssertTrue(firstImported, "phase=\(adapter.phase) saved=\(store.savedSessions.count)")
    let first = try XCTUnwrap(store.savedSessions.first)
    XCTAssertEqual(first.playableMedia?.isPlayable, true)
    XCTAssertNotEqual(store.editMessage, warning)

    try await deliverDrop()
    let repeated = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return store.savedSessions.count == 2 && store.editMessage == warning
        && self.hostedLabels(in: host).contains { $0.contains(warning) }
    }
    XCTAssertTrue(
      repeated && window.contentView === host,
      "saved=\(store.savedSessions.map(\.sessionId)) edit=\(store.editMessage ?? "nil") labels=\(self.hostedLabels(in: host))"
    )
    XCTAssertFalse(store.editMessageIsFailure)
    let kept = try XCTUnwrap(store.savedSessions.first { $0.sessionId == first.sessionId })
    let added = try XCTUnwrap(store.savedSessions.first { $0.sessionId != first.sessionId })
    XCTAssertEqual(kept.title, first.title)
    XCTAssertEqual(kept.playableMedia?.isPlayable, true)
    XCTAssertEqual(added.playableMedia?.isPlayable, true)
    XCTAssertNotEqual(kept.sessionId, added.sessionId)
    XCTAssertEqual(try Data(contentsOf: source), original)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(window) {}
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

  /// After the automatic queue transcribes a confirmed drop, the same session
  /// plays, accepts a speaker rename and a correction, searches both the
  /// machine text and the correction, and exports them. The test does not call
  /// `transcribe` itself.
  func testATranscribedDropPlaysRenamesSearchesCorrectsAndExports() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_M4A"]
    else {
      throw XCTSkip(
        "Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_M4A for the queued import.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Dropped memo.m4a")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: source)
    let original = try Data(contentsOf: source)
    let modelURL = URL(fileURLWithPath: modelPath)
    let modelBytes = try XCTUnwrap(modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
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
      suiteName: "OpenScribe.Proof.DropReview.\(UUID().uuidString)")!
    let scheduler = TranscriptionScheduler(
      managedRoot: importRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    await speech.refreshAndWait()
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
      scheduler.queue.map(\.sessionId) == [sessionId] && scheduler.hold == .noSpeechModel
        && scheduler.runningSessionId == nil
    }
    XCTAssertTrue(queued, "hold=\(String(describing: scheduler.hold))")
    let managedCopy = try XCTUnwrap(importedAudioFile(under: importRoot))
    let managedBefore = try Data(contentsOf: managedCopy)
    let record = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await speech.install(record, from: modelURL)
    XCTAssertTrue(installed, speech.message ?? "")
    let finished = await waitUntil(timeoutNanoseconds: 180_000_000_000) {
      if case .finished = scheduler.state(for: sessionId) { return true }
      return false
    }
    XCTAssertTrue(
      finished,
      "state=\(String(describing: scheduler.state(for: sessionId))) message=\(speech.message ?? "")"
    )

    let transcripts = TranscriptLibraryModel(managedRoot: importRoot)
    await transcripts.load(sessionId: sessionId)
    XCTAssertEqual(transcripts.availability, .final)
    let machine = try XCTUnwrap(
      transcripts.segments.first {
        $0.effectiveText.localizedCaseInsensitiveContains("recording safe")
      })
    await transcripts.search("recording")
    let hit = try XCTUnwrap(
      transcripts.searchResults.first {
        $0.sessionId == sessionId && $0.effectiveText.localizedCaseInsensitiveContains("recording")
      })
    XCTAssertGreaterThan(hit.endNanoseconds, hit.startNanoseconds)

    let preparation = try NativeRecordingPreparation.open(managedRoot: importRoot.path)
    let saved = try XCTUnwrap(
      try preparation.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let session = RuntimeSessionPresentation(native: saved)
    XCTAssertEqual(session.playableMedia?.isPlayable, true)
    let player = RecoveredAudioPlayer(outputMode: .silent)
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: importRoot.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    playback.play(session, startNanoseconds: hit.startNanoseconds)
    await assertEventually { playback.playingSessionId == sessionId }
    XCTAssertNil(playback.errorMessage)
    playback.stopPlayback()

    let beginning = try sampleImported(preparation: preparation, sessionId: sessionId, frame: 0)
    let later = try sampleImported(preparation: preparation, sessionId: sessionId, frame: 24_000)
    XCTAssertEqual(beginning.count, later.count)
    XCTAssertGreaterThan(beginning.count, 1)
    XCTAssertNotEqual(beginning, later)
    XCTAssertFalse(beginning.allSatisfy { $0 == 0 } && later.allSatisfy { $0 == 0 })

    let renamed = await transcripts.renameSpeaker(trackId: machine.trackId, label: " Dana ")
    XCTAssertTrue(renamed, transcripts.message ?? "")
    let named = try XCTUnwrap(transcripts.segments.first { $0.sequence == machine.sequence })
    XCTAssertEqual(named.speakerLabel, "Dana")
    XCTAssertTrue(named.speakerNamedByUser)
    XCTAssertEqual(named.verbatimText, machine.verbatimText)
    let savedCorrection = await transcripts.correct(named, text: "The recording stays on this Mac.")
    XCTAssertTrue(savedCorrection, transcripts.message ?? "")
    let corrected = try XCTUnwrap(transcripts.segments.first { $0.sequence == machine.sequence })
    XCTAssertEqual(corrected.verbatimText, machine.verbatimText)
    XCTAssertEqual(corrected.effectiveText, "The recording stays on this Mac.")
    XCTAssertTrue(corrected.corrected)
    XCTAssertEqual(corrected.speakerLabel, "Dana")
    await transcripts.search("stays on this Mac")
    XCTAssertTrue(
      transcripts.searchResults.contains {
        $0.sessionId == sessionId
          && $0.effectiveText.localizedCaseInsensitiveContains("stays on this Mac")
      })

    let markdown = root.appendingPathComponent("Dropped.md")
    let wroteMarkdown = await transcripts.export(format: .markdown, to: markdown)
    XCTAssertTrue(wroteMarkdown, transcripts.message ?? "")
    let markdownText = try String(contentsOf: markdown, encoding: .utf8)
    XCTAssertTrue(markdownText.localizedCaseInsensitiveContains("Dana"))
    XCTAssertTrue(markdownText.localizedCaseInsensitiveContains("stays on this Mac"))
    let jsonURL = root.appendingPathComponent("Dropped.json")
    let wroteJSON = await transcripts.export(format: .transcriptJson, to: jsonURL)
    XCTAssertTrue(wroteJSON, transcripts.message ?? "")
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
    let exportedSegments = try XCTUnwrap(document["segments"] as? [[String: Any]])
    let exported = try XCTUnwrap(
      exportedSegments.first {
        ($0["effective_text"] as? String) == "The recording stays on this Mac."
      })
    XCTAssertEqual(exported["verbatim_text"] as? String, machine.verbatimText)
    XCTAssertNotEqual(exported["verbatim_text"] as? String, exported["effective_text"] as? String)
    let exportedAudio = root.appendingPathComponent("Exported.m4a")
    let wroteAudio = await transcripts.export(.original, to: exportedAudio)
    XCTAssertTrue(wroteAudio, transcripts.message ?? "")
    XCTAssertEqual(try Data(contentsOf: exportedAudio), managedBefore)
    XCTAssertEqual(try Data(contentsOf: managedCopy), managedBefore)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, modelBytes)
    withExtendedLifetime(scheduler) {}
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(speech) {}
    withExtendedLifetime(pressure) {}
    withExtendedLifetime(playback) {}
    withExtendedLifetime(player) {}
  }

  /// The library banner's Import button is the shipped confirmation control.
  /// The test presses that control and does not call `confirmPendingAudioImport`.
  func testTheConfirmControlImportsADroppedFileAndLeavesTheOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-confirm-control-\(UUID().uuidString)", isDirectory: true)
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
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    let recovery = RecoveredSessionController(managedRoot: importRoot)
    adapter.stageDroppedAudio([source])
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertNotNil(adapter.pendingAudioImport)
    XCTAssertTrue(store.savedSessions.isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), original)

    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: TranscriptLibraryModel(managedRoot: importRoot),
      speech: SpeechTranscriptionModel(managedRoot: importRoot),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    if #available(macOS 14, *) {
      NSApplication.shared.activate()
    }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return confirmControl(in: host) != nil
    }
    let control = confirmControl(in: host)
    XCTAssertTrue(
      shown && control != nil,
      "key=\(window.isKeyWindow) active=\(NSApp.isActive) proxies=\(focusProxyProbe(in: host))"
    )
    let button = try XCTUnwrap(control)
    let identifiesConfirmButton =
      accessibilityTexts(of: button).contains(confirmControlLabel)
      || (button as? NSView) === leftBannerConfirmProxy(in: host)
    XCTAssertTrue(identifiesConfirmButton)
    pressConfirmControl(button)
    await assertEventually { adapter.phase == .succeeded }
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertNotNil(adapter.importedSessionId)
    XCTAssertEqual(try Data(contentsOf: source), original)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(window) {}
  }

  /// Dropping a supported audio file on the hosted library asks before copying.
  /// The original stays in place, and no conversation is saved yet.
  func testASupportedAudioDropOntoTheHostedLibraryStagesConfirmation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-destination-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Library drop.m4a")
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
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    let recovery = RecoveredSessionController(managedRoot: importRoot)
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertTrue(store.savedSessions.isEmpty)
    XCTAssertNil(adapter.importedSessionId)

    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: TranscriptLibraryModel(managedRoot: importRoot),
      speech: SpeechTranscriptionModel(managedRoot: importRoot),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    if #available(macOS 14, *) {
      NSApplication.shared.activate()
    }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return dropDestination(in: host) != nil
    }
    let destination = try XCTUnwrap(dropDestination(in: host))
    XCTAssertTrue(shown, "class=\(type(of: destination))")
    let location = destination.convert(
      NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
    let drag = AudioFileDrag(fileURL: source, window: window, location: location)
    defer { drag.draggingPasteboard.releaseGlobally() }
    let entered = destinationDragOperation("draggingEntered:", on: destination, info: drag)
    let updated = destinationDragOperation("draggingUpdated:", on: destination, info: drag)
    let prepared = destinationDragAccepted("prepareForDragOperation:", on: destination, info: drag)
    let performed = destinationDragAccepted("performDragOperation:", on: destination, info: drag)
    destinationDragEnded("concludeDragOperation:", on: destination, info: drag)
    destinationDragEnded("draggingEnded:", on: destination, info: drag)
    let operation = updated == 0 ? entered : updated
    XCTAssertNotEqual(
      operation, 0,
      "class=\(type(of: destination)) entered=\(entered) updated=\(updated) prepared=\(prepared) performed=\(performed) types=\(destination.registeredDraggedTypes) classes=\(drag.requestedClasses)"
    )
    XCTAssertTrue(
      prepared && performed,
      "class=\(type(of: destination)) entered=\(entered) updated=\(updated) prepared=\(prepared) performed=\(performed) classes=\(drag.requestedClasses)"
    )
    let staged = await waitUntil {
      adapter.pendingAudioImport?.urls == [source]
    }
    XCTAssertTrue(
      staged,
      "class=\(type(of: destination)) performed=\(performed) classes=\(drag.requestedClasses) phase=\(adapter.phase) message=\(adapter.statusMessage ?? "nil") pending=\(String(describing: adapter.pendingAudioImport?.urls))"
    )
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertTrue(store.savedSessions.isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), original)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(window) {}
    withExtendedLifetime(drag) {}
  }

  /// Cancel on the same hosted banner drops the staged file. The original stays
  /// put and no conversation is saved. The test does not call `stageDroppedAudio`
  /// or `cancelPendingAudioImport`.
  func testAHostedDropCancelledFromTheBannerAddsNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Cancelled drop.m4a")
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
    let events = ImportEventRecorder()
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: { title, url in
        events.append("import")
        return try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    let recovery = RecoveredSessionController(managedRoot: importRoot)
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: TranscriptLibraryModel(managedRoot: importRoot),
      speech: SpeechTranscriptionModel(managedRoot: importRoot),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    if #available(macOS 14, *) {
      NSApplication.shared.activate()
    }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.dropDestination(in: host) != nil
    }
    let destination = try XCTUnwrap(self.dropDestination(in: host))
    XCTAssertTrue(ready && window.contentView === host, "class=\(type(of: destination))")
    let location = destination.convert(
      NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
    let drag = AudioFileDrag(fileURL: source, window: window, location: location)
    defer { drag.draggingPasteboard.releaseGlobally() }
    let entered = destinationDragOperation("draggingEntered:", on: destination, info: drag)
    let updated = destinationDragOperation("draggingUpdated:", on: destination, info: drag)
    let prepared = destinationDragAccepted("prepareForDragOperation:", on: destination, info: drag)
    let performed = destinationDragAccepted("performDragOperation:", on: destination, info: drag)
    destinationDragEnded("concludeDragOperation:", on: destination, info: drag)
    destinationDragEnded("draggingEnded:", on: destination, info: drag)
    let operation = updated == 0 ? entered : updated
    XCTAssertNotEqual(operation, 0)
    XCTAssertTrue(prepared && performed)
    let staged = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return adapter.pendingAudioImport?.urls == [source]
        && self.bannerCancelButton(in: host) != nil
    }
    XCTAssertTrue(
      staged && window.contentView === host,
      self.bannerProbe(in: host).joined(separator: "\n"))
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertTrue(store.savedSessions.isEmpty)
    let cancel = try XCTUnwrap(self.bannerCancelButton(in: host))
    XCTAssertTrue(cancel.isDescendant(of: host))
    cancel.performClick(nil)
    let cleared = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return adapter.pendingAudioImport == nil
        && adapter.phase == .idle
        && adapter.importedSessionId == nil
        && store.savedSessions.isEmpty
        && self.bannerCancelButton(in: host) == nil
        && adapter.statusMessage == "Import cancelled. No conversation was added."
    }
    XCTAssertTrue(cleared && window.contentView === host, adapter.statusMessage ?? "nil")
    XCTAssertEqual(events.snapshot(), [])
    XCTAssertEqual(try Data(contentsOf: source), original)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(window) {}
    withExtendedLifetime(drag) {}
  }

  /// Pressing Record in the empty library starts the shipped recorder. The
  /// test does not call `start`. Both selected sources stay named while
  /// preparation is still short of Recording.
  /// Pressing Portable Package… on an empty library restores a compressed M4A
  /// package through the shipped opener. The test supplies the package URL in
  /// place of the open panel and does not call `chooseAndOpenPackage`.
  func testHostedEmptyLibraryOpensACompressedPortablePackage() async throws {
    let exchange = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-package-open-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: exchange) }
    let source = exchange.appendingPathComponent("Memo.m4a")
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
        channels[0][frame] = 0.2
        channels[1][frame] = -0.1
      }
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: source)
    let sourceLibrary = exchange.appendingPathComponent("Source", isDirectory: true)
    let evidence = try RuntimeLibraryStore(managedRoot: sourceLibrary)
      .importManagedAudio(title: "Memo", sourceURL: source)
    XCTAssertTrue(evidence.relativePath.hasSuffix(".m4a"))
    let sourceModel = TranscriptLibraryModel(managedRoot: sourceLibrary)
    await sourceModel.load(sessionId: evidence.sessionId)
    let package = exchange.appendingPathComponent("Memo.openscribe", isDirectory: true)
    let exported = await sourceModel.export(.portablePackage, to: package)
    XCTAssertTrue(exported, sourceModel.message ?? "package export failed")
    let packageBefore = try packageFileBytes(package)
    XCTAssertFalse(packageBefore.isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), original)

    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    let store = RuntimeLibraryStore(managedRoot: harness.root, refreshesImmediately: false)
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      canBeginImport: { harness.controller.canStart },
      importer: { _, _ in throw CancellationError() },
      packagePicker: { package },
      packageOpener: { try store.openPortablePackage(packageURL: $0) }
    )
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: harness.controller,
      recoveredSessions: RecoveredSessionController(
        recoveryFactory: {
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
        },
        importedPlaybackLeaseProvider: { sessionId in
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
            .leaseImportedPlayback(sessionId: sessionId)
        },
        player: RecoveredAudioPlayerFake()
      ),
      transcripts: TranscriptLibraryModel(managedRoot: harness.root),
      speech: SpeechTranscriptionModel(managedRoot: harness.root),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: harness.root, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let ready = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedActionButton(
        labeled: ConversationControlLabels.portablePackage, in: host) != nil
    }
    let open = self.hostedActionButton(labeled: ConversationControlLabels.portablePackage, in: host)
    XCTAssertTrue(
      ready && open != nil && window.contentView === host,
      self.reviewProbe(in: host))
    let button = try XCTUnwrap(open)
    XCTAssertTrue(button.isDescendant(of: host))
    XCTAssertTrue(button.isEnabled)
    XCTAssertEqual(button.title, ConversationControlLabels.portablePackage)
    XCTAssertEqual(button.accessibilityIdentifier(), "Open portable package")
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertTrue(store.savedSessions.isEmpty)
    XCTAssertEqual(harness.controller.phase, .idle)
    button.performClick(nil)

    let restored = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return adapter.phase == .succeeded && store.savedSessions.count == 1
    }
    XCTAssertTrue(restored, adapter.statusMessage ?? "\(adapter.phase)")
    let saved = try XCTUnwrap(store.savedSessions.first)
    XCTAssertNotEqual(saved.sessionId, evidence.sessionId)
    XCTAssertEqual(adapter.importedSessionId, saved.sessionId)
    XCTAssertTrue(
      adapter.statusMessage?.contains("1 audio file") == true, adapter.statusMessage ?? "")
    XCTAssertTrue(adapter.statusMessage?.contains("Opened") == true, adapter.statusMessage ?? "")
    let library = try NativeTranscriptLibrary.open(managedRoot: harness.root.path)
    let options = try library.audioExportOptions(sessionId: saved.sessionId)
    XCTAssertEqual(options.originalExtension, "m4a")
    XCTAssertTrue(options.pcmTracks.isEmpty)
    let restoredMedia = try XCTUnwrap(importedAudioFile(under: harness.root))
    XCTAssertEqual(try Data(contentsOf: restoredMedia), original)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try packageFileBytes(package), packageBefore)
    XCTAssertEqual(harness.controller.phase, .idle)
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime((store, harness, window, host, sourceModel)) {}
  }

  func testHostedEmptyLibraryRecordStartsPreparationWithBothSources() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    let store = RuntimeLibraryStore(managedRoot: harness.root, refreshesImmediately: false)
    let adapter = ImportedMediaAuthorityAdapter(
      canBeginImport: { harness.controller.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: harness.controller,
      recoveredSessions: RecoveredSessionController(
        recoveryFactory: {
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
        },
        importedPlaybackLeaseProvider: { sessionId in
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
            .leaseImportedPlayback(sessionId: sessionId)
        },
        player: RecoveredAudioPlayerFake()
      ),
      transcripts: TranscriptLibraryModel(managedRoot: harness.root),
      speech: SpeechTranscriptionModel(managedRoot: harness.root),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: harness.root, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.recordConversationButton(in: host) != nil
    }
    let record = try XCTUnwrap(self.recordConversationButton(in: host))
    XCTAssertTrue(ready && window.contentView === host)
    XCTAssertTrue(record.isDescendant(of: host))
    XCTAssertTrue(record.isEnabled)
    XCTAssertEqual(record.title, ConversationControlLabels.record)
    XCTAssertEqual(harness.controller.phase, .idle)
    XCTAssertTrue(harness.controller.canStart)
    XCTAssertEqual(harness.captures.microphones.count, 0)
    XCTAssertEqual(harness.captures.systems.count, 0)
    record.performClick(nil)
    let started = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return harness.controller.phase == .starting
        && harness.captures.microphones.count == 1
        && harness.captures.systems.count == 1
    }
    XCTAssertTrue(started, harness.controller.errorMessage ?? harness.controller.phase.rawValue)
    XCTAssertEqual(harness.controller.statusText, "Starting microphone + system audio…")
    XCTAssertEqual(
      harness.controller.sourceSelectionPresentation.summary, "Microphone + Mac system audio")
    XCTAssertFalse(harness.controller.canStart)
    XCTAssertTrue(harness.controller.canStop)
    let current = try XCTUnwrap(harness.preparation.runtimeLibrarySnapshot().currentSession)
    XCTAssertEqual(current.lifecycle, "preparing")
    let session = RuntimeSessionPresentation(native: current)
    XCTAssertEqual(session.sources.map(\.name), ["Mac microphone", "Mac system audio"])
    XCTAssertEqual(session.sources.map(\.stateText), ["Ready", "Ready"])
    let preparingMenu = MenuBarLabel.presentation(
      session: session,
      snapshotStale: false,
      livePhase: harness.controller.phase,
      liveStatus: harness.controller.statusText)
    XCTAssertFalse(preparingMenu.text.hasPrefix("Recording"))
    XCTAssertFalse(preparingMenu.accessibilityText.hasPrefix("Recording"))
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime(store) {}
    withExtendedLifetime(harness) {}
    withExtendedLifetime(window) {}
  }

  /// Pressing Record in the toolbar starts the shipped recorder. The test does
  /// not call `start` and does not press the empty-library Record button.
  func testHostedToolbarRecordStartsPreparationWithBothSources() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    let store = RuntimeLibraryStore(managedRoot: harness.root, refreshesImmediately: false)
    let adapter = ImportedMediaAuthorityAdapter(
      canBeginImport: { harness.controller.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: harness.controller,
      recoveredSessions: RecoveredSessionController(
        recoveryFactory: {
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
        },
        importedPlaybackLeaseProvider: { sessionId in
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
            .leaseImportedPlayback(sessionId: sessionId)
        },
        player: RecoveredAudioPlayerFake()
      ),
      transcripts: TranscriptLibraryModel(managedRoot: harness.root),
      speech: SpeechTranscriptionModel(managedRoot: harness.root),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: harness.root, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.toolbarRecordButton(in: window) != nil
    }
    let record = try XCTUnwrap(self.toolbarRecordButton(in: window))
    let libraryRecord = self.recordConversationButton(in: host)
    XCTAssertTrue(ready && window.contentView === host)
    XCTAssertTrue(record.isEnabled)
    XCTAssertEqual(record.title, ConversationControlLabels.record)
    XCTAssertEqual(record.accessibilityIdentifier(), "Toolbar record")
    XCTAssertEqual(record.keyEquivalent, "r")
    XCTAssertEqual(record.keyEquivalentModifierMask, [.command, .shift])
    XCTAssertEqual(record.toolTip, "Record microphone + system audio")
    if let libraryRecord {
      XCTAssertFalse(record === libraryRecord)
    }
    XCTAssertEqual(harness.controller.phase, .idle)
    XCTAssertTrue(harness.controller.canStart)
    XCTAssertEqual(harness.captures.microphones.count, 0)
    XCTAssertEqual(harness.captures.systems.count, 0)
    record.performClick(nil)
    let started = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return harness.controller.phase == .starting
        && harness.captures.microphones.count == 1
        && harness.captures.systems.count == 1
    }
    XCTAssertTrue(started, harness.controller.errorMessage ?? harness.controller.phase.rawValue)
    XCTAssertEqual(harness.controller.statusText, "Starting microphone + system audio…")
    XCTAssertEqual(
      harness.controller.sourceSelectionPresentation.summary, "Microphone + Mac system audio")
    XCTAssertFalse(harness.controller.canStart)
    XCTAssertTrue(harness.controller.canStop)
    let current = try XCTUnwrap(harness.preparation.runtimeLibrarySnapshot().currentSession)
    XCTAssertEqual(current.lifecycle, "preparing")
    let session = RuntimeSessionPresentation(native: current)
    XCTAssertEqual(session.sources.map(\.name), ["Mac microphone", "Mac system audio"])
    XCTAssertEqual(session.sources.map(\.stateText), ["Ready", "Ready"])
    let preparingMenu = MenuBarLabel.presentation(
      session: session,
      snapshotStale: false,
      livePhase: harness.controller.phase,
      liveStatus: harness.controller.statusText)
    XCTAssertFalse(preparingMenu.text.hasPrefix("Recording"))
    XCTAssertFalse(preparingMenu.accessibilityText.hasPrefix("Recording"))
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime(store) {}
    withExtendedLifetime(harness) {}
    withExtendedLifetime(window) {}
  }

  /// Pressing Stop and Save in the toolbar seals both sources into one saved
  /// conversation. The test clicks Record, delivers one durable sample on each
  /// source, then clicks Stop. It does not call `start` or `stop`.
  func testHostedToolbarStopSavesBothSourcesAsOneConversation() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    let store = RuntimeLibraryStore(managedRoot: harness.root, refreshesImmediately: false)
    let adapter = ImportedMediaAuthorityAdapter(
      canBeginImport: { harness.controller.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: harness.controller,
      recoveredSessions: RecoveredSessionController(
        recoveryFactory: {
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
        },
        importedPlaybackLeaseProvider: { sessionId in
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
            .leaseImportedPlayback(sessionId: sessionId)
        },
        player: RecoveredAudioPlayerFake()
      ),
      transcripts: TranscriptLibraryModel(managedRoot: harness.root),
      speech: SpeechTranscriptionModel(managedRoot: harness.root),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: harness.root, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.toolbarRecordButton(in: window) != nil
    }
    let record = try XCTUnwrap(self.toolbarRecordButton(in: window))
    XCTAssertTrue(ready && window.contentView === host)
    XCTAssertEqual(harness.controller.phase, .idle)
    record.performClick(nil)
    let started = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return harness.controller.phase == .starting
        && harness.captures.microphones.last?.didStart == true
        && harness.captures.systems.last?.didStart == true
    }
    XCTAssertTrue(started, harness.controller.errorMessage ?? harness.controller.phase.rawValue)
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let sessionId = microphone.writer.authorization.sessionId
    try microphone.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    let capturing = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return harness.controller.phase == .capturing
    }
    guard capturing else {
      XCTFail(
        "phase=\(harness.controller.phase.rawValue) code=\(harness.controller.failureCode ?? "none") message=\(harness.controller.errorMessage ?? "none")"
      )
      return
    }
    harness.clock.advance(seconds: 1)
    let current = try XCTUnwrap(harness.preparation.runtimeLibrarySnapshot().currentSession)
    XCTAssertEqual(current.lifecycle, "recording")
    let recording = RuntimeSessionPresentation(native: current)
    XCTAssertEqual(recording.sources.map(\.name), ["Mac microphone", "Mac system audio"])
    XCTAssertEqual(recording.sources.map(\.stateText), ["Capturing", "Capturing"])
    let recordingMenu = MenuBarLabel.presentation(
      session: recording,
      snapshotStale: false,
      livePhase: harness.controller.phase,
      liveStatus: harness.controller.statusText)
    XCTAssertTrue(recordingMenu.text.hasPrefix("Recording"))
    let stopReady = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.toolbarStopButton(in: window) != nil
    }
    let stop = try XCTUnwrap(self.toolbarStopButton(in: window))
    XCTAssertTrue(stopReady)
    XCTAssertTrue(stop.isEnabled)
    XCTAssertEqual(stop.title, ConversationControlLabels.stopAndSave)
    XCTAssertEqual(stop.accessibilityIdentifier(), "Toolbar stop")
    XCTAssertEqual(stop.keyEquivalent, "s")
    XCTAssertEqual(stop.keyEquivalentModifierMask, [.command, .shift])
    XCTAssertNil(self.toolbarRecordButton(in: window))
    stop.performClick(nil)
    let saved = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return harness.controller.phase == .saved
        && store.savedSessions.contains { $0.sessionId == sessionId }
    }
    XCTAssertTrue(saved, harness.controller.errorMessage ?? harness.controller.phase.rawValue)
    XCTAssertNil(harness.controller.errorMessage)
    XCTAssertEqual(microphone.stopCount, 1)
    XCTAssertEqual(system.stopCount, 1)
    XCTAssertTrue(harness.controller.canStart)
    XCTAssertFalse(harness.controller.canStop)
    XCTAssertNil(store.currentSession)
    let conversation = try XCTUnwrap(store.savedSessions.first { $0.sessionId == sessionId })
    XCTAssertEqual(store.savedSessions.count, 1)
    XCTAssertEqual(conversation.lifecycle, "ready_for_review")
    XCTAssertEqual(conversation.sources.map(\.name), ["Mac microphone", "Mac system audio"])
    XCTAssertEqual(conversation.sources.map(\.stateText), ["Saved", "Saved"])
    XCTAssertGreaterThan(conversation.elapsedSeconds, 0)
    XCTAssertEqual(conversation.transcript.state, .none)
    let detail = try harness.preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "ready_for_review")
    _ = try harness.preparation.recoverPlayableSessions()
    let plan = try harness.preparation.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(Set(plan.map(\.trackId)).count, 2)
    XCTAssertEqual(plan.count, 2)
    for segment in plan {
      XCTAssertEqual(segment.sampleCount, 48_000)
    }
    let savedMenu = MenuBarLabel.presentation(
      session: conversation,
      snapshotStale: false,
      livePhase: harness.controller.phase,
      liveStatus: harness.controller.statusText)
    XCTAssertFalse(savedMenu.text.hasPrefix("Recording"))
    let recordReturns = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.toolbarRecordButton(in: window) != nil
        && self.toolbarStopButton(in: window) == nil
    }
    XCTAssertTrue(recordReturns)
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime(store) {}
    withExtendedLifetime(harness) {}
    withExtendedLifetime(window) {}
  }

  /// One durable source is not Recording. Pressing the toolbar Stop control
  /// leaves that written audio in place and does not seal a saved conversation.
  /// The test does not call `start` or `stop`.
  func testHostedDelayedSourceStopKeepsTheWrittenSampleAndDoesNotClaimRecording() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    let store = RuntimeLibraryStore(managedRoot: harness.root, refreshesImmediately: false)
    let adapter = ImportedMediaAuthorityAdapter(
      canBeginImport: { harness.controller.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: harness.controller,
      recoveredSessions: RecoveredSessionController(
        recoveryFactory: {
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
        },
        importedPlaybackLeaseProvider: { sessionId in
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
            .leaseImportedPlayback(sessionId: sessionId)
        },
        player: RecoveredAudioPlayerFake()
      ),
      transcripts: TranscriptLibraryModel(managedRoot: harness.root),
      speech: SpeechTranscriptionModel(managedRoot: harness.root),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: harness.root, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.toolbarRecordButton(in: window) != nil
    }
    let record = try XCTUnwrap(self.toolbarRecordButton(in: window))
    XCTAssertTrue(ready && window.contentView === host)
    record.performClick(nil)
    let started = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return harness.controller.phase == .starting
        && harness.captures.microphones.last?.didStart == true
        && harness.captures.systems.last?.didStart == true
    }
    XCTAssertTrue(started, harness.controller.errorMessage ?? harness.controller.phase.rawValue)
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    try microphone.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    let oneSource = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      guard harness.controller.phase == .starting,
        let current = try? harness.preparation.runtimeLibrarySnapshot().currentSession
      else { return false }
      let session = RuntimeSessionPresentation(native: current)
      let microphoneState = session.sources.first { $0.name == "Mac microphone" }?.lifecycle
      let systemState = session.sources.first { $0.name == "Mac system audio" }?.lifecycle
      return session.lifecycle == "preparing" && microphoneState == "capturing"
        && systemState == "open" && session.isRecording == false
    }
    guard oneSource else {
      let current = try? harness.preparation.runtimeLibrarySnapshot().currentSession
      XCTFail(
        "phase=\(harness.controller.phase.rawValue) code=\(harness.controller.failureCode ?? "none") message=\(harness.controller.errorMessage ?? "none") lifecycle=\(current?.lifecycle ?? "none")"
      )
      return
    }
    let microphoneURL = URL(fileURLWithPath: microphone.writer.authorization.absolutePath)
    let systemURL = URL(fileURLWithPath: system.writer.authorization.absolutePath)
    let microphoneBytes = try Data(contentsOf: microphoneURL)
    let systemBytes = try Data(contentsOf: systemURL)
    XCTAssertGreaterThan(microphoneBytes.count, systemBytes.count)
    let current = try XCTUnwrap(harness.preparation.runtimeLibrarySnapshot().currentSession)
    let waiting = RuntimeSessionPresentation(native: current)
    let waitingMenu = MenuBarLabel.presentation(
      session: waiting,
      snapshotStale: false,
      livePhase: harness.controller.phase,
      liveStatus: harness.controller.statusText)
    XCTAssertFalse(waitingMenu.text.hasPrefix("Recording"))
    XCTAssertFalse(waiting.isRecording)
    let stopReady = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.toolbarStopButton(in: window) != nil
        && self.toolbarRecordButton(in: window) == nil
    }
    let stop = try XCTUnwrap(self.toolbarStopButton(in: window))
    XCTAssertTrue(stopReady)
    XCTAssertEqual(stop.title, ConversationControlLabels.stopAndSave)
    XCTAssertEqual(stop.accessibilityIdentifier(), "Toolbar stop")
    stop.performClick(nil)
    let interrupted = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return harness.controller.phase == .failed
        && store.currentSession?.lifecycle == "interrupted"
        && self.toolbarStopButton(in: window) == nil
        && self.toolbarRecordButton(in: window) != nil
    }
    XCTAssertTrue(interrupted, harness.controller.errorMessage ?? harness.controller.phase.rawValue)
    XCTAssertEqual(harness.controller.failureCode, "no-durable-sample")
    XCTAssertEqual(
      harness.controller.errorMessage,
      "A required source produced no durable sample. Recovery state was preserved.")
    XCTAssertEqual(microphone.stopCount, 1)
    XCTAssertEqual(system.stopCount, 1)
    XCTAssertEqual(try Data(contentsOf: microphoneURL), microphoneBytes)
    XCTAssertEqual(try Data(contentsOf: systemURL), systemBytes)
    let conversation = try XCTUnwrap(store.currentSession)
    XCTAssertEqual(conversation.sessionId, microphone.writer.authorization.sessionId)
    XCTAssertEqual(conversation.lifecycle, "interrupted")
    XCTAssertEqual(conversation.interruptionReason, "stop_without_durable_sample")
    XCTAssertEqual(
      conversation.interruptionText, "A required source had no durable final sample.")
    XCTAssertFalse(conversation.isRecording)
    XCTAssertEqual(
      conversation.sources.first { $0.name == "Mac microphone" }?.stateText, "Failed")
    XCTAssertEqual(
      conversation.sources.first { $0.name == "Mac system audio" }?.stateText, "Failed")
    XCTAssertTrue(store.savedSessions.isEmpty)
    XCTAssertNotEqual(conversation.lifecycle, "ready_for_review")
    let interruptedMenu = MenuBarLabel.presentation(
      session: conversation,
      snapshotStale: false,
      livePhase: harness.controller.phase,
      liveStatus: harness.controller.statusText)
    XCTAssertEqual(interruptedMenu.text, "Recording interrupted")
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime(store) {}
    withExtendedLifetime(harness) {}
    withExtendedLifetime(window) {}
  }

  /// Pressing Record in the idle menu starts the shipped recorder. The test
  /// does not call `start`. Both selected sources stay named while preparation
  /// is still short of Recording.
  func testHostedMenuBarRecordStartsPreparationWithBothSources() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    let store = RuntimeLibraryStore(managedRoot: harness.root, refreshesImmediately: false)
    let adapter = ImportedMediaAuthorityAdapter(
      canBeginImport: { harness.controller.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let menu = MenuBarContent(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: harness.controller,
      recoveredSessions: RecoveredSessionController(
        recoveryFactory: {
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
        },
        importedPlaybackLeaseProvider: { sessionId in
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
            .leaseImportedPlayback(sessionId: sessionId)
        },
        player: RecoveredAudioPlayerFake()
      ),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation(),
      scheduler: TranscriptionScheduler.inert(),
      speech: SpeechTranscriptionModel(managedRoot: harness.root)
    )
    let host = NSHostingView(rootView: menu)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let expectedTitle = MenuBarContent.recordTitle(
      lifecycle: nil, summary: harness.controller.sourceSelectionPresentation.summary)
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.menuBarRecordButton(in: host) != nil
    }
    let record = try XCTUnwrap(self.menuBarRecordButton(in: host))
    XCTAssertTrue(ready && window.contentView === host)
    XCTAssertTrue(record.isDescendant(of: host))
    XCTAssertTrue(record.isEnabled)
    XCTAssertEqual(record.title, expectedTitle)
    XCTAssertEqual(record.keyEquivalent, "r")
    XCTAssertEqual(record.keyEquivalentModifierMask, [.command, .shift])
    XCTAssertEqual(harness.controller.phase, .idle)
    XCTAssertTrue(harness.controller.canStart)
    XCTAssertEqual(harness.captures.microphones.count, 0)
    XCTAssertEqual(harness.captures.systems.count, 0)
    record.performClick(nil)
    let started = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return harness.controller.phase == .starting
        && harness.captures.microphones.count == 1
        && harness.captures.systems.count == 1
    }
    XCTAssertTrue(started, harness.controller.errorMessage ?? harness.controller.phase.rawValue)
    XCTAssertEqual(harness.controller.statusText, "Starting microphone + system audio…")
    XCTAssertEqual(
      harness.controller.sourceSelectionPresentation.summary, "Microphone + Mac system audio")
    XCTAssertFalse(harness.controller.canStart)
    XCTAssertTrue(harness.controller.canStop)
    let current = try XCTUnwrap(harness.preparation.runtimeLibrarySnapshot().currentSession)
    XCTAssertEqual(current.lifecycle, "preparing")
    let session = RuntimeSessionPresentation(native: current)
    XCTAssertEqual(session.sources.map(\.name), ["Mac microphone", "Mac system audio"])
    XCTAssertEqual(session.sources.map(\.stateText), ["Ready", "Ready"])
    let preparingMenu = MenuBarLabel.presentation(
      session: session,
      snapshotStale: false,
      livePhase: harness.controller.phase,
      liveStatus: harness.controller.statusText)
    XCTAssertFalse(preparingMenu.text.hasPrefix("Recording"))
    XCTAssertFalse(preparingMenu.accessibilityText.hasPrefix("Recording"))
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime(store) {}
    withExtendedLifetime(menu) {}
    withExtendedLifetime(harness) {}
    withExtendedLifetime(window) {}
  }

  /// Pressing Stop and Save in the menu seals both sources into one saved
  /// conversation. The test clicks the menu Record control, delivers one
  /// durable sample on each source, then clicks Stop. It does not call
  /// `start` or `stop`.
  func testHostedMenuBarStopSavesBothSourcesAsOneConversation() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    let store = RuntimeLibraryStore(managedRoot: harness.root, refreshesImmediately: false)
    let adapter = ImportedMediaAuthorityAdapter(
      canBeginImport: { harness.controller.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let menu = MenuBarContent(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: harness.controller,
      recoveredSessions: RecoveredSessionController(
        recoveryFactory: {
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
        },
        importedPlaybackLeaseProvider: { sessionId in
          try NativeRecordingPreparation.open(managedRoot: harness.root.path)
            .leaseImportedPlayback(sessionId: sessionId)
        },
        player: RecoveredAudioPlayerFake()
      ),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation(),
      scheduler: TranscriptionScheduler.inert(),
      speech: SpeechTranscriptionModel(managedRoot: harness.root)
    )
    let host = NSHostingView(rootView: menu)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.menuBarRecordButton(in: host) != nil
    }
    let record = try XCTUnwrap(self.menuBarRecordButton(in: host))
    XCTAssertTrue(ready && window.contentView === host)
    XCTAssertEqual(harness.controller.phase, .idle)
    record.performClick(nil)
    let started = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return harness.controller.phase == .starting
        && harness.captures.microphones.last?.didStart == true
        && harness.captures.systems.last?.didStart == true
    }
    XCTAssertTrue(started, harness.controller.errorMessage ?? harness.controller.phase.rawValue)
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let sessionId = microphone.writer.authorization.sessionId
    try microphone.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    let capturing = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return harness.controller.phase == .capturing
    }
    guard capturing else {
      XCTFail(
        "phase=\(harness.controller.phase.rawValue) code=\(harness.controller.failureCode ?? "none") message=\(harness.controller.errorMessage ?? "none")"
      )
      return
    }
    harness.clock.advance(seconds: 1)
    let current = try XCTUnwrap(harness.preparation.runtimeLibrarySnapshot().currentSession)
    XCTAssertEqual(current.lifecycle, "recording")
    let recording = RuntimeSessionPresentation(native: current)
    XCTAssertEqual(recording.sources.map(\.stateText), ["Capturing", "Capturing"])
    let recordingMenu = MenuBarLabel.presentation(
      session: recording,
      snapshotStale: false,
      livePhase: harness.controller.phase,
      liveStatus: harness.controller.statusText)
    XCTAssertTrue(recordingMenu.text.hasPrefix("Recording"))
    let stopReady = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.menuBarStopButton(in: host) != nil
    }
    let stop = try XCTUnwrap(self.menuBarStopButton(in: host))
    XCTAssertTrue(stopReady)
    XCTAssertTrue(stop.isEnabled)
    XCTAssertEqual(stop.title, ConversationControlLabels.stopAndSave)
    XCTAssertEqual(stop.accessibilityIdentifier(), "Menu bar stop")
    XCTAssertEqual(stop.keyEquivalent, "s")
    XCTAssertEqual(stop.keyEquivalentModifierMask, [.command, .shift])
    XCTAssertNil(self.menuBarRecordButton(in: host))
    stop.performClick(nil)
    let saved = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return harness.controller.phase == .saved
        && store.savedSessions.contains { $0.sessionId == sessionId }
    }
    XCTAssertTrue(saved, harness.controller.errorMessage ?? harness.controller.phase.rawValue)
    XCTAssertNil(harness.controller.errorMessage)
    XCTAssertEqual(microphone.stopCount, 1)
    XCTAssertEqual(system.stopCount, 1)
    XCTAssertTrue(harness.controller.canStart)
    XCTAssertFalse(harness.controller.canStop)
    XCTAssertNil(store.currentSession)
    let conversation = try XCTUnwrap(store.savedSessions.first { $0.sessionId == sessionId })
    XCTAssertEqual(store.savedSessions.count, 1)
    XCTAssertEqual(conversation.lifecycle, "ready_for_review")
    XCTAssertEqual(conversation.sources.map(\.name), ["Mac microphone", "Mac system audio"])
    XCTAssertEqual(conversation.sources.map(\.stateText), ["Saved", "Saved"])
    XCTAssertGreaterThan(conversation.elapsedSeconds, 0)
    XCTAssertEqual(conversation.transcript.state, .none)
    let detail = try harness.preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "ready_for_review")
    _ = try harness.preparation.recoverPlayableSessions()
    let plan = try harness.preparation.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(plan.count, 2)
    for segment in plan {
      XCTAssertEqual(segment.sampleCount, 48_000)
    }
    let savedMenu = MenuBarLabel.presentation(
      session: conversation,
      snapshotStale: false,
      livePhase: harness.controller.phase,
      liveStatus: harness.controller.statusText)
    XCTAssertFalse(savedMenu.text.hasPrefix("Recording"))
    let recordReturns = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.menuBarRecordButton(in: host) != nil
        && self.menuBarStopButton(in: host) == nil
    }
    XCTAssertTrue(recordReturns)
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime(store) {}
    withExtendedLifetime(menu) {}
    withExtendedLifetime(harness) {}
    withExtendedLifetime(window) {}
  }

  /// Pressing Audio Files… imports the file the chooser returns. The shipped
  /// default chooser is the open panel. This test supplies one file, presses
  /// the button, and does not call `chooseAndImport` or open the panel.
  func testAHostedAudioFileControlImportsAndLeavesTheOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-open-panel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Opened recording.m4a")
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
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    var pickerCalls = 0
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      canBeginImport: { live.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      },
      batchPicker: {
        pickerCalls += 1
        return [source]
      }
    )
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: RecoveredSessionController(
        recoveryFactory: {
          try NativeRecordingPreparation.open(managedRoot: importRoot.path)
        },
        importedPlaybackLeaseProvider: { sessionId in
          try NativeRecordingPreparation.open(managedRoot: importRoot.path)
            .leaseImportedPlayback(sessionId: sessionId)
        },
        player: RecoveredAudioPlayerFake()
      ),
      transcripts: TranscriptLibraryModel(managedRoot: importRoot),
      speech: SpeechTranscriptionModel(managedRoot: importRoot),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    if #available(macOS 14, *) {
      NSApplication.shared.activate()
    }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let label = ConversationControlLabels.audioFiles
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedActionButton(labeled: label, in: host) != nil
    }
    let choose = try XCTUnwrap(self.hostedActionButton(labeled: label, in: host))
    XCTAssertTrue(ready && window.contentView === host, self.bannerProbe(in: host).joined(separator: "\n"))
    XCTAssertTrue(choose.isDescendant(of: host))
    XCTAssertTrue(choose.isEnabled)
    XCTAssertEqual(pickerCalls, 0)
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertTrue(store.savedSessions.isEmpty)
    XCTAssertNil(self.bannerImportButton(in: host))
    choose.performClick(nil)
    let imported = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let sessionId = adapter.importedSessionId
      return adapter.phase == .succeeded
        && sessionId != nil
        && adapter.pendingAudioImport == nil
        && store.savedSessions.contains { $0.sessionId == sessionId }
        && self.bannerImportButton(in: host) == nil
    }
    XCTAssertTrue(
      imported && window.contentView === host,
      "phase=\(adapter.phase) message=\(adapter.statusMessage ?? "nil") pending=\(String(describing: adapter.pendingAudioImport)) sessions=\(store.savedSessions.map(\.sessionId))"
    )
    XCTAssertEqual(pickerCalls, 1)
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let saved = try XCTUnwrap(store.savedSessions.first { $0.sessionId == sessionId })
    XCTAssertEqual(saved.playableMedia?.isPlayable, true)
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertNil(self.bannerImportButton(in: host))
    XCTAssertEqual(try Data(contentsOf: source), original)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(window) {}
  }

  /// A pasteboard carrying the file URL and filename list Finder writes stages
  /// the audio. Confirming the banner imports it and Play starts that
  /// conversation. The original stays unchanged. The drag supplies no item
  /// provider. The test does not call `stageDroppedAudio`,
  /// `confirmPendingAudioImport`, or `play`.
  func testHostedFinderFileDropConfirmsImportAndLeavesTheOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-finder-drop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Finder drop.m4a")
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
    let player = RecoveredAudioPlayerFake()
    let recovery = RecoveredSessionController(
      recoveryFactory: {
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
          .leaseImportedPlayback(sessionId: sessionId)
      },
      player: player
    )
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      canBeginImport: { live.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: TranscriptLibraryModel(managedRoot: importRoot),
      speech: SpeechTranscriptionModel(managedRoot: importRoot),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.dropDestination(in: host) != nil
    }
    let destination = try XCTUnwrap(self.dropDestination(in: host))
    XCTAssertTrue(ready && window.contentView === host)
    XCTAssertEqual(destination.accessibilityIdentifier(), "Audio drop")
    XCTAssertTrue(destination.registeredDraggedTypes.contains(.fileURL))
    XCTAssertTrue(
      destination.registeredDraggedTypes.contains(
        NSPasteboard.PasteboardType("NSFilenamesPboardType")))
    let location = destination.convert(
      NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
    let drag = FinderFileDrag(fileURL: source, window: window, location: location)
    defer { drag.draggingPasteboard.releaseGlobally() }
    XCTAssertTrue(drag.wroteFileURL)
    XCTAssertTrue(drag.draggingPasteboard.types?.contains(.fileURL) == true)
    XCTAssertEqual(
      drag.draggingPasteboard.propertyList(
        forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
      [source.path])
    let entered = destinationDragOperation("draggingEntered:", on: destination, info: drag)
    let updated = destinationDragOperation("draggingUpdated:", on: destination, info: drag)
    let prepared = destinationDragAccepted("prepareForDragOperation:", on: destination, info: drag)
    let performed = destinationDragAccepted("performDragOperation:", on: destination, info: drag)
    destinationDragEnded("concludeDragOperation:", on: destination, info: drag)
    destinationDragEnded("draggingEnded:", on: destination, info: drag)
    XCTAssertFalse(drag.didEnumerateItems)
    let operation = updated == 0 ? entered : updated
    XCTAssertNotEqual(operation, 0)
    XCTAssertTrue(prepared && performed)
    let staged = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return adapter.pendingAudioImport?.urls == [source]
        && self.bannerImportButton(in: host) != nil
    }
    XCTAssertTrue(staged && window.contentView === host, adapter.statusMessage ?? "nil")
    XCTAssertTrue(store.savedSessions.isEmpty)
    let confirm = try XCTUnwrap(self.bannerImportButton(in: host))
    confirm.performClick(nil)
    let imported = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return adapter.phase == .succeeded
        && adapter.importedSessionId != nil
        && self.playConversationButton(in: host) != nil
    }
    XCTAssertTrue(
      imported,
      "phase=\(adapter.phase) message=\(adapter.statusMessage ?? "nil")"
    )
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let saved = try XCTUnwrap(store.savedSessions.first { $0.sessionId == sessionId })
    XCTAssertEqual(saved.playableMedia?.isPlayable, true)
    let play = try XCTUnwrap(self.playConversationButton(in: host))
    play.performClick(nil)
    let playing = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      return recovery.playingSessionId == sessionId
        && player.importedReceipt?.isEmpty == false
    }
    XCTAssertTrue(playing, recovery.errorMessage ?? "not playing")
    XCTAssertEqual(try Data(contentsOf: source), original)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(window) {}
    withExtendedLifetime(drag) {}
  }

  /// A file dropped on the hosted library imports when that same hosting view's
  /// banner button is pressed, then plays when that same view's Play button is
  /// pressed. The original file stays unchanged. The test does not call
  /// `stageDroppedAudio`, `confirmPendingAudioImport`, or `play`.
  func testAHostedDropConfirmedFromTheBannerPlaysAndLeavesTheOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-play-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Played drop.m4a")
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
    let player = RecoveredAudioPlayerFake()
    let recovery = RecoveredSessionController(
      recoveryFactory: {
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
          .leaseImportedPlayback(sessionId: sessionId)
      },
      player: player
    )
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      canBeginImport: { live.canStart },
      importer: { title, url in
        try store.importManagedAudio(title: title, sourceURL: url)
      }
    )
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: TranscriptLibraryModel(managedRoot: importRoot),
      speech: SpeechTranscriptionModel(managedRoot: importRoot),
      scheduler: TranscriptionScheduler.inert(),
      pressure: SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false),
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    if #available(macOS 14, *) {
      NSApplication.shared.activate()
    }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.dropDestination(in: host) != nil
    }
    let destination = try XCTUnwrap(self.dropDestination(in: host))
    XCTAssertTrue(ready && window.contentView === host, "class=\(type(of: destination))")
    XCTAssertNil(self.bannerImportButton(in: host))
    XCTAssertNil(self.playConversationButton(in: host))
    let location = destination.convert(
      NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
    let drag = AudioFileDrag(fileURL: source, window: window, location: location)
    defer { drag.draggingPasteboard.releaseGlobally() }
    let entered = destinationDragOperation("draggingEntered:", on: destination, info: drag)
    let updated = destinationDragOperation("draggingUpdated:", on: destination, info: drag)
    let prepared = destinationDragAccepted("prepareForDragOperation:", on: destination, info: drag)
    let performed = destinationDragAccepted("performDragOperation:", on: destination, info: drag)
    destinationDragEnded("concludeDragOperation:", on: destination, info: drag)
    destinationDragEnded("draggingEnded:", on: destination, info: drag)
    let operation = updated == 0 ? entered : updated
    XCTAssertNotEqual(operation, 0)
    XCTAssertTrue(prepared && performed)
    let staged = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return adapter.pendingAudioImport?.urls == [source]
        && self.bannerImportButton(in: host) != nil
    }
    XCTAssertTrue(
      staged && window.contentView === host,
      self.bannerProbe(in: host).joined(separator: "\n"))
    XCTAssertNil(self.playConversationButton(in: host))
    XCTAssertTrue(store.savedSessions.isEmpty)
    XCTAssertNil(adapter.importedSessionId)
    let confirm = try XCTUnwrap(self.bannerImportButton(in: host))
    XCTAssertTrue(confirm.isDescendant(of: host))
    confirm.performClick(nil)
    let imported = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return adapter.phase == .succeeded
        && adapter.importedSessionId != nil
        && self.playConversationButton(in: host) != nil
    }
    XCTAssertTrue(
      imported && window.contentView === host,
      "phase=\(adapter.phase) message=\(adapter.statusMessage ?? "nil") pending=\(String(describing: adapter.pendingAudioImport)) play=\(self.playProbe(in: host))"
    )
    XCTAssertNil(adapter.pendingAudioImport)
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let saved = try XCTUnwrap(store.savedSessions.first { $0.sessionId == sessionId })
    XCTAssertEqual(saved.playableMedia?.isPlayable, true)
    let play = try XCTUnwrap(self.playConversationButton(in: host))
    XCTAssertTrue(play.isDescendant(of: host))
    XCTAssertTrue(play.isEnabled)
    XCTAssertNil(player.importedReceipt)
    XCTAssertNil(recovery.playingSessionId)
    play.performClick(nil)
    let playing = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return recovery.playingSessionId == sessionId
        && player.importedReceipt?.isEmpty == false
    }
    XCTAssertTrue(
      playing,
      "playing=\(recovery.playingSessionId ?? "nil") error=\(recovery.errorMessage ?? "nil") receipt=\(player.importedReceipt ?? "nil")"
    )
    XCTAssertEqual(recovery.activePlaybackSessionId, sessionId)
    XCTAssertEqual(player.importedStartNanoseconds, 0)
    XCTAssertNotNil(player.retainedLease)
    XCTAssertNil(recovery.errorMessage)
    XCTAssertEqual(try Data(contentsOf: source), original)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(player) {}
    withExtendedLifetime(window) {}
    withExtendedLifetime(drag) {}
  }

  /// A Finder-format file URL dropped on the hosted library imports when the
  /// banner button is pressed. Typing in the sidebar field and pressing the
  /// match opens that passage. The pasteboard carries the public types Finder
  /// writes and no item provider. The test does not call `stageDroppedAudio`,
  /// `confirmPendingAudioImport`, `search`, or `playTranscriptSearchHit`.
  /// Set `OPEN_SCRIBE_WHISPER_MODEL` and `OPEN_SCRIBE_WHISPER_SPEECH_M4A`
  /// (`TEST_RUNNER_` prefix under xcodebuild).
  func testHostedFinderFileDropOpensTheSearchHit() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_M4A"]
    else {
      throw XCTSkip(
        "Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_M4A for the hosted drop.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-finder-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Finder search.m4a")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: source)
    let original = try Data(contentsOf: source)
    let modelURL = URL(fileURLWithPath: modelPath)
    let modelBytes = try XCTUnwrap(modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let importRoot = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: false)
    let player = RecoveredAudioPlayerFake()
    let recovery = RecoveredSessionController(
      recoveryFactory: {
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
          .leaseImportedPlayback(sessionId: sessionId)
      },
      player: player
    )
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    live.isLaunchRecoveryPending = { !recovery.captureSafetyComplete }
    let store = RuntimeLibraryStore(
      managedRoot: importRoot,
      isLaunchRecoveryPending: { !recovery.captureSafetyComplete })
    let speech = SpeechTranscriptionModel(managedRoot: importRoot)
    let pressure = SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false)
    let defaults = UserDefaults(
      suiteName: "OpenScribe.Proof.FinderDropSearch.\(UUID().uuidString)")!
    let scheduler = TranscriptionScheduler(
      managedRoot: importRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    await speech.refreshAndWait()
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
    let transcripts = TranscriptLibraryModel(managedRoot: importRoot)
    let navigation = MainWorkspaceNavigation()
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: transcripts,
      speech: speech,
      scheduler: scheduler,
      pressure: pressure,
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    if #available(macOS 14, *) {
      NSApplication.shared.activate()
    }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.dropDestination(in: host) != nil && self.hostedSearchField(in: host) != nil
    }
    let destination = try XCTUnwrap(self.dropDestination(in: host))
    let field = try XCTUnwrap(self.hostedSearchField(in: host))
    XCTAssertTrue(ready && window.contentView === host && field.isDescendant(of: host))
    XCTAssertEqual(destination.accessibilityIdentifier(), "Audio drop")
    XCTAssertNil(self.bannerImportButton(in: host))
    XCTAssertTrue(self.hostedResultButtons(containing: "recording", in: host).isEmpty)
    let location = destination.convert(
      NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
    let drag = FinderFileDrag(fileURL: source, window: window, location: location)
    defer { drag.draggingPasteboard.releaseGlobally() }
    XCTAssertTrue(drag.wroteFileURL)
    XCTAssertTrue(drag.draggingPasteboard.types?.contains(.fileURL) == true)
    XCTAssertEqual(
      drag.draggingPasteboard.propertyList(
        forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
      [source.path])
    let entered = destinationDragOperation("draggingEntered:", on: destination, info: drag)
    let updated = destinationDragOperation("draggingUpdated:", on: destination, info: drag)
    let prepared = destinationDragAccepted("prepareForDragOperation:", on: destination, info: drag)
    let performed = destinationDragAccepted("performDragOperation:", on: destination, info: drag)
    destinationDragEnded("concludeDragOperation:", on: destination, info: drag)
    destinationDragEnded("draggingEnded:", on: destination, info: drag)
    XCTAssertFalse(drag.didEnumerateItems)
    XCTAssertNotEqual(updated == 0 ? entered : updated, 0)
    XCTAssertTrue(prepared && performed)
    let staged = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return adapter.pendingAudioImport?.urls == [source]
        && self.bannerImportButton(in: host) != nil
    }
    XCTAssertTrue(staged && window.contentView === host, self.bannerProbe(in: host).joined(separator: "\n"))
    let confirm = try XCTUnwrap(self.bannerImportButton(in: host))
    XCTAssertTrue(confirm.isDescendant(of: host))
    confirm.performClick(nil)
    let imported = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      adapter.phase == .succeeded && adapter.importedSessionId != nil
    }
    XCTAssertTrue(imported, "phase=\(adapter.phase) message=\(adapter.statusMessage ?? "nil")")
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let queued = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      scheduler.queue.map(\.sessionId) == [sessionId] && scheduler.hold == .noSpeechModel
        && scheduler.runningSessionId == nil && speech.transcribingSessionId == nil
    }
    XCTAssertTrue(
      queued,
      "queue=\(scheduler.queue.map(\.sessionId)) hold=\(String(describing: scheduler.hold))"
    )
    let record = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await speech.install(record, from: modelURL)
    XCTAssertTrue(installed, speech.message ?? "")
    let finished = await waitUntil(timeoutNanoseconds: 180_000_000_000) {
      if case .finished = scheduler.state(for: sessionId) { return true }
      return false
    }
    XCTAssertTrue(
      finished,
      "state=\(String(describing: scheduler.state(for: sessionId))) hold=\(String(describing: scheduler.hold)) running=\(String(describing: scheduler.runningSessionId)) message=\(speech.message ?? "")"
    )
    XCTAssertNil(recovery.playingSessionId)
    XCTAssertNil(player.importedReceipt)
    let listed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      store.savedSessions.contains { $0.sessionId == sessionId && $0.playableMedia?.isPlayable == true }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let queryField = try XCTUnwrap(self.hostedSearchField(in: host))
    XCTAssertTrue(queryField.isDescendant(of: host))
    queryField.stringValue = "recording"
    let matched = await waitUntil(timeoutNanoseconds: 10_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedResultButtons(containing: "recording", in: host).contains {
        ($0.identifier?.rawValue ?? "").hasPrefix(sessionId + "#")
      }
    }
    XCTAssertTrue(
      matched && window.contentView === host,
      "results=\(transcripts.searchResults.map(\.effectiveText)) message=\(transcripts.message ?? "nil")"
    )
    let match = try XCTUnwrap(
      self.hostedResultButtons(containing: "recording", in: host).first {
        ($0.identifier?.rawValue ?? "").hasPrefix(sessionId + "#")
      })
    XCTAssertTrue(match.isDescendant(of: host))
    let key = try XCTUnwrap(match.identifier?.rawValue)
    match.performClick(nil)
    let playing = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      recovery.playingSessionId == sessionId && player.importedReceipt?.isEmpty == false
    }
    let hit = transcripts.searchResults.first { "\($0.sessionId)#\($0.sequence)" == key }
    XCTAssertTrue(
      playing,
      "playing=\(recovery.playingSessionId ?? "nil") error=\(recovery.errorMessage ?? "nil") start=\(String(describing: player.importedStartNanoseconds)) hit=\(String(describing: hit?.startNanoseconds))"
    )
    let opened = try XCTUnwrap(hit)
    XCTAssertEqual(opened.sessionId, sessionId)
    XCTAssertTrue(opened.effectiveText.localizedCaseInsensitiveContains("recording"))
    XCTAssertGreaterThan(opened.endNanoseconds, opened.startNanoseconds)
    XCTAssertEqual(navigation.selectedSessionId, sessionId)
    XCTAssertEqual(recovery.activePlaybackSessionId, sessionId)
    XCTAssertEqual(player.importedStartNanoseconds, opened.startNanoseconds)
    XCTAssertNotNil(player.retainedLease)
    XCTAssertNil(recovery.errorMessage)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, modelBytes)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(player) {}
    withExtendedLifetime(speech) {}
    withExtendedLifetime(scheduler) {}
    withExtendedLifetime(pressure) {}
    withExtendedLifetime(window) {}
    withExtendedLifetime(drag) {}
  }

  /// Two saved conversations already have final transcripts. After both
  /// transcripts exist, IP is denied for the rest of this process. Typing in
  /// the sidebar field lists a match for each, and pressing a match opens that
  /// conversation at its timestamp. The test does not call `search` or
  /// `playTranscriptSearchHit`.
  func testHostedSearchListsBothConversationsAndOpensEachRange() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_M4A"]
    else {
      throw XCTSkip("Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_M4A.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-search-two-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let morningSource = root.appendingPathComponent("Morning meeting.m4a")
    let afternoonSource = root.appendingPathComponent("Afternoon meeting.m4a")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: morningSource)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: afternoonSource)
    let morningOriginal = try Data(contentsOf: morningSource)
    let afternoonOriginal = try Data(contentsOf: afternoonSource)
    let modelURL = URL(fileURLWithPath: modelPath)
    let modelBytes = try XCTUnwrap(modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let managedRoot = root.appendingPathComponent("Library", isDirectory: true)
    let player = RecoveredAudioPlayerFake()
    let recovery = RecoveredSessionController(
      recoveryFactory: {
        try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
          .leaseImportedPlayback(sessionId: sessionId)
      },
      player: player
    )
    let live = LiveMicrophoneRecordingController(managedRoot: managedRoot)
    live.isLaunchRecoveryPending = { !recovery.captureSafetyComplete }
    let store = RuntimeLibraryStore(
      managedRoot: managedRoot, isLaunchRecoveryPending: { !recovery.captureSafetyComplete })
    let speech = SpeechTranscriptionModel(managedRoot: managedRoot)
    let pressure = SystemPressureMonitor(libraryRoot: managedRoot, samplesAutomatically: false)
    let defaults = UserDefaults(suiteName: "OpenScribe.Proof.SearchTwo.\(UUID().uuidString)")!
    let scheduler = TranscriptionScheduler(
      managedRoot: managedRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    await speech.refreshAndWait()
    let morning = try store.importManagedAudio(title: "Morning meeting", sourceURL: morningSource)
    let afternoon = try store.importManagedAudio(
      title: "Afternoon meeting", sourceURL: afternoonSource)
    XCTAssertNotEqual(morning.sessionId, afternoon.sessionId)
    let record = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await speech.install(record, from: modelURL)
    XCTAssertTrue(installed, speech.message ?? "")
    let sessionIds = [morning.sessionId, afternoon.sessionId]
    let transcribed = await waitUntil(timeoutNanoseconds: 180_000_000_000) {
      store.refresh()
      let ready = sessionIds.allSatisfy { id in
        guard let session = store.savedSessions.first(where: { $0.sessionId == id }) else {
          return false
        }
        return session.transcript.documentAvailability == .final
          && session.transcript.selectedRevisionIds.isEmpty == false
      }
      return ready && scheduler.runningSessionId == nil && scheduler.queue.isEmpty
    }
    XCTAssertTrue(
      transcribed,
      "states=\(sessionIds.map { "\($0)=\(String(describing: scheduler.state(for: $0)))" }) hold=\(String(describing: scheduler.hold)) message=\(speech.message ?? "")"
    )
    let transcripts = TranscriptLibraryModel(managedRoot: managedRoot)
    let navigation = MainWorkspaceNavigation()
    let view = ContentView(
      store: store,
      importedMediaAuthority: ImportedMediaAuthorityAdapter(
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in },
        canBeginImport: { live.canStart },
        importer: { title, url in
          try store.importManagedAudio(title: title, sourceURL: url)
        }
      ),
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: transcripts,
      speech: speech,
      scheduler: scheduler,
      pressure: pressure,
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedSearchField(in: host) != nil
    }
    let field = try XCTUnwrap(self.hostedSearchField(in: host))
    XCTAssertTrue(ready && window.contentView === host && field.isDescendant(of: host))
    XCTAssertTrue(self.hostedResultButtons(containing: "recording", in: host).isEmpty)
    let reachable = self.loopbackConnectErrno()
    XCTAssertNotEqual(reachable, EPERM, "loopback was already denied: \(reachable)")
    try self.denyInternetProtocol()
    XCTAssertEqual(self.loopbackConnectErrno(), EPERM)
    field.stringValue = "recording"
    let matched = await waitUntil(timeoutNanoseconds: 10_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let buttons = self.hostedResultButtons(containing: "recording", in: host)
      let found = Set(sessionIds.filter { id in
        buttons.contains { ($0.identifier?.rawValue ?? "").hasPrefix(id + "#") }
      })
      return found == Set(sessionIds)
    }
    XCTAssertTrue(
      matched && window.contentView === host,
      "results=\(transcripts.searchResults.map { "\($0.sessionId) \($0.sessionTitle) \($0.effectiveText)" }) message=\(transcripts.message ?? "nil")"
    )
    let buttons = hostedResultButtons(containing: "recording", in: host)
    let matchedSessions = Set(buttons.compactMap { button -> String? in
      guard let raw = button.identifier?.rawValue else { return nil }
      return raw.split(separator: "#").first.map(String.init)
    })
    XCTAssertEqual(matchedSessions, Set(sessionIds))
    for sessionId in sessionIds {
      let title = sessionId == morning.sessionId ? "Morning meeting" : "Afternoon meeting"
      let match = try XCTUnwrap(
        buttons.first { ($0.identifier?.rawValue ?? "").hasPrefix(sessionId + "#") })
      XCTAssertTrue(match.isDescendant(of: host))
      XCTAssertTrue(match.accessibilityLabel()?.contains(title) == true, match.accessibilityLabel() ?? "")
      let key = try XCTUnwrap(match.identifier?.rawValue)
      match.performClick(nil)
      let playing = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        recovery.playingSessionId == sessionId && player.importedReceipt?.isEmpty == false
      }
      let hit = try XCTUnwrap(
        transcripts.searchResults.first { "\($0.sessionId)#\($0.sequence)" == key })
      XCTAssertTrue(
        playing,
        "playing=\(recovery.playingSessionId ?? "nil") error=\(recovery.errorMessage ?? "nil") hit=\(hit.startNanoseconds)"
      )
      XCTAssertEqual(hit.sessionId, sessionId)
      XCTAssertEqual(hit.sessionTitle, title)
      XCTAssertTrue(hit.effectiveText.localizedCaseInsensitiveContains("recording"))
      XCTAssertGreaterThan(hit.endNanoseconds, hit.startNanoseconds)
      XCTAssertEqual(navigation.selectedSessionId, sessionId)
      XCTAssertEqual(player.importedStartNanoseconds, hit.startNanoseconds)
      XCTAssertNil(recovery.errorMessage)
    }
    XCTAssertEqual(try Data(contentsOf: morningSource), morningOriginal)
    XCTAssertEqual(try Data(contentsOf: afternoonSource), afternoonOriginal)
    XCTAssertEqual(try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, modelBytes)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(player) {}
    withExtendedLifetime(speech) {}
    withExtendedLifetime(scheduler) {}
  }

  /// A confirmed drop is transcribed by the automatic queue. Typing in the
  /// sidebar field and pressing the match opens that passage. The test does
  /// not call `stageDroppedAudio`, `confirmPendingAudioImport`, `search`, or
  /// `playTranscriptSearchHit`.
  func testAHostedDropConfirmedFromTheBannerOpensTheSearchHit() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_M4A"]
    else {
      throw XCTSkip(
        "Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_M4A for the hosted drop.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Searched drop.m4a")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: source)
    let original = try Data(contentsOf: source)
    let modelURL = URL(fileURLWithPath: modelPath)
    let modelBytes = try XCTUnwrap(modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let importRoot = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: false)
    let player = RecoveredAudioPlayerFake()
    let recovery = RecoveredSessionController(
      recoveryFactory: {
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
          .leaseImportedPlayback(sessionId: sessionId)
      },
      player: player
    )
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    live.isLaunchRecoveryPending = { !recovery.captureSafetyComplete }
    let store = RuntimeLibraryStore(
      managedRoot: importRoot,
      isLaunchRecoveryPending: { !recovery.captureSafetyComplete })
    let speech = SpeechTranscriptionModel(managedRoot: importRoot)
    let pressure = SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false)
    let defaults = UserDefaults(
      suiteName: "OpenScribe.Proof.HostedDropSearch.\(UUID().uuidString)")!
    let scheduler = TranscriptionScheduler(
      managedRoot: importRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    await speech.refreshAndWait()
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
    let transcripts = TranscriptLibraryModel(managedRoot: importRoot)
    let navigation = MainWorkspaceNavigation()
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: transcripts,
      speech: speech,
      scheduler: scheduler,
      pressure: pressure,
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    if #available(macOS 14, *) {
      NSApplication.shared.activate()
    }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.dropDestination(in: host) != nil && self.hostedSearchField(in: host) != nil
    }
    let destination = try XCTUnwrap(self.dropDestination(in: host))
    let field = try XCTUnwrap(self.hostedSearchField(in: host))
    XCTAssertTrue(ready && window.contentView === host && field.isDescendant(of: host))
    XCTAssertNil(self.bannerImportButton(in: host))
    XCTAssertTrue(self.hostedResultButtons(containing: "recording", in: host).isEmpty)
    let location = destination.convert(
      NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
    let drag = AudioFileDrag(fileURL: source, window: window, location: location)
    defer { drag.draggingPasteboard.releaseGlobally() }
    let entered = destinationDragOperation("draggingEntered:", on: destination, info: drag)
    let updated = destinationDragOperation("draggingUpdated:", on: destination, info: drag)
    let prepared = destinationDragAccepted("prepareForDragOperation:", on: destination, info: drag)
    let performed = destinationDragAccepted("performDragOperation:", on: destination, info: drag)
    destinationDragEnded("concludeDragOperation:", on: destination, info: drag)
    destinationDragEnded("draggingEnded:", on: destination, info: drag)
    XCTAssertNotEqual(updated == 0 ? entered : updated, 0)
    XCTAssertTrue(prepared && performed)
    let staged = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return adapter.pendingAudioImport?.urls == [source]
        && self.bannerImportButton(in: host) != nil
    }
    XCTAssertTrue(staged && window.contentView === host, self.bannerProbe(in: host).joined(separator: "\n"))
    let confirm = try XCTUnwrap(self.bannerImportButton(in: host))
    XCTAssertTrue(confirm.isDescendant(of: host))
    confirm.performClick(nil)
    let imported = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      adapter.phase == .succeeded && adapter.importedSessionId != nil
    }
    XCTAssertTrue(imported, "phase=\(adapter.phase) message=\(adapter.statusMessage ?? "nil")")
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let queued = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      scheduler.queue.map(\.sessionId) == [sessionId] && scheduler.hold == .noSpeechModel
        && scheduler.runningSessionId == nil && speech.transcribingSessionId == nil
    }
    XCTAssertTrue(
      queued,
      "queue=\(scheduler.queue.map(\.sessionId)) hold=\(String(describing: scheduler.hold))"
    )
    let record = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await speech.install(record, from: modelURL)
    XCTAssertTrue(installed, speech.message ?? "")
    let finished = await waitUntil(timeoutNanoseconds: 180_000_000_000) {
      if case .finished = scheduler.state(for: sessionId) { return true }
      return false
    }
    XCTAssertTrue(
      finished,
      "state=\(String(describing: scheduler.state(for: sessionId))) hold=\(String(describing: scheduler.hold)) running=\(String(describing: scheduler.runningSessionId)) message=\(speech.message ?? "")"
    )
    XCTAssertNil(recovery.playingSessionId)
    XCTAssertNil(player.importedReceipt)
    let listed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      store.savedSessions.contains { $0.sessionId == sessionId && $0.playableMedia?.isPlayable == true }
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId))")
    let queryField = try XCTUnwrap(self.hostedSearchField(in: host))
    XCTAssertTrue(queryField.isDescendant(of: host))
    queryField.stringValue = "recording"
    let matched = await waitUntil(timeoutNanoseconds: 10_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.hostedResultButtons(containing: "recording", in: host).contains {
        ($0.identifier?.rawValue ?? "").hasPrefix(sessionId + "#")
      }
    }
    XCTAssertTrue(
      matched && window.contentView === host,
      "results=\(transcripts.searchResults.map(\.effectiveText)) message=\(transcripts.message ?? "nil")"
    )
    let match = try XCTUnwrap(
      self.hostedResultButtons(containing: "recording", in: host).first {
        ($0.identifier?.rawValue ?? "").hasPrefix(sessionId + "#")
      })
    XCTAssertTrue(match.isDescendant(of: host))
    let key = try XCTUnwrap(match.identifier?.rawValue)
    match.performClick(nil)
    let playing = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      recovery.playingSessionId == sessionId && player.importedReceipt?.isEmpty == false
    }
    let hit = transcripts.searchResults.first { "\($0.sessionId)#\($0.sequence)" == key }
    XCTAssertTrue(
      playing,
      "playing=\(recovery.playingSessionId ?? "nil") error=\(recovery.errorMessage ?? "nil") start=\(String(describing: player.importedStartNanoseconds)) hit=\(String(describing: hit?.startNanoseconds))"
    )
    let opened = try XCTUnwrap(hit)
    XCTAssertEqual(opened.sessionId, sessionId)
    XCTAssertTrue(opened.effectiveText.localizedCaseInsensitiveContains("recording"))
    XCTAssertGreaterThan(opened.endNanoseconds, opened.startNanoseconds)
    XCTAssertEqual(navigation.selectedSessionId, sessionId)
    XCTAssertEqual(recovery.activePlaybackSessionId, sessionId)
    XCTAssertEqual(player.importedStartNanoseconds, opened.startNanoseconds)
    XCTAssertNotNil(player.retainedLease)
    XCTAssertNil(recovery.errorMessage)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, modelBytes)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(player) {}
    withExtendedLifetime(speech) {}
    withExtendedLifetime(scheduler) {}
    withExtendedLifetime(pressure) {}
    withExtendedLifetime(window) {}
    withExtendedLifetime(drag) {}
  }

  /// A Finder-format file URL dropped on the hosted library imports when the
  /// banner button is pressed. The automatic queue transcribes it, and the
  /// hosted review strip names the speaker, saves a correction, and exports
  /// Markdown. The pasteboard carries the public types Finder writes and no
  /// item provider. The test does not call `stageDroppedAudio`,
  /// `confirmPendingAudioImport`, `load`, `assignSpeaker`, `renameSpeaker`,
  /// `correct`, or `export`. Set `OPEN_SCRIBE_WHISPER_MODEL` and
  /// `OPEN_SCRIBE_WHISPER_SPEECH_M4A` (`TEST_RUNNER_` prefix under xcodebuild).
  func testHostedFinderFileDropReviewsAndExports() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_M4A"]
    else {
      throw XCTSkip(
        "Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_M4A for the hosted drop.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-finder-review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Finder review.m4a")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: source)
    let original = try Data(contentsOf: source)
    let modelURL = URL(fileURLWithPath: modelPath)
    let modelBytes = try XCTUnwrap(modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let exportURL = root.appendingPathComponent("Finder review.md")
    let importRoot = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: false)
    let recovery = RecoveredSessionController(
      recoveryFactory: {
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
          .leaseImportedPlayback(sessionId: sessionId)
      },
      player: RecoveredAudioPlayerFake()
    )
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    live.isLaunchRecoveryPending = { !recovery.captureSafetyComplete }
    let store = RuntimeLibraryStore(
      managedRoot: importRoot,
      isLaunchRecoveryPending: { !recovery.captureSafetyComplete })
    let speech = SpeechTranscriptionModel(managedRoot: importRoot)
    let pressure = SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false)
    let defaults = UserDefaults(
      suiteName: "OpenScribe.Proof.FinderDropReview.\(UUID().uuidString)")!
    let scheduler = TranscriptionScheduler(
      managedRoot: importRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    await speech.refreshAndWait()
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
    let transcripts = TranscriptLibraryModel(managedRoot: importRoot)
    let navigation = MainWorkspaceNavigation()
    let speakerName = "Riley"
    let revised = "The recording stays on this Mac after review."
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: transcripts,
      speech: speech,
      scheduler: scheduler,
      pressure: pressure,
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation,
      exportTranscriptDestination: { _ in exportURL }
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    if #available(macOS 14, *) {
      NSApplication.shared.activate()
    }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.dropDestination(in: host) != nil
    }
    let destination = try XCTUnwrap(self.dropDestination(in: host))
    XCTAssertTrue(ready && window.contentView === host && destination.isDescendant(of: host))
    XCTAssertEqual(destination.accessibilityIdentifier(), "Audio drop")
    XCTAssertNil(self.bannerImportButton(in: host))
    let location = destination.convert(
      NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
    let drag = FinderFileDrag(fileURL: source, window: window, location: location)
    defer { drag.draggingPasteboard.releaseGlobally() }
    XCTAssertTrue(drag.wroteFileURL)
    XCTAssertTrue(drag.draggingPasteboard.types?.contains(.fileURL) == true)
    XCTAssertEqual(
      drag.draggingPasteboard.propertyList(
        forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
      [source.path])
    let entered = destinationDragOperation("draggingEntered:", on: destination, info: drag)
    let updated = destinationDragOperation("draggingUpdated:", on: destination, info: drag)
    let prepared = destinationDragAccepted("prepareForDragOperation:", on: destination, info: drag)
    let performed = destinationDragAccepted("performDragOperation:", on: destination, info: drag)
    destinationDragEnded("concludeDragOperation:", on: destination, info: drag)
    destinationDragEnded("draggingEnded:", on: destination, info: drag)
    XCTAssertFalse(drag.didEnumerateItems)
    XCTAssertNotEqual(updated == 0 ? entered : updated, 0)
    XCTAssertTrue(prepared && performed)
    let staged = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return adapter.pendingAudioImport?.urls == [source]
        && self.bannerImportButton(in: host) != nil
    }
    XCTAssertTrue(staged && window.contentView === host, self.bannerProbe(in: host).joined(separator: "\n"))
    let confirm = try XCTUnwrap(self.bannerImportButton(in: host))
    XCTAssertTrue(confirm.isDescendant(of: host))
    confirm.performClick(nil)
    let imported = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      adapter.phase == .succeeded && adapter.importedSessionId != nil
    }
    XCTAssertTrue(imported, "phase=\(adapter.phase) message=\(adapter.statusMessage ?? "nil")")
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let queued = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      scheduler.queue.map(\.sessionId) == [sessionId] && scheduler.hold == .noSpeechModel
        && scheduler.runningSessionId == nil && speech.transcribingSessionId == nil
    }
    XCTAssertTrue(
      queued,
      "queue=\(scheduler.queue.map(\.sessionId)) hold=\(String(describing: scheduler.hold))"
    )
    let record = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await speech.install(record, from: modelURL)
    XCTAssertTrue(installed, speech.message ?? "")
    let finished = await waitUntil(timeoutNanoseconds: 180_000_000_000) {
      if case .finished = scheduler.state(for: sessionId) { return true }
      return false
    }
    XCTAssertTrue(
      finished,
      "state=\(String(describing: scheduler.state(for: sessionId))) hold=\(String(describing: scheduler.hold)) running=\(String(describing: scheduler.runningSessionId)) message=\(speech.message ?? "")"
    )
    let listed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      store.savedSessions.contains { $0.sessionId == sessionId && $0.playableMedia?.isPlayable == true }
        && navigation.selectedSessionId == sessionId
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId)) selected=\(navigation.selectedSessionId ?? "nil")")
    let reviewReady = await waitUntil(timeoutNanoseconds: 20_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard let segment = transcripts.segments.first(where: { $0.finality != "draft" }),
        transcripts.sessionId == sessionId
      else { return false }
      let stamp = TranscriptSection.timestamp(segment.startNanoseconds)
      let nameLabel = ConversationControlLabels.nameSpeakerAccessibility(
        stamp: stamp, label: segment.speakerLabel)
      return self.hostedActionButton(labeled: nameLabel, in: host) != nil
        && self.hostedActionButton(
          labeled: ConversationControlLabels.correctAccessibility(stamp: stamp), in: host) != nil
        && self.hostedActionButton(
          labeled: ConversationControlLabels.exportTranscript, in: host) != nil
    }
    XCTAssertTrue(
      reviewReady && window.contentView === host,
      "segments=\(transcripts.segments.map(\.effectiveText)) message=\(transcripts.message ?? "nil")\n\(self.reviewProbe(in: host))"
    )
    let segment = try XCTUnwrap(transcripts.segments.first { $0.finality != "draft" })
    let stamp = TranscriptSection.timestamp(segment.startNanoseconds)
    let nameLabel = ConversationControlLabels.nameSpeakerAccessibility(
      stamp: stamp, label: segment.speakerLabel)
    let nameButton = try XCTUnwrap(self.hostedActionButton(labeled: nameLabel, in: host))
    XCTAssertTrue(nameButton.isDescendant(of: host))
    nameButton.performClick(nil)
    let nameShown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return self.hostedLabeledField(labeled: "Person's name", in: host) != nil
        && self.hostedActionButton(labeled: "Save speaker", in: host) != nil
    }
    XCTAssertTrue(nameShown && window.contentView === host, self.reviewProbe(in: host))
    let nameField = try XCTUnwrap(self.hostedLabeledField(labeled: "Person's name", in: host))
    nameField.stringValue = speakerName
    let saveSpeaker = try XCTUnwrap(self.hostedActionButton(labeled: "Save speaker", in: host))
    XCTAssertTrue(saveSpeaker.isEnabled && saveSpeaker.isDescendant(of: host), self.reviewProbe(in: host))
    saveSpeaker.performClick(nil)
    let named = await waitUntil(timeoutNanoseconds: 10_000_000_000) {
      transcripts.segments.first { $0.id == segment.id }?.speakerLabel == speakerName
    }
    XCTAssertTrue(named, "labels=\(transcripts.segments.map(\.speakerLabel)) message=\(transcripts.message ?? "nil")")
    let correctLabel = ConversationControlLabels.correctAccessibility(stamp: stamp)
    let correctButton = try XCTUnwrap(self.hostedActionButton(labeled: correctLabel, in: host))
    XCTAssertTrue(correctButton.isDescendant(of: host))
    correctButton.performClick(nil)
    let editor = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return self.hostedLabeledField(labeled: "Corrected text", in: host) != nil
        && self.hostedActionButton(labeled: "Save correction", in: host) != nil
    }
    XCTAssertTrue(editor && window.contentView === host, self.reviewProbe(in: host))
    let correctionField = try XCTUnwrap(self.hostedLabeledField(labeled: "Corrected text", in: host))
    correctionField.stringValue = revised
    let saveCorrection = try XCTUnwrap(self.hostedActionButton(labeled: "Save correction", in: host))
    XCTAssertTrue(
      saveCorrection.isEnabled && saveCorrection.isDescendant(of: host), self.reviewProbe(in: host))
    saveCorrection.performClick(nil)
    let corrected = await waitUntil(timeoutNanoseconds: 10_000_000_000) {
      let passage = transcripts.segments.first { $0.id == segment.id }
      return passage?.effectiveText == revised && passage?.corrected == true
        && passage?.speakerLabel == speakerName
    }
    XCTAssertTrue(
      corrected, "text=\(transcripts.segments.map(\.effectiveText)) message=\(transcripts.message ?? "nil")")
    let export = try XCTUnwrap(
      self.hostedActionButton(labeled: ConversationControlLabels.exportTranscript, in: host))
    XCTAssertTrue(export.isEnabled && export.isDescendant(of: host))
    export.performClick(nil)
    let wrote = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      guard let text = try? String(contentsOf: exportURL, encoding: .utf8) else { return false }
      return text.contains(speakerName) && text.contains(revised)
    }
    XCTAssertTrue(wrote, "message=\(transcripts.message ?? "nil")")
    let markdown = try String(contentsOf: exportURL, encoding: .utf8)
    XCTAssertTrue(markdown.contains(speakerName))
    XCTAssertTrue(markdown.contains(revised))
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, modelBytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path) == false)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(speech) {}
    withExtendedLifetime(scheduler) {}
    withExtendedLifetime(pressure) {}
    withExtendedLifetime(window) {}
    withExtendedLifetime(drag) {}
  }

  /// A confirmed drop is transcribed by the automatic queue. The hosted review
  /// strip then names the speaker, saves a correction, and exports Markdown.
  /// The test does not call `stageDroppedAudio`, `confirmPendingAudioImport`,
  /// `load`, `assignSpeaker`, `renameSpeaker`, `correct`, or `export`.
  func testAHostedDropConfirmedFromTheBannerReviewsAndExports() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_M4A"]
    else {
      throw XCTSkip(
        "Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_M4A for the hosted drop.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-review-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Reviewed drop.m4a")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: source)
    let original = try Data(contentsOf: source)
    let modelURL = URL(fileURLWithPath: modelPath)
    let modelBytes = try XCTUnwrap(modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let exportURL = root.appendingPathComponent("Reviewed drop.md")
    let importRoot = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: false)
    let recovery = RecoveredSessionController(
      recoveryFactory: {
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
          .leaseImportedPlayback(sessionId: sessionId)
      },
      player: RecoveredAudioPlayerFake()
    )
    let live = LiveMicrophoneRecordingController(managedRoot: importRoot)
    live.isLaunchRecoveryPending = { !recovery.captureSafetyComplete }
    let store = RuntimeLibraryStore(
      managedRoot: importRoot,
      isLaunchRecoveryPending: { !recovery.captureSafetyComplete })
    let speech = SpeechTranscriptionModel(managedRoot: importRoot)
    let pressure = SystemPressureMonitor(libraryRoot: importRoot, samplesAutomatically: false)
    let defaults = UserDefaults(
      suiteName: "OpenScribe.Proof.HostedDropReview.\(UUID().uuidString)")!
    let scheduler = TranscriptionScheduler(
      managedRoot: importRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    await speech.refreshAndWait()
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
    let transcripts = TranscriptLibraryModel(managedRoot: importRoot)
    let navigation = MainWorkspaceNavigation()
    let speakerName = "Riley"
    let revised = "The recording stays on this Mac after review."
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: transcripts,
      speech: speech,
      scheduler: scheduler,
      pressure: pressure,
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: navigation,
      exportTranscriptDestination: { _ in exportURL }
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    if #available(macOS 14, *) {
      NSApplication.shared.activate()
    }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let ready = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.dropDestination(in: host) != nil
    }
    let destination = try XCTUnwrap(self.dropDestination(in: host))
    XCTAssertTrue(ready && window.contentView === host && destination.isDescendant(of: host))
    XCTAssertNil(self.bannerImportButton(in: host))
    let location = destination.convert(
      NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
    let drag = AudioFileDrag(fileURL: source, window: window, location: location)
    defer { drag.draggingPasteboard.releaseGlobally() }
    let entered = destinationDragOperation("draggingEntered:", on: destination, info: drag)
    let updated = destinationDragOperation("draggingUpdated:", on: destination, info: drag)
    let prepared = destinationDragAccepted("prepareForDragOperation:", on: destination, info: drag)
    let performed = destinationDragAccepted("performDragOperation:", on: destination, info: drag)
    destinationDragEnded("concludeDragOperation:", on: destination, info: drag)
    destinationDragEnded("draggingEnded:", on: destination, info: drag)
    XCTAssertNotEqual(updated == 0 ? entered : updated, 0)
    XCTAssertTrue(prepared && performed)
    let staged = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return adapter.pendingAudioImport?.urls == [source]
        && self.bannerImportButton(in: host) != nil
    }
    XCTAssertTrue(staged && window.contentView === host, self.bannerProbe(in: host).joined(separator: "\n"))
    let confirm = try XCTUnwrap(self.bannerImportButton(in: host))
    XCTAssertTrue(confirm.isDescendant(of: host))
    confirm.performClick(nil)
    let imported = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      adapter.phase == .succeeded && adapter.importedSessionId != nil
    }
    XCTAssertTrue(imported, "phase=\(adapter.phase) message=\(adapter.statusMessage ?? "nil")")
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let queued = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      scheduler.queue.map(\.sessionId) == [sessionId] && scheduler.hold == .noSpeechModel
        && scheduler.runningSessionId == nil && speech.transcribingSessionId == nil
    }
    XCTAssertTrue(
      queued,
      "queue=\(scheduler.queue.map(\.sessionId)) hold=\(String(describing: scheduler.hold))"
    )
    let record = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await speech.install(record, from: modelURL)
    XCTAssertTrue(installed, speech.message ?? "")
    let finished = await waitUntil(timeoutNanoseconds: 180_000_000_000) {
      if case .finished = scheduler.state(for: sessionId) { return true }
      return false
    }
    XCTAssertTrue(
      finished,
      "state=\(String(describing: scheduler.state(for: sessionId))) hold=\(String(describing: scheduler.hold)) running=\(String(describing: scheduler.runningSessionId)) message=\(speech.message ?? "")"
    )
    let listed = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      store.savedSessions.contains { $0.sessionId == sessionId && $0.playableMedia?.isPlayable == true }
        && navigation.selectedSessionId == sessionId
    }
    XCTAssertTrue(listed, "saved=\(store.savedSessions.map(\.sessionId)) selected=\(navigation.selectedSessionId ?? "nil")")
    let reviewReady = await waitUntil(timeoutNanoseconds: 20_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard let segment = transcripts.segments.first(where: { $0.finality != "draft" }),
        transcripts.sessionId == sessionId
      else { return false }
      let stamp = TranscriptSection.timestamp(segment.startNanoseconds)
      let nameLabel = ConversationControlLabels.nameSpeakerAccessibility(
        stamp: stamp, label: segment.speakerLabel)
      return self.hostedActionButton(labeled: nameLabel, in: host) != nil
        && self.hostedActionButton(
          labeled: ConversationControlLabels.correctAccessibility(stamp: stamp), in: host) != nil
        && self.hostedActionButton(
          labeled: ConversationControlLabels.exportTranscript, in: host) != nil
    }
    XCTAssertTrue(
      reviewReady && window.contentView === host,
      "segments=\(transcripts.segments.map(\.effectiveText)) message=\(transcripts.message ?? "nil")\n\(self.reviewProbe(in: host))"
    )
    let segment = try XCTUnwrap(transcripts.segments.first { $0.finality != "draft" })
    let stamp = TranscriptSection.timestamp(segment.startNanoseconds)
    let nameLabel = ConversationControlLabels.nameSpeakerAccessibility(
      stamp: stamp, label: segment.speakerLabel)
    let nameButton = try XCTUnwrap(self.hostedActionButton(labeled: nameLabel, in: host))
    XCTAssertTrue(nameButton.isDescendant(of: host))
    nameButton.performClick(nil)
    let nameShown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return self.hostedLabeledField(labeled: "Person's name", in: host) != nil
        && self.hostedActionButton(labeled: "Save speaker", in: host) != nil
    }
    XCTAssertTrue(nameShown && window.contentView === host, self.reviewProbe(in: host))
    let nameField = try XCTUnwrap(self.hostedLabeledField(labeled: "Person's name", in: host))
    nameField.stringValue = speakerName
    let saveSpeaker = try XCTUnwrap(self.hostedActionButton(labeled: "Save speaker", in: host))
    XCTAssertTrue(saveSpeaker.isEnabled && saveSpeaker.isDescendant(of: host), self.reviewProbe(in: host))
    saveSpeaker.performClick(nil)
    let named = await waitUntil(timeoutNanoseconds: 10_000_000_000) {
      transcripts.segments.first { $0.id == segment.id }?.speakerLabel == speakerName
    }
    XCTAssertTrue(named, "labels=\(transcripts.segments.map(\.speakerLabel)) message=\(transcripts.message ?? "nil")")
    let correctLabel = ConversationControlLabels.correctAccessibility(stamp: stamp)
    let correctButton = try XCTUnwrap(self.hostedActionButton(labeled: correctLabel, in: host))
    XCTAssertTrue(correctButton.isDescendant(of: host))
    correctButton.performClick(nil)
    let editor = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      return self.hostedLabeledField(labeled: "Corrected text", in: host) != nil
        && self.hostedActionButton(labeled: "Save correction", in: host) != nil
    }
    XCTAssertTrue(editor && window.contentView === host, self.reviewProbe(in: host))
    let correctionField = try XCTUnwrap(self.hostedLabeledField(labeled: "Corrected text", in: host))
    correctionField.stringValue = revised
    let saveCorrection = try XCTUnwrap(self.hostedActionButton(labeled: "Save correction", in: host))
    XCTAssertTrue(
      saveCorrection.isEnabled && saveCorrection.isDescendant(of: host), self.reviewProbe(in: host))
    saveCorrection.performClick(nil)
    let corrected = await waitUntil(timeoutNanoseconds: 10_000_000_000) {
      let passage = transcripts.segments.first { $0.id == segment.id }
      return passage?.effectiveText == revised && passage?.corrected == true
        && passage?.speakerLabel == speakerName
    }
    XCTAssertTrue(
      corrected, "text=\(transcripts.segments.map(\.effectiveText)) message=\(transcripts.message ?? "nil")")
    let export = try XCTUnwrap(
      self.hostedActionButton(labeled: ConversationControlLabels.exportTranscript, in: host))
    XCTAssertTrue(export.isEnabled && export.isDescendant(of: host))
    export.performClick(nil)
    let wrote = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      guard let text = try? String(contentsOf: exportURL, encoding: .utf8) else { return false }
      return text.contains(speakerName) && text.contains(revised)
    }
    XCTAssertTrue(wrote, "message=\(transcripts.message ?? "nil")")
    let markdown = try String(contentsOf: exportURL, encoding: .utf8)
    XCTAssertTrue(markdown.contains(speakerName))
    XCTAssertTrue(markdown.contains(revised))
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, modelBytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path) == false)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(speech) {}
    withExtendedLifetime(scheduler) {}
    withExtendedLifetime(pressure) {}
    withExtendedLifetime(window) {}
    withExtendedLifetime(drag) {}
  }

  /// A file dropped on the hosted library imports when that same hosting view's
  /// banner button is pressed. The imported item then plays, transcribes through
  /// the automatic queue, and accepts speaker review, search, correction, and
  /// export. The test does not call `stageDroppedAudio`, `confirmPendingAudioImport`,
  /// or `transcribe`. Set `OPEN_SCRIBE_WHISPER_MODEL` and
  /// `OPEN_SCRIBE_WHISPER_SPEECH_M4A` (`TEST_RUNNER_` prefix under xcodebuild).
  func testAHostedDropConfirmedFromTheBannerImportsAndLeavesTheOriginal() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_WHISPER_MODEL"],
      let speechPath = environment["OPEN_SCRIBE_WHISPER_SPEECH_M4A"]
    else {
      throw XCTSkip(
        "Set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_M4A for the hosted drop.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-drop-confirm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Dropped memo.m4a")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: speechPath), to: source)
    let original = try Data(contentsOf: source)
    let modelURL = URL(fileURLWithPath: modelPath)
    let modelBytes = try XCTUnwrap(modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
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
      suiteName: "OpenScribe.Proof.HostedDrop.\(UUID().uuidString)")!
    let scheduler = TranscriptionScheduler(
      managedRoot: importRoot, speech: speech, store: store, liveRecording: live,
      recovery: recovery, pressure: pressure, defaults: defaults)
    recovery.recoverOnLaunch()
    await recovery.waitForLaunchRecovery()
    XCTAssertTrue(recovery.captureSafetyComplete)
    await speech.refreshAndWait()
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
    let transcripts = TranscriptLibraryModel(managedRoot: importRoot)
    let view = ContentView(
      store: store,
      importedMediaAuthority: adapter,
      liveRecording: live,
      recoveredSessions: recovery,
      transcripts: transcripts,
      speech: speech,
      scheduler: scheduler,
      pressure: pressure,
      context: ContextScopeModel(
        binding: { nil },
        frames: IdleContextFrames(),
        permissionCheck: { .denied },
        permissionRequest: { .denied },
        topology: { [] }
      ),
      navigation: MainWorkspaceNavigation()
    )
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 720))
    host.frame = window.contentLayoutRect
    if #available(macOS 14, *) {
      NSApplication.shared.activate()
    }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return dropDestination(in: host) != nil
    }
    let destination = try XCTUnwrap(dropDestination(in: host))
    XCTAssertTrue(shown, "class=\(type(of: destination))")
    XCTAssertNil(bannerImportButton(in: host))
    let location = destination.convert(
      NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
    let drag = AudioFileDrag(fileURL: source, window: window, location: location)
    defer { drag.draggingPasteboard.releaseGlobally() }
    let entered = destinationDragOperation("draggingEntered:", on: destination, info: drag)
    let updated = destinationDragOperation("draggingUpdated:", on: destination, info: drag)
    let prepared = destinationDragAccepted("prepareForDragOperation:", on: destination, info: drag)
    let performed = destinationDragAccepted("performDragOperation:", on: destination, info: drag)
    destinationDragEnded("concludeDragOperation:", on: destination, info: drag)
    destinationDragEnded("draggingEnded:", on: destination, info: drag)
    XCTAssertTrue(
      prepared && performed,
      "class=\(type(of: destination)) entered=\(entered) updated=\(updated) prepared=\(prepared) performed=\(performed) classes=\(drag.requestedClasses)"
    )
    let staged = await waitUntil {
      adapter.pendingAudioImport?.urls == [source]
    }
    XCTAssertTrue(
      staged,
      "performed=\(performed) classes=\(drag.requestedClasses) phase=\(adapter.phase) message=\(adapter.statusMessage ?? "nil")"
    )
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertTrue(store.savedSessions.isEmpty)
    XCTAssertTrue(window.contentView === host)
    let banner = await waitUntilPumped(host, window: window) {
      bannerImportButton(in: host) != nil
    }
    let button = bannerImportButton(in: host)
    XCTAssertTrue(
      banner && button != nil && window.contentView === host,
      "key=\(window.isKeyWindow) bounds=\(host.bounds) pending=\(String(describing: adapter.pendingAudioImport?.urls)) banner=\(bannerProbe(in: host)) proxies=\(focusProxyProbe(in: host))"
    )
    let control = try XCTUnwrap(button)
    XCTAssertTrue(control.isDescendant(of: host))
    XCTAssertTrue(control.window === window)
    XCTAssertFalse(control.isHidden)
    window.displayIfNeeded()
    click(control)
    let imported = await waitUntil { adapter.phase == .succeeded }
    XCTAssertTrue(
      imported,
      "phase=\(adapter.phase) frame=\(control.frame) pending=\(String(describing: adapter.pendingAudioImport))"
    )
    XCTAssertNil(adapter.pendingAudioImport)
    XCTAssertNotNil(adapter.importedSessionId)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let sessionId = try XCTUnwrap(adapter.importedSessionId)
    let queued = await waitUntil(timeoutNanoseconds: 15_000_000_000) {
      scheduler.queue.map(\.sessionId) == [sessionId] && scheduler.hold == .noSpeechModel
        && scheduler.runningSessionId == nil && speech.transcribingSessionId == nil
    }
    XCTAssertTrue(
      queued,
      "queue=\(scheduler.queue.map(\.sessionId)) hold=\(String(describing: scheduler.hold))"
    )
    XCTAssertEqual(scheduler.queue.first?.requestedByUser, false)
    let managedCopy = try XCTUnwrap(importedAudioFile(under: importRoot))
    let managedBefore = try Data(contentsOf: managedCopy)
    let record = try XCTUnwrap(speech.models.first { $0.modelId == "whisper-small.en-q5_1" })
    let installed = await speech.install(record, from: modelURL)
    XCTAssertTrue(installed, speech.message ?? "")
    let finished = await waitUntil(timeoutNanoseconds: 180_000_000_000) {
      if case .finished = scheduler.state(for: sessionId) { return true }
      return false
    }
    XCTAssertTrue(
      finished,
      "state=\(String(describing: scheduler.state(for: sessionId))) hold=\(String(describing: scheduler.hold)) running=\(String(describing: scheduler.runningSessionId)) message=\(speech.message ?? "")"
    )
    await transcripts.load(sessionId: sessionId)
    XCTAssertEqual(transcripts.availability, .final)
    let machine = try XCTUnwrap(
      transcripts.segments.first {
        $0.effectiveText.localizedCaseInsensitiveContains("recording safe")
      })
    await transcripts.search("recording")
    let hit = try XCTUnwrap(
      transcripts.searchResults.first {
        $0.sessionId == sessionId && $0.effectiveText.localizedCaseInsensitiveContains("recording")
      })
    XCTAssertGreaterThan(hit.endNanoseconds, hit.startNanoseconds)
    let preparation = try NativeRecordingPreparation.open(managedRoot: importRoot.path)
    let saved = try XCTUnwrap(
      try preparation.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let session = RuntimeSessionPresentation(native: saved)
    XCTAssertEqual(session.playableMedia?.isPlayable, true)
    let player = RecoveredAudioPlayer(outputMode: .silent)
    let playback = RecoveredSessionController(
      recoveryFactory: { try NativeRecordingPreparation.open(managedRoot: importRoot.path) },
      importedPlaybackLeaseProvider: { id in
        try NativeRecordingPreparation.open(managedRoot: importRoot.path)
          .leaseImportedPlayback(sessionId: id)
      },
      player: player)
    playback.play(session, startNanoseconds: hit.startNanoseconds)
    await assertEventually { playback.playingSessionId == sessionId }
    XCTAssertNil(playback.errorMessage)
    playback.stopPlayback()
    let beginning = try sampleImported(preparation: preparation, sessionId: sessionId, frame: 0)
    let later = try sampleImported(preparation: preparation, sessionId: sessionId, frame: 24_000)
    XCTAssertEqual(beginning.count, later.count)
    XCTAssertGreaterThan(beginning.count, 1)
    XCTAssertNotEqual(beginning, later)
    XCTAssertFalse(beginning.allSatisfy { $0 == 0 } && later.allSatisfy { $0 == 0 })
    let renamed = await transcripts.renameSpeaker(trackId: machine.trackId, label: " Dana ")
    XCTAssertTrue(renamed, transcripts.message ?? "")
    let named = try XCTUnwrap(transcripts.segments.first { $0.sequence == machine.sequence })
    XCTAssertEqual(named.speakerLabel, "Dana")
    XCTAssertTrue(named.speakerNamedByUser)
    XCTAssertEqual(named.verbatimText, machine.verbatimText)
    let savedCorrection = await transcripts.correct(named, text: "The recording stays on this Mac.")
    XCTAssertTrue(savedCorrection, transcripts.message ?? "")
    let corrected = try XCTUnwrap(transcripts.segments.first { $0.sequence == machine.sequence })
    XCTAssertEqual(corrected.verbatimText, machine.verbatimText)
    XCTAssertEqual(corrected.effectiveText, "The recording stays on this Mac.")
    XCTAssertTrue(corrected.corrected)
    XCTAssertEqual(corrected.speakerLabel, "Dana")
    await transcripts.search("stays on this Mac")
    XCTAssertTrue(
      transcripts.searchResults.contains {
        $0.sessionId == sessionId
          && $0.effectiveText.localizedCaseInsensitiveContains("stays on this Mac")
      })
    let markdown = root.appendingPathComponent("Dropped.md")
    let wroteMarkdown = await transcripts.export(format: .markdown, to: markdown)
    XCTAssertTrue(wroteMarkdown, transcripts.message ?? "")
    let markdownText = try String(contentsOf: markdown, encoding: .utf8)
    XCTAssertTrue(markdownText.localizedCaseInsensitiveContains("Dana"))
    XCTAssertTrue(markdownText.localizedCaseInsensitiveContains("stays on this Mac"))
    let jsonURL = root.appendingPathComponent("Dropped.json")
    let wroteJSON = await transcripts.export(format: .transcriptJson, to: jsonURL)
    XCTAssertTrue(wroteJSON, transcripts.message ?? "")
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
    let exportedSegments = try XCTUnwrap(document["segments"] as? [[String: Any]])
    let exported = try XCTUnwrap(
      exportedSegments.first {
        ($0["effective_text"] as? String) == "The recording stays on this Mac."
      })
    XCTAssertEqual(exported["verbatim_text"] as? String, machine.verbatimText)
    XCTAssertNotEqual(exported["verbatim_text"] as? String, exported["effective_text"] as? String)
    let exportedAudio = root.appendingPathComponent("Exported.m4a")
    let wroteAudio = await transcripts.export(.original, to: exportedAudio)
    XCTAssertTrue(wroteAudio, transcripts.message ?? "")
    XCTAssertEqual(try Data(contentsOf: exportedAudio), managedBefore)
    XCTAssertEqual(try Data(contentsOf: managedCopy), managedBefore)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, modelBytes)
    withExtendedLifetime(store) {}
    withExtendedLifetime(live) {}
    withExtendedLifetime(recovery) {}
    withExtendedLifetime(window) {}
    withExtendedLifetime(drag) {}
    withExtendedLifetime(scheduler) {}
    withExtendedLifetime(speech) {}
    withExtendedLifetime(pressure) {}
    withExtendedLifetime(playback) {}
    withExtendedLifetime(player) {}
  }

  private func dropDestination(in root: NSView) -> NSView? {
    var matched: NSView?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if view.accessibilityIdentifier() == "Audio drop",
        view.responds(to: NSSelectorFromString("performDragOperation:"))
      {
        matched = view
        return
      }
      for child in view.subviews {
        walk(child)
      }
    }
    walk(root)
    return matched
  }

  private func destinationDragOperation(
    _ selectorName: String, on view: NSView, info: NSDraggingInfo
  ) -> UInt {
    let selector = NSSelectorFromString(selectorName)
    guard view.responds(to: selector) else { return 0 }
    typealias Reply = @convention(c) (AnyObject, Selector, AnyObject) -> UInt
    let function = unsafeBitCast(view.method(for: selector), to: Reply.self)
    return function(view, selector, info)
  }

  private func destinationDragAccepted(
    _ selectorName: String, on view: NSView, info: NSDraggingInfo
  ) -> Bool {
    let selector = NSSelectorFromString(selectorName)
    guard view.responds(to: selector) else { return false }
    typealias Reply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    let function = unsafeBitCast(view.method(for: selector), to: Reply.self)
    return function(view, selector, info)
  }

  private func destinationDragEnded(
    _ selectorName: String, on view: NSView, info: NSDraggingInfo
  ) {
    let selector = NSSelectorFromString(selectorName)
    guard view.responds(to: selector) else { return }
    typealias Reply = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    let function = unsafeBitCast(view.method(for: selector), to: Reply.self)
    function(view, selector, info)
  }

  private func focusProxyProbe(in root: NSView) -> [String] {
    focusProxies(in: root).map { proxy in
      let hit = hitTest(at: proxy)
      let hitTexts = (hit as? NSObject).map { accessibilityTexts(of: $0) } ?? []
      return
        "frame=\(proxy.frame) texts=\(accessibilityTexts(of: proxy)) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") hitTexts=\(hitTexts)"
    }
  }

  private func confirmControl(in root: NSView) -> NSObject? {
    var pending: [NSObject] = [root]
    var seen = Set<ObjectIdentifier>()
    while let current = pending.popLast() {
      guard seen.insert(ObjectIdentifier(current)).inserted else { continue }
      if accessibilityTexts(of: current).contains(confirmControlLabel) {
        return current
      }
      pending.append(contentsOf: accessibilityDescendants(of: current))
    }
    for proxy in focusProxies(in: root) {
      if accessibilityTexts(of: proxy).contains(confirmControlLabel) {
        return proxy
      }
      if let hit = hitTest(at: proxy) as? NSObject,
        accessibilityTexts(of: hit).contains(confirmControlLabel)
      {
        return hit
      }
    }
    return leftBannerConfirmProxy(in: root)
  }

  private let cancelControlLabel = "Cancel audio import"

  /// The AppKit Cancel button the drop host reveals beside Import.
  private func bannerCancelButton(in root: NSView) -> NSButton? {
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton, !(button is NSPopUpButton),
        button.accessibilityLabel() == cancelControlLabel,
        button.isHidden == false,
        button.isHiddenOrHasHiddenAncestor == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  /// Seatbelt profile matching the local-only harness: default allow, IP denied.
  /// `sandbox_init` cannot be lifted, so later tests in this process also lose IP.
  private func denyInternetProtocol() throws {
    let profile =
      "(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound (local ip))(deny network-bind (local ip))"
    var error: UnsafeMutablePointer<CChar>?
    let status = profile.withCString { openScribeProofSandboxInit($0, 0, &error) }
    let detail = error.map { String(cString: $0) } ?? ""
    if error != nil {
      openScribeProofSandboxFreeError(error)
    }
    if status != 0 {
      throw NSError(
        domain: "OpenScribeProof", code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "sandbox_init failed" : detail])
    }
  }

  private func loopbackConnectErrno() -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return errno }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(9).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return connected == 0 ? 0 : errno
  }

  private func hostedSearchField(in root: NSView) -> NSSearchField? {
    var matched: NSSearchField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSSearchField {
        let label = field.accessibilityLabel() ?? ""
        let placeholder = field.placeholderString ?? ""
        let identifier = field.accessibilityIdentifier() ?? ""
        let named =
          label == "Search transcripts" || placeholder == "Search transcripts"
          || identifier == "Search transcripts"
        if named, field.isHidden == false, field.isHiddenOrHasHiddenAncestor == false,
          field.frame.width > 1, field.frame.height > 1
        {
          matched = field
        }
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func hostedResultButtons(containing text: String, in root: NSView) -> [NSButton] {
    var matched: [NSButton] = []
    func walk(_ view: NSView) {
      if let button = view as? NSButton, !(button is NSPopUpButton) {
        let label = button.accessibilityLabel() ?? ""
        let visible =
          button.isHidden == false && button.isHiddenOrHasHiddenAncestor == false
          && button.frame.width > 1 && button.frame.height > 1
        if visible,
          button.title.localizedCaseInsensitiveContains(text)
            || label.localizedCaseInsensitiveContains(text)
        {
          matched.append(button)
        }
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private let playConversationLabel = "Play conversation audio"

  private func toolbarStopButton(in window: NSWindow) -> NSButton? {
    guard let root = window.contentView?.superview ?? window.contentView else { return nil }
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton, !(button is NSPopUpButton),
        button.accessibilityIdentifier() == "Toolbar stop",
        button.isHidden == false,
        button.isHiddenOrHasHiddenAncestor == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func toolbarRecordButton(in window: NSWindow) -> NSButton? {
    guard let root = window.contentView?.superview ?? window.contentView else { return nil }
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton, !(button is NSPopUpButton),
        button.accessibilityIdentifier() == "Toolbar record",
        button.isHidden == false,
        button.isHiddenOrHasHiddenAncestor == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func menuBarStopButton(in root: NSView) -> NSButton? {
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton, !(button is NSPopUpButton),
        button.accessibilityIdentifier() == "Menu bar stop",
        button.isHidden == false,
        button.isHiddenOrHasHiddenAncestor == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func menuBarRecordButton(in root: NSView) -> NSButton? {
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton, !(button is NSPopUpButton),
        button.accessibilityIdentifier() == "Menu bar record",
        button.isHidden == false,
        button.isHiddenOrHasHiddenAncestor == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func recordConversationButton(in root: NSView) -> NSButton? {
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton, !(button is NSPopUpButton),
        button.accessibilityIdentifier() == "Record conversation",
        button.isHidden == false,
        button.isHiddenOrHasHiddenAncestor == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func hostedActionButton(labeled label: String, in root: NSView) -> NSButton? {
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton, !(button is NSPopUpButton),
        button.accessibilityLabel() == label,
        button.isHidden == false,
        button.isHiddenOrHasHiddenAncestor == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func hostedLabeledField(labeled label: String, in root: NSView) -> NSTextField? {
    var matched: NSTextField?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let field = view as? NSTextField,
        field.accessibilityLabel() == label,
        field.isHidden == false,
        field.isHiddenOrHasHiddenAncestor == false,
        field.frame.width > 1,
        field.frame.height > 1
      {
        matched = field
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func reviewProbe(in root: NSView) -> String {
    var lines: [String] = []
    func walk(_ view: NSView) {
      if view.accessibilityIdentifier() == "Imported review"
        || view.accessibilityIdentifier() == "Speaker review"
        || view.accessibilityIdentifier() == "Correct transcript text"
      {
        lines.append(
          "banner id=\(view.accessibilityIdentifier() ?? "") frame=\(view.frame) hidden=\(view.isHidden)"
        )
      }
      if let button = view as? NSButton {
        lines.append(
          "button label=\(button.accessibilityLabel() ?? "") title=\(button.title) frame=\(button.frame) hidden=\(button.isHidden) ancestor=\(button.isHiddenOrHasHiddenAncestor) enabled=\(button.isEnabled)"
        )
      } else if let field = view as? NSTextField {
        let label = field.accessibilityLabel() ?? ""
        if label == "Person's name" || label == "Corrected text" || label == "Machine reading" {
          lines.append(
            "field label=\(label) value=\(field.stringValue) frame=\(field.frame) hidden=\(field.isHidden) ancestor=\(field.isHiddenOrHasHiddenAncestor)"
          )
        }
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return lines.joined(separator: "\n")
  }

  /// The AppKit Play button the host reveals after a confirmed import is selected.
  private func playConversationButton(in root: NSView) -> NSButton? {
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton, !(button is NSPopUpButton),
        button.accessibilityLabel() == playConversationLabel,
        button.isHidden == false,
        button.isHiddenOrHasHiddenAncestor == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return matched
  }

  private func playProbe(in root: NSView) -> String {
    var lines: [String] = []
    func walk(_ view: NSView) {
      let name = String(describing: type(of: view))
      if name.contains("ImportedPlayback") || view.accessibilityIdentifier() == "Imported playback"
        || view is NSButton
      {
        let label = (view as? NSButton)?.accessibilityLabel() ?? ""
        lines.append(
          "\(name) frame=\(view.frame) hidden=\(view.isHidden) enabled=\((view as? NSButton)?.isEnabled.description ?? "") label=\(label) id=\(view.accessibilityIdentifier() ?? "")"
        )
      }
      for child in view.subviews { walk(child) }
    }
    walk(root)
    return lines.joined(separator: "\n")
  }

  /// The AppKit Import button the drop host reveals after a file is staged.
  private func bannerImportButton(in root: NSView) -> NSButton? {
    var matched: NSButton?
    func walk(_ view: NSView) {
      if matched != nil { return }
      if let button = view as? NSButton,
        button.accessibilityLabel() == confirmControlLabel,
        button.isHidden == false,
        button.frame.width > 1,
        button.frame.height > 1
      {
        matched = button
      }
      for child in view.subviews {
        walk(child)
      }
    }
    walk(root)
    return matched
  }

  private func hostedLabels(in root: NSView) -> [String] {
    var labels: [String] = []
    func walk(_ view: NSView) {
      if let label = view.accessibilityLabel(), !label.isEmpty {
        labels.append(label)
      }
      if let text = view as? NSTextField, !text.stringValue.isEmpty {
        labels.append(text.stringValue)
      }
      for child in view.subviews {
        walk(child)
      }
    }
    walk(root)
    return labels
  }

  private func bannerProbe(in root: NSView) -> [String] {
    var lines: [String] = []
    func walk(_ view: NSView) {
      let name = String(describing: type(of: view))
      if name.contains("DropConfirmation") || view.accessibilityIdentifier() == "Drop confirmation"
        || view is NSButton
      {
        let label = (view as? NSButton)?.accessibilityLabel() ?? ""
        lines.append(
          "\(name) frame=\(view.frame) hidden=\(view.isHidden) label=\(label) id=\(view.accessibilityIdentifier() ?? "")"
        )
      }
      for child in view.subviews {
        walk(child)
      }
    }
    walk(root)
    return lines
  }

  /// The banner's Import button is the left of the two wide focus proxies at the
  /// top of the detail column once layout has given them a positive origin.
  private func settledBannerConfirmProxy(in root: NSView) -> NSView? {
    let banner = focusProxies(in: root).filter { proxy in
      let frame = proxy.frame
      return frame.minY >= 0 && frame.minY < 40 && frame.height <= 26 && frame.width >= 40
    }
    guard banner.count == 2 else { return nil }
    return banner.min { $0.frame.minX < $1.frame.minX }
  }

  /// The banner's Import button is the left of the two focus proxies at the top
  /// of the detail column. This hosting session does not publish that button as
  /// an `NSButton`, and its accessibility label stays unread until the window is
  /// key. Cancel is the proxy to its right. The lower Import menu is taller.
  private func leftBannerConfirmProxy(in root: NSView) -> NSView? {
    let banner = focusProxies(in: root).filter { $0.frame.minY < 40 && $0.frame.height <= 26 }
    guard banner.count == 2 else { return nil }
    return banner.min { $0.frame.minX < $1.frame.minX }
  }

  private let confirmControlLabel = "Confirm audio import"

  private func focusProxies(in root: NSView) -> [NSView] {
    var proxies: [NSView] = []
    func walk(_ view: NSView) {
      if String(describing: type(of: view)).contains("KeyViewProxy") {
        proxies.append(view)
      }
      for child in view.subviews {
        walk(child)
      }
    }
    walk(root)
    return proxies
  }

  private func hitTest(at view: NSView) -> Any? {
    guard let window = view.window else { return nil }
    let screen = window.convertPoint(
      toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    return view.accessibilityHitTest(screen)
  }

  private func accessibilityTexts(of object: NSObject) -> [String] {
    var texts: [String] = []
    if let view = object as? NSView, let label = view.accessibilityLabel(), !label.isEmpty {
      texts.append(label)
    }
    if let element = object as? NSAccessibilityElement, let label = element.accessibilityLabel(),
      !label.isEmpty
    {
      texts.append(label)
    }
    if let button = object as? any NSAccessibilityButton, let label = button.accessibilityLabel(),
      !label.isEmpty
    {
      texts.append(label)
    }
    for attribute: NSAccessibility.Attribute in [.description, .title, .value, .roleDescription] {
      if let text = accessibilityAttribute(object, attribute) as? String, !text.isEmpty {
        texts.append(text)
      }
    }
    return texts
  }

  private func accessibilityDescendants(of object: NSObject) -> [NSObject] {
    var descendants: [NSObject] = []
    if let view = object as? NSView {
      descendants.append(contentsOf: view.subviews)
      if let children = view.accessibilityChildren() {
        descendants.append(contentsOf: children.compactMap { $0 as? NSObject })
      }
    } else if let element = object as? NSAccessibilityElement {
      if let children = element.accessibilityChildren() {
        descendants.append(contentsOf: children.compactMap { $0 as? NSObject })
      }
    }
    if let children = accessibilityAttribute(object, .children) as? [Any] {
      descendants.append(contentsOf: children.compactMap { $0 as? NSObject })
    }
    return descendants
  }

  private func pressConfirmControl(_ object: NSObject) {
    if let button = object as? NSButton {
      button.performClick(nil)
      return
    }
    if let button = object as? any NSAccessibilityButton {
      XCTAssertTrue(button.accessibilityPerformPress())
      return
    }
    if let view = object as? NSView {
      if view.accessibilityPerformPress() { return }
      click(view)
      return
    }
    if let element = object as? NSAccessibilityElement {
      XCTAssertTrue(element.accessibilityPerformPress())
      return
    }
    accessibilityPerform(object, .press)
  }

  private func click(_ view: NSView) {
    guard let window = view.window else {
      XCTFail("Confirm control is not in a window")
      return
    }
    let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    func mouseEvent(_ type: NSEvent.EventType, pressure: Float) -> NSEvent? {
      NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: pressure)
    }
    guard let down = mouseEvent(.leftMouseDown, pressure: 1),
      let up = mouseEvent(.leftMouseUp, pressure: 0)
    else {
      XCTFail("Could not build a click for the confirm control")
      return
    }
    window.sendEvent(down)
    window.sendEvent(up)
  }

  /// SwiftUI's hosted controls are private accessibility objects. The typed
  /// AppKit properties do not see them, so the walk uses the attribute API.
  private func accessibilityAttribute(_ object: NSObject, _ attribute: NSAccessibility.Attribute)
    -> Any?
  {
    object.accessibilityAttributeValue(attribute)
  }

  private func accessibilityPerform(_ object: NSObject, _ action: NSAccessibility.Action) {
    object.accessibilityPerformAction(action)
  }

  private func sampleImported(
    preparation: NativeRecordingPreparation, sessionId: String, frame: Int64
  ) throws -> [Float] {
    let lease = try preparation.leaseImportedPlayback(sessionId: sessionId)
    let serialized = lease.playbackPath()
    XCTAssertTrue(serialized.hasPrefix("v3;"), serialized)
    let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: serialized)
    let source = try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt)
    let decoder = try CallbackCAFDecoder(
      source: source, fileTypeHint: receipt.fileTypeHint, onClose: {})
    defer { decoder.close() }
    if frame > 0 { try decoder.seek(toFrame: frame) }
    let buffer = try XCTUnwrap(decoder.read(maximumFrames: 256))
    XCTAssertEqual(buffer.format.channelCount, 2)
    let samples = Array(
      UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    withExtendedLifetime(lease) {}
    return samples
  }

  private func packageFileBytes(_ root: URL) throws -> [String: Data] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [:] }
    var files: [String: Data] = [:]
    for case let url as URL in enumerator {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
      files[relative] = try Data(contentsOf: url)
    }
    return files
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

  /// Turns the main queue without laying the host out again. A layout pass
  /// during the drop discards the banner; the later turn has to mount it.
  private func waitUntilPumped(
    _ host: NSView,
    window: NSWindow,
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    _ predicate: () -> Bool
  ) async -> Bool {
    let started = DispatchTime.now().uptimeNanoseconds
    while true {
      let turned = expectation(description: "hosted turn")
      DispatchQueue.main.async { turned.fulfill() }
      await fulfillment(of: [turned], timeout: 1)
      window.displayIfNeeded()
      if predicate() { return true }
      if DispatchTime.now().uptimeNanoseconds - started >= timeoutNanoseconds {
        return false
      }
    }
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

private struct IdleContextFrames: ContextFrameCapturing {
  func captureFrame(_ target: ContextCaptureTarget) async throws -> CGImage {
    throw CancellationError()
  }
}

/// A file drop whose pasteboard carries the public types Finder writes.
/// It does not install an item provider.
private final class FinderFileDrag: NSObject, NSDraggingInfo {
  let fileURL: URL
  let draggingDestinationWindow: NSWindow?
  let draggingLocation: NSPoint
  let wroteFileURL: Bool
  private(set) var didEnumerateItems = false
  private let pasteboard: NSPasteboard

  init(fileURL: URL, window: NSWindow?, location: NSPoint) {
    self.fileURL = fileURL
    self.draggingDestinationWindow = window
    self.draggingLocation = location
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("open-scribe-finder-drop-\(UUID().uuidString)"))
    let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    pasteboard.clearContents()
    let wrote = pasteboard.writeObjects([fileURL as NSURL])
    pasteboard.addTypes([filenames], owner: nil)
    pasteboard.setPropertyList([fileURL.path], forType: filenames)
    self.wroteFileURL = wrote
    self.pasteboard = pasteboard
    super.init()
  }

  var draggingSourceOperationMask: NSDragOperation { .copy }
  var draggedImageLocation: NSPoint { draggingLocation }
  var draggedImage: NSImage? { nil }
  var draggingPasteboard: NSPasteboard { pasteboard }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }

  func slideDraggedImage(to screenPoint: NSPoint) {}

  override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
    nil
  }

  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }

  func resetSpringLoading() {}

  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions,
    for view: NSView?,
    classes classArray: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {
    didEnumerateItems = true
  }
}

/// An in-process file drag. The hosted drop view reads `NSDraggingItem.item`
/// and the dragging pasteboard; a new item otherwise reports only its writer.
private final class AudioFileDrag: NSObject, NSDraggingInfo {
  let fileURL: URL
  let provider: NSItemProvider
  let draggingDestinationWindow: NSWindow?
  let draggingLocation: NSPoint
  private let pasteboard: NSPasteboard
  private(set) var requestedClasses: [String] = []

  init(fileURL: URL, window: NSWindow?, location: NSPoint) {
    self.fileURL = fileURL
    self.provider = NSItemProvider(object: fileURL as NSURL)
    self.draggingDestinationWindow = window
    self.draggingLocation = location
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("open-scribe-audio-drop-\(UUID().uuidString)"))
    pasteboard.writeObjects([fileURL as NSURL])
    self.pasteboard = pasteboard
    super.init()
  }

  var draggingSourceOperationMask: NSDragOperation { .copy }
  var draggedImageLocation: NSPoint { draggingLocation }
  var draggedImage: NSImage? { nil }
  var draggingPasteboard: NSPasteboard { pasteboard }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }

  func slideDraggedImage(to screenPoint: NSPoint) {}

  override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
    nil
  }

  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }

  func resetSpringLoading() {}

  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions,
    for view: NSView?,
    classes classArray: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {
    requestedClasses.append(classArray.map { String(describing: $0) }.joined(separator: ","))
    var stop = ObjCBool(false)
    let wantsProvider = classArray.contains { $0 == NSItemProvider.self }
    if wantsProvider {
      block(providerItem(), 0, &stop)
      if stop.boolValue { return }
    }
    let readable = classArray.filter { $0.conforms(to: NSPasteboardReading.self) }
    guard !readable.isEmpty else { return }
    let objects = pasteboard.readObjects(forClasses: readable, options: searchOptions) ?? []
    for (offset, object) in objects.enumerated() {
      guard let writer = object as? any NSPasteboardWriting else { continue }
      let item = NSDraggingItem(pasteboardWriter: writer)
      item.draggingFrame = NSRect(origin: draggingLocation, size: NSSize(width: 64, height: 64))
      block(item, wantsProvider ? offset + 1 : offset, &stop)
      if stop.boolValue { return }
    }
  }

  private func providerItem() -> NSDraggingItem {
    let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
    item.draggingFrame = NSRect(origin: draggingLocation, size: NSSize(width: 64, height: 64))
    if let field = class_getInstanceVariable(NSDraggingItem.self, "_item") {
      object_setIvar(item, field, provider)
    }
    return item
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
