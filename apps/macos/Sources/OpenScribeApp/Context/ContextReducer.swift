import Accelerate
import CoreGraphics
import Foundation
@preconcurrency import Vision

enum ContextReductionError: Error {
  case invalidImage
  case recognitionFailed
}

/// A 160-by-90 grayscale working image of one frame and its 16-by-9 grid of
/// 10-pixel block means (ADR 0012, Change detection). It lives only in
/// memory for one scope epoch and is never durable evidence.
struct ContextFingerprint: Equatable, Sendable {
  static let width = 160
  static let height = 90
  static let block = 10
  let luma: [UInt8]
  let blocks: [Double]

  init(luma: [UInt8]) {
    self.luma = luma
    let columns = Self.width / Self.block
    var sums = [Int](repeating: 0, count: columns * (Self.height / Self.block))
    for (index, value) in luma.enumerated() {
      let row = index / Self.width / Self.block
      let column = index % Self.width / Self.block
      sums[row * columns + column] += Int(value)
    }
    blocks = sums.map { Double($0) / Double(Self.block * Self.block) }
  }

  /// The largest change of any block's mean luma, 0–255. A local text
  /// change registers; a uniform shift of a level or two does not.
  func delta(to other: ContextFingerprint) -> Double {
    guard blocks.count == other.blocks.count, !blocks.isEmpty else { return .infinity }
    return zip(blocks, other.blocks).map { abs($0 - $1) }.max() ?? 0
  }
}

/// Local frame reduction: grayscale fingerprinting through Accelerate, then
/// Vision text recognition only after a calibrated visual change. The
/// revision strings are recorded with every event; changing the threshold,
/// the fingerprint, or the reading rules requires a new revision.
enum ContextReducer {
  static let revision = "luma160x90-block10-max3-v1"
  /// Frames whose largest block-mean luma change is below this produce no OCR work.
  static let changeThreshold = 3.0
  static let languages = ["en-US"]

  static var visionRevision: String {
    "VNRecognizeTextRequest-\(VNRecognizeTextRequest.currentRevision)"
  }

  /// Aspect-fits the frame onto a black 160-by-90 grayscale canvas.
  static func fingerprint(_ image: CGImage) throws -> ContextFingerprint {
    guard image.width > 0, image.height > 0,
      var format = vImage_CGImageFormat(
        bitsPerComponent: 8, bitsPerPixel: 8,
        colorSpace: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))
    else { throw ContextReductionError.invalidImage }
    var source = vImage_Buffer()
    guard vImageBuffer_InitWithCGImage(&source, &format, nil, image, vImage_Flags(kvImageNoFlags))
      == kvImageNoError
    else { throw ContextReductionError.invalidImage }
    defer { free(source.data) }

    let width = ContextFingerprint.width
    let height = ContextFingerprint.height
    let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
    let fittedWidth = max(1, min(width, Int((Double(image.width) * scale).rounded())))
    let fittedHeight = max(1, min(height, Int((Double(image.height) * scale).rounded())))
    var canvas = [UInt8](repeating: 0, count: width * height)
    let originX = (width - fittedWidth) / 2
    let originY = (height - fittedHeight) / 2
    let result = canvas.withUnsafeMutableBytes { bytes -> vImage_Error in
      guard let base = bytes.baseAddress else { return kvImageMemoryAllocationError }
      var destination = vImage_Buffer(
        data: base + originY * width + originX,
        height: vImagePixelCount(fittedHeight), width: vImagePixelCount(fittedWidth),
        rowBytes: width)
      return vImageScale_Planar8(
        &source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
    }
    guard result == kvImageNoError else { throw ContextReductionError.invalidImage }
    return ContextFingerprint(luma: canvas)
  }

  /// Whether a frame differs enough from the last candidate to justify OCR.
  static func changed(_ current: ContextFingerprint, from previous: ContextFingerprint?) -> Bool {
    guard let previous else { return true }
    return current.delta(to: previous) >= changeThreshold
  }

  /// Recognizes text locally. Each block's box is normalized to the frame
  /// with a top-left origin; text is Unicode-normalized (NFC). Confidence is
  /// not used to drop anything.
  static func recognize(_ image: CGImage) throws -> [NativeContextTextBlock] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      throw ContextReductionError.recognitionFailed
    }
    return (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let text = candidate.string.precomposedStringWithCanonicalMapping
      let box = observation.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
      return NativeContextTextBlock(
        text: text, x: Double(box.minX), y: Double(1 - box.maxY),
        width: Double(box.width), height: Double(box.height))
    }
  }
}
