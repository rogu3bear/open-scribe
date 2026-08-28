import Foundation

typealias MicrophoneFirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
typealias MicrophoneFailureHandler = @Sendable (MicrophoneCaptureAdapterError) -> Void
typealias SystemAudioFirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
typealias SystemAudioFailureHandler = @Sendable (SystemAudioCaptureAdapterError) -> Void

protocol ManagedSegmentWriting: CapturedAudioWriting {
  var authorization: NativeMediaOpenAuthorization { get }
  func receipt() throws -> NativeMediaOpenReceipt
  func sealSegmentReceipt(finalSampleHostTime: UInt64) throws -> NativeSealSegmentReceipt
}

extension ManagedCAFWriter: ManagedSegmentWriting {}

protocol MicrophoneCapturing: AnyObject, Sendable {
  func start(
    onFirstSample: @escaping MicrophoneFirstSampleHandler,
    onFailure: @escaping MicrophoneFailureHandler
  ) throws
  func stop() -> UInt64?
}

extension MicrophoneCaptureAdapter: MicrophoneCapturing {}

protocol SystemAudioCapturing: AnyObject, Sendable {
  func start(
    onFirstSample: @escaping SystemAudioFirstSampleHandler,
    onFailure: @escaping SystemAudioFailureHandler
  ) async throws
  func stop() async throws -> UInt64?
}

extension SystemAudioCaptureAdapter: SystemAudioCapturing {}

enum LiveMicrophoneRecordingPhase: String, Equatable, Sendable {
  case idle
  case requestingPermission
  case preparing
  case starting
  case capturing
  case stopping
  case saved
  case failed
}

@MainActor
final class LiveMicrophoneRecordingController: NSObject, ObservableObject {
  typealias PreparationFactory = @Sendable () throws -> NativeRecordingPreparationProtocol
  typealias WriterFactory =
    @Sendable (NativeMediaOpenAuthorization) throws
    -> ManagedSegmentWriting
  typealias CaptureFactory = @Sendable (ManagedSegmentWriting) -> MicrophoneCapturing
  typealias SystemCaptureFactory =
    @Sendable (ManagedSegmentWriting) async throws -> SystemAudioCapturing

  @Published private(set) var phase: LiveMicrophoneRecordingPhase = .idle
  @Published private(set) var errorMessage: String?
  @Published private(set) var failureCode: String?
  @Published private(set) var savedPath: String?
  @Published private(set) var savedPaths: [String] = []

  private let permission: MicrophonePermissionProviding
  private let preparationFactory: PreparationFactory
  private let writerFactory: WriterFactory
  private let captureFactory: CaptureFactory
  private let systemCaptureFactory: SystemCaptureFactory?
  private let requiredSources: [NativeMediaSourceKind]

  private var preparation: NativeRecordingPreparationProtocol?
  private var writers: [NativeMediaSourceKind: ManagedSegmentWriting] = [:]
  private var microphoneCapture: MicrophoneCapturing?
  private var systemCapture: SystemAudioCapturing?
  private var sourcesWithFirstSample: Set<NativeMediaSourceKind> = []
  private var activeSessionId: String?

  init(
    permission: MicrophonePermissionProviding,
    preparationFactory: @escaping PreparationFactory,
    writerFactory: @escaping WriterFactory,
    captureFactory: @escaping CaptureFactory,
    requiredSources: [NativeMediaSourceKind] = [.microphone],
    systemCaptureFactory: SystemCaptureFactory? = nil
  ) {
    self.permission = permission
    self.preparationFactory = preparationFactory
    self.writerFactory = writerFactory
    self.captureFactory = captureFactory
    self.requiredSources = requiredSources
    self.systemCaptureFactory = systemCaptureFactory
    super.init()
  }

  override convenience init() {
    let root = try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("Open Scribe", isDirectory: true)
    self.init(managedRoot: root)
  }

