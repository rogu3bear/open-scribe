import AppKit
import SwiftUI

enum ImportedMediaAuthorityPhase: Equatable {
  case idle
  case choosing
  case importing
  case succeeded
  case failed
}

@MainActor
final class ImportedMediaAuthorityAdapter: ObservableObject {
  typealias Picker = @MainActor () -> URL?
  typealias StartSecurityScope = @MainActor (URL) -> Bool
  typealias StopSecurityScope = @MainActor (URL) -> Void
  typealias CanBeginImport = @MainActor () -> Bool
  typealias Importer = @Sendable (String, URL) throws -> NativeImportedMediaEvidence
  typealias PackageOpener = @Sendable (URL) throws -> NativePackageImportReceipt

  @Published private(set) var phase: ImportedMediaAuthorityPhase = .idle
  @Published private(set) var statusMessage: String?
  @Published private(set) var importedSessionId: String?

  private let picker: Picker
  private let startSecurityScope: StartSecurityScope
  private let stopSecurityScope: StopSecurityScope
  private let canBeginImport: CanBeginImport
  private let importer: Importer
  private let packagePicker: Picker
  private let packageOpener: PackageOpener?
  private var operationTask: Task<Void, Never>?

  init(
    picker: @escaping Picker = ImportedMediaAuthorityAdapter.openPanelSelection,
    startSecurityScope: @escaping StartSecurityScope = {
      $0.startAccessingSecurityScopedResource()
    },
    stopSecurityScope: @escaping StopSecurityScope = {
      $0.stopAccessingSecurityScopedResource()
    },
    canBeginImport: @escaping CanBeginImport = { true },
    importer: @escaping Importer,
    packagePicker: @escaping Picker = ImportedMediaAuthorityAdapter.packagePanelSelection,
    packageOpener: PackageOpener? = nil
  ) {
    self.picker = picker
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
    guard let selectedURL = picker() else {
      phase = .idle
      return
    }
    guard selectedURL.isFileURL, startSecurityScope(selectedURL) else {
      phase = .failed
      statusMessage =
        "Open Scribe could not read the selected file. Nothing was added to the conversation library."
      return
    }
    phase = .importing
    let proposedTitle = selectedURL.deletingPathExtension().lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let title = proposedTitle.isEmpty ? "Imported conversation" : proposedTitle
    let importer = importer
    operationTask = Task { [weak self] in
      guard let self else { return }
      let result: Result<NativeImportedMediaEvidence, Error>
      do {
        result = .success(
          try await StructuredNativeIO.mutation {
            try importer(title, selectedURL)
          }
        )
      } catch {
        result = .failure(error)
      }
      self.stopSecurityScope(selectedURL)
      defer { self.operationTask = nil }
      switch result {
      case .success(let evidence)
      where evidence.originalUntouched && evidence.readyForReview:
        self.importedSessionId = evidence.sessionId
        self.phase = .succeeded
        self.statusMessage = "Imported \(title) into the local conversation library."
      case .failure(let error) where error is CancellationError:
        self.phase = .idle
        self.statusMessage = "Import cancelled. No conversation was added."
      default:
        self.phase = .failed
        self.statusMessage = Self.failureMessage(result: result)
      }
    }
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

  private static func openPanelSelection() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Import Conversation Audio"
    panel.message =
      "Choose a local PCM CAF (up to 256 MiB) or 48 kHz AAC/Apple Lossless M4A (up to 1 GiB and four hours)."
    panel.prompt = "Import"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    return panel.runModal() == .OK ? panel.url : nil
  }

  private static func failureMessage(
    result: Result<NativeImportedMediaEvidence, Error>
  ) -> String {
    guard case .failure(let error) = result else {
      return "Import evidence was not accepted. Nothing was added to the conversation library."
    }
    let policy = nativeImportPolicy()
    let maximumMiB = policy.maximumSourceBytes / 1_048_576
    if let failure = error as? BoundedAudioImportError {
      switch failure {
      case .sourceTooLarge(let actual, let maximum):
        let actualMiB = String(format: "%.1f", Double(actual) / 1_048_576)
        return
          "This file is \(actualMiB) MiB; its import limit is \(maximum / 1_048_576) MiB. Choose a smaller file. Nothing was added."
      case .decodedTooLarge:
        return
          "The decoded audio exceeds the \(policy.maximumManagedBytes / 1_048_576) MiB PCM playback limit. Choose a shorter file. Nothing was added."
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
          "This file is not supported. Large or stereo M4A must be 48 kHz AAC or Apple Lossless. Nothing was added."
      case .invalidSource, .decodeFailed:
        return "The selected audio could not be read safely. Nothing was added."
      }
    }
    if let failure = error as? NativeStorageError {
      switch failure {
      case .ImportSizeLimit:
        return
          "The audio exceeds the \(maximumMiB) MiB M4A or 256 MiB PCM CAF limit. Nothing was added."
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
}
