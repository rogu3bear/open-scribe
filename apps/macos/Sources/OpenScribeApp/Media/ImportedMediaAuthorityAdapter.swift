import AppKit
import SwiftUI

enum ImportedMediaAuthorityPhase: Equatable {
  case idle
  case choosing
  case importing
  case paused
  case succeeded
  case failed
}

struct ImportedAudioFailure: Identifiable, Equatable {
  let id: Int
  let fileName: String
  let message: String
}

@MainActor
final class ImportedMediaAuthorityAdapter: ObservableObject {
  typealias Picker = @MainActor () -> URL?
  typealias BatchPicker = @MainActor () -> [URL]
  typealias StartSecurityScope = @MainActor (URL) -> Bool
  typealias StopSecurityScope = @MainActor (URL) -> Void
  typealias CanBeginImport = @MainActor () -> Bool
  typealias Importer = @Sendable (String, URL) throws -> NativeImportedMediaEvidence
  typealias PackageOpener = @Sendable (URL) throws -> NativePackageImportReceipt

  @Published private(set) var phase: ImportedMediaAuthorityPhase = .idle
  @Published private(set) var statusMessage: String?
  @Published private(set) var importedSessionId: String?
  @Published private(set) var importedSessionIds: [String] = []
  @Published private(set) var selectedFileCount = 0
  @Published private(set) var hasPendingAudioImports = false
  @Published private(set) var pauseRequested = false
  @Published private(set) var failedImports: [ImportedAudioFailure] = []

  private let picker: BatchPicker
  private let startSecurityScope: StartSecurityScope
  private let stopSecurityScope: StopSecurityScope
  private let canBeginImport: CanBeginImport
  private let importer: Importer
  private let packagePicker: Picker
  private let packageOpener: PackageOpener?
  private var operationTask: Task<Void, Never>?

  init(
    picker: Picker? = nil,
    startSecurityScope: @escaping StartSecurityScope = {
      $0.startAccessingSecurityScopedResource()
    },
    stopSecurityScope: @escaping StopSecurityScope = {
      $0.stopAccessingSecurityScopedResource()
    },
    canBeginImport: @escaping CanBeginImport = { true },
    importer: @escaping Importer,
    packagePicker: @escaping Picker = ImportedMediaAuthorityAdapter.packagePanelSelection,
    packageOpener: PackageOpener? = nil,
    batchPicker: BatchPicker? = nil
  ) {
    if let batchPicker {
      self.picker = batchPicker
    } else if let picker {
      self.picker = { picker().map { [$0] } ?? [] }
    } else {
      self.picker = Self.openPanelSelections
    }
    self.startSecurityScope = startSecurityScope
    self.stopSecurityScope = stopSecurityScope
    self.canBeginImport = canBeginImport
    self.importer = importer
    self.packagePicker = packagePicker
    self.packageOpener = packageOpener
  }

  var canOpenPackages: Bool {
    packageOpener != nil
  }

  var isBusy: Bool {
    phase == .choosing || phase == .importing
  }

