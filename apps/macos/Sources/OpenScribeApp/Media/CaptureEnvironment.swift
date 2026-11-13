@preconcurrency import AVFoundation
import AppKit
import Darwin
import Foundation

/// Everything the recorder takes from the platform: permission, the Rust
/// store, writers, capture sources, the clock, the storage probe and live
/// captions. `production(managedRoot:)` is the shipped set; the injected proof
/// and tests supply their own sources and probes for the same recorder.
@MainActor
struct CaptureEnvironment {
  typealias PreparationFactory = @Sendable () throws -> NativeRecordingPreparationProtocol
  typealias WriterFactory =
    @Sendable (NativeMediaOpenAuthorization) throws -> ManagedSegmentWriting
  typealias SuccessorWriterFactory =
    @Sendable (NativeMediaOpenAuthorization) throws -> ManagedCAFWriter
  typealias CaptureFactory = @Sendable (ManagedSegmentWriting) -> MicrophoneCapturing
  /// Opens the computer-audio source for the selected audio.
  typealias SystemCaptureFactory =
    @Sendable (ManagedSegmentWriting, RecorderCaptureSelection) async throws
    -> SystemAudioCapturing
  typealias CaptureHealthTelemetry = @Sendable (CaptureSourceHealthTelemetryRecord) -> Void

  var permission: MicrophonePermissionProviding
  var preparationFactory: PreparationFactory
  var writerFactory: WriterFactory
  var captureFactory: CaptureFactory
  var requiredSources: [NativeMediaSourceKind]
  var systemCaptureFactory: SystemCaptureFactory?
  /// Shipped capture always rotates segments; only test doubles that model a
  /// single file turn it off.
  var segmentedCapture: Bool
  var hostTime: @Sendable () -> UInt64
  var availableBytes: @Sendable (String) throws -> UInt64
  var successorWriterFactory: SuccessorWriterFactory
  var observer: RecordingObserver?
  var captureHealthTelemetry: CaptureHealthTelemetry
  var microphoneDeviceProbe: @MainActor () -> MicrophoneDeviceIdentity?
  var restoreTimeoutWait: MicrophoneRestoreMonitor.Wait
  var screenCaptureAuthorized: @MainActor () -> Bool
  /// No recording or import begins while this holds; the app passes the
  /// launch-recovery scan.
  var isLaunchRecoveryPending: @MainActor () -> Bool
  var liveCaptions: LiveCaptionModel

  init(
    permission: MicrophonePermissionProviding,
    preparationFactory: @escaping PreparationFactory,
    writerFactory: @escaping WriterFactory,
    captureFactory: @escaping CaptureFactory,
    requiredSources: [NativeMediaSourceKind] = [.microphone],
    systemCaptureFactory: SystemCaptureFactory? = nil,
    segmentedCapture: Bool = false,
    hostTime: @escaping @Sendable () -> UInt64 = { mach_absolute_time() },
    availableBytes: @escaping @Sendable (String) throws -> UInt64 = {
      try RecorderStorage.availableBytes(at: $0)
    },
    successorWriterFactory: @escaping SuccessorWriterFactory = {
      try ManagedCAFWriter(authorization: $0)
    },
    observer: RecordingObserver? = nil,
    captureHealthTelemetry: @escaping CaptureHealthTelemetry = {
      AppTelemetry.captureSourceHealth($0)
    },
    microphoneDeviceProbe: @escaping @MainActor () -> MicrophoneDeviceIdentity? = { nil },
    restoreTimeoutWait: @escaping MicrophoneRestoreMonitor.Wait = {
      try await MicrophoneRestoreMonitor.waitForTimeout($0)
    },
    screenCaptureAuthorized: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
    isLaunchRecoveryPending: @escaping @MainActor () -> Bool = { false },
    liveCaptions: LiveCaptionModel = LiveCaptionModel()
  ) {
    self.permission = permission
    self.preparationFactory = preparationFactory
    self.writerFactory = writerFactory
    self.captureFactory = captureFactory
    self.requiredSources = requiredSources
    self.systemCaptureFactory = systemCaptureFactory
    self.segmentedCapture = segmentedCapture
    self.hostTime = hostTime
    self.availableBytes = availableBytes
    self.successorWriterFactory = successorWriterFactory
    self.observer = observer
    self.captureHealthTelemetry = captureHealthTelemetry
    self.microphoneDeviceProbe = microphoneDeviceProbe
    self.restoreTimeoutWait = restoreTimeoutWait
    self.screenCaptureAuthorized = screenCaptureAuthorized
    self.isLaunchRecoveryPending = isLaunchRecoveryPending
    self.liveCaptions = liveCaptions
  }

  /// The Mac's microphone and computer audio, recorded into `managedRoot`.
  static func production(
    managedRoot: URL?,
    isLaunchRecoveryPending: @escaping @MainActor () -> Bool = { false },
    liveCaptions: LiveCaptionModel = LiveCaptionModel()
  ) -> CaptureEnvironment {
    CaptureEnvironment(
      permission: AVFoundationMicrophonePermissionAuthority(),
      preparationFactory: {
        guard let root = managedRoot else {
          throw LiveMicrophoneRecordingError.managedRootUnavailable
        }
        return try NativeRecordingPreparation.open(managedRoot: root.path)
      },
      writerFactory: { try ManagedCAFWriter(authorization: $0) },
      captureFactory: { writer in
        MicrophoneCaptureAdapter(
          backend: AVAudioEngineMicrophoneBackend(),
          writer: writer,
          identity: MicrophoneCaptureIdentity(authorization: writer.authorization)
        )
      },
      requiredSources: [.microphone, .systemAudio],
      systemCaptureFactory: { writer, selection in
        if let filter = selection.filter {
          return SystemAudioCaptureAdapter(writer: writer, filter: filter)
        }
        guard selection.kind == .systemAudio else {
          throw LiveMicrophoneRecordingError.invalidSourcePlan
        }
        return try await SystemAudioCaptureAdapter.allAuthorizedSystemAudio(writer: writer)
      },
      segmentedCapture: true,
      microphoneDeviceProbe: { MicrophoneDeviceProbe.currentInput() },
      isLaunchRecoveryPending: isLaunchRecoveryPending,
      liveCaptions: liveCaptions
    )
  }
}
