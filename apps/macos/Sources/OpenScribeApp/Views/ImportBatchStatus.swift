import SwiftUI

/// User-opened progress and recovery controls, without a modal dialog per
/// file or automatic document navigation while a batch is running.
struct ImportBatchStatus: View {
  @ObservedObject var imports: ImportedMediaAuthorityAdapter
  let canResume: Bool
  @State private var showsDetails = false

  var body: some View {
    Button {
      showsDetails.toggle()
    } label: {
      Label(title, systemImage: "square.and.arrow.down")
    }
    .help("Review import progress, pause between files, or see files that could not be imported")
    .popover(isPresented: $showsDetails) {
      VStack(alignment: .leading, spacing: ScribeSpacing.compact) {
        Text(title)
          .scribeSectionHeading()
        if imports.selectedFileCount > 0 {
          ProgressView(
            value: Double(imports.importedSessionIds.count + imports.failedImports.count),
            total: Double(imports.selectedFileCount)
          )
          .accessibilityLabel("Files processed")
          Text(
            "\(imports.importedSessionIds.count) imported · \(imports.failedImports.count) not imported"
          )
          .font(.callout)
        }
        Text("Your original recordings are kept. Pause takes effect after the current file.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if imports.hasPendingAudioImports {
          HStack {
            if imports.phase == .paused {
              Button("Resume Imports") { imports.resumeImports() }
                .disabled(!canResume)
                .help(
                  canResume
                    ? "Continue the selected files" : "Finish recording before resuming imports")
            } else {
              Button(imports.pauseRequested ? "Pausing…" : "Pause Imports") {
                imports.pauseImports()
              }
              .disabled(imports.pauseRequested)
            }
            Button("Stop Importing", role: .cancel) { imports.cancelImport() }
          }
        }
        if !imports.failedImports.isEmpty {
          Text("Files not imported")
            .font(.subheadline.weight(.semibold))
          ScrollView {
            LazyVStack(alignment: .leading, spacing: ScribeSpacing.compact) {
              ForEach(imports.failedImports) { failure in
                VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
                  Text(failure.fileName).font(.callout.weight(.medium))
                  Text(failure.message).font(.caption).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 220)
        }
      }
      .padding(20)
      .frame(width: 380)
    }
  }

  private var title: String {
    if imports.phase == .paused { return "Imports Paused" }
    if imports.hasPendingAudioImports { return "Importing \(imports.selectedFileCount) Recordings" }
    return "\(imports.failedImports.count) Files Not Imported"
  }
}
