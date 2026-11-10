@preconcurrency import AVFoundation
import Foundation

enum MicrophoneCaptureAdapterError: Error, Equatable {
  case invalidInputFormat
  case alreadyStarted
  case bufferPoolExhausted
  case bufferFrameCapacityExceeded
  case bufferLayoutMismatch
  case bufferByteSizeMismatch
  case missingHostTime
  case writerFailed
  case inputDeviceUnavailable
  case inputDeviceChanged
}

enum MicrophoneRouteEvent: String, Equatable, Sendable {
  case interrupted
  case recovered
}

typealias MicrophoneRouteEventHandler = @Sendable (MicrophoneRouteEvent) -> Void

struct MicrophoneCaptureIdentity: Equatable, Sendable {
  let sessionId: String
  let trackId: String
  let writerGeneration: UInt64

  init(sessionId: String, trackId: String, writerGeneration: UInt64) {
    self.sessionId = sessionId
    self.trackId = trackId
    self.writerGeneration = writerGeneration
  }

  init(authorization: NativeMediaOpenAuthorization) {
    self.init(
      sessionId: authorization.sessionId,
      trackId: authorization.trackId,
      writerGeneration: authorization.writerGeneration
    )
  }

  static func testFixture(generation: UInt64) -> Self {
    Self(
      sessionId: "session-observation",
      trackId: "track-microphone",
      writerGeneration: generation
    )
  }

  fileprivate static let unbound = Self(
    sessionId: "unbound",
    trackId: "unbound",
    writerGeneration: 0
  )
}

enum MicrophoneSourceHealthEvent: String, Equatable, Sendable {
  case progress
  case routeInterrupted = "route_interrupted"
  case routeRecovered = "route_recovered"
  case writerFailed = "writer_failed"
}

struct MicrophoneSourceHealthObservation: Equatable, Sendable {
  let identity: MicrophoneCaptureIdentity
  let sequence: UInt64
  let event: MicrophoneSourceHealthEvent
  let callbackCount: UInt64
  let successfullyWrittenFrameCount: UInt64
  let lastProgressMonotonicNanoseconds: UInt64
}

typealias MicrophoneObservationHandler = @Sendable (MicrophoneSourceHealthObservation) -> Void

protocol MicrophoneCaptureBackend: AnyObject, Sendable {
  var inputFormat: AVAudioFormat { get }
  func bindInput(to device: MicrophoneDeviceIdentity?) throws
  func installTap(
    bufferSize: AVAudioFrameCount,
    handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
  )
  func start() throws
  func stop()
  func setRouteEventHandler(_ handler: MicrophoneRouteEventHandler?)
}

extension MicrophoneCaptureBackend {
  func bindInput(to device: MicrophoneDeviceIdentity?) throws {
    if device != nil { throw MicrophoneCaptureAdapterError.inputDeviceUnavailable }
  }
}

final class AVAudioEngineMicrophoneBackend: MicrophoneCaptureBackend, @unchecked Sendable {
  private let engine: AVAudioEngine
  private let routeEventLock = NSLock()
  private var routeEventHandler: MicrophoneRouteEventHandler?
  private var configurationObserver: NSObjectProtocol?
  private var boundInput: MicrophoneDeviceIdentity?

  init(engine: AVAudioEngine = AVAudioEngine()) {
    self.engine = engine
  }

  var inputFormat: AVAudioFormat {
    engine.inputNode.outputFormat(forBus: 0)
  }

  private var inputBinding: MicrophoneInputBinding {
    MicrophoneInputBinding(
      resolve: CoreAudioInputDevice.resolve,
      select: { [self] in try engine.inputNode.auAudioUnit.setDeviceID($0) },
      selectedUID: { [self] in
        try CoreAudioInputDevice.uniqueID(engine.inputNode.auAudioUnit.deviceID)
      })
  }

  func bindInput(to device: MicrophoneDeviceIdentity?) throws {
    try inputBinding.bind(device)
    boundInput = device
  }

  func installTap(
    bufferSize: AVAudioFrameCount,
    handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
  ) {
    engine.inputNode.installTap(
      onBus: 0,
      bufferSize: bufferSize,
      format: inputFormat,
      block: handler
    )
  }

