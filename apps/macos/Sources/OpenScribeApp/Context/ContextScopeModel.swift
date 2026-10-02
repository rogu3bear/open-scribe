import AppKit
import Combine
@preconcurrency import ScreenCaptureKit

/// The recording writer and the capture session context attaches to.
struct ContextBinding: @unchecked Sendable {
  let preparation: NativeRecordingPreparationProtocol
  let sessionId: String
}

/// A display or window the preflight offers, named as ADR 0011 requires.
struct ContextChoice: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable { case display, window }
  let id: String
  let kind: Kind
  let platformId: String
  let name: String
  let application: String?
  let description: String
  /// Global Core Graphics points, top-left origin.
  let frame: CGRect
}

/// What the user is about to authorize.
struct ContextSelection: Equatable, Sendable {
  var mode: NativeContextMode = .watchWindow
  var choiceId: String?
  /// Watch Region bounds, normalized to the chosen display (top-left origin).
  var region = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
}

/// Swift's half of context authority: choices, preflight, sampling, and the
/// platform signals that pause or stop context. Rust owns the durable scope,
/// its epoch, and every accept or reject decision.
@MainActor
final class ContextScopeModel: ObservableObject {
  @Published private(set) var detail: NativeContextDetail? {
    didSet { updateOverlay() }
  }
  @Published private(set) var choices: [ContextChoice] = []
  @Published private(set) var windowsNeedPermission = false
  @Published private(set) var permission: NativeScreenPermission = .denied
  @Published private(set) var message: String?
  /// Advances only when Rust accepts an event (Active attention).
  @Published private(set) var acceptedPulse = 0 {
    didSet { overlay.pulse() }
  }
  @Published private(set) var lastOutcome: ContextOutcome?
  @Published var selection = ContextSelection()

  let worker: ContextWorker
  let overlay = ContextOverlayController()
  private let relay: ProposalRelay
  private let bindingSource: @MainActor () -> ContextBinding?
  private let permissionCheck: @MainActor () -> NativeScreenPermission
  private let permissionRequest: @MainActor () -> NativeScreenPermission
  private let topology: @MainActor () -> [ContextDisplay]
  private var sampler: Task<Void, Never>?
  private var monitor: Task<Void, Never>?
  private var pointerTimer: Timer?
  private var dwell = PointerDwellDetector()
  private var lastPointerCapture: Date = .distantPast
  private var lastAcceptedAt: Date = .distantPast
  private var consecutiveFailures = 0
  private var topologySignature = ""
  private var observers: [NSObjectProtocol] = []
  private var cancellables: Set<AnyCancellable> = []

  init(
    binding: @escaping @MainActor () -> ContextBinding?,
    frames: ContextFrameCapturing = ScreenContextFrameSource(),
    recognize: @escaping ContextWorker.Recognize = { try ContextReducer.recognize($0) },
    permissionCheck: @escaping @MainActor () -> NativeScreenPermission = {
      ScreenCapturePermission.current()
    },
    permissionRequest: @escaping @MainActor () -> NativeScreenPermission = {
      ScreenCapturePermission.request()
    },
    topology: @escaping @MainActor () -> [ContextDisplay] = { ContextTopology.current() }
  ) {
    bindingSource = binding
    self.permissionCheck = permissionCheck
    self.permissionRequest = permissionRequest
    self.topology = topology
    let relay = ProposalRelay()
    self.relay = relay
    worker = ContextWorker(
      frames: frames, propose: { try relay.propose($0) }, recognize: recognize)
    worker.onOutcome { [weak self] request, outcome in
      Task { @MainActor in self?.handle(outcome, for: request) }
    }
    permission = permissionCheck()
  }

  convenience init(recorder: LiveMicrophoneRecordingController) {
    self.init(binding: { [weak recorder] in recorder?.contextBinding })
    recorder.$phase.sink { [weak self] _ in
      Task { @MainActor in self?.recordingChanged() }
    }.store(in: &cancellables)
  }

  var current: NativeContextScope? { detail?.scopes.last }
  var isLive: Bool { current.map { [.active, .paused].contains($0.condition) } ?? false }
  var isActive: Bool { current?.condition == .active }
  var canAuthorize: Bool { bindingSource() != nil }
  func binding() -> ContextBinding? { bindingSource() }

  // MARK: Preflight

