import Foundation

/// The one way the app writes a length of time. A running timer reads as a
/// clock in the transcript's own stamp format; every other length reads in words.
enum DurationText {
  /// "2:05", "1:01:01".
  static func clock(seconds: UInt64) -> String {
    transcriptClock(nanoseconds: nanoseconds(seconds))
  }

  /// "40 sec", "12 min", "1 hr, 4 min".
  static func length(seconds: UInt64) -> String {
    length(nanoseconds: nanoseconds(seconds))
  }

  static func length(nanoseconds: Int64) -> String {
    let seconds = max(1, Int((Double(nanoseconds) / 1_000_000_000).rounded()))
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .short
    formatter.allowedUnits =
      seconds >= 3_600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
    return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) sec"
  }

  static func length(nanoseconds: UInt64) -> String {
    length(nanoseconds: Int64(clamping: nanoseconds))
  }

  /// "6 min, 26 sec": a source track's length to the whole second, so
  /// sources that stopped at different times read differently.
  static func preciseLength(nanoseconds: UInt64) -> String {
    let seconds = max(1, nanoseconds / 1_000_000_000)
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .short
    formatter.allowedUnits = [.hour, .minute, .second]
    return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) sec"
  }

  private static func nanoseconds(_ seconds: UInt64) -> Int64 {
    let (value, overflow) = Int64(clamping: seconds).multipliedReportingOverflow(
      by: 1_000_000_000)
    return overflow ? .max : value
  }
}

/// What the recorder knows about itself before a library snapshot confirms it.
struct RecorderStatusFacts: Equatable, Sendable {
  var phase: LiveMicrophoneRecordingPhase
  /// "microphone + system audio".
  var recordedAudio: String
  /// What macOS will ask for next, said before it asks.
  var permissionPreflight: String?
  var launchRecoveryPending: Bool
  /// A source stopped and recording continues with the others.
  var lostSource: Bool
  var checkingMicrophoneRoute: Bool
  /// What the saved recording's stereo mix came to.
  var savedNote: String?
}

/// What the saved recording's stereo mix came to. A note still in progress
/// ends with an ellipsis; a settled one does not.
enum RecorderSavedNote {
  static let mixed = "Saved with a stereo mix"
  static let mixUnavailable =
    "Saved. The stereo mix couldn't be made; each source still plays on its own."
  static let mixing = "Saved. Making the stereo mix…"
}

/// What capture is doing, in the words, symbol, and tint every surface shows:
/// the menu bar, the live page, library rows, and Details. The words say what
/// a person can rely on, never how Open Scribe checks it.
struct CaptureStatusPresentation: Equatable, Sendable {
  enum Tint: Equatable, Sendable {
    /// Red, and only beside the word "Recording".
    case recording
    case attention
    case quiet
  }

  let text: String
  let symbolName: String
  let tint: Tint
  /// The running clock beside the text while a capture records or is paused.
  let timer: String?
  let accessibilityText: String
  /// The menu bar status item's words: the app's name while nothing happens.
  let statusItemText: String

  private init(
    _ text: String, symbol: String, tint: Tint = .quiet, timer: String? = nil,
    spoken: String? = nil, statusItem: String? = nil
  ) {
    self.text = text
    symbolName = symbol
    self.tint = tint
    self.timer = timer
    accessibilityText = spoken ?? text
    statusItemText = statusItem ?? [text, timer].compactMap { $0 }.joined(separator: " · ")
  }

  // MARK: One conversation

  init(session: RuntimeSessionPresentation) {
    let clocked =
      session.isRecording || session.isDegradedRecording
      || (session.lifecycle == .paused && !session.captureRecoveryIsolated)
    let timer = clocked ? DurationText.clock(seconds: session.elapsedSeconds) : nil
    let spokenLength = clocked ? ", \(DurationText.length(seconds: session.elapsedSeconds))" : ""
    let attention = SymbolResolver.captureSymbol(for: .recoveryRequired)
    let degraded = SymbolResolver.captureSymbol(for: .degraded)
    if session.didNotRecord {
      self.init("Didn't record", symbol: "minus.circle")
    } else if session.captureRecoveryIsolated {
      self.init("Audio couldn't be opened", symbol: attention, tint: .attention)
    } else if session.lifecycle == .interrupted {
      self.init("Stopped unexpectedly", symbol: attention, tint: .attention)
    } else if session.lifecycle == .readyForReview, session.health == .degraded {
      self.init("Partly saved", symbol: attention, tint: .attention)
    } else if session.isDegradedRecording {
      self.init(
        "Recording — a source stopped", symbol: degraded, tint: .attention, timer: timer,
        spoken: "Recording \(session.capturingSourcesText); a source stopped\(spokenLength)")
    } else if session.health == .degraded {
      let text = Self.lifecycleText(session)
      self.init(text, symbol: degraded, tint: .attention, timer: timer, spoken: text + spokenLength)
    } else if session.isRecording {
      self.init(
        "Recording", symbol: SymbolResolver.captureSymbol(for: .recording), tint: .recording,
        timer: timer, spoken: "Recording \(session.capturingSourcesText)\(spokenLength)")
    } else if let media = session.playableMedia, !media.isPlayable {
      self.init(media.statusText, symbol: degraded, tint: .attention)
    } else {
      let text = Self.lifecycleText(session)
      let symbol: String =
        switch session.lifecycle {
        case .paused: SymbolResolver.pausedCaptureSymbolName
        case .readyForReview: SymbolResolver.captureSymbol(for: .ready)
        case .deleted, .interrupted: SymbolResolver.captureSymbol(for: .idle)
        case .preparing, .recording, .finalizing: SymbolResolver.captureSymbol(for: .starting)
        }
      self.init(text, symbol: symbol, timer: timer, spoken: text + spokenLength)
    }
  }

