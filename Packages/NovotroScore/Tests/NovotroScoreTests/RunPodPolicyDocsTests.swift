import Foundation
import Testing

@Suite("RunPod Policy Docs")
struct RunPodPolicyDocsTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func monitorScriptExists() {
        let scriptURL = repoRoot.appendingPathComponent("Scripts/runpod_pod_monitor.py")
        #expect(FileManager.default.fileExists(atPath: scriptURL.path))
    }

    @Test func policyDocExists() {
        let docURL = repoRoot.appendingPathComponent("docs/superpowers/RUNPOD-POD-GUARDRAILS.md")
        #expect(FileManager.default.fileExists(atPath: docURL.path))
    }

    @Test func agentDocsRequireRunPodWatchdog() throws {
        let expectedTokens = [
            "docs/superpowers/RUNPOD-POD-GUARDRAILS.md",
            "Scripts/runpod_pod_monitor.py",
        ]
        let paths = [
            "AGENTS.md",
            "CLAUDE.md",
            "Claude to Terminal.md",
        ]

        for path in paths {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(path))
            for token in expectedTokens {
                #expect(text.contains(token), "\(path) is missing \(token)")
            }
        }
    }
}
