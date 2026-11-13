import Foundation

extension Sequence where Element == UInt8 {
  /// Two lowercase hex digits per byte, the form every stored and logged
  /// digest uses. BoundedAudioImport and PlaybackByteSources keep their own
  /// copy because import and round-trip checks compile them without this file.
  var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}
