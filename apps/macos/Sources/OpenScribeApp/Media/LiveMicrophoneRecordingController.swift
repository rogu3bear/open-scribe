import Foundation

typealias MicrophoneFirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
typealias MicrophoneFailureHandler = @Sendable (MicrophoneCaptureAdapterError) -> Void

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

  @Published private(set) var phase: LiveMicrophoneRecordingPhase = .idle
  @Published private(set) var errorMessage: String?
  @Published private(set) var failureCode: String?
  @Published private(set) var savedPath: String?

  private let permission: MicrophonePermissionProviding
  private let preparationFactory: PreparationFactory
  private let writerFactory: WriterFactory
  private let captureFactory: CaptureFactory

  private var preparation: NativeRecordingPreparationProtocol?
  private var writer: ManagedSegmentWriting?
  private var capture: MicrophoneCapturing?
  private var activeSessionId: String?

  init(
    permission: MicrophonePermissionProviding,
    preparationFactory: @escaping PreparationFactory,
    writerFactory: @escaping WriterFactory,
    captureFactory: @escaping CaptureFactory
  ) {
    self.permission = permission
    self.preparationFactory = preparationFactory
    self.writerFactory = writerFactory
    self.captureFactory = captureFactory
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
    case .idle: "Microphone idle"
    case .requestingPermission: "Requesting microphone access…"
    case .preparing: "Preparing durable recording…"
    case .starting: "Starting microphone…"
    case .capturing: "Capturing microphone"
    case .stopping: "Securing recording…"
    case .saved: "Audio segment saved"
    case .failed: "Microphone capture failed"
    }
  }

  func start() async {
    guard canStart else { return }
    errorMessage = nil
    failureCode = nil
    savedPath = nil
    activeSessionId = nil
    phase = .requestingPermission

    let permissionState = await permission.request()
    guard permissionState == .authorized else {
      fail(
        "Microphone access is \(permissionState.rawValue). Enable it in System Settings.",
        code: "permission-\(permissionState.rawValue)"
      )
      return
    }

    phase = .preparing
    do {
      let preparation = try preparationFactory()
      let prepared = try preparation.prepareSession(title: Self.sessionTitle())
      guard prepared.journalDurable, !prepared.recordingStarted else {
        throw LiveMicrophoneRecordingError.invalidPreparation
      }
      self.preparation = preparation
      activeSessionId = prepared.sessionId
      let authorization = try preparation.authorizeInitialMedia(
        sessionId: prepared.sessionId,
        sourceKind: .microphone,
        sourceDisplayName: "Mac microphone"
      )
      let writer = try writerFactory(authorization)
      let mediaOpen = try preparation.acceptMediaOpen(receipt: writer.receipt())
      guard mediaOpen.journalDurable, mediaOpen.mediaFilesOpen, !mediaOpen.recordingStarted else {
        throw LiveMicrophoneRecordingError.invalidMediaOpen
      }
      let capture = captureFactory(writer)
      self.writer = writer
      self.capture = capture
      phase = .starting
      try capture.start(
        onFirstSample: { [weak self, preparation] receipt in
          do {
            let evidence = try preparation.acceptFirstSample(receipt: receipt)
            Task { @MainActor [weak self] in
              self?.acceptFirstSampleEvidence(evidence)
            }
          } catch {
            Task { @MainActor [weak self] in
              self?.handleCaptureFailure(
                error.localizedDescription,
                code: "first-sample-evidence",
                interruptionReason: .firstSampleRejected
              )
            }
          }
        },
        onFailure: { [weak self] error in
          Task { @MainActor [weak self] in
            self?.handleCaptureFailure(
              String(describing: error),
              code: "capture-\(String(describing: error))",
              interruptionReason: .captureFailed
            )
          }
        }
      )
    } catch {
      fail(
        error.localizedDescription,
        code: Self.failureCode(for: error),
        interruptionReason: .captureStartFailed
      )
    }
  }

  func stop() {
    guard canStop, let preparation, let writer, let capture else { return }
    phase = .stopping
    guard let finalSampleHostTime = capture.stop() else {
      fail(
        "No microphone sample was durably written. Recovery state was preserved.",
        code: "no-durable-sample",
        stopCapture: false,
        interruptionReason: .stopWithoutDurableSample
      )
      return
    }
    do {
      let receipt = try writer.sealSegmentReceipt(finalSampleHostTime: finalSampleHostTime)
      let evidence = try preparation.sealSegment(receipt: receipt)
      guard evidence.segmentSealed, !evidence.recordingStarted else {
        throw LiveMicrophoneRecordingError.invalidSegmentSeal
      }
      savedPath = writer.authorization.absolutePath
      self.preparation = nil
      self.writer = nil
      self.capture = nil
      activeSessionId = nil
      phase = .saved
    } catch {
      fail(
        error.localizedDescription,
        code: "segment-seal",
        interruptionReason: .segmentSealFailed
      )
    }
  }

  private func acceptFirstSampleEvidence(_ evidence: NativeFirstSampleEvidence) {
    guard phase == .starting else { return }
    guard evidence.journalDurable, evidence.mediaFilesOpen, evidence.firstSampleDurable else {
      handleCaptureFailure(
        LiveMicrophoneRecordingError.invalidFirstSample.localizedDescription,
        code: "first-sample-evidence",
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
  ) {
    fail(message, code: code, interruptionReason: interruptionReason)
  }

  private func fail(
    _ message: String,
    code: String,
    stopCapture: Bool = true,
    interruptionReason: NativeSessionInterruptionReason? = nil
  ) {
    if stopCapture {
      _ = capture?.stop()
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
      preparation = nil
      writer = nil
      capture = nil
      activeSessionId = nil
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
    "Microphone capture \(ISO8601DateFormatter().string(from: Date()))"
  }
}

private enum LiveMicrophoneRecordingError: LocalizedError {
  case invalidPreparation
  case invalidMediaOpen
  case invalidFirstSample
  case invalidSegmentSeal
  case managedRootUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidPreparation: "Rust did not confirm durable session preparation."
    case .invalidMediaOpen: "Rust did not confirm durable media-open evidence."
    case .invalidFirstSample: "Rust did not confirm the first microphone sample."
    case .invalidSegmentSeal: "Rust did not confirm the closed microphone segment."
    case .managedRootUnavailable: "The managed recording directory is unavailable."
    }
  }

  var failureCode: String {
    switch self {
    case .invalidPreparation: "durable-preparation"
    case .invalidMediaOpen: "media-open-evidence"
    case .invalidFirstSample: "first-sample-evidence"
    case .invalidSegmentSeal: "segment-seal"
    case .managedRootUnavailable: "managed-root"
    }
  }
}