  convenience init(managedRoot: URL?) {
    self.init(
      permission: AVFoundationMicrophonePermissionAuthority(),
      preparationFactory: {
        guard let root = managedRoot else {
          throw LiveMicrophoneRecordingError.managedRootUnavailable
        }
        return try NativeRecordingPreparation.open(managedRoot: root.path)
      },
      writerFactory: { try ManagedCAFWriter(authorization: $0) },
      captureFactory: { writer in
        MicrophoneCaptureAdapter(backend: AVAudioEngineMicrophoneBackend(), writer: writer)
      },
      requiredSources: [.microphone, .systemAudio],
      systemCaptureFactory: { writer in
        try await SystemAudioCaptureAdapter.allAuthorizedSystemAudio(writer: writer)
      }
    )
  }

  var isCapturing: Bool {
    phase == .capturing
  }

  var canStart: Bool {
    (phase == .idle || phase == .saved || phase == .failed) && activeSessionId == nil
  }

  var canStop: Bool {
    phase == .starting || phase == .capturing
  }

  var statusText: String {
    switch phase {
    case .idle: "Ready to record microphone + system audio"
    case .requestingPermission: "Requesting microphone access…"
    case .preparing: "Preparing durable recording…"
    case .starting: "Starting microphone + system audio…"
    case .capturing: "Recording microphone + system audio"
    case .stopping: "Securing recording…"
    case .saved: "Audio segment saved"
    case .failed: "Conversation capture failed"
    }
  }

  func start() async {
    guard canStart else { return }
    errorMessage = nil
    failureCode = nil
    savedPath = nil
    savedPaths = []
    activeSessionId = nil
    writers = [:]
    sourcesWithFirstSample = []
    phase = .requestingPermission

    let permissionState = await permission.request()
    guard permissionState == .authorized else {
      await fail(
        "Microphone access is \(permissionState.rawValue). Enable it in System Settings.",
        code: "permission-\(permissionState.rawValue)"
      )
      return
    }

    phase = .preparing
    do {
      let preparation = try preparationFactory()
      let prepared = try preparation.prepareSessionWithRequiredSources(
        title: Self.sessionTitle(),
        requiredSources: requiredSources
      )
      guard prepared.journalDurable, !prepared.recordingStarted else {
        throw LiveMicrophoneRecordingError.invalidPreparation
      }
      self.preparation = preparation
      activeSessionId = prepared.sessionId
      for (index, source) in requiredSources.enumerated() {
        let authorization = try preparation.authorizeInitialMedia(
          sessionId: prepared.sessionId,
          sourceKind: source,
          sourceDisplayName: Self.displayName(for: source)
        )
        let writer = try writerFactory(authorization)
        let mediaOpen = try preparation.acceptMediaOpen(receipt: writer.receipt())
        let allMediaShouldBeOpen = index == requiredSources.count - 1
        guard mediaOpen.journalDurable,
          mediaOpen.mediaFilesOpen == allMediaShouldBeOpen,
          !mediaOpen.recordingStarted
        else {
          throw LiveMicrophoneRecordingError.invalidMediaOpen
        }
        writers[source] = writer
      }

      guard let microphoneWriter = writers[.microphone] else {
        throw LiveMicrophoneRecordingError.invalidSourcePlan
      }
      let microphoneCapture = captureFactory(microphoneWriter)
      self.microphoneCapture = microphoneCapture

      if requiredSources.contains(.systemAudio) {
        guard let systemWriter = writers[.systemAudio], let systemCaptureFactory else {
          throw LiveMicrophoneRecordingError.invalidSourcePlan
        }
        do {
          systemCapture = try await systemCaptureFactory(systemWriter)
        } catch {
          await fail(
            "System audio access or the selected source is unavailable. \(error.localizedDescription)",
            code: "system-audio-unavailable",
            interruptionReason: .captureStartFailed
          )
          return
        }
      }

      phase = .starting
      if let systemCapture {
        try await systemCapture.start(
          onFirstSample: { [weak self] receipt in
            Task { @MainActor [weak self] in
              await self?.acceptFirstSample(receipt, from: .systemAudio)
            }
          },
          onFailure: { [weak self] error in
            Task { @MainActor [weak self] in
              await self?.handleCaptureFailure(
                String(describing: error),
                code: "system-audio-\(String(describing: error))",
                interruptionReason: .captureFailed
              )
            }
          }
        )
      }
      try microphoneCapture.start(
        onFirstSample: { [weak self] receipt in
          Task { @MainActor [weak self] in
            await self?.acceptFirstSample(receipt, from: .microphone)
          }
        },
        onFailure: { [weak self] error in
          Task { @MainActor [weak self] in
            await self?.handleCaptureFailure(
              String(describing: error),
              code: "capture-\(String(describing: error))",
              interruptionReason: .captureFailed
            )
          }
        }
      )
    } catch {
      await fail(
        error.localizedDescription,
        code: Self.failureCode(for: error),
        interruptionReason: .captureStartFailed
      )
    }
  }