  /// Lists displays with topology names and, when permitted, ordinary windows.
  func refreshChoices() async {
    permission = permissionCheck()
    let displays = topology()
    let names = ContextTopology.uniqueNames(displays)
    var result = displays.map { display in
      ContextChoice(
        id: "display-\(display.id)", kind: .display, platformId: String(display.id),
        name: names[display.id] ?? display.name, application: nil,
        description: ContextTopology.describe(display, in: displays), frame: display.frame)
    }
    windowsNeedPermission = permission != .granted
    if permission == .granted,
      let content = try? await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
    {
      let ownProcess = ProcessInfo.processInfo.processIdentifier
      for window in content.windows where window.windowLayer == 0 && window.isOnScreen {
        guard let application = window.owningApplication,
          application.processID != ownProcess,
          window.frame.width >= 80, window.frame.height >= 60
        else { continue }
        let appName = application.applicationName.isEmpty ? "Application" : application.applicationName
        let title = (window.title?.isEmpty == false ? window.title : nil) ?? "Untitled window"
        let display = displays.first { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }
        let place = display.map { " on \(names[$0.id] ?? $0.name)" } ?? ""
        result.append(
          ContextChoice(
            id: "window-\(window.windowID)", kind: .window, platformId: String(window.windowID),
            name: title, application: appName, description: "\(appName) — \(title)\(place)",
            frame: window.frame))
      }
    }
    choices = result
    if selection.choiceId.map({ id in !result.contains { $0.id == id } }) ?? true {
      selection.choiceId = result.first { $0.kind == (needsWindow ? .window : .display) }?.id
    }
  }

  var needsWindow: Bool { [.watchWindow, .addCurrentWindow].contains(selection.mode) }

  /// The exact surfaces this mode excludes, as disclosed before authorization.
  nonisolated static func exclusions(for mode: NativeContextMode) -> [String] {
    switch mode {
    case .followPointer:
      ["open_scribe", "dock", "menu_bar", "notifications", "password_managers", "private_windows", "lock_screen"]
    case .watchWindow, .addCurrentWindow:
      ["open_scribe", "dock", "menu_bar", "notifications", "lock_screen"]
    case .watchDisplay, .watchRegion:
      ["open_scribe", "lock_screen"]
    }
  }

  func request(for selection: ContextSelection, permission: NativeScreenPermission) throws
    -> NativeContextScopeRequest
  {
    let displays = topology()
    let names = ContextTopology.uniqueNames(displays)
    func displayTarget(_ display: ContextDisplay) -> NativeContextTarget {
      NativeContextTarget(
        kind: .display, platformId: String(display.id), name: names[display.id] ?? display.name,
        application: nil, description: ContextTopology.describe(display, in: displays))
    }
    let choice = choices.first { $0.id == selection.choiceId }
    var targets: [NativeContextTarget]
    var bounds: NativeContextBounds?
    switch selection.mode {
    case .followPointer:
      targets = displays.map(displayTarget)
    case .watchDisplay, .watchRegion:
      guard let choice, choice.kind == .display,
        let display = displays.first(where: { String($0.id) == choice.platformId })
      else { throw NativeStorageError.InvalidRequest }
      targets = [displayTarget(display)]
      if selection.mode == .watchRegion {
        bounds = NativeContextBounds(
          displayId: choice.platformId, x: selection.region.minX, y: selection.region.minY,
          width: selection.region.width, height: selection.region.height)
      }
    case .watchWindow, .addCurrentWindow:
      guard let choice, choice.kind == .window else { throw NativeStorageError.InvalidRequest }
      targets = [
        NativeContextTarget(
          kind: .window, platformId: choice.platformId, name: choice.name,
          application: choice.application, description: choice.description)
      ]
    }
    return NativeContextScopeRequest(
      mode: selection.mode, targets: targets, bounds: bounds,
      topology: ContextTopology.native(displays), exclusions: Self.exclusions(for: selection.mode),
      permission: permission, retention: .noPixels)
  }

  // MARK: Authority

  /// Requests Screen Recording only now, when the chosen operation needs it.
  @discardableResult
  func authorize() -> Bool {
    guard let binding = bindingSource() else {
      report("Context can be added only while recording.")
      return false
    }
    permission = permissionCheck()
    if permission != .granted { permission = permissionRequest() }
    guard permission == .granted else {
      report(
        "Screen Recording permission is off. Turn it on in System Settings › Privacy & Security, then try again. Audio recording is unaffected."
      )
      return false
    }
    do {
      let request = try request(for: selection, permission: permission)
      stopSampling()
      let detail = try binding.preparation.contextAction(
        sessionId: binding.sessionId, action: .authorize(request: request))
      apply(detail)
      report(nil)
      startSampling()
      if selection.mode == .addCurrentWindow { markNow() }
      return true
    } catch {
      report("Context could not be authorized. Nothing is being observed.")
      return false
    }
  }

