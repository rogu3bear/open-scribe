import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import OpenScribeApp

@MainActor
final class TranscriptLibraryModelTests: XCTestCase {
  func testTranscriptSearchUsesReviewedTextAndPreservesPassageIdentityAndOrder() {
    let rows = [
      segment(
        0, 0, "Dana", named: true, "Approve the café budget.", machine: "Reject the old budget."),
      segment(1, 3_000_000_000, "Morgan", named: true, "The next review is Friday."),
      segment(2, 6_000_000_000, "Dana", named: true, "Café opens Monday."),
    ]
    let matches = TranscriptSearch.matching(rows, query: "  CAFE \n")
    XCTAssertEqual(matches.map(\.id), [rows[0].id, rows[2].id])
    XCTAssertEqual(matches.map(\.startNanoseconds), [0, 6_000_000_000])
    XCTAssertTrue(TranscriptSearch.matching(rows, query: "Reject").isEmpty)
    XCTAssertEqual(TranscriptSearch.matching(rows, query: " \n"), rows)
    XCTAssertEqual(TranscriptSearch.matching(Array(rows.suffix(1)), query: "café"), [rows[2]])
    let draft = segment(
      3, 9_000_000_000, "Dana", named: true, "Café secret draft", finality: "draft")
    XCTAssertTrue(TranscriptSearch.matching(rows + [draft], query: "secret").isEmpty)
    XCTAssertEqual(
      TranscriptSearch.matching(rows + [draft], query: "café").map(\.id),
      [rows[0].id, rows[2].id])
    let value = "Café — café ☕"
    XCTAssertEqual(
      TranscriptSearch.ranges(in: value, query: "CAFE").map { String(value[$0]) },
      ["Café", "café"])
    XCTAssertTrue(TranscriptSearch.ranges(in: value, query: " \n").isEmpty)
  }

  func testReviewReaderRendersAtNarrowAndWideWidths() throws {
    let rows = [
      segment(
        0, 0, "Dana", named: true, "We agreed to send the revised proposal on Friday.",
        machine: "We agreed to send the revised proposal on Monday."),
      segment(
        1, 7_000_000_000, "Morgan", named: true,
        "Yes. Keep the original recording with the reviewed transcript."),
    ]
    let model = TranscriptLibraryModel(preview: .final, segments: rows, speakers: [])
    for width in [360.0, 720.0] {
      for scheme in [ColorScheme.light, .dark] {
        let view = TranscriptReader(
          sessionId: "review-fixture", transcripts: model, canSeek: true,
          isPlaybackActive: false, playbackPosition: { nil }, onSeek: { _ in },
          onCorrect: { _ in }, onFollowPlayback: { _ in }
        )
        .padding(20)
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        XCTAssertLessThanOrEqual(size.width, width + 1)
        XCTAssertGreaterThan(size.height, 180)
        guard let directory = ProcessInfo.processInfo.environment["OPEN_SCRIBE_RENDER_DIR"] else {
          continue
        }
        // ImageRenderer substitutes placeholders for AppKit text fields and
        // buttons. Capture an offscreen native view without opening a scene.
        let window = NSWindow(
          contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        window.close()
        try png.write(
          to: URL(fileURLWithPath: directory)
            .appendingPathComponent(
              "review-reader-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
      }
    }
  }

  func testReviewEditorSheetsFitTheirNativeWidths() throws {
    let store = RuntimeLibraryStore(
      snapshotProvider: { NativeRuntimeLibrarySnapshot(currentSession: nil, savedSessions: []) },
      startsPolling: false, refreshesImmediately: false)
    let conversation = session("review-fixture", calibrated: false, sources: [])
    for scheme in [ColorScheme.light, .dark] {
      try captureEditorSheet(
        ConversationRenameSheet(session: conversation, store: store, onClose: {}),
        width: 420, name: "rename", scheme: scheme)
      try captureEditorSheet(
        ConversationDetailsSheet(
          session: conversation, declaration: nil, store: store, onSaved: {}, onClose: {}),
        width: 460, name: "details", scheme: scheme)
    }
  }

  private func captureEditorSheet<Content: View>(
    _ content: Content, width: CGFloat, name: String, scheme: ColorScheme
  ) throws {
    let host = NSHostingView(
      rootView: content.background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme))
    let size = host.fittingSize
    XCTAssertEqual(size.width, width, accuracy: 1)
    XCTAssertGreaterThan(size.height, 100)
    guard let directory = ProcessInfo.processInfo.environment["OPEN_SCRIBE_RENDER_DIR"] else {
      return
    }
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.contentView = host
    host.setFrameSize(size)
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    window.close()
    try png.write(
      to: URL(fileURLWithPath: directory)
        .appendingPathComponent("review-\(name)-\(scheme == .dark ? "dark" : "light").png"))
  }

  func testSpeakerRenameAndResetRefreshAnUnchangedSearchQuery() async {
    let library = TranscriptTimingLibraryFake(reviewedName: "Dana")
    let model = TranscriptLibraryModel(library: library)
    await model.load(session: session("valid", calibrated: false, sources: []))
    await model.search("speaker:Dana")
    XCTAssertEqual(model.searchResults.count, 1)
    let renamed = await model.renameNamedSpeaker(
      sessionId: "valid", speakerId: "person", label: "Morgan")
    XCTAssertTrue(renamed)
    XCTAssertTrue(model.searchResults.isEmpty)
    await model.search("speaker:Morgan")
    XCTAssertEqual(model.searchResults.count, 1)
    let reset = await model.assignSpeaker(
      sessionId: "valid", segment: model.segments[0], assignment: .source)
    XCTAssertTrue(reset)
    XCTAssertTrue(model.searchResults.isEmpty)
  }

  func testMergeAndSplitCallTheLibraryAndKeepAssignmentHistoryWords() async {
    let library = TranscriptTimingLibraryFake()
    let model = TranscriptLibraryModel(library: library)
    await model.load(session: session("valid", calibrated: false, sources: []))
    let merged = await model.mergeNamedSpeakers(
      sessionId: "valid", keepId: "dana", absorbId: "morgan")
    XCTAssertTrue(merged)
    XCTAssertEqual(library.mergedKeep, "dana")
    XCTAssertEqual(library.mergedAbsorb, "morgan")
    guard let segment = model.segments.first else {
      XCTFail("The loaded transcript has no passage")
      return
    }
    let split = await model.splitNamedSpeaker(
      sessionId: "valid", speakerId: "dana", segment: segment, label: "Mina")
    XCTAssertTrue(split)
    XCTAssertEqual(library.splitSpeakerId, "dana")
    XCTAssertEqual(library.splitSequence, 0)
    XCTAssertEqual(library.splitLabel, "Mina")
    let history = NativeNamedSpeakerTurnHistory(
      revisionId: "fixture", sequence: 1, trackId: "track", sourceDefaultLabel: "Unknown speaker",
      revisions: [
        NativeNamedSpeakerTurnRevision(
          label: "Morgan", origin: .human, speakerId: "morgan", createdAtMs: 1),
        NativeNamedSpeakerTurnRevision(
          label: "Dana", origin: .human, speakerId: "dana", createdAtMs: 2),
        NativeNamedSpeakerTurnRevision(
          label: "Unknown speaker", origin: .sourceDefault, speakerId: nil, createdAtMs: 3),
      ])
    XCTAssertEqual(
      TranscriptLibraryModel.namedSpeakerTurnHistoryText(for: history),
      """
      Source default: Unknown speaker
      Morgan, named by you
      Dana, named by you
      Unknown speaker, source name
      """)
  }

  func testSpeakerCompletionRefreshesTheLatestQueryWithoutChangingANewerDocument() async {
    let checkpoint = MetadataCheckpoint()
    defer { checkpoint.release.signal() }
    let library = TranscriptTimingLibraryFake(
      reviewedName: "Dana",
      beforeSpeakerMutation: {
        checkpoint.entered.signal()
        checkpoint.release.wait()
      })
    let model = TranscriptLibraryModel(library: library)
    await model.load(session: session("valid", calibrated: false, sources: []))
    let editing = Task {
      await model.renameNamedSpeaker(sessionId: "valid", speakerId: "person", label: "Morgan")
    }
    await Task.detached { checkpoint.waitUntilEntered() }.value
    await model.load(session: session("newer", calibrated: false, sources: []))
    await model.search("speaker:Morgan")
    XCTAssertTrue(model.searchResults.isEmpty)
    checkpoint.release.signal()
    let saved = await editing.value
    XCTAssertTrue(saved)
    XCTAssertEqual(model.sessionId, "newer")
    XCTAssertEqual(model.searchResults.count, 1)
  }

  private final class MetadataCheckpoint: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasHeld = false
    func waitUntilEntered() { entered.wait() }
    func enteredBeforeTimeout() -> Bool {
      entered.wait(timeout: .now() + 2) == .success
    }
    func holdOnce() {
      let shouldHold = lock.withLock {
        guard !hasHeld else { return false }
        hasHeld = true
        return true
      }
      guard shouldHold else { return }
      entered.signal()
      _ = release.wait(timeout: .now() + 3)
    }
  }

  func testImportedReviewRecordsUnresolvedSpeakersWithoutACalibratedModel() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("diarize-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.caf")
    try Self.recoverableCaf(frames: 4_800).write(to: source)
    let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
    let preparation = try NativeRecordingPreparation.open(managedRoot: libraryRoot.path)
    let imported = try preparation.importRecoverableCaf(
      title: "Imported review", sourcePath: source.path)
    let before = try Self.mediaDigests(under: libraryRoot)
    let library = try NativeTranscriptLibrary.open(managedRoot: libraryRoot.path)
    let first = try library.prepareSpeakerDiarization(sessionId: imported.sessionId)
    XCTAssertTrue(first.inserted)
    XCTAssertEqual(first.clusteringState, "unavailable")
    XCTAssertEqual(first.reason, "no calibrated diarization model")
    XCTAssertEqual(first.algorithmId, "topology-before-clustering-v1")
    XCTAssertEqual(first.tracks.count, 1)
    XCTAssertEqual(first.tracks[0].sourceKind, "imported_audio")
    XCTAssertEqual(first.tracks[0].disposition, "unresolved")
    XCTAssertEqual(first.tracks[0].label, "Unknown speaker")
    XCTAssertEqual(first.tracks[0].labelOrigin, "source_default")
    let model = TranscriptLibraryModel(library: library)
    await model.load(session: session(imported.sessionId, calibrated: false, sources: []))
    XCTAssertEqual(
      model.speakerDiarizationText,
      "Speakers follow the audio source. Voice diarization is unavailable without a calibrated model."
    )
    XCTAssertEqual(model.speakers.first?.label, "Unknown speaker")
    XCTAssertEqual(model.speakers.first?.namedByUser, false)
    XCTAssertNil(model.message)
    let second = try library.prepareSpeakerDiarization(sessionId: imported.sessionId)
    XCTAssertFalse(second.inserted)
    XCTAssertEqual(second.runId, first.runId)
    XCTAssertEqual(model.segments.map(\.effectiveText), [])
    XCTAssertEqual(try library.inspectProvenance(sessionId: imported.sessionId), [])
    XCTAssertEqual(try Self.mediaDigests(under: libraryRoot), before)
    let trackId = try XCTUnwrap(model.speakers.first?.trackId)
    let renamed = await model.renameSpeaker(trackId: trackId, label: " Dana ")
    XCTAssertTrue(renamed)
    XCTAssertNil(model.message)
    XCTAssertFalse(model.messageIsFailure)
    XCTAssertEqual(model.segments.map(\.effectiveText), [])
    XCTAssertEqual(model.speakers.first?.label, "Dana")
    XCTAssertEqual(model.speakers.first?.namedByUser, true)
    let reviewed = try library.prepareSpeakerDiarization(sessionId: imported.sessionId)
    XCTAssertFalse(reviewed.inserted)
    XCTAssertNotEqual(reviewed.runId, first.runId)
    XCTAssertEqual(reviewed.clusteringState, "unavailable")
    XCTAssertEqual(reviewed.reason, "no calibrated diarization model")
    XCTAssertEqual(reviewed.tracks.count, 1)
    XCTAssertEqual(reviewed.tracks[0].disposition, "unresolved")
    XCTAssertEqual(reviewed.tracks[0].label, "Dana")
    XCTAssertEqual(reviewed.tracks[0].labelOrigin, "human")
    XCTAssertEqual(try library.inspectProvenance(sessionId: imported.sessionId), [])
    XCTAssertEqual(try Self.mediaDigests(under: libraryRoot), before)
  }

