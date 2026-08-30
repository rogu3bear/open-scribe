import Foundation
import XCTest

@testable import OpenScribeApp

@MainActor
final class ImportedMediaAuthorityAdapterTests: XCTestCase {
  func testSecurityScopeStaysOpenThroughImportAndClosesAfterSuccess() {
    let selectedURL = URL(fileURLWithPath: "/tmp/Interview.caf")
    var events: [String] = []
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
        XCTAssertEqual(title, "Interview")
        XCTAssertEqual(url, selectedURL)
        events.append("import")
        return acceptedEvidence()
      }
    )

    adapter.chooseAndImport()

    XCTAssertEqual(events, ["pick", "start", "import", "stop"])
    XCTAssertEqual(adapter.phase, .succeeded)
    XCTAssertEqual(adapter.importedSessionId, "imported-session")
    XCTAssertEqual(
      adapter.statusMessage,
      "Imported Interview into the local conversation library."
    )
  }

  func testScopeDenialFailsClosedWithoutCallingRustOrStoppingUnopenedScope() {
    var importCalled = false
    var stopCalled = false
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { URL(fileURLWithPath: "/tmp/Denied.caf") },
      startSecurityScope: { _ in false },
      stopSecurityScope: { _ in stopCalled = true },
      importer: { _, _ in
        importCalled = true
        return acceptedEvidence()
      }
    )

    adapter.chooseAndImport()

    XCTAssertEqual(adapter.phase, .failed)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertFalse(importCalled)
    XCTAssertFalse(stopCalled)
    XCTAssertTrue(adapter.statusMessage?.contains("Nothing was added") == true)
  }

  func testRustFailureClosesScopeAndReportsNoLibraryAddition() {
    var stopCalled = false
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { URL(fileURLWithPath: "/tmp/Unsupported.wav") },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in stopCalled = true },
      importer: { _, _ in throw CocoaError(.fileReadCorruptFile) }
    )

    adapter.chooseAndImport()

    XCTAssertTrue(stopCalled)
    XCTAssertEqual(adapter.phase, .failed)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertTrue(adapter.statusMessage?.contains("supported local CAF") == true)
    XCTAssertTrue(adapter.statusMessage?.contains("Nothing was added") == true)
  }

  func testStartingAnotherChoiceClearsThePreviousImportedIdentity() {
    let selectedURL = URL(fileURLWithPath: "/tmp/First.caf")
    var selections: [URL?] = [selectedURL, nil]
    let adapter = ImportedMediaAuthorityAdapter(
      picker: { selections.removeFirst() },
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: { _, _ in acceptedEvidence() }
    )

    adapter.chooseAndImport()
    XCTAssertEqual(adapter.importedSessionId, "imported-session")

    adapter.chooseAndImport()
    XCTAssertEqual(adapter.phase, .idle)
    XCTAssertNil(adapter.importedSessionId)
    XCTAssertNil(adapter.statusMessage)
  }

  func testTerminalPhaseCannotReenterBeforeSecurityScopeCleanupFinishes() {
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

    XCTAssertEqual(pickerCount, 1)
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(adapter.phase, .succeeded)
    XCTAssertEqual(adapter.importedSessionId, "imported-session")
  }

  func testRuntimeStoreRefreshesTheExistingLibraryAfterAcceptedImport() throws {
    let fixture = ImportRuntimeFixture()
    let store = RuntimeLibraryStore(
      snapshotProvider: { fixture.snapshot() },
      importProvider: { title, sourcePath in
        fixture.importMedia(title: title, sourcePath: sourcePath)
      },
      startsPolling: false
    )
    XCTAssertTrue(store.savedSessions.isEmpty)

    let evidence = try store.importManagedCaf(
      title: "Customer interview",
      sourceURL: URL(fileURLWithPath: "/tmp/customer.caf")
    )

    XCTAssertTrue(evidence.readyForReview)
    XCTAssertEqual(store.savedSessions.map(\.sessionId), ["imported-session"])
    XCTAssertEqual(store.savedSessions.map(\.title), ["Customer interview"])
    XCTAssertEqual(store.savedSessions[0].playableMedia?.sourceDisplayName, "customer.caf")
    XCTAssertEqual(store.savedSessions[0].playableMedia?.durationText, "00:00:01")
    XCTAssertEqual(store.savedSessions[0].statusText, "Ready to play")
    XCTAssertTrue(store.savedSessions[0].playableMedia?.isPlayable == true)
    XCTAssertFalse(store.isSnapshotStale)
  }

  func testAcceptedImportSelectsAfterATransientLibraryProjectionFailure() {
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

    adapter.chooseAndImport()

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