  func pause() { perform(.pause(reason: .user), stopFirst: true) }

  func resume() {
    permission = permissionCheck()
    perform(.resume(permission: permission), stopFirst: false)
  }

  /// Local work stops before Rust records the revocation (ADR 0011).
  func revoke() { perform(.revoke, stopFirst: true) }

  /// Records this moment explicitly, even when nothing changed.
  func markNow() {
    guard isActive, let request = captureRequest(reason: .userMarked) else { return }
    worker.offer(request)
  }

  private func perform(_ action: NativeContextAction, stopFirst: Bool) {
    guard let binding = bindingSource() else { return }
    if stopFirst { stopSampling() }
    do {
      apply(try binding.preparation.contextAction(sessionId: binding.sessionId, action: action))
      report(nil)
      if isActive { startSampling() }
    } catch {
      report("Open Scribe could not change context in its current state.")
    }
  }

  private func apply(_ detail: NativeContextDetail) {
    self.detail = detail
    relay.set(bindingSource())
    if let scope = current, scope.condition == .active {
      worker.activate(ContextEpochToken(scopeId: scope.scopeId, epoch: scope.epoch))
      topologySignature = ContextTopology.signature(topology())
    }
  }

  private func report(_ text: String?) { message = text }

  func refreshDetail() {
    guard let binding = bindingSource() else { return }
    if let detail = try? binding.preparation.contextDetail(sessionId: binding.sessionId) {
      self.detail = detail
    }
  }

  // MARK: Sampling