  private static func append(_ value: some FixedWidthInteger, to data: inout Data) {
    withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
  }

  private static func recoverableCaf(frames: Int) -> Data {
    var data = Data()
    data.append(contentsOf: [0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00])
    data.append(contentsOf: Array("desc".utf8))
    append(Int64(32).bigEndian, to: &data)
    append(Double(48_000).bitPattern.bigEndian, to: &data)
    data.append(contentsOf: Array("lpcm".utf8))
    for value in [UInt32(2), 2, 1, 1, 16] {
      append(value.bigEndian, to: &data)
    }
    data.append(contentsOf: Array("data".utf8))
    append(Int64(-1).bigEndian, to: &data)
    append(UInt32(0).bigEndian, to: &data)
    for frame in 0..<frames {
      let sample = Int16(((frame % 997) - 498) * 31)
      append(sample.littleEndian, to: &data)
    }
    return data
  }

  private static func mediaDigests(under root: URL) throws -> [String: String] {
    let sessions = root.appendingPathComponent("Sessions")
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessions, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [:] }
    var digests: [String: String] = [:]
    for case let url as URL in enumerator {
      guard url.pathExtension == "caf" else { continue }
      let digest = SHA256.hash(data: try Data(contentsOf: url))
      digests[url.lastPathComponent] = digest.map { String(format: "%02x", $0) }.joined()
    }
    return digests
  }

  private func session(
    _ id: String, calibrated: Bool, sources: [NativeMediaSourceKind], recovered: Bool = false
  ) -> RuntimeSessionPresentation {
    RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: id, title: id, lifecycle: "ready_for_review", health: "healthy",
        elapsedSeconds: 1, journalDurable: true, mediaFilesOpen: false,
        interruptionReason: nil, recovered: recovered, hasCaptureTimeline: calibrated,
        sources: sources.map {
          NativeRuntimeSourceSnapshot(kind: $0, displayName: "Fixture", lifecycle: "sealed")
        }, playableMedia: nil))
  }

  func testMissingCaptureTimingDoesNotBlockImportsOrCalibratedCaptures() {
    XCTAssertNil(session("import", calibrated: false, sources: []).transcriptionUnavailableReason)
    XCTAssertNil(
      session("capture", calibrated: true, sources: [.microphone, .systemAudio])
        .transcriptionUnavailableReason)
    XCTAssertNil(
      session("restored", calibrated: true, sources: [.microphone], recovered: true)
        .transcriptionUnavailableReason)
    XCTAssertNotNil(
      session("single-source", calibrated: false, sources: [.microphone])
        .transcriptionUnavailableReason)
    XCTAssertNotNil(
      session("two-source", calibrated: false, sources: [.microphone, .systemAudio])
        .transcriptionUnavailableReason)
  }

  func testMissingTimingClearsPriorTranscriptAndRetainsAvailableMetadata() async {
    let library = TranscriptTimingLibraryFake()
    let model = TranscriptLibraryModel(library: library)
    let valid = session("valid", calibrated: false, sources: [])
    let historical = session("historical", calibrated: false, sources: [.microphone])
    await model.load(session: valid)
    await model.search("fixture")
    XCTAssertEqual(model.availability, .final)
    XCTAssertEqual(model.segments.first?.trackId, "valid")
    XCTAssertFalse(model.searchResults.isEmpty)
    XCTAssertEqual(model.audioOptions?.originalExtension, "caf")
    XCTAssertEqual(library.transcriptReads, 2)

    await model.load(session: historical)
    XCTAssertEqual(model.sessionId, "historical")
    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertTrue(model.segments.isEmpty)
    XCTAssertTrue(model.searchResults.isEmpty)
    XCTAssertEqual(model.availabilityText, historical.transcriptionUnavailableReason)
    XCTAssertNil(model.message)
    XCTAssertFalse(model.messageIsFailure)
    XCTAssertEqual(model.speakers.first?.trackId, "historical")
    XCTAssertEqual(model.audioOptions?.pcmTracks, ["historical"])
    XCTAssertNil(model.audioOptions?.originalExtension)
    XCTAssertEqual(
      library.transcriptReads, 2, "missing timing must not invoke transcript collection")

    let historicalRenamed = await model.renameSpeaker(trackId: "historical", label: "Fixture")
    XCTAssertTrue(historicalRenamed)
    XCTAssertEqual(model.availabilityText, historical.transcriptionUnavailableReason)
    XCTAssertEqual(library.transcriptReads, 2, "same-session edit reload retains the timing gate")

    await model.load(session: valid)
    XCTAssertNil(model.transcriptionUnavailableReason)
    XCTAssertEqual(model.availabilityText, "Final transcript")
    XCTAssertEqual(model.segments.first?.trackId, "valid")
    XCTAssertEqual(library.transcriptReads, 4)

    // Calibration can become available without changing the selected ID.
    await model.load(session: historical)
    await model.load(session: session("historical", calibrated: true, sources: [.microphone]))
    XCTAssertNil(model.transcriptionUnavailableReason)
    XCTAssertEqual(model.availability, .final)
    XCTAssertEqual(library.transcriptReads, 6)

    // Current untimed capture inventories cannot supply export options.
    // An unsuccessful metadata read must not keep the prior import's options.
    let limited = TranscriptLibraryModel(
      library: TranscriptTimingLibraryFake(rejectsHistoricalAudioOptions: true))
    await limited.load(session: valid)
    XCTAssertNotNil(limited.audioOptions)
    await limited.load(session: historical)
    XCTAssertNil(limited.audioOptions)
    XCTAssertNil(limited.message)
  }

  private func capturedSession() throws -> (
    root: URL, sessionId: String, capture: TimelineRuntimeProof.Capture
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let capture = try TimelineRuntimeProof.capture(root: root)
    _ = try TimelineRuntimeProof.verify(root: root, sessionId: capture.sessionId)
    return (root, capture.sessionId, capture)
  }

  func testDetailsSaveCompletionCannotReplaceANewerSelectedConversation() async throws {
    final class Checkpoint: @unchecked Sendable {
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      func waitUntilEntered() { entered.wait() }
    }
    let (root, sessionId, capture) = try capturedSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    let checkpoint = Checkpoint()
    let store = RuntimeLibraryStore(
      snapshotProvider: { NativeRuntimeLibrarySnapshot(currentSession: nil, savedSessions: []) },
      declareProvider: { id, participants, topic in
        checkpoint.entered.signal()
        checkpoint.release.wait()
        _ = try preparation.declareSession(
          sessionId: id,
          declaration: NativeSessionDeclaration(participants: participants, topic: topic))
      }, startsPolling: false)
    let library = TranscriptTimingLibraryFake()
    let model = TranscriptLibraryModel(library: library)
    let original = session(sessionId, calibrated: true, sources: [.microphone, .systemAudio])
    let selected = session("other-conversation", calibrated: false, sources: [])
    await model.load(session: original)
    let saving = Task {
      let saved = await store.declare(
        sessionId: sessionId, participants: ["Synthetic participant"], topic: "Saved for A")
      if saved { await model.reloadAfterDetailsSave(session: original) }
      return saved
    }
    await Task.detached { checkpoint.waitUntilEntered() }.value
    // Dismissing the old sheet does not undo a mutation already admitted to
    // Rust. A different conversation owns the presentation before it finishes.
    await model.load(session: selected)
    let before = model.segments
    let reads = library.transcriptReads
    checkpoint.release.signal()
    let saved = await saving.value
    XCTAssertTrue(saved)
    XCTAssertEqual(
      try preparation.contextDetail(sessionId: sessionId).declaration.topic, "Saved for A")
    XCTAssertEqual(model.sessionId, selected.sessionId)
    XCTAssertEqual(model.segments, before)
    XCTAssertEqual(library.transcriptReads, reads)
    let exported = await model.export(
      format: .plainText, to: root.appendingPathComponent("route-probe.txt"))
    XCTAssertTrue(exported)
    XCTAssertEqual(library.lastExportedSessionId, selected.sessionId)

    await model.load(session: original)
    let currentReads = library.transcriptReads
    await model.reloadAfterDetailsSave(session: original)
    XCTAssertEqual(
      library.transcriptReads, currentReads + 2, "the selected document still refreshes")
    withExtendedLifetime(capture) {}
  }

  func testDelayedRenameCannotDismissANewerMetadataPresentation() async throws {
    for sameConversation in [false, true] {
      let (root, sessionId, capture) = try capturedSession()
      defer { try? FileManager.default.removeItem(at: root) }
      let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
      let checkpoint = MetadataCheckpoint()
      let store = RuntimeLibraryStore(
        snapshotProvider: { NativeRuntimeLibrarySnapshot(currentSession: nil, savedSessions: []) },
        renameProvider: { id, title in
          checkpoint.entered.signal()
          checkpoint.release.wait()
          return try preparation.renameSession(sessionId: id, title: title)
        }, startsPolling: false)
      let original = session(sessionId, calibrated: true, sources: [.microphone, .systemAudio])
      let opening = ConversationMetadataPresentation(session: original)
      var presented: ConversationMetadataPresentation? = opening
      let saving = Task {
        let renamed = await store.rename(sessionId: sessionId, title: "Saved title for A")
        if renamed != nil { opening.close(&presented) }
        return renamed
      }
      await Task.detached { checkpoint.waitUntilEntered() }.value
      opening.close(&presented)
      XCTAssertNil(presented, "the originating Cancel closes its own sheet")
      let replacement = ConversationMetadataPresentation(
        session: sameConversation ? original : session("B", calibrated: false, sources: []))
      presented = replacement
      XCTAssertNotEqual(opening.id, replacement.id)
      checkpoint.release.signal()
      let saved = await saving.value
      XCTAssertEqual(saved, "Saved title for A")
      XCTAssertEqual(
        try preparation.runtimeLibrarySnapshot().savedSessions.first?.title, "Saved title for A")
      XCTAssertEqual(
        presented?.id, replacement.id,
        "the new sheet and its draft must keep their SwiftUI presentation identity")
      replacement.close(&presented)
      XCTAssertNil(presented, "the new sheet can still close itself")
      withExtendedLifetime(capture) {}
    }
  }

  func testDelayedDetailsSaveCannotDismissAReopenedSheetForTheSameConversation() async throws {
    let (root, sessionId, capture) = try capturedSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    let checkpoint = MetadataCheckpoint()
    let store = RuntimeLibraryStore(
      snapshotProvider: { NativeRuntimeLibrarySnapshot(currentSession: nil, savedSessions: []) },
      declareProvider: { id, participants, topic in
        checkpoint.entered.signal()
        checkpoint.release.wait()
        _ = try preparation.declareSession(
          sessionId: id,
          declaration: NativeSessionDeclaration(participants: participants, topic: topic))
      }, startsPolling: false)
    let original = session(sessionId, calibrated: true, sources: [.microphone, .systemAudio])
    let opening = ConversationMetadataPresentation(session: original)
    var presented: ConversationMetadataPresentation? = opening
    let saving = Task {
      let saved = await store.declare(
        sessionId: sessionId, participants: [], topic: "Saved topic A")
      if saved { opening.close(&presented) }
      return saved
    }
    await Task.detached { checkpoint.waitUntilEntered() }.value
    opening.close(&presented)
    let replacement = ConversationMetadataPresentation(session: original)
    presented = replacement
    checkpoint.release.signal()
    let saved = await saving.value
    XCTAssertTrue(saved)
    XCTAssertEqual(
      try preparation.contextDetail(sessionId: sessionId).declaration.topic, "Saved topic A")
    XCTAssertEqual(presented?.id, replacement.id, "same-session reopen is a new presentation")
    replacement.close(&presented)
    XCTAssertNil(presented)
    withExtendedLifetime(capture) {}
  }

  func testSavedRecordingReportsNoInventedTranscriptAndNamesSpeakersFromSources() async throws {
    let (root, sessionId, capture) = try capturedSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = TranscriptLibraryModel(managedRoot: root)
    await model.load(sessionId: sessionId)
    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertTrue(model.segments.isEmpty)
    XCTAssertEqual(
      model.availabilityText,
      "No transcript yet.")
    XCTAssertFalse(model.speakers.isEmpty)
    XCTAssertTrue(model.speakers.allSatisfy { !$0.namedByUser })
    let track = try XCTUnwrap(model.speakers.first)

    await model.renameSpeaker(trackId: track.trackId, label: "  Dana ")
    XCTAssertEqual(model.speakers.first { $0.trackId == track.trackId }?.label, "Dana")
    XCTAssertEqual(model.speakers.first { $0.trackId == track.trackId }?.namedByUser, true)
    await model.renameSpeaker(trackId: track.trackId, label: nil)
    XCTAssertEqual(model.speakers.first { $0.trackId == track.trackId }, track)
    let emptyNameAccepted = await model.renameSpeaker(trackId: track.trackId, label: "")
    XCTAssertFalse(emptyNameAccepted)
    XCTAssertNotNil(model.message)
    XCTAssertTrue(model.messageIsFailure, "a failed rename is reported as a failure")
    model.dismissMessage()
    XCTAssertNil(model.message)
    XCTAssertFalse(model.messageIsFailure)

    await model.search("anything")
    XCTAssertTrue(model.searchResults.isEmpty)
    withExtendedLifetime(capture) {}
  }

  /// `systemTrash` is the mover production deletion uses. The returned Trash
  /// URL is the only item this test removes.
  func testSystemTrashMovesADirectoryAndDeletesTheReturnedTrashURL() throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      "open-scribe-system-trash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let payload = Data("open-scribe system trash proof".utf8)
    try payload.write(to: source.appendingPathComponent("clip.caf"))
    var trashed: URL?
    defer {
      if let trashed, Self.isMovedTrashDirectory(trashed) {
        try? FileManager.default.removeItem(at: trashed)
      }
      try? FileManager.default.removeItem(at: source)
    }

    let resulting = try TranscriptLibraryModel.systemTrash(source)
    trashed = resulting
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    let destination = try XCTUnwrap(resulting)
    XCTAssertTrue(Self.isMovedTrashDirectory(destination))
    XCTAssertNotEqual(destination.standardizedFileURL, source.standardizedFileURL)
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("clip.caf")), payload)

    try FileManager.default.removeItem(at: destination)
    trashed = nil
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  /// True only for the directory `trashItem` moved, never the Trash folder itself.
  private static func isMovedTrashDirectory(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    guard name != ".Trash", name != "Trash", name.hasPrefix("open-scribe-system-trash-") else {
      return false
    }
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("clip.caf").path)
  }

  func testDeletionStatesItsScopeAndOnlyCompletesAfterTrash() async throws {
    let (root, sessionId, capture) = try capturedSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try NativeTranscriptLibrary.open(managedRoot: root.path)

    let failing = TranscriptLibraryModel(library: library) { _ in
      throw CocoaError(.fileWriteNoPermission)
    }
    await failing.requestDeletion(sessionId: sessionId)
    let inventory = try XCTUnwrap(failing.pendingDeletion)
    await failing.requestDeletion(sessionId: "another-conversation")
    XCTAssertEqual(failing.pendingDeletion?.sessionId, sessionId)
    XCTAssertEqual(inventory.mediaFiles, 4)
    XCTAssertGreaterThan(inventory.mediaBytes, 0)
    XCTAssertTrue(SessionDeletionSummary.text(inventory).contains("4 audio files"))
    XCTAssertTrue(SessionDeletionSummary.text(inventory).contains("Files you exported elsewhere"))
    XCTAssertTrue(SessionDeletionSummary.text(inventory).contains("Time Machine or other backups"))
    XCTAssertTrue(
      SessionDeletionSummary.text(inventory).contains(
        "does not restore the deleted review database"))
    let failedDeletion = await failing.confirmDeletion()
    XCTAssertFalse(failedDeletion)
    XCTAssertEqual(
      failing.message,
      "The move to Trash did not finish. The conversation is still listed in Open Scribe; check its audio before trying again."
    )
    XCTAssertTrue(failing.messageIsFailure)
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    XCTAssertTrue(
      try preparation.runtimeLibrarySnapshot().savedSessions.contains { $0.sessionId == sessionId })

    let trash = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: trash) }
    let model = TranscriptLibraryModel(library: library) { directory in
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      let destination = trash.appendingPathComponent(directory.lastPathComponent)
      try FileManager.default.moveItem(at: directory, to: destination)
      return destination
    }
    await model.requestDeletion(sessionId: sessionId)
    let deleted = await model.confirmDeletion()
    XCTAssertTrue(deleted)
    XCTAssertFalse(model.messageIsFailure)
    XCTAssertFalse(
      try preparation.runtimeLibrarySnapshot().savedSessions.contains { $0.sessionId == sessionId })
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: trash.appendingPathComponent(sessionId).path),
      "the audio remains recoverable from Trash")
    withExtendedLifetime(capture) {}
  }

  func testDeletionKeepsTheCompletedEffectVisibleWhenDatabaseCleanupIsPending() {
    let message = TranscriptLibraryModel.deletionResult(title: "Example", walCheckpointed: false)
    XCTAssertTrue(message.contains("was moved to Trash"))
    XCTAssertTrue(message.contains("database is busy"))
    XCTAssertTrue(message.contains("Earlier data may remain"))
    XCTAssertEqual(
      TranscriptLibraryModel.deletionResult(title: "Example", walCheckpointed: true),
      "“Example” was moved to Trash.")
  }

  func testUncertainTrashMovePreservesIntentForRecoveryWithoutReplayingTheMove() async throws {
    let (root, sessionId, capture) = try capturedSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: trash) }
    let library = try NativeTranscriptLibrary.open(managedRoot: root.path)
    let moves = TrashMoveCounter()
    let model = TranscriptLibraryModel(library: library) { directory in
      moves.record()
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      try FileManager.default.moveItem(
        at: directory, to: trash.appendingPathComponent(directory.lastPathComponent))
      throw CocoaError(.fileWriteUnknown)
    }
    await model.requestDeletion(sessionId: sessionId)
    let deleted = await model.confirmDeletion()
    XCTAssertFalse(deleted)
    XCTAssertEqual(moves.count, 1)
    XCTAssertNil(model.pendingDeletion)
    XCTAssertTrue(model.messageIsFailure)
    XCTAssertTrue(model.message?.contains("could not be confirmed") == true)
    XCTAssertTrue(model.message?.contains("verify Trash") == true)
    await model.load(sessionId: sessionId)
    XCTAssertTrue(
      model.message?.contains("could not be confirmed") == true,
      "document refresh must not acknowledge a library-operation warning")
    model.dismissMessage()
    XCTAssertTrue(
      model.message?.contains("verify Trash") == true,
      "starting another edit does not resolve an uncertain move")
    XCTAssertNil(
      model.editingFailureMessage,
      "a library-operation warning is not a failed transcript edit")
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    _ = try preparation.recoverPlayableSessions()
    XCTAssertFalse(
      try preparation.runtimeLibrarySnapshot().savedSessions.contains { $0.sessionId == sessionId })
    XCTAssertEqual(moves.count, 1)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: trash.appendingPathComponent(sessionId).path))
    withExtendedLifetime(capture) {}
  }

  func testCancelDeletionKeepsAudioTranscriptAndCorrections() async throws {
    let (root, sessionId, capture) = try capturedSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try NativeTranscriptLibrary.open(managedRoot: root.path)
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: sessionId)
    let transcriptBefore = model.segments.map(\.effectiveText)
    let correctedBefore = model.segments.map(\.corrected)
    let availabilityBefore = model.availability

    await model.requestDeletion(sessionId: sessionId)
    let inventory = try XCTUnwrap(model.pendingDeletion)
    XCTAssertEqual(inventory.sessionId, sessionId)
    XCTAssertGreaterThan(inventory.mediaBytes, 0)
    XCTAssertGreaterThan(inventory.mediaFiles, 0)
    let directory = URL(fileURLWithPath: inventory.directoryPath, isDirectory: true)
    let bytesBefore = try Self.fileBytes(in: directory)

    await model.cancelDeletion()
    XCTAssertNil(model.pendingDeletion)
    XCTAssertNil(model.message)
    XCTAssertFalse(model.messageIsFailure)

    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    XCTAssertTrue(
      try preparation.runtimeLibrarySnapshot().savedSessions.contains { $0.sessionId == sessionId })
    XCTAssertEqual(try Self.fileBytes(in: directory), bytesBefore)

    await model.load(sessionId: sessionId)
    XCTAssertEqual(model.segments.map(\.effectiveText), transcriptBefore)
    XCTAssertEqual(model.segments.map(\.corrected), correctedBefore)
    XCTAssertEqual(model.availability, availabilityBefore)

    await model.requestDeletion(sessionId: sessionId)
    let again = try XCTUnwrap(model.pendingDeletion)
    XCTAssertEqual(again.mediaBytes, inventory.mediaBytes)
    XCTAssertEqual(again.mediaFiles, inventory.mediaFiles)
    XCTAssertEqual(again.transcriptRevisions, inventory.transcriptRevisions)
    XCTAssertEqual(again.humanCorrections, inventory.humanCorrections)
    await model.cancelDeletion()
    XCTAssertNil(model.pendingDeletion)
    XCTAssertEqual(try Self.fileBytes(in: directory), bytesBefore)
    withExtendedLifetime(capture) {}
  }

  private static func fileBytes(in directory: URL) throws -> [String: Data] {
    let root = directory.path
    guard let enumerator = FileManager.default.enumerator(atPath: root) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    var files: [String: Data] = [:]
    for case let relative as String in enumerator {
      let url = directory.appendingPathComponent(relative)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      files[relative] = try Data(contentsOf: url)
    }
    return files
  }

  private func segment(
    _ sequence: UInt32, _ start: Int64, _ speaker: String, named: Bool, _ text: String,
    machine: String? = nil, finality: String = "final"
  ) -> NativeTranscriptSegment {
    NativeTranscriptSegment(
      revisionId: "revision", trackId: named ? "system" : "microphone", sequence: sequence,
      startNanoseconds: start, endNanoseconds: start + 3_000_000_000,
      verbatimText: machine ?? text, effectiveText: text, corrected: machine != nil,
      speakerLabel: speaker, speakerNamedByUser: named, namedSpeakerId: nil, finality: finality)
  }

  func testTranscriptReaderStaysHiddenUntilThePreviewBelongsToTheSession() async {
    let shown = session("valid", calibrated: false, sources: [])
    let rows = [segment(0, 0, "Local user", named: false, "Thanks for joining.")]
    let model = TranscriptLibraryModel(preview: .final, segments: rows, speakers: [])
    XCTAssertFalse(TranscriptSection.showsReader(session: shown, transcripts: model))
    await model.load(session: shown)
    XCTAssertTrue(TranscriptSection.showsReader(session: shown, transcripts: model))
    XCTAssertFalse(
      TranscriptSection.showsReader(
        session: session("other", calibrated: false, sources: []), transcripts: model))
    let unavailable = session("single-source", calibrated: false, sources: [.microphone])
    let empty = TranscriptLibraryModel(preview: .unavailable, segments: [], speakers: [])
    await empty.load(session: unavailable)
    XCTAssertFalse(TranscriptSection.showsReader(session: unavailable, transcripts: empty))
  }

  func testDelayedLoadKeepsTheUIResponsiveAndCannotReplaceANewerDocument() async {
    let checkpoint = MetadataCheckpoint()
    let library = TranscriptTimingLibraryFake(beforeOperation: { kind, id in
      if kind == "document", id == "old" {
        checkpoint.entered.signal()
        _ = checkpoint.release.wait(timeout: .now() + 3)
      }
    })
    let model = TranscriptLibraryModel(library: library)
    let loading = Task { await model.load(sessionId: "old") }
    let entered = await Task.detached {
      checkpoint.enteredBeforeTimeout()
    }.value
    XCTAssertTrue(entered)
    XCTAssertTrue(model.isLoading, "the main actor can observe work while its IO is held")
    await model.load(sessionId: "new")
    checkpoint.release.signal()
    await loading.value
    XCTAssertEqual(model.sessionId, "new")
    XCTAssertEqual(model.segments.first?.trackId, "new")
    XCTAssertFalse(model.isLoading)
    XCTAssertEqual(library.mainThreadOperations, 0)
  }

  func testDelayedSearchCannotPublishOverANewerQuery() async {
    let checkpoint = MetadataCheckpoint()
    let library = TranscriptTimingLibraryFake(beforeOperation: { kind, query in
      if kind == "search", query == "old" {
        checkpoint.entered.signal()
        _ = checkpoint.release.wait(timeout: .now() + 3)
      }
    })
    let model = TranscriptLibraryModel(library: library)
    let searching = Task { await model.search("old") }
    let entered = await Task.detached {
      checkpoint.enteredBeforeTimeout()
    }.value
    XCTAssertTrue(entered)
    await model.search("new")
    checkpoint.release.signal()
    await searching.value
    XCTAssertEqual(model.searchResults.first?.effectiveText, "new")
    XCTAssertFalse(model.isSearching)
    XCTAssertEqual(library.mainThreadOperations, 0)
  }

  func testDeletionInvalidatesHeldDocumentAndSearchSnapshots() async {
    let document = MetadataCheckpoint()
    let search = MetadataCheckpoint()
    defer {
      document.release.signal()
      search.release.signal()
    }
    let library = TranscriptTimingLibraryFake(beforeOperation: { kind, _ in
      if kind == "document" { document.holdOnce() }
      if kind == "search" { search.holdOnce() }
    })
    let model = TranscriptLibraryModel(library: library, moveToTrash: { _ in nil })
    let loading = Task { await model.load(sessionId: "valid") }
    let searching = Task { await model.search("Fixture") }
    let entered = await Task.detached {
      document.enteredBeforeTimeout() && search.enteredBeforeTimeout()
    }.value
    XCTAssertTrue(entered)
    await model.requestDeletion(sessionId: "valid")
    let deleted = await model.confirmDeletion()
    XCTAssertTrue(deleted)
    XCTAssertFalse(model.isLoading)
    XCTAssertFalse(model.isSearching)
    document.release.signal()
    search.release.signal()
    await loading.value
    await searching.value
    XCTAssertTrue(model.segments.isEmpty, "a deleted document cannot return from an older read")
    XCTAssertTrue(model.searchResults.isEmpty, "the refreshed query must replace old matches")
    XCTAssertEqual(model.message, "“Fixture” was moved to Trash.")
    XCTAssertEqual(library.mainThreadOperations, 0)
  }

  func testCancelledContextSeekCannotStartPlaybackOrPublishAnError() async {
    let checkpoint = MetadataCheckpoint()
    defer { checkpoint.release.signal() }
    let library = TranscriptTimingLibraryFake(beforeOperation: { kind, _ in
      if kind == "resolve" { checkpoint.holdOnce() }
    })
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: "valid")
    let event = NativeContextEvent(
      eventId: "event", scopeId: "scope", epoch: 0, startNs: 10, endNs: 20,
      observedAtMs: 0, reason: .userMarked, sourceName: "Fixture", application: nil,
      text: "Evidence", blockCount: 1, semanticHash: "fixture", retention: "text")
    let seeking = Task { await model.contextEvidenceStart(event, in: "valid") }
    let entered = await Task.detached {
      checkpoint.enteredBeforeTimeout()
    }.value
    XCTAssertTrue(entered)
    // SwiftUI cancels this owner task when its conversation disappears, even
    // when the next screen is live capture and does not load another transcript.
    seeking.cancel()
    checkpoint.release.signal()
    let playbackStart = await seeking.value
    XCTAssertNil(playbackStart)
    XCTAssertNil(model.message)
    XCTAssertEqual(model.sessionId, "valid")
    XCTAssertEqual(library.mainThreadOperations, 0)
  }

  func testHeldCorrectionRejectsDuplicateSubmissionAndRetainsItsOriginalSession() async throws {
    let checkpoint = MetadataCheckpoint()
    let library = TranscriptTimingLibraryFake(beforeOperation: { kind, _ in
      if kind == "correct" {
        checkpoint.entered.signal()
        _ = checkpoint.release.wait(timeout: .now() + 3)
      }
    })
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: "old")
    let segment = try XCTUnwrap(model.segments.first)
    let editing = Task { await model.correct(segment, text: "Updated", in: "old") }
    let entered = await Task.detached {
      checkpoint.enteredBeforeTimeout()
    }.value
    XCTAssertTrue(entered)
    let duplicate = await model.correct(segment, text: "Duplicate", in: "old")
    XCTAssertFalse(duplicate)
    await model.load(sessionId: "new")
    checkpoint.release.signal()
    let saved = await editing.value
    XCTAssertTrue(saved)
    XCTAssertEqual(library.correctedSessions, ["old"])
    XCTAssertEqual(model.sessionId, "new")
    XCTAssertEqual(model.segments.first?.trackId, "new")
    XCTAssertFalse(model.isEditing)
    XCTAssertEqual(library.mainThreadOperations, 0)
  }

  func testHeldExportRemainsBoundToItsOriginalDocument() async {
    let checkpoint = MetadataCheckpoint()
    let library = TranscriptTimingLibraryFake(beforeOperation: { kind, _ in
      if kind == "export" {
        checkpoint.entered.signal()
        _ = checkpoint.release.wait(timeout: .now() + 3)
      }
    })
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: "old")
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    let exporting = Task { await model.export(format: .plainText, to: destination) }
    let entered = await Task.detached {
      checkpoint.enteredBeforeTimeout()
    }.value
    XCTAssertTrue(entered)
    let duplicate = await model.export(format: .plainText, to: destination)
    XCTAssertFalse(duplicate)
    await model.load(sessionId: "new")
    checkpoint.release.signal()
    let exported = await exporting.value
    XCTAssertTrue(exported)
    XCTAssertEqual(library.lastExportedSessionId, "old")
    XCTAssertNil(model.message, "an old export must not publish success onto the new document")
    XCTAssertFalse(model.isExporting)
    XCTAssertEqual(library.mainThreadOperations, 0)
  }

  func testTimestampsAndExportNamesAreStable() {
    XCTAssertEqual(TranscriptSection.timestamp(0), "0:00")
    XCTAssertEqual(TranscriptSection.timestamp(65_400_000_000), "1:05")
    XCTAssertEqual(TranscriptSection.timestamp(3_725_000_000_000), "1:02:05")
    XCTAssertEqual(
      TranscriptSection.fileName("Team: sync/notes", type: .json), "Team- sync-notes.json")
    XCTAssertEqual(TranscriptSection.fileName(" .hidden", type: .plainText), "Transcript.txt")
  }

  func testAnObsoleteExportActionCannotExportTheNewDocument() async {
    let library = TranscriptTimingLibraryFake()
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: "new")
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    let exported = await model.export(format: .plainText, to: destination, from: "old")
    XCTAssertFalse(exported)
    XCTAssertNil(library.lastExportedSessionId)
    XCTAssertFalse(model.isExporting)
  }

  func testClaimEvidenceSeeksHighlightsTheCitedPassageAndReturnsFocus() async throws {
    let library = TranscriptTimingLibraryFake()
    library.claimsJSON = """
      [{"claim_id":"claim-decision","revision_id":"revision-b","kind":"decision","status":"agreed","text":"The team deferred the remote recorder.","adjudication":"corrected","supporting_count":1,"contradicting_count":1}]
      """
    library.claimNavigation = NativeClaimNavigation(
      claimId: "claim-decision", revisionId: "revision-b",
      text: "The team deferred the remote recorder.", adjudication: "corrected",
      targets: [
        NativeClaimTarget(
          side: "supporting", state: .available, recordId: "fixture", startNs: 0,
          endNs: 1_000_000_000, text: "alpha"),
        NativeClaimTarget(
          side: "contradicting", state: .missing, recordId: "missing", startNs: 5, endNs: 9,
          text: nil),
      ])
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: "valid")
    let claim = try XCTUnwrap(model.derivedClaims.first)
    XCTAssertEqual(claim.claimId, "claim-decision")
    XCTAssertEqual(claim.adjudication, "corrected")

    var sought: [Int64] = []
    if let start = await model.openClaimEvidence(claimId: claim.claimId, side: "supporting") {
      sought.append(start)
    }
    XCTAssertEqual(sought, [0])
    XCTAssertEqual(model.claimHighlightSegmentId, "fixture#0")
    XCTAssertEqual(model.focusedClaim?.claimId, "claim-decision")
    XCTAssertEqual(model.focusedClaim?.revisionId, "revision-b")
    XCTAssertEqual(model.focusedClaim?.text, "The team deferred the remote recorder.")
    XCTAssertTrue(model.claimEvidenceOpen)
    XCTAssertNil(model.message)
    let generation = model.claimFocusGeneration
    model.returnToClaim()
    XCTAssertFalse(model.claimEvidenceOpen)
    XCTAssertNil(model.claimHighlightSegmentId)
    XCTAssertEqual(model.focusedClaim?.claimId, "claim-decision")
    XCTAssertEqual(model.claimFocusGeneration, generation + 1)

    let contradicted = await model.openClaimEvidence(claimId: claim.claimId, side: "contradicting")
    XCTAssertNil(contradicted)
    XCTAssertFalse(model.claimEvidenceOpen)
    XCTAssertEqual(
      model.message, TranscriptLibraryModel.evidenceProblem(.missing))

    library.claimNavigation = NativeClaimNavigation(
      claimId: "claim-decision", revisionId: "revision-b",
      text: "The team deferred the remote recorder.", adjudication: "corrected",
      targets: [
        NativeClaimTarget(
          side: "supporting", state: .available, recordId: "other-revision", startNs: 0,
          endNs: 1_000_000_000, text: "alpha")
      ])
    let unmatched = await model.openClaimEvidence(claimId: claim.claimId, side: "supporting")
    XCTAssertEqual(unmatched, 0)
    XCTAssertNil(
      model.claimHighlightSegmentId,
      "a different revision at the same range is not the cited passage")
    XCTAssertTrue(model.claimEvidenceOpen)
    model.returnToClaim()
    XCTAssertEqual(model.focusedClaim?.revisionId, "revision-b")
    XCTAssertFalse(model.claimEvidenceOpen)
  }

  func testAdjudicationConfirmsTheClaimAndACorrectionReplacesItsText() async throws {
    let library = TranscriptTimingLibraryFake()
    library.claimsJSON = """
      [{"claim_id":"claim-decision","revision_id":"revision-a","kind":"decision","status":"agreed","text":"The team agreed to ship the local recorder.","adjudication":null,"supporting_count":1,"contradicting_count":0}]
      """
    let model = TranscriptLibraryModel(library: library)
    await model.load(sessionId: "valid")
    let confirmed = await model.adjudicateClaim(
      claimId: "claim-decision", action: "accepted", text: nil)
    XCTAssertTrue(confirmed)
    let accepted = try XCTUnwrap(library.lastAdjudication)
    XCTAssertEqual(accepted.action, "accepted")
    XCTAssertNil(accepted.text)
    XCTAssertEqual(model.derivedClaims.first?.adjudication, "accepted")
    XCTAssertEqual(
      model.derivedClaims.first?.text, "The team agreed to ship the local recorder.")
    XCTAssertEqual(model.derivedClaims.first?.revisionId, "revision-accepted")

    let corrected = await model.adjudicateClaim(
      claimId: "claim-decision", action: "corrected",
      text: "The team deferred the remote recorder.")
    XCTAssertTrue(corrected)
    let correction = try XCTUnwrap(library.lastAdjudication)
    XCTAssertEqual(correction.action, "corrected")
    XCTAssertEqual(correction.text, "The team deferred the remote recorder.")
    XCTAssertEqual(model.derivedClaims.first?.text, "The team deferred the remote recorder.")
    XCTAssertEqual(model.derivedClaims.first?.revisionId, "revision-corrected")
    XCTAssertEqual(model.derivedClaims.first?.adjudication, "corrected")

    let unresolved = await model.adjudicateClaim(
      claimId: "claim-decision", action: "unresolved", text: nil)
    XCTAssertFalse(unresolved)
    XCTAssertEqual(library.lastAdjudication?.action, "corrected")
    XCTAssertEqual(model.derivedClaims.first?.text, "The team deferred the remote recorder.")
    XCTAssertNil(model.message)
  }
}

