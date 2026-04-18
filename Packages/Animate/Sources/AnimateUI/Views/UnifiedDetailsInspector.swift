import AppKit
import ImageIO
import SwiftUI

@available(macOS 26.0, *)
struct SharedInspectorTabItem<Value: Hashable & Identifiable>: Identifiable {
    let value: Value
    let title: String
    let systemImage: String

    var id: Value.ID { value.id }
}

@available(macOS 26.0, *)
struct SharedInspectorTabBar<Value: Hashable & Identifiable>: View {
    @Binding var selection: Value
    let items: [SharedInspectorTabItem<Value>]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    selection = item.value
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                        .font(.caption)
                        .fontWeight(selection == item.value ? .semibold : .regular)
                        .foregroundStyle(selection == item.value ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .padding(.horizontal, 10)
                        .background(
                            selection == item.value
                                ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                                : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Protocol

@available(macOS 26.0, *)
@MainActor
protocol DetailedImageSelection {
    var imageURL: URL? { get }
    var title: String { get }
    var subtitle: String? { get }
    var rating: Int? { get }
    var isRejected: Bool { get }
    var notes: String { get }
    var metadataRows: [(label: String, value: String)] { get }
    var emptyStateMessage: String { get }
    var supportsRating: Bool { get }
    var supportsNotes: Bool { get }

    func setRating(_ newValue: Int?)
    func toggleRejected()
    func setNotes(_ newValue: String)
}

@available(macOS 26.0, *)
extension DetailedImageSelection {
    var supportsRating: Bool { true }
    var supportsNotes: Bool { true }
}

// MARK: - Shared View

@available(macOS 26.0, *)
struct UnifiedDetailsInspectorSection<Selection: DetailedImageSelection, ExtraActions: View>: View {
    let selection: Selection
    @ViewBuilder let extraActions: () -> ExtraActions

    // Persisted committed height — only written on drag end so an
    // @AppStorage-driven invalidation loop can't jitter the preview during
    // live drags.
    @AppStorage("animate.details.previewHeight") private var persistedPreviewHeight: Double = 240
    // Live height used for rendering during a drag; seeded from persistence
    // on first appear and whenever the persisted value changes.
    @State private var previewHeight: Double = 240
    @State private var isDragging = false
    @State private var dragStartHeight: Double?
    @State private var loadedImage: NSImage?
    @State private var loadedImageURL: URL?

    private let minPreviewHeight: CGFloat = 140
    private let maxPreviewHeight: CGFloat = 1200

    init(selection: Selection, @ViewBuilder extraActions: @escaping () -> ExtraActions) {
        self.selection = selection
        self.extraActions = extraActions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Details", systemImage: "info.circle")
                .font(.headline)

            if selection.imageURL != nil {
                previewCard
                if selection.supportsRating {
                    ratingSection
                }
                if selection.supportsNotes {
                    notesEditor
                }
                extraActions()
                if !selection.metadataRows.isEmpty {
                    Divider()
                    metadataSection
                }
            } else {
                emptyState
            }
        }
        .onAppear {
            // Seed live @State from persisted value so subsequent drags
            // mutate only @State and leave UserDefaults untouched until the
            // drag ends.
            if previewHeight != persistedPreviewHeight {
                previewHeight = persistedPreviewHeight
            }
        }
    }

    // MARK: - Preview Card

    @ViewBuilder
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selection.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if selection.isRejected {
                    Text("Rejected")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.14), in: Capsule())
                        .foregroundStyle(.red)
                }
            }

            if let subtitle = selection.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let url = selection.imageURL {
                Group {
                    if let image = loadedImage, loadedImageURL == url {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                            .overlay {
                                ProgressView().controlSize(.small)
                            }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: CGFloat(previewHeight))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .task(id: "\(url.path)#\(previewPixelSize)") {
                    // Load off the main thread so tab switches / selection
                    // changes don't block UI. Decode an inspector-sized
                    // preview instead of the full source asset so 4K/8K
                    // images don't beachball the main actor.
                    if loadedImageURL == url,
                       let loadedImage,
                       Int(max(loadedImage.size.width, loadedImage.size.height)) >= previewPixelSize {
                        return
                    }
                    let target = url
                    let pixelSize = previewPixelSize
                    let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                        return loadInspectorPreview(url: target, maxPixelSize: pixelSize)
                    }.value
                    if !Task.isCancelled {
                        loadedImage = image
                        loadedImageURL = url
                    }
                }

                // Drag handle for resizing. Uses highPriorityGesture so the
                // parent ScrollView (in InspectorView / ImagineInspectorView)
                // doesn't swallow the vertical drag.
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(isDragging ? 0.6 : 0.35))
                            .frame(width: 48, height: 4)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() }
                        else { NSCursor.pop() }
                    }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragStartHeight == nil {
                                    dragStartHeight = previewHeight
                                }
                                isDragging = true
                                let proposed = (dragStartHeight ?? previewHeight) + Double(value.translation.height)
                                previewHeight = min(max(proposed, Double(minPreviewHeight)), Double(maxPreviewHeight))
                            }
                            .onEnded { _ in
                                isDragging = false
                                dragStartHeight = nil
                                // Commit to persistence once, not on every
                                // drag frame — AppStorage writes force a
                                // UserDefaults round-trip + observable
                                // publish that was visibly jittering the
                                // preview.
                                if abs(persistedPreviewHeight - previewHeight) > 0.5 {
                                    persistedPreviewHeight = previewHeight
                                }
                            }
                    )
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: CGFloat(previewHeight))
                    .overlay {
                        Text("Preview unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .padding(12)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var previewPixelSize: Int {
        max(720, Int(CGFloat(previewHeight) * 2.0))
    }

    // MARK: - Rating

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rating")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        selection.setRating(selection.rating == star ? nil : star)
                    } label: {
                        Image(systemName: (selection.rating ?? 0) >= star ? "star.fill" : "star")
                            .foregroundStyle(.yellow)
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: 18)

                Button(selection.isRejected ? "Unreject" : "Reject") {
                    selection.toggleRejected()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Notes Editor

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: Binding(
                get: { selection.notes },
                set: { selection.setNotes($0) }
            ))
            .font(.system(.body, design: .default))
            .frame(minHeight: 120)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Metadata")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(selection.metadataRows.enumerated()), id: \.offset) { _, row in
                // Long values (like full prompts) need a stacked layout so they
                // can wrap to the full inspector width instead of being squeezed
                // to whatever space LabeledContent leaves on the right.
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(row.value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.quaternary)
                .frame(height: 120)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text(selection.emptyStateMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
        }
    }
}

