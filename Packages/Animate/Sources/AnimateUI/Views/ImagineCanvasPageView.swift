import AppKit
import ProjectKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Reference Image Model

@available(macOS 26.0, *)
struct CanvasReferenceImage: Identifiable, Sendable {
    var id: UUID = UUID()
    var url: URL
    var nsImage: NSImage
}

// MARK: - Sidebar

/// Thin sidebar listing all canvas generations (most-recent first).
@available(macOS 26.0, *)
struct CanvasSidebarView: View {
    @Bindable var store: AnimateStore

    var body: some View {
        let sorted = store.canvasGenerations.sorted { $0.createdAt > $1.createdAt }
        if sorted.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 24))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Text("No generations yet")
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(sorted) { gen in
                VStack(alignment: .leading, spacing: 2) {
                    Text(gen.prompt)
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .lineLimit(2)
                    Text("\(gen.model.displayName) · \(gen.aspectRatio) · \(gen.imageSize)")
                        .font(.system(size: 10))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
        }
    }
}

// MARK: - Main Page View

@available(macOS 26.0, *)
struct ImagineCanvasPageView: View {
    @Bindable var store: AnimateStore

    // MARK: Prompt builder state
    @State private var prompt: String = ""
    @State private var selectedModel: GeminiModel = .flash
    @State private var selectedAspectRatio: String = "3:4"
    @State private var selectedImageSize: String = "2K"

    // MARK: Reference images state
    @State private var referenceImages: [CanvasReferenceImage] = []

    // MARK: Generation state
    @State private var isGenerating: Bool = false
    @State private var errorMessage: String? = nil

    // MARK: Delete confirmation
    @State private var pendingDeleteID: UUID? = nil
    @State private var showDeleteConfirm: Bool = false

    private let aspectRatioOptions = ["1:1", "2:3", "3:4", "4:5", "4:3", "16:9", "21:9"]
    private let imageSizeOptions = ["1K", "2K", "4K"]

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                promptBuilderSection
                referenceImagesSection
                gallerySection
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectedModel = store.selectedGeminiModel
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

    // MARK: - Prompt Builder

    private var promptBuilderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Prompt", systemImage: "text.alignleft")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OperaChromeTheme.textSecondary)

            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .frame(minHeight: 80, maxHeight: 160)
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

            HStack(spacing: 12) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(GeminiModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 160)

                Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                    ForEach(aspectRatioOptions, id: \.self) { ratio in
                        Text(ratio).tag(ratio)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 80)