private struct RecordedAdjudication: Equatable {
  let claimId: String
  let action: String
  let text: String?
}

private final class TrashMoveCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func record() { lock.withLock { value += 1 } }
}

/// No Rust handle or media access: exercises the model's selection and
/// capability handling, including reads that must not run for untimed capture.
private final class TranscriptTimingLibraryFake: NativeTranscriptLibrary, @unchecked Sendable {
  private let lock = NSLock()
  private let rejectsHistoricalAudioOptions: Bool
  private var reads = 0
  private var exportedSessionId: String?
  private var reviewedName: String?
  private let beforeSpeakerMutation: (@Sendable () -> Void)?
  private let beforeOperation: (@Sendable (String, String) -> Void)?
  private var mainThreadCalls = 0
  private var corrections: [String] = []
  private var deletedSessions: Set<String> = []
  var claimsJSON = "[]"
  var claimNavigation: NativeClaimNavigation?
  private var storedAdjudication: RecordedAdjudication?
  var lastAdjudication: RecordedAdjudication? { lock.withLock { storedAdjudication } }
  var mainThreadOperations: Int { lock.withLock { mainThreadCalls } }
  var correctedSessions: [String] { lock.withLock { corrections } }
  var transcriptReads: Int { lock.withLock { reads } }
  var lastExportedSessionId: String? { lock.withLock { exportedSessionId } }

