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

    static func prioritizedItems(
        from items: [Animate3DGenerationQueueItem],
        pinnedKeys: Set<String>,
        skippedKeys: Set<String>
    ) -> [Animate3DGenerationQueueItem] {
        items
            .filter { !skippedKeys.contains($0.stableKey) }
            .sorted { lhs, rhs in
                let lhsPinned = pinnedKeys.contains(lhs.stableKey)
                let rhsPinned = pinnedKeys.contains(rhs.stableKey)
                if lhsPinned != rhsPinned {
                    return lhsPinned && !rhsPinned
                }
                if lhs.isBatchDraftable != rhs.isBatchDraftable {
                    return lhs.isBatchDraftable && !rhs.isBatchDraftable
                }
                let lhsHasContext = !(lhs.contextSummary?.isEmpty ?? true)
                let rhsHasContext = !(rhs.contextSummary?.isEmpty ?? true)
                if lhsHasContext != rhsHasContext {
                    return lhsHasContext && !rhsHasContext
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    static func effectiveProviderHint(
        for item: Animate3DGenerationQueueItem,
        overridesByStableKey: [String: Animate3DGenerationDraftOverride] = [:]
    ) -> String {
        let override = overridesByStableKey[item.stableKey] ?? Animate3DGenerationDraftOverride()
        let trimmed = override.providerHintOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? item.providerHint : trimmed
    }

    static func effectivePromptAppendix(
        for item: Animate3DGenerationQueueItem,
        overridesByStableKey: [String: Animate3DGenerationDraftOverride] = [:]
    ) -> String? {
        let trimmed = (overridesByStableKey[item.stableKey]?.promptAppendix ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func hasLockedOverride(
        for item: Animate3DGenerationQueueItem,
        overridesByStableKey: [String: Animate3DGenerationDraftOverride] = [:]
    ) -> Bool {
        overridesByStableKey[item.stableKey]?.isLocked ?? false
    }

    static func applyOverrides(
        to draft: GeminiGenerationDraft,
        item: Animate3DGenerationQueueItem,
        overridesByStableKey: [String: Animate3DGenerationDraftOverride] = [:]
    ) -> GeminiGenerationDraft {
        let override = overridesByStableKey[item.stableKey] ?? Animate3DGenerationDraftOverride()
        var updated = draft
        let provider = effectiveProviderHint(for: item, overridesByStableKey: overridesByStableKey)
        let promptAppendix = effectivePromptAppendix(for: item, overridesByStableKey: overridesByStableKey)
        if let promptAppendix {
            updated.prompt += "\n\nOverride Notes:\n" + promptAppendix
        }
        var contextLines: [String] = []
        if let existing = updated.contextNote?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            contextLines.append(existing)
        }
        if provider.caseInsensitiveCompare(item.providerHint) != .orderedSame || !provider.isEmpty {
            contextLines.append("provider: \(provider)")
        }
        if override.isLocked {
            contextLines.append("locked override")
        }
        updated.contextNote = contextLines.isEmpty ? nil : contextLines.joined(separator: "\n")
        let providerOverride = provider.caseInsensitiveCompare(item.providerHint) == .orderedSame ? nil : provider
        let overrideTelemetry = GeminiGenerationDraftOverrideTelemetry(
            effectiveProviderHint: providerOverride,
            promptAppendix: promptAppendix,
            isLocked: override.isLocked
        )
        updated.overrideTelemetry = overrideTelemetry.hasVisibleChanges ? overrideTelemetry : nil
        return updated
    }

    static func queue(
        item: Animate3DGenerationQueueItem,
        scene: AnimationScene?,
        status: Animate3DProductionStatus,
        store: AnimateStore,
        overridesByStableKey: [String: Animate3DGenerationDraftOverride] = [:]
    ) -> Int {
        guard let result = draft(
            for: item,
            scene: scene,
            status: status,
            store: store,
            overridesByStableKey: overridesByStableKey
        ) else {
            return 0
        }
        return queuePreflightDrafts([result.draft], owner: result.owner, store: store)
    }

    static func queue(
        items: [Animate3DGenerationQueueItem],
        scene: AnimationScene?,
        status: Animate3DProductionStatus,
        store: AnimateStore,
        overridesByStableKey: [String: Animate3DGenerationDraftOverride] = [:]
    ) -> Int {
        items.reduce(into: 0) { queued, item in
            queued += queue(
                item: item,
                scene: scene,
                status: status,
                store: store,
                overridesByStableKey: overridesByStableKey
            )
        }
    }

    static func draft(
        for item: Animate3DGenerationQueueItem,
        scene: AnimationScene?,
        status: Animate3DProductionStatus,
        store: AnimateStore,
        overridesByStableKey: [String: Animate3DGenerationDraftOverride] = [:]
    ) -> (draft: GeminiGenerationDraft, owner: PreflightOwner)? {
        guard let draft = Animate3DAssetGapQueueService(store: store).draft(
            for: item,
            scene: scene,
            status: status
        ) else {
            return nil
        }
        let overriddenDraft = applyOverrides(to: draft, item: item, overridesByStableKey: overridesByStableKey)
        return (overriddenDraft, PreflightOwner(item: item, store: store))
    }

    static func queuePreflightDrafts(
        _ drafts: [GeminiGenerationDraft],
        owner: PreflightOwner,
        store: AnimateStore
    ) -> Int {
        queuePreflightDrafts(
            drafts,
            ownersByDraftID: [:],
            fallbackOwner: owner,
            store: store
        )
    }

    static func queuePreflightDrafts(
        _ drafts: [GeminiGenerationDraft],
        ownersByDraftID: [UUID: PreflightOwner],
        fallbackOwner: PreflightOwner? = nil,
        store: AnimateStore
    ) -> Int {
        var queued = 0
        for draft in drafts {
            guard let owner = ownersByDraftID[draft.id] ?? fallbackOwner else { continue }
            if let characterID = owner.characterID {
                store.addToBatchQueue(
                    characterID: characterID,
                    characterName: owner.displayName,
                    draftTitle: draft.title,
                    draft: draft,
                    characterSlug: owner.characterSlug
                )
                queued += 1
            } else if let outputRootRelativePath = owner.outputRootRelativePath {
                store.addToBatchQueue(
                    pipelineName: owner.displayName,
                    draftTitle: draft.title,
                    draft: draft,
                    outputRootRelativePath: outputRootRelativePath
                )
                queued += 1
            }
        }
        return queued
    }

    static func isQueued(item: Animate3DGenerationQueueItem, store: AnimateStore) -> Bool {
        let owner = PreflightOwner(item: item, store: store)
        return store.batchQueue.contains { queuedItem in
            guard queuedItem.draftTitle == item.title else { return false }
            if let characterID = owner.characterID {
                return queuedItem.characterID == characterID
            }
            if let outputRootRelativePath = owner.outputRootRelativePath {
                return queuedItem.outputRootRelativePath == outputRootRelativePath
            }
            return queuedItem.characterName == owner.displayName
        }
    }

    // MARK: - Provider Route Helpers

    /// Maps a queue item to its resolved `Animate3DGenerationProviderRoute`,
    /// respecting any provider-hint override before falling back to defaults.
    static func resolvedRoute(for item: Animate3DGenerationQueueItem) -> Animate3DGenerationProviderRoute {
        let hint = item.providerHint.lowercased()
        if hint.contains("meshy") { return .meshy }
        if hint.contains("external") || hint.contains("import") { return .externalImport }
        if hint.contains("manual") { return .manual }
        // Fall back to default route based on kind.
        // defaultRoute(for:) expects camelCase; Kind.rawValue is snake_case.
        return Animate3DGenerationProviderRoute.defaultRoute(for: item.kind.camelCaseRawValue)
    }

    /// Whether the item's resolved route can be automatically processed
    /// without human intervention.
    static func isAutomatable(_ item: Animate3DGenerationQueueItem) -> Bool {
        resolvedRoute(for: item).isAutomatable
    }

    /// Display-friendly name and SF Symbol for the item's resolved route.
    static func routeDisplayInfo(for item: Animate3DGenerationQueueItem) -> (name: String, icon: String) {
        let route = resolvedRoute(for: item)
        return (route.displayName, route.systemImage)
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
