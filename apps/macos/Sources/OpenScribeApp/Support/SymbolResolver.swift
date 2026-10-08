import AppKit

enum SymbolResolver {
  enum CaptureState: CaseIterable {
    case idle, ready, starting, recording, paused, degraded, recoveryRequired

    var symbols: (primary: String, fallback: String) {
      switch self {
      case .idle: ("waveform", "circle")
      case .ready: ("waveform.circle", "waveform")
      case .starting: ("ellipsis.circle", "ellipsis")
      case .recording: ("record.circle.fill", "circle.fill")
      case .paused: ("pause.circle.fill", "pause.fill")
      case .degraded: ("exclamationmark.triangle.fill", "exclamationmark.triangle")
      case .recoveryRequired: ("clock.arrow.circlepath", "clock")
      }
    }
  }

  static func captureSymbol(
    for state: CaptureState,
    isAvailable: (String) -> Bool = symbolIsAvailable
  ) -> String {
    resolve(
      primary: state.symbols.primary, fallback: state.symbols.fallback,
      isAvailable: isAvailable
    ) ?? ""
  }

  static var pausedCaptureSymbolName: String {
    captureSymbol(for: .paused)
  }

  static func resolve(
    primary: String?, fallback: String?,
    isAvailable: (String) -> Bool = symbolIsAvailable
  ) -> String? {
    if let primary, isAvailable(primary) {
      return primary
    }
    if let fallback, isAvailable(fallback) {
      return fallback
    }
    return nil
  }

  private static func symbolIsAvailable(_ name: String) -> Bool {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
  }
}