  init(
    rejectsHistoricalAudioOptions: Bool = false, reviewedName: String? = nil,
    beforeSpeakerMutation: (@Sendable () -> Void)? = nil,
    beforeOperation: (@Sendable (String, String) -> Void)? = nil
  ) {
    self.rejectsHistoricalAudioOptions = rejectsHistoricalAudioOptions
    self.reviewedName = reviewedName
    self.beforeSpeakerMutation = beforeSpeakerMutation
    self.beforeOperation = beforeOperation
    super.init(noHandle: NoHandle())
  }
  required init(unsafeFromHandle handle: UInt64) {
    rejectsHistoricalAudioOptions = false
    beforeSpeakerMutation = nil
    beforeOperation = nil
    super.init(unsafeFromHandle: handle)
  }

  override func availability(sessionId: String) throws -> NativeTranscriptAvailability {
    lock.withLock { reads += 1 }
    return .final
  }

  override func inspectProvenance(sessionId: String) throws -> [NativeTranscriptProvenance] {
    []
  }

  override func document(sessionId: String) throws -> [NativeTranscriptSegment] {
    lock.withLock { reads += 1 }
    let snapshot = [
      NativeTranscriptSegment(
        revisionId: "fixture", trackId: sessionId, sequence: 0, startNanoseconds: 0,
        endNanoseconds: 1_000_000_000, verbatimText: "Fixture", effectiveText: "Fixture",
        corrected: false, speakerLabel: "Fixture", speakerNamedByUser: false, namedSpeakerId: nil,
        finality: "final")
    ]
    observe("document", sessionId)
    return snapshot
  }

