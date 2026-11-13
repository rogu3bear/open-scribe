import Foundation

/// The live transcript shown while recording. One capture span (from Record
/// or Resume until Pause or Stop) owns one transcriber per required source.
/// Settled phrases are saved as Draft windows on their track; the in-progress
/// phrase is shown only. The recorder never waits for captions to start, and a
/// failure here leaves capture untouched.
@MainActor
final class LiveCaptionModel: ObservableObject {
  enum Status: Equatable {
    /// Not checked yet, or no recording has asked.
    case idle
    /// Listening with this recognizer language.
    case listening(language: String)
    /// Turned off in Settings.
    case off
    /// This Mac needs a newer macOS or the speech model for the language.
    case unavailable(String)
  }

  static let enabledDefaultsKey = "OpenScribeLiveCaptionsEnabled"
  static let maximumLines = 2_000

  @Published private(set) var lines: [LiveCaptionLine] = []
  @Published private(set) var current: [LiveCaptionSource: LiveCaptionLine] = [:]
  @Published private(set) var status: Status = .idle
  @Published var isEnabled: Bool {
    didSet { defaults.set(isEnabled, forKey: Self.enabledDefaultsKey) }
  }

  private let defaults: UserDefaults
  /// While suspended no recognizer runs and no Draft window is written. Only
  /// the app's normal launch turns captions on.
  private let suspended: Bool
  private var sessionId: String?
  /// Increases with every span so a slow start cannot attach to a later one.
  private var generation = 0
  private var spanTask: Task<Void, Never>?
  private var settleTask: Task<Void, Never>?
  private var clocks: [String: LiveCaptionClock] = [:]
  private var listeners: [LiveAudioListenerSlot] = []
  private var finishers: [@Sendable () async -> Void] = []
  private var cancellers: [@Sendable () async -> Void] = []
  private var committers: [LiveDraftCommitter] = []

  init(defaults: UserDefaults = .standard, suspended: Bool = true) {
    self.defaults = defaults
    self.suspended = suspended
    defaults.register(defaults: [Self.enabledDefaultsKey: true])
    isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
  }

  var isListening: Bool {
    if case .listening = status { return true }
    return false
  }

  /// Starts captions for a new or resumed span. Audio before the recognizer
  /// is ready is recorded but not captioned.
  func beginSpan(
    preparation: NativeRecordingPreparationProtocol,
    tracks: [(LiveCaptionTrack, LiveAudioListenerSlot)]
  ) {
    guard let first = tracks.first, !suspended else { return }
    if sessionId != first.0.sessionId {
      sessionId = first.0.sessionId
      lines = []
      current = [:]
    }
    generation += 1
    clocks = Dictionary(tracks.map { ($0.0.trackId, $0.0.clock) }) { first, _ in first }
    guard isEnabled else {
      status = .off
      return
    }
    let span = generation
    // Hold the span's audio while the recognizer loads; it is captioned as
    // soon as the recognizer attaches, or dropped if it never does.
    listeners = tracks.map(\.1)
    for slot in listeners { slot.hold() }
    let previous = settleTask
    spanTask = Task { [weak self] in
      await previous?.value
      await self?.startSpan(span, preparation: preparation, tracks: tracks)
    }
  }

  /// Places the span's audio on the session timeline from the first sample
  /// the store accepted for this track.
  func anchor(trackId: String, hostTime: UInt64, sessionNanoseconds: Int64) {
    clocks[trackId]?.anchor(hostTime: hostTime, sessionNanoseconds: sessionNanoseconds)
  }

