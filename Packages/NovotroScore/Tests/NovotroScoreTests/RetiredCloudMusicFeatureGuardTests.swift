import Foundation
import Testing

@Suite("Retired Cloud Music Feature Guard")
struct RetiredCloudMusicFeatureGuardTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func retiredSourceFilesAreAbsent() {
        let fm = FileManager.default
        let retiredPaths = [
            "Sources/NovotroScore/Services/AceStepRunPodManager.swift",
            "Sources/NovotroScore/Views/AceStepInspectorView.swift",
            "Sources/NovotroScore/Models/AceStepModels.swift",
            "Sources/NovotroScore/Resources/ace-step-runpod-bridge.py",
            "Sources/NovotroScore/Resources/ace-step-remote-worker.py",
            "Sources/NovotroScore/Resources/songbloom-runpod-bridge.py",
            "Scripts/run_ace_step_preview_batch.py",
        ]

        let found = retiredPaths.filter {
            fm.fileExists(atPath: repoRoot.appendingPathComponent($0).path)
        }

        #expect(found.isEmpty, "Retired cloud-music files must stay removed: \(found)")
    }

    @Test func retiredArtifactCachesAreAbsent() {
        let fm = FileManager.default
        let retiredPaths = [
            "Sources/NovotroScore/Resources/__pycache__/songbloom-runpod-bridge.cpython-313.pyc",
            "Scripts/__pycache__/run_ace_step_preview_batch.cpython-313.pyc",
        ]

        let found = retiredPaths.filter {
            fm.fileExists(atPath: repoRoot.appendingPathComponent($0).path)
        }

        #expect(found.isEmpty, "Retired cloud-music caches must stay removed: \(found)")
    }

    @Test func packageResourcesStaySunoOnly() throws {
        let packageText = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"))
        #expect(!packageText.contains("ace-step"))
        #expect(!packageText.contains("songbloom"))
        #expect(!packageText.contains("RunPod"))
        #expect(!packageText.contains("runpod"))
    }
}