  override func namedSpeakers(sessionId: String) throws -> [NativeNamedTranscriptSpeaker] { [] }

  override func reviewMetadata(sessionId: String) throws -> NativeConversationReviewMetadata {
    NativeConversationReviewMetadata(
      addedAtMs: 1_700_000_000_000, origin: "capture", storedMediaBytes: 2_048,
      sourceNames: ["Fixture"])
  }

  override func speakers(sessionId: String) throws -> [NativeSessionSpeaker] {
    [
      NativeSessionSpeaker(
        trackId: sessionId, sourceKind: "microphone", label: "Fixture", namedByUser: false)
    ]
  }

  override func speakerLabelHistory(sessionId: String) throws -> [NativeSpeakerLabelHistory] {
    []
  }

  override func namedSpeakerTurnHistory(sessionId: String) throws -> [NativeNamedSpeakerTurnHistory]
  {
    []
  }

  var mergedKeep: String? { lock.withLock { storedMerge?.0 } }
  var mergedAbsorb: String? { lock.withLock { storedMerge?.1 } }
  var splitSpeakerId: String? { lock.withLock { storedSplit?.0 } }
  var splitSequence: UInt32? { lock.withLock { storedSplit?.1 } }
  var splitLabel: String? { lock.withLock { storedSplit?.2 } }
  private var storedMerge: (String, String)?
  private var storedSplit: (String, UInt32, String)?

