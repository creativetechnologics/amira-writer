import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A reusable Gemini prompt + reference-images composer.
///
/// Combines a `ResizablePromptEditor` for the prompt text with a horizontal
/// strip of reference image thumbnails. The strip is also a drag-and-drop
/// target — drop image files (or URLs from elsewhere in the app, including
/// storyboard drawings) and they're appended to the binding. Click the
/// dashed-border zone to open a file picker.
///
/// Same component is shared by Canvas and Scenes so both pages get the
/// identical drop-target / file-picker behavior.
@available(macOS 26.0, *)
struct GeminiPromptComposer: View {
    @Binding var prompt: String
    @Binding var referenceURLs: [URL]
    let promptPersistenceID: String
    let promptPlaceholder: String
    let maxReferenceCount: Int

    init(
        prompt: Binding<String>,
        referenceURLs: Binding<[URL]>,
        promptPersistenceID: String,
        promptPlaceholder: String = "Describe the image you want…",
        maxReferenceCount: Int = 8
    ) {
        self._prompt = prompt
        self._referenceURLs = referenceURLs
        self.promptPersistenceID = promptPersistenceID
        self.promptPlaceholder = promptPlaceholder
        self.maxReferenceCount = maxReferenceCount
    }

    @State private var isDropTarget = false
    /// Memo of NSImages keyed by URL. Loaded on a background thread the first
    /// time a URL appears, never re-decoded on subsequent body recomputes.
    @State private var thumbnailCache: [URL: NSImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                } label: {
                    Label("Copy Prompt", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Copy the full prompt text.")
            }

            ResizablePromptEditor(
                text: $prompt,
                persistenceID: promptPersistenceID,
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

            referencesRow
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
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                    .padding(2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let resolvedURLs = ImageMultiSelectionDragContext.resolveDroppedURLs(urls)
            appendReferenceURLs(resolvedURLs)
            return !resolvedURLs.isEmpty
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }

    private var referencesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Label("References", systemImage: "photo.on.rectangle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(referenceURLs.count)/\(maxReferenceCount)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)

                if !referenceURLs.isEmpty {
                    Button(role: .destructive) {
                        referenceURLs.removeAll()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                Button(action: addImagesViaPanel) {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 2)

            // Strip of thumbs + drop zone chip — empty state is a wide dropzone.
            if referenceURLs.isEmpty {
                dropZoneWide
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(referenceURLs.enumerated()), id: \.element) { _, url in
                            referenceThumbnail(url: url)
                        }
                        if referenceURLs.count < maxReferenceCount {
                            dropZoneChip
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var dropZoneWide: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(height: 86)
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                    Text("Drag images here — including storyboard drawings — or click Add")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            )
            .contentShape(Rectangle())
            .onTapGesture { addImagesViaPanel() }
    }

    private var dropZoneChip: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.25, dash: [6, 4]))
            .frame(width: 72, height: 72)
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            )
            .contentShape(Rectangle())
            .onTapGesture { addImagesViaPanel() }
    }

    @ViewBuilder
    private func referenceThumbnail(url: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = thumbnailCache[url] {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: url) {
                if thumbnailCache[url] != nil { return }
                let loaded = await Task.detached(priority: .userInitiated) {
                    NSImage(contentsOf: url)
                }.value
                if let loaded {
                    thumbnailCache[url] = loaded
                }
            }

            Button {
                referenceURLs.removeAll { $0 == url }
                thumbnailCache.removeValue(forKey: url)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .padding(3)
        }
        .help(url.lastPathComponent)
    }

    private func addImagesViaPanel() {
        // Defer the modal to the next runloop tick so the SwiftUI event cycle
        // that triggered this tap can complete its layout/state pass first.
        // Running the modal directly from a tap handler can cause SwiftUI to
        // miss state updates queued in the same tick.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.image]
            panel.title = "Choose Reference Images"
            guard panel.runModal() == .OK else { return }
            appendReferenceURLs(panel.urls)
        }
    }

    private func appendReferenceURLs(_ urls: [URL]) {
        let standardized = urls.map { $0.standardizedFileURL }
        for url in standardized {
            guard referenceURLs.count < maxReferenceCount else { break }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if referenceURLs.contains(url) { continue }
            referenceURLs.append(url)
        }
    }
}