  func start() throws {
    guard let boundInput else { throw MicrophoneCaptureAdapterError.inputDeviceUnavailable }
    try inputBinding.validate(boundInput)
    engine.prepare()
    try engine.start()
    do { try inputBinding.validate(boundInput) } catch {
      engine.stop()
      throw error
    }
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }

  func setRouteEventHandler(_ handler: MicrophoneRouteEventHandler?) {
    let priorObserver = routeEventLock.withLock { () -> NSObjectProtocol? in
      let priorObserver = configurationObserver
      configurationObserver = nil
      routeEventHandler = handler
      return priorObserver
    }
    if let priorObserver {
      NotificationCenter.default.removeObserver(priorObserver)
    }
    guard handler != nil else { return }
    let observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      let event: MicrophoneRouteEvent = self.engine.isRunning ? .recovered : .interrupted
      let currentHandler = self.routeEventLock.withLock { self.routeEventHandler }
      currentHandler?(event)
    }
    routeEventLock.withLock {
      configurationObserver = observer
    }
  }

  deinit {
    setRouteEventHandler(nil)
  }
}

private final class CaptureBufferPool: @unchecked Sendable {
  private let lock = NSLock()
  private let frameCapacity: AVAudioFrameCount
  private var available: [AVAudioPCMBuffer]

  init?(format: AVAudioFormat, capacity: AVAudioFrameCount, count: Int) {
    frameCapacity = capacity
    var buffers: [AVAudioPCMBuffer] = []
    buffers.reserveCapacity(count)
    for _ in 0..<count {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
        return nil
      }
      buffers.append(buffer)
    }
    available = buffers
  }

  enum CopyResult {
    case copied(AVAudioPCMBuffer)
    case exhausted
    case frameCapacityExceeded
    case layoutMismatch
    case byteSizeMismatch
  }

  func copyWithoutWaiting(_ source: AVAudioPCMBuffer) -> CopyResult {
    guard source.frameLength <= frameCapacity else {
      return .frameCapacityExceeded
    }
    let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    guard lock.try() else { return .exhausted }
    guard let destination = available.popLast() else {
      lock.unlock()
      return .exhausted
    }
    lock.unlock()

    destination.frameLength = source.frameLength
    let destinationList = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
    guard sourceList.count == destinationList.count else {
      recycleWithoutWaiting(destination)
      return .layoutMismatch
    }
    for index in 0..<sourceList.count {
      let sourceBuffer = sourceList[index]
      var destinationBuffer = destinationList[index]
      guard let sourceData = sourceBuffer.mData,
        let destinationData = destinationBuffer.mData,
        sourceBuffer.mDataByteSize <= destinationBuffer.mDataByteSize
      else {
        recycleWithoutWaiting(destination)
        return .byteSizeMismatch
      }
      memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
      destinationBuffer.mDataByteSize = sourceBuffer.mDataByteSize
      destinationList[index] = destinationBuffer
    }
    return .copied(destination)
  }

  func recycle(_ buffer: AVAudioPCMBuffer) {
    buffer.frameLength = 0
    lock.lock()
    available.append(buffer)
    lock.unlock()
  }

  private func recycleWithoutWaiting(_ buffer: AVAudioPCMBuffer) {
    buffer.frameLength = 0
    guard lock.try() else { return }
    available.append(buffer)
    lock.unlock()
  }
}

/// Swift-owned microphone hot path. Buffers are copied into a bounded pool in
/// the AVAudioEngine callback and written on a dedicated serial queue. Only one
/// coarse first-sample receipt leaves Swift.
final class MicrophoneCaptureAdapter: @unchecked Sendable {
  typealias FirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
  typealias FailureHandler = @Sendable (MicrophoneCaptureAdapterError) -> Void

  private static let bufferSize: AVAudioFrameCount = 4_096
  // AVAudioEngine treats the tap buffer size as a request. Hardware and
  // aggregate devices may deliver larger callbacks, so the real-time pool has
  // a separate, bounded capacity while the requested cadence stays small.
  private static let maximumCallbackFrames: AVAudioFrameCount = 16_384
  private static let poolCount = 8

