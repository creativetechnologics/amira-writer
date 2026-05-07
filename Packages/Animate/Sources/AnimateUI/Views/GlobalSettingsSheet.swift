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

    @ObservedObject private var storyboardStatus = StoryboardServerStatusModel.shared
    @AppStorage("animate.features.map3dEnabled") private var map3dEnabled: Bool = true
    @AppStorage(AnimatedLookPromptSettings.masterPromptDefaultsKey) private var masterAnimatedLookPrompt = ""

    @State private var selectedTab: Tab = .general
    @State private var showAPISettings = false
    @State private var storyboardPortDraft = ""
    @State private var storyboardURLCopied = false
    @FocusState private var storyboardPortFieldFocused: Bool

    enum Tab: String, CaseIterable {
        case general = "General"
        case gemini = "Gemini"
        case features = "Features"
        case places = "Places"
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
                    case .places:
                        placesTab
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
        .frame(width: 680, height: 640)
        .onAppear {
            syncStoryboardPortDraft()
            masterAnimatedLookPrompt = AnimatedLookPromptSettings.loadMasterPrompt()
        }
        .onChange(of: storyboardStatus.port) { _, _ in
            guard !storyboardPortFieldFocused else { return }
            syncStoryboardPortDraft()
        }
        .onChange(of: masterAnimatedLookPrompt) { _, newValue in
            store.persistProjectAnimatedLookPrompt(newValue)
        }
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
                title: "Gemini batch API jobs",
                subtitle: "Controls the long-running Gemini batch system that submits jobs and waits for them to come back later. Immediate multi-image generation still works when this is OFF."
            ) {
                Toggle(isOn: $store.geminiBatchJobsEnabled) {
                    Label("Allow Gemini batch API jobs", systemImage: "tray.full")
                }
                if !store.geminiBatchJobsEnabled {
                    Text("Gemini batch submission is currently blocked across the app. Add-to-Batch, queue submission, and watchdog-backed batch jobs are disabled.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            sectionCard(
                title: "Current AI generation activity",
                subtitle: "Matches the universal AI generation status badge in the title bar."
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

            storyboardServerCard
        }
    }

    // MARK: - Gemini

    private var geminiTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(
                title: "API Keys",
                subtitle: "Stored in the project folder (synced by Syncthing). Covers Gemini, OpenAI, the supplemental LLM, Vidu, RunPod, and the Vertex AI backend."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    apiKeyStatusRow("Gemini", configured: store.hasGeminiImageGenerationConfiguration)
                    apiKeyStatusRow("OpenAI", configured: !store.openAIAPIKey.isEmpty)
                    apiKeyStatusRow("Supplemental LLM", configured: !store.supplementalLLMConfiguration().apiKey.isEmpty)
                    apiKeyStatusRow("RunPod", configured: !store.runPodAPIKey.isEmpty)

                    Button("Open API Settings…") {
                        showAPISettings = true
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
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

            sectionCard(
                title: "Master Animated Look Prompt",
                subtitle: "Stored in the project folder so it can sync between machines. This prompt is prepended whenever the Animated Look toggles are enabled from Canvas or Gemini generation flows."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $masterAnimatedLookPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(4)
                        .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.white.opacity(0.08)))

                    HStack {
                        Text(masterAnimatedLookPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "No animated look prompt is configured yet."
                             : "Configured — generation toggles can inject this prompt anywhere they are enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !masterAnimatedLookPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Clear") {
                                masterAnimatedLookPrompt = ""
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

        }
        .sheet(isPresented: $showAPISettings) {
            GeminiSettingsSheet(
                store: store,
                onDismiss: { showAPISettings = false }
            )
        }
    }

    private var storyboardServerCard: some View {
        sectionCard(
            title: "iPad storyboard server",
            subtitle: "Local LAN page for drawing storyboard frames on the iPad. Port changes restart this small server immediately."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(storyboardStatus.statusText, systemImage: storyboardStatus.statusSymbolName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(storyboardStatusColor)
                    Spacer()
                    Text(storyboardStatus.displayURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(storyboardStatus.displayURL.absoluteString, forType: .string)
                        storyboardURLCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            storyboardURLCopied = false
                        }
                    } label: {
                        Label(storyboardURLCopied ? "Copied" : "Copy URL",
                              systemImage: storyboardURLCopied ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Port")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("\(StoryboardAPIServer.defaultPort)", text: $storyboardPortDraft)
                        .font(.caption.monospacedDigit())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .focused($storyboardPortFieldFocused)
                    Button("Apply") {
                        applyStoryboardPortDraft()
                    }
                    .controlSize(.small)
                    .disabled(!canApplyStoryboardPortDraft)
                    Button("Default") {
                        storyboardPortDraft = "\(StoryboardAPIServer.defaultPort)"
                        storyboardPortFieldFocused = false
                        StoryboardAPIServer.setConfiguredPort(Int(StoryboardAPIServer.defaultPort))
                        syncStoryboardPortDraft()
                    }
                    .controlSize(.small)
                    Spacer()
                    Text("Allowed: \(StoryboardAPIServer.allowedPortRange.lowerBound)–\(StoryboardAPIServer.allowedPortRange.upperBound)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var storyboardStatusColor: Color {
        switch storyboardStatus.state {
        case .live:
            return .green
        case .starting:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private var parsedStoryboardPortDraft: Int? {
        let cleaned = storyboardPortDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(cleaned),
              StoryboardAPIServer.allowedPortRange.contains(value) else {
            return nil
        }
        return value
    }

    private var canApplyStoryboardPortDraft: Bool {
        guard let parsedStoryboardPortDraft else { return false }
        return parsedStoryboardPortDraft != Int(storyboardStatus.port)
    }

    private func syncStoryboardPortDraft() {
        storyboardPortDraft = "\(storyboardStatus.port)"
    }

    private func applyStoryboardPortDraft() {
        guard let parsedStoryboardPortDraft else { return }
        storyboardPortFieldFocused = false
        StoryboardAPIServer.setConfiguredPort(parsedStoryboardPortDraft)
        syncStoryboardPortDraft()
    }

    private func apiKeyStatusRow(_ name: String, configured: Bool) -> some View {
        HStack {
            Text(name)
                .font(.caption)
            Spacer()
            Text(configured ? "Configured" : "Not set")
                .font(.caption)
                .foregroundStyle(configured ? .green : .red)
        }
    }

    // MARK: - Features

    private var featuresTab: some View {
        VStack(alignment: .leading, spacing: 14) {
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

    // MARK: - Places

    private var placesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(
                title: "Places World Context",
                subtitle: "These context lines can feed shot generation, image prompts, and 3D Map camera capture drafts. Delete anything you do not want generated. One line per idea."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    worldContextEditor(
                        label: "Environmental",
                        text: Binding(
                            get: { store.placesWorldContextBlocks.environmental },
                            set: { store.placesWorldContextBlocks.environmental = $0 }
                        ),
                        defaultValue: PlacesWorldContextBlocks.defaultEnvironmental
                    )
                    worldContextEditor(
                        label: "Time Period",
                        text: Binding(
                            get: { store.placesWorldContextBlocks.timePeriod },
                            set: { store.placesWorldContextBlocks.timePeriod = $0 }
                        ),
                        defaultValue: PlacesWorldContextBlocks.defaultTimePeriod
                    )
                    worldContextEditor(
                        label: "Aesthetic",
                        text: Binding(
                            get: { store.placesWorldContextBlocks.aesthetic },
                            set: { store.placesWorldContextBlocks.aesthetic = $0 }
                        ),
                        defaultValue: PlacesWorldContextBlocks.defaultAesthetic
                    )
                    HStack {
                        Spacer()
                        Button("Save") {
                            store.save(writePlaces: true)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func worldContextEditor(
        label: String,
        text: Binding<String>,
        defaultValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Reset to default") {
                    text.wrappedValue = defaultValue
                }
                .controlSize(.mini)
            }
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 110)
                .padding(4)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.white.opacity(0.08)))
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