  override func prepareSpeakerDiarization(sessionId: String) throws -> NativeSpeakerDiarization {
    NativeSpeakerDiarization(
      runId: "fixture-run", algorithmId: "topology-before-clustering-v1",
      clusteringState: "unavailable", reason: "no calibrated diarization model", inserted: false,
      tracks: [
        NativeSpeakerDiarizationTrack(
          trackId: sessionId, sourceKind: "microphone", disposition: "topology", label: "Fixture",
          labelOrigin: "source_default")
      ])
  }

  override func audioExportOptions(sessionId: String) throws -> NativeAudioExportOptions {
    if rejectsHistoricalAudioOptions, sessionId == "historical" {
      throw NativeStorageError.InvalidState
    }
    return NativeAudioExportOptions(
      hasValidatedMix: false, originalExtension: sessionId == "valid" ? "caf" : nil,
      pcmTracks: [sessionId])
  }

  override func contextDetail(sessionId: String) throws -> NativeContextDetail {
    throw NativeStorageError.InvalidState
  }

  override func contextEvents(sessionId: String) throws -> [NativeContextEvent] { [] }

  override func effectiveDerivedClaims(sessionId: String) throws -> String {
    observe("claims", sessionId)
    return lock.withLock { claimsJSON }
  }

  override func adjudicateDerivedClaim(
    sessionId: String, claimId: String, action: String, text: String?
  ) throws -> String {
    observe("adjudicate", action)
    return try lock.withLock {
      storedAdjudication = RecordedAdjudication(claimId: claimId, action: action, text: text)
      switch action {
      case "accepted":
        claimsJSON = """
          [{"claim_id":"\(claimId)","revision_id":"revision-accepted","kind":"decision","status":"agreed","text":"The team agreed to ship the local recorder.","adjudication":"accepted","supporting_count":1,"contradicting_count":0}]
          """
        return "revision-accepted"
      case "corrected":
        let replacement = text ?? ""
        claimsJSON = """
          [{"claim_id":"\(claimId)","revision_id":"revision-corrected","kind":"decision","status":"agreed","text":"\(replacement)","adjudication":"corrected","supporting_count":1,"contradicting_count":0}]
          """
        return "revision-corrected"
      default:
        throw NativeStorageError.InvalidRequest
      }
    }
  }

