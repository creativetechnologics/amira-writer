import AppKit
import SwiftUI

/// Reusable right-click menu content for any image tile in the app.
///
/// Every grid across Characters, Places, Imagine, LORA, Universal Picker, etc.
/// should use this so the right-click surface stays consistent. Pass `nil`
/// for any closure a given grid shouldn't expose.
///
/// Usage:
/// ```
/// Image(...)
///     .contextMenu {
///         UnifiedImageContextMenuContent(
///             path: path,
///             selectedCount: selectedCount,
///             isSelected: isSelected,
///             actions: .init(
///                 onQuickLook: { preview() },
///                 onShowInFinder: { showInFinder(path) },
///                 onEditWithGemini: { editWithGemini(path) },
///                 onGenerateWithGemini: { count in generateWithGemini(path, count: count) }
///             )
///         )
///     }
/// ```
@available(macOS 26.0, *)
struct UnifiedImageActions {
    var onToggleCurated: (() -> Void)? = nil
    var isCurated: Bool = false
    var onShowPrompt: (() -> Void)? = nil
    var onSetAsProfile: (() -> Void)? = nil
    var onShowInFinder: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onQuickLook: (() -> Void)? = nil
    var onEditWithGemini: (() -> Void)? = nil
    /// Called with variation count (usually 1 or 27). Caller decides what
    /// that means in their subject's context.
    var onGenerateWithGemini: ((Int) -> Void)? = nil
    /// Extra Gemini submenu entries (e.g. wardrobe-specific generation).
    /// Each entry becomes a button under the "Generate with Gemini…" menu
    /// above the standard 1/27 buttons.
    var extraGeminiGenerateEntries: [UnifiedGeminiGenerateEntry] = []
    var onSetRating: ((Int?) -> Void)? = nil
    var currentRating: Int? = nil
    var onToggleRejected: (() -> Void)? = nil
    var isRejected: Bool = false
    /// Called when the user wants to remove this item from the current
    /// *collection* (e.g. inspiration set). File stays on disk.
    var onRemoveFromCollection: (() -> Void)? = nil
    var removeFromCollectionLabel: String = "Remove Image"
    /// Called when the user wants to move the underlying file to trash.
    var onMoveToTrash: (() -> Void)? = nil
}

@available(macOS 26.0, *)
struct UnifiedGeminiGenerateEntry: Identifiable {
    let id = UUID()
    let label: String
    let systemImage: String?
    let count: Int
    let action: (Int) -> Void
}

@available(macOS 26.0, *)
struct UnifiedImageContextMenuContent: View {
    let selectedCount: Int
    let isSelected: Bool
    let actions: UnifiedImageActions

    var body: some View {
        Group {
            curatedSection
            promptSection
            fileSection
            geminiSection
            ratingSection
            rejectionSection
            trashSection
        }
    }

    @ViewBuilder
    private var curatedSection: some View {
        if let onToggleCurated = actions.onToggleCurated {
            Button(
                actions.isCurated ? "Remove from Curated" : "Add to Curated References",
                systemImage: actions.isCurated ? "star.slash" : "star.fill"
            ) {
                onToggleCurated()
            }
            Divider()
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        if let onShowPrompt = actions.onShowPrompt {
            Button("View Prompt", systemImage: "eye.circle") { onShowPrompt() }
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        if let onShowInFinder = actions.onShowInFinder {
            Button("Show in Finder", systemImage: "folder") { onShowInFinder() }
        }
        if let onSetAsProfile = actions.onSetAsProfile {
            Button("Set as Profile Pic") { onSetAsProfile() }
        }
        if let onCopy = actions.onCopy {
            Button("Copy Image", systemImage: "doc.on.doc") { onCopy() }
        }
        if let onQuickLook = actions.onQuickLook {
            Button("Quick Look", systemImage: "eye") { onQuickLook() }
        }
    }

    @ViewBuilder
    private var geminiSection: some View {
        if actions.onEditWithGemini != nil
            || actions.onGenerateWithGemini != nil
            || !actions.extraGeminiGenerateEntries.isEmpty {
            Divider()
            if let onEditWithGemini = actions.onEditWithGemini {
                Button("Edit with Gemini…", systemImage: "wand.and.sparkles") {
                    onEditWithGemini()
                }
            }
            if actions.onGenerateWithGemini != nil
                || !actions.extraGeminiGenerateEntries.isEmpty {
                Menu {
                    if let onGenerate = actions.onGenerateWithGemini {
                        Button("Generate 1 with this as reference") { onGenerate(1) }
                        Button("Generate 27 batch variations") { onGenerate(27) }
                    }
                    if !actions.extraGeminiGenerateEntries.isEmpty {
                        if actions.onGenerateWithGemini != nil { Divider() }
                        ForEach(actions.extraGeminiGenerateEntries) { entry in
                            Button {
                                entry.action(entry.count)
                            } label: {
                                if let systemImage = entry.systemImage {
                                    Label(entry.label, systemImage: systemImage)
                                } else {
                                    Text(entry.label)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Generate with Gemini…", systemImage: "sparkles")
                }
            }
        }
    }

    @ViewBuilder
    private var ratingSection: some View {
        if let onSetRating = actions.onSetRating {
            Divider()
            Menu {
                ForEach(1...5, id: \.self) { rating in
                    Button {
                        onSetRating(rating)
                    } label: {
                        HStack {
                            Text(String(repeating: "★", count: rating))
                            if actions.currentRating == rating {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button("Clear Rating") { onSetRating(nil) }
            } label: {
                Label("Rate", systemImage: "star")
            }
        }
    }

    @ViewBuilder
    private var rejectionSection: some View {
        if let onToggleRejected = actions.onToggleRejected {
            Button(
                actions.isRejected ? "Show (Unreject)" : "Reject (Hide)",
                systemImage: actions.isRejected ? "eye" : "eye.slash"
            ) {
                onToggleRejected()
            }
        }
    }

    @ViewBuilder
    private var trashSection: some View {
        if actions.onRemoveFromCollection != nil || actions.onMoveToTrash != nil {
            Divider()
        }
        if let onRemoveFromCollection = actions.onRemoveFromCollection {
            let label = selectedCount > 1 && isSelected
                ? "Remove \(selectedCount) Selected"
                : actions.removeFromCollectionLabel
            Button(label, systemImage: "trash", role: .destructive) {
                onRemoveFromCollection()
            }
        }
        if let onMoveToTrash = actions.onMoveToTrash {
            Button("Move File to Trash", systemImage: "trash.slash", role: .destructive) {
                onMoveToTrash()
            }
        }
    }
}
