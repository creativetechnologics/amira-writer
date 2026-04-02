import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct APISettingsSheet: View {
    @Bindable var store: AnimateStore
    let onDismiss: () -> Void

    @State private var geminiKeyDraft: String = ""
    @State private var meshyKeyDraft: String = ""
    @State private var revealGeminiKey: Bool = false
    @State private var revealMeshyKey: Bool = false
    @State private var selectedTab: SettingsTab = .gemini

    enum SettingsTab: String, CaseIterable {
        case gemini = "Gemini"
        case meshy = "Meshy"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            Picker("Service", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .gemini:
                geminiForm
            case .meshy:
                meshyForm
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            geminiKeyDraft = store.geminiAPIKey
            meshyKeyDraft = store.meshyAPIKey
            Task { await store.fetchMeshyBalance() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Settings")
                .font(.title3.weight(.semibold))
            Text("Manage API keys for AI services used by Animate. Keys are stored locally in your macOS Keychain.")
                .font(.callout)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Gemini

    private var geminiForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            apiKeyField(
                label: "Gemini API Key",
                draft: $geminiKeyDraft,
                reveal: $revealGeminiKey,
                placeholder: "Paste Gemini API key...",
                isSaved: !store.geminiAPIKey.isEmpty,
                savedLabel: "Gemini key saved.",
                unsavedLabel: "No Gemini key saved yet."
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Default Model")
                    .font(.body.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Picker("Default Model", selection: $store.selectedGeminiModel) {
                    ForEach(GeminiModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Text("Default for master sheets, head poses, costume poses, accessories, and other Gemini requests.")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Meshy

    private var meshyForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            apiKeyField(
                label: "Meshy API Key",
                draft: $meshyKeyDraft,
                reveal: $revealMeshyKey,
                placeholder: "Paste Meshy API key...",
                isSaved: !store.meshyAPIKey.isEmpty,
                savedLabel: "Meshy key saved.",
                unsavedLabel: "No Meshy key saved yet."
            )

            if let balance = store.meshyBalance {
                HStack(spacing: 8) {
                    Image(systemName: "creditcard")
                        .foregroundStyle(.secondary)
                    Text("\(balance) credits remaining")
                        .font(.callout)
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                    Spacer()
                    Button("Refresh") {
                        Task { await store.fetchMeshyBalance() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("Used for 3D model generation from character reference images. Get a key at meshy.ai/settings/api.")
                .font(.caption)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared API Key Field

    private func apiKeyField(
        label: String,
        draft: Binding<String>,
        reveal: Binding<Bool>,
        placeholder: String,
        isSaved: Bool,
        savedLabel: String,
        unsavedLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.body.bold())
                .foregroundStyle(OperaChromeTheme.textPrimary)

            HStack(spacing: 8) {
                Group {
                    if reveal.wrappedValue {
                        TextField(placeholder, text: draft)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(placeholder, text: draft)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .font(.callout)

                Button(reveal.wrappedValue ? "Hide" : "Show") {
                    reveal.wrappedValue.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Image(systemName: isSaved ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isSaved ? .green : .orange)
                Text(isSaved ? savedLabel : unsavedLabel)
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Clear Keys", role: .destructive) {
                switch selectedTab {
                case .gemini:
                    geminiKeyDraft = ""
                    store.clearGeminiAPIKey()
                case .meshy:
                    meshyKeyDraft = ""
                    store.clearMeshyAPIKey()
                }
            }
            .buttonStyle(.bordered)
            .disabled(currentKeyIsEmpty)

            Spacer()

            Button("Cancel") {
                onDismiss()
            }
            .buttonStyle(.bordered)

            Button("Save") {
                store.setGeminiAPIKey(geminiKeyDraft)
                store.setMeshyAPIKey(meshyKeyDraft)
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var currentKeyIsEmpty: Bool {
        switch selectedTab {
        case .gemini: store.geminiAPIKey.isEmpty && geminiKeyDraft.isEmpty
        case .meshy: store.meshyAPIKey.isEmpty && meshyKeyDraft.isEmpty
        }
    }
}

// Keep backward-compatible typealias during transition
@available(macOS 26.0, *)
typealias GeminiSettingsSheet = APISettingsSheet