  private let backend: MicrophoneCaptureBackend
  private let writer: CapturedAudioWriting
  private let identity: MicrophoneCaptureIdentity
  private let observationCadenceNanoseconds: UInt64
  private let monotonicClock: @Sendable () -> UInt64
  private let lifecycleQueue = DispatchQueue(label: "app.open-scribe.microphone-lifecycle")
  private let writerQueue = DispatchQueue(
    label: "app.open-scribe.microphone-writer",
    qos: .userInitiated
  )
  private let eventQueue = DispatchQueue(
    label: "app.open-scribe.microphone-events",
    qos: .userInitiated
  )
  private let stateLock = NSLock()
  private let acceptedCallbacks = DispatchGroup()
  private let observationLock = NSLock()
  private var started = false
  private var acceptingCallbacks = false
  private var inputAdmitted = false
  private var hasStarted = false
  private var failureReported = false
  private var firstSampleReported = false
  private var backendActive = false
  private var lastWrittenSampleHostTime: UInt64?
  private var observationHandler: MicrophoneObservationHandler?
  private var observationActive = false
  private var progressObservationPending = false
  private var observationSequence: UInt64 = 0
  private var callbackCount: UInt64 = 0
  private var successfullyWrittenFrameCount: UInt64 = 0
  private var lastProgressMonotonicNanoseconds: UInt64 = 0
  private let provisionalLock = NSLock()
  private var provisionalQueue: ProvisionalDraftQueue?

