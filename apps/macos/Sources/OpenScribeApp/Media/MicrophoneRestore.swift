import Foundation

/// The microphone-restore fields of one recording. A restore brings a lost
/// microphone back on a new segment while the other source keeps recording,
/// or as part of resuming a paused recording.
@MainActor
struct MicrophoneRestoreState {
  /// Bounds how long a restored microphone may wait for its first sample.
  let monitor: MicrophoneRestoreMonitor
  /// A different input the person may approve with Use This Microphone.
  var pendingDifferentDevice: MicrophoneDeviceIdentity?
  /// The sealed microphone writer a restore replaces; put back when the
  /// restore never accepts a sample.
  var sealedWriter: ManagedSegmentWriting?
  /// The restored microphone's capture until its first sample is accepted.
  var capture: MicrophoneCapturing?
  var task: Task<Void, Never>?
  var sampleGate: RestoreSampleGate?
  var permissionTask: Task<Void, Never>?
  /// Changes with every restore so a late callback cannot reach a later one.
  var generation = UUID()
  var cancelled = false
  /// Approved device for one paused restore. The next resume consumes it.
  /// Later probes must not read the mutable selection in its place.
  var approvedPausedDevice: MicrophoneDeviceIdentity?
  /// Continuing-source notice held until Rust confirms `.capturing`.
  /// A Starting span must not claim the other source is recording.
  var pendingNotice: RecorderNotice?
  /// Set while an explicit restore has an opening segment and no new sample.
  var segmentOpen = false
  var permissionWithdrawn = false

  init(monitor: MicrophoneRestoreMonitor) {
    self.monitor = monitor
  }

  /// Clears the restore with its session. A running restore keeps its task
  /// and generation so it still recognizes itself when it resumes.
  mutating func endSession() {
    monitor.cancel()
    pendingDifferentDevice = nil
    sealedWriter = nil
    capture = nil
    sampleGate?.resume(false)
    sampleGate = nil
    permissionTask?.cancel()
    permissionTask = nil
    approvedPausedDevice = nil
    pendingNotice = nil
    segmentOpen = false
    permissionWithdrawn = false
    cancelled = false
  }
}

extension LiveMicrophoneRecordingController {
  var showsUseThisMicrophone: Bool {
    showsReconnect && restore.pendingDifferentDevice != nil
  }

  var replacementMicrophoneName: String? {
    guard showsUseThisMicrophone else { return nil }
    let name = restore.pendingDifferentDevice?.localizedName ?? ""
    return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Microphone" : name
  }

  func reconnectMicrophone() {
    beginMicrophoneRestore(approvedDevice: selectedMicrophoneDevice)
  }

  func confirmDifferentMicrophone() {
    guard showsUseThisMicrophone, restore.task == nil,
      let pending = restore.pendingDifferentDevice
    else {
      return
    }
    selectedMicrophoneDevice = pending
    restore.pendingDifferentDevice = nil
    beginMicrophoneRestore(approvedDevice: pending)
  }

  func dismissDifferentMicrophone() {
    restore.pendingDifferentDevice = nil
    notice = nil
    publishRetirementIfNeeded()
  }

  /// A retired microphone is named on every open span, replacing only an
  /// empty notice or the other phase's microphone-stopped notice.
  func publishRetirementIfNeeded() {
    guard phase == .paused || phase == .capturing, isMicrophoneRetired, activeSessionId != nil
    else { return }
    let paused = RecorderNotice.microphoneStopped(.paused)
    let capturing = RecorderNotice.microphoneStopped(continuingRecording)
    if notice == nil || notice == paused || notice == capturing {
      notice = phase == .paused ? paused : capturing
    }
  }

