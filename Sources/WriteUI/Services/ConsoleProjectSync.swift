import Foundation
import ProjectKit

// MARK: - Console Project Sync Service

/// Extracts editable project content to a temporary directory for AI agents,
/// watches for changes, syncs modifications back to ScriptStore, and supports
/// snapshot/restore for undo.
@available(macOS 26.0, *)
@MainActor
final class ConsoleProjectSync {
    private let store: ScriptStore
    private(set) var tempDirectoryURL: URL?
    private var fileWatchers: [DispatchSourceFileSystemObject] = []

    init(store: ScriptStore) {
        self.store = store
    }

    func extractToTempDirectory() throws -> URL {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteUI-Console-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)

        let encoder = JSONCoders.makeEncoder()
        encoder.outputFormatting.insert(.sortedKeys)

        // project_metadata.json
        try encoder.encode(store.metadata).write(to: tempBase.appendingPathComponent("project_metadata.json"))

        // songs/<name>/info.json + version lyrics
        let songsDir = tempBase.appendingPathComponent("songs")
        try FileManager.default.createDirectory(at: songsDir, withIntermediateDirectories: true)

        for stub in store.songStubs {
            guard let asset = store.songAssets.first(where: { $0.relativePath == stub.relativePath }) else { continue }
            let doc = asset.document

            let songFolderName = sanitizeFilename(stub.displayName)
            let songDir = songsDir.appendingPathComponent(songFolderName)
            try FileManager.default.createDirectory(at: songDir, withIntermediateDirectories: true)

            let infoDict: [String: String] = [
                "title": doc.title,
                "canonicalTitle": doc.canonicalTitle,
                "notes": doc.notes,
            ]
            try encoder.encode(infoDict).write(to: songDir.appendingPathComponent("info.json"))

            for version in doc.versions {
                let versionDir = songDir.appendingPathComponent(sanitizeFilename(version.label))
                try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
                try Data(version.lyrics.utf8).write(to: versionDir.appendingPathComponent("lyrics.txt"))
            }
        }

        // characters/<name>.json
        let charsDir = tempBase.appendingPathComponent("characters")
        try FileManager.default.createDirectory(at: charsDir, withIntermediateDirectories: true)
        for character in store.characters {
            let charFilename = sanitizeFilename(character.name) + ".json"
            try encoder.encode(character).write(to: charsDir.appendingPathComponent(charFilename))
        }

        // libretto/<name>.txt
        let librettoDir = tempBase.appendingPathComponent("libretto")
        try FileManager.default.createDirectory(at: librettoDir, withIntermediateDirectories: true)
        for file in store.librettoFiles {
            let libFilename = sanitizeFilename(file.displayName) + ".txt"
            try Data(file.content.utf8).write(to: librettoDir.appendingPathComponent(libFilename))
        }

        // CLAUDE.md
        try writeRulesFile(to: tempBase)

        tempDirectoryURL = tempBase
        return tempBase
    }

    func writeRulesFile(to directory: URL) throws {
        let content = """
        # Write Project: \(store.metadata.name)

        ## Project Summary
        - Songs: \(store.songStubs.count)
        - Characters: \(store.characters.count)
        - Libretto files: \(store.librettoFiles.count)

        ## What You Can Edit
        - Lyrics (songs/<name>/<version>/lyrics.txt)
        - Libretto (libretto/*.txt)
        - Characters (characters/*.json)
        - Song info (songs/<name>/info.json)
        - Project metadata (project_metadata.json)

        ## Format Notes
        - All JSON uses ISO 8601 dates.
        - Do not rename folders.
        """
        let data = Data(content.utf8)
        try data.write(to: directory.appendingPathComponent("CLAUDE.md"))
        try data.write(to: directory.appendingPathComponent("AGENTS.md"))
    }

    func startWatching() {
        guard let tempDir = tempDirectoryURL else { return }
        stopWatching()

        let dirsToWatch = [
            tempDir,
            tempDir.appendingPathComponent("songs"),
            tempDir.appendingPathComponent("characters"),
            tempDir.appendingPathComponent("libretto"),
        ]

        for dir in dirsToWatch {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .extend],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler {
                Task { @MainActor [weak self] in
                    _ = self?.syncChangesBack()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            fileWatchers.append(source)
        }
    }

    private func stopWatching() {
        for source in fileWatchers { source.cancel() }
        fileWatchers.removeAll()
    }

    @discardableResult
    func syncChangesBack() -> Bool {
        guard let tempDir = tempDirectoryURL else { return false }
        var anyChanges = false
        var directChanges = false

        // Sync metadata (direct — not part of text editor preview)
        let metaURL = tempDir.appendingPathComponent("project_metadata.json")
        if let data = try? Data(contentsOf: metaURL),
           let decoded = try? JSONCoders.makeDecoder().decode(ProjectMetadata.self, from: data) {
            if decoded.name != store.metadata.name || decoded.notes != store.metadata.notes {
                store.metadata.name = decoded.name
                store.metadata.notes = decoded.notes
                store.metadata.updatedAt = Date()
                anyChanges = true
                directChanges = true
            }
        }

        // Sync libretto directly into the live store so agent edits are visible immediately.
        let librettoDir = tempDir.appendingPathComponent("libretto")
        if let files = try? FileManager.default.contentsOfDirectory(at: librettoDir, includingPropertiesForKeys: nil) {
            for fileURL in files where fileURL.pathExtension == "txt" {
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let displayName = fileURL.deletingPathExtension().lastPathComponent
                if let index = store.librettoFiles.firstIndex(where: { sanitizeFilename($0.displayName) == displayName }) {
                    let committed = store.librettoFiles[index].content
                    if committed != content {
                        store.applySyncedLyricsChange(
                            atPath: store.librettoFiles[index].relativePath,
                            lyrics: content
                        )
                        anyChanges = true
                    }
                }
            }
        }

        // Sync characters (direct — not part of text editor preview)
        let charsDir = tempDir.appendingPathComponent("characters")
        if let files = try? FileManager.default.contentsOfDirectory(at: charsDir, includingPropertiesForKeys: nil) {
            for fileURL in files where fileURL.pathExtension == "json" {
                let decoder = JSONCoders.makeDecoder()
                guard let data = try? Data(contentsOf: fileURL),
                      let decoded = try? decoder.decode(OPWCharacter.self, from: data) else { continue }
                if let index = store.characters.firstIndex(where: { $0.id == decoded.id }) {
                    if store.characters[index] != decoded {
                        store.characters[index] = decoded
                        anyChanges = true
                        directChanges = true
                    }
                }
            }
        }

        // Only mark dirty for direct metadata/character changes here.
        // Libretto changes are applied through ScriptStore, which marks them dirty itself.
        if directChanges { store.metadataDirty = true }
        return anyChanges
    }

    func takeSnapshot() -> ConsoleSnapshot {
        ConsoleSnapshot(
            metadata: store.metadata,
            librettoFiles: store.librettoFiles,
            characters: store.characters
        )
    }

    func restoreSnapshot(_ snapshot: ConsoleSnapshot) {
        store.metadata = snapshot.metadata
        store.librettoFiles = snapshot.librettoFiles
        store.characters = snapshot.characters
        store.metadataDirty = true
    }

    func cleanUp() {
        stopWatching()
        if let tempDir = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDirectoryURL = nil
    }

    private func sanitizeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
    }
}
// JSON Coders: use ProjectKit.JSONCoders.makeDecoder() / makeEncoder() instead of custom extensions.
