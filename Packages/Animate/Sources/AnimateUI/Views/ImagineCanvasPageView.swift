import AppKit
import ProjectKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 26.0, *)
struct CanvasReferenceImage: Identifiable, Sendable {
    var id: UUID = UUID()
    var url: URL
    var nsImage: NSImage
}

@available(macOS 26.0, *)
struct CanvasPromptDraft: Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var text: String
    var iterationCount: Int = 1

    func displayTitle(fallbackIndex: Int) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Prompt \(fallbackIndex)" : trimmed
    }
}

@available(macOS 26.0, *)
@Observable @MainActor
final class CanvasFormState {
    var promptDrafts: [CanvasPromptDraft] = [
        CanvasPromptDraft(title: "Prompt 1", text: "", iterationCount: 1)
    ] {
        didSet { refreshPromptDraftMetrics() }
    }
    var selectedModel: GeminiModel = .flash
    var selectedAspectRatio: String = UserDefaults.standard.string(forKey: "novotro.canvas.aspectRatio") ?? "3:4" {
        didSet { UserDefaults.standard.set(selectedAspectRatio, forKey: "novotro.canvas.aspectRatio") }
    }
    var selectedImageSize: String = UserDefaults.standard.string(forKey: "novotro.canvas.imageSize") ?? "2K" {
        didSet { UserDefaults.standard.set(selectedImageSize, forKey: "novotro.canvas.imageSize") }
    }
    var referenceImages: [CanvasReferenceImage] = []
    var activeGenerationJobCount = 0
    var isGenerating: Bool { activeGenerationJobCount > 0 }
    var generationProgressMessage: String? = nil
    var errorMessage: String? = nil
    var promptGeneratorText: String = ""
    var isGeneratingPrompt: Bool = false
    var promptGeneratorStatusMessage: String? = nil
    var promptGeneratorErrorMessage: String? = nil
    var promptGeneratorReferenceSummaries: [String] = []
    var filledPromptDraftCount = 0
    var totalRequestedImages = 0
    var promptDraftsRevision = 0

    var hasFilledPromptDrafts: Bool {
        filledPromptDraftCount > 0
    }

    func filledPromptDrafts() -> [CanvasPromptDraft] {
        promptDrafts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func refreshPromptDraftMetrics() {
        var filledCount = 0
        var requestedImages = 0

        for draft in promptDrafts {
            let trimmedText = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }
            filledCount += 1
            requestedImages += max(1, draft.iterationCount)
        }

        filledPromptDraftCount = filledCount
        totalRequestedImages = requestedImages
        promptDraftsRevision &+= 1
    }
}

@available(macOS 26.0, *)
struct ImagineCanvasPageView: View {
    @Bindable var store: AnimateStore
    @Bindable var canvasState: CanvasFormState
    @Bindable var libraryState: AllProjectImagesState
    @Binding var selectedGenerationID: UUID?
    @AppStorage(AnimatedLookPromptSettings.canvasToggleDefaultsKey) private var applyMasterAnimatedLookPrompt = false


    @State private var pendingDeleteID: UUID? = nil
    @State private var showDeleteConfirm = false

    @State private var showPromptImportSheet = false
    @State private var promptImportText = ""
    @State private var promptImportErrorMessage: String? = nil
    @State private var isReferenceDropTarget = false

