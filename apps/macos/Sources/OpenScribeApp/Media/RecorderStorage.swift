import Foundation

enum RecorderStorage {
  /// Space available for important usage, which includes purgeable APFS space
  /// the system can reclaim. The plain free size omits it and trips the reserve
  /// preflight while space is available. A volume that does not report the
  /// capacity is unknown under the existing reserve policy: this surfaces an
  /// error (handled conservatively by callers), never unlimited space.
  static func availableBytes(at path: String) throws -> UInt64 {
    let values = try URL(fileURLWithPath: path).resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let importantUsage = values.volumeAvailableCapacityForImportantUsage else {
      throw ManagedCAFWriterError.mediaAttributesUnavailable
    }
    return UInt64(max(0, importantUsage))
  }
}
