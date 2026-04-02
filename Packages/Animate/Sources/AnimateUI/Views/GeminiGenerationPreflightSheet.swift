import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct GeminiGenerationReferenceDraft: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var label: String
    var path: String
    var isIncluded: Bool = true
}

@available(macOS 26.0, *)
struct GeminiGenerationDraft: Identifiable, Hashable, Sendable {
    enum PricingMode: Hashable, Sendable {
        case standard
        case batch
    }

    var id: UUID = UUID()
    var title: String
    var destinationDescription: String
    var prompt: String
    var contextNote: String? = nil
    var model: GeminiModel
    var aspectRatio: String
    var imageSize: String
    var referenceItems: [GeminiGenerationReferenceDraft]
    var pricingMode: PricingMode = .standard

    var estimatedCost: Double {
        switch pricingMode {
        case .standard:
            model.estimatedCost(for: imageSize)
        case .batch:
            model.estimatedBatchCost(for: imageSize)
        }
    }

    var includedReferenceItems: [GeminiGenerationReferenceDraft] {
        referenceItems.filter(\.isIncluded)
    }
}

@available(macOS 26.0, *)
struct GeminiGenerationPreflightSheet: View {
    let store: AnimateStore
    @Binding var drafts: [GeminiGenerationDraft]
    let title: String
    let confirmTitle: String
    let onConfirm: ([GeminiGenerationDraft], GeminiGenerationDraft.PricingMode) -> Void
    let onCancel: () -> Void

    @State private var selectedMode: GeminiGenerationDraft.PricingMode = .standard

    private let aspectRatioOptions = ["1:1", "3:4", "4:3", "16:9", "21:9"]
    private let imageSizeOptions = ["1K", "2K", "4K"]

    private var usesSharedConfiguration: Bool {
        drafts.count > 1
    }

