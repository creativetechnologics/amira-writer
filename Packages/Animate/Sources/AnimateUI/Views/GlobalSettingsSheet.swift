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
    @State private var showAPISettings = false
    @State private var drawThingsStatus: String?
    @State private var drawThingsStatusIcon: String = "network"

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
                title: "API Keys",
                subtitle: "Stored in the project folder (synced by Syncthing). Covers Gemini, MiniMax, Vidu, RunPod, and the Vertex AI backend."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    apiKeyStatusRow("Gemini", configured: !store.geminiAPIKey.isEmpty)
                    apiKeyStatusRow("MiniMax", configured: !store.miniMaxAPIKey.isEmpty)
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

            vertexCreditCard

            sectionCard(
                title: "Draw Things",
                subtitle: "Local Stable Diffusion server for bulk generation."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Host") {
                        TextField("http://127.0.0.1", text: Binding(
                            get: { store.drawThingsPlaceConfig.apiHost },
                            set: { newValue in
                                var updated = store.drawThingsPlaceConfig
                                updated.apiHost = newValue
                                store.updateDrawThingsPlacesConfig(updated)
                            }
                        ))
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    }
                    LabeledContent("Port") {
                        TextField("7860", value: Binding(
                            get: { store.drawThingsPlaceConfig.apiPort },
                            set: { newValue in
                                var updated = store.drawThingsPlaceConfig
                                updated.apiPort = newValue
                                store.updateDrawThingsPlacesConfig(updated)
                            }
                        ), format: IntegerFormatStyle<Int>().grouping(.never))
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                    }

                    Button {
                        checkDrawThingsConnection()
                    } label: {
                        Label(drawThingsStatus ?? "Check Connection", systemImage: drawThingsStatusIcon)
                    }
                    .controlSize(.small)
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

    private var vertexCreditCard: some View {
        let used = store.vertexCreditUsedUSD
        let budget = store.vertexCreditBudgetUSD
        let remaining = store.vertexCreditRemainingUSD
        let pct = budget > 0 ? min(max(used / budget, 0), 1) : 0
        return sectionCard(
            title: "Vertex AI free-trial credit",
            subtitle: "Google doesn't expose a live credit endpoint, so this is a local running estimate: $\(String(format: "%.2f", budget)) minus the model-estimated cost of each Gemini image the app has generated. Reset if you top up or switch accounts."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("$\(String(format: "%.2f", used)) used")
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Spacer()
                    Text("$\(String(format: "%.2f", remaining)) remaining")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(remaining > 10 ? .green : (remaining > 1 ? .orange : .red))
                }
                ProgressView(value: pct)
                    .progressViewStyle(.linear)
                    .tint(remaining > 10 ? .green : (remaining > 1 ? .orange : .red))
                Text("Budget: $\(String(format: "%.2f", budget))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack {
                    Button("Reset tracking") {
                        store.resetVertexCreditTracking()
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
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

    private func checkDrawThingsConnection() {
        drawThingsStatus = "Checking…"
        drawThingsStatusIcon = "arrow.triangle.2.circlepath"
        let config = store.drawThingsPlaceConfig
        guard var components = URLComponents(string: config.apiHost) else {
            drawThingsStatus = "Invalid host"
            drawThingsStatusIcon = "xmark.circle.fill"
            return
        }
        if components.scheme == nil { components.scheme = "http" }
        components.port = config.apiPort
        components.path = "/sdapi/v1/options"
        guard let url = components.url else {
            drawThingsStatus = "Invalid URL"
            drawThingsStatusIcon = "xmark.circle.fill"
            return
        }
        Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    drawThingsStatus = "Connected"
                    drawThingsStatusIcon = "checkmark.circle.fill"
                } else {
                    drawThingsStatus = "Error (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"
                    drawThingsStatusIcon = "xmark.circle.fill"
                }
            } catch {
                drawThingsStatus = "Offline — \(error.localizedDescription)"
                drawThingsStatusIcon = "xmark.circle.fill"
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

    // MARK: - Places

    private var placesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(
                title: "Places World Context",
                subtitle: "These context lines are pre-filled into every 3D Map camera capture draft. Delete anything you don't want before submitting the Gemini sheet. One line per idea — blank lines separate the three blocks in the final prompt."
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