  private static func lifecycleText(_ session: RuntimeSessionPresentation) -> String {
    switch session.lifecycle {
    case .preparing, .recording: "Starting…"
    case .paused: "Paused"
    case .finalizing: "Saving…"
    case .interrupted: "Stopped unexpectedly"
    case .readyForReview: session.recovered ? "Recovered" : "Saved"
    case .deleted: "Moved to Trash"
    }
  }

  /// What happened to a conversation that needs attention, as one plain
  /// sentence for its page. Which source failed is in Details.
  static func attentionText(for session: RuntimeSessionPresentation) -> String? {
    if session.didNotRecord {
      return session.interruptionReason == .permissionRevoked
        ? "Recording stopped when access to audio was turned off, before any audio was saved."
        : "This recording didn't start, so there is no audio."
    }
    if session.captureRecoveryIsolated {
      return
        "Recording stopped unexpectedly, and Open Scribe couldn't open the audio it saved. The files are kept."
    }
    switch session.interruptionReason {
    case .permissionRevoked?:
      return
        "Recording stopped when access to audio was turned off. The audio up to that point is saved."
    case .segmentSealFailed?, .stopWithoutDurableSample?:
      return "Part of this recording couldn't be saved. Details lists each source."
    case .captureStartFailed?, .firstSampleRejected?:
      return "Recording couldn't start properly. The audio that arrived is saved."
    case .captureFailed?:
      return session.lifecycle == .readyForReview
        ? "Part of this recording couldn't be saved. Details lists each source."
        : "Recording stopped unexpectedly — the audio up to that point is saved."
    case nil:
      if session.lifecycle == .interrupted {
        return "Recording stopped unexpectedly — the audio up to that point is saved."
      }
      return session.health == .degraded
        ? "Part of this recording couldn't be saved. Details lists each source." : nil
    }
  }

  // MARK: The recorder

  /// The recorder's wording for its own phase. While it is starting, nothing
  /// says Recording; it says so only once both sources are capturing.
  static func recorderText(_ facts: RecorderStatusFacts) -> String {
    if facts.phase == .requestingPermission, let preflight = facts.permissionPreflight {
      return preflight
    }
    return switch facts.phase {
    case .idle:
      readiness(recordedAudio: facts.recordedAudio, launchRecoveryPending: facts.launchRecoveryPending)
    case .requestingPermission: "Asking for microphone access…"
    case .preparing: "Starting…"
    case .starting:
      facts.lostSource ? "Starting the remaining audio…" : "Starting \(facts.recordedAudio)…"
    case .capturing:
      if facts.lostSource {
        "Recording continues with remaining audio"
      } else if facts.checkingMicrophoneRoute {
        "Recording continues; checking the microphone after an audio change"
      } else {
        "Recording \(facts.recordedAudio)"
      }
    case .pausing: "Pausing…"
    case .paused: "Paused"
    case .stopping: "Saving…"
    case .saved: facts.savedNote ?? "Saved"
    case .failed: "Couldn't record"
    }
  }

  /// Idle wording. It never claims readiness while the last session is checked.
  static func readiness(recordedAudio: String, launchRecoveryPending: Bool) -> String {
    launchRecoveryPending
      ? "Checking recordings from the last session…" : "Ready to record \(recordedAudio)"
  }

  // MARK: The status the menu bar and live page show

  /// The conversation in progress when there is one, else the recorder's own
  /// phase. A capture the library has not confirmed never reads as Recording.
  static func current(
    session: RuntimeSessionPresentation?, snapshotStale: Bool,
    livePhase: LiveMicrophoneRecordingPhase, liveText: String
  ) -> CaptureStatusPresentation {
    let starting = SymbolResolver.captureSymbol(for: .starting)
    if snapshotStale {
      return .init(
        "Status unavailable", symbol: "exclamationmark.circle", tint: .attention,
        spoken: "Recording status unavailable")
    }
    if livePhase == .requestingPermission { return .init(liveText, symbol: starting) }
    // An attempt that never recorded has nothing to show here; its row says so.
    if let session, !session.didNotRecord { return .init(session: session) }
    return switch livePhase {
    case .idle:
      .init(
        liveText, symbol: SymbolResolver.captureSymbol(for: .ready), statusItem: "Open Scribe")
    case .capturing: .init("Starting…", symbol: starting)
    case .paused: .init(liveText, symbol: SymbolResolver.pausedCaptureSymbolName)
    case .failed: .init(liveText, symbol: "exclamationmark.circle", tint: .attention)
    case .saved: .init(liveText, symbol: "waveform.badge.checkmark")
    case .requestingPermission, .preparing, .starting, .pausing, .stopping:
      .init(liveText, symbol: starting)
    }
  }
}