  /// Stop ends any restore before it seals. A first sample the restored writer
  /// already accepted is kept.
  func cancelRestoreForStop() {
    restore.monitor.cancel()
    guard restore.task != nil || restore.segmentOpen else { return }
    restore.cancelled = true
    restore.sampleGate?.resume(false)
    _ = (restore.capture ?? microphoneCapture)?.stop()
    if let writer = writers[.microphone],
      writer.acceptedFirstSampleEvidence(segmentId: writer.authorization.segmentId) != nil,
      let receipt = writer.firstAcceptedReceipt()
    {
      acceptRestoredMicrophoneSample(
        receipt, generation: restore.generation, preservingForStop: true)
    }
  }

  /// Waits for a running restore, then drops one that never accepted a sample.
  func settleRestoreForStop() async {
    if let task = restore.task {
      await task.value
      if restore.task == task { restore.task = nil }
    }
    restore.cancelled = false
    cancelOpenMicrophoneRestore()
  }

  /// A paused restore resumes only on the device the person approved. The
  /// approved identity is fixed for this resume; probe with no further
  /// suspension, because a change is a different choice and must not start
  /// capture. Returns false when the resume must not start the microphone.
  func continueApprovedPausedRestore(
    _ approved: MicrophoneDeviceIdentity, sessionId: String, attempt: UUID
  ) async -> Bool {
    guard activeAttempt == attempt, activeSessionId == sessionId, !restore.cancelled,
      phase == .starting || phase == .capturing
    else {
      if restore.cancelled { cancelOpenMicrophoneRestore() }
      return false
    }
    let observedDevice = environment.microphoneDeviceProbe()
    guard observedDevice?.uniqueID != approved.uniqueID else { return true }
    cancelOpenMicrophoneRestore()
    // Starting has not confirmed the span, so describe resume. Recording
    // already confirmed by Rust keeps the continuing-source sentence.
    let alreadyConfirmed = phase == .capturing
    restore.pendingDifferentDevice = observedDevice
    let continuing: RecorderNotice =
      observedDevice == nil
      ? .microphoneUnavailable(continuingRecording) : .differentMicrophone(continuingRecording)
    if alreadyConfirmed {
      restore.pendingNotice = nil
      notice = continuing
    } else {
      restore.pendingNotice = continuing
      notice =
        observedDevice == nil ? .microphoneUnavailable(.resuming) : .differentMicrophone(.resuming)
    }
    await confirmRecordingIfReady(sessionId: sessionId, attempt: attempt)
    return false
  }

  /// The restored microphone failed before its first sample. The other source
  /// keeps the session; Starting has not confirmed it yet, so the notice
  /// describes resume until Rust does, including when its sample is still
  /// pending. Capturing keeps the live sentence and the confirm no-ops.
  func dropOpenRestore(withdrawn: Bool, failedSessionId: String?, failedAttempt: UUID?) async {
    restore.permissionWithdrawn = withdrawn
    cancelOpenMicrophoneRestore()
    restore.sampleGate?.resume(false)
    if phase == .starting {
      restore.pendingNotice =
        withdrawn
        ? .microphoneAccessWithdrawn(continuingRecording)
        : .microphoneNotRestored(continuingRecording)
      notice = withdrawn ? .microphoneAccessWithdrawn(.resuming) : .microphoneNotRestored(.resuming)
    } else {
      let next = restoreContinuation(continuingRecording)
      notice = withdrawn ? .microphoneAccessWithdrawn(next) : .microphoneNotRestored(next)
    }
    if let failedSessionId, let failedAttempt {
      await confirmRecordingIfReady(sessionId: failedSessionId, attempt: failedAttempt)
    }
  }

  private func beginMicrophoneRestore(approvedDevice: MicrophoneDeviceIdentity?) {
    guard showsReconnect, restore.task == nil else { return }
    let generation = UUID()
    restore.generation = generation
    restore.cancelled = false
    restore.permissionWithdrawn = false
    restore.task = Task { @MainActor in
      await self.performMicrophoneRestore(
        generation: generation, approvedDevice: approvedDevice)
      if self.restore.generation == generation {
        self.restore.task = nil
      }
    }
  }

