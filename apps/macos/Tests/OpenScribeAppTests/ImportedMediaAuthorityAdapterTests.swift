@preconcurrency import AVFoundation
import Darwin
import Foundation
import XCTest

@testable import OpenScribeApp

@MainActor
final class ImportedMediaAuthorityAdapterTests: XCTestCase {
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

  func testBoundedMonoM4AImportsAsRecoverableManagedCAFWithoutChangingOriginal() async throws {
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
    let controller = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
    XCTAssertNoThrow(try controller.leaseImportedPlayback(sessionId: saved.sessionId))
    XCTAssertFalse(runtime.isSnapshotStale)

    let policy = nativeImportPolicy()
    XCTAssertThrowsError(
      try BoundedAudioImport.prepare(
        sourceURL: originalURL,
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
    XCTAssertThrowsError(
      try BoundedAudioImport.prepare(
        sourceURL: originalURL,
        policy: NativeImportPolicy(
          maximumSourceBytes: policy.maximumSourceBytes,
          maximumManagedBytes: 8_192,
          maximumDurationNanoseconds: policy.maximumDurationNanoseconds,
          maximumManagedSamples: policy.maximumManagedSamples
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? BoundedAudioImportError,
        .decodedTooLarge(maximum: 8_192)
      )
    }
  }

  func testSizeFailureExplainsPolicyWithoutAddingASession() async {
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { URL(fileURLWithPath: "/tmp/large.m4a") },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: { _, _ in
        throw BoundedAudioImportError.sourceTooLarge(
          actual: 1_610_612_736,
          maximum: nativeImportPolicy().maximumSourceBytes
        )
      }
    )
    adapter.chooseAndImport()
    await assertEventually { adapter.phase == .failed }
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertTrue(adapter.statusMessage?.contains("1536.0 MiB") == true)
    XCTAssertTrue(adapter.statusMessage?.contains("1024 MiB") == true)
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
    readyForReview: true
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
