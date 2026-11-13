import AVFoundation
import CryptoKit
import Foundation

/// Receives audio a capture adapter has already written durably. Called on
/// the adapter's writer queue, never the real-time callback; the buffer is
/// only valid for the duration of the call, so a listener copies it.
/// `hostTime` is the capture host time of the buffer's first frame.
protocol LiveAudioListening: AnyObject, Sendable {
  func receive(_ buffer: AVAudioPCMBuffer, writtenFrames: AVAudioFrameCount, hostTime: UInt64)
}

/// A lock-guarded listener slot a capture adapter owns. While the recognizer
/// is still loading, the slot holds copies of the written audio so the first
/// words of a span are captioned as soon as it is ready instead of lost.
final class LiveAudioListenerSlot: @unchecked Sendable {
  /// The most audio held while waiting; the oldest is dropped beyond it.
  static let holdLimitSeconds: Double = 20

  private struct Held {
    let buffer: AVAudioPCMBuffer
    let writtenFrames: AVAudioFrameCount
    let hostTime: UInt64
  }

  private let lock = NSLock()
  private var listener: LiveAudioListening?
  private var holding = false
  private var held: [Held] = []
  private var heldSeconds: Double = 0

  /// Holds written audio until a listener attaches or the slot is cleared.
  func hold() {
    lock.withLock {
      holding = listener == nil
      held = []
      heldSeconds = 0
    }
  }

  /// Attaches a listener and hands it the held audio first, in order, or
  /// clears the slot and drops what it held.
  func set(_ listener: LiveAudioListening?) {
    lock.withLock {
      self.listener = listener
      let pending = held
      holding = false
      held = []
      heldSeconds = 0
      guard let listener else { return }
      // Under the lock, so a buffer written meanwhile follows the held ones.
      for item in pending {
        listener.receive(item.buffer, writtenFrames: item.writtenFrames, hostTime: item.hostTime)
      }
    }
  }

  func deliver(_ buffer: AVAudioPCMBuffer, writtenFrames: AVAudioFrameCount, hostTime: UInt64) {
    guard writtenFrames > 0 else { return }
    let attached: LiveAudioListening? = lock.withLock {
      if let listener { return listener }
      guard holding, buffer.format.sampleRate > 0, let copy = buffer.deepCopy() else { return nil }
      held.append(Held(buffer: copy, writtenFrames: writtenFrames, hostTime: hostTime))
      heldSeconds += Double(copy.frameLength) / copy.format.sampleRate
      while heldSeconds > Self.holdLimitSeconds, !held.isEmpty {
        let oldest = held.removeFirst()
        heldSeconds -= Double(oldest.buffer.frameLength) / oldest.buffer.format.sampleRate
      }
      return nil
    }
    attached?.receive(buffer, writtenFrames: writtenFrames, hostTime: hostTime)
  }
}

extension AVAudioPCMBuffer {
  /// A deep copy in the same format, or nil for an empty buffer.
  func deepCopy() -> AVAudioPCMBuffer? {
    let count = frameLength
    guard count > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
      return nil
    }
    copy.frameLength = count
    let length = Int(count) * Int(format.streamDescription.pointee.mBytesPerFrame)
    let source = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: audioBufferList))
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for index in 0..<min(source.count, destination.count) {
      guard let from = source[index].mData, let to = destination[index].mData,
        Int(source[index].mDataByteSize) >= length
      else { continue }
      memcpy(to, from, length)
      destination[index].mDataByteSize = UInt32(length)
    }
    return copy
  }
}

/// Places caption audio on the session timeline. The store maps a segment's
/// first-sample host time to session time; within one capture span that
/// mapping is linear in host time, so one accepted first sample anchors every
/// later buffer of the span, including after a dropped buffer or a late start.
final class LiveCaptionClock: @unchecked Sendable {
  private let lock = NSLock()
  private var origin: (hostTime: UInt64, sessionNanoseconds: Int64)?

  func anchor(hostTime: UInt64, sessionNanoseconds: Int64) {
    lock.withLock {
      guard origin == nil else { return }
      origin = (hostTime, sessionNanoseconds)
    }
  }

  /// The session time of `hostTime`, or nil before the span's first sample
  /// is accepted or for audio from before the session timeline begins.
  func sessionNanoseconds(hostTime: UInt64) -> Int64? {
    guard let origin = lock.withLock({ origin }) else { return nil }
    let ticks = Int64(bitPattern: hostTime &- origin.hostTime)
    let value = origin.sessionNanoseconds + Self.nanoseconds(ticks: ticks)
    return value >= 0 ? value : nil
  }

  private static let timebase: (numer: Int64, denom: Int64) = {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return (1, 1) }
    return (Int64(info.numer), Int64(info.denom))
  }()

  static func nanoseconds(ticks: Int64) -> Int64 {
    let (numer, denom) = timebase
    return Int64((Double(ticks) * Double(numer) / Double(denom)).rounded())
  }
}

/// Which side of the conversation a caption came from. The microphone is the
/// local user; computer audio carries everyone else (founding PRD 11.3).
enum LiveCaptionSource: String, Sendable {
  case microphone
  case computer
}

/// One caption line. Volatile lines are the recognizer's current guess for
/// the phrase being spoken; final lines are settled and saved as Draft text.
struct LiveCaptionLine: Identifiable, Equatable, Sendable {
  let id: String
  let source: LiveCaptionSource
  let speaker: String
  let text: String
  let startNanoseconds: Int64
  let endNanoseconds: Int64
  let isFinal: Bool
}

/// A settled phrase with word timings, used to split it into store windows.
struct LiveCaptionPhrase: Sendable {
  struct Word: Sendable {
    let text: String
    let startNanoseconds: Int64
    let endNanoseconds: Int64
  }
  let text: String
  let startNanoseconds: Int64
  let endNanoseconds: Int64
  let words: [Word]
}

