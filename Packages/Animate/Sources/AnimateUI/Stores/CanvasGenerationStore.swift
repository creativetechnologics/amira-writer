import Foundation

@available(macOS 26.0, *)
@MainActor
final class CanvasGenerationStore {
    unowned let parent: AnimateStore
    init(parent: AnimateStore) { self.parent = parent }

    @ObservationIgnored var canvasGenerationsNewestCache: [AnimateStore.CanvasGeneration] = []
    @ObservationIgnored var canvasGenerationsNewestCacheSignature: Int = 0
    @ObservationIgnored var canvasGenerationsNewestCacheIsValid = false

    func canvasGenerationsNewestFirst() -> [AnimateStore.CanvasGeneration] {
        let signature = sortSignature()
        if !canvasGenerationsNewestCacheIsValid || signature != canvasGenerationsNewestCacheSignature {
            canvasGenerationsNewestCache = parent.canvasGenerations.sorted { $0.createdAt > $1.createdAt }
            canvasGenerationsNewestCacheSignature = signature
            canvasGenerationsNewestCacheIsValid = true
        }
        return canvasGenerationsNewestCache
    }

    func bumpCanvasGenerationsRevision() {
        canvasGenerationsNewestCacheIsValid = false
    }

    private func sortSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(parent.canvasGenerations.count)
        for generation in parent.canvasGenerations {
            hasher.combine(generation.id)
            hasher.combine(generation.createdAt)
        }
        return hasher.finalize()
    }
}
