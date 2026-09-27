@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

enum SystemAudioCaptureAdapterError: Error, Equatable {
  case noDisplayAvailable
  case alreadyStarted
  case outputRegistrationFailed
  case invalidSampleBuffer
  case writerFailed
  case streamStopped
  case userStopped
  case permissionDenied
}

/// The same adapter and writer queue are exercised without opening a device in tests.
protocol SystemAudioStreamControlling: AnyObject {
  var synchronizationClock: CMClock? { get }
  func addStreamOutput(
    _ output: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue?
  ) throws
  func removeStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType) throws
  func startCapture() async throws
  func stopCapture() async throws
}

extension SCStream: SystemAudioStreamControlling {}

/// ScreenCaptureKit system-audio hot path. The selected display bounds audio
/// scope to the user's authorized system capture; video output is never added.
/// Audio samples remain in Swift and only coarse media receipts cross UniFFI.
final class SystemAudioCaptureAdapter: NSObject, SCStreamOutput, SCStreamDelegate,
  @unchecked Sendable
{
  typealias FirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
  typealias FailureHandler = @Sendable (SystemAudioCaptureAdapterError) -> Void

  private let writer: CapturedAudioWriting
  private var stream: SystemAudioStreamControlling!
  private let writerQueue = DispatchQueue(
    label: "app.open-scribe.system-audio-writer",
    qos: .userInitiated
  )
  private let stateLock = NSLock()
  private var started = false
  private var hasStarted = false
  private var stopping = false
  private var startTask: Task<Void, Error>?
  private var stopTask: Task<UInt64?, Error>?
  private var firstSampleReported = false
  private var failureReported = false
  private var lastHostTime: UInt64?
  private var onFirstSample: FirstSampleHandler?
  private var onFailure: FailureHandler?

  init(writer: CapturedAudioWriting, filter: SCContentFilter) {
    self.writer = writer
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
    configuration.queueDepth = 1
    configuration.capturesAudio = true
    configuration.sampleRate = 48_000
    configuration.channelCount = 1
    configuration.excludesCurrentProcessAudio = true
    super.init()
    stream = SCStream(filter: filter, configuration: configuration, delegate: self)
  }

  init(writer: CapturedAudioWriting, stream: SystemAudioStreamControlling) {
    self.writer = writer
    self.stream = stream
    super.init()
  }

  static func allAuthorizedSystemAudio(writer: CapturedAudioWriting) async throws
    -> SystemAudioCaptureAdapter
  {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    guard let display = content.displays.first else {
      throw SystemAudioCaptureAdapterError.noDisplayAvailable
    }
    let filter = SCContentFilter(
      display: display,
      excludingApplications: [],
      exceptingWindows: []
    )
    return SystemAudioCaptureAdapter(writer: writer, filter: filter)
  }

  nonisolated static func hostTime(
    from presentationTime: CMTime,
    synchronizationClock: CMClockOrTimebase
  ) -> UInt64? {
    guard presentationTime.isValid, presentationTime.isNumeric else { return nil }
    let hostTime = CMSyncConvertTime(
      presentationTime,
      from: synchronizationClock,
      to: CMClockGetHostTimeClock()
    )
    guard hostTime.isValid, hostTime.isNumeric, hostTime >= .zero else { return nil }
    return CMClockConvertHostTimeToSystemUnits(hostTime)
  }

  nonisolated static func sampleFailure(
    for sampleBuffer: CMSampleBuffer,
    type: SCStreamOutputType
  ) -> SystemAudioCaptureAdapterError? {
    guard type == .audio else { return nil }
    return sampleBuffer.isValid ? nil : .invalidSampleBuffer
  }

  func start(
    onFirstSample: @escaping FirstSampleHandler,
    onFailure: @escaping FailureHandler
  ) async throws {
    let task = try beginStart(onFirstSample: onFirstSample, onFailure: onFailure)
    try await task.value
  }

  private func startStream() async throws {
    var outputRegistered = false
    do {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
      outputRegistered = true
      try await stream.startCapture()
    } catch {
      if outputRegistered {
        try? stream.removeStreamOutput(self, type: .audio)
      }
      _ = await drainAndFinishStop()
      throw error
    }
  }

  func stop() async throws -> UInt64? {
    let task = stateLock.withLock { () -> Task<UInt64?, Error> in
      if let stopTask { return stopTask }
      stopping = true
      let task = Task { try await self.stopAndDrain() }
      stopTask = task
      return task
    }
    return try await task.value
  }

  private func stopAndDrain() async throws -> UInt64? {
    let startup = stateLock.withLock { startTask }
    if let startup {
      do { try await startup.value } catch { return nil }
    }
    guard stateLock.withLock({ started }) else { return nil }
    var firstError: Error?
    do {
      try await stream.stopCapture()
    } catch {
      // A delegate-reported loss can leave the stream already stopped. Detach
      // output and drain accepted writes before reporting its final sample.
      let native = error as NSError
      if native.domain != SCStreamErrorDomain
        || native.code != SCStreamError.attemptToStopStreamState.rawValue
      {
        firstError = error
      }
    }
    do {
      try stream.removeStreamOutput(self, type: .audio)
    } catch {
      firstError = firstError ?? error
    }
    let finalHostTime = await drainAndFinishStop()
    if let firstError {
      throw firstError
    }
    return finalHostTime
  }

  private func beginStart(
    onFirstSample: @escaping FirstSampleHandler,
    onFailure: @escaping FailureHandler
  ) throws -> Task<Void, Error> {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !hasStarted, !stopping else {
      throw SystemAudioCaptureAdapterError.alreadyStarted
    }
    started = true
    hasStarted = true
    firstSampleReported = false
    failureReported = false
    lastHostTime = nil
    self.onFirstSample = onFirstSample
    self.onFailure = onFailure
    let task = Task { try await self.startStream() }
    startTask = task
    return task
  }

  private func drainAndFinishStop() async -> UInt64? {
    await withCheckedContinuation { continuation in
      // ScreenCaptureKit delivers on this serial queue. Closing admission here
      // preserves preceding writes and prevents late callbacks after sealing.
      writerQueue.async {
        continuation.resume(returning: self.finishStop())
      }
    }
  }

  private func finishStop() -> UInt64? {
    stateLock.lock()
    defer { stateLock.unlock() }
    started = false
    onFirstSample = nil
    onFailure = nil
    return lastHostTime
  }

  func stream(
    _: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    consume(sampleBuffer, type: type)
  }

  func consume(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
    guard stateLock.withLock({ started && !failureReported }) else { return }
    guard type == .audio else { return }
    if let failure = Self.sampleFailure(for: sampleBuffer, type: type) {
      reportFailure(failure)
      return
    }
    guard sampleBuffer.numSamples > 0 else { return }
    guard let description = sampleBuffer.formatDescription else {
      reportFailure(.invalidSampleBuffer)
      return
    }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    var retainedBlockBuffer: CMBlockBuffer?
    var bufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
    )
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: &bufferList,
      bufferListSize: MemoryLayout<AudioBufferList>.size,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      blockBufferOut: &retainedBlockBuffer
    )
    guard status == noErr,
      let pcm = AVAudioPCMBuffer(
        pcmFormat: format,
        bufferListNoCopy: &bufferList,
        deallocator: nil
      )
    else {
      reportFailure(.invalidSampleBuffer)
      return
    }
    pcm.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
    guard let synchronizationClock = stream.synchronizationClock,
      let hostTime = Self.hostTime(
        from: sampleBuffer.presentationTimeStamp,
        synchronizationClock: synchronizationClock
      )
    else {
      reportFailure(.invalidSampleBuffer)
      return
    }
    do {
      let written = try withExtendedLifetime(retainedBlockBuffer) {
        try writer.writeCapturedBuffer(pcm, hostTime: hostTime)
      }
      guard written > 0 else { return }
      stateLock.lock()
      lastHostTime = hostTime
      let shouldReport = !firstSampleReported
      firstSampleReported = true
      let handler = onFirstSample
      stateLock.unlock()
      if shouldReport {
        handler?(try writer.firstSampleReceipt(hostTime: hostTime, frameCount: UInt64(written)))
      }
    } catch {
      reportFailure(.writerFailed)
    }
  }

  func stream(_: SCStream, didStopWithError error: Error) {
    handleStreamStopped(error)
  }

  func handleStreamStopped(_ error: Error) {
    let native = error as NSError
    let failure: SystemAudioCaptureAdapterError
    if native.domain == SCStreamErrorDomain,
      native.code == SCStreamError.userStopped.rawValue
    {
      failure = .userStopped
    } else if native.domain == SCStreamErrorDomain,
      native.code == SCStreamError.userDeclined.rawValue
    {
      failure = .permissionDenied
    } else {
      failure = .streamStopped
    }
    writerQueue.async { self.reportFailure(failure) }
  }

  private func reportFailure(_ failure: SystemAudioCaptureAdapterError) {
    stateLock.lock()
    guard started, !stopping, !failureReported else {
      stateLock.unlock()
      return
    }
    failureReported = true
    let handler = onFailure
    stateLock.unlock()
    handler?(failure)
  }
}