  override func navigateDerivedClaim(sessionId: String, claimId: String) throws
    -> NativeClaimNavigation
  {
    observe("navigate", claimId)
    if let claimNavigation = lock.withLock({ claimNavigation }) { return claimNavigation }
    throw NativeStorageError.InvalidRequest
  }

  override func citeContextEvent(sessionId: String, eventId: String, block: UInt32?) throws
    -> String
  {
    sessionId
  }

  override func resolveEvidence(referenceJson: String) throws -> NativeResolvedEvidence {
    observe("resolve", referenceJson)
    return NativeResolvedEvidence(
      state: .available, kind: "context", sessionId: referenceJson, startNs: 10,
      endNs: 20, text: "Evidence", currentRevisionId: nil)
  }

  override func beginDeletion(sessionId: String) throws -> NativeSessionDeletionInventory {
    observe("beginDeletion", sessionId)
    return NativeSessionDeletionInventory(
      sessionId: sessionId, title: "Fixture", directoryPath: "/synthetic/\(sessionId)",
      mediaFiles: 1, mediaBytes: 100, transcriptRevisions: 1, humanCorrections: 0,
      speakerNames: 0, markers: 0, contextEvents: 0, exportFiles: 0, exportBytes: 0)
  }

  override func completeDeletion(sessionId: String, trashReference: String?) throws
    -> NativeSessionDeletionReceipt
  {
    observe("completeDeletion", sessionId)
    _ = lock.withLock { deletedSessions.insert(sessionId) }
    return NativeSessionDeletionReceipt(receiptId: "fixture", walCheckpointed: true)
  }

