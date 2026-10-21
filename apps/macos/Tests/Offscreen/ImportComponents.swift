import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw CheckFailure(description: message) }
}

private final class Events: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func add(_ value: String) { lock.withLock { values.append(value) } }
  var all: [String] { lock.withLock { values } }
}

private final class Gate: @unchecked Sendable {
  private let condition = NSCondition()
  private var entered = false
  private var released = false
  var hasEntered: Bool { condition.withLock { entered } }
  func wait() {
    condition.lock()
    entered = true
    while !released { condition.wait() }
    condition.unlock()
  }
  func release() {
    condition.withLock {
      released = true
      condition.broadcast()
    }
  }
}

@MainActor private final class Admission {
  var allowsImport = true
}

/// Links the checked-in production adapter, cancellation helper, import errors,
/// clock projection, generated bindings and Rust library. This command-line
/// component check constructs no App/Scene/NSApplication, opens no panel or
/// store, and injects every file selection/import. It is not native UI proof.
@main
private struct ImportComponents {
  @MainActor static func main() async {
    do {
      try clock()
      try await partialBatch()
      try await cancelledBatch()
      try await pausedBatch()
      try await captureHold()
      print(
        "IMPORT_COMPONENTS_GREEN cases=clock,overlap,partial_batch,cancelled_batch,paused_batch,capture_hold"
      )
      print(
        "excludes=app,test_host,panels,storage,private_audio,ASR,renderer,UI,permissions,release")
    } catch {
      FileHandle.standardError.write(Data("IMPORT_COMPONENTS_RED \(error)\n".utf8))
      exit(1)
    }
  }

  @MainActor private static func wait(_ condition: () -> Bool) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !condition() {
      if DispatchTime.now().uptimeNanoseconds - start > 5_000_000_000 {
        throw CheckFailure(description: "component operation timed out")
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private static func evidence(_ title: String) -> NativeImportedMediaEvidence {
    NativeImportedMediaEvidence(
      sessionId: title, relativePath: "audio/imported/fixture.caf", byteLength: 128,
      sampleCount: 42, digestSha256: String(repeating: "a", count: 64), journalVersion: 1,
      lastJournalSequence: 5, originalUntouched: true, readyForReview: true)
  }

  @MainActor private static func selections() -> [URL] {
    ["First", "Second"].map { URL(fileURLWithPath: "/not-opened/\($0).caf") }
  }

  private static func clock() throws {
    try require(
      TranscriptPlaybackProjection.position(
        start: 30_000_000_000, end: 40_000_000_000,
        renderedFrames: 24_000, sampleRate: 48_000) == 30_500_000_000, "seek origin")
    for rate in [0.0, -1.0, Double.nan, Double.infinity] {
      try require(
        TranscriptPlaybackProjection.position(
          start: 0, end: 10, renderedFrames: 1, sampleRate: rate) == nil, "invalid clock")
    }
    try require(
      TranscriptPlaybackProjection.position(
        start: Int64.max - 1, end: Int64.max, renderedFrames: 48_000,
        sampleRate: 48_000) == nil, "overflow")
    let index = TranscriptPlaybackIndex([
      .init(id: "long", start: 0, end: 100), .init(id: "brief", start: 20, end: 30),
      .init(id: "later", start: 90, end: 110),
    ])
    try require(index.activeTurnIds(at: 25) == ["long", "brief"], "overlap")
    try require(index.activeTurnIds(at: 35) == ["long"], "long overlapping passage")
    try require(index.activeTurnIds(at: 110).isEmpty, "exclusive end")
  }

  @MainActor private static func partialBatch() async throws {
    let events = Events()
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: {
        events.add("open:\($0.lastPathComponent)")
        return true
      },
      stopSecurityScope: { events.add("close:\($0.lastPathComponent)") },
      importer: { title, _ in
        events.add("import:\(title)")
        if title == "Second" { throw NativeStorageError.InvalidRequest }
        return evidence(title)
      },
      batchPicker: {
        selections() + [URL(fileURLWithPath: "/not-opened/Third.caf")]
      })
    adapter.chooseAndImport()
    try await wait { !adapter.hasPendingAudioImports }
    try require(adapter.phase == .failed, "partial batch failure")
    try require(adapter.importedSessionIds == ["First", "Third"], "accepted imports retained")
    try require(adapter.importedSessionId == nil, "batch selection isolation")
    try require(adapter.failedImports.map(\.fileName) == ["Second.caf"], "per-file failure")
    try require(
      events.all == [
        "open:First.caf", "import:First", "close:First.caf",
        "open:Second.caf", "import:Second", "close:Second.caf",
        "open:Third.caf", "import:Third", "close:Third.caf",
      ], "one scope/import at a time")
  }

  @MainActor private static func cancelledBatch() async throws {
    let gate = Gate()
    defer { gate.release() }
    let events = Events()
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true }, stopSecurityScope: { _ in },
      importer: { title, _ in
        events.add(title)
        gate.wait()
        return evidence(title)
      },
      batchPicker: selections)
    adapter.chooseAndImport()
    try await wait { gate.hasEntered }
    adapter.cancelImport()
    gate.release()
    try await wait { !adapter.hasPendingAudioImports }
    try require(adapter.phase == .idle, "user cancellation is not failure")
    try require(adapter.importedSessionIds == ["First"], "cancel after commit retains result")
    try require(events.all == ["First"], "cancel stops next file")
  }

  @MainActor private static func pausedBatch() async throws {
    let gate = Gate()
    defer { gate.release() }
    let events = Events()
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true }, stopSecurityScope: { events.add($0.lastPathComponent) },
      importer: { title, _ in
        if title == "First" { gate.wait() }
        return evidence(title)
      }, batchPicker: selections)
    adapter.chooseAndImport()
    try await wait { gate.hasEntered }
    adapter.pauseImports()
    gate.release()
    try await wait { adapter.phase == .paused }
    try require(
      adapter.importedSessionIds == ["First"] && events.all == ["First.caf"],
      "pause closes current scope and holds next file")
    adapter.resumeImports()
    try await wait { !adapter.hasPendingAudioImports }
    try require(
      adapter.phase == .succeeded && adapter.importedSessionIds == ["First", "Second"],
      "explicit resume")
  }

  @MainActor private static func captureHold() async throws {
    let gate = Gate()
    defer { gate.release() }
    let admission = Admission()
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true }, stopSecurityScope: { _ in },
      canBeginImport: { admission.allowsImport },
      importer: { title, _ in
        if title == "First" { gate.wait() }
        return evidence(title)
      }, batchPicker: selections)
    adapter.chooseAndImport()
    try await wait { gate.hasEntered }
    admission.allowsImport = false
    gate.release()
    try await wait { adapter.phase == .paused }
    adapter.resumeImports()
    try require(
      adapter.phase == .paused && adapter.importedSessionIds == ["First"],
      "resume cannot bypass capture hold")
    admission.allowsImport = true
    try await wait { !adapter.hasPendingAudioImports }
    try require(
      adapter.phase == .succeeded && adapter.importedSessionIds.count == 2,
      "capture completion resumes pending explicit imports")
  }
}
