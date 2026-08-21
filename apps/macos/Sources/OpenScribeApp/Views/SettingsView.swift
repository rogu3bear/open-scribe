import SwiftUI

struct SettingsView: View {
  let status: AppStatus

  var body: some View {
    Form {
      Section("Native core") {
        LabeledContent("Product", value: status.productName)
        LabeledContent("Rust version", value: status.coreVersion)
      }

      Section("Current implementation") {
        LabeledContent("Persistence", value: status.persistence)
        LabeledContent("Capture", value: status.capture)
        LabeledContent("Intelligence", value: status.intelligence)
      }
    }
    .formStyle(.grouped)
    .frame(width: 460, height: 300)
    .padding()
    .onAppear {
      AppTelemetry.sceneAppeared("settings", status: status)
    }
  }
}