  private func startSampling() {
    stopSampling(invalidate: false)
    guard let scope = current, scope.condition == .active else { return }
    consecutiveFailures = 0
    lastAcceptedAt = Date()
    observePlatform()
    switch scope.request.mode {
    case .followPointer:
      dwell.reset()
      let timer = Timer(timeInterval: PointerDwellDetector.sampleInterval, repeats: true) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.samplePointer() }
      }
      RunLoop.main.add(timer, forMode: .common)
      pointerTimer = timer
    case .watchDisplay, .watchWindow, .watchRegion:
      sampler = Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          if let request = self.captureRequest(reason: .fixedScopeChange) {
            self.worker.offer(request)
          }
          // 1 Hz while content changes; 0.2 Hz after 30 s without an accepted change.
          let idle = Date().timeIntervalSince(self.lastAcceptedAt) > 30
          try? await Task.sleep(nanoseconds: idle ? 5_000_000_000 : 1_000_000_000)
        }
      }
    case .addCurrentWindow:
      break
    }
    monitor = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let self, !Task.isCancelled else { return }
        if self.permissionCheck() != .granted { self.stopForPermissionLoss() }
      }
    }
  }

  /// Stops the sampler and, unless told otherwise, invalidates local work.
  private func stopSampling(invalidate: Bool = true) {
    sampler?.cancel()
    sampler = nil
    monitor?.cancel()
    monitor = nil
    pointerTimer?.invalidate()
    pointerTimer = nil
    dwell.reset()
    if invalidate { worker.invalidate() }
  }

  func captureRequest(reason: NativeContextEventReason) -> ContextCaptureRequest? {
    guard let scope = current, scope.condition == .active else { return nil }
    let token = ContextEpochToken(scopeId: scope.scopeId, epoch: scope.epoch)
    let request = scope.request
    switch request.mode {
    case .followPointer:
      guard let window = ContextWindowLocator.window(at: Self.pointerLocation()) else { return nil }
      return ContextCaptureRequest(
        token: token, reason: reason == .userMarked ? .userMarked : .attention,
        target: .window(window.id),
        source: NativeContextSource(
          platformId: String(window.id), name: window.title ?? window.application,
          application: window.application),
        bounds: nil)
    case .watchDisplay, .watchRegion:
      guard let target = request.targets.first, let id = CGDirectDisplayID(target.platformId)
      else { return nil }
      let region = request.bounds.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
      return ContextCaptureRequest(
        token: token, reason: reason, target: .display(id, region: region),
        source: NativeContextSource(platformId: target.platformId, name: target.name, application: nil),
        bounds: request.bounds)
    case .watchWindow, .addCurrentWindow:
      guard let target = request.targets.first, let id = CGWindowID(target.platformId) else {
        return nil
      }
      return ContextCaptureRequest(
        token: token, reason: request.mode == .addCurrentWindow ? .userMarked : reason,
        target: .window(id),
        source: NativeContextSource(
          platformId: target.platformId, name: target.name, application: target.application),
        bounds: nil)
    }
  }

  /// The pointer in global Core Graphics points (top-left origin).
  static func pointerLocation() -> CGPoint {
    let location = NSEvent.mouseLocation
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: location.x, y: primaryHeight - location.y)
  }

  private func samplePointer() {
    guard let scope = current, scope.condition == .active else { return }
    let point = Self.pointerLocation()
    let authorized = Set(scope.request.targets.map(\.platformId))
    let inScope = topology().contains { authorized.contains(String($0.id)) && $0.frame.contains(point) }
    let window = inScope ? ContextWindowLocator.window(at: point) : nil
    let sample = PointerSample(
      time: ProcessInfo.processInfo.systemUptime, point: point,
      surface: window.map { String($0.id) }, inScope: inScope)
    guard dwell.observe(sample) != nil,
      Date().timeIntervalSince(lastPointerCapture) >= 1,
      let request = captureRequest(reason: .attention)
    else { return }
    lastPointerCapture = Date()
    worker.offer(request)
  }

  private func handle(_ outcome: ContextOutcome, for request: ContextCaptureRequest) {
    guard request.token.scopeId == current?.scopeId, request.token.epoch == current?.epoch else {
      return
    }
    lastOutcome = outcome
    switch outcome {
    case .accepted:
      consecutiveFailures = 0
      lastAcceptedAt = Date()
      acceptedPulse += 1
      refreshDetail()
    case .failed:
      consecutiveFailures += 1
      if consecutiveFailures >= 3 && isActive {
        fail(.captureFailed, message: "The observed screen content is no longer available. Context stopped; audio recording continues.")
      }
    case .unchanged, .noText, .rejected:
      consecutiveFailures = 0
    case .invalidated:
      break
    }
  }

  // MARK: Platform signals

  private func observePlatform() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.topologyChanged() } })
    observers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.isActive else { return }
          self.perform(.pause(reason: .screenLocked), stopFirst: true)
          self.report("Context paused while the screen is locked.")
        }
      })
  }

  /// A display change pauses display-dependent scopes; a removed display
  /// they name stops them. A new scope must then be confirmed.
  func topologyChanged() {
    guard let scope = current, isLive,
      [.followPointer, .watchDisplay, .watchRegion].contains(scope.request.mode)
    else { return }
    let displays = topology()
    guard ContextTopology.signature(displays) != topologySignature else { return }
    let present = Set(displays.map { String($0.id) })
    if scope.request.targets.contains(where: { !present.contains($0.platformId) }) {
      fail(.displayRemoved, message: "A watched display was disconnected. Context stopped; audio recording continues.")
    } else if scope.condition == .active {
      perform(.pause(reason: .topologyChanged), stopFirst: true)
      report("The display arrangement changed. Context is paused until you confirm a scope.")
    }
  }

  private func stopForPermissionLoss() {
    fail(.permissionLost, message: "Screen Recording permission was turned off. Context stopped; audio recording continues.")
  }

  private func fail(_ reason: NativeContextFailureReason, message: String) {
    stopSampling()
    guard let binding = bindingSource() else { return }
    if let detail = try? binding.preparation.contextAction(
      sessionId: binding.sessionId, action: .fail(reason: reason))
    {
      self.detail = detail
    }
    report(message)
  }

  /// The recording closed: stop observing. Rust reports the scope as Ended.
  func recordingChanged() {
    if bindingSource() == nil {
      stopSampling()
      relay.set(nil)
      detail = nil
      message = nil
    } else if detail == nil {
      refreshDetail()
    }
  }
}

/// Forwards proposals to the recording writer off the main actor. The model
/// sets the binding on every scope change and clears it when the recording
/// closes, so a closed session is never written.
private final class ProposalRelay: @unchecked Sendable {
  private let lock = NSLock()
  private var binding: ContextBinding?

  func set(_ binding: ContextBinding?) {
    lock.withLock { self.binding = binding }
  }

  func propose(_ proposal: NativeContextProposal) throws -> NativeContextDecision {
    guard let binding = lock.withLock({ binding }) else {
      return .rejected(reason: .notRecording)
    }
    return try binding.preparation.proposeContextEvent(
      sessionId: binding.sessionId, proposal: proposal)
  }
}
