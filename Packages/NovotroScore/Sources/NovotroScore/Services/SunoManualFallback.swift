import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Handles the manual Suno workflow: export chunk WAVs + manifest,
/// then import user-dropped results.
@available(macOS 26.0, *)
enum SunoManualFallback {

    static func exportForManualGeneration(
        session: SunoRenderSession,
        outputDirectory: URL
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var manifest = "# Suno Generation Manifest\n\n"
        manifest += "Style: \(session.plan.styleTemplate)\n\n"

        for (i, chunk) in session.plan.chunks.enumerated() {
            manifest += "## Chunk \(i + 1): \(chunk.groupLabel)\n"
            manifest += "- Time: \(String(format: "%.1f", chunk.timeStart))s"
            manifest += " – \(String(format: "%.1f", chunk.timeEnd))s\n"
            manifest += "- Instruments: \(chunk.instrumentGroup.joined(separator: ", "))\n"
            manifest += "- Prompt: \(chunk.generatedPrompt)\n"
            manifest += "- Source WAV: chunk-\(String(format: "%03d", i + 1)).wav\n"
            manifest += "- Drop result as: result-\(String(format: "%03d", i + 1)).mp3\n\n"

            if let wavPath = chunk.renderedWAVPath {
                let destName = "chunk-\(String(format: "%03d", i + 1)).wav"
                let dest = outputDirectory.appendingPathComponent(destName)
                do {
                    try fm.copyItem(at: URL(fileURLWithPath: wavPath), to: dest)
                } catch {
                    NSLog("[SunoManualFallback] Failed to copy WAV %@: %@", wavPath, error.localizedDescription)
                }
            }
        }

        let resultsDir = outputDirectory.appendingPathComponent("results")
        try fm.createDirectory(at: resultsDir, withIntermediateDirectories: true)

        let manifestURL = outputDirectory.appendingPathComponent("MANIFEST.md")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        #if canImport(AppKit)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outputDirectory.path)
        #endif
    }

    static func importResults(
        from resultsDirectory: URL,
        into session: inout SunoRenderSession
    ) -> Int {
        let fm = FileManager.default
        var matched = 0

        for i in 0..<session.plan.chunks.count {
            let fileName = "result-\(String(format: "%03d", i + 1))"
            for ext in ["mp3", "wav", "m4a"] {
                let filePath = resultsDirectory
                    .appendingPathComponent("\(fileName).\(ext)")
                if fm.fileExists(atPath: filePath.path) {
                    var take = SunoTake()
                    take.downloadedFilePath = filePath.path
                    session.plan.chunks[i].takes.append(take)
                    if session.plan.chunks[i].status == .exported
                        || session.plan.chunks[i].status == .failed
                    {
                        session.plan.chunks[i].status = .downloaded
                    }
                    matched += 1
                    break
                }
            }
        }
        return matched
    }
}
