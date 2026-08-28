@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import Foundation

enum SystemAudioCaptureAdapterError: Error, Equatable {
  case noDisplayAvailable
  case alreadyStarted
  case outputRegistrationFailed
  case invalidSampleBuffer
  case writerFailed
}

/// ScreenCaptureKit system-audio hot path. The selected display bounds audio
/// scope to the user's authorized system capture; video output is never added.
/// Audio samples remain in Swift and only coarse media receipts cross UniFFI.
final class SystemAudioCaptureAdapter: NSObject, SCStreamOutput, SCStreamDelegate,
  @unchecked Sendable
{
  typealias FirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
  typealias FailureHandler = @Sendable (SystemAudioCaptureAdapterError) -> Void

  private let writer: CapturedAudioWriting
  private var stream: SCStream!
  private let writerQueue = DispatchQueue(
    label: "app.open-scribe.system-audio-writer",
    qos: .userInitiated
  )
  private let stateLock = NSLock()
  private var started = false
  private var firstSampleReported = false
  private var failureReported = false
  private var lastHostTime: UInt64?
  private var onFirstSample: FirstSampleHandler?
  private var onFailure: FailureHandler?

  private init(writer: CapturedAudioWriting, filter: SCContentFilter) {
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
    try beginStart(onFirstSample: onFirstSample, onFailure: onFailure)
    var outputRegistered = false
    do {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
      outputRegistered = true
      try await stream.startCapture()
    } catch {
      if outputRegistered {
        try? stream.removeStreamOutput(self, type: .audio)
      }
      resetAfterFailedStart()
      throw error
    }
  }

  func stop() async throws -> UInt64? {
    var firstError: Error?
    do {
      try await stream.stopCapture()
    } catch {
      firstError = error
    }
    do {
      try stream.removeStreamOutput(self, type: .audio)
    } catch {
      firstError = firstError ?? error
    }
    let finalHostTime = finishStop()
    if let firstError {
      throw firstError
    }
    return finalHostTime
  }

  private func beginStart(
    onFirstSample: @escaping FirstSampleHandler,
    onFailure: @escaping FailureHandler
  ) throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !started else {
      throw SystemAudioCaptureAdapterError.alreadyStarted
    }
    started = true
    firstSampleReported = false
    failureReported = false
    lastHostTime = nil
    self.onFirstSample = onFirstSample
    self.onFailure = onFailure
  }

  private func resetAfterFailedStart() {
    stateLock.lock()
    defer { stateLock.unlock() }
    started = false
    onFirstSample = nil
    onFailure = nil
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
    do {
      let written = try writer.writeCapturedBuffer(pcm)
      guard written > 0 else { return }
      let presentation = sampleBuffer.presentationTimeStamp
      guard let synchronizationClock = stream.synchronizationClock,
        let hostTime = Self.hostTime(
          from: presentation,
          synchronizationClock: synchronizationClock
        )
      else {
        reportFailure(.invalidSampleBuffer)
        return
      }
      stateLock.lock()
      lastHostTime = hostTime
      let shouldReport = !firstSampleReported
      firstSampleReported = true
      stateLock.unlock()
      if shouldReport {
        onFirstSample?(try writer.firstSampleReceipt(hostTime: hostTime, frameCount: UInt64(written)))
      }
    } catch {
      reportFailure(.writerFailed)
    }
  }

  func stream(_: SCStream, didStopWithError _: Error) {
    reportFailure(.writerFailed)
  }

  private func reportFailure(_ failure: SystemAudioCaptureAdapterError) {
    stateLock.lock()
    guard !failureReported else {
      stateLock.unlock()
      return
    }
    failureReported = true
    let handler = onFailure
    stateLock.unlock()
    handler?(failure)
  }
}
