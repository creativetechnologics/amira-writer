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
        if await handleSceneSweepCommand() {
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
    private static func handleSceneSweepCommand() async -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--scene-lora-sweep") else { return false }

        guard let projectPath = argumentValue(after: "--project", in: arguments),
              let outputPath = argumentValue(after: "--output", in: arguments) else {
            fputs("Missing required flags for --scene-lora-sweep.\n", stderr)
            fputs("Required: --project <path> --output <server-output-dir>\n", stderr)
            fputs("Optional: --host <draw-things-host> --port <draw-things-port>\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        let host = argumentValue(after: "--host", in: arguments) ?? "http://Garys-Server.local"
        let port = argumentValue(after: "--port", in: arguments).flatMap(Int.init) ?? 7860

        do {
            let result = try await AnimateAutomation.runDrawThingsSceneSweep(
                projectURL: URL(fileURLWithPath: projectPath),
                outputDirectoryURL: URL(fileURLWithPath: outputPath),
                drawThingsHost: host,
                drawThingsPort: port,
                onEvent: { line in
                    print(line)
                    fflush(stdout)
                }
            )

            print("SCENE_LORA_SWEEP_DONE")
            print("output_dir=\(result.outputDirectory)")
            print("generated_count=\(result.items.count)")
            print("failure_count=\(result.failures.count)")
            for item in result.items {
                print("item label=\(item.label) song=\(item.songPath) shot=\(item.shotNumber) moment=\(item.moment) image=\(item.imagePath)")
            }
            for failure in result.failures {
                print("failure \(failure)")
            }
        } catch {
            fputs("Scene LoRA sweep failed: \(error.localizedDescription)\n", stderr)
            fflush(stderr)
            Darwin.exit(EXIT_FAILURE)
        }

        return true
    }
}
