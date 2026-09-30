import AppKit
import CoreGraphics
import CoreMedia
@preconcurrency import ScreenCaptureKit
import VideoToolbox

enum ContextCaptureError: Error {
  case targetUnavailable
  case noFrame
}

/// Screen Recording permission as the platform reports it. The check never
/// prompts; the request is made only when the user authorizes a scope.
enum ScreenCapturePermission {
  static func current() -> NativeScreenPermission {
    CGPreflightScreenCaptureAccess() ? .granted : .denied
  }

  /// Shows the system prompt at most once per process state; returns the
  /// resulting posture.
  static func request() -> NativeScreenPermission {
    CGRequestScreenCaptureAccess() ? .granted : .denied
  }
}

/// One-frame capture through the exact authorized ScreenCaptureKit filter,
/// with Open Scribe itself excluded (ADR 0012). macOS 14 and later use
/// `SCScreenshotManager`; macOS 13 opens a bounded stream, keeps its first
/// complete frame, and stops it.
struct ScreenContextFrameSource: ContextFrameCapturing {
  /// The longest captured edge, in pixels; reduction needs far less.
  static let maximumEdge = 2_560.0

  func captureFrame(_ target: ContextCaptureTarget) async throws -> CGImage {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let ownProcess = ProcessInfo.processInfo.processIdentifier
    let configuration = SCStreamConfiguration()
    configuration.showsCursor = false
    configuration.capturesAudio = false
    let filter: SCContentFilter
    var size: CGSize
    switch target {
    case .display(let id, let region):
      guard let display = content.displays.first(where: { $0.displayID == id }) else {
        throw ContextCaptureError.targetUnavailable
      }
      let own = content.applications.filter { $0.processID == ownProcess }
      filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
      size = CGSize(width: display.width, height: display.height)
      if let region {
        let rect = CGRect(
          x: region.minX * size.width, y: region.minY * size.height,
          width: region.width * size.width, height: region.height * size.height)
        configuration.sourceRect = rect
        size = rect.size
      }
    case .window(let id):
      guard
        let window = content.windows.first(where: {
          $0.windowID == id && $0.owningApplication?.processID != ownProcess
        })
      else { throw ContextCaptureError.targetUnavailable }
      filter = SCContentFilter(desktopIndependentWindow: window)
      size = window.frame.size
    }
    let pixels = min(2.0, Self.maximumEdge / max(size.width, size.height, 1))
    configuration.width = max(1, Int(size.width * pixels))
    configuration.height = max(1, Int(size.height * pixels))
    if #available(macOS 14.0, *) {
      return try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration)
    }
    return try await OneFrameStream.capture(filter: filter, configuration: configuration)
  }
}

/// The macOS 13 path: a stream that delivers one complete frame, then stops.
private final class OneFrameStream: NSObject, SCStreamOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<CGImage, Error>?

  static func capture(filter: SCContentFilter, configuration: SCStreamConfiguration)
    async throws -> CGImage
  {
    let receiver = OneFrameStream()
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.queueDepth = 3
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(
      receiver, type: .screen, sampleHandlerQueue: DispatchQueue(label: "open-scribe.context.frame"))
    defer { Task { try? await stream.stopCapture() } }
    return try await withThrowingTaskGroup(of: CGImage.self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { continuation in
          receiver.lock.withLock { receiver.continuation = continuation }
          stream.startCapture { error in
            if let error { receiver.finish(.failure(error)) }
          }
        }
      }
      group.addTask {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        receiver.finish(.failure(ContextCaptureError.noFrame))
        throw ContextCaptureError.noFrame
      }
      defer { group.cancelAll() }
      guard let image = try await group.next() else { throw ContextCaptureError.noFrame }
      return image
    }
  }

  private func finish(_ result: Result<CGImage, Error>) {
    let continuation = lock.withLock {
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume(with: result)
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int,
      SCFrameStatus(rawValue: raw) == .complete,
      let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }
    var image: CGImage?
    VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
    if let image { finish(.success(image)) }
  }
}

/// The eligible window under a point, for Follow Pointer. Only ordinary
/// application windows qualify; the Dock, menu bar, notifications, Open
/// Scribe, and known password managers are filtered. These are best-effort
/// safeguards, not a guarantee.
enum ContextWindowLocator {
  static let deniedApplications: Set<String> = [
    "1Password", "1Password 7", "Bitwarden", "Dashlane", "Keychain Access", "LastPass",
    "Passwords", "loginwindow", "Notification Center", "Dock", "Control Center",
  ]

  struct Window: Equatable, Sendable {
    let id: CGWindowID
    let title: String?
    let application: String
    /// Global Core Graphics points, top-left origin.
    let frame: CGRect
  }

  static func window(at point: CGPoint) -> Window? {
    guard
      let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let ownProcess = ProcessInfo.processInfo.processIdentifier
    for info in list {
      guard (info[kCGWindowLayer as String] as? Int) == 0,
        let owner = info[kCGWindowOwnerPID as String] as? Int32, owner != ownProcess,
        let number = info[kCGWindowNumber as String] as? UInt32,
        let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsInfo), bounds.contains(point)
      else { continue }
      let application = info[kCGWindowOwnerName as String] as? String ?? "Application"
      let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
      // The frontmost window at the point decides; a filtered one hides what is beneath.
      if deniedApplications.contains(application)
        || title?.localizedCaseInsensitiveContains("Private Browsing") == true
      {
        return nil
      }
      return Window(id: number, title: title, application: application, frame: bounds)
    }
    return nil
  }
}
