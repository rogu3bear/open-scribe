@preconcurrency import AVFoundation
import Foundation

enum MicrophoneCaptureAdapterError: Error, Equatable {
  case invalidInputFormat
  case alreadyStarted
  case bufferPoolExhausted
  case bufferCopyFailed
  case missingHostTime
  case writerFailed
}

protocol MicrophoneCaptureBackend: AnyObject, Sendable {
  var inputFormat: AVAudioFormat { get }
  func installTap(
    bufferSize: AVAudioFrameCount,
    handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
  )
  func start() throws
  func stop()
}

final class AVAudioEngineMicrophoneBackend: MicrophoneCaptureBackend, @unchecked Sendable {
  private let engine: AVAudioEngine

  init(engine: AVAudioEngine = AVAudioEngine()) {
    self.engine = engine
  }

  var inputFormat: AVAudioFormat {
    engine.inputNode.inputFormat(forBus: 0)
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
    case invalid
  }

  func copyWithoutWaiting(_ source: AVAudioPCMBuffer) -> CopyResult {
    guard source.frameLength <= frameCapacity else {
      return .invalid
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
      return .invalid
    }
    for index in 0..<sourceList.count {
      let sourceBuffer = sourceList[index]
      var destinationBuffer = destinationList[index]
      guard let sourceData = sourceBuffer.mData,
        let destinationData = destinationBuffer.mData,
        sourceBuffer.mDataByteSize <= destinationBuffer.mDataByteSize
      else {
        recycleWithoutWaiting(destination)
        return .invalid
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
  private static let poolCount = 8

  private let backend: MicrophoneCaptureBackend
  private let writer: CapturedAudioWriting
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
  private var started = false
  private var hasStarted = false
  private var failureReported = false
  private var firstSampleReported = false
  private var backendActive = false

  init(backend: MicrophoneCaptureBackend, writer: CapturedAudioWriting) {
    self.backend = backend
    self.writer = writer
  }

  convenience init(writer: ManagedCAFWriter) {
    self.init(backend: AVAudioEngineMicrophoneBackend(), writer: writer)
  }

  func start(
    onFirstSample: @escaping FirstSampleHandler,
    onFailure: @escaping FailureHandler
  ) throws {
    try lifecycleQueue.sync {
      try startIsolated(onFirstSample: onFirstSample, onFailure: onFailure)
    }
  }

  private func startIsolated(
    onFirstSample: @escaping FirstSampleHandler,
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
        capacity: Self.bufferSize,
        count: Self.poolCount
      )
    else {
      stateLock.unlock()
      throw MicrophoneCaptureAdapterError.bufferCopyFailed
    }
    started = true
    hasStarted = true
    failureReported = false
    firstSampleReported = false
    stateLock.unlock()

    backend.installTap(bufferSize: Self.bufferSize) { [weak self] buffer, time in
      guard let self else { return }
      let copy: AVAudioPCMBuffer
      switch pool.copyWithoutWaiting(buffer) {
      case .copied(let captured):
        copy = captured
      case .exhausted:
        self.reportFailureFromCallback(.bufferPoolExhausted, handler: onFailure)
        return
      case .invalid:
        self.reportFailureFromCallback(.bufferCopyFailed, handler: onFailure)
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
          self.stateLock.lock()
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
          self.reportFailure(.writerFailed, handler: onFailure)
        }
      }
    }
    backendActive = true

    do {
      try backend.start()
    } catch {
      stopIsolated()
      throw error
    }
  }

  func stop() {
    lifecycleQueue.sync {
      stopIsolated()
    }
  }

  private func stopIsolated() {
    stateLock.lock()
    started = false
    stateLock.unlock()
    if backendActive {
      backend.stop()
      backendActive = false
    }
    // A writer that passed its last state check before stop is allowed to
    // finish, but stop does not return until every previously queued write has
    // completed. No capture callback waits on this barrier.
    writerQueue.sync {}
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
