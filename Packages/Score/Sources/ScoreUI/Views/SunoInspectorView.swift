import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@available(macOS 26.0, iOS 26.0, *)
struct SunoInspectorView: View {
    @Bindable var store: ScoreStore

    private enum Tab: String, CaseIterable {
        case uploads = "Uploads"
        case settings = "Settings"
    }

    @State private var activeTab: Tab = .uploads

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        activeTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.caption2.weight(activeTab == tab ? .semibold : .regular))
                            .foregroundStyle(activeTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(activeTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.top, 4)

            Divider().padding(.vertical, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch activeTab {
                    case .uploads:
                        uploadsTabContent
                    case .settings:
                        settingsTabContent
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var uploadsTabContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { store.sunoAutoUploadExportedWavs },
                set: { store.sunoAutoUploadExportedWavs = $0 }
            )) {
                Label("Auto-upload exported WAVs", systemImage: "arrow.up.circle")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 6) {
                Circle()
                    .fill(store.sunoCLIIsInstalled ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(store.sunoCLIIsInstalled ? "Suno CLI ready" : "Suno CLI missing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.sunoIsUploading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if !store.sunoUploadStatus.isEmpty {
                Text(store.sunoUploadStatus)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.sunoUploadQueueCount > 0 {
                Label("\(store.sunoUploadQueueCount) queued", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Upload Log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !store.sunoStatusLog.isEmpty {
                    Button("Clear") {
                        store.sunoStatusLog.removeAll()
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if store.sunoStatusLog.isEmpty {
                Text("No uploads yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.sunoStatusLog) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(logLevelColor(entry.level))
                            .frame(width: 5, height: 5)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.message)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            Text(entry.timestamp, style: .time)
                                .font(.system(size: 8))
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var settingsTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Suno CLI")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.sunoCLIIsInstalled ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(store.sunoCLIIsInstalled ? "CLI installed" : "CLI not found")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(store.sunoCLI.cliPath)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Change...") { selectSunoCLIPath() }
                        .font(.caption2)
                        .controlSize(.mini)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Login Check")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let result = store.sunoCLILastSelftest {
                    HStack(spacing: 6) {
                        Image(systemName: result.loggedIn ? "checkmark.circle.fill" : "xmark.octagon")
                            .foregroundStyle(result.loggedIn ? .green : .orange)
                        Text(result.loggedIn ? "Logged in to Suno" : "Not logged in")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Button {
                        Task { await store.openSunoLoginBrowser() }
                    } label: {
                        Label("Open Suno Login", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .font(.caption2)
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.sunoCLIIsInstalled)

                    Button {
                        Task { await store.runSunoSelftest() }
                    } label: {
                        Label("Run Selftest", systemImage: "stethoscope")
                    }
                    .font(.caption2)
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .disabled(!store.sunoCLIIsInstalled)
                }

                if let message = store.sunoCLIStatusMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let err = store.sunoCLIErrorMessage, !err.isEmpty {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Browser Profile")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(store.sunoCLI.profileDir)
                    .font(.caption2.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    store.revealSunoProfileDirectory()
                } label: {
                    Label("Reveal Profile Folder", systemImage: "folder")
                }
                .font(.caption2)
                .controlSize(.mini)
                .buttonStyle(.bordered)
            }
        }
    }

    private func logLevelColor(_ level: ScoreStore.SunoLogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    private func selectSunoCLIPath() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Select the `suno` CLI executable"
        if panel.runModal() == .OK, let url = panel.url {
            store.sunoCLI.cliPath = url.path
        }
        #endif
    }
}
