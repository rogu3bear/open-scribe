@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import OpenScribeApp

@MainActor
final class RecoveredAudioPlaybackTests: RecoveredSessionTestCase {
  func testRecoveredDescriptorPlaybackRetainsLeasedObjectAcrossPathReplacement() throws {
    let mediaURL = try nativePlaybackCAF(frameCount: 2_400)
    defer { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
    let original = try Data(contentsOf: mediaURL)
    let leaseReleased = SendableFlag()
    var lease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: mediaURL,
      released: leaseReleased,
      recovered: true
    )
    let receipt = try RecoveredPlaybackDescriptorReceipt(
      serialized: try XCTUnwrap(lease?.playbackPath())
    )

    try FileManager.default.removeItem(at: mediaURL)
    let replacement = Data(repeating: 0xff, count: original.count)
    try replacement.write(to: mediaURL, options: .withoutOverwriting)
    let source = try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt)
    var copied = Data(count: original.count)
    var actualCount: UInt32 = 0
    let status = copied.withUnsafeMutableBytes { buffer in
      source.copyBytes(
        position: 0,
        requestedCount: UInt32(buffer.count),
        buffer: buffer.baseAddress!,
        actualCount: &actualCount
      )
    }

    XCTAssertEqual(status, noErr)
    XCTAssertEqual(actualCount, UInt32(original.count))
    XCTAssertEqual(copied, original)
    XCTAssertNotEqual(try Data(contentsOf: mediaURL), original)
    withExtendedLifetime(lease) {}
    lease = nil
    XCTAssertTrue(leaseReleased.value)
  }

  func testRecoveredDescriptorPreparationRejectsPartialCopyAndHashMismatch() throws {
    let accepted = Data((0..<70_000).map { UInt8($0 % 251) })
    let digest = SHA256.hash(data: accepted).map { String(format: "%02x", $0) }.joined()
    let receipt = try RecoveredPlaybackDescriptorReceipt(
      serialized: recoveredDescriptorReceipt(byteLength: UInt64(accepted.count), digest: digest)
    )
    let backing = DescriptorBytesFake(bytes: accepted)

    XCTAssertThrowsError(
      try VerifiedDescriptorPlaybackSource.prepare(
        receipt: receipt,
        inspect: backing.inspect,
        readAt: { descriptor, offset, buffer in
          let count = try backing.read(descriptor, offset: offset, buffer: buffer)
          return offset == 0 ? count - 1 : count
        }
      )
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .incompleteSnapshot)
    }

    let mismatchedReceipt = try RecoveredPlaybackDescriptorReceipt(
      serialized: recoveredDescriptorReceipt(
        byteLength: UInt64(accepted.count),
        digest: String(repeating: "0", count: 64)
      )
    )
    XCTAssertThrowsError(
      try VerifiedDescriptorPlaybackSource.prepare(
        receipt: mismatchedReceipt,
        inspect: backing.inspect,
        readAt: backing.read
      )
    ) { error in
      XCTAssertEqual(error as? ImportedPlaybackError, .changedSnapshot)
    }
  }

  func testRecoveredDescriptorPlaybackRejectsSameInodeMutationAndIdentityDrift() throws {
    let accepted = Data((0..<70_000).map { UInt8($0 % 251) })
    let digest = SHA256.hash(data: accepted).map { String(format: "%02x", $0) }.joined()
    let receipt = try RecoveredPlaybackDescriptorReceipt(
      serialized: recoveredDescriptorReceipt(byteLength: UInt64(accepted.count), digest: digest)
    )
    let backing = DescriptorBytesFake(bytes: accepted)
    let source = try VerifiedDescriptorPlaybackSource.prepare(
      receipt: receipt,
      inspect: backing.inspect,
      readAt: backing.read
    )
    var output = [UInt8](repeating: 0, count: 32)
    var actualCount: UInt32 = 0

    backing.mutateByte(at: 5)
    let mutationStatus = output.withUnsafeMutableBytes { buffer in
      source.copyBytes(
        position: 0,
        requestedCount: UInt32(buffer.count),
        buffer: buffer.baseAddress!,
        actualCount: &actualCount
      )
    }
    XCTAssertNotEqual(mutationStatus, noErr)
    XCTAssertEqual(actualCount, 0)

    backing.replaceIdentity(device: 7, inode: 12, byteLength: UInt64(accepted.count))
    let replacementStatus = output.withUnsafeMutableBytes { buffer in
      source.copyBytes(
        position: 65_536,
        requestedCount: UInt32(buffer.count),
        buffer: buffer.baseAddress!,
        actualCount: &actualCount
      )
    }
    XCTAssertNotEqual(replacementStatus, noErr)
    XCTAssertEqual(actualCount, 0)
  }

  func testRecoveredDescriptorPlaybackHasNoImportedSnapshotCapOrWholeFileBuffer() throws {
    let byteLength: UInt64 = 268_435_457
    let receipt = try RecoveredPlaybackDescriptorReceipt(
      serialized: recoveredDescriptorReceipt(byteLength: byteLength)
    )
    let source = VerifiedDescriptorPlaybackSource(
      receipt: receipt,
      identity: PlaybackDescriptorIdentity(device: 7, inode: 11, byteLength: byteLength),
      chunkDigests: [],
      inspect: { _ in
        PlaybackDescriptorIdentity(device: 7, inode: 11, byteLength: byteLength)
      },
      readAt: { _, _, _ in 0 }
    )

    XCTAssertEqual(source.callbackByteCount, Int64(byteLength))
    XCTAssertEqual(VerifiedDescriptorPlaybackSource.maximumBufferedByteCount, 65_536)
  }

  func testNativeRecoveredReplacementIgnoresOldEOFAndReleasesActiveLease() async throws {
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
      released: firstReleased,
      recovered: true
    )
    var secondLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: secondURL,
      released: secondReleased,
      recovered: true
    )
    let lifecycle = NativePlaybackLifecycleRecorder()
    let completionGate = NativePlaybackCompletionGate()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(
        observer: lifecycle.record,
        recoveredCompletionDelivery: completionGate.deliver
      )
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let firstGeneration = UUID()
    let secondGeneration = UUID()

    try await player.playRecovered(
      receipt: try XCTUnwrap(firstLease?.playbackPath()),
      retaining: try XCTUnwrap(firstLease),
      generation: firstGeneration
    )
    firstLease = nil
    let receivedOldCompletion = await waitUntil { completionGate.isHoldingCompletion }
    XCTAssertTrue(receivedOldCompletion)
    try await player.playRecovered(
      receipt: try XCTUnwrap(secondLease?.playbackPath()),
      retaining: try XCTUnwrap(secondLease),
      generation: secondGeneration
    )
    secondLease = nil
    completionGate.release()

    let releasedFirstLease = await waitUntil { firstReleased.value }
    let deliveredOldCompletion = await waitUntil {
      lifecycle.contains(.recoveredCompletionDelivered(firstGeneration))
    }
    XCTAssertTrue(releasedFirstLease)
    XCTAssertTrue(deliveredOldCompletion)
    XCTAssertFalse(termination.contains(generation: firstGeneration))
    let reachedSecondEOF = await waitUntil { termination.finished(generation: secondGeneration) }
    let releasedSecondLease = await waitUntil { secondReleased.value }
    XCTAssertTrue(reachedSecondEOF)
    XCTAssertTrue(releasedSecondLease)
  }

  func testNativeRecoveredFailedReplacementReleasesPriorAndReplacementLeases() async throws {
    let firstURL = try nativePlaybackCAF(frameCount: 24_000)
    let replacementURL = try nativePlaybackCAF(frameCount: 24_000)
    defer {
      try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: replacementURL.deletingLastPathComponent())
    }
    let firstReleased = SendableFlag()
    let replacementReleased = SendableFlag()
    var firstLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: firstURL,
      released: firstReleased,
      recovered: true
    )
    var replacementLease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: replacementURL,
      released: replacementReleased,
      recovered: true
    )
    let firstDescriptor = try XCTUnwrap(firstLease?.fileDescriptor)
    let replacementDescriptor = try XCTUnwrap(replacementLease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(observer: lifecycle.record)
    )
    let firstGeneration = UUID()
    let replacementGeneration = UUID()

    try await player.playRecovered(
      receipt: try XCTUnwrap(firstLease?.playbackPath()),
      retaining: try XCTUnwrap(firstLease),
      generation: firstGeneration
    )
    firstLease = nil

    let replacementBytes = try Data(contentsOf: replacementURL)
    let mutationDescriptor = open(replacementURL.path, O_WRONLY | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(mutationDescriptor, 0)
    guard mutationDescriptor >= 0 else { return }
    var changedByte = (try XCTUnwrap(replacementBytes.last)) ^ 0xff
    XCTAssertEqual(
      pwrite(
        mutationDescriptor,
        &changedByte,
        1,
        off_t(replacementBytes.count - 1)
      ),
      1
    )
    XCTAssertEqual(fsync(mutationDescriptor), 0)
    XCTAssertEqual(close(mutationDescriptor), 0)

    do {
      try await player.playRecovered(
        receipt: try XCTUnwrap(replacementLease?.playbackPath()),
        retaining: try XCTUnwrap(replacementLease),
        generation: replacementGeneration
      )
      XCTFail("mutated replacement unexpectedly opened")
    } catch {
      XCTAssertEqual(error as? ImportedPlaybackError, .changedSnapshot)
    }

    let releasedPrior = await waitUntil { firstReleased.value }
    XCTAssertTrue(releasedPrior)
    XCTAssertEqual(fcntl(firstDescriptor, F_GETFD), -1)
    replacementLease = nil
    let releasedReplacement = await waitUntil { replacementReleased.value }
    XCTAssertTrue(releasedReplacement)
    XCTAssertEqual(fcntl(replacementDescriptor, F_GETFD), -1)
    XCTAssertTrue(
      lifecycle.occursInOrder([
        .recoveredSessionDeactivated(firstGeneration),
        .recoveredDecoderClosed(firstGeneration),
        .playerStopped(firstGeneration),
        .engineStopped(firstGeneration),
      ])
    )
  }

  func testNativeRecoveredStopReleasesLeaseDescriptor() async throws {
    let mediaURL = try nativePlaybackCAF(frameCount: 24_000)
    defer { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
    let leaseReleased = SendableFlag()
    var lease: DescriptorPlaybackLeaseProbe? = try DescriptorPlaybackLeaseProbe(
      url: mediaURL,
      released: leaseReleased,
      recovered: true
    )
    let descriptor = try XCTUnwrap(lease?.fileDescriptor)
    let lifecycle = NativePlaybackLifecycleRecorder()
    let player = RecoveredAudioPlayer(
      lifecycle: NativePlaybackLifecycleHooks(observer: lifecycle.record)
    )
    let termination = PlaybackTerminationRecorder()
    player.setPlaybackTerminationHandler { termination.record($0) }
    let generation = UUID()

    try await player.playRecovered(
      receipt: try XCTUnwrap(lease?.playbackPath()),
      retaining: try XCTUnwrap(lease),
      generation: generation
    )
    lease = nil
    player.stop()

    let releasedLease = await waitUntil { leaseReleased.value }
    XCTAssertTrue(releasedLease)
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    XCTAssertTrue(
      lifecycle.occursInOrder([
        .recoveredSessionDeactivated(generation),
        .recoveredDecoderClosed(generation),
        .playerStopped(generation),
        .engineStopped(generation),
      ])
    )
    XCTAssertFalse(termination.contains(generation: generation))
  }
}
