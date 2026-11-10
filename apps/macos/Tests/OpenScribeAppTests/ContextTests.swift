import AVFoundation
import AppKit
import SwiftUI
import XCTest

@testable import OpenScribeApp

/// A recording session with a calibrated clock and one open microphone
/// segment: the smallest state in which Rust accepts context.
private struct RecordingFixture {
  let root: URL
  let preparation: NativeRecordingPreparation
  let sessionId: String
  let writer: SegmentedCAFWriter

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    let session = try preparation.prepareSessionWithRequiredSources(
      title: "Context fixture", requiredSources: [.microphone])
    sessionId = session.sessionId
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let anchor = mach_absolute_time()
    try preparation.anchorCaptureClock(
      sessionId: sessionId, hostAnchor: anchor, numerator: timebase.numer,
      denominator: timebase.denom)
    let authorization = try preparation.authorizeInitialMedia(
      sessionId: sessionId, sourceKind: .microphone, sourceDisplayName: "Fixture microphone")
    let file = try ManagedCAFWriter(authorization: authorization)
    _ = try preparation.acceptMediaOpen(receipt: file.receipt())
    writer = SegmentedCAFWriter(current: file, preparation: preparation)
    _ = try writer.writeCapturedBuffer(
      TimelineRuntimeProof.buffer(frames: 480, value: 0), hostTime: anchor)
    _ = try preparation.confirmRecording(sessionId: sessionId)
  }

  var binding: ContextBinding { ContextBinding(preparation: preparation, sessionId: sessionId) }

  static let displays = [
    ContextDisplay(
      id: 1, name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
      scale: 2, rotation: 0, isMain: true),
    ContextDisplay(
      id: 2, name: "Studio Display", frame: CGRect(x: 1512, y: -300, width: 2560, height: 1440),
      scale: 2, rotation: 0, isMain: false),
  ]

  func windowScope() -> NativeContextScopeRequest {
    NativeContextScopeRequest(
      mode: .watchWindow,
      targets: [
        NativeContextTarget(
          kind: .window, platformId: "4242", name: "Plan", application: "Preview",
          description: "Preview — Plan on Built-in Display")
      ],
      bounds: nil, topology: ContextTopology.native(Self.displays),
      exclusions: ContextScopeModel.exclusions(for: .watchWindow), permission: .granted,
      retention: .noPixels)
  }
}

/// Serves prepared frames and counts OCR, optionally holding a capture open.
private final class FrameScript: ContextFrameCapturing, @unchecked Sendable {
  private let lock = NSLock()
  var frames: [CGImage] = []
  var delay: UInt64 = 0
  private(set) var recognitions = 0
  private var captures = 0

  var captureCount: Int { lock.withLock { captures } }

  func enqueue(_ images: [CGImage]) {
    lock.withLock { frames.append(contentsOf: images) }
  }

  func captureFrame(_ target: ContextCaptureTarget) async throws -> CGImage {
    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
    return try lock.withLock {
      captures += 1
      guard !frames.isEmpty else { throw ContextCaptureError.noFrame }
      return frames.removeFirst()
    }
  }

  func recognize(_ image: CGImage) throws -> [NativeContextTextBlock] {
    lock.withLock { recognitions += 1 }
    return try ContextReducer.recognize(image)
  }
}

