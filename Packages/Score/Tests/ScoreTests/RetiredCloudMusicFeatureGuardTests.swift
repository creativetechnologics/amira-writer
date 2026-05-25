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
            "Sources/ScoreUI/Services/AceStepRunPodManager.swift",
            "Sources/ScoreUI/Views/AceStepInspectorView.swift",
            "Sources/ScoreUI/Models/AceStepModels.swift",
            "Sources/ScoreUI/Resources/ace-step-runpod-bridge.py",
            "Sources/ScoreUI/Resources/ace-step-remote-worker.py",
            "Sources/ScoreUI/Resources/songbloom-runpod-bridge.py",
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
            "Sources/ScoreUI/Resources/__pycache__/songbloom-runpod-bridge.cpython-313.pyc",
            "Scripts/__pycache__/run_ace_step_preview_batch.cpython-313.pyc",
        ]

        let found = retiredPaths.filter {
            fm.fileExists(atPath: repoRoot.appendingPathComponent($0).path)
        }

        #expect(found.isEmpty, "Retired cloud-music caches must stay removed: \(found)")
    }

    @Test func packageResourcesStayFreeOfRetiredCloudMusicHooks() throws {
        let packageText = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"))
        #expect(!packageText.contains("ace-step"))
        #expect(!packageText.contains("songbloom"))
        #expect(!packageText.contains("RunPod"))
        #expect(!packageText.contains("runpod"))
        #expect(!packageText.contains("suno"))
        #expect(!packageText.contains("Suno"))
    }
}
