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
  typealias Importer = @Sendable (String, URL) throws -> NativeImportedMediaEvidence

  @Published private(set) var phase: ImportedMediaAuthorityPhase = .idle
  @Published private(set) var statusMessage: String?
  @Published private(set) var importedSessionId: String?

  private let picker: Picker
  private let startSecurityScope: StartSecurityScope
  private let stopSecurityScope: StopSecurityScope
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
    importer: @escaping Importer
  ) {
    self.picker = picker
    self.startSecurityScope = startSecurityScope
    self.stopSecurityScope = stopSecurityScope
    self.importer = importer
  }

  var isBusy: Bool {
    phase == .choosing || phase == .importing
  }

  func chooseAndImport() {
    guard operationTask == nil else { return }
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
        self.statusMessage = "Import cancelled before the local copy began."
      default:
        self.phase = .failed
        self.statusMessage =
          "The selected file could not be imported as a supported local CAF. Nothing was added to the conversation library."
      }
    }
  }

  func cancelImport() {
    operationTask?.cancel()
  }

  private static func openPanelSelection() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Import Conversation Audio"
    panel.message = "Choose a local PCM CAF file to copy into Open Scribe."
    panel.prompt = "Import"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    return panel.runModal() == .OK ? panel.url : nil
  }
}

private enum ImportedMediaAuthorityError: Error {
  case unacceptedEvidence
}
