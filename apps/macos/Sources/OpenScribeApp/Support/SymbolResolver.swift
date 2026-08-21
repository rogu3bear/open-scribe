import AppKit

enum SymbolResolver {
  static func resolve(primary: String?, fallback: String?) -> String? {
    if let primary, NSImage(systemSymbolName: primary, accessibilityDescription: nil) != nil {
      return primary
    }
    if let fallback, NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil {
      return fallback
    }
    return nil
  }
}