  /// Permission, device, and free space are decided before any restore journal.
  /// A paused recording reuses resume. A live recording does not restart the
  /// other source. This task never calls `stop()`.
  private func performMicrophoneRestore(
    generation: UUID, approvedDevice: MicrophoneDeviceIdentity?
  ) async {
    guard showsReconnect, let preparation, let sessionId = activeSessionId else { return }
    let permission = environment.permission
    var permissionState = permission.currentState
    if permissionState == .notDetermined {
      notice = .microphoneAccessNeededToRejoin
      permissionState = await permission.request()
      guard restore.generation == generation, !restore.cancelled, showsReconnect else {
        return
      }
    }
    if permissionState == .notDetermined {
      notice = .microphoneAccessNeededToRejoin
      return
    }
    if permissionState == .denied || permissionState == .restricted {
      notice = .microphoneAccessOff(restoreContinuation(continuingRecording))
      return
    }
    guard permissionState == .authorized else {
      notice = .microphoneAccessNeededToRejoin
      return
    }
    let deadline = ContinuousClock.now.advanced(by: MicrophoneRestoreMonitor.timeout)
    guard let currentDevice = environment.microphoneDeviceProbe() else {
      notice = .microphoneUnavailable(restoreContinuation(continuingRecording))
      return
    }
    // Approval belongs to the device offered to the user, even if the default
    // input changes before this task runs or while permission is being granted.
    if let approvedDevice, approvedDevice.uniqueID != currentDevice.uniqueID {
      restore.pendingDifferentDevice = currentDevice
      notice = .differentMicrophone(restoreContinuation(continuingRecording))
      return
    }
    selectedMicrophoneDevice = currentDevice
    do {
      if try !microphoneRestoreHasReserve() {
        notice = .noSpaceToRestoreMicrophone(restoreContinuation(.existingAudioRecording))
        return
      }
    } catch {
      notice = .restoreSpaceUnchecked(restoreContinuation(continuingRecording))
      return
    }
    guard restore.generation == generation, !restore.cancelled, showsReconnect else { return }
    if phase == .capturing { beginRestoreDeadline(sessionId: sessionId, deadline: deadline) }
    do {
      recorderDetail = try preparation.recorderAction(
        sessionId: sessionId, action: .restoreMicrophone)
    } catch {
      restore.monitor.cancel()
      notice = .microphoneNotRestored(restoreContinuation(continuingRecording))
      return
    }
    guard restore.generation == generation, !restore.cancelled else {
      cancelJournaledMicrophoneRestore(sessionId: sessionId, preparation: preparation)
      return
    }
    if phase == .paused {
      guard canResume else {
        cancelJournaledMicrophoneRestore(sessionId: sessionId, preparation: preparation)
        notice = .microphoneNotRestored(restoreContinuation(continuingRecording))
        return
      }
      restore.approvedPausedDevice = currentDevice
      await start(resuming: true)
      return
    }
    await performLiveMicrophoneRestore(
      generation: generation, preparation: preparation, sessionId: sessionId)
  }

  /// A restore at or below Rust's capture reserve returns the space sentence
  /// and does not observe storage or stop the recording.
  private func microphoneRestoreHasReserve() throws -> Bool {
    guard
      let path = (writers.first { $0.key != .microphone }?.value ?? writers.values.first)?
        .authorization.absolutePath
    else { return false }
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    return try environment.availableBytes(directory)
      > NativeCapturePolicy.current.storageReserveBytes
  }

  func beginRestoreDeadline(
    sessionId: String,
    deadline: ContinuousClock.Instant =
      ContinuousClock.now.advanced(by: MicrophoneRestoreMonitor.timeout)
  ) {
    let generation = restore.generation
    restore.monitor.start(deadline: deadline) { [weak self] in
      guard let self, self.restore.generation == generation,
        self.activeSessionId == sessionId, self.restore.segmentOpen,
        !self.restore.cancelled
      else { return }
      await self.handleCaptureFailure(
        .restoreDeadlinePassed,
        code: .microphoneRestoreTimeout, source: .microphone,
        interruptionReason: .captureFailed, expectedRestoreGeneration: generation,
        requiresUnstartedRestore: true)
    }
  }

