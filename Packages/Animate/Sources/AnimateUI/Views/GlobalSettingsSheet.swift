import AppKit
import ProjectKit
import SwiftUI

/// Top-level settings modal opened from the gear icon in every workspace's
/// title bar. Collects settings that affect multiple pages so the user
/// doesn't have to hop between Characters / Imagine / Places to flip
/// app-wide toggles.
///
/// Narrowly-scoped settings (Score-only, Mix-only, etc.) still live in
/// their own inspectors. Only cross-cutting settings belong here.
@available(macOS 26.0, *)
struct GlobalSettingsSheet: View {
    @Bindable var store: AnimateStore
    let onDismiss: () -> Void

    @AppStorage("animate.features.loraEnabled") private var loraEnabled: Bool = true
    @AppStorage("animate.features.map3dEnabled") private var map3dEnabled: Bool = true

    @State private var selectedTab: Tab = .general

    enum Tab: String, CaseIterable {
        case general = "General"
        case gemini = "Gemini"
        case features = "Features"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("Section", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .general:
                        generalTab
                    case .gemini:
                        geminiTab
                    case .features:
                        featuresTab
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Amira Writer — Settings")
                .font(.title3.weight(.semibold))
            Text("Settings that affect multiple pages live here. Page-specific options remain in each page's inspector.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(
                title: "Gemini API calls",
                subtitle: "Master switch for anything that would call Gemini. When OFF, no Gemini API calls can be made from anywhere in the app."
            ) {
                Toggle(isOn: $store.geminiMasterSwitch) {
                    Label("Allow Gemini API calls", systemImage: "sparkles")
                }
                if !store.geminiMasterSwitch {
                    Text("Gemini is currently blocked. Image generation and related actions are disabled across the app.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            sectionCard(
                title: "Current Gemini activity",
                subtitle: "Matches the status badge in the title bar."
            ) {
                HStack {
                    Label("\(store.geminiActivityActiveCount) running / queued",
                          systemImage: store.geminiActivityActiveCount > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                        .foregroundStyle(store.geminiActivityActiveCount > 0 ? .green : .secondary)
                    Spacer()
                    Text("\(store.geminiActivityLog.count) total in recent log")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Gemini

    private var geminiTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(
                title: "Access",
                subtitle: "Gemini API key management lives in the API Settings sheet (Gemini tab). This section links to it."
            ) {
                Text("API keys are stored in the macOS Keychain. Use the gear icon in the Animate workspace sidebar (or the Imagine inspector's Tools tab) to open the full API Settings sheet, which covers Gemini, MiniMax, Vidu, RunPod, and the Vertex AI backend picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            sectionCard(
                title: "Default model",
                subtitle: "Applies anywhere a draft doesn't explicitly override."
            ) {
                Picker("Default Model", selection: $store.selectedGeminiModel) {
                    ForEach(GeminiModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Features

    private var featuresTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(
                title: "LoRA training features",
                subtitle: "When OFF, LoRA-specific UI (per-thumbnail 'L' selector, LoRA training sheet, training-batch controls) is hidden across the app. Underlying code stays in place for future use; this just removes the clutter while you're working exclusively with Gemini."
            ) {
                Toggle(isOn: $loraEnabled) {
                    Label("Show LoRA features", systemImage: "brain.head.profile")
                }
                if !loraEnabled {
                    Text("LoRA UI is hidden. Flip this back on to resume training flows.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            sectionCard(
                title: "3D Map preview",
                subtitle: "Shows / hides the Places → 3D Map tab and the Map View camera preset button in Gemini preflight drafts."
            ) {
                Toggle(isOn: $map3dEnabled) {
                    Label("Show 3D map features", systemImage: "mountain.2")
                }
            }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.06)))
    }
}

/// Host button that opens the GlobalSettingsSheet. Drop into any workspace
/// title bar near the sidebar/inspector toggles.
@available(macOS 26.0, *)
struct GlobalSettingsGear: View {
    @Bindable var store: AnimateStore
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(OperaChromeTheme.raisedBackground.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .help("Global settings — cross-page toggles")
        .sheet(isPresented: $isOpen) {
            GlobalSettingsSheet(store: store, onDismiss: { isOpen = false })
        }
    }
}