  init(
    backend: MicrophoneCaptureBackend,
    writer: CapturedAudioWriting,
    identity: MicrophoneCaptureIdentity = .unbound,
    observationCadenceNanoseconds: UInt64 = 1_000_000_000,
    monotonicClock: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    }
  ) {
    self.backend = backend
    self.writer = writer
    self.identity = identity
    self.observationCadenceNanoseconds = observationCadenceNanoseconds
    self.monotonicClock = monotonicClock
  }

  /// Installs admission of sealed provisional windows. `hypothesis` is nil in
  /// the shipped app until a real recognizer supplies text. A nil or empty
  /// hypothesis does not create transcript words. A sealed window whose
  /// accepted frames are all silent is not admitted. The writer queue only
  /// counts accepted frames; the store call runs on the queue's own serial queue.
  func installProvisionalDraftAdmission(
    preparation: NativeRecordingPreparationProtocol,
    hypothesis: ProvisionalHypothesisProvider? = nil,
    originNanoseconds: Int64 = 0,
    windowFrames: UInt64 = ProvisionalDraftQueue.defaultWindowFrames,
    overlapFrames: UInt64 = ProvisionalDraftQueue.defaultOverlapFrames
  ) {
    let queue = ProvisionalDraftQueue(
      preparation: preparation,
      sessionId: identity.sessionId,
      trackId: identity.trackId,
      hypothesis: hypothesis,
      originNanoseconds: originNanoseconds,
      windowFrames: windowFrames,
      overlapFrames: overlapFrames
    )
    provisionalLock.withLock { provisionalQueue = queue }
  }

  func provisionalDraftWindowFrameCount() -> UInt64? {
    provisionalLock.withLock { provisionalQueue?.windowFrames }
  }

  func provisionalDraftOverlapFrameCount() -> UInt64? {
    provisionalLock.withLock { provisionalQueue?.overlapFrames }
  }

  /// Returns after accepted frames have been offered to the provisional queue.
  /// The capture callback never calls this.
  func waitForAcceptedAudio() {
    writerQueue.sync {}
  }

  func waitForProvisionalDraftAdmission() {
    let queue = provisionalLock.withLock { provisionalQueue }
    queue?.waitUntilIdle()
  }

  convenience init(writer: ManagedCAFWriter) {
    self.init(
      backend: AVAudioEngineMicrophoneBackend(),
      writer: writer,
      identity: MicrophoneCaptureIdentity(authorization: writer.authorization)
    )
  }

  func bindInput(to device: MicrophoneDeviceIdentity?) throws {
    try lifecycleQueue.sync {
      guard !hasStarted else { throw MicrophoneCaptureAdapterError.alreadyStarted }
      try backend.bindInput(to: device)
    }
  }

  func start(
    onFirstSample: @escaping FirstSampleHandler,
    onObservation: @escaping MicrophoneObservationHandler = { _ in },
    onFailure: @escaping FailureHandler
  ) throws {
    try lifecycleQueue.sync {
      try startIsolated(
        onFirstSample: onFirstSample,
        onObservation: onObservation,
        onFailure: onFailure
      )
    }
  }

  private func startIsolated(
    onFirstSample: @escaping FirstSampleHandler,
    onObservation: @escaping MicrophoneObservationHandler,
    onFailure: @escaping FailureHandler
  ) throws {
    stateLock.lock()
    guard !hasStarted else {
      stateLock.unlock()
      throw MicrophoneCaptureAdapterError.alreadyStarted
    }
    let format = backend.inputFormat
    guard format.sampleRate > 0, format.channelCount > 0 else {
      stateLock.unlock()
      throw MicrophoneCaptureAdapterError.invalidInputFormat
    }
    guard
      let pool = CaptureBufferPool(
        format: format,
        capacity: Self.maximumCallbackFrames,
        count: Self.poolCount
      )
    else {
      stateLock.unlock()
      throw MicrophoneCaptureAdapterError.bufferLayoutMismatch
    }
    started = true
    acceptingCallbacks = true
    inputAdmitted = false
    hasStarted = true
    failureReported = false
    firstSampleReported = false
    stateLock.unlock()

    observationLock.withLock {
      observationHandler = onObservation
      observationActive = true
      progressObservationPending = false
      observationSequence = 0
      callbackCount = 0
      successfullyWrittenFrameCount = 0
      lastProgressMonotonicNanoseconds = 0
    }
    backend.setRouteEventHandler { [weak self] event in
      self?.recordRouteEvent(event)
    }

    backend.installTap(bufferSize: Self.bufferSize) { [weak self] buffer, time in
      guard let self else { return }
      let accepted = self.stateLock.withLock {
        guard self.acceptingCallbacks, self.inputAdmitted else { return false }
        self.acceptedCallbacks.enter()
        return true
      }
      guard accepted else { return }
      defer { self.acceptedCallbacks.leave() }
      self.recordCallbackProgress()
      let copy: AVAudioPCMBuffer
      switch pool.copyWithoutWaiting(buffer) {
      case .copied(let captured):
        copy = captured
      case .exhausted:
        self.reportFailureFromCallback(.bufferPoolExhausted, handler: onFailure)
        return
      case .frameCapacityExceeded:
        self.reportFailureFromCallback(.bufferFrameCapacityExceeded, handler: onFailure)
        return
      case .layoutMismatch:
        self.reportFailureFromCallback(.bufferLayoutMismatch, handler: onFailure)
        return
      case .byteSizeMismatch:
        self.reportFailureFromCallback(.bufferByteSizeMismatch, handler: onFailure)
        return
      }
      let hostTime = time.isHostTimeValid ? time.hostTime : 0
      self.writerQueue.async { [weak self] in
        guard let self else {
          pool.recycle(copy)
          return
        }
        defer { pool.recycle(copy) }
        guard hostTime > 0 else {
          self.reportFailure(.missingHostTime, handler: onFailure)
          return
        }
        self.stateLock.lock()
        let stillStarted = self.started
        self.stateLock.unlock()
        guard stillStarted else { return }
        do {
          let writtenFrames = try self.writer.writeCapturedBuffer(copy, hostTime: hostTime)
          guard writtenFrames > 0 else { return }
          self.recordWrittenProgress(UInt64(writtenFrames))
          let silent = writtenFrames == copy.frameLength && bufferIsSilent(copy)
          self.noteProvisionalAudio(writtenFrames, silent: silent)
          self.stateLock.lock()
          self.lastWrittenSampleHostTime = hostTime
          let shouldReport = self.started && self.acceptingCallbacks && !self.firstSampleReported
          if shouldReport {
            self.firstSampleReported = true
          }
          self.stateLock.unlock()
          if shouldReport {
            let receipt = try self.writer.firstSampleReceipt(
              hostTime: hostTime,
              frameCount: UInt64(writtenFrames)
            )
            self.eventQueue.async { onFirstSample(receipt) }
          }
        } catch {
          self.recordImmediateObservation(.writerFailed)
          self.reportFailure(.writerFailed, handler: onFailure)
        }
      }
    }
    backendActive = true

    do {
      try backend.start()
      stateLock.withLock { inputAdmitted = true }
    } catch {
      _ = stopIsolated()
      throw error
    }
  }

  func stop() -> UInt64? {
    lifecycleQueue.sync {
      stopIsolated()
    }
  }

  private func stopIsolated() -> UInt64? {
    stateLock.lock()
    acceptingCallbacks = false
    inputAdmitted = false
    stateLock.unlock()
    if backendActive {
      backend.stop()
      backendActive = false
    }
    backend.setRouteEventHandler(nil)
    // Close callback admission first, then preserve every buffer already
    // accepted, including a callback still copying into the bounded pool.
    // Only the lifecycle queue waits; the capture callback never waits here.
    acceptedCallbacks.wait()
    writerQueue.sync {
      stateLock.withLock { started = false }
    }
    stateLock.lock()
    let lastHostTime = lastWrittenSampleHostTime
    stateLock.unlock()
    observationLock.withLock {
      observationActive = false
      progressObservationPending = false
      observationHandler = nil
    }
    return lastHostTime
  }

  private func noteProvisionalAudio(_ writtenFrames: AVAudioFrameCount, silent: Bool) {
    let queue = provisionalLock.withLock { provisionalQueue }
    queue?.accept(writtenFrames: writtenFrames, silent: silent)
  }

  private func recordCallbackProgress() {
    guard observationLock.try() else { return }
    guard observationActive else {
      observationLock.unlock()
      return
    }
    callbackCount &+= 1
    lastProgressMonotonicNanoseconds = monotonicClock()
    let shouldSchedule = !progressObservationPending
    if shouldSchedule {
      progressObservationPending = true
    }
    observationLock.unlock()
    if shouldSchedule {
      scheduleProgressObservation()
    }
  }

  private func recordWrittenProgress(_ frameCount: UInt64) {
    let shouldSchedule = observationLock.withLock { () -> Bool in
      guard observationActive else { return false }
      successfullyWrittenFrameCount &+= frameCount
      lastProgressMonotonicNanoseconds = monotonicClock()
      guard !progressObservationPending else { return false }
      progressObservationPending = true
      return true
    }
    if shouldSchedule {
      scheduleProgressObservation()
    }
  }

  private func scheduleProgressObservation() {
    if observationCadenceNanoseconds == 0 {
      eventQueue.async { [weak self] in
        self?.emitObservation(.progress)
      }
      return
    }
    eventQueue.asyncAfter(
      deadline: .now() + .nanoseconds(Int(observationCadenceNanoseconds))
    ) { [weak self] in
      self?.emitObservation(.progress)
    }
  }

  private func recordRouteEvent(_ event: MicrophoneRouteEvent) {
    let observationEvent: MicrophoneSourceHealthEvent =
      event == .interrupted ? .routeInterrupted : .routeRecovered
    recordImmediateObservation(observationEvent)
  }

  private func recordImmediateObservation(_ event: MicrophoneSourceHealthEvent) {
    eventQueue.async { [weak self] in
      self?.emitObservation(event)
    }
  }

  private func emitObservation(_ event: MicrophoneSourceHealthEvent) {
    let delivery = observationLock.withLock {
      () -> (MicrophoneObservationHandler, MicrophoneSourceHealthObservation)? in
      guard observationActive, let observationHandler else { return nil }
      if event == .progress {
        progressObservationPending = false
      }
      observationSequence &+= 1
      return (
        observationHandler,
        MicrophoneSourceHealthObservation(
          identity: identity,
          sequence: observationSequence,
          event: event,
          callbackCount: callbackCount,
          successfullyWrittenFrameCount: successfullyWrittenFrameCount,
          lastProgressMonotonicNanoseconds: lastProgressMonotonicNanoseconds
        )
      )
    }
    if let (handler, observation) = delivery {
      handler(observation)
    }
  }

  private func reportFailureFromCallback(
    _ failure: MicrophoneCaptureAdapterError,
    handler: @escaping FailureHandler
  ) {
    guard stateLock.try() else {
      writerQueue.async { [weak self] in
        self?.reportFailure(failure, handler: handler)
      }
      return
    }
    let shouldReport = !failureReported
    if shouldReport {
      failureReported = true
      acceptingCallbacks = false
      started = false
    }
    stateLock.unlock()
    if shouldReport {
      scheduleFailure(failure, handler: handler)
    }
  }

  private func reportFailure(
    _ failure: MicrophoneCaptureAdapterError,
    handler: @escaping FailureHandler
  ) {
    stateLock.lock()
    let shouldReport = !failureReported
    if shouldReport {
      failureReported = true
      acceptingCallbacks = false
      started = false
    }
    stateLock.unlock()
    if shouldReport {
      scheduleFailure(failure, handler: handler)
    }
  }

  private func scheduleFailure(
    _ failure: MicrophoneCaptureAdapterError,
    handler: @escaping FailureHandler
  ) {
    lifecycleQueue.async { [weak self, eventQueue] in
      guard let self else { return }
      if self.backendActive {
        self.backend.stop()
        self.backendActive = false
      }
      eventQueue.async { handler(failure) }
    }
  }
}