/// Renders text as a screen would show it.
private func frame(_ lines: [String], noise: UInt8 = 0, size: CGSize = CGSize(width: 1280, height: 720))
  -> CGImage
{
  let context = CGContext(
    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let gray = 1 - CGFloat(noise) / 255
  context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
  context.fill(CGRect(origin: .zero, size: size))
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  for (index, line) in lines.enumerated() {
    NSAttributedString(
      string: line,
      attributes: [.font: NSFont.systemFont(ofSize: 56, weight: .semibold), .foregroundColor: NSColor.black]
    ).draw(at: CGPoint(x: 80, y: size.height - 160 - CGFloat(index) * 110))
  }
  NSGraphicsContext.restoreGraphicsState()
  return context.makeImage()!
}

@MainActor
final class ContextTests: XCTestCase {

  func testConversationDetailsDoNotImplyScreenContextHistory() {
    let declaration = NativeSessionDeclaration(participants: ["Dana"], topic: "Planning")
    XCTAssertFalse(ContextEventsSection.hasHistory(nil))
    XCTAssertFalse(
      ContextEventsSection.hasHistory(
        NativeContextDetail(scopes: [], acceptedEvents: 0, declaration: declaration)))
    XCTAssertTrue(
      ContextEventsSection.hasHistory(
        NativeContextDetail(scopes: [], acceptedEvents: 1, declaration: declaration)))
  }
  // MARK: Topology

  /// Four displays: negative origins, one above, one rotated at mixed scale.
  func testFourDisplayTopologyIsNamedByPositionAndChangesAreDetected() {
    let displays = [
      ContextDisplay(id: 10, name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, rotation: 0, isMain: true),
      ContextDisplay(id: 11, name: "DELL U2720Q", frame: CGRect(x: -2560, y: -200, width: 2560, height: 1440), scale: 1, rotation: 0, isMain: false),
      ContextDisplay(id: 12, name: "DELL U2720Q", frame: CGRect(x: 1512, y: -500, width: 1440, height: 2560), scale: 1, rotation: 90, isMain: false),
      ContextDisplay(id: 13, name: "Studio Display", frame: CGRect(x: -200, y: -1440, width: 2560, height: 1440), scale: 2, rotation: 0, isMain: false),
    ]
    let names = ContextTopology.uniqueNames(displays)
    XCTAssertEqual(names[11], "DELL U2720Q")
    XCTAssertEqual(names[12], "DELL U2720Q (2)")
    XCTAssertEqual(ContextTopology.describe(displays[0], in: displays), "Built-in Display, below Studio Display")
    XCTAssertEqual(ContextTopology.describe(displays[1], in: displays), "DELL U2720Q, left of Built-in Display")
    XCTAssertEqual(ContextTopology.describe(displays[2], in: displays), "DELL U2720Q (2), right of Built-in Display")
    XCTAssertEqual(ContextTopology.describe(displays[3], in: displays), "Studio Display, above Built-in Display")
    XCTAssertEqual(ContextTopology.describe(displays[0], in: [displays[0]]), "Built-in Display")
    let native = ContextTopology.native(displays)
    XCTAssertEqual(native.map(\.x), [0, -2560, 1512, -200])
    XCTAssertEqual(native[2].rotation, 90)

    let signature = ContextTopology.signature(displays)
    var moved = displays
    moved[2] = ContextDisplay(id: 12, name: "DELL U2720Q", frame: CGRect(x: 1512, y: 0, width: 1440, height: 2560), scale: 1, rotation: 90, isMain: false)
    XCTAssertNotEqual(ContextTopology.signature(moved), signature)
    XCTAssertEqual(ContextTopology.signature(displays.reversed()), signature)
  }

  // MARK: Follow Pointer

  private func samples(
    from start: CGPoint, velocity: CGVector, seconds: Double, surface: String? = "w1",
    inScope: Bool = true, startTime: TimeInterval = 0
  ) -> [PointerSample] {
    stride(from: 0.0, through: seconds, by: PointerDwellDetector.sampleInterval).map { time in
      PointerSample(
        time: startTime + time,
        point: CGPoint(x: start.x + velocity.dx * time, y: start.y + velocity.dy * time),
        surface: surface, inScope: inScope)
    }
  }

  func testFollowPointerIgnoresTransitAndAcceptsOnlyARestedPointer() {
    var detector = PointerDwellDetector()
    // Fast transit across the screen (1,200 pt/s) never produces a candidate.
    XCTAssertTrue(samples(from: .zero, velocity: CGVector(dx: 1_200, dy: 0), seconds: 2).compactMap { detector.observe($0) }.isEmpty)
    // A brief 400 ms pause does not either.
    detector.reset()
    XCTAssertTrue(samples(from: CGPoint(x: 50, y: 50), velocity: .zero, seconds: 0.4).compactMap { detector.observe($0) }.isEmpty)
    // Slow drift within 16 points for 700 ms yields exactly one candidate.
    detector.reset()
    let rested = samples(from: CGPoint(x: 100, y: 100), velocity: CGVector(dx: 10, dy: 5), seconds: 0.7)
      .compactMap { detector.observe($0) }
    XCTAssertEqual(rested.count, 1)
    XCTAssertEqual(rested.first?.surface, "w1")
    // Leaving scope, a filtered surface, or a new surface restarts the dwell.
    detector.reset()
    let interrupted =
      samples(from: .zero, velocity: .zero, seconds: 0.4)
      + samples(from: .zero, velocity: .zero, seconds: 0.1, inScope: false, startTime: 0.43)
      + samples(from: .zero, velocity: .zero, seconds: 0.4, startTime: 0.56)
    XCTAssertTrue(interrupted.compactMap { detector.observe($0) }.isEmpty)
    detector.reset()
    let switched =
      samples(from: .zero, velocity: .zero, seconds: 0.4)
      + samples(from: .zero, velocity: .zero, seconds: 0.4, surface: "w2", startTime: 0.43)
    XCTAssertTrue(switched.compactMap { detector.observe($0) }.isEmpty)
    detector.reset()
    XCTAssertTrue(samples(from: .zero, velocity: .zero, seconds: 1, surface: nil).compactMap { detector.observe($0) }.isEmpty)
  }

  // MARK: Reduction

  func testUnchangedFramesSkipOCRAndChangedTextIsRecognizedLocally() throws {
    let first = try ContextReducer.fingerprint(frame(["Quarterly revenue 42"]))
    XCTAssertEqual(first.luma.count, ContextFingerprint.width * ContextFingerprint.height)
    XCTAssertFalse(ContextReducer.changed(try ContextReducer.fingerprint(frame(["Quarterly revenue 42"])), from: first))
    // A one-level background shift stays below the threshold.
    XCTAssertFalse(ContextReducer.changed(try ContextReducer.fingerprint(frame(["Quarterly revenue 42"], noise: 1)), from: first))
    XCTAssertTrue(ContextReducer.changed(try ContextReducer.fingerprint(frame(["Hiring plan", "Owner: Dana"])), from: first))
    XCTAssertTrue(ContextReducer.changed(first, from: nil))

    let blocks = try ContextReducer.recognize(frame(["Quarterly revenue 42", "Owner: Dana"]))
    let text = blocks.map(\.text).joined(separator: " ")
    XCTAssertTrue(text.contains("Quarterly revenue 42"), text)
    XCTAssertTrue(text.contains("Dana"), text)
    for block in blocks {
      XCTAssertGreaterThanOrEqual(block.x, 0)
      XCTAssertLessThanOrEqual(block.y + block.height, 1.000_001)
    }
    // Top-left origin: the first line sits above the second.
    XCTAssertLessThan(blocks[0].y, blocks[blocks.count - 1].y)
    XCTAssertTrue(try ContextReducer.recognize(frame([])).isEmpty)
  }

  // MARK: Worker and Rust authority

  func testTheWorkerProposesOnlyChangedTextAndRustDecidesEveryOutcome() async throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let script = FrameScript()
    let worker = ContextWorker(
      frames: script,
      propose: { try fixture.preparation.proposeContextEvent(sessionId: fixture.sessionId, proposal: $0) },
      recognize: { try script.recognize($0) })
    let detail = try fixture.preparation.contextAction(
      sessionId: fixture.sessionId, action: .authorize(request: fixture.windowScope()))
    let scope = try XCTUnwrap(detail.scopes.last)
    let token = ContextEpochToken(scopeId: scope.scopeId, epoch: scope.epoch)
    worker.activate(token)
    func request(_ reason: NativeContextEventReason = .fixedScopeChange) -> ContextCaptureRequest {
      ContextCaptureRequest(
        token: token, reason: reason, target: .window(4242),
        source: NativeContextSource(platformId: "4242", name: "Plan", application: "Preview"),
        bounds: nil)
    }

    script.frames = [
      frame(["Quarterly revenue 42"]), frame(["Quarterly revenue 42"]),
      frame(["Quarterly revenue 42"], noise: 40), frame([]), frame(["Hiring plan"]),
      frame(["Hiring plan"]),
    ]
    guard case .accepted = await worker.process(request()) else { return XCTFail("first reading") }
    let unchanged = await worker.process(request())
    XCTAssertEqual(unchanged, .unchanged)
    XCTAssertEqual(script.recognitions, 1, "an unchanged frame runs no OCR")
    // A visual change with the same text reaches Rust and is suppressed there.
    let duplicate = await worker.process(request())
    XCTAssertEqual(duplicate, .rejected(.duplicate))
    let textless = await worker.process(request())
    XCTAssertEqual(textless, .noText)
    let changed = await worker.process(request())
    guard case .accepted = changed else { return XCTFail("changed text: \(changed)") }
    // The user may mark an unchanged moment explicitly.
    guard case .accepted = await worker.process(request(.userMarked)) else { return XCTFail("mark") }

    // Revocation during a slow capture: the frame is discarded locally.
    script.frames = [frame(["Revoked during capture"])]
    script.delay = 300_000_000
    async let raced = worker.process(request())
    try await Task.sleep(nanoseconds: 50_000_000)
    worker.invalidate()
    _ = try fixture.preparation.contextAction(sessionId: fixture.sessionId, action: .revoke)
    let racedOutcome = await raced
    XCTAssertEqual(racedOutcome, .invalidated)
    // Even a proposal that bypassed the local token is refused by Rust.
    let late = NativeContextProposal(
      scopeId: scope.scopeId, epoch: scope.epoch, reason: .fixedScopeChange,
      startHostTime: mach_absolute_time(), endHostTime: mach_absolute_time(),
      observedAtMs: 0, source: request().source, bounds: nil,
      reducerRevision: ContextReducer.revision, visionRevision: ContextReducer.visionRevision,
      languages: ["en-US"],
      blocks: [NativeContextTextBlock(text: "Late", x: 0.1, y: 0.1, width: 0.2, height: 0.1)])
    XCTAssertEqual(
      try fixture.preparation.proposeContextEvent(sessionId: fixture.sessionId, proposal: late),
      .rejected(reason: .revoked))

    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let events = try library.contextEvents(sessionId: fixture.sessionId)
    XCTAssertEqual(events.count, 3)
    XCTAssertTrue(events[0].text.contains("Quarterly revenue 42"))
    XCTAssertEqual(events[2].reason, .userMarked)
    XCTAssertTrue(events.allSatisfy { $0.retention == "no_pixels" })
    XCTAssertEqual(try library.contextDetail(sessionId: fixture.sessionId).scopes.last?.condition, .revoked)
    // Default retention: no image file exists anywhere in the managed root.
    let images = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { ["png", "jpg", "jpeg", "heic", "tiff", "bmp", "gif"].contains($0.pathExtension.lowercased()) }
    XCTAssertEqual(images ?? [], [])
    withExtendedLifetime(fixture.writer) {}
  }

  func testTheCandidateSlotHoldsOneAndCountsWhatItDrops() async throws {
    let script = FrameScript()
    script.delay = 200_000_000
    script.frames = (0..<4).map { frame(["Frame \($0)"]) }
    let proposals = ProposalCounter()
    let worker = ContextWorker(
      frames: script, propose: { _ in proposals.increment(); return .rejected(reason: .duplicate) },
      recognize: { _ in [NativeContextTextBlock(text: "x", x: 0, y: 0, width: 0.5, height: 0.5)] })
    let token = ContextEpochToken(scopeId: "s", epoch: 1)
    worker.activate(token)
    let request = ContextCaptureRequest(
      token: token, reason: .fixedScopeChange, target: .window(1),
      source: NativeContextSource(platformId: "1", name: "W", application: nil), bounds: nil)
    // The first request is taken at once; while its capture is held, three
    // more arrive and only the newest survives in the one slot.
    worker.offer(request)
    try await Task.sleep(nanoseconds: 50_000_000)
    for _ in 0..<3 { worker.offer(request) }
    // Another epoch's work is not admitted at all.
    worker.offer(ContextCaptureRequest(token: ContextEpochToken(scopeId: "s", epoch: 2), reason: .fixedScopeChange, target: .window(1), source: request.source, bounds: nil))
    for _ in 0..<40 where !worker.isIdle { try await Task.sleep(nanoseconds: 50_000_000) }
    XCTAssertTrue(worker.isIdle)
    XCTAssertEqual(worker.droppedCandidates, 2)
    XCTAssertEqual(proposals.count, 2)
  }

  /// Opt-in: reads one real frame of the main display in memory through the
  /// exact filter, reduces it, and reports only sizes and counts. It never
  /// prompts: it runs only when permission was already granted.
  func testALiveOneFrameCaptureReducesWithoutRetainingPixels() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["OPEN_SCRIBE_CONTEXT_LIVE_CAPTURE"] == "1",
      "set OPEN_SCRIBE_CONTEXT_LIVE_CAPTURE=1 to read one real frame")
    try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Screen Recording is not granted")
    let display = CGMainDisplayID()
    let source = ScreenContextFrameSource()
    let image = try await source.captureFrame(.display(display, region: nil))
    XCTAssertGreaterThan(image.width, 0)
    let region = try await source.captureFrame(
      .display(display, region: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
    XCTAssertLessThan(region.width, image.width)
    let fingerprint = try ContextReducer.fingerprint(image)
    let blocks = try ContextReducer.recognize(image)
    print("CONTEXT_LIVE_CAPTURE width=\(image.width) height=\(image.height) region=\(region.width)x\(region.height) blocks=\(blocks.count) luma=\(fingerprint.luma.count)")
  }

  func testSavedContextNavigatesOnlyThroughResolvedEvidence() async throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scope = try XCTUnwrap(
      fixture.preparation.contextAction(
        sessionId: fixture.sessionId, action: .authorize(request: fixture.windowScope())
      ).scopes.last)
    let host = mach_absolute_time()
    let decision = try fixture.preparation.proposeContextEvent(
      sessionId: fixture.sessionId,
      proposal: NativeContextProposal(
        scopeId: scope.scopeId, epoch: scope.epoch, reason: .userMarked, startHostTime: host,
        endHostTime: host, observedAtMs: 0,
        source: NativeContextSource(platformId: "4242", name: "Plan", application: "Preview"),
        bounds: nil, reducerRevision: ContextReducer.revision,
        visionRevision: ContextReducer.visionRevision, languages: ["en-US"],
        blocks: [NativeContextTextBlock(text: "Agenda", x: 0.1, y: 0.1, width: 0.3, height: 0.1)]))
    guard case .accepted(let eventId, let startNs, _, _) = decision else {
      return XCTFail("\(decision)")
    }
    // Saved review reads a saved conversation: recover it as a relaunch would.
    let recovered = try fixture.preparation.recoverPlayableSessions()
    XCTAssertTrue(recovered.contains { $0.sessionId == fixture.sessionId })
    let model = TranscriptLibraryModel(managedRoot: fixture.root)
    await model.load(sessionId: fixture.sessionId)
    let event = try XCTUnwrap(model.contextEvents.first, model.message ?? "")
    XCTAssertEqual(model.contextDetail?.scopes.last?.condition, .ended)
    XCTAssertEqual(event.eventId, eventId)
    let evidenceStart = await model.contextEvidenceStart(event)
    XCTAssertEqual(evidenceStart, startNs)

    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let reference = try library.citeContextEvent(
      sessionId: fixture.sessionId, eventId: eventId, block: 0)
    let resolved = try library.resolveEvidence(referenceJson: reference)
    XCTAssertEqual(resolved.state, .available)
    XCTAssertEqual(resolved.kind, "context_event")
    XCTAssertEqual(resolved.text, "Agenda")
    let newer = reference.replacingOccurrences(
      of: "open-scribe.evidence-ref/v1", with: "open-scribe.evidence-ref/v2")
    XCTAssertNotEqual(newer, reference)
    XCTAssertEqual(try library.resolveEvidence(referenceJson: newer).state, .unsupportedVersion)
    XCTAssertThrowsError(try library.resolveEvidence(referenceJson: "{}"))
    XCTAssertEqual(
      TranscriptLibraryModel.evidenceProblem(.integrityMismatch),
      "This evidence no longer matches what was recorded.")
    withExtendedLifetime(fixture.writer) {}
  }

  // MARK: Scope model

  func testTheModelAsksForPermissionOnlyToAuthorizeAndStopsOnPlatformSignals() async throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let permission = ScreenPermissionStub()
    var requests = 0
    var displays = RecordingFixture.displays
    let model = ContextScopeModel(
      binding: { fixture.binding }, frames: FrameScript(), recognize: { _ in [] },
      permissionCheck: { permission.current },
      permissionRequest: { requests += 1; return permission.current },
      topology: { displays })
    await model.refreshChoices()
    XCTAssertEqual(requests, 0, "listing choices never prompts")
    XCTAssertTrue(model.windowsNeedPermission)
    XCTAssertEqual(model.choices.map(\.description), [
      "Built-in Display, left of Studio Display", "Studio Display, right of Built-in Display",
    ])
    model.selection = ContextSelection(mode: .watchDisplay, choiceId: "display-2")
    XCTAssertFalse(model.authorize())
    XCTAssertEqual(requests, 1)
    XCTAssertNil(model.current)
    XCTAssertNotNil(model.message)

    permission.grant()
    XCTAssertTrue(model.authorize())
    XCTAssertEqual(model.current?.condition, .active)
    XCTAssertEqual(model.current?.request.targets.first?.description, "Studio Display, right of Built-in Display")
    model.pause()
    XCTAssertEqual(model.current?.condition, .paused)
    model.resume()
    XCTAssertEqual(model.current?.epoch, 2)

    // A moved display pauses the scope until a new one is confirmed.
    displays[1] = ContextDisplay(id: 2, name: "Studio Display", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), scale: 2, rotation: 0, isMain: false)
    model.topologyChanged()
    XCTAssertEqual(model.current?.condition, .paused)
    XCTAssertEqual(model.current?.reason, "topology_changed")
    model.resume()
    XCTAssertEqual(model.current?.condition, .paused, "a topology pause cannot simply resume")
    // Confirming a scope again issues a new epoch; removing its display stops it.
    XCTAssertTrue(model.authorize())
    XCTAssertEqual(model.current?.epoch, 3)
    displays.removeLast()
    model.topologyChanged()
    XCTAssertEqual(model.current?.condition, .failed)
    XCTAssertEqual(model.current?.reason, "display_removed")
    XCTAssertFalse(model.isLive)
    // The recording itself was never touched.
    XCTAssertEqual(try fixture.preparation.recorderDetail(sessionId: fixture.sessionId).lifecycle, "recording")
    withExtendedLifetime(fixture.writer) {}
  }

  /// The live permission watch and a paused Resume both record permission loss.
  /// Audio recording stays open.
  func testLiveScreenPermissionLossStopsContextAndLeavesTheRecording() async throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let permission = ScreenPermissionStub()
    permission.grant()
    let model = ContextScopeModel(
      binding: { fixture.binding }, frames: FrameScript(), recognize: { _ in [] },
      permissionCheck: { permission.current },
      permissionRequest: { permission.current },
      topology: { RecordingFixture.displays })
    model.selection = ContextSelection(mode: .followPointer)
    XCTAssertTrue(model.authorize())
    XCTAssertEqual(model.current?.condition, .active)

    permission.set(.denied)
    let deadline = Date().addingTimeInterval(4)
    while model.current?.reason != "permission_lost", Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(model.current?.condition, .failed)
    XCTAssertEqual(model.current?.reason, "permission_lost")
    XCTAssertEqual(
      model.message,
      "Screen Recording permission was turned off. Context stopped; audio recording continues.")
    XCTAssertEqual(model.permission, .denied)
    XCTAssertEqual(
      try fixture.preparation.recorderDetail(sessionId: fixture.sessionId).lifecycle, "recording")

    permission.grant()
    XCTAssertTrue(model.authorize())
    model.pause()
    XCTAssertEqual(model.current?.condition, .paused)
    permission.set(.denied)
    model.resume()
    XCTAssertEqual(model.current?.condition, .failed)
    XCTAssertEqual(model.current?.reason, "permission_lost")
    XCTAssertEqual(
      model.message,
      "Screen Recording permission was turned off. Context stopped; audio recording continues.")
    XCTAssertEqual(
      try fixture.preparation.recorderDetail(sessionId: fixture.sessionId).lifecycle, "recording")
    withExtendedLifetime(fixture.writer) {}
  }

  func testDeclaredParticipantsAndTopicGrantNoScope() throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ContextScopeModel(binding: { fixture.binding }, permissionCheck: { .granted })
    XCTAssertTrue(model.declare(participants: "Dana, Sam", topic: "Quarterly plan"))
    XCTAssertEqual(model.detail?.declaration.participants, ["Dana", "Sam"])
    XCTAssertEqual(model.detail?.declaration.topic, "Quarterly plan")
    XCTAssertTrue(model.detail?.scopes.isEmpty ?? false)
    withExtendedLifetime(fixture.writer) {}
  }

  // MARK: Presentation

  /// Renders the context surfaces through AppKit (controls included) for
  /// inspection when OPEN_SCRIBE_RENDER_DIR is set. Only fixture displays
  /// and text appear; no real window is listed.
  func testContextSurfacesRenderForInspection() async throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let permission = ScreenPermissionStub()
    let model = ContextScopeModel(
      binding: { fixture.binding }, frames: FrameScript(), recognize: { _ in [] },
      permissionCheck: { permission.current }, permissionRequest: { permission.current },
      topology: { RecordingFixture.displays })
    let off = ContextInspector(
      model: ContextScopeModel(binding: { fixture.binding }, permissionCheck: { .denied }))
    let preflight = ContextScopeModel(
      binding: { fixture.binding }, frames: FrameScript(), recognize: { _ in [] },
      permissionCheck: { .denied }, permissionRequest: { .denied },
      topology: { RecordingFixture.displays })
    await preflight.refreshChoices()
    preflight.selection = ContextSelection(
      mode: .watchRegion, choiceId: "display-2", region: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4))
    let sheet = ContextScopeSheet(model: preflight, dismiss: {})
    await model.refreshChoices()
    permission.grant()
    model.selection = ContextSelection(mode: .watchDisplay, choiceId: "display-2")
    XCTAssertTrue(model.authorize())
    model.overlay.hide()
    let events = [
      NativeContextEvent(
        eventId: "e1", scopeId: "s", epoch: 1, startNs: 65_000_000_000, endNs: 65_100_000_000,
        observedAtMs: 0, reason: .fixedScopeChange, sourceName: "Studio Display", application: nil,
        text: "Q3 plan\nOwner: Dana", blockCount: 2, semanticHash: "h", retention: "no_pixels"),
      NativeContextEvent(
        eventId: "e2", scopeId: "s", epoch: 1, startNs: 130_000_000_000, endNs: 130_100_000_000,
        observedAtMs: 0, reason: .userMarked, sourceName: "Studio Display", application: nil,
        text: "", blockCount: 0, semanticHash: "h2", retention: "no_pixels"),
    ]
    let review = ScrollView {
      ContextEventsSection(detail: model.detail, events: events)
    }.frame(height: 360)
    let longText = Array(
      repeating: "Résumé — 契約の確認 — مراجعة المحادثة. Preserve the complete recorded context 📝.",
      count: 24).joined(separator: "\n")
    let longEvent = NativeContextEvent(
      eventId: "long-text", scopeId: "s", epoch: 1, startNs: 0, endNs: 1,
      observedAtMs: 0, reason: .fixedScopeChange, sourceName: "Fixture document", application: nil,
      text: longText, blockCount: 24, semanticHash: "fixture-long", retention: "no_pixels")
    // Measure the production row, not a lazy container's estimated first pass.
    let measured = NSHostingView(
      rootView: ContextEventRow(event: longEvent, canSeek: false, onSeek: { _ in })
        .frame(width: 312))
    XCTAssertGreaterThan(measured.fittingSize.height, 500, "long context remains fully readable")
    let longReview = ScrollView {
      ContextEventsSection(detail: model.detail, events: [longEvent])
    }.frame(height: measured.fittingSize.height + 240)
    let manyEvents = (0..<1_000).map { index in
      NativeContextEvent(
        eventId: "event-\(index)", scopeId: "s", epoch: 1,
        startNs: Int64(index) * 1_000_000_000, endNs: Int64(index + 1) * 1_000_000_000,
        observedAtMs: 0, reason: .fixedScopeChange, sourceName: "Fixture document", application: nil,
        text: "Event \(index)", blockCount: 1, semanticHash: "fixture-\(index)", retention: "no_pixels")
    }
    let manyReview = ScrollView {
      ContextEventsSection(detail: model.detail, events: manyEvents)
    }.frame(height: 400)
    guard let directory = ProcessInfo.processInfo.environment["OPEN_SCRIBE_RENDER_DIR"] else { return }
    func render<V: View>(_ name: String, _ view: V, width: CGFloat) throws {
      let host = NSHostingView(rootView: view.padding(24).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
      host.frame = CGRect(origin: .zero, size: host.fittingSize)
      let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
    try render("context-inspector-active", ContextInspector(model: model), width: 560)
    try render("context-inspector-off", off, width: 560)
    try render("context-preflight-region", sheet, width: 600)
    try render("context-saved-review", review, width: 760)
    try render("context-long-review", longReview, width: 360)
    try render("context-large-history", manyReview, width: 760)
    withExtendedLifetime(fixture.writer) {}
  }

  func testPerimeterStylesMatchTheOverlayContract() {
    let expected: [(ContextOverlayState, PerimeterStyle)] = [
      (.eligible, PerimeterStyle(lineWidth: 1, opacity: 0.10, bloomRadius: 0, bloomOpacity: 0, keyline: false)),
      (.hover, PerimeterStyle(lineWidth: 1, opacity: 0.55, bloomRadius: 8, bloomOpacity: 0.20, keyline: false)),
      (.selected, PerimeterStyle(lineWidth: 2, opacity: 0.70, bloomRadius: 12, bloomOpacity: 0.25, keyline: false)),
      (.active, PerimeterStyle(lineWidth: 2, opacity: 0.90, bloomRadius: 16, bloomOpacity: 0.35, keyline: false)),
      (.paused, PerimeterStyle(lineWidth: 1, opacity: 0.30, bloomRadius: 0, bloomOpacity: 0, keyline: false)),
    ]
    for (state, style) in expected {
      XCTAssertEqual(PerimeterStyle.style(for: state, increaseContrast: false), style, "\(state)")
      XCTAssertEqual(
        PerimeterStyle.style(for: state, increaseContrast: true),
        PerimeterStyle(lineWidth: 2, opacity: 1, bloomRadius: 0, bloomOpacity: 0, keyline: true))
    }
    XCTAssertEqual(PerimeterStyle.transition(reduceMotion: false).luminance, 0.16)
    XCTAssertEqual(PerimeterStyle.transition(reduceMotion: true).luminance, 0.1)
    XCTAssertEqual(ContextOverlayController.cocoaFrame(CGRect(x: 10, y: 20, width: 100, height: 50)).width, 100)
  }

  /// The perimeter view draws its boundary. The window stays unordered, and
  /// this does not call `ContextOverlayController.show`.
  @MainActor
  func testRenderedPerimeterMeasuresTheBoundaryWithoutShowingAPanel() throws {
    let dark = NSColor(calibratedWhite: 0, alpha: 1)
    let light = NSColor(calibratedWhite: 1, alpha: 1)
    let eligible = try renderPerimeter(
      state: .eligible, increaseContrast: false, reduceMotion: false, wallpaper: dark,
      appearance: .darkAqua)
    let active = try renderPerimeter(
      state: .active, increaseContrast: false, reduceMotion: false, wallpaper: dark,
      appearance: .darkAqua)
    let activeReduced = try renderPerimeter(
      state: .active, increaseContrast: false, reduceMotion: true, wallpaper: dark,
      appearance: .darkAqua)
    let lightPlain = try renderPerimeter(
      state: .selected, increaseContrast: false, reduceMotion: false, wallpaper: light,
      appearance: .aqua)
    let lightContrast = try renderPerimeter(
      state: .selected, increaseContrast: true, reduceMotion: true, wallpaper: light,
      appearance: .aqua)

    let eligiblePeak = peakLuminance(eligible.bitmap)
    let activePeak = peakLuminance(active.bitmap)
    XCTAssertGreaterThan(
      activePeak - eligiblePeak, 0.4,
      "eligible=\(eligiblePeak) active=\(activePeak)")
    XCTAssertLessThan(eligible.center, 0.05, "the open interior stays the dark wallpaper")
    XCTAssertLessThan(active.center, 0.05, "the open interior stays the dark wallpaper")
    XCTAssertEqual(peakLuminance(activeReduced.bitmap), activePeak, accuracy: 0.05)
    XCTAssertGreaterThan(
      lightPlain.darkest, 0.85, "a white perimeter on a light wallpaper adds no dark keyline")
    XCTAssertLessThan(
      lightContrast.darkest, 0.25, "Increase Contrast draws the black outer keyline")
    XCTAssertGreaterThan(lightContrast.brightest, 0.9)
    for sample in [eligible, active, activeReduced, lightPlain, lightContrast] {
      XCTAssertFalse(sample.windowWasVisible)
      XCTAssertFalse(sample.accessibilityElement)
      XCTAssertNil(sample.hit)
    }
  }

  private struct RenderedPerimeterSample {
    let bitmap: NSBitmapImageRep
    let center: CGFloat
    let brightest: CGFloat
    let darkest: CGFloat
    let windowWasVisible: Bool
    let accessibilityElement: Bool
    let hit: NSView?
  }

  @MainActor
  private func renderPerimeter(
    state: ContextOverlayState,
    increaseContrast: Bool,
    reduceMotion: Bool,
    wallpaper: NSColor,
    appearance: NSAppearance.Name
  ) throws -> RenderedPerimeterSample {
    let size = NSSize(width: 200, height: 140)
    let view = PerimeterView(frame: NSRect(origin: .zero, size: size))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    defer { window.close() }
    let background = NSView(frame: NSRect(origin: .zero, size: size))
    background.wantsLayer = true
    background.layer?.backgroundColor = wallpaper.cgColor
    window.contentView = background
    background.addSubview(view)
    view.frame = background.bounds
    view.apply(state, increaseContrast: increaseContrast, reduceMotion: reduceMotion)
    background.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    removeLayerAnimations(view.layer)
    let visible = window.isVisible
    let hit = view.hitTest(NSPoint(x: size.width / 2, y: size.height / 2))
    let element = view.isAccessibilityElement()
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    let image = try XCTUnwrap(bitmap)
    NSGraphicsContext.saveGraphicsState()
    let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: image))
    NSGraphicsContext.current = graphics
    graphics.cgContext.setFillColor(wallpaper.cgColor)
    graphics.cgContext.fill(CGRect(origin: .zero, size: size))
    view.layer?.render(in: graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return RenderedPerimeterSample(
      bitmap: image,
      center: luminance(image, x: Int(size.width / 2), y: Int(size.height / 2)),
      brightest: peakLuminance(image),
      darkest: floorLuminance(image),
      windowWasVisible: visible,
      accessibilityElement: element,
      hit: hit)
  }

  private func removeLayerAnimations(_ layer: CALayer?) {
    guard let layer else { return }
    layer.removeAllAnimations()
    layer.sublayers?.forEach(removeLayerAnimations)
  }

  private func luminance(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
    return (color.redComponent + color.greenComponent + color.blueComponent) / 3
  }

  private func peakLuminance(_ bitmap: NSBitmapImageRep) -> CGFloat {
    var peak: CGFloat = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        peak = max(peak, luminance(bitmap, x: x, y: y))
      }
    }
    return peak
  }

  private func floorLuminance(_ bitmap: NSBitmapImageRep) -> CGFloat {
    var floor: CGFloat = 1
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        floor = min(floor, luminance(bitmap, x: x, y: y))
      }
    }
    return floor
  }

  /// The words and shortcuts the conversation controls use. This does not drive
  /// VoiceOver, a hosted menu, or an increased-text layout pass.
  func testRequiredConversationControlsStayWordedWithoutColor() {
    XCTAssertEqual(ConversationControlLabels.record, "Record")
    XCTAssertEqual(ConversationControlLabels.stopAndSave, "Stop and Save")
    XCTAssertEqual(ConversationControlLabels.pause, "Pause")
    XCTAssertEqual(ConversationControlLabels.resume, "Resume")
    XCTAssertEqual(ConversationControlLabels.addMarker, "Add Marker")
    XCTAssertEqual(ConversationControlLabels.reviewPreservedAudio, "Review Preserved Audio")
    XCTAssertEqual(ConversationControlLabels.findInTranscript, "Find in this transcript")
    XCTAssertEqual(ConversationControlLabels.searchTranscripts, "Search transcripts")
    XCTAssertEqual(ConversationControlLabels.exportTranscript, "Export Transcript…")
    XCTAssertEqual(ConversationControlLabels.audioFiles, "Audio Files…")
    XCTAssertEqual(ConversationControlLabels.recordShortcut.key.character, "r")
    XCTAssertEqual(ConversationControlLabels.recordShortcut.modifiers, [.command, .shift])
    XCTAssertEqual(ConversationControlLabels.stopShortcut.key.character, "s")
    XCTAssertEqual(ConversationControlLabels.stopShortcut.modifiers, [.command, .shift])
    XCTAssertEqual(ConversationControlLabels.pauseShortcut.key.character, "p")
    XCTAssertEqual(ConversationControlLabels.pauseShortcut.modifiers, [.command, .shift])
    XCTAssertEqual(ConversationControlLabels.markerShortcut.key.character, "m")
    XCTAssertEqual(ConversationControlLabels.markerShortcut.modifiers, [.command, .shift])
    XCTAssertEqual(ConversationControlLabels.findShortcut.key.character, "f")
    XCTAssertEqual(ConversationControlLabels.findShortcut.modifiers, .command)
    XCTAssertEqual(
      ConversationControlLabels.playConversationAudio(.play), "Play conversation audio")
    XCTAssertEqual(
      ConversationControlLabels.recoveredSegment(.play, name: "Interview", segment: "A"),
      "Play Interview, segment A")
    XCTAssertEqual(
      ConversationControlLabels.seekAccessibility(stamp: "0:01", canSeek: true), "Play from 0:01")
    XCTAssertEqual(
      ConversationControlLabels.correctAccessibility(stamp: "0:01"), "Correct the text at 0:01")
    XCTAssertEqual(
      ConversationControlLabels.passageAccessibility(
        speaker: "Local user", text: "later brook", finality: "draft", corrected: false,
        isPlaying: false, isCited: false),
      "Local user. later brook Draft.")
    XCTAssertEqual(
      ConversationControlLabels.passageAccessibility(
        speaker: "Local user", text: "later brook", finality: "final", corrected: false,
        isPlaying: false, isCited: false),
      "Local user. later brook Final.")
    XCTAssertEqual(
      ConversationControlLabels.passageAccessibility(
        speaker: "Local user", text: "later brook", finality: "final", corrected: true,
        isPlaying: true, isCited: false),
      "Local user. later brook Playing. Corrected.")
    XCTAssertFalse(ConversationControlLabels.stopAndSave.contains("#"))
    let reduced = PerimeterStyle.transition(reduceMotion: true)
    let full = PerimeterStyle.transition(reduceMotion: false)
    XCTAssertEqual(reduced.luminance, 0.1)
    XCTAssertEqual(reduced.depth, 0)
    XCTAssertEqual(full.luminance, 0.16)
    XCTAssertEqual(full.depth, 0.2)
    XCTAssertEqual(PlaybackControlAction.play.title, "Play")
    XCTAssertEqual(PlaybackControlAction.stop.title, "Stop")
  }

  /// The transcript reader stores this scale and calls `TranscriptPassagePresentation.make`.
  /// This does not host the reader, drive VoiceOver, or walk focus order.
  func testLargerTranscriptTextStaysNamedAndSearchMatchesStayMarked() throws {
    XCTAssertEqual(TranscriptTextScale.resolve(nil), .standard)
    XCTAssertEqual(TranscriptTextScale.resolve("purple"), .standard)
    XCTAssertEqual(TranscriptTextScale.resolve(TranscriptTextScale.larger.rawValue), .larger)
    XCTAssertEqual(
      TranscriptTextScale.resolve("purple").rawValue, TranscriptTextScale.standard.rawValue)
    XCTAssertEqual(TranscriptTextScale.controlLabel, "Transcript text size")
    XCTAssertEqual(TranscriptTextScale.standard.spokenValue, "Standard text")
    XCTAssertEqual(TranscriptTextScale.larger.spokenValue, "Larger text")
    XCTAssertEqual(TranscriptTextScale.largest.spokenValue, "Largest text")
    for scale in TranscriptTextScale.allCases {
      XCTAssertFalse(scale.spokenValue.contains("#"))
      XCTAssertFalse(scale.title.isEmpty)
    }

    let suite = "OpenScribe.Proof.TranscriptText.\(UUID().uuidString)"
    let store = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { store.removePersistentDomain(forName: suite) }
    XCTAssertEqual(
      TranscriptTextScale.resolve(store.string(forKey: TranscriptTextScale.storageKey)), .standard)
    store.set(TranscriptTextScale.largest.rawValue, forKey: TranscriptTextScale.storageKey)
    let chosen = TranscriptTextScale.resolve(store.string(forKey: TranscriptTextScale.storageKey))
    XCTAssertEqual(chosen, .largest)
    XCTAssertEqual(chosen.spokenValue, "Largest text")
    XCTAssertLessThan(TranscriptTextScale.standard.pointSize, TranscriptTextScale.larger.pointSize)
    XCTAssertLessThan(TranscriptTextScale.larger.pointSize, TranscriptTextScale.largest.pointSize)

    let value = "alpha bravo"
    let marked = TranscriptPassagePresentation.make(
      speaker: "Local user", text: value, finality: "final", corrected: false, isPlaying: false,
      isCited: false, query: "bravo", scale: .largest)
    XCTAssertEqual(marked.spoken, "Local user. alpha bravo Final. Matches bravo.")
    let match = try XCTUnwrap(value.range(of: "bravo"))
    let matchRange = try XCTUnwrap(Range(match, in: marked.text))
    XCTAssertEqual(marked.text[matchRange].underlineStyle, .single)
    XCTAssertNotNil(marked.text[matchRange].font)
    let other = try XCTUnwrap(value.range(of: "alpha"))
    let otherRange = try XCTUnwrap(Range(other, in: marked.text))
    XCTAssertNil(marked.text[otherRange].underlineStyle)

    let cleared = TranscriptPassagePresentation.make(
      speaker: "Local user", text: value, finality: "final", corrected: true, isPlaying: false,
      isCited: false, query: " \n", scale: .larger)
    XCTAssertEqual(cleared.spoken, "Local user. alpha bravo Corrected.")
    XCTAssertFalse(cleared.spoken.contains(" Final."))
    XCTAssertFalse(cleared.spoken.contains("Matches"))
    XCTAssertTrue(cleared.text.runs.allSatisfy { $0.underlineStyle == nil })
  }

  func testScopeSummariesStateScopeRetentionAndWhyContextStopped() throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scope = try XCTUnwrap(
      fixture.preparation.contextAction(
        sessionId: fixture.sessionId, action: .authorize(request: fixture.windowScope())
      ).scopes.last)
    XCTAssertEqual(ContextScopeSummary.target(scope.request), "Preview — Plan on Built-in Display")
    XCTAssertEqual(ContextScopeSummary.line(scope, events: 1), "Watch Window: Active · 1 context event")
    XCTAssertEqual(
      ContextScopeSummary.exclusions(scope.request.exclusions),
      "Excluded where possible: Open Scribe, the Dock, the menu bar, and notifications. Context pauses when the screen locks.")
    let failed = try XCTUnwrap(
      fixture.preparation.contextAction(
        sessionId: fixture.sessionId, action: .fail(reason: .permissionLost)
      ).scopes.last)
    XCTAssertEqual(ContextScopeSummary.condition(failed), "Stopped: Screen Recording permission was turned off")
    XCTAssertEqual(ContextScopeSummary.retention, "No screen images are kept. Only recognized text is saved.")
    XCTAssertEqual(RegionEditor.clamped(CGRect(x: 0.98, y: -0.2, width: 0.01, height: 2)), CGRect(x: 0.95, y: 0, width: 0.05, height: 1))
    withExtendedLifetime(fixture.writer) {}
  }

  /// Pause and Revoke are the shipped inspector buttons. A saved text event
  /// stays, and a later display reading is refused. The test does not call
  /// `pause` or `revoke`.
  func testHostedPauseAndRevokeLeaveSavedContextWithoutNewEvents() async throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let permission = ScreenPermissionStub()
    permission.grant()
    let model = ContextScopeModel(
      binding: { fixture.binding }, frames: FrameScript(), recognize: { _ in [] },
      permissionCheck: { permission.current },
      permissionRequest: { permission.current },
      topology: { RecordingFixture.displays })
    defer { model.overlay.hide() }
    model.selection = ContextSelection(mode: .followPointer)
    XCTAssertTrue(model.authorize())
    let scope = try XCTUnwrap(model.current)
    let savedHost = mach_absolute_time()
    let saved = try fixture.preparation.proposeContextEvent(
      sessionId: fixture.sessionId,
      proposal: NativeContextProposal(
        scopeId: scope.scopeId, epoch: scope.epoch, reason: .userMarked,
        startHostTime: savedHost, endHostTime: savedHost, observedAtMs: 0,
        source: NativeContextSource(platformId: "pointer", name: "Pointer", application: nil),
        bounds: nil, reducerRevision: ContextReducer.revision,
        visionRevision: ContextReducer.visionRevision, languages: ["en-US"],
        blocks: [
          NativeContextTextBlock(text: "Agenda", x: 0.1, y: 0.1, width: 0.3, height: 0.1)
        ]))
    guard case .accepted = saved else { return XCTFail("\(saved)") }

    let view = ContextInspector(model: model).frame(width: 520, height: 280)
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 520, height: 280))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let offered = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard let button = self.button(titled: "Pause Context", in: host) else { return false }
      return button.frame.width > 1 && button.frame.height > 1 && button.isEnabled
    }
    let pause = try XCTUnwrap(self.button(titled: "Pause Context", in: host))
    XCTAssertTrue(offered && pause.isDescendant(of: host) && window.contentView === host)
    pause.performClick(nil)
    let paused = await waitUntil {
      host.layoutSubtreeIfNeeded()
      return model.current?.condition == .paused
    }
    XCTAssertTrue(paused)
    XCTAssertEqual(model.current?.condition, .paused)

    let pausedScope = try XCTUnwrap(model.current)
    let laterHost = mach_absolute_time()
    let duringPause = try fixture.preparation.proposeContextEvent(
      sessionId: fixture.sessionId,
      proposal: NativeContextProposal(
        scopeId: pausedScope.scopeId, epoch: pausedScope.epoch, reason: .attention,
        startHostTime: laterHost, endHostTime: laterHost, observedAtMs: 0,
        source: NativeContextSource(platformId: "pointer", name: "Pointer", application: nil),
        bounds: nil, reducerRevision: ContextReducer.revision,
        visionRevision: ContextReducer.visionRevision, languages: ["en-US"],
        blocks: [
          NativeContextTextBlock(
            text: "Paused screen", x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        ]))
    XCTAssertEqual(duringPause, .rejected(reason: .paused))

    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let events = try library.contextEvents(sessionId: fixture.sessionId)
    XCTAssertEqual(events.map(\.text), ["Agenda"])
    XCTAssertTrue(events.allSatisfy { $0.retention == "no_pixels" })
    let images = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter {
        ["png", "jpg", "jpeg", "heic", "tiff", "bmp", "gif"].contains($0.pathExtension.lowercased())
      }
    XCTAssertEqual(images ?? [], [])

    let revokeOffered = await waitUntil {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard let button = self.button(titled: "Revoke", in: host) else { return false }
      return button.frame.width > 1 && button.isEnabled && button.isDescendant(of: host)
    }
    let revoke = try XCTUnwrap(self.button(titled: "Revoke", in: host))
    XCTAssertTrue(revokeOffered && window.contentView === host)
    revoke.performClick(nil)
    let revoked = await waitUntil { model.current?.condition == .revoked }
    XCTAssertTrue(revoked)
    let afterRevoke = try fixture.preparation.proposeContextEvent(
      sessionId: fixture.sessionId,
      proposal: NativeContextProposal(
        scopeId: pausedScope.scopeId, epoch: pausedScope.epoch, reason: .attention,
        startHostTime: mach_absolute_time(), endHostTime: mach_absolute_time(), observedAtMs: 0,
        source: NativeContextSource(platformId: "pointer", name: "Pointer", application: nil),
        bounds: nil, reducerRevision: ContextReducer.revision,
        visionRevision: ContextReducer.visionRevision, languages: ["en-US"],
        blocks: [
          NativeContextTextBlock(text: "Revoked screen", x: 0.1, y: 0.3, width: 0.3, height: 0.1)
        ]))
    XCTAssertEqual(afterRevoke, .rejected(reason: .revoked))
    let remaining = try library.contextEvents(sessionId: fixture.sessionId)
    XCTAssertEqual(remaining.map(\.text), ["Agenda"])
    XCTAssertTrue(window.contentView === host)
    withExtendedLifetime(fixture.writer) {}
  }

  /// While a display watch is paused, a screen-parameters notification does
  /// not read another frame or store another event. The test clicks Pause
  /// and does not call `pause` or `topologyChanged`.
  func testHostedPausedContextIgnoresADisplayArrangementChange() async throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let permission = ScreenPermissionStub()
    permission.grant()
    let script = FrameScript()
    let quiet = frame([""], size: CGSize(width: 32, height: 32))
    script.enqueue(Array(repeating: quiet, count: 30))
    let gate = RecognitionGate()
    var displays = RecordingFixture.displays
    let model = ContextScopeModel(
      binding: { fixture.binding }, frames: script,
      recognize: { _ in gate.blocks() },
      permissionCheck: { permission.current },
      permissionRequest: { permission.current },
      topology: { displays })
    defer { model.overlay.hide() }
    await model.refreshChoices()
    model.selection = ContextSelection(mode: .watchDisplay, choiceId: "display-2")
    XCTAssertTrue(model.authorize())
    XCTAssertEqual(model.current?.condition, .active)
    let scope = try XCTUnwrap(model.current)
    let savedHost = mach_absolute_time()
    let saved = try fixture.preparation.proposeContextEvent(
      sessionId: fixture.sessionId,
      proposal: NativeContextProposal(
        scopeId: scope.scopeId, epoch: scope.epoch, reason: .userMarked,
        startHostTime: savedHost, endHostTime: savedHost, observedAtMs: 0,
        source: NativeContextSource(platformId: "2", name: "Studio Display", application: nil),
        bounds: nil, reducerRevision: ContextReducer.revision,
        visionRevision: ContextReducer.visionRevision, languages: ["en-US"],
        blocks: [
          NativeContextTextBlock(text: "Agenda", x: 0.1, y: 0.1, width: 0.3, height: 0.1)
        ]))
    guard case .accepted = saved else { return XCTFail("\(saved)") }

    let view = ContextInspector(model: model).frame(width: 520, height: 280)
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 520, height: 280))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let offered = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard let button = self.button(titled: "Pause Context", in: host) else { return false }
      return button.frame.width > 1 && button.frame.height > 1 && button.isEnabled
    }
    let pause = try XCTUnwrap(self.button(titled: "Pause Context", in: host))
    XCTAssertTrue(offered && pause.isDescendant(of: host) && window.contentView === host)
    pause.performClick(nil)
    let paused = await waitUntil {
      host.layoutSubtreeIfNeeded()
      return model.current?.condition == .paused
    }
    XCTAssertTrue(paused)
    XCTAssertEqual(model.current?.reason, "user")
    try await Task.sleep(nanoseconds: 300_000_000)

    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let before = try library.contextEvents(sessionId: fixture.sessionId)
    let idsBefore = before.map(\.eventId)
    let capturesBefore = script.captureCount
    XCTAssertEqual(before.map(\.text), ["Agenda"])
    gate.openChangedScreen()
    script.enqueue([frame(["Changed screen"], noise: 40, size: CGSize(width: 64, height: 64))])
    displays[1] = ContextDisplay(
      id: 2, name: "Studio Display",
      frame: CGRect(x: 1800, y: -300, width: 2560, height: 1440),
      scale: 2, rotation: 0, isMain: false)
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    try await Task.sleep(nanoseconds: 1_200_000_000)

    XCTAssertEqual(model.current?.condition, .paused)
    XCTAssertEqual(model.current?.reason, "user")
    XCTAssertNil(model.message)
    XCTAssertEqual(script.captureCount, capturesBefore)
    let events = try library.contextEvents(sessionId: fixture.sessionId)
    XCTAssertEqual(events.map(\.eventId), idsBefore)
    XCTAssertEqual(events.map(\.text), ["Agenda"])
    XCTAssertTrue(events.allSatisfy { $0.retention == "no_pixels" })
    let images = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter {
        ["png", "jpg", "jpeg", "heic", "tiff", "bmp", "gif"].contains($0.pathExtension.lowercased())
      }
    XCTAssertEqual(images ?? [], [])

    model.refreshDetail()
    window.close()
    let review = ContextEventsSection(detail: model.detail, events: events)
      .frame(width: 640, height: 420)
    let reviewHost = NSHostingView(rootView: review)
    reviewHost.sizingOptions = []
    let reviewWindow = NSWindow(
      contentRect: NSRect(x: 40, y: 40, width: 640, height: 420),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    reviewWindow.isReleasedWhenClosed = false
    reviewWindow.contentView = reviewHost
    reviewWindow.setContentSize(NSSize(width: 640, height: 420))
    reviewHost.frame = reviewWindow.contentLayoutRect
    reviewWindow.makeKeyAndOrderFront(nil)
    reviewWindow.orderFrontRegardless()
    defer { reviewWindow.close() }
    let saw = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      reviewHost.layoutSubtreeIfNeeded()
      reviewWindow.displayIfNeeded()
      let text = self.visibleText(in: reviewHost)
      return text.contains("Paused")
        && text.contains(ContextScopeSummary.retention)
        && text.contains("Agenda")
    }
    let visible = visibleText(in: reviewHost)
    XCTAssertTrue(saw, visible)
    XCTAssertTrue(visible.contains("Paused"), visible)
    XCTAssertTrue(visible.contains(ContextScopeSummary.retention), visible)
    XCTAssertTrue(visible.contains("Agenda"), visible)
    XCTAssertFalse(visible.contains("Changed screen"), visible)
    XCTAssertTrue(reviewWindow.contentView === reviewHost)
    withExtendedLifetime(fixture.writer) {}
  }

  /// While context is off, and again after Revoke, a screen-parameters
  /// notification does not read a frame or store an event. The test clicks
  /// Revoke and does not call `revoke` or `topologyChanged`.
  func testHostedOffAndRevokedContextIgnoreADisplayArrangementChange() async throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let permission = ScreenPermissionStub()
    permission.grant()
    let script = FrameScript()
    let quiet = frame([""], size: CGSize(width: 32, height: 32))
    script.enqueue(Array(repeating: quiet, count: 30))
    let gate = RecognitionGate()
    var displays = RecordingFixture.displays
    let model = ContextScopeModel(
      binding: { fixture.binding }, frames: script,
      recognize: { _ in gate.blocks() },
      permissionCheck: { permission.current },
      permissionRequest: { permission.current },
      topology: { displays })
    defer { model.overlay.hide() }
    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)

    let off = mount(
      ContextInspector(model: model).frame(width: 520, height: 180),
      size: NSSize(width: 520, height: 180))
    defer { off.window.close() }
    let offShown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      off.host.layoutSubtreeIfNeeded()
      off.window.displayIfNeeded()
      return self.visibleText(in: off.host).contains(ContextScopeSummary.off)
    }
    let offText = visibleText(in: off.host)
    XCTAssertTrue(offShown, offText)
    XCTAssertNil(model.current)
    XCTAssertEqual(script.captureCount, 0)
    XCTAssertEqual(try library.contextEvents(sessionId: fixture.sessionId).map(\.eventId), [])
    displays[1] = ContextDisplay(
      id: 2, name: "Studio Display",
      frame: CGRect(x: 1800, y: -300, width: 2560, height: 1440),
      scale: 2, rotation: 0, isMain: false)
    script.enqueue([frame(["Changed screen"], noise: 20, size: CGSize(width: 64, height: 64))])
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    try await Task.sleep(nanoseconds: 1_200_000_000)
    XCTAssertNil(model.current)
    XCTAssertEqual(script.captureCount, 0)
    XCTAssertEqual(try library.contextEvents(sessionId: fixture.sessionId).map(\.text), [])
    let offAfter = visibleText(in: off.host)
    XCTAssertTrue(offAfter.contains(ContextScopeSummary.off), offAfter)
    XCTAssertFalse(offAfter.contains("Changed screen"), offAfter)
    XCTAssertTrue(off.window.contentView === off.host)
    off.window.close()

    await model.refreshChoices()
    model.selection = ContextSelection(mode: .watchDisplay, choiceId: "display-2")
    XCTAssertTrue(model.authorize())
    let scope = try XCTUnwrap(model.current)
    XCTAssertEqual(scope.condition, .active)
    let savedHost = mach_absolute_time()
    let saved = try fixture.preparation.proposeContextEvent(
      sessionId: fixture.sessionId,
      proposal: NativeContextProposal(
        scopeId: scope.scopeId, epoch: scope.epoch, reason: .userMarked,
        startHostTime: savedHost, endHostTime: savedHost, observedAtMs: 0,
        source: NativeContextSource(platformId: "2", name: "Studio Display", application: nil),
        bounds: nil, reducerRevision: ContextReducer.revision,
        visionRevision: ContextReducer.visionRevision, languages: ["en-US"],
        blocks: [
          NativeContextTextBlock(text: "Agenda", x: 0.1, y: 0.1, width: 0.3, height: 0.1)
        ]))
    guard case .accepted = saved else { return XCTFail("\(saved)") }

    let live = mount(
      ContextInspector(model: model).frame(width: 520, height: 280),
      size: NSSize(width: 520, height: 280))
    defer { live.window.close() }
    let offered = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      live.host.layoutSubtreeIfNeeded()
      live.window.displayIfNeeded()
      guard let button = self.button(titled: "Revoke", in: live.host) else { return false }
      return button.frame.width > 1 && button.frame.height > 1 && button.isEnabled
    }
    let revoke = try XCTUnwrap(self.button(titled: "Revoke", in: live.host))
    XCTAssertTrue(offered && revoke.isDescendant(of: live.host) && live.window.contentView === live.host)
    let sampled = await waitUntil(timeoutNanoseconds: 3_000_000_000) {
      model.current?.condition == .active && script.captureCount > 0
    }
    XCTAssertTrue(sampled)
    revoke.performClick(nil)
    let revoked = await waitUntil {
      live.host.layoutSubtreeIfNeeded()
      return model.current?.condition == .revoked
    }
    XCTAssertTrue(revoked)
    try await Task.sleep(nanoseconds: 300_000_000)

    let before = try library.contextEvents(sessionId: fixture.sessionId)
    let idsBefore = before.map(\.eventId)
    let capturesBefore = script.captureCount
    XCTAssertEqual(before.map(\.text), ["Agenda"])
    XCTAssertGreaterThan(capturesBefore, 0)
    gate.openChangedScreen()
    script.enqueue([frame(["Changed screen"], noise: 90, size: CGSize(width: 64, height: 64))])
    displays[1] = ContextDisplay(
      id: 2, name: "Studio Display",
      frame: CGRect(x: 2400, y: -300, width: 2560, height: 1440),
      scale: 2, rotation: 0, isMain: false)
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    try await Task.sleep(nanoseconds: 1_200_000_000)

    XCTAssertEqual(model.current?.condition, .revoked)
    XCTAssertNotEqual(model.current?.reason, "topology_changed")
    XCTAssertNil(model.message)
    XCTAssertEqual(script.captureCount, capturesBefore)
    let events = try library.contextEvents(sessionId: fixture.sessionId)
    XCTAssertEqual(events.map(\.eventId), idsBefore)
    XCTAssertEqual(events.map(\.text), ["Agenda"])
    XCTAssertTrue(events.allSatisfy { $0.retention == "no_pixels" })
    let images = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter {
        ["png", "jpg", "jpeg", "heic", "tiff", "bmp", "gif"].contains($0.pathExtension.lowercased())
      }
    XCTAssertEqual(images ?? [], [])
    live.window.close()

    let status = mount(
      ContextInspector(model: model).frame(width: 520, height: 180),
      size: NSSize(width: 520, height: 180))
    defer { status.window.close() }
    let stopped = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      status.host.layoutSubtreeIfNeeded()
      status.window.displayIfNeeded()
      return self.visibleText(in: status.host).contains("Stopped")
    }
    let statusText = visibleText(in: status.host)
    XCTAssertTrue(stopped, statusText)
    XCTAssertTrue(statusText.contains("Stopped"), statusText)
    XCTAssertFalse(statusText.contains("Changed screen"), statusText)
    XCTAssertTrue(status.window.contentView === status.host)

    model.refreshDetail()
    let review = mount(
      ContextEventsSection(detail: model.detail, events: events).frame(width: 640, height: 420),
      size: NSSize(width: 640, height: 420))
    defer { review.window.close() }
    let saw = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      review.host.layoutSubtreeIfNeeded()
      review.window.displayIfNeeded()
      let text = self.visibleText(in: review.host)
      return text.contains("Stopped")
        && text.contains(ContextScopeSummary.retention)
        && text.contains("Agenda")
    }
    let visible = visibleText(in: review.host)
    XCTAssertTrue(saw, visible)
    XCTAssertTrue(visible.contains("Stopped"), visible)
    XCTAssertTrue(visible.contains(ContextScopeSummary.retention), visible)
    XCTAssertTrue(visible.contains("Agenda"), visible)
    XCTAssertFalse(visible.contains("Changed screen"), visible)
    XCTAssertTrue(review.window.contentView === review.host)
    withExtendedLifetime(fixture.writer) {}
  }

  private func mount<V: View>(_ view: V, size: NSSize) -> (window: NSWindow, host: NSHostingView<V>) {
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(size)
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    return (window, host)
  }

  private func button(titled title: String, in root: NSView) -> NSButton? {
    if let button = root as? NSButton,
      button.title == title || button.accessibilityLabel() == title
    {
      return button
    }
    for subview in root.subviews {
      if let found = button(titled: title, in: subview) { return found }
    }
    return nil
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000, _ body: () -> Bool
  ) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if body() { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return body()
  }

  private func visibleText(in root: NSView) -> String {
    var parts: [String] = []
    func walk(_ view: NSView) {
      if view.isHidden || view.isHiddenOrHasHiddenAncestor { return }
      if view.frame.width < 1 || view.frame.height < 1 { return }
      if let field = view as? NSTextField {
        let plain = field.stringValue
        parts.append(plain.isEmpty ? field.attributedStringValue.string : plain)
      }
      if let label = view.accessibilityLabel(), !label.isEmpty { parts.append(label) }
      if let value = view.accessibilityValue() as? String, !value.isEmpty { parts.append(value) }
      for subview in view.subviews { walk(subview) }
    }
    walk(root)
    return parts.joined(separator: "\n")
  }
}

private final class ProposalCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func increment() { lock.withLock { value += 1 } }
}

/// Turns on the "changed screen" blocks only after the pause snapshot.
private final class RecognitionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false

  func openChangedScreen() { lock.withLock { changed = true } }

  func blocks() -> [NativeContextTextBlock] {
    let changed = lock.withLock { self.changed }
    guard changed else { return [] }
    return [
      NativeContextTextBlock(text: "Changed screen", x: 0.1, y: 0.1, width: 0.4, height: 0.1)
    ]
  }
}

/// Screen permission a test changes after handing its checks to the model.
private final class ScreenPermissionStub: @unchecked Sendable {
  private let lock = NSLock()
  private var state = NativeScreenPermission.denied
  var current: NativeScreenPermission { lock.withLock { state } }
  func grant() { set(.granted) }
  func set(_ state: NativeScreenPermission) { lock.withLock { self.state = state } }
}