  override func export(
    sessionId: String, format: NativeTranscriptExportFormat, destinationPath: String
  )
    throws -> NativeTranscriptExportReceipt
  {
    observe("export", sessionId)
    lock.withLock { exportedSessionId = sessionId }
    return NativeTranscriptExportReceipt(availability: .final, byteLength: 0, segmentCount: 1)
  }
  override func renameSpeaker(sessionId: String, trackId: String, label: String?) throws {}

  override func correctSegment(
    sessionId: String, revisionId: String, sequence: UInt32, text: String?
  ) throws {
    observe("correct", sessionId)
    lock.withLock { corrections.append(sessionId) }
  }

  private func observe(_ kind: String, _ id: String) {
    if Thread.isMainThread { lock.withLock { mainThreadCalls += 1 } }
    beforeOperation?(kind, id)
  }

  override func renameNamedSpeaker(sessionId: String, speakerId: String, label: String) throws {
    beforeSpeakerMutation?()
    lock.withLock { reviewedName = label }
  }

  override func assignSpeaker(
    sessionId: String, revisionId: String, sequence: UInt32,
    assignment: NativeTranscriptSpeakerAssignment
  ) throws -> String? {
    lock.withLock { reviewedName = nil }
    return nil
  }

  override func mergeNamedSpeakers(sessionId: String, keepId: String, absorbId: String) throws
    -> UInt32
  {
    lock.withLock { storedMerge = (keepId, absorbId) }
    return 1
  }

  override func splitNamedSpeaker(
    sessionId: String, speakerId: String, turns: [NativeNamedSpeakerTurn], label: String
  ) throws -> String {
    lock.withLock { storedSplit = (speakerId, turns.first?.sequence ?? 999, label) }
    return "mina"
  }

  override func search(query: String, sessionId: String?, limit: UInt32) throws
    -> [NativeTranscriptSearchHit]
  {
    let matches = lock.withLock {
      !deletedSessions.contains("valid")
        && (!query.hasPrefix("speaker:")
          || reviewedName?.lowercased() == String(query.dropFirst("speaker:".count)).lowercased())
    }
    let snapshot =
      matches
      ? [
        NativeTranscriptSearchHit(
          sessionId: "valid", sessionTitle: "Fixture", revisionId: "fixture", trackId: "valid",
          sequence: 0, startNanoseconds: 0, endNanoseconds: 1_000_000_000, effectiveText: query)
      ] : []
    observe("search", query)
    return snapshot
  }
}