  private func performLiveMicrophoneRestore(
    generation: UUID,
    preparation: NativeRecordingPreparationProtocol,
    sessionId: String
  ) async {
    let gate = RestoreSampleGate()
    restore.sampleGate = gate
    do {
      let span = span(preparation)
      let authorization = try span.authorize(
        .microphone, sessionId: sessionId, after: nil,
        displayName: Self.displayName(for: .microphone))
      let writer = try span.openWriter(authorization)
      restore.sealedWriter = writers[.microphone]
      writers[.microphone] = writer
      restore.segmentOpen = true
      let identity = MicrophoneCaptureIdentity(authorization: writer.authorization)
      microphoneCaptureIdentity = identity
      acceptedMicrophoneObservationSequence = 0
      microphoneSourceHealth = nil
      let capture = environment.captureFactory(writer)
      restore.capture = capture
      try capture.bindInput(to: selectedMicrophoneDevice)
      try capture.start(
        onFirstSample: { [weak self] receipt in
          Task { @MainActor in
            self?.acceptRestoredMicrophoneSample(receipt, generation: generation)
          }
        },
        onObservation: { [weak self] observation in
          Task { @MainActor in
            guard let self, self.restore.generation == generation,
              self.activeSessionId == sessionId, self.microphoneCaptureIdentity == identity
            else { return }
            await self.acceptMicrophoneObservation(observation)
          }
        },
        onFailure: { [weak self] error in
          Task { @MainActor in
            guard let self, self.restore.generation == generation,
              self.activeSessionId == sessionId, self.microphoneCaptureIdentity == identity
            else { return }
            let withdrawn = self.environment.permission.currentState != .authorized
            await self.handleCaptureFailure(
              .detail(String(describing: error)), code: RecorderFailureCode(error),
              source: .microphone,
              interruptionReason: withdrawn ? .permissionRevoked : .captureFailed,
              expectedMicrophoneIdentity: identity, expectedRestoreGeneration: generation)
          }
        }
      )
      restore.permissionTask = Task { @MainActor in
        while !Task.isCancelled {
          guard self.restore.generation == generation, self.restore.segmentOpen else {
            return
          }
          if self.environment.permission.currentState != .authorized {
            self.restore.permissionWithdrawn = true
            self.restore.sampleGate?.resume(false)
            return
          }
          try? await Task.sleep(for: CaptureWatchers.interval)
        }
      }
      let accepted = await gate.wait()
      restore.permissionTask?.cancel()
      restore.permissionTask = nil
      guard restore.generation == generation, activeSessionId == sessionId, !restore.cancelled
      else {
        return
      }
      if accepted, !failedSources.contains(.microphone) { return }
      finishRejectedMicrophoneRestore(sessionId: sessionId, preparation: preparation)
    } catch {
      restore.permissionTask?.cancel()
      restore.permissionTask = nil
      finishRejectedMicrophoneRestore(sessionId: sessionId, preparation: preparation)
    }
  }

  func acceptRestoredMicrophoneSample(
    _ receipt: NativeFirstSampleReceipt, generation: UUID, preservingForStop: Bool = false
  ) {
    // An older adapter cannot resolve the current attempt's sample gate.
    guard restore.generation == generation else { return }
    guard !restore.cancelled || preservingForStop, restore.segmentOpen, let preparation else {
      restore.sampleGate?.resume(false)
      return
    }
    do {
      let evidence: NativeFirstSampleEvidence
      if let accepted = writers[.microphone]?.acceptedFirstSampleEvidence(
        segmentId: receipt.segmentId)
      {
        evidence = accepted
      } else {
        evidence = try preparation.acceptFirstSample(receipt: receipt)
      }
      guard evidence.journalDurable, evidence.firstSampleDurable else {
        throw LiveMicrophoneRecordingError.invalidFirstSample
      }
      restore.segmentOpen = false
      restore.monitor.cancel()
      failedSources.remove(.microphone)
      sourcesWithFirstSample.insert(.microphone)
      if let capture = restore.capture {
        microphoneCapture = capture
      }
      restore.capture = nil
      restore.pendingDifferentDevice = nil
      notice = nil
      if let activeSessionId {
        _ = try? preparation.confirmRecording(sessionId: activeSessionId)
      }
      if !preservingForStop { beginPermissionWatch() }
      restore.sampleGate?.resume(true)
    } catch {
      restore.sampleGate?.resume(false)
    }
  }

