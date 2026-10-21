import XCTest

@testable import OpenScribeApp

final class TranscriptPlaybackProjectionTests: XCTestCase {
  func testRendererClockUsesTheSeekOriginAndClampsToMediaEnd() {
    XCTAssertEqual(
      TranscriptPlaybackProjection.position(
        start: -1_000_000_000, end: 2_000_000_000, renderedFrames: 48_000, sampleRate: 48_000), 0)
    XCTAssertEqual(
      TranscriptPlaybackProjection.position(
        start: 30_000_000_000, end: 40_000_000_000, renderedFrames: 24_000, sampleRate: 48_000),
      30_500_000_000)
    XCTAssertEqual(
      TranscriptPlaybackProjection.position(
        start: 0, end: 1_000_000_000, renderedFrames: 96_000, sampleRate: 48_000),
      1_000_000_000)
  }

  func testUnavailableOrInvalidClocksNeverManufactureAPlaybackPosition() {
    for rate in [0.0, -1.0, Double.nan, Double.infinity] {
      XCTAssertNil(
        TranscriptPlaybackProjection.position(
          start: 0, end: 10, renderedFrames: 1, sampleRate: rate))
      XCTAssertNil(TranscriptPlaybackProjection.frame(nanoseconds: 1, sampleRate: rate))
    }
    XCTAssertNil(
      TranscriptPlaybackProjection.position(
        start: 0, end: 10, renderedFrames: -1, sampleRate: 48_000))
    XCTAssertNil(
      TranscriptPlaybackProjection.position(
        start: Int64.max - 1, end: Int64.max, renderedFrames: 48_000, sampleRate: 48_000))
    XCTAssertNil(
      TranscriptPlaybackProjection.frame(
        nanoseconds: Int64.max, sampleRate: Double.greatestFiniteMagnitude))
    XCTAssertNil(TranscriptPlaybackProjection.frame(nanoseconds: -1, sampleRate: 48_000))
  }

  func testOverlappingVoicesStayActiveAfterAShorterPassageEnds() {
    let index = TranscriptPlaybackIndex([
      .init(id: "long", start: 0, end: 100),
      .init(id: "brief", start: 20, end: 30),
      .init(id: "later", start: 90, end: 110),
    ])
    XCTAssertEqual(index.activeTurnIds(at: 25), ["long", "brief"])
    XCTAssertEqual(index.activeTurnIds(at: 35), ["long"])
    XCTAssertEqual(index.activeTurnIds(at: 95), ["long", "later"])
    XCTAssertEqual(index.activeTurnIds(at: 100), ["later"])
    XCTAssertEqual(index.activeTurnIds(at: 110), [])
  }

  func testSilenceNegativeOriginsAndInvalidRangesDoNotHighlightUnrelatedText() {
    let index = TranscriptPlaybackIndex([
      .init(id: "negative", start: -10, end: -1),
      .init(id: "zero", start: 0, end: 0),
      .init(id: "backward", start: 3, end: 1),
      .init(id: "later", start: 10, end: 20),
    ])
    XCTAssertEqual(index.activeTurnIds(at: -5), ["negative"])
    XCTAssertEqual(index.activeTurnIds(at: 0), [])
    XCTAssertEqual(index.activeTurnIds(at: 9), [])
    XCTAssertEqual(index.activeTurnIds(at: 10), ["later"])
    XCTAssertEqual(index.activeTurnIds(at: 20), [])
    XCTAssertEqual(TranscriptPlaybackIndex([]).activeTurnIds(at: 0), [])
  }
}