  func chooseAndImport() {
    guard operationTask == nil else { return }
    guard canBeginImport() else {
      phase = .failed
      importedSessionId = nil
      statusMessage = "Finish the current recording before importing audio. Nothing was added."
      return
    }
    phase = .choosing
    statusMessage = nil
    importedSessionId = nil
    importedSessionIds = []
    failedImports = []
    pauseRequested = false
    let selected = picker()
    selectedFileCount = selected.count
    guard !selected.isEmpty else {
      phase = .idle
      return
    }
    // Preserve immediate single-file permission failures. A batch acquires
    // just one file's scope at a time and reports each refused file separately.
    var firstAuthorized = false
    if selected.count == 1 {
      guard selected[0].isFileURL, startSecurityScope(selected[0]) else {
        phase = .failed
        statusMessage =
          "Open Scribe could not read the selected file. Nothing was added to the conversation library."
        return
      }
      firstAuthorized = true
    }
    phase = .importing
    hasPendingAudioImports = true
    let importer = importer
    let stopScope = stopSecurityScope
    let initiallyAuthorized = firstAuthorized
    operationTask = Task { [weak self] in
      guard let self else {
        if initiallyAuthorized { stopScope(selected[0]) }
        return
      }
      var firstScopeOpen = initiallyAuthorized
      defer {
        if firstScopeOpen { self.stopSecurityScope(selected[0]) }
        self.hasPendingAudioImports = false
        self.pauseRequested = false
        self.operationTask = nil
      }
      do {
        for (index, url) in selected.enumerated() {
          try Task.checkCancellation()
          while self.pauseRequested || !self.canBeginImport() {
            if firstScopeOpen {
              self.stopSecurityScope(selected[0])
              firstScopeOpen = false
            }
            self.phase = .paused
            self.statusMessage =
              self.pauseRequested
              ? "Imports paused. Your original recordings are kept."
              : "Imports are waiting for the current recording to finish."
            try await Task.sleep(nanoseconds: 100_000_000)
          }
          try Task.checkCancellation()
          self.phase = .importing
          self.statusMessage = "Importing file \(index + 1) of \(selected.count)…"
          let hasScope = index == 0 && firstScopeOpen
          if !hasScope && (!url.isFileURL || !self.startSecurityScope(url)) {
            self.failedImports.append(
              ImportedAudioFailure(
                id: index, fileName: url.lastPathComponent,
                message: "Open Scribe could not read this file. It was not imported."))
            await Task.yield()
            continue
          }
          if hasScope { firstScopeOpen = false }
          let title = Self.proposedTitle(url)
          let result: Result<NativeImportedMediaEvidence, Error>
          do {
            result = .success(try await StructuredNativeIO.mutation { try importer(title, url) })
          } catch {
            result = .failure(error)
          }
          self.stopSecurityScope(url)
          switch result {
          case .success(let evidence) where evidence.originalUntouched && evidence.readyForReview:
            self.importedSessionIds.append(evidence.sessionId)
            // A batch updates the library without repeatedly stealing the
            // selected document. Single-file navigation keeps its old contract.
            if selected.count == 1 { self.importedSessionId = evidence.sessionId }
          case .failure(let error) where error is CancellationError:
            throw error
          default:
            self.failedImports.append(
              ImportedAudioFailure(
                id: index, fileName: url.lastPathComponent,
                message: Self.failureMessage(result: result)))
          }
          await Task.yield()
        }
        self.phase = self.failedImports.isEmpty ? .succeeded : .failed
        if selected.count == 1, self.failedImports.isEmpty {
          self.statusMessage =
            "Imported \(Self.proposedTitle(selected[0])) into the local conversation library."
        } else if selected.count == 1 {
          self.statusMessage = self.failedImports.first?.message
        } else {
          self.statusMessage =
            "Imported \(self.importedSessionIds.count) of \(selected.count) recordings. "
            + (self.failedImports.isEmpty
              ? "" : "\(self.failedImports.count) could not be imported. ")
            + "Your original files are kept."
        }
      } catch {
        self.phase = .idle
        self.statusMessage =
          self.importedSessionIds.isEmpty
          ? "Import cancelled. No conversation was added."
          : "Stopped after importing \(self.importedSessionIds.count) of \(selected.count) recordings. Your original files are kept."
      }
    }
  }

  func pauseImports() {
    guard hasPendingAudioImports, phase == .importing else { return }
    pauseRequested = true
    statusMessage = "Pausing after the current file. Your original recordings are kept."
  }

  func resumeImports() {
    guard hasPendingAudioImports, canBeginImport() else { return }
    pauseRequested = false
    phase = .importing
  }

  private static func proposedTitle(_ url: URL) -> String {
    let title = url.deletingPathExtension().lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Imported conversation" : title
  }

  func cancelImport() {
    operationTask?.cancel()
  }

  /// Opens a `.openscribe` portable package exported on another Mac as a new
  /// conversation. Rust verifies the whole package before copying anything.
  func chooseAndOpenPackage() {
    guard operationTask == nil, let packageOpener else { return }
    guard canBeginImport() else {
      phase = .failed
      importedSessionId = nil
      statusMessage =
        "Finish the current recording before opening a portable package. Nothing was added."
      return
    }
    phase = .choosing
    statusMessage = nil
    importedSessionId = nil
    importedSessionIds = []
    failedImports = []
    selectedFileCount = 0
    guard let selectedURL = packagePicker() else {
      phase = .idle
      return
    }
    guard selectedURL.isFileURL, selectedURL.pathExtension == "openscribe" else {
      phase = .failed
      statusMessage =
        "Choose a portable package whose name ends in .openscribe. Nothing was added."
      return
    }
    guard startSecurityScope(selectedURL) else {
      phase = .failed
      statusMessage = "Open Scribe could not read the selected package. Nothing was added."
      return
    }
    phase = .importing
    operationTask = Task { [weak self] in
      guard let self else { return }
      let result: Result<NativePackageImportReceipt, Error>
      do {
        result = .success(
          try await StructuredNativeIO.mutation {
            try packageOpener(selectedURL)
          }
        )
      } catch {
        result = .failure(error)
      }
      self.stopSecurityScope(selectedURL)
      defer { self.operationTask = nil }
      switch result {
      case .success(let receipt):
        self.importedSessionId = receipt.sessionId
        self.phase = .succeeded
        self.statusMessage = Self.packageSuccessMessage(receipt)
      case .failure(let error) where error is CancellationError:
        self.phase = .idle
        self.statusMessage = "Opening cancelled. No conversation was added."
      case .failure(let error):
        self.phase = .failed
        self.statusMessage = Self.packageFailureMessage(error)
      }
    }
  }

