import CoreGraphics
import Foundation
import Darwin
import AnimateUI

@main
@available(macOS 26.0, *)
struct AnimateMain {
    static func main() async {
        if await handleSnapshotCommand() {
            return
        }
        if await handleDumpCharactersCommand() {
            return
        }
        if await handleShotFrameDryRunCommand() {
            return
        }
        if await handleImageIntelligenceSmokeTestCommand() {
            return
        }
        if await handleVertexImageSmokeTestCommand() {
            return
        }
        AnimateBootstrap.main()
    }

    private static func argumentValue(
        after flag: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func handleSnapshotCommand() async -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--snapshot") else { return false }

        guard let projectPath = argumentValue(after: "--project", in: arguments),
              let scenePath = argumentValue(after: "--scene", in: arguments),
              let outputPath = argumentValue(after: "--output", in: arguments)
        else {
            fputs("Missing required flags for --snapshot.\n", stderr)
            fputs("Required: --project <path> --scene <relative-song-path> --output <png>\n", stderr)
            return true
        }

        let frame = argumentValue(after: "--frame", in: arguments).flatMap(Int.init) ?? 0
        let width = argumentValue(after: "--width", in: arguments).flatMap(Double.init) ?? 2100
        let height = argumentValue(after: "--height", in: arguments).flatMap(Double.init) ?? 900
        let mode = argumentValue(after: "--mode", in: arguments).flatMap(AnimationPreviewSnapshotMode.init(rawValue:)) ?? .live

        do {
            try await AnimationPreviewSnapshotExporter.export(
                projectURL: URL(fileURLWithPath: projectPath),
                scenePath: scenePath,
                frame: frame,
                mode: mode,
                size: CGSize(width: width, height: height),
                outputURL: URL(fileURLWithPath: outputPath)
            )
            print("Wrote snapshot to \(outputPath)")
        } catch {
            fputs("Snapshot export failed: \(error.localizedDescription)\n", stderr)
        }

        return true
    }

    @MainActor
    private static func handleDumpCharactersCommand() async -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--dump-characters") else { return false }

        guard let projectPath = argumentValue(after: "--project", in: arguments) else {
            fputs("Missing required flags for --dump-characters.\n", stderr)
            fputs("Required: --project <path>\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        let controller = AnimateWorkspaceController(startServers: false)
        let projectURL = URL(fileURLWithPath: projectPath)
        if let error = await controller.ensureProjectLoaded(projectURL) {
            fputs("Character dump failed: \(error)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        let rows = controller.debugCharacterRows()
        print("character_count=\(rows.count)")
        for row in rows {
            print("\(row.name)\towp=\(row.owpSlug)\tstorage=\(row.storageSlug)")
        }
        return true
    }

    @MainActor
    private static func handleShotFrameDryRunCommand() async -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--shot-frame-dry-run") else { return false }

        guard let projectPath = argumentValue(after: "--project", in: arguments) else {
            fputs("Missing required flags for --shot-frame-dry-run.\n", stderr)
            fputs("Required: --project <path>\n", stderr)
            fputs("Optional: --scene <all|first|index|name|uuid> --model <flash|pro> --image-size <1K|2K|4K>\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        let controller = AnimateWorkspaceController(startServers: false)
        let projectURL = URL(fileURLWithPath: projectPath)
        if let error = await controller.ensureProjectLoaded(projectURL) {
            fputs("Shot-frame dry run failed to load project: \(error)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        do {
            let result = try await controller.runShotFrameGenerationDryRun(
                sceneFilter: argumentValue(after: "--scene", in: arguments),
                modelName: argumentValue(after: "--model", in: arguments),
                imageSize: argumentValue(after: "--image-size", in: arguments)
            )
            print("SHOT_FRAME_DRY_RUN_DONE")
            for key in result.keys.sorted() {
                print("\(key)=\(result[key] ?? "")")
            }
        } catch {
            fputs("Shot-frame dry run failed: \(error.localizedDescription)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        return true
    }

    @MainActor
    private static func handleImageIntelligenceSmokeTestCommand() async -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--image-intelligence-smoke") else { return false }

        guard let projectPath = argumentValue(after: "--project", in: arguments) else {
            fputs("Missing required flags for --image-intelligence-smoke.\n", stderr)
            fputs("Required: --project <path>\n", stderr)
            fputs("Optional: --image <path> --vertex-project <id> --vertex-region <region> --max-spend <usd>\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        let maxSpend = argumentValue(after: "--max-spend", in: arguments)
            .flatMap(Double.init) ?? 1.0

        let controller = AnimateWorkspaceController(startServers: false)
        let projectURL = URL(fileURLWithPath: projectPath)
        if let error = await controller.ensureProjectLoaded(projectURL) {
            fputs("Image Intelligence smoke test failed to load project: \(error)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        do {
            let result = try await controller.runImageIntelligenceSmokeTest(
                imagePath: argumentValue(after: "--image", in: arguments),
                projectID: argumentValue(after: "--vertex-project", in: arguments),
                region: argumentValue(after: "--vertex-region", in: arguments),
                maxSpendUSD: maxSpend
            )
            print("IMAGE_INTELLIGENCE_SMOKE_DONE")
            for key in result.keys.sorted() {
                print("\(key)=\(result[key] ?? "")")
            }
        } catch {
            fputs("Image Intelligence smoke test failed: \(error.localizedDescription)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        return true
    }

    @MainActor
    private static func handleVertexImageSmokeTestCommand() async -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--vertex-image-smoke") else { return false }

        guard let projectPath = argumentValue(after: "--project", in: arguments) else {
            fputs("Missing required flags for --vertex-image-smoke.\n", stderr)
            fputs("Required: --project <path>\n", stderr)
            fputs("Optional: --vertex-project <id> --vertex-region <region> --model <flash|pro> --image-size <1K|2K|4K> --aspect-ratio <4:3|16:9> --max-spend <usd>\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        let maxSpend = argumentValue(after: "--max-spend", in: arguments)
            .flatMap(Double.init) ?? 5.0

        let controller = AnimateWorkspaceController(startServers: false)
        let projectURL = URL(fileURLWithPath: projectPath)
        if let error = await controller.ensureProjectLoaded(projectURL) {
            fputs("Vertex smoke test failed to load project: \(error)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        do {
            let result = try await controller.runVertexImageSmokeTest(
                projectID: argumentValue(after: "--vertex-project", in: arguments),
                region: argumentValue(after: "--vertex-region", in: arguments),
                modelName: argumentValue(after: "--model", in: arguments),
                imageSize: argumentValue(after: "--image-size", in: arguments),
                aspectRatio: argumentValue(after: "--aspect-ratio", in: arguments),
                maxSpendUSD: maxSpend
            )
            print("VERTEX_IMAGE_SMOKE_DONE")
            for key in result.keys.sorted() {
                print("\(key)=\(result[key] ?? "")")
            }
        } catch {
            fputs("Vertex image smoke test failed: \(error.localizedDescription)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        return true
    }
}
