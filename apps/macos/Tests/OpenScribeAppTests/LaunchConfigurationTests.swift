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
