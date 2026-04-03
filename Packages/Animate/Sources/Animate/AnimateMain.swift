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
        AnimateBootstrap.main()
    }

    private static func handleSnapshotCommand() async -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--snapshot") else { return false }

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        guard let projectPath = value(after: "--project"),
              let scenePath = value(after: "--scene"),
              let outputPath = value(after: "--output")
        else {
            fputs("Missing required flags for --snapshot.\n", stderr)
            fputs("Required: --project <path> --scene <relative-song-path> --output <png>\n", stderr)
            return true
        }

        let frame = value(after: "--frame").flatMap(Int.init) ?? 0
        let width = value(after: "--width").flatMap(Double.init) ?? 2100
        let height = value(after: "--height").flatMap(Double.init) ?? 900
        let mode = value(after: "--mode").flatMap(AnimationPreviewSnapshotMode.init(rawValue:)) ?? .live

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
}
