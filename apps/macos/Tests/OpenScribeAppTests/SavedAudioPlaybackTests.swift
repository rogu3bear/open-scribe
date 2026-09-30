@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import OpenScribeApp

@MainActor
final class SavedAudioPlaybackTests: RecoveredSessionTestCase {
  func testImportedTeardownDrainsSchedulingBeforeFinalPlayerStop() {
    var importedSchedulingActive = true
    var staleBufferScheduled = false
    var events: [String] = []

    PlaybackTeardownOrder.release(
      deactivateAndDrainImportedPlayback: {
        events.append("imported-inactive")
        importedSchedulingActive = false
      },
      stopPlayer: {
        events.append("player-stop-completion")
        if importedSchedulingActive {
          staleBufferScheduled = true
        }
      },
      stopEngine: { events.append("engine-stop") }
    )

    XCTAssertEqual(events, ["imported-inactive", "player-stop-completion", "engine-stop"])
    XCTAssertFalse(staleBufferScheduled)
  }

  func testAvailableImportedSessionUsesTheExistingNativeAudioPlayer() async {
    let player = RecoveredAudioPlayerFake()
    let lease = ImportedPlaybackLeaseFake(path: descriptorReceipt())
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in lease },
      player: player
    )
    let imported = savedSession(availability: "available", absolutePath: "/tmp/imported.caf")

    controller.play(imported)
    await assertEventually { controller.playingSessionId == imported.sessionId }

    XCTAssertEqual(controller.playingSessionId, imported.sessionId)
    XCTAssertEqual(controller.activePlaybackSessionId, imported.sessionId)
    XCTAssertEqual(player.importedReceipt, descriptorReceipt())
    XCTAssertEqual(player.importedStartNanoseconds, 0)
    XCTAssertNil(player.recoveredReceipt)
    XCTAssertTrue(player.retainedLease === lease)
    XCTAssertNil(controller.errorMessage)
  }

  func testImportedPlaybackStartsFromTheRequestedMediaPosition() async {
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in ImportedPlaybackLeaseFake(path: descriptorReceipt()) },
      player: player
    )
    let imported = savedSession(availability: "available", absolutePath: "/tmp/imported.m4a")

    controller.play(imported, startNanoseconds: 12_500_000_000)
    await assertEventually { controller.playingSessionId == imported.sessionId }

    XCTAssertEqual(player.importedStartNanoseconds, 12_500_000_000)
  }

  func testPendingImportedPlaybackIsSelectionBoundAndCannotStartAfterDetachment() async {
    let player = RecoveredAudioPlayerFake()
    player.holdImportedPlayback = true
    let pendingLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 42))
    let replacementLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 43))
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { sessionId in
        sessionId == "pending-import" ? pendingLease : replacementLease
      },
      player: player
    )
    let imported = savedSession(
      sessionId: "pending-import",
      availability: "available",
      absolutePath: "/tmp/pending.caf"
    )

    controller.play(imported)
    await assertEventually { player.importedReceipt != nil }

    XCTAssertEqual(controller.activePlaybackSessionId, imported.sessionId)
    XCTAssertNil(controller.playingSessionId)
    XCTAssertTrue(
      MainWorkspaceSelection.shouldStopDetachedPlayback(
        activePlaybackSessionId: controller.activePlaybackSessionId,
        selectedSessionId: "another-conversation"
      )
    )

    controller.stopPlayback()
    player.holdImportedPlayback = false
    let replacement = savedSession(
      sessionId: "replacement-import",
      availability: "available",
      absolutePath: "/tmp/replacement.caf"
    )
    controller.play(replacement)
    await assertEventually { controller.playingSessionId == replacement.sessionId }
    player.releaseImportedPlayback()
    await assertEventually { player.retainedLease === replacementLease }

    XCTAssertEqual(controller.activePlaybackSessionId, replacement.sessionId)
    XCTAssertEqual(controller.playingSessionId, replacement.sessionId)
    XCTAssertTrue(player.retainedLease === replacementLease)
  }

  func testStructuredImportedCopyCancellationAfterReadReturnsReleasesRegionAndLease() async throws {
    let bytes = Data(repeating: 0, count: 128 * 1024)
    let receipt = try ImportedPlaybackDescriptorReceipt(
      serialized: descriptorReceipt(bytes: bytes)
    )
    let readGate = SnapshotReadGate()
    let cancellationObserved = SendableFlag()
    let regionReleased = SendableFlag()
    let leaseReleased = SendableFlag()
    let finished = SendableFlag()
    let copy = Task<Void, Error> {
      defer { finished.set() }
      let lease = PlaybackLifetimeProbe(released: leaseReleased)
      let snapshot = try await StructuredImportedPlaybackCopy.run { isCancelled in
        try AnonymousImportedPlaybackSnapshot.copy(
          from: receipt,
          isCancelled: {
            let cancelled = isCancelled()
            if cancelled { cancellationObserved.set() }
            return cancelled
          },
          onRegionRelease: regionReleased.set,
          readAt: readGate.read
        )
      }
      try Task.checkCancellation()
      try withExtendedLifetime((snapshot, lease)) {
        if Task.isCancelled {
          throw CancellationError()
        }
      }
    }

    await assertEventually { readGate.hasEntered }
    copy.cancel()
    readGate.release()

    let completed = await waitUntil {
      finished.value && regionReleased.value && leaseReleased.value
    }
    XCTAssertTrue(completed)
    guard completed else { return }
    XCTAssertTrue(cancellationObserved.value)
    XCTAssertTrue(regionReleased.value)
    XCTAssertTrue(leaseReleased.value)
    do {
      try await copy.value
      XCTFail("cancelled snapshot copy unexpectedly completed")
    } catch is CancellationError {
      // Expected after the structured child observes cancellation.
    } catch {
      XCTFail("unexpected snapshot copy error: \(error)")
    }
  }

  func testUnavailableAndCorruptCapturedSessionsUseNeutralSavedAudioMessaging() {
    for availability in ["unavailable", "corrupt"] {
      let player = RecoveredAudioPlayerFake()
      let leaseRequested = SendableFlag()
      let controller = RecoveredSessionController(
        recoveryFactory: { RecoveryPreparationFake() },
        importedPlaybackLeaseProvider: { _ in
          leaseRequested.set()
          return ImportedPlaybackLeaseFake(path: descriptorReceipt())
        },
        player: player
      )

      let captured = savedSession(
        sessionId: "session-captured", availability: availability, absolutePath: nil,
        sourceDisplayName: "Mac microphone")
      controller.play(captured)

      XCTAssertNil(controller.playingSessionId)
      XCTAssertNil(controller.activePlaybackSessionId)
      XCTAssertNil(player.recoveredReceipt)
      XCTAssertEqual(player.stopCount, 1)
      XCTAssertFalse(leaseRequested.value)
      XCTAssertEqual(
        controller.errorMessage,
        availability == "corrupt"
          ? "Saved audio appears corrupt and was not opened."
          : "Saved audio is unavailable and was not opened.")
      XCTAssertEqual(controller.errorSessionId, captured.sessionId)
    }
  }

  func testCapturedPlaybackOpenFailureUsesNeutralSavedAudioMessaging() async {
    let player = RecoveredAudioPlayerFake()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in throw CocoaError(.fileReadCorruptFile) },
      player: player
    )

    controller.play(
      savedSession(
        sessionId: "session-captured", availability: "available", absolutePath: nil,
        sourceDisplayName: "Mac microphone"))
    await assertEventually { controller.errorSessionId == "session-captured" }

    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.recoveredReceipt)
    XCTAssertEqual(player.stopCount, 2)
    XCTAssertEqual(controller.errorMessage, "Saved audio could not be opened for playback.")
    XCTAssertEqual(controller.errorSessionId, "session-captured")
  }

  func testFailedImportedReplacementReleasesThePriorLeaseAndPlayingState() async {
    let player = RecoveredAudioPlayerFake()
    let firstLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 42))
    let replacementLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 43))
    let selectedLease = ImportedPlaybackLeaseSelection(firstLease)
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in selectedLease.lease },
      player: player
    )
    let first = savedSession(availability: "available", absolutePath: "/tmp/first.caf")
    controller.play(first)
    await assertEventually { controller.playingSessionId == first.sessionId }
    XCTAssertTrue(player.retainedLease === firstLease)

    selectedLease.select(replacementLease)
    player.playError = CocoaError(.fileReadCorruptFile)
    let replacement = RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "session-replacement",
        title: "Replacement",
        lifecycle: "ready_for_review",
        health: "healthy",
        elapsedSeconds: 2,
        journalDurable: true,
        mediaFilesOpen: false,
        interruptionReason: nil,
        recovered: false,
        hasCaptureTimeline: false,
        sources: [],
        playableMedia: NativeRuntimePlayableMediaSnapshot(
          sourceDisplayName: "replacement.caf",
          availability: "available",
          absolutePath: "/tmp/replacement.caf",
          durationNanoseconds: 2_000_000_000,
          sampleCount: 96_000,
          byteLength: 192_068
        )
      )
    )

    controller.play(replacement)
    await assertEventually { controller.errorMessage != nil }

    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.recoveredReceipt)
    XCTAssertNil(player.retainedLease)
    XCTAssertEqual(controller.errorMessage, "Saved audio could not be opened for playback.")
  }

  func testAnonymousSnapshotAcceptsOnlyTheCompleteAdmittedDigest() throws {
    let accepted = Data("accepted CAF bytes".utf8)
    let receipt = try ImportedPlaybackDescriptorReceipt(
      serialized: descriptorReceipt(bytes: accepted)
    )

    let snapshot = try AnonymousImportedPlaybackSnapshot.copy(from: receipt) {
      offset, buffer in
      let start = Int(offset)
      guard start < accepted.count else { return 0 }
      let count = min(buffer.count, accepted.count - start)
      accepted.copyBytes(
        to: buffer.bindMemory(to: UInt8.self),
        from: start..<(start + count)
      )
      return count
    }

    let context = CallbackAudioFileContext(source: snapshot.region)
    var copied = [UInt8](repeating: 0, count: accepted.count)
    var copiedCount: UInt32 = 0
    let copyStatus = copied.withUnsafeMutableBytes { buffer in
      context.read(
        position: 0,
        requestedCount: UInt32(accepted.count),
        buffer: buffer.baseAddress!,
        actualCount: &copiedCount
      )
    }
    XCTAssertEqual(copyStatus, noErr)
    XCTAssertEqual(copiedCount, UInt32(accepted.count))
    XCTAssertEqual(Data(copied), accepted)

    XCTAssertThrowsError(
      try AnonymousImportedPlaybackSnapshot.copy(from: receipt) { offset, buffer in
        let start = Int(offset)
        guard start < accepted.count - 1 else { return 0 }
        let count = min(buffer.count, accepted.count - 1 - start)
        accepted.copyBytes(
          to: buffer.bindMemory(to: UInt8.self),
          from: start..<(start + count)
        )
        return count
      }
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .incompleteSnapshot)
    }

    let changedReceipt = try ImportedPlaybackDescriptorReceipt(
      serialized: descriptorReceipt(bytes: accepted, digest: String(repeating: "0", count: 64))
    )
    XCTAssertThrowsError(
      try AnonymousImportedPlaybackSnapshot.copy(from: changedReceipt) { offset, buffer in
        let start = Int(offset)
        guard start < accepted.count else { return 0 }
        let count = min(buffer.count, accepted.count - start)
        accepted.copyBytes(
          to: buffer.bindMemory(to: UInt8.self),
          from: start..<(start + count)
        )
        return count
      }
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .changedSnapshot)
    }
  }

  func testAnonymousSnapshotRejectsAbovePlaybackCapBeforeAllocationOrRead() throws {
    let receipt = try ImportedPlaybackDescriptorReceipt(
      serialized:
        "v1;fd=42;byte_length=268435457;sha256=\(String(repeating: "a", count: 64));max_byte_length=268435456"
    )
    var allocationCalled = false
    var readCalled = false

    XCTAssertThrowsError(
      try AnonymousImportedPlaybackSnapshot.copy(
        from: receipt,
        allocator: { _ in
          allocationCalled = true
          return nil
        },
        deallocator: { _, _ in },
        protector: { _, _ in true }
      ) { _, _ in
        readCalled = true
        return 0
      }
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .unsupportedByteLength)
    }
    XCTAssertFalse(allocationCalled)
    XCTAssertFalse(readCalled)
  }

  func testAnonymousSnapshotReportsAllocationFailureBeforeRead() throws {
    let accepted = Data("accepted CAF bytes".utf8)
    let receipt = try ImportedPlaybackDescriptorReceipt(
      serialized: descriptorReceipt(bytes: accepted)
    )
    var readCalled = false

    XCTAssertThrowsError(
      try AnonymousImportedPlaybackSnapshot.copy(
        from: receipt,
        allocator: { _ in nil },
        deallocator: { _, _ in },
        protector: { _, _ in true }
      ) { _, _ in
        readCalled = true
        return 0
      }
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .anonymousAllocationFailed)
    }
    XCTAssertFalse(readCalled)
  }

  func testExactPlaybackCapIsEligibleWithoutAllocatingTheBoundary() throws {
    let receipt = try ImportedPlaybackDescriptorReceipt(
      serialized:
        "v1;fd=42;byte_length=268435456;sha256=\(String(repeating: "a", count: 64));max_byte_length=268435456"
    )

    XCTAssertNoThrow(try ImportedPlaybackMemoryPolicy.validate(receipt))
  }

  func testAudioFileCallbackReadsOnlyWithinTheAnonymousSnapshot() {
    let accepted = Data([10, 20, 30, 40])
    let receipt = try! ImportedPlaybackDescriptorReceipt(
      serialized: descriptorReceipt(bytes: accepted)
    )
    let snapshot = try! AnonymousImportedPlaybackSnapshot.copy(from: receipt) {
      offset, buffer in
      let start = Int(offset)
      guard start < accepted.count else { return 0 }
      let count = min(buffer.count, accepted.count - start)
      accepted.copyBytes(
        to: buffer.bindMemory(to: UInt8.self),
        from: start..<(start + count)
      )
      return count
    }
    let context = CallbackAudioFileContext(source: snapshot.region)
    var output = [UInt8](repeating: 0, count: 4)
    var actualCount: UInt32 = 0
    let status = output.withUnsafeMutableBytes { buffer in
      context.read(
        position: 2,
        requestedCount: 4,
        buffer: buffer.baseAddress!,
        actualCount: &actualCount
      )
    }

    XCTAssertEqual(status, noErr)
    XCTAssertEqual(actualCount, 2)
    XCTAssertEqual(Array(output.prefix(2)), [30, 40])
    let invalidStatus = output.withUnsafeMutableBytes { buffer in
      context.read(
        position: -1,
        requestedCount: 1,
        buffer: buffer.baseAddress!,
        actualCount: &actualCount
      )
    }
    XCTAssertEqual(invalidStatus, kAudioFilePositionError)
  }

  func testNativeImportedCallbacksReachNaturalEOFAndReleaseLeaseDescriptor() async throws {
    let mediaURL = try nativePlaybackCAF(frameCount: 2_400)
    defer { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
    let leaseReleased = SendableFlag()
    var lease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: mediaURL,
      released: leaseReleased
    )
    let descriptor = try XCTUnwrap(lease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(observer: lifecycle.record),
      outputMode: .silent
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let generation = UUID()

    try await player.playImported(
      receipt: try XCTUnwrap(lease).playbackPath(),
      retaining: try XCTUnwrap(lease),
      generation: generation
    )
    lease = nil

    let reachedEOF = await waitUntil { termination.finished(generation: generation) }
    let releasedLease = await waitUntil { leaseReleased.value }
    let releasedRegion = await waitUntil {
      lifecycle.contains(.anonymousRegionReleased(generation))
    }
    XCTAssertTrue(reachedEOF)
    XCTAssertTrue(releasedLease)
    XCTAssertTrue(releasedRegion)
    XCTAssertTrue(lifecycle.contains(.importedDecoderClosed(generation)))
    XCTAssertTrue(lifecycle.contains(.playerStopped(generation)))
    XCTAssertTrue(lifecycle.contains(.engineStopped(generation)))
    errno = 0
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    XCTAssertEqual(errno, EBADF)
  }

  func testNativeImportedReplacementIgnoresOldQueuedCompletion() async throws {
    let firstURL = try nativePlaybackCAF(frameCount: 2_400)
    let secondURL = try nativePlaybackCAF(frameCount: 24_000)
    defer {
      try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
    }
    let firstReleased = SendableFlag()
    let secondReleased = SendableFlag()
    var firstLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: firstURL,
      released: firstReleased
    )
    var secondLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: secondURL,
      released: secondReleased
    )
    let firstDescriptor = try XCTUnwrap(firstLease?.fileDescriptor)
    let secondDescriptor = try XCTUnwrap(secondLease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let completionGate = NativePlaybackCompletionGate()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(
        observer: lifecycle.record,
        importedCompletionDelivery: completionGate.deliver
      ),
      outputMode: .silent
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let firstGeneration = UUID()
    let secondGeneration = UUID()

    try await player.playImported(
      receipt: try XCTUnwrap(firstLease).playbackPath(),
      retaining: try XCTUnwrap(firstLease),
      generation: firstGeneration
    )
    firstLease = nil
    let receivedOldCompletion = await waitUntil { completionGate.isHoldingCompletion }
    XCTAssertTrue(receivedOldCompletion)
    try await player.playImported(
      receipt: try XCTUnwrap(secondLease).playbackPath(),
      retaining: try XCTUnwrap(secondLease),
      generation: secondGeneration
    )
    secondLease = nil
    completionGate.release()

    let releasedFirstLease = await waitUntil { firstReleased.value }
    let deliveredOldCompletion = await waitUntil {
      lifecycle.contains(.importedCompletionDelivered(firstGeneration))
    }
    XCTAssertTrue(releasedFirstLease)
    XCTAssertTrue(deliveredOldCompletion)
    XCTAssertEqual(fcntl(firstDescriptor, F_GETFD), -1)
    XCTAssertFalse(termination.contains(generation: firstGeneration))
    let reachedSecondEOF = await waitUntil { termination.finished(generation: secondGeneration) }
    let releasedSecondLease = await waitUntil { secondReleased.value }
    XCTAssertTrue(reachedSecondEOF)
    XCTAssertTrue(releasedSecondLease)
    XCTAssertEqual(fcntl(secondDescriptor, F_GETFD), -1)
  }

  func testNativeImportedStopDrainsQueuedCompletionAndReleasesLease() async throws {
    let mediaURL = try nativePlaybackCAF(frameCount: 24_000)
    defer { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
    let leaseReleased = SendableFlag()
    var lease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: mediaURL,
      released: leaseReleased
    )
    let descriptor = try XCTUnwrap(lease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(observer: lifecycle.record),
      outputMode: .silent
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let generation = UUID()

    try await player.playImported(
      receipt: try XCTUnwrap(lease).playbackPath(),
      retaining: try XCTUnwrap(lease),
      generation: generation
    )
    lease = nil
    player.stop()

    let releasedLease = await waitUntil { leaseReleased.value }
    let releasedRegion = await waitUntil {
      lifecycle.contains(.anonymousRegionReleased(generation))
    }
    XCTAssertTrue(releasedLease)
    XCTAssertTrue(releasedRegion)
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    XCTAssertTrue(
      lifecycle.occursInOrder([
        .importedSessionDeactivated(generation),
        .importedDecoderClosed(generation),
        .playerStopped(generation),
        .engineStopped(generation),
        .anonymousRegionReleased(generation),
      ])
    )
    XCTAssertFalse(termination.contains(generation: generation))
  }

  func testNativeOutputConfigurationChangeTerminatesAndReleasesImportedLease() async throws {
    let mediaURL = try nativePlaybackCAF(frameCount: 24_000)
    defer { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
    let leaseReleased = SendableFlag()
    var lease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: mediaURL,
      released: leaseReleased
    )
    let descriptor = try XCTUnwrap(lease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(observer: lifecycle.record),
      outputMode: .silent
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let generation = UUID()

    try await player.playImported(
      receipt: try XCTUnwrap(lease?.playbackPath()),
      retaining: try XCTUnwrap(lease),
      generation: generation
    )
    lease = nil
    player.handleOutputConfigurationChange(generation: generation)

    let terminated = await waitUntil {
      termination.contains(generation: generation, outcome: .outputRouteChanged)
    }
    XCTAssertTrue(terminated)
    let released = await waitUntil { leaseReleased.value }
    XCTAssertTrue(released)
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    XCTAssertTrue(
      lifecycle.occursInOrder([
        .outputConfigurationChanged(generation),
        .importedSessionDeactivated(generation),
        .importedDecoderClosed(generation),
        .playerStopped(generation),
        .engineStopped(generation),
        .anonymousRegionReleased(generation),
      ])
    )

    player.handleOutputConfigurationChange(generation: generation)
    XCTAssertTrue(
      termination.contains(generation: generation, outcome: .outputRouteChanged)
    )
  }

  func testRecoveryAndAsyncDecodeFailureReleaseImportedPlayingTruth() async {
    let player = RecoveredAudioPlayerFake()
    let lease = ImportedPlaybackLeaseFake(path: descriptorReceipt())
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in lease },
      player: player
    )
    let imported = savedSession(availability: "available", absolutePath: "/tmp/imported.caf")

    controller.play(imported)
    await assertEventually { controller.playingSessionId == imported.sessionId }
    controller.recoverOnLaunch()
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.retainedLease)

    controller.play(imported)
    await assertEventually { controller.playingSessionId == imported.sessionId }
    let generation = player.importedGeneration!
    player.terminate(generation: generation, outcome: .failed)
    await assertEventually { controller.errorMessage != nil }
    XCTAssertNil(controller.playingSessionId)
    XCTAssertEqual(
      controller.errorMessage,
      "Saved audio playback stopped because decoding failed."
    )
  }

  func testOutputRouteTerminationClearsPlayingTruthAndReportsRestartAction() async {
    let player = RecoveredAudioPlayerFake()
    let lease = ImportedPlaybackLeaseFake(path: descriptorReceipt())
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in lease },
      player: player
    )
    let imported = savedSession(availability: "available", absolutePath: nil)

    controller.play(imported)
    await assertEventually { controller.playingSessionId == imported.sessionId }
    let generation = player.importedGeneration!
    player.terminate(generation: generation, outcome: .outputRouteChanged)

    await assertEventually { controller.errorMessage != nil }
    XCTAssertNil(controller.activePlaybackSessionId)
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.retainedLease)
    XCTAssertEqual(
      controller.errorMessage,
      "Playback stopped because the audio output changed. Press Play to restart."
    )
  }

  func testOldCompletionAfterReplacementCannotMutateCurrentPlaybackTruth() async {
    let player = RecoveredAudioPlayerFake()
    let decisions = PlaybackTerminationDecisionRecorder()
    let firstLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 42))
    let secondLease = ImportedPlaybackLeaseFake(path: descriptorReceipt(fileDescriptor: 43))
    let selectedLease = ImportedPlaybackLeaseSelection(firstLease)
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in selectedLease.lease },
      player: player,
      playbackTerminationDecisionObserver: decisions.record
    )
    let first = savedSession(
      sessionId: "session-first",
      availability: "available",
      absolutePath: "/tmp/first.caf"
    )
    let second = savedSession(
      sessionId: "session-second",
      availability: "available",
      absolutePath: "/tmp/second.caf"
    )

    controller.play(first)
    await assertEventually { controller.playingSessionId == first.sessionId }
    let firstGeneration = player.importedGeneration!

    selectedLease.select(secondLease)
    controller.play(second)
    await assertEventually { controller.playingSessionId == second.sessionId }
    let secondGeneration = player.importedGeneration!
    XCTAssertEqual(controller.playingSessionId, second.sessionId)
    XCTAssertTrue(player.retainedLease === secondLease)

    player.deliverTermination(generation: firstGeneration, outcome: .failed)
    await assertEventually { decisions.decision(for: firstGeneration) == false }

    XCTAssertEqual(controller.playingSessionId, second.sessionId)
    XCTAssertEqual(player.importedGeneration, secondGeneration)
    XCTAssertTrue(player.retainedLease === secondLease)
    XCTAssertNil(controller.errorMessage)

    controller.stopPlayback()
    player.terminate(generation: secondGeneration, outcome: .finished)
    await assertEventually { controller.playingSessionId == nil }
    XCTAssertNil(controller.playingSessionId)
    XCTAssertNil(player.retainedLease)
    XCTAssertNil(controller.errorMessage)
  }

  func testLargeMediaRequestsTheAuthoritativeLeaseBeforePlayback() async {
    let player = RecoveredAudioPlayerFake()
    let leaseRequested = SendableFlag()
    let controller = RecoveredSessionController(
      recoveryFactory: { RecoveryPreparationFake() },
      importedPlaybackLeaseProvider: { _ in
        leaseRequested.set()
        return ImportedPlaybackLeaseFake(path: descriptorReceipt())
      },
      player: player
    )
    let captured = savedSession(
      sessionId: "session-captured",
      availability: "available",
      absolutePath: "/managed/large.caf",
      byteLength: 268_435_457,
      sourceDisplayName: "Mac microphone"
    )

    controller.play(captured)
    await assertEventually { controller.playingSessionId == captured.sessionId }
    XCTAssertNotNil(player.retainedLease)
    XCTAssertTrue(leaseRequested.value)
    XCTAssertNil(controller.errorMessage)
    XCTAssertEqual(captured.playableMedia?.sourceDisplayName, "Mac microphone")
    XCTAssertTrue(captured.playableMedia?.isPlayable == true)
  }
}
