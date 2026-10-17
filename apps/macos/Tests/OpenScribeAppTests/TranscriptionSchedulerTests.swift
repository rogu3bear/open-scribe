import AVFoundation
import AppKit
import SwiftUI
import XCTest

@testable import OpenScribeApp

@MainActor
final class TranscriptionSchedulerTests: XCTestCase {
  /// Production coordinator and store against owned synthetic audio. Only the
  /// ASR executor and native observations are injected, never a separate app.
  @MainActor private final class Harness {
    let root: URL
    let defaults: UserDefaults
    let coordinator: NativeWorkCoordinator
    let session: String
    var capture = false
    var recovery = false
    var readiness: NativeModelReadiness = .ready
    var started: [NativeTranscriptionWork] = []
    var continuation: CheckedContinuation<NativeWorkOutcome, Never>?
    lazy var scheduler = TranscriptionScheduler(
      coordinator: coordinator,
      runner: { [weak self] entry in
        guard let self else { return .deferred }
        started.append(entry)
        return await withCheckedContinuation { continuation = $0 }
      },
      observations: { [weak self] in
        guard let self else {
          return NativeWorkObservations(
            automatic: false, paused: false, captureActive: false,
            mediaRecoveryPending: true, model: .absent, availableDiskBytes: nil,
            memoryCritical: false, thermalCritical: false)
        }
        return NativeWorkObservations(
          automatic: true, paused: false, captureActive: capture,
          mediaRecoveryPending: recovery, model: readiness, availableDiskBytes: nil,
          memoryCritical: false, thermalCritical: false)
      },
      stop: { [weak self] preempt in
        self?.finish(preempt ? .capturePreempted : .userCancelled)
      },
      defaults: defaults)

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("scheduler-\(UUID())")
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defaults = UserDefaults(suiteName: "OpenScribe.Proof.Scheduler.\(UUID())")!
      let source = root.appendingPathComponent("source.caf")
      do {
        let file = try AVAudioFile(
          forWriting: source,
          settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
          ], commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        buffer.int16ChannelData![0].initialize(repeating: 0, count: 4_800)
        try file.write(from: buffer)
      }
      let preparation = try NativeRecordingPreparation.open(
        managedRoot: root.appendingPathComponent("Library").path)
      session = try preparation.importRecoverableCaf(title: "Synthetic", sourcePath: source.path)
        .sessionId
      coordinator = try NativeWorkCoordinator.open(
        managedRoot: root.appendingPathComponent("Library").path)
    }
    func finish(_ outcome: NativeWorkOutcome) {
      let pending = continuation
      continuation = nil
      pending?.resume(returning: outcome)
    }
    func removeOwnedFixture() { try? FileManager.default.removeItem(at: root) }
  }
  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The isolated scheduler did not reach the expected state.")
  }

  func testRefreshAfterFixtureOwnerEndsHasNoBorrowedObservation() async throws {
    weak var departed: Harness?
    let scheduler: TranscriptionScheduler
    do {
      let fixture = try Harness()
      fixture.readiness = .absent
      departed = fixture
      scheduler = fixture.scheduler
      fixture.removeOwnedFixture()
    }
    XCTAssertNil(departed)
    scheduler.reconsider()
    await waitUntil { scheduler.hold == .launchRecoveryPending }
    XCTAssertNil(scheduler.runningSessionId)
  }

  func testManualPausePreemptionAndRefreshPreserveOneManualRunner() async throws {
    let h = try Harness()
    defer { h.removeOwnedFixture() }
    h.scheduler.isAutomatic = false
    h.scheduler.isPaused = true
    h.scheduler.request(sessionId: h.session)
    await waitUntil { h.started.count == 1 }
    XCTAssertTrue(h.started[0].manual)
    for _ in 0..<20 { h.scheduler.reconsider() }
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(h.started.count, 1, "refresh cannot admit a second runner")
    h.capture = true
    h.scheduler.reconsider()
    await waitUntil { h.scheduler.runningSessionId == nil }
    await waitUntil { h.scheduler.queue.first?.requestedByUser == true }
    XCTAssertEqual(h.scheduler.hold, .recordingInProgress)
    h.capture = false
    h.scheduler.reconsider()
    await waitUntil { h.started.count == 2 }
    XCTAssertTrue(h.started[1].manual)
    h.finish(.completed)
    await waitUntil { h.scheduler.runningSessionId == nil }
  }
  func testAutomaticOffDoesNotRestartPreemptedWorkAndCancellationIsNotFailure() async throws {
    let h = try Harness()
    defer { h.removeOwnedFixture() }
    h.scheduler.reconsider()
    await waitUntil { h.started.count == 1 }
    h.scheduler.isAutomatic = false
    h.capture = true
    h.scheduler.reconsider()
    await waitUntil { h.scheduler.runningSessionId == nil }
    h.capture = false
    h.scheduler.reconsider()
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(h.started.count, 1)
    h.scheduler.request(sessionId: h.session)
    await waitUntil { h.started.count == 2 }
    h.scheduler.cancel(sessionId: h.session)
    await waitUntil { h.scheduler.state(for: h.session) == .cancelled }
    XCTAssertFalse(
      h.scheduler.outcomes.values.contains {
        if case .failed = $0 { return true }
        return false
      },
      "the former cancellation-as-failure assertion described a defect, not a product invariant")
  }
  func testQueuedManualIntentSurvivesAReopenedCoordinatorWithAutomationOff() async throws {
    let h = try Harness()
    defer { h.removeOwnedFixture() }
    h.capture = true
    h.scheduler.isAutomatic = false
    h.scheduler.request(sessionId: h.session)
    await waitUntil { h.scheduler.queue.count == 1 }
    let reopened = try NativeWorkCoordinator.open(
      managedRoot: h.root.appendingPathComponent("Library").path)
    let queue = try reopened.queue(
      observations: NativeWorkObservations(
        automatic: false, paused: true,
        captureActive: true, mediaRecoveryPending: false, model: .absent, availableDiskBytes: nil,
        memoryCritical: false, thermalCritical: false))
    XCTAssertEqual(queue.map(\.sessionId), [h.session])
    XCTAssertTrue(queue[0].manual)
    XCTAssertEqual(queue[0].hold, .capture)
  }

  func testIncompleteRebuildEndsManualIntentAndLeavesRecognitionEligible() async throws {
    let h = try Harness()
    defer { h.removeOwnedFixture() }
    h.readiness = .absent
    h.scheduler.isAutomatic = false
    h.scheduler.request(sessionId: h.session, intent: .reconcileRetained)
    await waitUntil { h.started.count == 1 }
    XCTAssertEqual(h.started[0].intent, .reconcileRetained)
    h.finish(.incomplete)
    await waitUntil { h.scheduler.state(for: h.session) == .incomplete }
    h.scheduler.reconsider()
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(h.started.count, 1, "an exhausted rebuild must not spin")
    h.scheduler.isAutomatic = true
    await waitUntil { h.scheduler.hold == .noSpeechModel }
    XCTAssertEqual(h.scheduler.queue.map(\.sessionId), [h.session])
    h.readiness = .ready
    h.scheduler.reconsider()
    await waitUntil { h.started.count == 2 }
    XCTAssertEqual(h.started[1].intent, .resumeIncomplete)
    XCTAssertFalse(h.started[1].manual)
    h.finish(.userCancelled)
    await waitUntil { h.scheduler.runningSessionId == nil }
  }

  /// Render the production controls beside real durable absent/invalid holds.
  /// Keep PNGs with OPEN_SCRIBE_RENDER_DIR for visual inspection: SwiftUI's
  /// in-process accessibility tree does not expose all controls on every SDK.
  func testQueuedConversationsRenderModelHoldsAndControls() async throws {
    let readinesses: [NativeModelReadiness] = [.absent, .invalid]
    for readiness in readinesses {
      let h = try Harness()
      defer { h.removeOwnedFixture() }
      h.readiness = readiness
      h.scheduler.reconsider()
      await waitUntil { h.scheduler.queue.map(\.sessionId) == [h.session] }
      let root = h.root.appendingPathComponent("Library")
      let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
      let session = RuntimeSessionPresentation(
        native: try XCTUnwrap(preparation.runtimeLibrarySnapshot().savedSessions.first))
      let model = NativeSpeechModel(
        modelId: "whisper-small.en-q5_1", profile: "fixture", languages: ["en"],
        fileName: "fixture.bin", byteLength: 10, sha256: String(repeating: "a", count: 64),
        downloadOrigin: "https://example.invalid/fixture", license: "MIT", engine: "fixture",
        installed: false, readiness: readiness, diagnostic: nil)
      let content = TranscriptSection(
        session: session, transcripts: TranscriptLibraryModel(managedRoot: root),
        speech: SpeechTranscriptionModel(preview: [model]), scheduler: h.scheduler,
        canSeek: true, onSeek: { _ in }
      ).padding(24).frame(width: 600).background(Color(nsColor: .windowBackgroundColor))
      XCTAssertNotNil(h.scheduler.hold)
      let host = NSHostingView(rootView: content)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      try await Task.sleep(for: .milliseconds(30))
      host.layoutSubtreeIfNeeded()
      let size = host.fittingSize
      XCTAssertLessThanOrEqual(size.width, 601)
      XCTAssertGreaterThan(size.height, 80)
      if let directory = ProcessInfo.processInfo.environment["OPEN_SCRIBE_RENDER_DIR"] {
        // Render this mounted view in process, including its AppKit controls;
        // this does not read the screen or request screen-capture permission.
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let png = try XCTUnwrap(
          image.representation(using: .png, properties: [:]))
        try png.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent(
            "queued-model-\(readiness).png"))
      }
    }
  }

  func testPressureReadingNamesOnlyMeasuredHolds() {
    let base = SystemPressureReading(
      availableDiskBytes: 40 << 30, memoryPressure: .normal, memoryPressureObserved: false,
      freeMemoryBytes: 2 << 30, totalMemoryBytes: 16 << 30, thermalState: .nominal,
      processCPUCores: 3.25, residentMemoryBytes: 900 << 20, sampledAt: Date())
    XCTAssertNil(base.transcriptionHoldReason)
    XCTAssertEqual(base.diskText, "42.95 GB free")
    XCTAssertTrue(base.memoryText.hasPrefix("Memory no pressure reported, "))
    XCTAssertEqual(base.processText, "Open Scribe using 3.2 CPU cores, 943.7 MB resident")

    let low = SystemPressureReading(
      availableDiskBytes: 512 << 20, memoryPressure: .warning, memoryPressureObserved: true,
      freeMemoryBytes: nil, totalMemoryBytes: 16 << 30, thermalState: .serious,
      processCPUCores: nil, residentMemoryBytes: nil, sampledAt: Date())
    XCTAssertTrue(low.diskIsLow)
    XCTAssertEqual(
      low.transcriptionHoldReason, "Waiting: less than 1.07 GB is free on the library disk.")
    XCTAssertEqual(low.memoryText, "Memory warning")
    XCTAssertNil(low.processText)

    let hot = SystemPressureReading(
      availableDiskBytes: nil, memoryPressure: .critical, memoryPressureObserved: true,
      freeMemoryBytes: nil, totalMemoryBytes: 16 << 30, thermalState: .critical,
      processCPUCores: nil, residentMemoryBytes: nil, sampledAt: Date())
    XCTAssertEqual(hot.transcriptionHoldReason, "Waiting: macOS reports critical memory pressure.")
    XCTAssertEqual(hot.diskText, "Disk space unavailable")

    // The monitor's measurements come from macOS and are present on this Mac.
    XCTAssertNotNil(SystemPressureMonitor.hostFreeMemoryBytes())
    XCTAssertNotNil(SystemPressureMonitor.residentMemoryBytes())
    XCTAssertGreaterThan(SystemPressureMonitor.processCPUTime(), 0)
    XCTAssertNotNil(
      SystemPressureMonitor.availableDiskBytes(at: FileManager.default.temporaryDirectory))
  }

  func testTranscriptPresentationReadsTheSnapshot() {
    let running = RuntimeTranscriptPresentation(
      native: NativeRuntimeTranscriptSnapshot(
        document: .partial, replacementResumable: false,
        state: .running, selectedRevisionIds: ["reviewed-A"], documentVersion: "v1",
        attempt: .running, attemptFailure: nil, totalTracks: 2, finalTracks: 1,
        completedChunks: 43, totalChunks: 83,
        failureClass: nil))
    XCTAssertEqual(running.state, .running)
    XCTAssertEqual(running.statusText, "Transcript ready for 1 of 2 tracks · transcription running")
    XCTAssertEqual(running.runningFraction.map { ($0 * 100).rounded() }, 52)
    let failed = RuntimeTranscriptPresentation(
      native: NativeRuntimeTranscriptSnapshot(
        document: .partial, replacementResumable: true,
        state: .failed, selectedRevisionIds: ["reviewed-A"], documentVersion: "v1",
        attempt: .failed, attemptFailure: "invalid_result", totalTracks: 2,
        finalTracks: 1, completedChunks: 0, totalChunks: 0,
        failureClass: "invalid_result"))
    XCTAssertEqual(failed.statusText, "Transcript ready for 1 of 2 tracks · latest attempt failed")
    XCTAssertTrue(failed.replacementResumable)
    XCTAssertEqual(failed.selectedRevisionIds, ["reviewed-A"])
    XCTAssertTrue(
      RuntimeTranscriptPresentation.failureText(failed.failureClass).contains(
        "rebuilds it from the parts that were kept"))
    let absent = RuntimeTranscriptPresentation(native: nil)
    XCTAssertEqual(absent.state, .unknown)
    XCTAssertEqual(absent.documentAvailability, .unavailable)
    XCTAssertFalse(absent.hasTranscribableAudio)
    XCTAssertEqual(
      RuntimeTranscriptPresentation(
        native: NativeRuntimeTranscriptSnapshot(
          document: .partial, replacementResumable: false,
          state: .partial, selectedRevisionIds: ["reviewed-A"], documentVersion: "v1",
          attempt: .none, attemptFailure: nil, totalTracks: 2, finalTracks: 1,
          completedChunks: 0, totalChunks: 0,
          failureClass: nil)
      ).statusText,
      "Transcript ready for 1 of 2 tracks")
  }

  func testReadableFinalAndReplacementOutcomesShareOneProjection() {
    for attempt: NativeAttemptState in [.running, .failed, .cancelled, .preempted] {
      let document = RuntimeTranscriptPresentation(
        native: NativeRuntimeTranscriptSnapshot(
          document: .final, replacementResumable: attempt == .failed,
          state: .final, selectedRevisionIds: ["reviewed"], documentVersion: "reviewed-v1",
          attempt: attempt, attemptFailure: attempt == .failed ? "engine_error" : nil,
          totalTracks: 1, finalTracks: 1, completedChunks: 0, totalChunks: 0, failureClass: nil))
      XCTAssertEqual(document.documentAvailability, .final)
      XCTAssertTrue(document.line(for: nil).text.hasPrefix("Transcript ready · replacement"))
      XCTAssertEqual(document.line(for: nil).text, document.statusText)
    }
    let available = RuntimeTranscriptPresentation(state: .final, finalTracks: 1)
    XCTAssertTrue(available.line(for: .preempted).text.contains("yielded to capture"))
    XCTAssertTrue(available.line(for: .cancelled).text.contains("cancelled"))
    XCTAssertFalse(available.line(for: .cancelled).text.contains("failed"))
  }

  func testIsolatedHistoricalCaptureCannotClaimRecordingOrLeaveTheAttentionList() {
    for lifecycle in ["preparing", "recording", "paused", "finalizing"] {
      let session = RuntimeSessionPresentation(
        native: NativeRuntimeSessionSnapshot(
          sessionId: "historical", title: "Unavailable history", lifecycle: lifecycle,
          health: "healthy", elapsedSeconds: 1, journalDurable: true, mediaFilesOpen: true,
          interruptionReason: nil, recovered: false, hasCaptureTimeline: true,
          sources: [], playableMedia: nil, captureRecoveryIsolated: true))
      XCTAssertEqual(session.lifecycle, lifecycle)
      XCTAssertFalse(session.isRecording)
      XCTAssertFalse(session.isDegradedRecording)
      XCTAssertNil(session.pausedStatusSymbolName)
      XCTAssertTrue(session.needsAttention)
      XCTAssertEqual(session.statusText, "Capture recovery unavailable")
      XCTAssertTrue(session.interruptionText?.contains(lifecycle) == true)
      XCTAssertNotNil(session.transcriptionUnavailableReason)
      XCTAssertTrue(session.deletionUnavailableReason?.contains("recovery") == true)
      XCTAssertEqual(
        LibraryConversationLists.interrupted([session]).map(\.sessionId), ["historical"])
    }
  }

  func testSavedAndInterruptedConversationsRetainTheirTrashAction() {
    for lifecycle in ["ready_for_review", "interrupted"] {
      let session = RuntimeSessionPresentation(
        native: NativeRuntimeSessionSnapshot(
          sessionId: "saved", title: "Saved conversation", lifecycle: lifecycle,
          health: "healthy", elapsedSeconds: 1, journalDurable: true, mediaFilesOpen: false,
          interruptionReason: nil, recovered: lifecycle == "interrupted", hasCaptureTimeline: true,
          sources: [], playableMedia: nil))
      XCTAssertNil(session.deletionUnavailableReason)
    }
  }

  func testRenameRoutesThroughRustAndReportsRefusals() async {
    let titles = TitleBox()
    let store = RuntimeLibraryStore(
      snapshotProvider: { titles.snapshot() },
      renameProvider: { sessionId, title in
        guard sessionId == "s1", !title.isEmpty else { throw NativeStorageError.InvalidRequest }
        titles.set(title)
        return title
      },
      startsPolling: false)
    await waitUntil { store.savedSessions.first != nil }
    XCTAssertEqual(store.savedSessions.first?.title, "Conversation 2026-10-13T17:00:14Z")
    let renamed = await store.rename(sessionId: "s1", title: "Weekly planning")
    XCTAssertEqual(renamed, "Weekly planning")
    XCTAssertNil(store.editMessage)
    for _ in 0..<20 where store.savedSessions.first?.title != "Weekly planning" {
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(store.savedSessions.first?.title, "Weekly planning", "the library is reread")

    let refused = await store.rename(sessionId: "s1", title: "")
    XCTAssertNil(refused)
    XCTAssertTrue(store.editMessageIsFailure)
    XCTAssertEqual(
      store.editMessage,
      "Open Scribe could not rename the conversation: the text is empty, too long, or contains characters that cannot be stored."
    )
    XCTAssertEqual(store.savedSessions.first?.title, "Weekly planning")
  }

  /// A one-session library whose title the test can change.
  private final class TitleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var title = "Conversation 2026-10-13T17:00:14Z"

    func set(_ value: String) {
      lock.lock()
      title = value
      lock.unlock()
    }

    func snapshot() -> NativeRuntimeLibrarySnapshot {
      lock.lock()
      defer { lock.unlock() }
      return NativeRuntimeLibrarySnapshot(
        currentSession: nil,
        savedSessions: [
          NativeRuntimeSessionSnapshot(
            sessionId: "s1", title: title, lifecycle: "ready_for_review", health: "healthy",
            elapsedSeconds: 1, journalDurable: true, mediaFilesOpen: false,
            interruptionReason: nil, recovered: false, hasCaptureTimeline: true,
            sources: [], playableMedia: nil,
            transcript: NativeRuntimeTranscriptSnapshot(
              document: .final, replacementResumable: false,
              state: .final, selectedRevisionIds: ["reviewed-A"], documentVersion: "v1",
              attempt: .complete, attemptFailure: nil, totalTracks: 1,
              finalTracks: 1, completedChunks: 0, totalChunks: 0,
              failureClass: nil))
        ])
    }
  }
}
