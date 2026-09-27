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

  @Published private(set) var phase: ImportedMediaAuthorityPhase = .idle
  @Published private(set) var statusMessage: String?
  @Published private(set) var importedSessionId: String?

  private let picker: Picker
  private let startSecurityScope: StartSecurityScope
  private let stopSecurityScope: StopSecurityScope
  private let canBeginImport: CanBeginImport
  private let importer: Importer
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
    importer: @escaping Importer
  ) {
    self.picker = picker
    self.startSecurityScope = startSecurityScope
    self.stopSecurityScope = stopSecurityScope
    self.canBeginImport = canBeginImport
    self.importer = importer
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

  private static func openPanelSelection() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Import Conversation Audio"
    panel.message =
      "Choose a local PCM CAF or mono M4A file to copy into Open Scribe (up to 256 MiB)."
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
      case .sourceTooLarge(let actual, _):
        let actualMiB = String(format: "%.1f", Double(actual) / 1_048_576)
        return
          "This file is \(actualMiB) MiB; the import limit is \(maximumMiB) MiB. Choose a smaller file. Nothing was added."
      case .decodedTooLarge:
        return
          "The decoded audio exceeds the \(maximumMiB) MiB playback limit. Choose a shorter file. Nothing was added."
      case .durationTooLong:
        return
          "The audio exceeds the four-hour import duration limit. Choose a shorter file. Nothing was added."
      case .unsupportedChannels:
        return
          "This M4A has multiple channels; this import supports mono audio only. Nothing was added."
      case .unsupportedFormat:
        return "This file is not a supported PCM CAF or mono M4A. Nothing was added."
      case .invalidSource, .decodeFailed:
        return "The selected audio could not be read safely. Nothing was added."
      }
    }
    if let failure = error as? NativeStorageError {
      switch failure {
      case .ImportSizeLimit:
        return
          "The audio exceeds the \(maximumMiB) MiB import or playback limit. Nothing was added."
      case .ImportDurationLimit:
        return "The audio exceeds the four-hour import duration limit. Nothing was added."
      case .InvalidRequest:
        return "This file is not a supported mono PCM CAF or M4A. Nothing was added."
      default:
        return "Open Scribe could not save a verified local copy. Nothing was added."
      }
    }
    return
      "The selected audio could not be imported. Nothing was added to the conversation library."
  }
}
