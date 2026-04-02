import AppKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
enum Animate3DGenerationQueueActionSupport {
    struct PreflightOwner {
        var characterID: UUID?
        var characterSlug: String?
        var displayName: String
        var outputRootRelativePath: String?

        @MainActor
        init(item: Animate3DGenerationQueueItem, store: AnimateStore) {
            if let slug = item.characterSlug,
               let character = store.characters.first(where: { $0.assetFolderSlug == slug || $0.owpSlug == slug }) {
                characterID = character.id
                characterSlug = character.assetFolderSlug
                displayName = character.name
                outputRootRelativePath = nil
            } else {
                characterID = nil
                characterSlug = nil
                displayName = item.characterName ?? "Environment"
                let trimmed = item.targetRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = trimmed.hasPrefix("Animate/")
                    ? String(trimmed.dropFirst("Animate/".count))
                    : trimmed
                let directory = normalized.hasSuffix("/")
                    ? normalized
                    : (normalized as NSString).deletingLastPathComponent
                let cleaned = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                outputRootRelativePath = cleaned.isEmpty
                    ? "3d/generation-queue-batches"
                    : "\(cleaned)/batch-queue-batches"
            }
        }
    }

    static func queue(
        item: Animate3DGenerationQueueItem,
        scene: AnimationScene?,
        status: Animate3DProductionStatus,
        store: AnimateStore
    ) -> Int {
        Animate3DAssetGapQueueService(store: store).queue(
            item: item,
            scene: scene,
            status: status
        )
    }

    static func draft(
        for item: Animate3DGenerationQueueItem,
        scene: AnimationScene?,
        status: Animate3DProductionStatus,
        store: AnimateStore
    ) -> (draft: GeminiGenerationDraft, owner: PreflightOwner)? {
        guard let draft = Animate3DAssetGapQueueService(store: store).draft(
            for: item,
            scene: scene,
            status: status
        ) else {
            return nil
        }
        return (draft, PreflightOwner(item: item, store: store))
    }

    static func queuePreflightDrafts(
        _ drafts: [GeminiGenerationDraft],
        owner: PreflightOwner,
        store: AnimateStore
    ) -> Int {
        for draft in drafts {
            if let characterID = owner.characterID {
                store.addToBatchQueue(
                    characterID: characterID,
                    characterName: owner.displayName,
                    draftTitle: draft.title,
                    draft: draft,
                    characterSlug: owner.characterSlug
                )
            } else if let outputRootRelativePath = owner.outputRootRelativePath {
                store.addToBatchQueue(
                    pipelineName: owner.displayName,
                    draftTitle: draft.title,
                    draft: draft,
                    outputRootRelativePath: outputRootRelativePath
                )
            }
        }
        return drafts.count
    }

    static func reveal(item: Animate3DGenerationQueueItem, projectURL: URL) {
        let trimmed = item.targetRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            projectURL.appendingPathComponent(trimmed)
        ])
    }

    static func manifestEditorContext(
        for item: Animate3DGenerationQueueItem,
        projectURL: URL
    ) -> Animate3DRegistryEditorContext? {
        guard let manifestKind = item.manifestKind,
              let relativePath = manifestRelativePath(for: manifestKind, projectURL: projectURL) else {
            return nil
        }
        return Animate3DRegistryEditorContext(
            kind: manifestKind,
            title: item.kind.title,
            relativePath: relativePath
        )
    }

    static func manifestRelativePath(
        for kind: Animate3DRegistryManifestKind,
        projectURL: URL
    ) -> String? {
        let index = ProjectDatabaseBridge.loadAnimate3DRegistryIndexFromDisk(projectURL: projectURL) ?? Animate3DRegistryIndex()
        switch kind {
        case .assetRegistry:
            return index.assetRegistryPath
        case .characterRegistry:
            return index.characterRegistryPath
        case .motionRegistry:
            return index.motionRegistryPath
        case .worldCatalog:
            return index.worldCatalogPath
        case .styleProfiles:
            return index.styleProfilesPath
        case .cameraPresets:
            return index.cameraPresetsPath
        case .lightRigs:
            return index.lightRigsPath
        case .atmospherePresets:
            return index.atmospherePresetsPath
        }
    }
}