struct ProvisionalDraftHypothesis: Equatable, Sendable {
  var text: String
  var engine: String
  var engineVersion: String
  var modelId: String
  var modelSha256: String
  var optionsDigest: String
  var reconciliationVersion: String
}

typealias ProvisionalHypothesisProvider = @Sendable (_ startNanoseconds: Int64, _ endNanoseconds: Int64)
  -> ProvisionalDraftHypothesis?

private struct ProvisionalWindow {
  var startFrames: UInt64
  var endFrames: UInt64
}

/// Counts accepted capture frames and admits at most two sealed windows.
/// The writer queue returns after the count. A commit, if the hypothesis has
/// text, happens on `commitQueue`. A third sealed window drops the oldest
/// window that has not started. Dropped audio stays in the capture file. A
/// window whose accepted frames are all silent is not admitted, so the
/// hypothesis cannot invent speech for that interval.
final class ProvisionalDraftQueue: @unchecked Sendable {
  static let captureSampleRate: UInt64 = 48_000
  static let defaultWindowFrames: UInt64 = 576_000
  static let defaultOverlapFrames: UInt64 = 96_000
  static let maximumWindows = 2

  let windowFrames: UInt64
  let overlapFrames: UInt64
  private let hopFrames: UInt64
  private let preparation: NativeRecordingPreparationProtocol
  private let sessionId: String
  private let trackId: String
  private let hypothesisProvider: ProvisionalHypothesisProvider?
  private let originNanoseconds: Int64
  private let commitQueue = DispatchQueue(
    label: "app.open-scribe.microphone-provisional-draft",
    qos: .utility
  )
  private let stateLock = NSLock()
  private var acceptedFrames: UInt64 = 0
  private var nextWindowStartFrames: UInt64 = 0
  private var sampleRuns: [SampleRun] = []
  private var pending: [ProvisionalWindow] = []
  private var inFlight = 0