  func stop() async {
    guard canStop, let preparation else { return }
    phase = .stopping
    var finalSampleTimes: [NativeMediaSourceKind: UInt64] = [:]
    if let microphoneTime = microphoneCapture?.stop() {
      finalSampleTimes[.microphone] = microphoneTime
    }
    do {
      if let systemTime = try await systemCapture?.stop() {
        finalSampleTimes[.systemAudio] = systemTime
      }
    } catch {
      await fail(
        "System audio could not be stopped safely. Recovery state was preserved.",
        code: "system-audio-stop",
        stopCapture: false,
        interruptionReason: .captureFailed
      )
      return
    }
    guard Set(finalSampleTimes.keys) == Set(requiredSources) else {
      let missingSources = Set(requiredSources).subtracting(finalSampleTimes.keys)
      let message =
        missingSources == [.microphone]
        ? "No microphone sample was durably written. Recovery state was preserved."
        : "A required source produced no durable sample. Recovery state was preserved."
      await fail(
        message,
        code: "no-durable-sample",
        stopCapture: false,
        interruptionReason: .stopWithoutDurableSample
      )
      return
    }
    do {
      for source in requiredSources {
        guard let writer = writers[source], let finalSampleHostTime = finalSampleTimes[source] else {
          throw LiveMicrophoneRecordingError.invalidSourcePlan
        }
        let receipt = try writer.sealSegmentReceipt(finalSampleHostTime: finalSampleHostTime)
        let evidence = try preparation.sealSegment(receipt: receipt)
        guard evidence.segmentSealed, !evidence.recordingStarted else {
          throw LiveMicrophoneRecordingError.invalidSegmentSeal
        }
      }
      savedPaths = requiredSources.compactMap { writers[$0]?.authorization.absolutePath }
      savedPath = savedPaths.first
      resetActiveSession()
      phase = .saved
    } catch {
      await fail(
        error.localizedDescription,
        code: "segment-seal",
        interruptionReason: .segmentSealFailed
      )
    }
  }

  private func acceptFirstSample(
    _ receipt: NativeFirstSampleReceipt,
    from source: NativeMediaSourceKind
  ) async {
    guard phase == .starting else { return }
    guard requiredSources.contains(source), let preparation else { return }
    let evidence: NativeFirstSampleEvidence
    do {
      evidence = try preparation.acceptFirstSample(receipt: receipt)
    } catch {
      await handleCaptureFailure(
        error.localizedDescription,
        code: "first-sample-evidence",
        interruptionReason: .firstSampleRejected
      )
      return
    }
    guard
      evidence.journalDurable, evidence.mediaFilesOpen, evidence.firstSampleDurable,
      !evidence.recordingStarted
    else {
      await handleCaptureFailure(
        LiveMicrophoneRecordingError.invalidFirstSample.localizedDescription,
        code: "first-sample-evidence",
        interruptionReason: .firstSampleRejected
      )
      return
    }
    sourcesWithFirstSample.insert(source)
    guard sourcesWithFirstSample == Set(requiredSources) else { return }
    let recording: NativeRecordingStartedEvidence
    do {
      recording = try preparation.confirmRecording(sessionId: receipt.sessionId)
    } catch {
      await handleCaptureFailure(
        error.localizedDescription,
        code: "recording-authority",
        interruptionReason: .firstSampleRejected
      )
      return
    }
    guard recording.journalDurable, recording.mediaFilesOpen, recording.recordingStarted,
      Set(recording.requiredSources) == Set(requiredSources),
      Set(recording.activeSources) == Set(requiredSources)
    else {
      await handleCaptureFailure(
        LiveMicrophoneRecordingError.invalidRecordingAuthority.localizedDescription,
        code: "recording-authority",
        interruptionReason: .firstSampleRejected
      )
      return
    }
    phase = .capturing
  }