    private var totalCost: Double {
        drafts.reduce(0) { $0 + $1.estimatedCost }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard

                    if usesSharedConfiguration {
                        sharedConfigurationCard
                    }

                    ForEach($drafts) { $draft in
                        if usesSharedConfiguration {
                            promptOnlyRequestCard($draft)
                        } else {
                            requestCard($draft)
                        }
                    }
                }
                .padding()
            }

            Divider()

            footer
        }
        .frame(minWidth: 960, minHeight: 720)
        .onAppear {
            if let first = drafts.first {
                selectedMode = first.pricingMode
            }
        }
        .onChange(of: selectedMode) { _, newMode in
            for index in drafts.indices {
                drafts[index].pricingMode = newMode
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(
                    usesSharedConfiguration
                        ? "Preview the shared Nano Banana configuration once at the top, then review each prompt and cost below."
                        : "Preview every Nano Banana request before it is sent. You can override prompts, reference images, model, aspect ratio, and size here."
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("\(drafts.count) request\(drafts.count == 1 ? "" : "s")", systemImage: "sparkles.rectangle.stack")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.22), in: Capsule())
        }
        .padding()
    }

    private var summaryCard: some View {
        HStack(spacing: 16) {
            preflightMetric(title: "Total Estimated Cost", value: "$\(String(format: "%.3f", totalCost))", icon: "creditcard.fill", tint: .orange)
            preflightMetric(title: "Models", value: drafts.map(\.model.displayName).joined(separator: ", "), icon: "cpu", tint: .purple)
            preflightMetric(title: "Sizes", value: Set(drafts.map(\.imageSize)).sorted().joined(separator: ", "), icon: "arrow.up.left.and.arrow.down.right", tint: .blue)
        }
        .padding(14)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var sharedConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shared Configuration")
                .font(.headline)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Model", selection: sharedModelBinding) {
                        ForEach(GeminiModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Aspect Ratio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Aspect Ratio", selection: sharedAspectRatioBinding) {
                        ForEach(aspectRatioOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 150)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Image Size", selection: sharedImageSizeBinding) {
                        ForEach(imageSizeOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 120)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Reference Images")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addSharedReferenceImages()
                    } label: {
                        Label("Add Image", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if sharedReferenceItems.isEmpty {
                    Text("No references selected.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(sharedReferenceItems.indices, id: \.self) { index in
                                sharedReferenceCard(reference: sharedReferenceBinding(at: index))
                                    .frame(width: 140)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func preflightMetric(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requestCard(_ draft: Binding<GeminiGenerationDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.wrappedValue.title)
                        .font(.headline)
                    Text(draft.wrappedValue.destinationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let contextNote = draft.wrappedValue.contextNote, !contextNote.isEmpty {
                        Text(contextNote)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("$\(String(format: "%.3f", draft.wrappedValue.estimatedCost))")
                        .font(.headline)
                    Text("\(draft.wrappedValue.imageSize) • \(draft.wrappedValue.aspectRatio)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: draft.prompt)
                    .font(.callout)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.quaternary.opacity(0.4))
                    }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Model", selection: draft.model) {
                        ForEach(GeminiModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Aspect Ratio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Aspect Ratio", selection: draft.aspectRatio) {
                        ForEach(aspectRatioOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 150)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Image Size", selection: draft.imageSize) {
                        ForEach(imageSizeOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 120)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Reference Images")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addReferenceImages(to: draft.wrappedValue.id)
                    } label: {
                        Label("Add Image", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if draft.wrappedValue.referenceItems.isEmpty {
                    Text("No references selected.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(draft.referenceItems.indices, id: \.self) { index in
                                referenceCard(reference: draft.referenceItems[index], draftID: draft.wrappedValue.id)
                                    .frame(width: 140)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func promptOnlyRequestCard(_ draft: Binding<GeminiGenerationDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.wrappedValue.title)
                        .font(.headline)
                    Text(draft.wrappedValue.destinationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let contextNote = draft.wrappedValue.contextNote, !contextNote.isEmpty {
                        Text(contextNote)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("$\(String(format: "%.3f", draft.wrappedValue.estimatedCost))")
                        .font(.headline)
                    Text("\(drafts.first?.imageSize ?? draft.wrappedValue.imageSize) • \(drafts.first?.aspectRatio ?? draft.wrappedValue.aspectRatio)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: draft.prompt)
                    .font(.callout)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.quaternary.opacity(0.4))
                    }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func referenceCard(
        reference: Binding<GeminiGenerationReferenceDraft>,
        draftID: UUID
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            referenceThumbnail(path: reference.wrappedValue.path)
                .overlay(alignment: .topTrailing) {
                    Button {
                        removeReference(reference.wrappedValue.id, from: draftID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary, .thinMaterial)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }

            Toggle(isOn: reference.isIncluded) {
                Text(reference.wrappedValue.label)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.checkbox)
        }
        .padding(10)
        .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(reference.wrappedValue.isIncluded ? Color.accentColor : Color.secondary, lineWidth: 1)
        }
    }

    private func sharedReferenceCard(
        reference: Binding<GeminiGenerationReferenceDraft>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            referenceThumbnail(path: reference.wrappedValue.path)
                .overlay(alignment: .topTrailing) {
                    Button {
                        removeSharedReference(reference.wrappedValue.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary, .thinMaterial)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }

            Toggle(isOn: reference.isIncluded) {
                Text(reference.wrappedValue.label)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.checkbox)
        }
        .padding(10)
        .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(reference.wrappedValue.isIncluded ? Color.accentColor : Color.secondary, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func referenceThumbnail(path: String) -> some View {
        if let image = store.thumbnailImage(for: path, maxSize: 120) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let absURL = resolvedAbsoluteURL(for: path),
                  let image = store.thumbnailImage(for: absURL.path, maxSize: 120) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.25))
                .frame(width: 120, height: 120)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var footer: some View {
        HStack {
            if store.geminiAPIKey.isEmpty {
                Label("Set a Gemini API key before generating.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            Spacer()

            Picker("Mode", selection: $selectedMode) {
                Label("Generate Now", systemImage: "bolt.fill")
                    .tag(GeminiGenerationDraft.PricingMode.standard)
                Label("Add to Batch", systemImage: "tray.and.arrow.down.fill")
                    .tag(GeminiGenerationDraft.PricingMode.batch)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .help(selectedMode == .standard
                  ? "Send requests immediately at standard pricing"
                  : "Add requests to the batch queue for submission from the inspector")

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button(selectedMode == .standard ? confirmTitle : "Add to Queue") {
                onConfirm(drafts, selectedMode)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.geminiAPIKey.isEmpty || drafts.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var sharedModelBinding: Binding<GeminiModel> {
        Binding(
            get: { drafts.first?.model ?? .flash },
            set: { newValue in
                for index in drafts.indices {
                    drafts[index].model = newValue
                }
            }
        )
    }

    private var sharedAspectRatioBinding: Binding<String> {
        Binding(
            get: { drafts.first?.aspectRatio ?? aspectRatioOptions.first ?? "1:1" },
            set: { newValue in
                for index in drafts.indices {
                    drafts[index].aspectRatio = newValue
                }
            }
        )
    }

    private var sharedImageSizeBinding: Binding<String> {
        Binding(
            get: { drafts.first?.imageSize ?? imageSizeOptions.first ?? "1K" },
            set: { newValue in
                for index in drafts.indices {
                    drafts[index].imageSize = newValue
                }
            }
        )
    }

    private var sharedReferenceItems: [GeminiGenerationReferenceDraft] {
        drafts.first?.referenceItems ?? []
    }

    private func sharedReferenceBinding(at index: Int) -> Binding<GeminiGenerationReferenceDraft> {
        Binding(
            get: { sharedReferenceItems[index] },
            set: { newValue in
                for draftIndex in drafts.indices where drafts[draftIndex].referenceItems.indices.contains(index) {
                    drafts[draftIndex].referenceItems[index] = newValue
                }
            }
        )
    }

    private func addReferenceImages(to draftID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Add Reference Images"
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }

        guard let draftIndex = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        for url in panel.urls {
            let item = GeminiGenerationReferenceDraft(
                label: url.deletingPathExtension().lastPathComponent,
                path: url.path,
                isIncluded: true
            )
            drafts[draftIndex].referenceItems.append(item)
        }
    }

    private func addSharedReferenceImages() {
        let panel = NSOpenPanel()
        panel.title = "Add Reference Images"
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            let item = GeminiGenerationReferenceDraft(
                label: url.deletingPathExtension().lastPathComponent,
                path: url.path,
                isIncluded: true
            )
            for draftIndex in drafts.indices {
                drafts[draftIndex].referenceItems.append(item)
            }
        }
    }

    private func removeReference(_ referenceID: UUID, from draftID: UUID) {
        guard let draftIndex = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[draftIndex].referenceItems.removeAll { $0.id == referenceID }
    }

    private func removeSharedReference(_ referenceID: UUID) {
        for draftIndex in drafts.indices {
            drafts[draftIndex].referenceItems.removeAll { $0.id == referenceID }
        }
    }

    private func resolvedAbsoluteURL(for path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
