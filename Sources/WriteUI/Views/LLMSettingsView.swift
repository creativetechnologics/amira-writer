import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct LLMSettingsView: View {
    var onSettingsChanged: (() -> Void)? = nil
    @State private var selectedProvider: LLMProviderType = LLMProviderConfig.shared.activeProvider
    @State private var apiKeyInput: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                providerPicker
                apiKeySection
                modelSection
            }
            .padding(12)
            .id(selectedProvider)  // Force full rebuild when provider changes
        }
        .onAppear {
            selectedProvider = LLMProviderConfig.shared.activeProvider
            apiKeyInput = LLMProviderConfig.shared.apiKey(for: selectedProvider)
        }
    }

    // MARK: - Provider Picker

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Provider")
                .font(.body.bold())
                .foregroundStyle(OperaChromeTheme.textPrimary)

            Picker("", selection: $selectedProvider) {
                Text("MiniMax").tag(LLMProviderType.minimax)
                Text("OpenCode Go").tag(LLMProviderType.opencode)
                Text("Claude").tag(LLMProviderType.claude)
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedProvider) { _, newProvider in
                LLMProviderConfig.shared.activeProvider = newProvider
                apiKeyInput = LLMProviderConfig.shared.apiKey(for: newProvider)
                onSettingsChanged?()
            }
        }
    }

    // MARK: - API Key / Auth

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch selectedProvider {
            case .claude:
                Text("Authentication")
                    .font(.body.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                HStack(spacing: 6) {
                    let available = LLMProviderConfig.shared.isClaudeCLIAvailable
                    Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(available ? .green : .red)
                    Text(available ? "Claude CLI found" : "Claude CLI not found")
                        .font(.callout)
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                }

                Text("Uses your Claude subscription via the claude CLI. No API key needed.")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textTertiary)

            case .minimax:
                apiKeyField(hint: "Uses your MiniMax Coding Plan subscription")

            case .opencode:
                apiKeyField(hint: "Uses your OpenCode Go subscription")
            }
        }
    }

    private func apiKeyField(hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Key")
                .font(.body.bold())
                .foregroundStyle(OperaChromeTheme.textPrimary)

            HStack(spacing: 6) {
                SecureField("Enter \(selectedProvider.displayName) API key...", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit {
                        LLMProviderConfig.shared.setAPIKey(apiKeyInput, for: selectedProvider); onSettingsChanged?()
                    }

                Button("Save") {
                    LLMProviderConfig.shared.setAPIKey(apiKeyInput, for: selectedProvider); onSettingsChanged?()
                }
                .font(.callout)
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(OperaChromeTheme.textTertiary)
        }
    }

    // MARK: - Model Selection

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model")
                .font(.body.bold())
                .foregroundStyle(OperaChromeTheme.textPrimary)

            ForEach(selectedProvider.knownModels) { model in
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: LLMModelInfo) -> some View {
        let isActive = LLMProviderConfig.shared.activeModelID == model.id
            && LLMProviderConfig.shared.activeProvider == selectedProvider

        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .font(.callout)
                    .foregroundStyle(isActive ? .cyan : OperaChromeTheme.textPrimary)
                    .lineLimit(1)

                if let ctx = model.contextLength {
                    Text("\(ctx / 1000)K context")
                        .font(.caption)
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.cyan)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.cyan.opacity(0.08) : Color.clear)
        )
        .onTapGesture {
            LLMProviderConfig.shared.activeProvider = selectedProvider
            LLMProviderConfig.shared.activeModelID = model.id
            onSettingsChanged?()
        }
    }
}