  private func handleCaptureFailure(
    _ message: String,
    code: String,
    interruptionReason: NativeSessionInterruptionReason
  ) async {
    await fail(message, code: code, interruptionReason: interruptionReason)
  }

  private func fail(
    _ message: String,
    code: String,
    stopCapture: Bool = true,
    interruptionReason: NativeSessionInterruptionReason? = nil
  ) async {
    if stopCapture {
      _ = microphoneCapture?.stop()
      _ = try? await systemCapture?.stop()
    }
    var operatorMessage = message
    var interruptionConfirmed = interruptionReason == nil || activeSessionId == nil
    if let interruptionReason, let preparation, let activeSessionId {
      do {
        let evidence = try preparation.interruptSession(
          sessionId: activeSessionId,
          reason: interruptionReason
        )
        interruptionConfirmed =
          evidence.journalDurable && evidence.sessionInterrupted && !evidence.recordingStarted
        if !interruptionConfirmed {
          operatorMessage += " Recovery state could not be confirmed."
        }
      } catch {
        operatorMessage += " Recovery state could not be confirmed."
      }
    }
    if interruptionConfirmed {
      resetActiveSession()
    }
    errorMessage = operatorMessage
    failureCode = code
    phase = .failed
  }

  nonisolated private static func failureCode(for error: Error) -> String {
    if let recordingError = error as? LiveMicrophoneRecordingError {
      return recordingError.failureCode
    }
    if let captureError = error as? MicrophoneCaptureAdapterError {
      return "capture-\(String(describing: captureError))"
    }
    return "capture-start-or-setup"
  }

  nonisolated private static func sessionTitle() -> String {
    "Conversation \(ISO8601DateFormatter().string(from: Date()))"
  }

  nonisolated private static func displayName(for source: NativeMediaSourceKind) -> String {
    switch source {
    case .microphone: "Mac microphone"
    case .applicationAudio: "Selected application audio"
    case .systemAudio: "Mac system audio"
    }
  }

  private func resetActiveSession() {
    preparation = nil
    writers = [:]
    microphoneCapture = nil
    systemCapture = nil
    sourcesWithFirstSample = []
    activeSessionId = nil
  }
}

private enum LiveMicrophoneRecordingError: LocalizedError {
  case invalidPreparation
  case invalidMediaOpen
  case invalidFirstSample
  case invalidRecordingAuthority
  case invalidSegmentSeal
  case invalidSourcePlan
  case managedRootUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidPreparation: "Rust did not confirm durable session preparation."
    case .invalidMediaOpen: "Rust did not confirm durable media-open evidence."
    case .invalidFirstSample: "Rust did not confirm the first microphone sample."
    case .invalidRecordingAuthority: "Rust did not confirm every required recording source."
    case .invalidSegmentSeal: "Rust did not confirm the closed microphone segment."
    case .invalidSourcePlan: "The required recording sources could not be initialized."
    case .managedRootUnavailable: "The managed recording directory is unavailable."
    }
  }

  var failureCode: String {
    switch self {
    case .invalidPreparation: "durable-preparation"
    case .invalidMediaOpen: "media-open-evidence"
    case .invalidFirstSample: "first-sample-evidence"
    case .invalidRecordingAuthority: "recording-authority"
    case .invalidSegmentSeal: "segment-seal"
    case .invalidSourcePlan: "required-source-plan"
    case .managedRootUnavailable: "managed-root"
    }
  }
}