  init(
    preparation: NativeRecordingPreparationProtocol,
    sessionId: String,
    trackId: String,
    hypothesis: ProvisionalHypothesisProvider?,
    originNanoseconds: Int64,
    windowFrames: UInt64,
    overlapFrames: UInt64
  ) {
    self.preparation = preparation
    self.sessionId = sessionId
    self.trackId = trackId
    self.hypothesisProvider = hypothesis
    self.originNanoseconds = originNanoseconds
    self.windowFrames = windowFrames
    self.overlapFrames = overlapFrames
    self.hopFrames = overlapFrames < windowFrames ? windowFrames - overlapFrames : 0
  }

  static func nanoseconds(forFrames frames: UInt64) -> Int64 {
    let wholeSeconds = frames / captureSampleRate
    let remainder = frames % captureSampleRate
    return Int64(wholeSeconds * 1_000_000_000 + remainder * 1_000_000_000 / captureSampleRate)
  }

  func accept(writtenFrames: AVAudioFrameCount, silent: Bool) {
    guard writtenFrames > 0, hopFrames > 0 else { return }
    let count = UInt64(writtenFrames)
    let start = acceptedFrames
    acceptedFrames += count
    if var last = sampleRuns.last, last.silent == silent, last.endFrames == start {
      last.endFrames = acceptedFrames
      sampleRuns[sampleRuns.count - 1] = last
    } else {
      sampleRuns.append(
        SampleRun(startFrames: start, endFrames: acceptedFrames, silent: silent))
    }
    var sealed: [ProvisionalWindow] = []
    while acceptedFrames >= nextWindowStartFrames + windowFrames {
      let windowStart = nextWindowStartFrames
      let windowEnd = windowStart + windowFrames
      if !windowIsSilent(startFrames: windowStart, endFrames: windowEnd) {
        sealed.append(ProvisionalWindow(startFrames: windowStart, endFrames: windowEnd))
      }
      nextWindowStartFrames += hopFrames
    }
    sampleRuns.removeAll { $0.endFrames <= nextWindowStartFrames }
    guard !sealed.isEmpty else { return }
    schedule(sealed)
  }

  func waitUntilIdle() {
    commitQueue.sync {}
  }

