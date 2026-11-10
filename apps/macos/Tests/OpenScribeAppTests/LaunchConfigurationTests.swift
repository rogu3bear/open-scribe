@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import OpenScribeApp

final class LaunchConfigurationTests: XCTestCase {
  func testVerificationBundleCannotFallBackAndOrdinaryBundleCannotRunProofs() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let normal = root.appendingPathComponent("unused-production")
    XCTAssertThrowsError(
      try LaunchConfiguration.resolve(
        arguments: ["app"], environment: [:], normalRoot: normal, verificationBuild: true))
    XCTAssertThrowsError(
      try LaunchConfiguration.resolve(
        arguments: ["app", "--m0-proof-settings", "--verification-root", root.path],
        environment: [:], normalRoot: normal, verificationBuild: false))
    XCTAssertEqual(Bundle.main.bundleIdentifier, "app.open-scribe.dev.verification")
  }

  func testSDKStandardPreferencesUseTheVerificationDomain() throws {
    guard Bundle.main.bundleIdentifier == "app.open-scribe.dev.verification" else {
      XCTFail("Refusing any preference write outside the isolated verification bundle")
      return
    }
    let token = UUID().uuidString
    UserDefaults.standard.set(token, forKey: "OpenScribeVerificationPreferenceProbe")
    XCTAssertEqual(
      UserDefaults.standard.persistentDomain(forName: "app.open-scribe.dev.verification")?[
        "OpenScribeVerificationPreferenceProbe"] as? String, token)
    UserDefaults.standard.removeObject(forKey: "OpenScribeVerificationPreferenceProbe")
  }
  func testUnknownInjectedCaseIsRejectedBeforeAnyHandleCanOpen() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-injected-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let proof = root.appendingPathComponent("Proof")
    try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: false)
    XCTAssertThrowsError(
      try LaunchConfiguration.resolve(
        arguments: [
          "app", "--m1-injected-proof-root", proof.path,
          "--m1-injected-case", "unknown-transition",
        ],
        environment: [:], normalRoot: root.appendingPathComponent("unused-production")))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: proof.path).isEmpty)
  }
  func testEveryProofModeRefusesMissingMalformedProductionAndConflictingRoots() throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-launch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let normal = directory.appendingPathComponent("Production")
    try FileManager.default.createDirectory(at: normal, withIntermediateDirectories: false)
    let sentinel = normal.appendingPathComponent("Library.sqlite3")
    let bytes = Data("production sentinel; no schema migration".utf8)
    try bytes.write(to: sentinel)
    let flags = [
      "--m1-injected-proof-root", "--m1-injected-recovery-root", "--foundation-review-root",
      "--foundation-live-recovery-root", "--foundation-synthetic-capture-root",
      "--foundation-synthetic-recovery-root", "--m1-live-microphone-proof-root",
      "--m1-forced-termination-capture-root", "--m1-forced-termination-recovery-root",
      "--local-only-proof-root", "--local-only-synthetic-proof-root", "--m1-drift-run-root",
    ]
    for flag in flags {
      for badRoot in [normal.path, "relative", "", normal.appendingPathComponent("child").path] {
        XCTAssertThrowsError(
          try LaunchConfiguration.resolve(
            arguments: ["app", flag, badRoot], environment: [:], normalRoot: normal))
      }
      XCTAssertThrowsError(
        try LaunchConfiguration.resolve(
          arguments: ["app", flag], environment: [:], normalRoot: normal))
      XCTAssertThrowsError(
        try LaunchConfiguration.resolve(
          arguments: ["app", flag, directory.path, "--m0-proof-settings"],
          environment: [:], normalRoot: normal))
    }
    XCTAssertThrowsError(
      try LaunchConfiguration.resolve(
        arguments: ["app", "--m0-proof-settings"], environment: [:], normalRoot: normal))
    XCTAssertThrowsError(
      try LaunchConfiguration.resolve(
        arguments: ["app", "--open-scribe-test-host"], environment: [:], normalRoot: normal))
    XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: normal.path), ["Library.sqlite3"])
  }

  func testLocalOnlyProofKeepsSyntheticAndExplicitLiveModesDistinct() throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-local-proof-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("Proof")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let normal = directory.appendingPathComponent("unused-production")
    let suite = "OpenScribe.Proof.\(UUID().uuidString)"
    for (flag, expected) in [
      ("--local-only-synthetic-proof-root", LaunchConfiguration.Mode.synthetic),
      ("--local-only-proof-root", .live),
    ] {
      let configuration = try LaunchConfiguration.resolve(
        arguments: ["app", flag, root.path, "--verification-preferences", suite],
        environment: [:], normalRoot: normal)
      XCTAssertEqual(configuration.mode, expected)
      XCTAssertEqual(configuration.action, .localOnly)
      XCTAssertEqual(configuration.libraryRoot.path, root.appendingPathComponent("Library").path)
      XCTAssertTrue(configuration.suspendsAutomation)
      XCTAssertFalse(configuration.preferences === UserDefaults.standard)
      configuration.preferences.removePersistentDomain(forName: suite)
    }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: normal.path))
  }

  func testSceneAndTestHostUseExplicitRootAndIsolatedPreferencesWithoutRecoveryFallback() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-proof-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let normal = root.appendingPathComponent("unused-production")
    let library = root.appendingPathComponent("Proof")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
    for mode in ["--m0-proof-settings", "--open-scribe-test-host"] {
      let suite = "OpenScribe.Proof.\(UUID().uuidString)"
      let config = try LaunchConfiguration.resolve(
        arguments: [
          "app", mode, "--verification-root", library.path,
          "--verification-preferences", suite,
        ], environment: [:], normalRoot: normal)
      XCTAssertEqual(config.libraryRoot.path, library.path)
      XCTAssertTrue(config.suspendsAutomation)
      XCTAssertFalse(config.preferences === UserDefaults.standard)
      config.preferences.removePersistentDomain(forName: suite)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: normal.path))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
  }

  func testProofFlagsAreRejectedInReleaseAndRedirectedRootsAreRefused() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-launch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("redirected")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    for (path, permitted) in [(root.path, false), (link.path, true)] {
      XCTAssertThrowsError(
        try LaunchConfiguration.resolve(
          arguments: ["app", "--m0-proof-settings", "--verification-root", path],
          environment: [:], normalRoot: root.appendingPathComponent("production"),
          permitsProofs: permitted))
    }
    let proof = root.appendingPathComponent("Proof")
    try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: false)
    let nested = proof.appendingPathComponent("Library")
    let production = root.appendingPathComponent("production")
    try FileManager.default.createDirectory(at: production, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: production)
    for flag in ["--local-only-proof-root", "--local-only-synthetic-proof-root"] {
      XCTAssertThrowsError(
        try LaunchConfiguration.resolve(
          arguments: ["app", flag, root.path], environment: [:], normalRoot: production,
          permitsProofs: false))
      XCTAssertThrowsError(
        try LaunchConfiguration.resolve(
          arguments: ["app", flag, proof.path], environment: [:], normalRoot: production))
    }
    XCTAssertThrowsError(
      try LaunchConfiguration.resolve(
        arguments: [
          "app", "--open-scribe-test-host", "--verification-root", proof.path,
          "--verification-preferences", "OpenScribe.Proof.one",
        ],
        environment: ["OPEN_SCRIBE_PROOF_PREFERENCES": "OpenScribe.Proof.two"],
        normalRoot: production))
  }

  func testCancellationAfterDurableMutationReturnsItsCommittedResult() async throws {
    final class Checkpoint: @unchecked Sendable {
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      func awaitEntered() { entered.wait() }
    }
    let checkpoint = Checkpoint()
    let task = Task {
      try await StructuredNativeIO.mutation {
        checkpoint.entered.signal()
        checkpoint.release.wait()
        return "committed"
      }
    }
    await Task.detached { checkpoint.awaitEntered() }.value
    task.cancel()
    checkpoint.release.signal()
    let result = try await task.value
    XCTAssertEqual(result, "committed", "cancellation must reconcile an already committed mutation")
  }

  /// The shipped verification app reaches the preparation checkpoint, stops, and
  /// is killed by this test. Relaunch recovers an interrupted session and does
  /// not invent audio or a second journal.
  func testKillPreparationStopsBeforeMediaAndRecoversInterrupted() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-kill-preparation-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }

    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "kill-preparation",
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let checkpointURL = proof.appendingPathComponent("checkpoint.json")
    let reached = await Self.waitForFile(checkpointURL, seconds: 45, process: capture)
    guard reached else {
      XCTFail(Self.launchFailure("preparation checkpoint was not reached", proof: proof, process: capture))
      return
    }
    let stopped = await Self.waitUntil(seconds: 5) { Self.processIsStopped(capture) }
    XCTAssertTrue(stopped, Self.launchFailure("process did not stop at the checkpoint", proof: proof, process: capture))
    let checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any]
    let sessionId = try XCTUnwrap(checkpoint?["session_id"] as? String)
    XCTAssertEqual(checkpoint?["phase"] as? String, "preparation")
    XCTAssertEqual((checkpoint?["pid"] as? NSNumber)?.int32Value, capture.processIdentifier)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    XCTAssertEqual(try Self.cafPaths(under: media), [])
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let journalBeforeKill = try Data(contentsOf: journal)
    XCTAssertFalse(String(decoding: journalBeforeKill, as: UTF8.self).contains("recording_started"))

    kill(pid_t(capture.processIdentifier), SIGKILL)
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationReason, .uncaughtSignal)
    XCTAssertEqual(capture.terminationStatus, SIGKILL)

    let firstRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-out.log"),
      standardError: proof.appendingPathComponent("recovery-err.log"))
    child = firstRecovery
    let recoveryURL = proof.appendingPathComponent("recovery.json")
    let recovered = await Self.waitForFile(recoveryURL, seconds: 45, process: firstRecovery)
    guard recovered else {
      XCTFail(Self.launchFailure("recovery did not report", proof: proof, process: firstRecovery))
      return
    }
    firstRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(firstRecovery.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let firstReport = try Data(contentsOf: recoveryURL)
    let report = try JSONSerialization.jsonObject(with: firstReport) as? [String: Any]
    XCTAssertEqual(report?["result"] as? String, "INJECTED_RECOVERY_GREEN")
    XCTAssertEqual(report?["session_id"] as? String, sessionId)
    XCTAssertEqual(report?["lifecycle"] as? String, "interrupted")
    XCTAssertEqual(report?["visible_lifecycle"] as? String, "interrupted")
    XCTAssertEqual((report?["rendered_frames"] as? NSNumber)?.intValue, 0)
    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let detail = try preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "interrupted")
    let kinds = try Self.journalKinds(journal)
    XCTAssertFalse(kinds.contains("recording_started"))
    XCTAssertTrue(kinds.contains("session_interrupted"), kinds.joined(separator: ","))
    XCTAssertEqual(try Self.cafPaths(under: media), [])
    let journalAfterRecovery = SHA256.hash(data: try Data(contentsOf: journal))

    let secondRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-second-out.log"),
      standardError: proof.appendingPathComponent("recovery-second-err.log"))
    child = secondRecovery
    let sawSecond = await Self.waitUntil(seconds: 45) { secondRecovery.isRunning == false }
    XCTAssertTrue(sawSecond, Self.launchFailure("second recovery did not exit", proof: proof, process: secondRecovery))
    secondRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(secondRecovery.terminationStatus, 0)
    XCTAssertEqual(try Data(contentsOf: recoveryURL), firstReport)
    XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: journal)), journalAfterRecovery)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
  }

  /// The shipped verification app reaches Recording, with a durable sample on
  /// each source, and suspends at that checkpoint. This test kills that process.
  /// Recovery keeps both source files and makes the session reviewable. A second
  /// launch does not append the journal.
  func testKillRecordingKeepsBothSourcesAfterForcedTermination() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-kill-recording-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }

    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "kill-recording",
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let checkpointURL = proof.appendingPathComponent("checkpoint.json")
    let reached = await Self.waitForFile(checkpointURL, seconds: 45, process: capture)
    guard reached else {
      XCTFail(Self.launchFailure("recording checkpoint was not reached", proof: proof, process: capture))
      return
    }
    let stopped = await Self.waitUntil(seconds: 5) { Self.processIsStopped(capture) }
    XCTAssertTrue(stopped, Self.launchFailure("process did not stop at the recording checkpoint", proof: proof, process: capture))
    let checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any]
    let sessionId = try XCTUnwrap(checkpoint?["session_id"] as? String)
    XCTAssertEqual(checkpoint?["phase"] as? String, "recording")
    XCTAssertEqual((checkpoint?["pid"] as? NSNumber)?.int32Value, capture.processIdentifier)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let capturedAudio = try Self.cafPaths(under: media)
    XCTAssertEqual(capturedAudio.count, 2)
    let audioBeforeKill = try Dictionary(uniqueKeysWithValues: capturedAudio.map { path in
      (path, try Self.fileDigest(path))
    })
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let kindsBeforeKill = try Self.journalKinds(journal)
    XCTAssertTrue(kindsBeforeKill.contains("recording_started"), kindsBeforeKill.joined(separator: ","))
    XCTAssertFalse(kindsBeforeKill.contains("marker_added"))

    kill(pid_t(capture.processIdentifier), SIGKILL)
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationReason, .uncaughtSignal)
    XCTAssertEqual(capture.terminationStatus, SIGKILL)

    let firstRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-out.log"),
      standardError: proof.appendingPathComponent("recovery-err.log"))
    child = firstRecovery
    let recoveryURL = proof.appendingPathComponent("recovery.json")
    let recovered = await Self.waitForFile(recoveryURL, seconds: 45, process: firstRecovery)
    guard recovered else {
      XCTFail(Self.launchFailure("recording recovery did not report", proof: proof, process: firstRecovery))
      return
    }
    firstRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(firstRecovery.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let firstReport = try Data(contentsOf: recoveryURL)
    let report = try JSONSerialization.jsonObject(with: firstReport) as? [String: Any]
    XCTAssertEqual(report?["result"] as? String, "INJECTED_RECOVERY_GREEN")
    XCTAssertEqual(report?["session_id"] as? String, sessionId)
    XCTAssertEqual(report?["lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual(report?["visible_lifecycle"] as? String, "ready_for_review")
    XCTAssertGreaterThan((report?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    for (path, digest) in audioBeforeKill {
      XCTAssertEqual(try Self.fileDigest(path), digest)
    }
    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    let tracks = Set(plan.map(\.trackId))
    XCTAssertEqual(tracks.count, 2)
    for track in tracks {
      let frames = plan.filter { $0.trackId == track }.reduce(UInt64(0)) { $0 + $1.sampleCount }
      XCTAssertGreaterThanOrEqual(frames, 48_000)
    }
    XCTAssertTrue(try Self.journalKinds(journal).contains("recording_started"))
    let journalAfterRecovery = SHA256.hash(data: try Data(contentsOf: journal))

    let secondRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-second-out.log"),
      standardError: proof.appendingPathComponent("recovery-second-err.log"))
    child = secondRecovery
    let sawSecond = await Self.waitUntil(seconds: 45) { secondRecovery.isRunning == false }
    XCTAssertTrue(sawSecond, Self.launchFailure("second recording recovery did not exit", proof: proof, process: secondRecovery))
    secondRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(secondRecovery.terminationStatus, 0)
    XCTAssertEqual(try Data(contentsOf: recoveryURL), firstReport)
    XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: journal)), journalAfterRecovery)
    for (path, digest) in audioBeforeKill {
      XCTAssertEqual(try Self.fileDigest(path), digest)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
  }

  /// The shipped verification app reaches Stop after a durable sample on each
  /// source and one marker, then suspends at that checkpoint. This test kills
  /// that process. Recovery keeps both source files and the marker and makes
  /// the session reviewable. A second launch does not append the journal.
  func testKillStopKeepsTheMarkerAndBothSourcesAfterForcedTermination() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-kill-stop-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }

    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "kill-stop",
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let checkpointURL = proof.appendingPathComponent("checkpoint.json")
    let reached = await Self.waitForFile(checkpointURL, seconds: 45, process: capture)
    guard reached else {
      XCTFail(Self.launchFailure("stop checkpoint was not reached", proof: proof, process: capture))
      return
    }
    let stopped = await Self.waitUntil(seconds: 5) { Self.processIsStopped(capture) }
    XCTAssertTrue(stopped, Self.launchFailure("process did not stop at the stop checkpoint", proof: proof, process: capture))
    let checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any]
    let sessionId = try XCTUnwrap(checkpoint?["session_id"] as? String)
    XCTAssertEqual(checkpoint?["phase"] as? String, "stop")
    XCTAssertEqual((checkpoint?["pid"] as? NSNumber)?.int32Value, capture.processIdentifier)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let capturedAudio = try Self.cafPaths(under: media)
    XCTAssertEqual(capturedAudio.count, 2)
    let audioBeforeKill = try Dictionary(uniqueKeysWithValues: capturedAudio.map { path in
      (path, try Self.fileDigest(path))
    })
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let kindsBeforeKill = try Self.journalKinds(journal)
    XCTAssertTrue(kindsBeforeKill.contains("recording_started"), kindsBeforeKill.joined(separator: ","))
    XCTAssertTrue(kindsBeforeKill.contains("marker_added"), kindsBeforeKill.joined(separator: ","))

    kill(pid_t(capture.processIdentifier), SIGKILL)
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationReason, .uncaughtSignal)
    XCTAssertEqual(capture.terminationStatus, SIGKILL)

    let firstRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-out.log"),
      standardError: proof.appendingPathComponent("recovery-err.log"))
    child = firstRecovery
    let recoveryURL = proof.appendingPathComponent("recovery.json")
    let recovered = await Self.waitForFile(recoveryURL, seconds: 45, process: firstRecovery)
    guard recovered else {
      XCTFail(Self.launchFailure("stop recovery did not report", proof: proof, process: firstRecovery))
      return
    }
    firstRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(firstRecovery.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let firstReport = try Data(contentsOf: recoveryURL)
    let report = try JSONSerialization.jsonObject(with: firstReport) as? [String: Any]
    XCTAssertEqual(report?["result"] as? String, "INJECTED_RECOVERY_GREEN")
    XCTAssertEqual(report?["session_id"] as? String, sessionId)
    XCTAssertEqual(report?["lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual(report?["visible_lifecycle"] as? String, "ready_for_review")
    XCTAssertGreaterThan((report?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    for (path, digest) in audioBeforeKill {
      XCTAssertEqual(try Self.fileDigest(path), digest)
    }
    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    let tracks = Set(plan.map(\.trackId))
    XCTAssertEqual(tracks.count, 2)
    for track in tracks {
      let frames = plan.filter { $0.trackId == track }.reduce(UInt64(0)) { $0 + $1.sampleCount }
      XCTAssertGreaterThanOrEqual(frames, 48_000)
    }
    let kindsAfterRecovery = try Self.journalKinds(journal)
    XCTAssertTrue(kindsAfterRecovery.contains("recording_started"))
    XCTAssertTrue(kindsAfterRecovery.contains("marker_added"))
    let journalAfterRecovery = SHA256.hash(data: try Data(contentsOf: journal))

    let secondRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-second-out.log"),
      standardError: proof.appendingPathComponent("recovery-second-err.log"))
    child = secondRecovery
    let sawSecond = await Self.waitUntil(seconds: 45) { secondRecovery.isRunning == false }
    XCTAssertTrue(sawSecond, Self.launchFailure("second stop recovery did not exit", proof: proof, process: secondRecovery))
    secondRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(secondRecovery.terminationStatus, 0)
    XCTAssertEqual(try Data(contentsOf: recoveryURL), firstReport)
    XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: journal)), journalAfterRecovery)
    for (path, digest) in audioBeforeKill {
      XCTAssertEqual(try Self.fileDigest(path), digest)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
  }

  /// The shipped verification app reaches the seal boundary after a durable
  /// sample on each source and one marker, then suspends before either segment
  /// is journaled as sealed. This test kills that process. Recovery keeps both
  /// source files and the marker, records each source as playable media, and
  /// makes the session reviewable. A second launch does not append the journal.
  func testKillSealRecoversReviewableMediaAfterForcedTermination() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-kill-seal-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }

    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "kill-seal",
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let checkpointURL = proof.appendingPathComponent("checkpoint.json")
    let reached = await Self.waitForFile(checkpointURL, seconds: 45, process: capture)
    guard reached else {
      XCTFail(Self.launchFailure("seal checkpoint was not reached", proof: proof, process: capture))
      return
    }
    let stopped = await Self.waitUntil(seconds: 5) { Self.processIsStopped(capture) }
    XCTAssertTrue(stopped, Self.launchFailure("process did not stop at the seal checkpoint", proof: proof, process: capture))
    let checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any]
    let sessionId = try XCTUnwrap(checkpoint?["session_id"] as? String)
    XCTAssertEqual(checkpoint?["phase"] as? String, "seal")
    XCTAssertEqual((checkpoint?["pid"] as? NSNumber)?.int32Value, capture.processIdentifier)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let capturedAudio = try Self.cafPaths(under: media)
    XCTAssertEqual(capturedAudio.count, 2)
    let audioBeforeKill = try Dictionary(uniqueKeysWithValues: capturedAudio.map { path in
      (path, try Self.fileDigest(path))
    })
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let kindsBeforeKill = try Self.journalKinds(journal)
    XCTAssertTrue(kindsBeforeKill.contains("recording_started"), kindsBeforeKill.joined(separator: ","))
    XCTAssertTrue(kindsBeforeKill.contains("marker_added"), kindsBeforeKill.joined(separator: ","))
    XCTAssertFalse(kindsBeforeKill.contains("segment_sealed"), kindsBeforeKill.joined(separator: ","))
    XCTAssertFalse(kindsBeforeKill.contains("playable_media_recovered"), kindsBeforeKill.joined(separator: ","))

    kill(pid_t(capture.processIdentifier), SIGKILL)
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationReason, .uncaughtSignal)
    XCTAssertEqual(capture.terminationStatus, SIGKILL)

    let firstRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-out.log"),
      standardError: proof.appendingPathComponent("recovery-err.log"))
    child = firstRecovery
    let recoveryURL = proof.appendingPathComponent("recovery.json")
    let recovered = await Self.waitForFile(recoveryURL, seconds: 45, process: firstRecovery)
    guard recovered else {
      XCTFail(Self.launchFailure("seal recovery did not report", proof: proof, process: firstRecovery))
      return
    }
    firstRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(firstRecovery.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let firstReport = try Data(contentsOf: recoveryURL)
    let report = try JSONSerialization.jsonObject(with: firstReport) as? [String: Any]
    XCTAssertEqual(report?["result"] as? String, "INJECTED_RECOVERY_GREEN")
    XCTAssertEqual(report?["session_id"] as? String, sessionId)
    XCTAssertEqual(report?["lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual(report?["visible_lifecycle"] as? String, "ready_for_review")
    XCTAssertGreaterThan((report?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    for (path, digest) in audioBeforeKill {
      XCTAssertEqual(try Self.fileDigest(path), digest)
    }
    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    let tracks = Set(plan.map(\.trackId))
    XCTAssertEqual(tracks.count, 2)
    for track in tracks {
      let frames = plan.filter { $0.trackId == track }.reduce(UInt64(0)) { $0 + $1.sampleCount }
      XCTAssertGreaterThanOrEqual(frames, 48_000)
    }
    let kindsAfterRecovery = try Self.journalKinds(journal)
    XCTAssertTrue(kindsAfterRecovery.contains("recording_started"))
    XCTAssertTrue(kindsAfterRecovery.contains("marker_added"))
    XCTAssertFalse(kindsAfterRecovery.contains("segment_sealed"), kindsAfterRecovery.joined(separator: ","))
    XCTAssertEqual(kindsAfterRecovery.filter { $0 == "playable_media_recovered" }.count, 2)
    let journalAfterRecovery = SHA256.hash(data: try Data(contentsOf: journal))

    let secondRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-second-out.log"),
      standardError: proof.appendingPathComponent("recovery-second-err.log"))
    child = secondRecovery
    let sawSecond = await Self.waitUntil(seconds: 45) { secondRecovery.isRunning == false }
    XCTAssertTrue(sawSecond, Self.launchFailure("second seal recovery did not exit", proof: proof, process: secondRecovery))
    secondRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(secondRecovery.terminationStatus, 0)
    XCTAssertEqual(try Data(contentsOf: recoveryURL), firstReport)
    XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: journal)), journalAfterRecovery)
    for (path, digest) in audioBeforeKill {
      XCTAssertEqual(try Self.fileDigest(path), digest)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
  }

  /// The shipped verification app seals both sources, opens the derived mix,
  /// and suspends before that mix is validated. This test kills that process.
  /// Recovery keeps both source files, the marker, and the sealed segments, and
  /// the session stays reviewable. A second launch does not append the journal.
  func testKillProcessingKeepsSealedSourcesAfterForcedTermination() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-kill-processing-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }

    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "kill-processing",
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let checkpointURL = proof.appendingPathComponent("checkpoint.json")
    let reached = await Self.waitForFile(checkpointURL, seconds: 45, process: capture)
    guard reached else {
      XCTFail(Self.launchFailure("processing checkpoint was not reached", proof: proof, process: capture))
      return
    }
    let stopped = await Self.waitUntil(seconds: 5) { Self.processIsStopped(capture) }
    XCTAssertTrue(stopped, Self.launchFailure("process did not stop at the processing checkpoint", proof: proof, process: capture))
    let checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any]
    let sessionId = try XCTUnwrap(checkpoint?["session_id"] as? String)
    XCTAssertEqual(checkpoint?["phase"] as? String, "processing")
    XCTAssertEqual((checkpoint?["pid"] as? NSNumber)?.int32Value, capture.processIdentifier)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let capturedAudio = try Self.cafPaths(under: media)
    XCTAssertEqual(capturedAudio.count, 2)
    XCTAssertEqual(try Self.mediaPaths(under: media, suffix: ".m4a").count, 1)
    let audioBeforeKill = try Dictionary(uniqueKeysWithValues: capturedAudio.map { path in
      (path, try Self.fileDigest(path))
    })
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let kindsBeforeKill = try Self.journalKinds(journal)
    XCTAssertTrue(kindsBeforeKill.contains("recording_started"), kindsBeforeKill.joined(separator: ","))
    XCTAssertTrue(kindsBeforeKill.contains("marker_added"), kindsBeforeKill.joined(separator: ","))
    XCTAssertEqual(kindsBeforeKill.filter { $0 == "segment_sealed" }.count, 2)
    XCTAssertEqual(kindsBeforeKill.filter { $0 == "mixdown_intent" }.count, 1)
    XCTAssertFalse(kindsBeforeKill.contains("mixdown_validated"), kindsBeforeKill.joined(separator: ","))
    XCTAssertFalse(kindsBeforeKill.contains("playable_media_recovered"), kindsBeforeKill.joined(separator: ","))

    kill(pid_t(capture.processIdentifier), SIGKILL)
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationReason, .uncaughtSignal)
    XCTAssertEqual(capture.terminationStatus, SIGKILL)

    let firstRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-out.log"),
      standardError: proof.appendingPathComponent("recovery-err.log"))
    child = firstRecovery
    let recoveryURL = proof.appendingPathComponent("recovery.json")
    let recovered = await Self.waitForFile(recoveryURL, seconds: 45, process: firstRecovery)
    guard recovered else {
      XCTFail(Self.launchFailure("processing recovery did not report", proof: proof, process: firstRecovery))
      return
    }
    firstRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(firstRecovery.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let firstReport = try Data(contentsOf: recoveryURL)
    let report = try JSONSerialization.jsonObject(with: firstReport) as? [String: Any]
    XCTAssertEqual(report?["result"] as? String, "INJECTED_RECOVERY_GREEN")
    XCTAssertEqual(report?["session_id"] as? String, sessionId)
    XCTAssertEqual(report?["lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual(report?["visible_lifecycle"] as? String, "ready_for_review")
    XCTAssertGreaterThan((report?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    for (path, digest) in audioBeforeKill {
      XCTAssertEqual(try Self.fileDigest(path), digest)
    }
    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    let tracks = Set(plan.map(\.trackId))
    XCTAssertEqual(tracks.count, 2)
    for track in tracks {
      let frames = plan.filter { $0.trackId == track }.reduce(UInt64(0)) { $0 + $1.sampleCount }
      XCTAssertGreaterThanOrEqual(frames, 48_000)
    }
    let kindsAfterRecovery = try Self.journalKinds(journal)
    XCTAssertTrue(kindsAfterRecovery.contains("recording_started"))
    XCTAssertTrue(kindsAfterRecovery.contains("marker_added"))
    XCTAssertEqual(kindsAfterRecovery.filter { $0 == "segment_sealed" }.count, 2)
    XCTAssertEqual(kindsAfterRecovery.filter { $0 == "mixdown_intent" }.count, 1)
    XCTAssertFalse(kindsAfterRecovery.contains("mixdown_validated"), kindsAfterRecovery.joined(separator: ","))
    let journalAfterRecovery = SHA256.hash(data: try Data(contentsOf: journal))

    let secondRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-second-out.log"),
      standardError: proof.appendingPathComponent("recovery-second-err.log"))
    child = secondRecovery
    let sawSecond = await Self.waitUntil(seconds: 45) { secondRecovery.isRunning == false }
    XCTAssertTrue(sawSecond, Self.launchFailure("second processing recovery did not exit", proof: proof, process: secondRecovery))
    secondRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(secondRecovery.terminationStatus, 0)
    XCTAssertEqual(try Data(contentsOf: recoveryURL), firstReport)
    XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: journal)), journalAfterRecovery)
    for (path, digest) in audioBeforeKill {
      XCTAssertEqual(try Self.fileDigest(path), digest)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
  }

  /// The shipped verification app pauses after a durable sample and marker,
  /// resumes on new synthetic sources, and saves more than one additional
  /// second from each source. This launch does not open platform capture
  /// devices. The real-device live-pause-resume case stays a live launch.
  func testSyntheticPauseResumeKeepsBothSourcesAcrossTheBoundary() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-pause-resume-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let normal = base.appendingPathComponent("unused-production")
    let suite = "OpenScribe.Proof.\(UUID().uuidString)"
    let synthetic = try LaunchConfiguration.resolve(
      arguments: [
        "app", "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "pause-resume",
        "--verification-preferences", suite,
      ],
      environment: [:], normalRoot: normal)
    XCTAssertEqual(synthetic.mode, .synthetic)
    XCTAssertEqual(synthetic.action, .injected("pause-resume"))
    synthetic.preferences.removePersistentDomain(forName: suite)
    let live = try LaunchConfiguration.resolve(
      arguments: [
        "app", "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "live-pause-resume",
        "--verification-preferences", suite,
      ],
      environment: [:], normalRoot: normal)
    XCTAssertEqual(live.mode, .live)
    XCTAssertEqual(live.action, .injected("live-pause-resume"))
    live.preferences.removePersistentDomain(forName: suite)

    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }
    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "pause-resume",
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let outcomeURL = proof.appendingPathComponent("outcome.json")
    let finished = await Self.waitForFile(outcomeURL, seconds: 45, process: capture)
    guard finished else {
      XCTFail(Self.launchFailure("pause-resume outcome was not written", proof: proof, process: capture))
      return
    }
    let exited = await Self.waitUntil(seconds: 20) { capture.isRunning == false }
    XCTAssertTrue(exited, Self.launchFailure("pause-resume launch did not exit", proof: proof, process: capture))
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let outcomeData = try Data(contentsOf: outcomeURL)
    let outcomeText = String(decoding: outcomeData, as: UTF8.self)
    XCTAssertFalse(outcomeText.contains("AVAudioEngine+ScreenCaptureKit"))
    XCTAssertFalse(outcomeText.contains("live-pause-resume"))
    let outcome = try JSONSerialization.jsonObject(with: outcomeData) as? [String: Any]
    XCTAssertEqual(outcome?["result"] as? String, "INJECTED_CASE_GREEN")
    XCTAssertEqual(outcome?["scenario"] as? String, "pause-resume")
    XCTAssertEqual(outcome?["capture_backend"] as? String, "synthetic")
    XCTAssertEqual(outcome?["lifecycle"] as? String, "ready_for_review")
    XCTAssertFalse((outcome?["paused_status"] as? String)?.isEmpty ?? true)
    XCTAssertFalse((outcome?["resumed_status"] as? String)?.isEmpty ?? true)
    XCTAssertGreaterThan((outcome?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    let sessionId = try XCTUnwrap(outcome?["session_id"] as? String)
    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let detail = try preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "ready_for_review")
    for kind in ["capture_paused", "capture_resumed", "marker_added"] {
      XCTAssertTrue(detail.events.contains { $0.kind == kind }, kind)
    }
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let kinds = try Self.journalKinds(journal)
    XCTAssertTrue(kinds.contains("recording_started"), kinds.joined(separator: ","))
    XCTAssertEqual(kinds.filter { $0 == "capture_paused" }.count, 1)
    XCTAssertEqual(kinds.filter { $0 == "capture_resumed" }.count, 1)
    XCTAssertEqual(kinds.filter { $0 == "marker_added" }.count, 1)
    XCTAssertEqual(kinds.filter { $0 == "segment_sealed" }.count, 4)
    XCTAssertFalse(kinds.contains("playable_media_recovered"), kinds.joined(separator: ","))
    let pausedAt = try XCTUnwrap(
      detail.events.last { $0.kind == "capture_paused" }?.sessionNanoseconds)
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(plan.count, 4)
    let tracks = Set(plan.map(\.trackId))
    XCTAssertEqual(tracks.count, 2)
    for track in tracks {
      let rows = plan.filter { $0.trackId == track }
      let prior = rows.filter { $0.nativeStartNanoseconds < pausedAt }
      let later = rows.filter { $0.nativeStartNanoseconds >= pausedAt }
      XCTAssertEqual(prior.map(\.sampleCount), [48_000])
      XCTAssertEqual(later.map(\.sampleCount), [96_000])
      let priorFrames = prior.reduce(UInt64(0)) { $0 + $1.sampleCount }
      let finalFrames = rows.reduce(UInt64(0)) { $0 + $1.sampleCount }
      XCTAssertGreaterThanOrEqual(priorFrames, 48_000)
      XCTAssertGreaterThan(finalFrames, priorFrames + 48_000)
    }
    XCTAssertEqual(try Self.cafPaths(under: media).count, 4)
  }

  /// The shipped verification app records both synthetic sources, observes a
  /// storage warning, and keeps capturing. Stop then validates the stereo mix.
  /// This launch does not open platform capture devices.
  func testStorageWarningLaunchContinuesCaptureThenValidatesTheStereoMix() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-storage-warning-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let normal = base.appendingPathComponent("unused-production")
    let suite = "OpenScribe.Proof.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let resolved = try LaunchConfiguration.resolve(
      arguments: [
        "app", "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "storage-warning",
        "--verification-preferences", suite,
      ],
      environment: [:], normalRoot: normal)
    XCTAssertEqual(resolved.mode, .synthetic)
    XCTAssertEqual(resolved.action, .injected("storage-warning"))

    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }
    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "storage-warning",
        "--verification-preferences", suite,
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let outcomeURL = proof.appendingPathComponent("outcome.json")
    let finished = await Self.waitForFile(outcomeURL, seconds: 60, process: capture)
    guard finished else {
      XCTFail(Self.launchFailure("storage-warning outcome was not written", proof: proof, process: capture))
      return
    }
    let exited = await Self.waitUntil(seconds: 20) { capture.isRunning == false }
    XCTAssertTrue(exited, Self.launchFailure("storage-warning launch did not exit", proof: proof, process: capture))
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))

    let outcomeData = try Data(contentsOf: outcomeURL)
    let outcomeText = String(decoding: outcomeData, as: UTF8.self)
    XCTAssertFalse(outcomeText.contains("AVAudioEngine+ScreenCaptureKit"))
    XCTAssertFalse(outcomeText.contains("live-pause-resume"))
    let outcome = try JSONSerialization.jsonObject(with: outcomeData) as? [String: Any]
    XCTAssertEqual(outcome?["result"] as? String, "INJECTED_CASE_GREEN")
    XCTAssertEqual(outcome?["scenario"] as? String, "storage-warning")
    XCTAssertEqual(outcome?["phase_at_event"] as? String, "capturing")
    XCTAssertEqual(outcome?["fallback"] as? String, "recording-with-storage-warning")
    XCTAssertEqual(outcome?["lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual((outcome?["tracks"] as? NSNumber)?.intValue, 2)
    XCTAssertGreaterThan((outcome?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    let visibleEvents = try XCTUnwrap(outcome?["visible_events"] as? [String])
    XCTAssertTrue(visibleEvents.contains("storage_observed"))
    XCTAssertTrue(visibleEvents.contains("marker_added"))
    let sessionId = try XCTUnwrap(outcome?["session_id"] as? String)

    let probe = try JSONSerialization.jsonObject(
      with: Data(contentsOf: proof.appendingPathComponent("storage-probe.json"))) as? [String: Any]
    XCTAssertEqual((probe?["available_bytes"] as? NSNumber)?.uint64Value, 768 * 1024 * 1024)

    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let detail = try preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "ready_for_review")
    XCTAssertEqual(detail.storageLevel, "warning")
    XCTAssertEqual(
      detail.events.filter { $0.kind == "storage_observed" }.map(\.label),
      ["normal", "warning"])
    XCTAssertEqual(
      detail.events.last { $0.kind == "marker_added" }?.label,
      "Injected failure boundary")
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    let tracks = Set(plan.map(\.trackId))
    XCTAssertEqual(tracks.count, 2)
    for track in tracks {
      XCTAssertEqual(plan.filter { $0.trackId == track }.map(\.sampleCount), [48_000])
    }
    let mix = try XCTUnwrap(try preparation.validatedMixdown(sessionId: sessionId))
    XCTAssertEqual(mix.sessionId, sessionId)
    XCTAssertEqual(mix.digestSha256.count, 64)
    XCTAssertTrue(mix.digestSha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    XCTAssertFalse(mix.sourceDigestSha256.isEmpty)
    XCTAssertGreaterThan(mix.byteLength, 32)
    XCTAssertGreaterThan(mix.decodedFrameCount, 0)
    let frameDifference =
      mix.decodedFrameCount > mix.expectedFrameCount
      ? mix.decodedFrameCount - mix.expectedFrameCount
      : mix.expectedFrameCount - mix.decodedFrameCount
    XCTAssertLessThanOrEqual(frameDifference, 1_024)
    let sources = try Self.cafPaths(under: media)
    XCTAssertEqual(sources.count, 2)
    let mixURL =
      media
      .appendingPathComponent("Sessions", isDirectory: true)
      .appendingPathComponent(sessionId, isDirectory: true)
      .appendingPathComponent(mix.relativePath)
    XCTAssertFalse(sources.contains(mixURL.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: mixURL.path)
    XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, mix.byteLength)
    let decoded = try AVAudioFile(forReading: mixURL)
    XCTAssertEqual(decoded.fileFormat.channelCount, 2)
    XCTAssertEqual(decoded.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
    XCTAssertGreaterThan(decoded.length, 0)
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let kinds = try Self.journalKinds(journal)
    XCTAssertTrue(kinds.contains("recording_started"), kinds.joined(separator: ","))
    XCTAssertEqual(kinds.filter { $0 == "storage_observed" }.count, 2)
    XCTAssertEqual(kinds.filter { $0 == "marker_added" }.count, 1)
    XCTAssertEqual(kinds.filter { $0 == "segment_sealed" }.count, 2)
    XCTAssertEqual(kinds.filter { $0 == "mixdown_validated" }.count, 1)
    XCTAssertFalse(kinds.contains("playable_media_recovered"), kinds.joined(separator: ","))
  }

  /// The shipped verification app records both synthetic sources, then observes
  /// free space below the reserve. Capture stops, the reserve sentence is
  /// visible, and both source tracks remain reviewable. This launch does not
  /// open platform capture devices.
  func testStorageCriticalLaunchStopsAtTheReserveAndKeepsBothSources() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-storage-critical-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let normal = base.appendingPathComponent("unused-production")
    let suite = "OpenScribe.Proof.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let resolved = try LaunchConfiguration.resolve(
      arguments: [
        "app", "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "storage-critical",
        "--verification-preferences", suite,
      ],
      environment: [:], normalRoot: normal)
    XCTAssertEqual(resolved.mode, .synthetic)
    XCTAssertEqual(resolved.action, .injected("storage-critical"))

    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }
    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "storage-critical",
        "--verification-preferences", suite,
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let outcomeURL = proof.appendingPathComponent("outcome.json")
    let finished = await Self.waitForFile(outcomeURL, seconds: 60, process: capture)
    guard finished else {
      XCTFail(Self.launchFailure("storage-critical outcome was not written", proof: proof, process: capture))
      return
    }
    let exited = await Self.waitUntil(seconds: 20) { capture.isRunning == false }
    XCTAssertTrue(exited, Self.launchFailure("storage-critical launch did not exit", proof: proof, process: capture))
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))

    let outcomeData = try Data(contentsOf: outcomeURL)
    let outcomeText = String(decoding: outcomeData, as: UTF8.self)
    XCTAssertFalse(outcomeText.contains("AVAudioEngine+ScreenCaptureKit"))
    XCTAssertFalse(outcomeText.contains("live-pause-resume"))
    let outcome = try JSONSerialization.jsonObject(with: outcomeData) as? [String: Any]
    XCTAssertEqual(outcome?["result"] as? String, "INJECTED_CASE_GREEN")
    XCTAssertEqual(outcome?["scenario"] as? String, "storage-critical")
    XCTAssertEqual(outcome?["phase_at_event"] as? String, "saved")
    XCTAssertEqual(outcome?["fallback"] as? String, "stopped-at-reserve")
    XCTAssertEqual(outcome?["lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual(outcome?["visible_lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual(
      outcome?["visible_message"] as? String,
      "Recording stopped at the storage reserve. Existing audio is preserved.")
    XCTAssertEqual((outcome?["tracks"] as? NSNumber)?.intValue, 2)
    XCTAssertGreaterThan((outcome?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    let visibleEvents = try XCTUnwrap(outcome?["visible_events"] as? [String])
    XCTAssertTrue(visibleEvents.contains("storage_observed"))
    XCTAssertTrue(visibleEvents.contains("marker_added"))
    let sessionId = try XCTUnwrap(outcome?["session_id"] as? String)

    let probe = try JSONSerialization.jsonObject(
      with: Data(contentsOf: proof.appendingPathComponent("storage-probe.json"))) as? [String: Any]
    XCTAssertEqual((probe?["available_bytes"] as? NSNumber)?.uint64Value, 64 * 1024 * 1024)

    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let detail = try preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "ready_for_review")
    XCTAssertEqual(detail.storageLevel, "critical")
    XCTAssertEqual(
      detail.events.filter { $0.kind == "storage_observed" }.map(\.label),
      ["normal", "critical"])
    XCTAssertEqual(
      detail.events.last { $0.kind == "marker_added" }?.label,
      "Injected failure boundary")
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    let tracks = Set(plan.map(\.trackId))
    XCTAssertEqual(tracks.count, 2)
    for track in tracks {
      XCTAssertEqual(plan.filter { $0.trackId == track }.map(\.sampleCount), [48_000])
    }
    XCTAssertEqual(try Self.cafPaths(under: media).count, 2)
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let kinds = try Self.journalKinds(journal)
    XCTAssertTrue(kinds.contains("recording_started"), kinds.joined(separator: ","))
    XCTAssertEqual(kinds.filter { $0 == "storage_observed" }.count, 2)
    XCTAssertEqual(kinds.filter { $0 == "marker_added" }.count, 1)
    XCTAssertEqual(kinds.filter { $0 == "segment_sealed" }.count, 2)
    XCTAssertFalse(kinds.contains("playable_media_recovered"), kinds.joined(separator: ","))
  }

  /// The shipped verification app records both synthetic sources on a dedicated
  /// APFS image. This test fills only that image, then releases the app. The
  /// next CAF write fails, critical storage is journaled while the image is
  /// still full, and a later launch keeps both source tracks.
  func testStorageExhaustionLaunchJournalsTheFullVolumeAndRecoversBothSources() async throws {
    let volume = try ExhaustionProofVolume()
    defer { volume.close() }
    let proof = volume.proof
    let media = volume.mediaRoot
    let suite = "OpenScribe.Proof.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let normal = volume.host.appendingPathComponent("unused-production")
    let resolved = try LaunchConfiguration.resolve(
      arguments: [
        "app", "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "storage-exhaustion",
        "--verification-preferences", suite,
      ],
      environment: [:], normalRoot: normal)
    XCTAssertEqual(resolved.mode, .synthetic)
    XCTAssertEqual(resolved.action, .injected("storage-exhaustion"))

    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }
    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "storage-exhaustion",
        "--verification-preferences", suite,
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let readyURL = proof.appendingPathComponent("injection-ready.json")
    let ready = await Self.waitForFile(readyURL, seconds: 60, process: capture)
    guard ready else {
      XCTFail(Self.launchFailure("storage-exhaustion did not become ready to fill", proof: proof, process: capture))
      return
    }
    let written = try volume.fillUntilNoSpaceRemains()
    let fillLog = "ENOSPC_OBSERVED bytes_written=\(written) smallest_refused_bytes=4096\n"
    try fillLog.write(
      to: proof.appendingPathComponent("volume-fill.log"), atomically: true, encoding: .utf8)
    let available = try RecorderStorage.availableBytes(at: media.path)
    XCTAssertLessThan(available, 512 * 1024 * 1024)
    FileManager.default.createFile(
      atPath: proof.appendingPathComponent("injection-go").path, contents: Data())

    let outcomeURL = proof.appendingPathComponent("outcome.json")
    let finished = await Self.waitForFile(outcomeURL, seconds: 60, process: capture)
    guard finished else {
      XCTFail(Self.launchFailure("storage-exhaustion outcome was not written", proof: proof, process: capture))
      return
    }
    let exited = await Self.waitUntil(seconds: 20) { capture.isRunning == false }
    XCTAssertTrue(exited, Self.launchFailure("storage-exhaustion launch did not exit", proof: proof, process: capture))
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))

    let outcomeData = try Data(contentsOf: outcomeURL)
    let outcomeText = String(decoding: outcomeData, as: UTF8.self)
    XCTAssertFalse(outcomeText.contains("AVAudioEngine+ScreenCaptureKit"))
    XCTAssertFalse(outcomeText.contains("live-pause-resume"))
    let outcome = try JSONSerialization.jsonObject(with: outcomeData) as? [String: Any]
    XCTAssertEqual(outcome?["result"] as? String, "EXHAUSTION_OBSERVED_REQUIRES_RECOVERY")
    XCTAssertEqual(outcome?["scenario"] as? String, "storage-exhaustion")
    XCTAssertEqual((outcome?["write_failed"] as? NSNumber)?.boolValue, true)
    XCTAssertEqual(outcome?["fallback"] as? String, "capture-stopped")
    XCTAssertLessThan((outcome?["available_bytes"] as? NSNumber)?.uint64Value ?? UInt64.max, 512 * 1024 * 1024)
    let phaseAtEvent = try XCTUnwrap(outcome?["phase_at_event"] as? String)
    XCTAssertTrue(phaseAtEvent == "saved" || phaseAtEvent == "failed", phaseAtEvent)
    let visibleMessage = try XCTUnwrap(outcome?["visible_message"] as? String)
    XCTAssertTrue(
      visibleMessage == "Recording stopped because storage reached its reserve. Existing audio was preserved."
        || visibleMessage == "Recording stopped at the storage reserve. Existing audio is preserved.",
      visibleMessage)
    let sessionId = try XCTUnwrap(outcome?["session_id"] as? String)

    let journalURL = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let journalWhileFull = try Data(contentsOf: journalURL)
    let fullRecords = try Self.journalRecords(journalWhileFull)
    XCTAssertTrue(fullRecords.contains { $0["event_kind"] as? String == "recording_started" })
    XCTAssertTrue(fullRecords.contains { $0["event_kind"] as? String == "marker_added" })
    XCTAssertTrue(
      fullRecords.contains {
        $0["event_kind"] as? String == "storage_observed" && Self.payloadLevel($0) == "critical"
      })
    XCTAssertFalse(fullRecords.contains { $0["event_kind"] as? String == "playable_media_recovered" })
    try FileManager.default.removeItem(at: volume.filler)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: media.appendingPathComponent(".capture-journal-reserve-v1").path))

    let capturedAudio = try Self.cafPaths(under: media)
    XCTAssertEqual(capturedAudio.count, 2)
    let audioBeforeRecovery = try Dictionary(uniqueKeysWithValues: capturedAudio.map { path in
      (path, try Self.fileDigest(path))
    })
    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let detail = try preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.storageLevel, "critical")
    XCTAssertEqual(
      detail.events.filter { $0.kind == "storage_observed" }.map(\.label).last, "critical")
    XCTAssertEqual(
      detail.events.last { $0.kind == "marker_added" }?.label, "Injected failure boundary")
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(Set(plan.map(\.trackId)).count, 2)
    XCTAssertTrue(plan.allSatisfy { $0.sampleCount >= 48_000 })

    let firstRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-out.log"),
      standardError: proof.appendingPathComponent("recovery-err.log"))
    child = firstRecovery
    let recoveryURL = proof.appendingPathComponent("recovery.json")
    let recovered = await Self.waitForFile(recoveryURL, seconds: 60, process: firstRecovery)
    guard recovered else {
      XCTFail(Self.launchFailure("exhaustion recovery did not report", proof: proof, process: firstRecovery))
      return
    }
    firstRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(firstRecovery.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
    let firstReport = try Data(contentsOf: recoveryURL)
    let report = try JSONSerialization.jsonObject(with: firstReport) as? [String: Any]
    XCTAssertEqual(report?["result"] as? String, "INJECTED_RECOVERY_GREEN")
    XCTAssertEqual(report?["session_id"] as? String, sessionId)
    XCTAssertEqual(report?["lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual(report?["visible_lifecycle"] as? String, "ready_for_review")
    XCTAssertGreaterThan((report?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    for (path, digest) in audioBeforeRecovery {
      XCTAssertEqual(try Self.fileDigest(path), digest)
    }
    let journalAfterRecovery = SHA256.hash(data: try Data(contentsOf: journalURL))

    let secondRecovery = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-recovery-root", proof.path,
        "--m1-proof-media-root", media.path,
      ],
      standardOutput: proof.appendingPathComponent("recovery-second-out.log"),
      standardError: proof.appendingPathComponent("recovery-second-err.log"))
    child = secondRecovery
    let sawSecond = await Self.waitUntil(seconds: 60) { secondRecovery.isRunning == false }
    XCTAssertTrue(sawSecond, Self.launchFailure("second exhaustion recovery did not exit", proof: proof, process: secondRecovery))
    secondRecovery.waitUntilExit()
    child = nil
    XCTAssertEqual(secondRecovery.terminationStatus, 0)
    XCTAssertEqual(try Data(contentsOf: recoveryURL), firstReport)
    XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: journalURL)), journalAfterRecovery)
    for (path, digest) in audioBeforeRecovery {
      XCTAssertEqual(try Self.fileDigest(path), digest)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))
  }

  /// The shipped verification app records both synthetic sources, then the
  /// microphone writer fails. System audio keeps recording, the microphone
  /// sentence stays visible, and Stop leaves both tracks reviewable.
  func testMicrophoneLossLaunchKeepsSystemAudioAndSealsTheMicrophone() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-microphone-loss-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let normal = base.appendingPathComponent("unused-production")
    let suite = "OpenScribe.Proof.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let resolved = try LaunchConfiguration.resolve(
      arguments: [
        "app", "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "microphone-loss",
        "--verification-preferences", suite,
      ],
      environment: [:], normalRoot: normal)
    XCTAssertEqual(resolved.mode, .synthetic)
    XCTAssertEqual(resolved.action, .injected("microphone-loss"))

    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }
    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "microphone-loss",
        "--verification-preferences", suite,
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let outcomeURL = proof.appendingPathComponent("outcome.json")
    let finished = await Self.waitForFile(outcomeURL, seconds: 60, process: capture)
    guard finished else {
      XCTFail(Self.launchFailure("microphone-loss outcome was not written", proof: proof, process: capture))
      return
    }
    let exited = await Self.waitUntil(seconds: 20) { capture.isRunning == false }
    XCTAssertTrue(exited, Self.launchFailure("microphone-loss launch did not exit", proof: proof, process: capture))
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))

    let outcomeData = try Data(contentsOf: outcomeURL)
    let outcomeText = String(decoding: outcomeData, as: UTF8.self)
    XCTAssertFalse(outcomeText.contains("AVAudioEngine+ScreenCaptureKit"))
    XCTAssertFalse(outcomeText.contains("live-pause-resume"))
    let outcome = try JSONSerialization.jsonObject(with: outcomeData) as? [String: Any]
    XCTAssertEqual(outcome?["result"] as? String, "INJECTED_CASE_GREEN")
    XCTAssertEqual(outcome?["scenario"] as? String, "microphone-loss")
    XCTAssertEqual(outcome?["phase_at_event"] as? String, "capturing")
    XCTAssertEqual(outcome?["fallback"] as? String, "recording-remaining-source")
    XCTAssertEqual(
      outcome?["visible_message"] as? String,
      "The microphone stopped. System audio is still recording.")
    XCTAssertEqual(outcome?["visible_lifecycle"] as? String, "recording")
    XCTAssertEqual(outcome?["lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual((outcome?["tracks"] as? NSNumber)?.intValue, 2)
    XCTAssertGreaterThan((outcome?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    let visibleEvents = try XCTUnwrap(outcome?["visible_events"] as? [String])
    XCTAssertTrue(visibleEvents.contains("source_failed"))
    XCTAssertTrue(visibleEvents.contains("marker_added"))
    let sessionId = try XCTUnwrap(outcome?["session_id"] as? String)

    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let detail = try preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "ready_for_review")
    XCTAssertTrue(detail.events.contains { $0.kind == "source_failed" })
    XCTAssertEqual(
      detail.events.last { $0.kind == "marker_added" }?.label, "Injected failure boundary")
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    var totals: [String: UInt64] = [:]
    for segment in plan {
      totals[segment.trackId, default: 0] += segment.sampleCount
    }
    XCTAssertEqual(Set(totals.values), [48_000, 96_000])
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let kinds = try Self.journalKinds(journal)
    XCTAssertTrue(kinds.contains("recording_started"), kinds.joined(separator: ","))
    XCTAssertTrue(kinds.contains("marker_added"), kinds.joined(separator: ","))
    XCTAssertTrue(kinds.contains("source_failed"), kinds.joined(separator: ","))
    XCTAssertFalse(kinds.contains("playable_media_recovered"), kinds.joined(separator: ","))
    XCTAssertEqual(try Self.cafPaths(under: media).count, 2)
  }

  /// The shipped verification app records both synthetic sources, then system
  /// audio stops. The microphone keeps recording, the system-audio sentence
  /// stays visible, and Stop leaves both tracks reviewable.
  func testSystemLossLaunchKeepsTheMicrophoneAndSealsSystemAudio() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-system-loss-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let normal = base.appendingPathComponent("unused-production")
    let suite = "OpenScribe.Proof.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let resolved = try LaunchConfiguration.resolve(
      arguments: [
        "app", "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "system-loss",
        "--verification-preferences", suite,
      ],
      environment: [:], normalRoot: normal)
    XCTAssertEqual(resolved.mode, .synthetic)
    XCTAssertEqual(resolved.action, .injected("system-loss"))

    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }
    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "system-loss",
        "--verification-preferences", suite,
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let outcomeURL = proof.appendingPathComponent("outcome.json")
    let finished = await Self.waitForFile(outcomeURL, seconds: 60, process: capture)
    guard finished else {
      XCTFail(Self.launchFailure("system-loss outcome was not written", proof: proof, process: capture))
      return
    }
    let exited = await Self.waitUntil(seconds: 20) { capture.isRunning == false }
    XCTAssertTrue(exited, Self.launchFailure("system-loss launch did not exit", proof: proof, process: capture))
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))

    let outcomeData = try Data(contentsOf: outcomeURL)
    let outcomeText = String(decoding: outcomeData, as: UTF8.self)
    XCTAssertFalse(outcomeText.contains("AVAudioEngine+ScreenCaptureKit"))
    XCTAssertFalse(outcomeText.contains("live-pause-resume"))
    let outcome = try JSONSerialization.jsonObject(with: outcomeData) as? [String: Any]
    XCTAssertEqual(outcome?["result"] as? String, "INJECTED_CASE_GREEN")
    XCTAssertEqual(outcome?["scenario"] as? String, "system-loss")
    XCTAssertEqual(outcome?["phase_at_event"] as? String, "capturing")
    XCTAssertEqual(outcome?["fallback"] as? String, "recording-remaining-source")
    XCTAssertEqual(
      outcome?["visible_message"] as? String,
      "Mac system audio stopped. Remaining audio is still recording. streamStopped")
    XCTAssertEqual(outcome?["visible_lifecycle"] as? String, "recording")
    XCTAssertEqual(outcome?["lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual((outcome?["tracks"] as? NSNumber)?.intValue, 2)
    XCTAssertGreaterThan((outcome?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    let visibleEvents = try XCTUnwrap(outcome?["visible_events"] as? [String])
    XCTAssertTrue(visibleEvents.contains("source_failed"))
    XCTAssertTrue(visibleEvents.contains("marker_added"))
    let sessionId = try XCTUnwrap(outcome?["session_id"] as? String)

    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let detail = try preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "ready_for_review")
    XCTAssertEqual(
      detail.events.last { $0.kind == "source_failed" }?.label, "Mac system audio")
    XCTAssertEqual(
      detail.events.last { $0.kind == "marker_added" }?.label, "Injected failure boundary")
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    var totals: [String: UInt64] = [:]
    for segment in plan {
      totals[segment.trackId, default: 0] += segment.sampleCount
    }
    XCTAssertEqual(Set(totals.values), [48_000, 96_000])
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let kinds = try Self.journalKinds(journal)
    XCTAssertTrue(kinds.contains("recording_started"), kinds.joined(separator: ","))
    XCTAssertTrue(kinds.contains("marker_added"), kinds.joined(separator: ","))
    XCTAssertTrue(kinds.contains("source_failed"), kinds.joined(separator: ","))
    XCTAssertFalse(kinds.contains("playable_media_recovered"), kinds.joined(separator: ","))
    XCTAssertEqual(try Self.cafPaths(under: media).count, 2)
  }

  /// The shipped verification app records the microphone and one selected
  /// application. That application stream stops. The microphone keeps
  /// recording, and Stop leaves both tracks reviewable.
  func testApplicationLossLaunchKeepsTheMicrophoneAndSealsTheApplication() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-application-loss-\(UUID().uuidString)", isDirectory: true)
    let proof = base.appendingPathComponent("proof", isDirectory: true)
    let media = proof.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let normal = base.appendingPathComponent("unused-production")
    let suite = "OpenScribe.Proof.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let resolved = try LaunchConfiguration.resolve(
      arguments: [
        "app", "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "application-loss",
        "--verification-preferences", suite,
      ],
      environment: [:], normalRoot: normal)
    XCTAssertEqual(resolved.mode, .synthetic)
    XCTAssertEqual(resolved.action, .injected("application-loss"))

    var child: Process?
    defer {
      if let child, child.isRunning {
        kill(pid_t(child.processIdentifier), SIGKILL)
        child.waitUntilExit()
      }
    }
    let capture = try Self.launchVerificationApp(
      arguments: [
        "--m1-injected-proof-root", proof.path,
        "--m1-proof-media-root", media.path,
        "--m1-injected-case", "application-loss",
        "--verification-preferences", suite,
      ],
      standardOutput: proof.appendingPathComponent("app-out.log"),
      standardError: proof.appendingPathComponent("app-err.log"))
    child = capture
    let outcomeURL = proof.appendingPathComponent("outcome.json")
    let finished = await Self.waitForFile(outcomeURL, seconds: 60, process: capture)
    guard finished else {
      XCTFail(Self.launchFailure("application-loss outcome was not written", proof: proof, process: capture))
      return
    }
    let exited = await Self.waitUntil(seconds: 20) { capture.isRunning == false }
    XCTAssertTrue(exited, Self.launchFailure("application-loss launch did not exit", proof: proof, process: capture))
    capture.waitUntilExit()
    child = nil
    XCTAssertEqual(capture.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.appendingPathComponent("proof-error").path))

    let outcomeData = try Data(contentsOf: outcomeURL)
    let outcomeText = String(decoding: outcomeData, as: UTF8.self)
    XCTAssertFalse(outcomeText.contains("AVAudioEngine+ScreenCaptureKit"))
    XCTAssertFalse(outcomeText.contains("live-pause-resume"))
    let outcome = try JSONSerialization.jsonObject(with: outcomeData) as? [String: Any]
    XCTAssertEqual(outcome?["result"] as? String, "INJECTED_CASE_GREEN")
    XCTAssertEqual(outcome?["scenario"] as? String, "application-loss")
    XCTAssertEqual(outcome?["phase_at_event"] as? String, "capturing")
    XCTAssertEqual(outcome?["fallback"] as? String, "recording-remaining-source")
    XCTAssertEqual(
      outcome?["visible_message"] as? String,
      "Selected application audio stopped. Remaining audio is still recording. streamStopped")
    XCTAssertEqual(outcome?["visible_lifecycle"] as? String, "recording")
    XCTAssertEqual(outcome?["lifecycle"] as? String, "ready_for_review")
    XCTAssertEqual((outcome?["tracks"] as? NSNumber)?.intValue, 2)
    XCTAssertGreaterThan((outcome?["rendered_frames"] as? NSNumber)?.intValue ?? 0, 0)
    let visibleEvents = try XCTUnwrap(outcome?["visible_events"] as? [String])
    XCTAssertTrue(visibleEvents.contains("source_failed"))
    XCTAssertTrue(visibleEvents.contains("marker_added"))
    let sessionId = try XCTUnwrap(outcome?["session_id"] as? String)

    let preparation = try NativeRecordingPreparation.open(managedRoot: media.path)
    let detail = try preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "ready_for_review")
    XCTAssertEqual(
      detail.events.last { $0.kind == "source_failed" }?.label, "Injected application")
    XCTAssertEqual(
      detail.events.last { $0.kind == "marker_added" }?.label, "Injected failure boundary")
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    var totals: [String: UInt64] = [:]
    for segment in plan {
      totals[segment.trackId, default: 0] += segment.sampleCount
    }
    XCTAssertEqual(Set(totals.values), [48_000, 96_000])
    let journal = media.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let kinds = try Self.journalKinds(journal)
    XCTAssertTrue(kinds.contains("recording_started"), kinds.joined(separator: ","))
    XCTAssertTrue(kinds.contains("marker_added"), kinds.joined(separator: ","))
    XCTAssertTrue(kinds.contains("source_failed"), kinds.joined(separator: ","))
    XCTAssertFalse(kinds.contains("playable_media_recovered"), kinds.joined(separator: ","))
    XCTAssertEqual(try Self.cafPaths(under: media).count, 2)
  }

  private static func journalRecords(_ data: Data) throws -> [[String: Any]] {
    try String(decoding: data, as: UTF8.self).split(separator: "\n").map { line in
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
  }

  private static func payloadLevel(_ record: [String: Any]) -> String? {
    if let payload = record["payload"] as? [String: Any] {
      return payload["level"] as? String
    }
    if let text = record["payload"] as? String,
      let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    {
      return payload["level"] as? String
    }
    return nil
  }

  private static func launchVerificationApp(
    arguments: [String], standardOutput: URL, standardError: URL
  ) throws -> Process {
    FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
    FileManager.default.createFile(atPath: standardError.path, contents: nil)
    let process = Process()
    process.executableURL = try XCTUnwrap(Bundle.main.executableURL)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    for key in [
      "XCTestConfigurationFilePath", "XCTestBundlePath", "OPEN_SCRIBE_TEST_HOST",
      "OPEN_SCRIBE_PROOF_ROOT", "OPEN_SCRIBE_PROOF_PREFERENCES",
    ] {
      environment.removeValue(forKey: key)
    }
    process.environment = environment
    process.standardOutput = try FileHandle(forWritingTo: standardOutput)
    process.standardError = try FileHandle(forWritingTo: standardError)
    try process.run()
    return process
  }

  private static func waitForFile(_ url: URL, seconds: Double, process: Process) async -> Bool {
    await waitUntil(seconds: seconds) {
      FileManager.default.fileExists(atPath: url.path) || process.isRunning == false
    } && FileManager.default.fileExists(atPath: url.path)
  }

  private static func waitUntil(seconds: Double, _ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < deadline {
      if predicate() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return predicate()
  }

  private static func processIsStopped(_ process: Process) -> Bool {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/bin/ps")
    probe.arguments = ["-p", "\(process.processIdentifier)", "-o", "state="]
    let pipe = Pipe()
    probe.standardOutput = pipe
    probe.standardError = FileHandle.nullDevice
    guard (try? probe.run()) != nil else { return false }
    probe.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return probe.terminationStatus == 0 && text.contains("T")
  }

  private static func journalKinds(_ url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
      let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      return try XCTUnwrap(record["event_kind"] as? String)
    }
  }

  private static func fileDigest(_ path: String) throws -> SHA256.Digest {
    SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
  }

  private static func mediaPaths(under root: URL, suffix: String) throws -> [String] {
    guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    return enumerator.compactMap { ($0 as? URL)?.path }.filter { $0.hasSuffix(suffix) }.sorted()
  }

  private static func cafPaths(under root: URL) throws -> [String] {
    guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    return enumerator.compactMap { ($0 as? URL)?.path }.filter { $0.hasSuffix(".caf") }.sorted()
  }

  private static func launchFailure(_ reason: String, proof: URL, process: Process) -> String {
    let errorURL = proof.appendingPathComponent("proof-error")
    let proofError = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? "none"
    let appError = (try? String(contentsOf: proof.appendingPathComponent("app-err.log"), encoding: .utf8)) ?? ""
    let recoveryError = (try? String(contentsOf: proof.appendingPathComponent("recovery-err.log"), encoding: .utf8)) ?? ""
    return "\(reason) running=\(process.isRunning) status=\(process.terminationStatus) proof_error=\(proofError) app_err=\(appError) recovery_err=\(recoveryError)"
  }
}