  nonisolated static func packageSuccessMessage(_ receipt: NativePackageImportReceipt) -> String {
    let files = receipt.mediaFiles == 1 ? "1 audio file" : "\(receipt.mediaFiles) audio files"
    let transcript =
      switch receipt.transcriptTracks {
      case 0: "no transcript"
      case 1: "a transcript"
      default: "transcripts for \(receipt.transcriptTracks) tracks"
      }
    return
      "Opened \(receipt.title) from a portable package with \(files) and \(transcript). It is a separate conversation on this Mac."
  }

  nonisolated static func packageFailureMessage(_ error: Error) -> String {
    switch error as? NativeStorageError {
    case .IntegrityMismatch:
      "This package did not verify: a file is missing, changed, linked, or not listed in its manifest. Nothing was added."
    case .InvalidRequest:
      "This package's transcript, timeline, or markers do not match its audio. Nothing was added."
    case .InvalidState:
      "This package holds something this version cannot open yet, such as a compressed import. Nothing was added."
    default:
      "Open Scribe could not save a local copy of this package. Check that this Mac has enough free space, then try again. Nothing was added."
    }
  }

  private static func packagePanelSelection() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Open Portable Package"
    panel.message =
      "Choose a .openscribe package exported by Open Scribe. It is verified before anything is copied."
    panel.prompt = "Open"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    return panel.runModal() == .OK ? panel.url : nil
  }

  private static func openPanelSelections() -> [URL] {
    let panel = NSOpenPanel()
    panel.title = "Import Conversation Audio"
    panel.message =
      Self.importLimitPrompt
    panel.prompt = "Import"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = true
    return panel.runModal() == .OK ? panel.urls : []
  }

  private static func failureMessage(
    result: Result<NativeImportedMediaEvidence, Error>
  ) -> String {
    guard case .failure(let error) = result else {
      return "Import evidence was not accepted. Nothing was added to the conversation library."
    }
    let policy = nativeImportPolicy()
    if let failure = error as? BoundedAudioImportError {
      switch failure {
      case .sourceTooLarge(let actual, let maximum):
        let actualMiB = String(format: "%.1f", Double(actual) / 1_048_576)
        return
          "This file is \(actualMiB) MiB; its import limit is \(maximum / 1_048_576) MiB. Choose a smaller file. Nothing was added."
      case .decodedTooLarge:
        return
          "The decoded audio exceeds the \(policy.maximumManagedBytes / 1_048_576) MiB PCM import limit. Choose a shorter file. Nothing was added."
      case .durationTooLong:
        return
          "The audio exceeds the four-hour import duration limit. Choose a shorter file. Nothing was added."
      case .unsupportedChannels:
        return
          "This M4A has an unsupported channel layout. Mono and stereo are supported. Nothing was added."
      case .unsupportedTracks:
        return
          "This M4A contains multiple or unreadable audio tracks. Choose a single-track file. Nothing was added."
      case .unsupportedFormat:
        return
          "This file is not supported. Choose a PCM CAF or a single-track AAC or Apple Lossless M4A. Nothing was added."
      case .invalidSource, .decodeFailed:
        return "The selected audio could not be read safely. Nothing was added."
      }
    }
    if let failure = error as? NativeStorageError {
      switch failure {
      case .ImportSizeLimit:
        return
          "The audio exceeds the import size limit (\(Self.pcmLimitMiB) MiB PCM CAF or \(Self.m4aLimitGiB) GiB M4A). Nothing was added."
      case .ImportDurationLimit:
        return "The audio exceeds the four-hour import duration limit. Nothing was added."
      case .InvalidRequest:
        return "This file is not a supported PCM CAF or 48 kHz mono/stereo M4A. Nothing was added."
      default:
        return "Open Scribe could not save a verified local copy. Nothing was added."
      }
    }
    return
      "The selected audio could not be imported. Nothing was added to the conversation library."
  }

  static var importLimitHelp: String {
    "Add local CAF or M4A audio (PCM CAF up to \(pcmLimitMiB) MiB, M4A up to \(m4aLimitGiB) GiB, four hours)"
  }

  private static var importLimitPrompt: String {
    "Choose local PCM CAF files (up to \(pcmLimitMiB) MiB each) or AAC/Apple Lossless M4A files (up to \(m4aLimitGiB) GiB each), up to four hours per recording. Files are imported one at a time; originals are kept. Transcription follows your Settings preference."
  }

  private static var pcmLimitMiB: UInt64 {
    nativeImportPolicy().maximumManagedBytes / 1_048_576
  }

  private static var m4aLimitGiB: UInt64 {
    nativeImportPolicy().maximumSourceBytes / 1_073_741_824
  }
}
