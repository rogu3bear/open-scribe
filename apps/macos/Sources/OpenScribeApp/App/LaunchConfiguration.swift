import CryptoKit
import Darwin
import Foundation

/// The only storage/preferences routing decision, made before any native handle.
/// Proof flags translate here; malformed proof intent never becomes a normal launch.
struct LaunchConfiguration {
  enum Mode: Equatable { case normal, scenes, testHost, synthetic, live }
  enum InjectedCase: String {
    case storageWarning = "storage-warning"
    case storageCritical = "storage-critical"
    case storageExhaustion = "storage-exhaustion"
    case microphoneLoss = "microphone-loss"
    case systemLoss = "system-loss"
    case applicationLoss = "application-loss"
    case selectedAppExit = "selected-app-exit"
    case sleepWake = "sleep-wake"
    case livePauseResume = "live-pause-resume"
    case killPreparation = "kill-preparation"
    case killRecording = "kill-recording"
    case killStop = "kill-stop"
    case killSeal = "kill-seal"
    case killProcessing = "kill-processing"
  }
  enum Action: Equatable {
    case none
    case injected(String)
    case injectedRecovery, review, liveRecovery
    case syntheticCapture, syntheticRecovery, microphone, forcedCapture, forcedRecovery
    case localOnly
    case drift(UInt64)
  }
  enum Rejection: Error {
    case malformed, conflict, missingRoot, unsafeRoot, releaseProof, preferencesNotIsolated
  }

  let mode: Mode
  let action: Action
  let libraryRoot: URL
  let proofRoot: URL?
  let mediaRoot: URL?
  let preferences: UserDefaults
  var suspendsAutomation: Bool { mode != .normal }

  static func resolve(
    arguments: [String], environment: [String: String], normalRoot: URL,
    permitsProofs: Bool = developmentBuild,
    verificationBuild: Bool = Bundle.main.bundleIdentifier?.hasSuffix(".verification") == true
  ) throws -> LaunchConfiguration {
    let rootFlags: [String: (Mode, Action)] = [
      "--m1-injected-proof-root": (.synthetic, .injected("invalid")),
      "--m1-injected-recovery-root": (.synthetic, .injectedRecovery),
      "--foundation-review-root": (.synthetic, .review),
      "--foundation-live-recovery-root": (.live, .liveRecovery),
      "--foundation-synthetic-capture-root": (.synthetic, .syntheticCapture),
      "--foundation-synthetic-recovery-root": (.synthetic, .syntheticRecovery),
      "--m1-live-microphone-proof-root": (.live, .microphone),
      "--m1-forced-termination-capture-root": (.live, .forcedCapture),
      "--m1-forced-termination-recovery-root": (.live, .forcedRecovery),
      "--local-only-proof-root": (.live, .localOnly),
      "--local-only-synthetic-proof-root": (.synthetic, .localOnly),
      "--m1-drift-run-root": (.live, .drift(0)),
    ]
    let valueFlags = Set(rootFlags.keys).union([
      "--verification-root", "--verification-preferences", "--m1-proof-media-root",
      "--m1-injected-case", "--m1-drift-run-seconds",
    ])
    var values: [String: String] = [:]
    var scenes = false
    var testHost =
      environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
      || environment["OPEN_SCRIBE_TEST_HOST"] == "1"
    var index = 1
    while index < arguments.count {
      let flag = arguments[index]
      if valueFlags.contains(flag) {
        guard values[flag] == nil, index + 1 < arguments.count,
          !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty
        else { throw Rejection.malformed }
        values[flag] = arguments[index + 1]
        index += 2
      } else {
        if flag == "--m0-proof-settings" {
          guard !scenes else { throw Rejection.conflict }
          scenes = true
        } else if flag == "--open-scribe-test-host" {
          testHost = true
        } else if flag.hasPrefix("--m0-proof") || flag.hasPrefix("--m1-")
          || flag.hasPrefix("--foundation-")
          || flag.hasPrefix("--verification-") || flag.hasPrefix("--local-only-")
        {
          throw Rejection.malformed
        }
        index += 1
      }
    }
    let selected = rootFlags.keys.filter { values[$0] != nil }
    guard selected.count + (scenes ? 1 : 0) + (testHost ? 1 : 0) <= 1 else {
      throw Rejection.conflict
    }
    let hasProofEnvironment =
      environment["OPEN_SCRIBE_PROOF_ROOT"] != nil
      || environment["OPEN_SCRIBE_PROOF_PREFERENCES"] != nil
    if selected.isEmpty && !scenes && !testHost {
      guard values.isEmpty, !hasProofEnvironment, !verificationBuild else {
        throw Rejection.conflict
      }
      return LaunchConfiguration(
        mode: .normal, action: .none, libraryRoot: normalRoot, proofRoot: nil,
        mediaRoot: nil, preferences: .standard)
    }
    guard permitsProofs else { throw Rejection.releaseProof }
    guard verificationBuild else { throw Rejection.preferencesNotIsolated }
    var mode: Mode = scenes ? .scenes : .testHost
    var action: Action = .none
    var suppliedRoot = values["--verification-root"] ?? environment["OPEN_SCRIBE_PROOF_ROOT"]
    if let flag = selected.first, let choice = rootFlags[flag] {
      guard suppliedRoot == nil else { throw Rejection.conflict }
      suppliedRoot = values[flag]
      (mode, action) = choice
    }
    guard let suppliedRoot else { throw Rejection.missingRoot }
    if let fromEnvironment = environment["OPEN_SCRIBE_PROOF_ROOT"],
      fromEnvironment != suppliedRoot
    {
      throw Rejection.conflict
    }
    let root = try validatedRoot(suppliedRoot, excluding: normalRoot)
    var mediaRoot: URL?
    if let value = values["--m1-proof-media-root"] {
      switch action {
      case .injected, .injectedRecovery: break
      default: throw Rejection.conflict
      }
      mediaRoot = try validatedRoot(value, excluding: normalRoot)
    }
    if case .injected = action {
      guard let text = values["--m1-injected-case"], let scenario = InjectedCase(rawValue: text)
      else {
        throw Rejection.malformed
      }
      action = .injected(scenario.rawValue)
      if scenario == .livePauseResume { mode = .live }
    } else if values["--m1-injected-case"] != nil {
      throw Rejection.conflict
    }
    if case .drift = action {
      guard let text = values["--m1-drift-run-seconds"], let seconds = UInt64(text),
        (1...10_800).contains(seconds)
      else { throw Rejection.malformed }
      action = .drift(seconds)
    } else if values["--m1-drift-run-seconds"] != nil {
      throw Rejection.conflict
    }
    return try make(mode, action, root, mediaRoot, values, environment, normalRoot)
  }