                Picker("Size", selection: $selectedImageSize) {
                    ForEach(imageSizeOptions, id: \.self) { size in
                        Text(size).tag(size)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 70)

                Spacer()

                if isGenerating {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }

                Button(action: generate) {
                    Label("Generate", systemImage: "sparkles")
                }
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !store.isGeminiAllowed()
                          || isGenerating)
                .buttonStyle(.borderedProminent)
            }

            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }

            if !store.isGeminiAllowed() {
                Label("Gemini is disabled. Enable it in Inspector > Tools.", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                )
        )
    }

    // MARK: - Reference Images

    private var referenceImagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Reference Images", systemImage: "photo.on.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                Spacer()
                Button(action: addReferenceImages) {
                    Label("Add Images", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if referenceImages.isEmpty {
                dropZoneView
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(referenceImages) { ref in
                            referenceImageThumbnail(ref)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                )
        )
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private var dropZoneView: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(height: 72)
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 18))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text("Drag images here or use Add Images")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }
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
                referenceImages.removeAll { $0.id == ref.id }
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

    // MARK: - Gallery

    private var gallerySection: some View {
        let sorted = store.canvasGenerations.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 10) {
            Label("Gallery (\(sorted.count))", systemImage: "square.grid.2x2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OperaChromeTheme.textSecondary)

            if sorted.isEmpty {
                Text("Generated images will appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(sorted) { gen in
                        galleryCell(gen)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func galleryCell(_ gen: AnimateStore.CanvasGeneration) -> some View {
        let imageURL = URL(fileURLWithPath: gen.imagePath)

        VStack(alignment: .leading, spacing: 6) {
            Group {
                AsyncResolvedImageView(
                    path: gen.imagePath,
                    maxPixelSize: 720,
                    contentMode: .fill
                )
                .overlay {
                    if !FileManager.default.fileExists(atPath: gen.imagePath) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.3))
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundStyle(OperaChromeTheme.textTertiary)
                            )
                    }
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(gen.prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(2)
                Text("\(gen.model.displayName) · \(gen.aspectRatio) · \(gen.imageSize)")
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
                        .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                )
        )
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([imageURL])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Button {
                if let img = NSImage(contentsOf: imageURL) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects([img])
                }
            } label: {
                Label("Copy Image", systemImage: "doc.on.doc")
            }

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(gen.prompt, forType: .string)
            } label: {
                Label("Copy Prompt", systemImage: "text.badge.plus")
            }

            Menu {
                Button("Character reference (coming soon)") {}
                Button("Place reference (coming soon)") {}
            } label: {
                Label("Send to...", systemImage: "paperplane")
            }

            Divider()

            Button(role: .destructive) {
                pendingDeleteID = gen.id
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func generate() {
        guard store.isGeminiAllowed() else {
            errorMessage = "Gemini is disabled. Enable it in Inspector > Tools."
            return
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        isGenerating = true
        errorMessage = nil

        let capturedRefs = referenceImages
        let capturedModel = selectedModel
        let capturedRatio = selectedAspectRatio
        let capturedSize = selectedImageSize
        let refCount = capturedRefs.count

        Task { @MainActor in
            do {
                let refItems: [GeminiImageService.ReferenceImage] = capturedRefs.compactMap { ref in
                    guard let tiff = ref.nsImage.tiffRepresentation,
                          let bmp = NSBitmapImageRep(data: tiff),
                          let png = bmp.representation(using: .png, properties: [:]) else { return nil }
                    return GeminiImageService.ReferenceImage(
                        data: png.base64EncodedString(),
                        mimeType: "image/png"
                    )
                }

                let request = GeminiImageService.GenerationRequest(
                    prompt: trimmedPrompt,
                    referenceImages: refItems,
                    model: capturedModel,
                    aspectRatio: capturedRatio,
                    imageSize: capturedSize
                )

                store.logGeminiAPICall(endpoint: "image-generation", source: "ImagineCanvasPageView")
                let service = GeminiImageService()
                let result = try await service.generate(request: request, apiKey: store.geminiAPIKey)

                // Write image to disk
                let gen = try saveCanvasImage(
                    data: result.imageData,
                    prompt: trimmedPrompt,
                    model: capturedModel,
                    aspectRatio: capturedRatio,
                    imageSize: capturedSize,
                    referenceCount: refCount
                )
                store.appendCanvasGeneration(gen)
                isGenerating = false
            } catch {
                errorMessage = error.localizedDescription
                isGenerating = false
            }
        }
    }

    private func saveCanvasImage(
        data: Data,
        prompt: String,
        model: GeminiModel,
        aspectRatio: String,
        imageSize: String,
        referenceCount: Int
    ) throws -> AnimateStore.CanvasGeneration {
        // Resolve canvas dir from animateURL or fallback to ~/Amira - A Modern Opera/Animate/debug/canvas/
        let canvasDir: URL
        if let animateURL = store.animateURL {
            canvasDir = animateURL.appendingPathComponent("debug/canvas")
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            canvasDir = home
                .appendingPathComponent("Amira - A Modern Opera")
                .appendingPathComponent("Animate/debug/canvas")
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: canvasDir.path) {
            try fm.createDirectory(at: canvasDir, withIntermediateDirectories: true)
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let slug = prompt
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .prefix(4)
            .joined(separator: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let filename = "\(timestamp)-\(slug).png"
        let fileURL = canvasDir.appendingPathComponent(filename)

        // Idempotency guard: skip write if file already exists with same content
        if fm.fileExists(atPath: fileURL.path),
           let existing = try? Data(contentsOf: fileURL),
           existing == data {
            // reuse existing file — find the record if it exists
        } else {
            try data.write(to: fileURL, options: .atomic)
        }

        return AnimateStore.CanvasGeneration(
            createdAt: Date(),
            prompt: prompt,
            model: model,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            imagePath: fileURL.path,
            referenceCount: referenceCount
        )
    }

    private func addReferenceImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg]
        panel.title = "Choose Reference Images"
        guard panel.runModal() == .OK else { return }
        appendReferenceURLs(panel.urls)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { self.appendReferenceURLs([url]) }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    // Drop from clipboard / drag-from-app: no file URL; skip
                    _ = obj
                }
                handled = true
            }
        }
        return handled
    }

    private func appendReferenceURLs(_ urls: [URL]) {
        for url in urls {
            guard let img = NSImage(contentsOf: url) else { continue }
            // Idempotency: don't add same URL twice
            if referenceImages.contains(where: { $0.url == url }) { continue }
            referenceImages.append(CanvasReferenceImage(url: url, nsImage: img))
        }
    }
}
