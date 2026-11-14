import Foundation

enum RecorderStorage {
  /// Space available for important usage, which includes purgeable APFS space
  /// the system can reclaim; the plain free size omits it and would trip the
  /// reserve while space is available. CacheDelete sometimes cannot answer for
  /// a volume (a freshly mounted disk image, for one) and the important-usage
  /// value comes back empty; the plain free size is then a lower bound, so the
  /// reserve can trip early but never late. A volume reporting neither is an
  /// error, never unlimited space.
  static func availableBytes(at path: String) throws -> UInt64 {
    let values = try URL(fileURLWithPath: path).resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    return try availableBytes(
      importantUsage: values.volumeAvailableCapacityForImportantUsage,
      free: values.volumeAvailableCapacity)
  }

  /// The choice `availableBytes(at:)` makes from what the volume reported.
  static func availableBytes(importantUsage: Int64?, free: Int?) throws -> UInt64 {
    if let importantUsage {
      return UInt64(max(0, importantUsage))
    }
    guard let free else {
      throw ManagedCAFWriterError.mediaAttributesUnavailable
    }
    return UInt64(max(0, free))
  }
}
