import Foundation
import XCTest

@testable import OpenScribeApp

@MainActor
final class ImportedMediaAuthorityAdapterTests: XCTestCase {
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
    XCTAssertTrue(adapter.statusMessage?.contains("supported local CAF") == true)
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