/// A 1.5 GiB APFS image. Filling it cannot write the host volume because the
/// mount is a different device, and the filler stops when that image is full.
private final class ExhaustionProofVolume {
  let host: URL
  let proof: URL
  let volume: URL
  let mediaRoot: URL
  let filler: URL
  private let image: URL
  private var mounted = false

  init() throws {
    host = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("open-scribe-storage-exhaustion-\(UUID().uuidString)", isDirectory: true)
    proof = host.appendingPathComponent("proof", isDirectory: true)
    volume = proof.appendingPathComponent("volume", isDirectory: true)
    mediaRoot = volume.appendingPathComponent("media", isDirectory: true)
    filler = volume.appendingPathComponent("owned-pressure-fill")
    image = proof.appendingPathComponent("pressure.sparseimage")
    try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
    try Self.run(
      "/usr/bin/hdiutil",
      [
        "create", "-size", "1536m", "-fs", "APFS", "-type", "SPARSE", "-volname",
        "OpenScribeM1Proof",
        proof.appendingPathComponent("pressure").path,
      ])
    try Self.run(
      "/usr/bin/hdiutil",
      ["attach", "-nobrowse", "-mountpoint", volume.path, image.path])
    mounted = true
    try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
    try requireDifferentDevice()
  }

  func close() {
    if mounted {
      _ = try? Self.run("/usr/bin/hdiutil", ["detach", "-force", volume.path])
      mounted = false
    }
    try? FileManager.default.removeItem(at: host)
  }