  private func schedule(_ windows: [ProvisionalWindow]) {
    var starting: ProvisionalWindow?
    stateLock.lock()
    pending.append(contentsOf: windows)
    while pending.count + inFlight > Self.maximumWindows {
      pending.removeFirst()
    }
    if inFlight == 0, !pending.isEmpty {
      inFlight = 1
      starting = pending.removeFirst()
    }
    stateLock.unlock()
    if let starting {
      commitQueue.async { [weak self] in
        self?.commit(starting)
      }
    }
  }

  private func commit(_ window: ProvisionalWindow) {
    defer { finishCommit() }
    guard let start = timelineNanoseconds(window.startFrames),
      let end = timelineNanoseconds(window.endFrames),
      end > start,
      let hypothesis = hypothesisProvider?(start, end)
    else { return }
    let text = hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    do {
      _ = try preparation.commitLiveDraftWindow(
        sessionId: sessionId,
        trackId: trackId,
        startNanoseconds: start,
        endNanoseconds: end,
        text: text,
        engine: hypothesis.engine,
        engineVersion: hypothesis.engineVersion,
        modelId: hypothesis.modelId,
        modelSha256: hypothesis.modelSha256,
        optionsDigest: hypothesis.optionsDigest,
        reconciliationVersion: hypothesis.reconciliationVersion
      )
    } catch {
      // The store rejected this window. Capture keeps the audio.
    }
  }

  private func finishCommit() {
    var next: ProvisionalWindow?
    stateLock.lock()
    inFlight = 0
    if !pending.isEmpty {
      inFlight = 1
      next = pending.removeFirst()
    }
    stateLock.unlock()
    if let next {
      commit(next)
    }
  }

  private func timelineNanoseconds(_ frames: UInt64) -> Int64? {
    let (sum, overflow) = originNanoseconds.addingReportingOverflow(
      Self.nanoseconds(forFrames: frames))
    guard !overflow else { return nil }
    return sum
  }

  /// A window is silent only when every accepted frame in it belongs to a
  /// silent run. A gap or any non-silent sample keeps the window admissible.
  private func windowIsSilent(startFrames: UInt64, endFrames: UInt64) -> Bool {
    guard endFrames > startFrames else { return false }
    var cursor = startFrames
    for run in sampleRuns {
      if run.endFrames <= cursor { continue }
      if run.startFrames > cursor { return false }
      if run.startFrames >= endFrames { break }
      if !run.silent { return false }
      cursor = min(run.endFrames, endFrames)
      if cursor >= endFrames { return true }
    }
    return false
  }
}

private struct SampleRun {
  var startFrames: UInt64
  var endFrames: UInt64
  var silent: Bool
}

/// Exact digital silence in the buffer that was written. Any other sample,
/// or a format this scan does not know, stays admissible as speech.
private func bufferIsSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
  let frames = Int(buffer.frameLength)
  guard frames > 0 else { return true }
  let channels = Int(buffer.format.channelCount)
  guard channels > 0 else { return false }
  switch buffer.format.commonFormat {
  case .pcmFormatInt16:
    guard let samples = buffer.int16ChannelData else { return false }
    return pcmSamplesAreSilent(samples, channels: channels, frames: frames, format: buffer.format) {
      $0 == 0
    }
  case .pcmFormatInt32:
    guard let samples = buffer.int32ChannelData else { return false }
    return pcmSamplesAreSilent(samples, channels: channels, frames: frames, format: buffer.format) {
      $0 == 0
    }
  case .pcmFormatFloat32:
    guard let samples = buffer.floatChannelData else { return false }
    return pcmSamplesAreSilent(samples, channels: channels, frames: frames, format: buffer.format) {
      $0 == 0
    }
  default:
    return false
  }
}

private func pcmSamplesAreSilent<Sample>(
  _ samples: UnsafePointer<UnsafeMutablePointer<Sample>>,
  channels: Int,
  frames: Int,
  format: AVAudioFormat,
  isZero: (Sample) -> Bool
) -> Bool {
  if format.isInterleaved {
    let stride = channels
    for frame in 0..<frames {
      for channel in 0..<channels where !isZero(samples[0][frame * stride + channel]) {
        return false
      }
    }
    return true
  }
  for channel in 0..<channels {
    let channelSamples = samples[channel]
    for frame in 0..<frames where !isZero(channelSamples[frame]) {
      return false
    }
  }
  return true
}
