import SwiftUI

@available(macOS 26.0, *)
struct TemplateBrowserView: View {
    @Bindable var store: ScoreStore
    @Environment(\.dismiss) private var dismiss

    @State private var templates: [ScoreTemplate] = []
    @State private var selectedTemplateID: UUID?
    @State private var showingSaveSheet = false
    @State private var newTemplateName = ""

    private var selectedTemplate: ScoreTemplate? {
        templates.first(where: { $0.id == selectedTemplateID })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Score Templates")
                    .font(.headline)
                Spacer()
                Button("Save Current as Template") {
                    newTemplateName = ""
                    showingSaveSheet = true
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Template list
            HSplitView {
                List(templates, selection: $selectedTemplateID) { template in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                                .font(.body.weight(.medium))
                            Text("\(template.tracks.count) tracks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if TemplateManager.builtInTemplates.contains(where: { $0.name == template.name }) {
                            Text("Built-in")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(template.id)
                    .padding(.vertical, 2)
                }
                .frame(minWidth: 200, idealWidth: 250)

                // Preview panel
                if let template = selectedTemplate {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(template.name)
                            .font(.title2.weight(.semibold))

                        HStack(spacing: 16) {
                            Label("\(Int(template.tempo)) BPM", systemImage: "metronome")
                            Label("\(template.timeSignatureNumerator)/\(template.timeSignatureDenominator)", systemImage: "music.note")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                        Divider()

                        Text("Tracks")
                            .font(.headline)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(template.tracks) { track in
                                    HStack(spacing: 8) {
                                        if let hex = track.colorHex {
                                            Circle()
                                                .fill(Color(hex: hex))
                                                .frame(width: 10, height: 10)
                                        }
                                        Text(track.name)
                                            .font(.body)
                                        if let inst = track.instrumentName, inst != track.name {
                                            Text("(\(inst))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        Spacer()

                        HStack {
                            if !TemplateManager.builtInTemplates.contains(where: { $0.name == template.name }) {
                                Button("Delete", role: .destructive) {
                                    _ = TemplateManager.shared.deleteTemplate(name: template.name)
                                    loadTemplates()
                                }
                                .buttonStyle(.bordered)
                            }
                            Spacer()
                            Button("Apply Template") {
                                TemplateManager.shared.applyTemplate(template, to: store)
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    .frame(minWidth: 300)
                } else {
                    VStack {
                        Spacer()
                        Text("Select a template to preview")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(minWidth: 300)
                }
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { loadTemplates() }
        .sheet(isPresented: $showingSaveSheet) {
            VStack(spacing: 16) {
                Text("Save Template")
                    .font(.headline)
                TextField("Template name", text: $newTemplateName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                HStack {
                    Button("Cancel") { showingSaveSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") {
                        guard !newTemplateName.isEmpty else { return }
                        do {
                            try TemplateManager.shared.saveTemplate(name: newTemplateName, from: store)
                            showingSaveSheet = false
                            loadTemplates()
                        } catch {
                            store.statusMessage = "Failed to save template: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newTemplateName.isEmpty)
                }
            }
            .padding()
            .frame(width: 350)
        }
    }

    private func loadTemplates() {
        templates = TemplateManager.shared.listTemplates()
        if selectedTemplateID == nil {
            selectedTemplateID = templates.first?.id
        }
    }
}