  private func startSpan(
    _ span: Int,
    preparation: NativeRecordingPreparationProtocol,
    tracks: [(LiveCaptionTrack, LiveAudioListenerSlot)]
  ) async {
    guard #available(macOS 26.0, *) else {
      release(tracks, span: span)
      status = .unavailable("Live transcript needs macOS 26 or later.")
      return
    }
    guard let locale = await LiveCaptionTranscriber.installedLocale(closestTo: .current) else {
      release(tracks, span: span)
      status = .unavailable(
        "Live transcript needs Apple's speech model for your language. Download it in Settings.")
      return
    }
    let identity = LiveCaptionEngineIdentity(
      localeIdentifier: locale.identifier(.bcp47), preset: LiveCaptionTranscriber.presetName)
    for (track, slot) in tracks {
      guard span == generation, !Task.isCancelled else { return }
      let committer = LiveDraftCommitter(
        preparation: preparation, sessionId: track.sessionId, trackId: track.trackId,
        identity: identity)
      let sink = LiveCaptionEventSink(model: self, committer: committer)
      do {
        let transcriber = try await LiveCaptionTranscriber.make(track: track, locale: locale) {
          event in sink.deliver(event)
        }
        // The span ended while the recognizer was preparing.
        guard span == generation, !Task.isCancelled else {
          await transcriber.cancel()
          return
        }
        slot.set(transcriber)
        committers.append(committer)
        finishers.append { await transcriber.finish() }
        cancellers.append { await transcriber.cancel() }
      } catch {
        if span == generation { slot.set(nil) }
        status = .unavailable("Live transcript could not start on this Mac.")
      }
    }
    if !finishers.isEmpty {
      status = .listening(
        language: Locale.current.localizedString(forIdentifier: locale.identifier)
          ?? locale.identifier)
    }
  }

  /// Stops holding audio for a span whose recognizer will not attach.
  private func release(_ tracks: [(LiveCaptionTrack, LiveAudioListenerSlot)], span: Int) {
    guard span == generation else { return }
    for (_, slot) in tracks { slot.set(nil) }
  }

  /// Stops listening, settles the last phrase on every track, and waits until
  /// its Draft window is saved. Called before a pause or stop is recorded,
  /// while the tracks still accept Draft windows. The whole wait, including a
  /// recognizer still preparing, is bounded, and a second caller shares it.
  func endSpan(timeoutNanoseconds: UInt64 = 2_000_000_000) async {
    if let settleTask {
      await settleTask.value
      return
    }
    guard spanTask != nil || !finishers.isEmpty || !listeners.isEmpty else { return }
    // A span that has not attached yet is abandoned rather than awaited.
    generation += 1
    spanTask?.cancel()
    spanTask = nil
    for slot in listeners { slot.set(nil) }
    let finishers = self.finishers
    let committers = self.committers
    let cancellers = self.cancellers
    listeners = []
    self.finishers = []
    self.cancellers = []
    self.committers = []
    current = [:]
    let settle = Task {
      let work = Task {
        for finish in finishers { await finish() }
        for committer in committers { await committer.drain() }
      }
      // Not a task group: a group would wait for a stuck recognizer anyway.
      if await !Self.completes(work, within: timeoutNanoseconds) {
        for cancel in cancellers { await cancel() }
      }
    }
    settleTask = settle
    await settle.value
    if settleTask == settle { settleTask = nil }
    if isListening { status = .idle }
  }

  /// True when `work` finishes first, false when the timeout does. The
  /// caller is released at the timeout even if `work` never returns.
  nonisolated static func completes(_ work: Task<Void, Never>, within nanoseconds: UInt64) async
    -> Bool
  {
    let once = ResumeOnce()
    return await withCheckedContinuation { continuation in
      Task {
        await work.value
        if once.claim() { continuation.resume(returning: true) }
      }
      Task {
        try? await Task.sleep(nanoseconds: nanoseconds)
        if once.claim() { continuation.resume(returning: false) }
      }
    }
  }

  /// Ends captions without settling, for a failed or abandoned recording.
  func cancel() {
    generation += 1
    spanTask?.cancel()
    spanTask = nil
    for slot in listeners { slot.set(nil) }
    let cancellers = self.cancellers
    listeners = []
    finishers = []
    self.cancellers = []
    committers = []
    current = [:]
    if isListening { status = .idle }
    Task { for cancel in cancellers { await cancel() } }
  }

  /// Forgets the transcript of a finished recording.
  func clear() {
    sessionId = nil
    lines = []
    current = [:]
  }

  fileprivate func apply(_ event: LiveCaptionTranscriberEvent) {
    switch event {
    case .volatile(let line):
      current[line.source] = line
    case .settled(let line, _):
      current[line.source] = nil
      insert(line)
    }
  }

  private func insert(_ line: LiveCaptionLine) {
    let index = lines.lastIndex { $0.startNanoseconds <= line.startNanoseconds }.map { $0 + 1 } ?? 0
    lines.insert(line, at: index)
    if lines.count > Self.maximumLines { lines.removeFirst(lines.count - Self.maximumLines) }
  }
}

/// The events a transcriber reports, available on every supported macOS so
/// the model can be compiled for the deployment floor.
enum LiveCaptionTranscriberEvent: Sendable {
  case volatile(LiveCaptionLine)
  case settled(LiveCaptionLine, LiveCaptionPhrase)
}

/// Hands transcriber events to the model on the main actor without the
/// transcriber keeping the model alive.
private final class LiveCaptionEventSink: @unchecked Sendable {
  private weak var model: LiveCaptionModel?
  private let committer: LiveDraftCommitter

  @MainActor
  init(model: LiveCaptionModel, committer: LiveDraftCommitter) {
    self.model = model
    self.committer = committer
  }

  /// Queues a settled phrase's Draft windows before returning, so a stop
  /// that drains the committer after the transcriber finishes includes it.
  func deliver(_ event: LiveCaptionTranscriberEvent) {
    if case .settled(_, let phrase) = event { committer.commit(phrase) }
    Task { @MainActor in self.model?.apply(event) }
  }
}

/// Lets exactly one of two racing tasks resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.withLock {
      defer { claimed = true }
      return !claimed
    }
  }
}
