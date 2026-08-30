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
  typealias StartSecurityScope = (URL) -> Bool
  typealias StopSecurityScope = (URL) -> Void
  typealias Importer = (String, URL) throws -> NativeImportedMediaEvidence

  @Published private(set) var phase: ImportedMediaAuthorityPhase = .idle
  @Published private(set) var statusMessage: String?
  @Published private(set) var importedSessionId: String?

  private let picker: Picker
  private let startSecurityScope: StartSecurityScope
  private let stopSecurityScope: StopSecurityScope
  private let importer: Importer
  private var operationInProgress = false

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
    guard !operationInProgress else { return }
    operationInProgress = true
    defer { operationInProgress = false }
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
    defer { stopSecurityScope(selectedURL) }

    phase = .importing
    let proposedTitle = selectedURL.deletingPathExtension().lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let title = proposedTitle.isEmpty ? "Imported conversation" : proposedTitle
    do {
      let evidence = try importer(title, selectedURL)
      guard evidence.originalUntouched, evidence.readyForReview else {
        throw ImportedMediaAuthorityError.unacceptedEvidence
      }
      importedSessionId = evidence.sessionId
      phase = .succeeded
      statusMessage = "Imported \(title) into the local conversation library."
    } catch {
      phase = .failed
      statusMessage =
        "The selected file could not be imported as a supported local CAF. Nothing was added to the conversation library."
    }
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
