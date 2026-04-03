import Foundation
import AppKit
import SceneKit

/// Batch-imports USDZ/GLB/OBJ prop files into the project's prop library.
///
/// Creates registry entries and copies files into `Animate/props/` within the project.
@available(macOS 26.0, *)
@MainActor
final class PropBatchImportService {

    struct ImportResult: Sendable {
        let importedCount: Int
        let skippedCount: Int
        let errorCount: Int
        let errors: [String]
        let importedPropNames: [String]
    }

    weak var store: AnimateStore?

    init(store: AnimateStore) {
        self.store = store
    }

    /// Present an NSOpenPanel to select multiple 3D files and import them.
    func importPropsWithPanel() async -> ImportResult {
        let panel = NSOpenPanel()
        panel.title = "Import Props"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["usdz", "glb", "obj", "scn"]

        let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!)
        guard response == .OK else {
            return ImportResult(importedCount: 0, skippedCount: 0, errorCount: 0, errors: [], importedPropNames: [])
        }

        return await importProps(from: panel.urls)
    }

    /// Import props from an array of file URLs.
    func importProps(from urls: [URL]) async -> ImportResult {
        guard let store, let animateURL = store.animateURL else {
            return ImportResult(importedCount: 0, skippedCount: 0, errorCount: 1, errors: ["No project open"], importedPropNames: [])
        }
        let propsDir = animateURL.appendingPathComponent("props")
        try? FileManager.default.createDirectory(at: propsDir, withIntermediateDirectories: true)

        var imported = 0, skipped = 0, errored = 0
        var errors: [String] = []
        var names: [String] = []

        for url in urls {
            let destURL = propsDir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destURL.path) {
                skipped += 1
                continue
            }
            do {
                try FileManager.default.copyItem(at: url, to: destURL)
                imported += 1
                names.append(url.deletingPathExtension().lastPathComponent)
            } catch {
                errored += 1
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if imported > 0 {
            store.statusMessage = "Imported \(imported) prop\(imported == 1 ? "" : "s") to Animate/props/"
        }

        return ImportResult(
            importedCount: imported,
            skippedCount: skipped,
            errorCount: errored,
            errors: errors,
            importedPropNames: names
        )
    }
}
