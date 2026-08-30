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
  func installTap(
    bufferSize: AVAudioFrameCount,
    handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
  )
  func start() throws
  func stop()
  func setRouteEventHandler(_ handler: MicrophoneRouteEventHandler?)
}

final class AVAudioEngineMicrophoneBackend: MicrophoneCaptureBackend, @unchecked Sendable {
  private let engine: AVAudioEngine
  private let routeEventLock = NSLock()
  private var routeEventHandler: MicrophoneRouteEventHandler?
  private var configurationObserver: NSObjectProtocol?

  init(engine: AVAudioEngine = AVAudioEngine()) {
    self.engine = engine
  }

  var inputFormat: AVAudioFormat {
    engine.inputNode.outputFormat(forBus: 0)
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
    engine.prepare()
    try engine.start()
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
  private let observationLock = NSLock()
  private var started = false
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

  convenience init(writer: ManagedCAFWriter) {
    self.init(
      backend: AVAudioEngineMicrophoneBackend(),
      writer: writer,
      identity: MicrophoneCaptureIdentity(authorization: writer.authorization)
    )
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
          let writtenFrames = try self.writer.writeCapturedBuffer(copy)
          guard writtenFrames > 0 else { return }
          self.recordWrittenProgress(UInt64(writtenFrames))
          self.stateLock.lock()
          self.lastWrittenSampleHostTime = hostTime
          let shouldReport = self.started && !self.firstSampleReported
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
    started = false
    stateLock.unlock()
    if backendActive {
      backend.stop()
      backendActive = false
    }
    backend.setRouteEventHandler(nil)
    // A writer that passed its last state check before stop is allowed to
    // finish, but stop does not return until every previously queued write has
    // completed. No capture callback waits on this barrier.
    writerQueue.sync {}
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