  private static func make(
    _ mode: Mode, _ action: Action, _ root: URL, _ media: URL?,
    _ values: [String: String], _ environment: [String: String], _ normalRoot: URL
  ) throws -> LaunchConfiguration {
    let library =
      (action == .localOnly
        || {
          if case .drift = action { return true }
          return false
        }())
      ? root.appendingPathComponent("Library", isDirectory: true) : (media ?? root)
    if FileManager.default.fileExists(atPath: library.path) {
      _ = try validatedRoot(library.path, excluding: normalRoot)
    } else if library.resolvingSymlinksInPath().path != library.path {
      throw Rejection.unsafeRoot
    }
    if let argument = values["--verification-preferences"],
      let variable = environment["OPEN_SCRIBE_PROOF_PREFERENCES"], argument != variable
    {
      throw Rejection.conflict
    }
    let token = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
    let suite =
      values["--verification-preferences"]
      ?? environment["OPEN_SCRIBE_PROOF_PREFERENCES"] ?? "OpenScribe.Proof.\(token)"
    guard suite.hasPrefix("OpenScribe.Proof."), suite.count <= 160,
      suite.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
      }),
      let preferences = UserDefaults(suiteName: suite)
    else { throw Rejection.malformed }
    return LaunchConfiguration(
      mode: mode, action: action, libraryRoot: library, proofRoot: root,
      mediaRoot: media, preferences: preferences)
  }

  /// Metadata reads only. No directory, database, model, or preference is opened
  /// until every mode and root has passed this validation.
  private static func validatedRoot(_ path: String, excluding normalRoot: URL) throws -> URL {
    guard path.hasPrefix("/"), path == path.trimmingCharacters(in: .whitespacesAndNewlines),
      !path.split(separator: "/").contains(".."), !path.contains("\0")
    else { throw Rejection.unsafeRoot }
    let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let real = root.resolvingSymlinksInPath()
    let production = normalRoot.standardizedFileURL.resolvingSymlinksInPath().path
    guard root.path == real.path, root.path != production,
      !root.path.hasPrefix(production + "/"), !production.hasPrefix(root.path + "/"),
      root.path != "/", root.path != NSHomeDirectory(),
      !root.path.contains("/Library/Application Support/Open Scribe/")
        && !root.path.hasSuffix("/Library/Application Support/Open Scribe")
    else { throw Rejection.unsafeRoot }
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else { throw Rejection.unsafeRoot }
    return root
  }

  static var developmentBuild: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }
}