    private let aspectRatioOptions = ["1:1", "2:3", "3:4", "4:5", "4:3", "16:9", "21:9"]
    private let imageSizeOptions = ["1K", "2K", "4K"]
    private let galleryColumns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]

    init(
        store: AnimateStore,
        canvasState: CanvasFormState,
        libraryState: AllProjectImagesState,
        selectedGenerationID: Binding<UUID?> = .constant(nil)
    ) {
        _store = Bindable(store)
        _canvasState = Bindable(canvasState)
        _libraryState = Bindable(libraryState)
        _selectedGenerationID = selectedGenerationID
    }

    private var canClearAllPrompts: Bool {
        canvasState.promptDrafts.count > 1 || canvasState.hasFilledPromptDrafts
    }

    private var bulkIterationCount: Int {
        get { min(max(canvasState.promptDrafts.first?.iterationCount ?? 1, 1), 20) }
        nonmutating set { setAllPromptIterations(newValue) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                promptBuilderSection
                referenceImagesSection
                promptGeneratorSection
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if canvasState.selectedModel != store.selectedGeminiModel {
                canvasState.selectedModel = store.selectedGeminiModel
            }
            ensurePromptDraft()
            ensureCanvasSelection()
        }
        .onChange(of: canvasGenerationSelectionSignature) { _, _ in
            ensureCanvasSelection()
        }
        .task(id: libraryState.recordsRefreshKey(store: store)) {
            libraryState.requestRebuildIfNeeded(store: store)
        }
        .sheet(isPresented: $showPromptImportSheet) {
            promptImportSheet
        }
        .alert("Delete Generation", isPresented: $showDeleteConfirm, presenting: pendingDeleteID) { id in
            Button("Delete", role: .destructive) {
                store.deleteCanvasGeneration(id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This will permanently delete the image and its metadata.")
        }
    }

    private var promptBuilderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Label("Prompts", systemImage: "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textSecondary)

                Spacer()

                Text(canvasState.totalRequestedImages == 1 ? "1 image queued" : "\(canvasState.totalRequestedImages) images queued")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            }

            Text("Import a block of prompts, tweak individual prompt boxes, and the shared reference images below will apply to every prompt in this canvas run.")
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(canvasState.promptDrafts.indices, id: \.self) { index in
                    promptDraftCard(index: index)
                }
            }

            HStack(spacing: 10) {
                Button {
                    openPromptImportSheet()
                } label: {
                    Label("Import Prompts…", systemImage: "text.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    canvasState.promptDrafts.append(
                        CanvasPromptDraft(
                            title: "Prompt \(canvasState.promptDrafts.count + 1)",
                            text: "",
                            iterationCount: canvasState.promptDrafts.last?.iterationCount ?? 1
                        )
                    )
                } label: {
                    Label("Add Prompt", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    resetPromptDrafts()
                } label: {
                    Label("Clear All Prompts", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(!canClearAllPrompts)

                Spacer()
            }

            HStack(spacing: 12) {
                Picker("Model", selection: $canvasState.selectedModel) {
                    ForEach(GeminiModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 170)

                Picker("Aspect Ratio", selection: $canvasState.selectedAspectRatio) {
                    ForEach(aspectRatioOptions, id: \.self) { ratio in
                        Text(ratio).tag(ratio)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 90)

                Picker("Size", selection: $canvasState.selectedImageSize) {
                    ForEach(imageSizeOptions, id: \.self) { size in
                        Text(size).tag(size)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 80)

                HStack(spacing: 6) {
                    Text("All Iterations")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(OperaChromeTheme.textTertiary)

                    TextField(
                        "All Iterations",
                        value: Binding(
                            get: { bulkIterationCount },
                            set: { bulkIterationCount = $0 }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)

                    Stepper(
                        "",
                        value: Binding(
                            get: { bulkIterationCount },
                            set: { bulkIterationCount = $0 }
                        ),
                        in: 1...20
                    )
                    .labelsHidden()
                }

                Spacer()

                if AnimatedLookPromptSettings.hasConfiguredMasterPrompt() {
                    Toggle("Animated Look", isOn: $applyMasterAnimatedLookPrompt)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("Prepends the master animated-look prompt to every Canvas generation request.")
                }

                if canvasState.isGenerating {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }

                Button(action: generate) {
                    Label(canvasState.totalRequestedImages <= 1 ? "Generate" : "Generate \(canvasState.totalRequestedImages)", systemImage: "sparkles")
                }
                .disabled(!canvasState.hasFilledPromptDrafts || !store.isGeminiAllowed())
                .buttonStyle(.borderedProminent)
            }

            if let progressMessage = canvasState.generationProgressMessage {
                Label(progressMessage, systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }

            if let err = canvasState.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.isGeminiAllowed() {
                Label("Gemini is disabled. Enable it in Inspector > Tools.", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    @ViewBuilder
    private func promptDraftCard(index: Int) -> some View {
        let draft = canvasState.promptDrafts[index]
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(draft.displayTitle(fallbackIndex: index + 1))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textSecondary)

                Spacer()

                Text("Iterations")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(OperaChromeTheme.textTertiary)

                TextField(
                    "Iterations",
                    value: $canvasState.promptDrafts[index].iterationCount,
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 46)

                Stepper(
                    "",
                    value: $canvasState.promptDrafts[index].iterationCount,
                    in: 1...20
                )
                .labelsHidden()

                if canvasState.promptDrafts.count > 1 {
                    Button(role: .destructive) {
                        canvasState.promptDrafts.remove(at: index)
                        ensurePromptDraft()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("Remove this prompt")
                }
            }

            ResizablePromptEditor(
                text: $canvasState.promptDrafts[index].text,
                persistenceID: "canvas.promptDraft",
                minHeight: 88,
                defaultHeight: 130
            )
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private var referenceImagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Reference Images", systemImage: "photo.on.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text("These references apply to every prompt box above.")
                        .font(.system(size: 10))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }
                Spacer()
                if !canvasState.referenceImages.isEmpty {
                    Button(role: .destructive) {
                        canvasState.referenceImages.removeAll()
                    } label: {
                        Label("Clear References", systemImage: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(action: addReferenceImages) {
                    Label("Add Images", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if canvasState.referenceImages.isEmpty {
                dropZoneView
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(canvasState.referenceImages) { ref in
                            referenceImageThumbnail(ref)
                        }
                        dropZoneChip
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay {
            if isReferenceDropTarget {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                    .padding(4)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let resolvedURLs = ImageMultiSelectionDragContext.resolveDroppedURLs(urls)
            appendReferenceURLs(resolvedURLs)
            return !resolvedURLs.isEmpty
        } isTargeted: { isTargeted in
            isReferenceDropTarget = isTargeted
        }
    }

    private var dropZoneView: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(height: 86)
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 18))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text("Drag images here from All Images or use Add Images")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }
            )
    }

    private var dropZoneChip: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.25, dash: [6, 4]))
            .frame(width: 72, height: 72)
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            )
    }

    @ViewBuilder
    private func referenceImageThumbnail(_ ref: CanvasReferenceImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: ref.nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Button {
                canvasState.referenceImages.removeAll { $0.id == ref.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .padding(3)
        }
    }

    private var promptGeneratorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Prompt Generator", systemImage: "wand.and.stars")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text("Plain English in; MiniMax writes the Canvas prompt and attaches eligible rated references.")
                        .font(.system(size: 10))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }

                Spacer()

                if canvasState.isGeneratingPrompt {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }

                Button {
                    generatePromptWithMiniMax()
                } label: {
                    Label("Generate Prompt", systemImage: "sparkles")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(canvasState.isGeneratingPrompt || canvasState.promptGeneratorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextEditor(text: $canvasState.promptGeneratorText)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            if !canvasState.promptGeneratorReferenceSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Attached by Prompt Generator")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    ForEach(Array(canvasState.promptGeneratorReferenceSummaries.prefix(8).enumerated()), id: \.offset) { _, summary in
                        Text("• \(summary)")
                            .font(.system(size: 10))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            if let message = canvasState.promptGeneratorStatusMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }

            if let message = canvasState.promptGeneratorErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var gallerySection: some View {
        let sorted = store.canvasGenerationsNewestFirst()
        return VStack(alignment: .leading, spacing: 10) {
            Label("Canvas Gallery (\(sorted.count))", systemImage: "square.grid.2x2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OperaChromeTheme.textSecondary)

            if sorted.isEmpty {
                Text("Generated images will appear here and in All Images.")
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: galleryColumns, spacing: 12) {
                    ForEach(sorted) { generation in
                        galleryCell(generation)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func galleryCell(_ generation: AnimateStore.CanvasGeneration) -> some View {
        let imageURL = URL(fileURLWithPath: generation.imagePath)
        let isSelected = selectedGenerationID == generation.id

        VStack(alignment: .leading, spacing: 6) {
            AsyncResolvedImageView(
                path: generation.imagePath,
                maxPixelSize: 720,
                contentMode: .fill
            )
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(generation.prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(3)
                Text("\(generation.model.displayName) · \(generation.aspectRatio) · \(generation.imageSize)")
                    .font(.system(size: 10))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.4),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedGenerationID = generation.id
        }
        .draggable(imageURL)
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([imageURL])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Button {
                copyImageToPasteboardAsync(path: generation.imagePath)
            } label: {
                Label("Copy Image", systemImage: "doc.on.doc")
            }

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(generation.prompt, forType: .string)
            } label: {
                Label("Copy Prompt", systemImage: "text.badge.plus")
            }

            Divider()

            Button(role: .destructive) {
                pendingDeleteID = generation.id
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var promptImportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Prompts")
                .font(.system(size: 16, weight: .semibold))
            Text("Paste a block like #Prompt 1 / prompt body / #Prompt 2 / prompt body, then populate the canvas prompt boxes.")
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $promptImportText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.8))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            if let promptImportErrorMessage {
                Label(promptImportErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showPromptImportSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Populate Prompts") {
                    populateImportedPrompts()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
    }

    private struct CanvasGenerationSelectionSignature: Equatable {
        var revision: Int
    }

    private var canvasGenerationSelectionSignature: CanvasGenerationSelectionSignature {
        CanvasGenerationSelectionSignature(revision: store.canvasGenerationsRevision)
    }

    private func ensurePromptDraft() {
        if canvasState.promptDrafts.isEmpty {
            canvasState.promptDrafts = [CanvasPromptDraft(title: "Prompt 1", text: "", iterationCount: 1)]
        }
        for index in canvasState.promptDrafts.indices {
            canvasState.promptDrafts[index].iterationCount = min(max(canvasState.promptDrafts[index].iterationCount, 1), 20)
            if canvasState.promptDrafts[index].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                canvasState.promptDrafts[index].title = "Prompt \(index + 1)"
            }
        }
    }

    private func resetPromptDrafts() {
        canvasState.promptDrafts = [CanvasPromptDraft(title: "Prompt 1", text: "", iterationCount: 1)]
        canvasState.errorMessage = nil
        canvasState.generationProgressMessage = nil
    }

    private func ensureCanvasSelection() {
        let sorted = store.canvasGenerationsNewestFirst()
        guard !sorted.isEmpty else {
            selectedGenerationID = nil
            return
        }
        if let selectedGenerationID,
           sorted.contains(where: { $0.id == selectedGenerationID }) {
            return
        }
        self.selectedGenerationID = sorted.first?.id
    }

    private func openPromptImportSheet() {
        promptImportText = serializedPromptDrafts()
        promptImportErrorMessage = nil
        showPromptImportSheet = true
    }

    private func serializedPromptDrafts() -> String {
        canvasState.promptDrafts.enumerated().map { index, draft in
            let title = draft.displayTitle(fallbackIndex: index + 1)
            let body = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "#\(title)\n\(body)"
        }
        .joined(separator: "\n\n")
    }

    private func populateImportedPrompts() {
        let defaultIterations = bulkIterationCount
        let imported = parseImportedPrompts(promptImportText, defaultIterations: defaultIterations)
        guard !imported.isEmpty else {
            promptImportErrorMessage = "No prompt blocks were found. Use lines that start with #Prompt (or another # header) followed by the prompt text."
            return
        }
        canvasState.promptDrafts = imported
        ensurePromptDraft()
        promptImportErrorMessage = nil
        showPromptImportSheet = false
    }

    private func parseImportedPrompts(_ rawText: String, defaultIterations: Int) -> [CanvasPromptDraft] {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        struct ParsedBlock {
            var title: String
            var body: String
        }

        var blocks: [ParsedBlock] = []
        var currentTitle: String? = nil
        var currentLines: [String] = []

        func commitCurrentBlock() {
            let body = currentLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentTitle != nil || !body.isEmpty else {
                currentLines = []
                return
            }
            let fallbackTitle = "Prompt \(blocks.count + 1)"
            let title = currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = (title?.isEmpty == false ? title! : fallbackTitle)
            let resolvedBody = body
            guard !resolvedBody.isEmpty else {
                currentLines = []
                currentTitle = nil
                return
            }
            blocks.append(ParsedBlock(title: resolvedTitle, body: resolvedBody))
            currentTitle = nil
            currentLines = []
        }

        for line in lines {
            if let header = parsePromptHeader(line) {
                commitCurrentBlock()
                currentTitle = header.title
                if let inlinePrompt = header.inlinePrompt,
                   !inlinePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    currentLines = [inlinePrompt]
                } else {
                    currentLines = []
                }
            } else {
                currentLines.append(line)
            }
        }
        commitCurrentBlock()

        if blocks.isEmpty {
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [CanvasPromptDraft(title: "Prompt 1", text: trimmed, iterationCount: defaultIterations)]
        }

        return blocks.enumerated().map { index, block in
            CanvasPromptDraft(
                title: block.title.isEmpty ? "Prompt \(index + 1)" : block.title,
                text: block.body,
                iterationCount: defaultIterations
            )
        }
    }

    private func parsePromptHeader(_ line: String) -> (title: String, inlinePrompt: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }

        let content = trimmed.drop { $0 == "#" || $0 == " " || $0 == "\t" }
        let remainder = String(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }

        for separator in [":", "—", "–"] {
            if let range = remainder.range(of: separator) {
                let title = remainder[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let inlinePrompt = remainder[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    title.isEmpty ? remainder : title,
                    inlinePrompt.isEmpty ? nil : String(inlinePrompt)
                )
            }
        }

        return (remainder, nil)
    }

    private func generatePromptWithMiniMax() {
        let brief = canvasState.promptGeneratorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else {
            canvasState.promptGeneratorErrorMessage = "Enter what you want first."
            return
        }
        guard let projectRoot = store.fileOWPURL else {
            canvasState.promptGeneratorErrorMessage = "Open a project before using Prompt Generator."
            return
        }

        canvasState.isGeneratingPrompt = true
        canvasState.promptGeneratorErrorMessage = nil
        canvasState.promptGeneratorStatusMessage = "MiniMax is building a prompt and choosing references…"
        canvasState.promptGeneratorReferenceSummaries = []
        store.statusMessage = "MiniMax Prompt Generator is working…"

        let request = CanvasPromptGeneratorService.Request(
            userBrief: brief,
            projectRoot: projectRoot,
            worldContext: store.placesWorldContextBlocks,
            animatedLookPrompt: AnimatedLookPromptSettings.loadMasterPrompt(),
            records: libraryState.cachedAllRecords,
            apiKey: store.miniMaxAPIKey,
            maxReferences: 8
        )

        Task { @MainActor in
            defer {
                canvasState.isGeneratingPrompt = false
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await CanvasPromptGeneratorService().generate(request)
                }.value
                ensurePromptDraft()
                let targetIndex = canvasState.promptDrafts.firstIndex {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } ?? 0
                if canvasState.promptDrafts.indices.contains(targetIndex) {
                    canvasState.promptDrafts[targetIndex].title = "Prompt Generator"
                    canvasState.promptDrafts[targetIndex].text = result.prompt
                } else {
                    canvasState.promptDrafts.append(CanvasPromptDraft(title: "Prompt Generator", text: result.prompt, iterationCount: bulkIterationCount))
                }
                if AnimatedLookPromptSettings.hasConfiguredMasterPrompt() {
                    applyMasterAnimatedLookPrompt = true
                }
                let urls = result.referencePaths.map { URL(fileURLWithPath: $0) }
                appendReferenceURLs(urls)
                canvasState.promptGeneratorReferenceSummaries = result.referenceSummaries
                let refSummary = result.referencePaths.isEmpty ? "No eligible rated references were found." : "Attached \(result.referencePaths.count) reference\(result.referencePaths.count == 1 ? "" : "s")."
                canvasState.promptGeneratorStatusMessage = "\(refSummary) Prompt filled in Prompt \(targetIndex + 1)."
                canvasState.promptGeneratorErrorMessage = result.warning
                store.statusMessage = "MiniMax filled a Canvas prompt"
            } catch {
                canvasState.promptGeneratorStatusMessage = nil
                canvasState.promptGeneratorErrorMessage = error.localizedDescription
                store.statusMessage = "MiniMax Prompt Generator failed"
            }
        }
    }

    private func generate() {
        if let error = store.geminiImageGenerationAvailabilityError {
            canvasState.errorMessage = error.localizedDescription
            return
        }

        let queuedPrompts = canvasState.filledPromptDrafts()
        guard !queuedPrompts.isEmpty else { return }

        canvasState.activeGenerationJobCount += 1
        canvasState.errorMessage = nil
        canvasState.generationProgressMessage = nil

        let capturedRefs = canvasState.referenceImages
        let capturedModel = canvasState.selectedModel
        let capturedRatio = canvasState.selectedAspectRatio
        let capturedSize = canvasState.selectedImageSize
        let capturedApplyMasterPrompt = applyMasterAnimatedLookPrompt
        var queuedJobs: [(draft: CanvasPromptDraft, finalPrompt: String, iteration: Int, iterations: Int, activityID: UUID)] = []
        for draft in queuedPrompts {
            let trimmedPrompt = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalPrompt = AnimatedLookPromptSettings.compose(
                basePrompt: trimmedPrompt,
                includeMasterPrompt: capturedApplyMasterPrompt
            )
            let iterations = max(1, draft.iterationCount)
            for iteration in 1...iterations {
                let activityTitle = iterations == 1
                    ? draft.displayTitle(fallbackIndex: 1)
                    : "\(draft.displayTitle(fallbackIndex: 1)) • \(iteration)/\(iterations)"
                let activityID = store.registerGeminiActivity(
                    kind: .immediate,
                    title: activityTitle,
                    source: "Canvas"
                )
                queuedJobs.append((draft, finalPrompt, iteration, iterations, activityID))
            }
        }
        let totalRequests = queuedJobs.count

        Task { @MainActor in
            defer {
                canvasState.activeGenerationJobCount = max(0, canvasState.activeGenerationJobCount - 1)
                if !canvasState.isGenerating {
                    canvasState.generationProgressMessage = nil
                }
            }
            let service = GeminiImageService()
            let refItems = await buildReferenceItems(from: capturedRefs)
            var finishedCount = 0
            var requestIndex = 0
            var encounteredError: String? = nil

            generationLoop: for job in queuedJobs {
                requestIndex += 1
                canvasState.generationProgressMessage = "Generating \(requestIndex) of \(totalRequests)"
                store.updateGeminiActivity(job.activityID, status: .running)
                let request = GeminiImageService.GenerationRequest(
                    prompt: job.finalPrompt,
                    referenceImages: refItems,
                    model: capturedModel,
                    aspectRatio: capturedRatio,
                    imageSize: capturedSize
                )
                store.logGeminiAPICall(endpoint: "image-generation", source: "ImagineCanvasPageView")

                do {
                    let result = try await service.generate(request: request, apiKey: store.geminiAPIKey)
                    let generation = try await saveCanvasImage(
                        data: result.imageData,
                        prompt: job.finalPrompt,
                        model: capturedModel,
                        aspectRatio: capturedRatio,
                        imageSize: capturedSize,
                        referenceCount: capturedRefs.count,
                        referencePaths: capturedRefs.map { $0.url.path }
                    )
                    store.appendCanvasGeneration(generation)
                    selectedGenerationID = generation.id
                    store.updateGeminiActivity(
                        job.activityID,
                        status: .completed,
                        outputFilename: URL(fileURLWithPath: generation.imagePath).lastPathComponent
                    )
                    finishedCount += 1
                } catch {
                    store.updateGeminiActivity(
                        job.activityID,
                        status: .failed,
                        errorMessage: error.localizedDescription
                    )
                    encounteredError = error.localizedDescription
                    break generationLoop
                }
            }

            if finishedCount > 0 {
                store.statusMessage = "Generated \(finishedCount) canvas image\(finishedCount == 1 ? "" : "s")"
            }
            canvasState.errorMessage = encounteredError
        }
    }

    private func buildReferenceItems(from references: [CanvasReferenceImage]) async -> [GeminiImageService.ReferenceImage] {
        await Task.detached(priority: .userInitiated) {
            references.compactMap { ref in
                GeminiImageService.referenceImage(from: ref.url)
            }
        }.value
    }

    private func saveCanvasImage(
        data: Data,
        prompt: String,
        model: GeminiModel,
        aspectRatio: String,
        imageSize: String,
        referenceCount: Int,
        referencePaths: [String]
    ) async throws -> AnimateStore.CanvasGeneration {
        let canvasDir: URL
        if let animateURL = store.animateURL {
            canvasDir = ProjectPaths(root: animateURL.deletingLastPathComponent()).animateCanvasDir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            canvasDir = home
                .appendingPathComponent("Amira - A Modern Opera")
                .appendingPathComponent("Canvas")
        }

        return try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: canvasDir.path) {
                try fileManager.createDirectory(at: canvasDir, withIntermediateDirectories: true)
            }

            let slug = prompt
                .lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .prefix(6)
                .joined(separator: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let uniqueSuffix = String(UUID().uuidString.prefix(8)).lowercased()
            let filename = "\(timestamp)-\(slug.isEmpty ? "canvas" : slug)-\(uniqueSuffix).png"
            let fileURL = canvasDir.appendingPathComponent(filename)
            try data.write(to: fileURL, options: .atomic)
            let cleanedReferencePaths = referencePaths
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let requestPayload: [String: Any] = [
                "prompt": prompt,
                "model_alias": model.displayName,
                "model": model.rawValue,
                "image_size": imageSize,
                "aspect_ratio": aspectRatio,
                "referencePaths": cleanedReferencePaths,
                "reference_paths": cleanedReferencePaths
            ]
            let metadataPayload: [String: Any] = ["request": requestPayload]
            let metadataData = try JSONSerialization.data(withJSONObject: metadataPayload, options: [.prettyPrinted, .sortedKeys])
            try metadataData.write(to: fileURL.deletingPathExtension().appendingPathExtension("json"), options: .atomic)

            return AnimateStore.CanvasGeneration(
                createdAt: Date(),
                prompt: prompt,
                model: model,
                aspectRatio: aspectRatio,
                imageSize: imageSize,
                imagePath: fileURL.path,
                referenceCount: referenceCount
            )
        }.value
    }

    private func addReferenceImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.title = "Choose Reference Images"
        guard panel.runModal() == .OK else { return }
        appendReferenceURLs(panel.urls)
    }

    private func appendReferenceURLs(_ urls: [URL]) {
        let validURLs = AnimateStore.filterImportableImageURLs(urls)
        Task { @MainActor in
            for url in validURLs {
                if canvasState.referenceImages.contains(where: { $0.url == url }) { continue }
                var image = await loadSharedPreviewImage(at: url.path, maxPixelSize: 256)
                if image == nil {
                    image = await Task.detached(priority: .utility) {
                        NSImage(contentsOf: url)
                    }.value
                }
                guard let image else { continue }
                if canvasState.referenceImages.contains(where: { $0.url == url }) { continue }
                canvasState.referenceImages.append(CanvasReferenceImage(url: url, nsImage: image))
            }
        }
    }

    private func setAllPromptIterations(_ value: Int) {
        let clamped = min(max(value, 1), 20)
        for index in canvasState.promptDrafts.indices {
            canvasState.promptDrafts[index].iterationCount = clamped
        }
    }
}
