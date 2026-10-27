import Foundation

/// Searches the visible, reviewed wording. Earlier machine text never creates
/// a hidden match after the user corrects a passage.
enum TranscriptSearch {
  static func matching(
    _ segments: [NativeTranscriptSegment], query: String
  ) -> [NativeTranscriptSegment] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return segments }
    return segments.filter { $0.effectiveText.localizedStandardContains(term) }
  }

  static func ranges(in text: String, query: String) -> [Range<String.Index>] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return [] }
    var matches: [Range<String.Index>] = []
    var start = text.startIndex
    while start < text.endIndex,
      let range = text.range(
        of: term, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex)
    {
      matches.append(range)
      start = range.upperBound
    }
    return matches
  }
}