/// The identity a live caption track writes Draft windows under.
struct LiveCaptionEngineIdentity: Sendable {
  static let engine = "apple-speech-transcriber"
  static let reconciliationVersion = "live-captions-1"
  let engineVersion: String
  let modelId: String
  let modelSha256: String
  let optionsDigest: String

  init(localeIdentifier: String, preset: String) {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    engineVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    modelId = "SpeechTranscriber.\(localeIdentifier)"
    modelSha256 = Self.sha256("\(Self.engine)|\(localeIdentifier)|\(engineVersion)")
    optionsDigest = Self.sha256(preset)
  }

  private static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).lowercaseHex
  }
}

/// Splits settled phrases into windows the store accepts and commits them in
/// order on one serial queue. A refused window is dropped: live Draft text is
/// a convenience, and capture never waits on it.
final class LiveDraftCommitter: @unchecked Sendable {
  /// Room left under Rust's window limit for word timings that end late.
  static let windowMarginNanoseconds: Int64 = 500_000_000
  static let maximumWindowNanoseconds =
    NativeCapturePolicy.current.liveDraftWindowMaxNanoseconds - windowMarginNanoseconds
  private let queue = DispatchQueue(label: "app.open-scribe.live-draft-commit", qos: .utility)
  private let preparation: NativeRecordingPreparationProtocol
  private let sessionId: String
  private let trackId: String
  private let identity: LiveCaptionEngineIdentity
  private let lock = NSLock()
  private var refused = 0

  init(
    preparation: NativeRecordingPreparationProtocol, sessionId: String, trackId: String,
    identity: LiveCaptionEngineIdentity
  ) {
    self.preparation = preparation
    self.sessionId = sessionId
    self.trackId = trackId
    self.identity = identity
  }

  var refusedWindows: Int { lock.withLock { refused } }

  func commit(_ phrase: LiveCaptionPhrase) {
    let windows = Self.windows(for: phrase)
    queue.async { [self] in
      for window in windows {
        do {
          _ = try preparation.commitLiveDraftWindow(
            window: NativeLiveDraftWindow(
              sessionId: sessionId, trackId: trackId,
              startNanoseconds: window.start, endNanoseconds: window.end, text: window.text,
              engine: LiveCaptionEngineIdentity.engine, engineVersion: identity.engineVersion,
              modelId: identity.modelId, modelSha256: identity.modelSha256,
              optionsDigest: identity.optionsDigest,
              reconciliationVersion: LiveCaptionEngineIdentity.reconciliationVersion))
        } catch {
          lock.withLock { refused += 1 }
        }
      }
    }
  }

  /// Waits for every commit already queued.
  func drain() async {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
  }

  struct Window: Equatable {
    let start: Int64
    let end: Int64
    let text: String
  }

  /// Groups words into consecutive windows no longer than the store limit.
  /// A phrase without word timings is clamped to one window.
  static func windows(for phrase: LiveCaptionPhrase) -> [Window] {
    let text = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, phrase.endNanoseconds > phrase.startNanoseconds else { return [] }
    if phrase.endNanoseconds - phrase.startNanoseconds <= maximumWindowNanoseconds
      || phrase.words.isEmpty
    {
      let end = min(phrase.endNanoseconds, phrase.startNanoseconds + maximumWindowNanoseconds)
      return [Window(start: phrase.startNanoseconds, end: end, text: text)]
    }
    var windows: [Window] = []
    var words: [String] = []
    var start = phrase.words[0].startNanoseconds
    var end = start
    for word in phrase.words {
      if !words.isEmpty, word.endNanoseconds - start > maximumWindowNanoseconds {
        windows.append(Window(start: start, end: max(end, start + 1), text: words.joined()))
        words = []
        start = word.startNanoseconds
      }
      words.append(word.text)
      end = word.endNanoseconds
    }
    if !words.isEmpty {
      windows.append(Window(start: start, end: max(end, start + 1), text: words.joined()))
    }
    return windows.compactMap { window in
      let trimmed = window.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : Window(start: window.start, end: window.end, text: trimmed)
    }
  }
}

/// The track a live caption transcriber listens to and writes for.
struct LiveCaptionTrack: Sendable {
  let sessionId: String
  let trackId: String
  let source: LiveCaptionSource
  let speaker: String
  /// Anchored when the span's first sample on this track is accepted.
  let clock: LiveCaptionClock
}

extension LiveCaptionTrack {
  /// The caption tracks for one capture span, each labeled with its source's
  /// default speaker and given a fresh clock for the span.
  static func span(
    sessionId: String,
    microphone: (NativeMediaOpenAuthorization, LiveAudioListenerSlot)?,
    computer: (NativeMediaSourceKind, NativeMediaOpenAuthorization, LiveAudioListenerSlot)?
  ) -> [(LiveCaptionTrack, LiveAudioListenerSlot)] {
    typealias Entry = (
      kind: NativeMediaSourceKind, source: LiveCaptionSource,
      authorization: NativeMediaOpenAuthorization, slot: LiveAudioListenerSlot
    )
    var entries: [Entry] = []
    if let (authorization, slot) = microphone {
      entries.append((.microphone, .microphone, authorization, slot))
    }
    if let (kind, authorization, slot) = computer {
      entries.append((kind, .computer, authorization, slot))
    }
    return entries.map { entry in
      let speaker = NativeCapturePolicy.current.source(entry.kind).speakerLabel
      return (
        LiveCaptionTrack(
          sessionId: sessionId, trackId: entry.authorization.trackId, source: entry.source,
          speaker: speaker, clock: LiveCaptionClock()),
        entry.slot
      )
    }
  }
}
