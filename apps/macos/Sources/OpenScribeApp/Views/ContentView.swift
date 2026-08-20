import SwiftUI

struct ContentView: View {
    let status: AppStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(status.productName)
                    .font(.largeTitle.weight(.semibold))
                Text("Milestone 0 native vertical proof")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Rust core state") {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                    StatusRow(label: "Core version", value: status.coreVersion)
                    StatusRow(label: "Persistence", value: status.persistence)
                    StatusRow(label: "Capture", value: status.capture)
                    StatusRow(label: "Intelligence", value: status.intelligence)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            HStack {
                Label(
                    "No media, observation, provider, or model capability is present.",
                    systemImage: "checkmark.shield"
                )
                .foregroundStyle(.secondary)

                Spacer()

                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Text("Settings…")
                    }
                }
            }
        }
        .padding(32)
        .frame(minWidth: 600, minHeight: 360, alignment: .topLeading)
        .onAppear {
            AppTelemetry.sceneAppeared("primary", status: status)
        }
        .background {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--m0-proof-settings") {
                    if #available(macOS 14.0, *) {
                        SettingsProofTrigger()
                    }
                }
            #endif
        }
    }
}

#if DEBUG
    @available(macOS 14.0, *)
    private struct SettingsProofTrigger: View {
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    openSettings()
                }
        }
    }
#endif

private struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
