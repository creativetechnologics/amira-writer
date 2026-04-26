import AppKit
import Foundation

/// Bridges SwiftUI's single-item `.onDrag` callback with Amira's multi-select
/// image grids.
///
/// SwiftUI hands most drop targets only the dragged item provider. When a user
/// drags from a multi-selected grid, the visible drag can still carry one URL;
/// this short-lived context lets in-app reference-image drop zones expand that
/// one URL back to the full selected set.
@available(macOS 26.0, *)
@MainActor
enum ImageMultiSelectionDragContext {
    private static var payloadURLs: [URL] = []
    private static var expiresAt: Date = .distantPast
    private static let lifetime: TimeInterval = 30

    static func begin(urls: [URL]) {
        let unique = uniqueFileURLs(urls)
        guard !unique.isEmpty else {
            clear()
            return
        }
        payloadURLs = unique
        expiresAt = Date().addingTimeInterval(lifetime)
    }

    static func itemProvider(for urls: [URL], fallbackURL: URL? = nil) -> NSItemProvider {
        let payload = uniqueFileURLs(urls)
        let effectivePayload: [URL]
        if payload.isEmpty, let fallbackURL {
            effectivePayload = [fallbackURL]
        } else {
            effectivePayload = payload
        }
        begin(urls: effectivePayload)
        if let first = effectivePayload.first {
            return NSItemProvider(object: first as NSURL)
        }
        return NSItemProvider()
    }

    static func resolveDroppedURLs(_ incomingURLs: [URL]) -> [URL] {
        guard Date() <= expiresAt, !payloadURLs.isEmpty else {
            return incomingURLs
        }

        let incomingPaths = Set(incomingURLs.map(normalizedPath))
        let payloadIntersectsDrop = payloadURLs.contains { incomingPaths.contains(normalizedPath($0)) }
        guard payloadIntersectsDrop else {
            return incomingURLs
        }

        let resolved = payloadURLs
        clear()
        return resolved
    }

    static func clear() {
        payloadURLs = []
        expiresAt = .distantPast
    }

    private static func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let normalized = url.standardizedFileURL
            let key = normalizedPath(normalized)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(normalized)
        }
        return result
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
