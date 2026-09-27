import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

/// A filter is an ephemeral platform capability. Its bounded identity and label
/// are journaled by Rust; a relaunch never silently restores capture authority.
struct RecorderCaptureSelection: @unchecked Sendable {
  let kind: NativeMediaSourceKind?
  let identity: String
  let name: String
  let filter: SCContentFilter?
  let processId: pid_t?

  static let system = Self(kind: .systemAudio, identity: "authorized-system-audio", name: "Mac system audio", filter: nil, processId: nil)
  static let microphoneOnly = Self(kind: nil, identity: "microphone-only", name: "Microphone only", filter: nil, processId: nil)
}

@MainActor
final class RecorderApplicationPicker: NSObject, ObservableObject {
  @Published private(set) var applications: [SCRunningApplication] = []
  @Published private(set) var errorMessage: String?
  var onSelection: ((RecorderCaptureSelection) -> Void)?

  func choose() async {
    errorMessage = nil
    if #available(macOS 14.0, *) {
      let picker = SCContentSharingPicker.shared
      var configuration = SCContentSharingPickerConfiguration()
      configuration.allowedPickerModes = [.singleApplication]
      configuration.allowsChangingSelectedContent = false
      configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "app.open-scribe"]
      picker.defaultConfiguration = configuration
      picker.add(self)
      picker.isActive = true
      picker.present()
    } else {
      do {
        applications = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).applications
          .filter { $0.processID != ProcessInfo.processInfo.processIdentifier }
          .sorted { $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending }
      } catch { errorMessage = "Application access is unavailable. Check Screen Recording permission." }
    }
  }

  func select(_ application: SCRunningApplication) async {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard let display = content.displays.first,
        let current = content.applications.first(where: { $0.processID == application.processID && $0.bundleIdentifier == application.bundleIdentifier })
      else { throw SystemAudioCaptureAdapterError.noDisplayAvailable }
      let filter = SCContentFilter(display: display, including: [current], exceptingWindows: [])
      onSelection?(Self.selection(filter: filter, app: current))
      applications = []
    } catch { errorMessage = "That application is no longer available. Choose it again." }
  }

  private static func selection(filter: SCContentFilter, app: SCRunningApplication?) -> RecorderCaptureSelection {
    RecorderCaptureSelection(kind: .applicationAudio,
      identity: app.map { "\($0.bundleIdentifier):\($0.processID)" } ?? "system-picker:\(UUID().uuidString)",
      name: app?.applicationName ?? "Application selected in macOS", filter: filter, processId: app?.processID)
  }
}

@available(macOS 14.0, *)
extension RecorderApplicationPicker: SCContentSharingPickerObserver {
  nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}

  nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
    guard stream == nil else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      let application: SCRunningApplication?
      if #available(macOS 15.2, *) { application = filter.includedApplications.first } else { application = nil }
      self.onSelection?(Self.selection(filter: filter, app: application))
    }
  }

  nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
    Task { @MainActor [weak self] in self?.errorMessage = "The macOS application picker could not open." }
  }
}

enum RecorderStorage {
  static func availableBytes(at path: String) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
    guard let bytes = attributes[.systemFreeSize] as? NSNumber else { throw ManagedCAFWriterError.mediaAttributesUnavailable }
    return bytes.uint64Value
  }
}

extension NativeRecordingPreparationProtocol {
  func recorderAction(sessionId: String, action: NativeRecorderAction) throws -> NativeRecorderDetail {
    throw ManagedCAFWriterError.unsupportedAuthorization
  }
  func recorderDetail(sessionId: String) throws -> NativeRecorderDetail {
    throw ManagedCAFWriterError.unsupportedAuthorization
  }
}
