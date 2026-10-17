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
}