@available(macOS 26.0, *)
private func loadInspectorPreview(url: URL, maxPixelSize: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return NSImage(contentsOf: url)
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return NSImage(contentsOf: url)
    }
    return NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
    )
}

// Convenience init when no extra actions are needed
@available(macOS 26.0, *)
extension UnifiedDetailsInspectorSection where ExtraActions == EmptyView {
    init(selection: Selection) {
        self.selection = selection
        self.extraActions = { EmptyView() }
    }
}

// MARK: - Place Extra Actions

@available(macOS 26.0, *)
struct PlaceDetailsExtraActionsSection: View {
    let store: AnimateStore
    @AppStorage("animate.places.workflowMode.v1") private var workflowModeRawValue = "photorealistic"
    @State private var isSubmittingImmediate = false
    @State private var inlineErrorMessage: String?

    private var workflowMode: PlaceWorkflowMode {
        PlaceWorkflowMode(rawValue: workflowModeRawValue) ?? .photorealistic
    }

    private var record: GeneratedBackgroundLibraryRecord? {
        store.selectedGeneratedBackgroundRecord
    }

    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 8) {
                if let queueItem = store.pendingGeneratedBackgroundEditQueueItem(for: record.id) {
                    HStack {
                        Image(systemName: "clock.fill")
                            .foregroundStyle(.secondary)
                        Text(queueItem.state.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(queueItem.state == .failed ? .orange : .secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        store.queueGeneratedBackgroundEdit(recordID: record.id, workflow: workflowMode)
                        inlineErrorMessage = nil
                    } label: {
                        Label("Add to Batch", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(record.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        runImmediateEdit(record)
                    } label: {
                        if isSubmittingImmediate {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Edit Now", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmittingImmediate || record.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let inlineErrorMessage, !inlineErrorMessage.isEmpty {
                    Text(inlineErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func runImmediateEdit(_ record: GeneratedBackgroundLibraryRecord) {
        inlineErrorMessage = nil
        isSubmittingImmediate = true
        Task { @MainActor in
            defer { isSubmittingImmediate = false }
            do {
                try await store.submitGeneratedBackgroundEditImmediately(recordID: record.id, workflow: workflowMode)
            } catch {
                inlineErrorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Place Adapter

@available(macOS 26.0, *)
struct PlaceImageSelection: DetailedImageSelection {
    let store: AnimateStore

    private var record: GeneratedBackgroundLibraryRecord? {
        store.selectedGeneratedBackgroundRecord
    }

    var imageURL: URL? {
        guard let record else { return nil }
        return store.resolvedCharacterAssetURL(for: record.activePath)
    }

    var title: String {
        guard let record else { return "" }
        return URL(fileURLWithPath: record.activePath).lastPathComponent
    }

    var subtitle: String? {
        record?.summary
    }

    var rating: Int? { record?.rating }
    var isRejected: Bool { record?.isRejected ?? false }
    var notes: String { record?.draftEditNotes ?? "" }

    var metadataRows: [(label: String, value: String)] {
        guard let record else { return [] }
        var rows: [(label: String, value: String)] = []
        rows.append(("Workflow", record.workflow.displayName))
        if !record.keywords.isEmpty {
            rows.append(("Keywords", record.keywords.joined(separator: ", ")))
        }
        if let metadata = store.generationMetadata(for: record.activePath) {
            if !metadata.model.isEmpty {
                rows.append(("Model", metadata.model))
            }
            if !metadata.aspectRatio.isEmpty {
                rows.append(("Aspect", metadata.aspectRatio))
            }
            if !metadata.imageSize.isEmpty {
                rows.append(("Size", metadata.imageSize))
            }
        }
        if let resolution = store.imageResolutionDescription(for: record.activePath),
           !resolution.isEmpty {
            rows.append(("Resolution", resolution))
        }
        rows.append(("Created", record.createdAt.formatted(date: .abbreviated, time: .shortened)))
        if let prompt = record.sourcePrompt, !prompt.isEmpty {
            // Full prompt — no prefix cap. Long values are rendered in a
            // wrapping VStack layout by metadataSection below.
            rows.append(("Prompt", prompt))
        }
        return rows
    }

    var emptyStateMessage: String {
        if store.selectedPlace != nil {
            return "Select an image in All Generated Background Images to inspect it here."
        }
        return "Select a generated background image to see its preview, notes, rating, and metadata."
    }

    func setRating(_ newValue: Int?) {
        guard let record else { return }
        store.setGeneratedBackgroundRating(newValue, for: record.id)
    }

    func toggleRejected() {
        guard let record else { return }
        store.toggleGeneratedBackgroundRejected(record.id)
    }

    func setNotes(_ newValue: String) {
        guard let record else { return }
        store.updateGeneratedBackgroundEditNotes(newValue, for: record.id)
    }
}

// MARK: - Character / Imagine Adapter

@available(macOS 26.0, *)
struct CharacterImageSelection: DetailedImageSelection {
    let store: AnimateStore

    private var character: AnimationCharacter? { store.selectedCharacter }
    private var currentPath: String? { store.imaginePreviewImagePath }

    var imageURL: URL? {
        guard let path = currentPath else { return nil }
        return store.resolvedCharacterAssetURL(for: path)
    }

    var title: String {
        guard let path = currentPath else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var subtitle: String? {
        character?.name
    }

    var rating: Int? {
        guard let path = currentPath else { return nil }
        return character?.inspirationRatings?[path]
    }

    var isRejected: Bool {
        guard let path = currentPath else { return false }
        return character?.inspirationRejectedPaths.contains(path) ?? false
    }

    var notes: String {
        guard let path = currentPath else { return "" }
        return character?.inspirationNotes?[path] ?? ""
    }

    var metadataRows: [(label: String, value: String)] {
        guard let path = currentPath else { return [] }
        var rows: [(label: String, value: String)] = []
        if let metadata = store.generationMetadata(for: path) {
            if !metadata.prompt.isEmpty {
                rows.append(("Prompt", String(metadata.prompt.prefix(120))))
            }
            rows.append(("Model", metadata.model))
            rows.append(("Size", "\(metadata.imageSize) • \(metadata.aspectRatio)"))
        }
        return rows
    }

    var emptyStateMessage: String {
        "Select an inspiration image to see its details."
    }

    func setRating(_ newValue: Int?) {
        guard let path = currentPath, let charID = character?.id else { return }
        store.setInspirationRating(newValue, path: path, for: charID)
    }

    func toggleRejected() {
        guard let path = currentPath, let charID = character?.id else { return }
        store.toggleInspirationRejected(path: path, for: charID)
    }

    func setNotes(_ newValue: String) {
        guard let path = currentPath, let charID = character?.id else { return }
        store.updateInspirationNotes(newValue, path: path, for: charID)
    }
}

// MARK: - Props Adapter (stub)

@available(macOS 26.0, *)
struct PropImageSelection: DetailedImageSelection {
    let store: AnimateStore

    var imageURL: URL? { nil }
    var title: String { "" }
    var subtitle: String? { nil }
    var rating: Int? { nil }
    var isRejected: Bool { false }
    var notes: String { "" }
    var metadataRows: [(label: String, value: String)] { [] }
    var emptyStateMessage: String { "No prop image selected." }
    var supportsRating: Bool { false }
    var supportsNotes: Bool { false }

    func setRating(_ newValue: Int?) {}
    func toggleRejected() {}
    func setNotes(_ newValue: String) {}
}
