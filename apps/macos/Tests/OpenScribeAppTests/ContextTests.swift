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

  func captureFrame(_ target: ContextCaptureTarget) async throws -> CGImage {
    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
    return try lock.withLock {
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

  // MARK: Scope model

  func testTheModelAsksForPermissionOnlyToAuthorizeAndStopsOnPlatformSignals() async throws {
    let fixture = try RecordingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var permission = NativeScreenPermission.denied
    var requests = 0
    var displays = RecordingFixture.displays
    let model = ContextScopeModel(
      binding: { fixture.binding }, frames: FrameScript(), recognize: { _ in [] },
      permissionCheck: { permission },
      permissionRequest: { requests += 1; return permission },
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

    permission = .granted
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
    var permission = NativeScreenPermission.denied
    let model = ContextScopeModel(
      binding: { fixture.binding }, frames: FrameScript(), recognize: { _ in [] },
      permissionCheck: { permission }, permissionRequest: { permission },
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
    permission = .granted
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
    let review = ContextEventsSection(detail: model.detail, events: events)
    guard let directory = ProcessInfo.processInfo.environment["OPEN_SCRIBE_RENDER_DIR"] else { return }
    func render<V: View>(_ name: String, _ view: V, width: CGFloat) throws {
      let host = NSHostingView(rootView: view.padding(24).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
      host.frame = CGRect(origin: .zero, size: host.fittingSize)
      let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
}

private final class ProposalCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func increment() { lock.withLock { value += 1 } }
}