  private func finishRejectedMicrophoneRestore(
    sessionId: String, preparation: NativeRecordingPreparationProtocol
  ) {
    if restore.segmentOpen {
      cancelOpenMicrophoneRestore()
    } else {
      cancelJournaledMicrophoneRestore(sessionId: sessionId, preparation: preparation)
    }
    guard !restore.cancelled else { return }
    let next = restoreContinuation(continuingRecording)
    notice =
      restore.permissionWithdrawn
      ? .microphoneAccessWithdrawn(next) : .microphoneNotRestored(next)
  }

  /// A paused restore opens the microphone's new segment before resume starts
  /// the sources. A refused open retires the microphone for this span.
  func openRestoredMicrophone(
    preparation: NativeRecordingPreparationProtocol,
    sessionId: String,
    previousWriters: [NativeMediaSourceKind: ManagedSegmentWriting]
  ) {
    do {
      let span = span(preparation)
      let authorization = try span.authorize(
        .microphone, sessionId: sessionId, after: nil,
        displayName: Self.displayName(for: .microphone))
      let writer = try span.openWriter(authorization)
      restore.sealedWriter = writers[.microphone] ?? previousWriters[.microphone]
      writers[.microphone] = writer
      restore.segmentOpen = true
    } catch {
      cancelJournaledMicrophoneRestore(sessionId: sessionId, preparation: preparation)
      if let previous = previousWriters[.microphone] { writers[.microphone] = previous }
      failedSources.insert(.microphone)
      // Preparing has not confirmed the surviving source. Describe resume until
      // Rust does. Paused preflight and live capture keep their own sentences.
      if phase == .preparing || phase == .starting {
        restore.pendingNotice = .microphoneNotRestored(continuingRecording)
        notice = .microphoneNotRestored(.resuming)
      } else {
        notice = .microphoneNotRestored(restoreContinuation(continuingRecording))
      }
    }
  }

  func cancelJournaledMicrophoneRestore(
    sessionId: String, preparation: NativeRecordingPreparationProtocol
  ) {
    restore.monitor.cancel()
    restore.segmentOpen = false
    restore.capture = nil
    restore.sealedWriter = nil
    restore.approvedPausedDevice = nil
    failedSources.insert(.microphone)
    if let detail = try? preparation.recorderAction(
      sessionId: sessionId, action: .cancelMicrophoneRestore)
    {
      recorderDetail = detail
    }
  }

  /// Drops a restore that never accepted a sample. Captured microphone audio
  /// stays sealed. Stop calls this before it seals the source that kept going.
  func cancelOpenMicrophoneRestore() {
    restore.monitor.cancel()
    guard restore.segmentOpen else { return }
    restore.segmentOpen = false
    restore.approvedPausedDevice = nil
    _ = restore.capture?.stop()
    restore.capture = nil
    _ = microphoneCapture?.stop()
    microphoneCapture = nil
    if let sealedWriter = restore.sealedWriter {
      writers[.microphone] = sealedWriter
    }
    restore.sealedWriter = nil
    failedSources.insert(.microphone)
    microphoneCaptureIdentity = nil
    guard let preparation, let activeSessionId else { return }
    if let detail = try? preparation.recorderAction(
      sessionId: activeSessionId, action: .cancelMicrophoneRestore)
    {
      recorderDetail = detail
    }
  }
}