  func fillUntilNoSpaceRemains() throws -> Int {
    try requireDifferentDevice()
    FileManager.default.createFile(atPath: filler.path, contents: nil)
    let handle = try FileHandle(forWritingTo: filler)
    defer { try? handle.close() }
    var written = 0
    let limit = 2 * 1024 * 1024 * 1024
    var sawNoSpace = false
    for size in [1024 * 1024, 64 * 1024, 4096] {
      let chunk = Data(repeating: 0xA5, count: size)
      while written < limit {
        do {
          try handle.write(contentsOf: chunk)
          written += size
        } catch let error as NSError {
          guard Self.isNoSpace(error) else { throw error }
          sawNoSpace = true
          break
        }
      }
    }
    guard sawNoSpace, written < limit else {
      throw CocoaError(.fileWriteUnknown)
    }
    return written
  }

  private func requireDifferentDevice() throws {
    let volumeDevice = try Self.deviceIdentifier(volume.path)
    let hostDevice = try Self.deviceIdentifier(host.path)
    guard volumeDevice != hostDevice else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
  }

  private static func isNoSpace(_ error: NSError) -> Bool {
    if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC) { return true }
    if error.code == NSFileWriteOutOfSpaceError { return true }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      return isNoSpace(underlying)
    }
    return false
  }

  private static func deviceIdentifier(_ path: String) throws -> Int32 {
    let descriptor = Darwin.open(path, O_RDONLY)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
    }
    defer { Darwin.close(descriptor) }
    let info = UnsafeMutablePointer<Darwin.stat>.allocate(capacity: 1)
    defer { info.deallocate() }
    memset(info, 0, MemoryLayout<Darwin.stat>.size)
    guard fstat(descriptor, info) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return info.pointee.st_dev
  }

  @discardableResult
  private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let text =
      String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errorText =
      String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw CocoaError(
        .fileWriteUnknown,
        userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? text : errorText])
    }
    return text
  }
}
