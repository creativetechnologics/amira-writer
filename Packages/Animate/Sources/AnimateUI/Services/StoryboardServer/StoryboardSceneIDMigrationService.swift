import Foundation
import ProjectKit

@available(macOS 26.0, *)
enum StoryboardSceneIDMigrationService {
    struct Report: Codable, Sendable {
        struct CopiedEntry: Codable, Sendable {
            var sourcePath: String
            var destinationPath: String
            var sceneID: UUID
            var shotID: UUID
            var frame: String
            var sourceModifiedAt: Date?
            var sourceSize: Int64
        }

        struct ConflictEntry: Codable, Sendable {
            var sceneID: UUID
            var shotID: UUID
            var frame: String
            var keptSourcePath: String
            var ignoredSourcePath: String
        }

        var migratedAt: Date = Date()
        var checkedPNGs: Int = 0
        var skippedCurrentSceneFiles: Int = 0
        var skippedUnknownShots: Int = 0
        var skippedExistingNewerOrSame: Int = 0
        var copied: [CopiedEntry] = []
        var conflicts: [ConflictEntry] = []
        var errors: [String] = []

        var didChangeProject: Bool {
            !copied.isEmpty || !errors.isEmpty
        }

        var summary: String {
            "checked \(checkedPNGs), copied \(copied.count), conflicts \(conflicts.count), skipped current \(skippedCurrentSceneFiles), skipped unknown \(skippedUnknownShots), skipped existing \(skippedExistingNewerOrSame), errors \(errors.count)"
        }
    }

    private struct ShotTarget: Sendable {
        var sceneID: UUID
        var shotID: UUID
        var frame: StoryboardFrame
    }

    private struct Candidate: Sendable {
        var target: ShotTarget
        var sourceURL: URL
        var modifiedAt: Date?
        var size: Int64
    }

    static func migrate(projectRoot: URL, scenes: [AnimationScene]) -> Report {
        let fm = FileManager.default
        let paths = ProjectPaths(root: projectRoot)
        let currentSceneIDs = Set(scenes.map(\.id))
        var shotToScene: [UUID: UUID] = [:]
        for scene in scenes {
            for shot in scene.shots where shotToScene[shot.id] == nil {
                shotToScene[shot.id] = scene.id
            }
        }

        var report = Report()
        var candidates: [String: Candidate] = [:]

        guard let sceneDirs = try? fm.contentsOfDirectory(
            at: paths.scenes,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return report
        }

        for sceneDir in sceneDirs {
            guard let sourceSceneID = UUID(uuidString: sceneDir.lastPathComponent),
                  (try? sceneDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let storyboardsDir = sceneDir.appendingPathComponent("storyboards", isDirectory: true)
            guard fm.fileExists(atPath: storyboardsDir.path),
                  let enumerator = fm.enumerator(
                    at: storyboardsDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            while let sourceURL = enumerator.nextObject() as? URL {
                guard sourceURL.pathExtension.lowercased() == "png",
                      let frame = StoryboardFrame(rawValue: sourceURL.deletingPathExtension().lastPathComponent),
                      let shotID = UUID(uuidString: sourceURL.deletingLastPathComponent().lastPathComponent) else {
                    continue
                }

                report.checkedPNGs += 1

                guard let targetSceneID = shotToScene[shotID] else {
                    report.skippedUnknownShots += 1
                    continue
                }
                guard sourceSceneID != targetSceneID else {
                    report.skippedCurrentSceneFiles += 1
                    continue
                }
                guard currentSceneIDs.contains(targetSceneID) else {
                    report.skippedUnknownShots += 1
                    continue
                }

                let values = try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let candidate = Candidate(
                    target: ShotTarget(sceneID: targetSceneID, shotID: shotID, frame: frame),
                    sourceURL: sourceURL,
                    modifiedAt: values?.contentModificationDate,
                    size: Int64(values?.fileSize ?? 0)
                )
                let key = "\(targetSceneID.uuidString)/\(shotID.uuidString)/\(frame.rawValue)"
                if let existing = candidates[key] {
                    let keepNew = isNewer(candidate, than: existing)
                    let kept = keepNew ? candidate : existing
                    let ignored = keepNew ? existing : candidate
                    candidates[key] = kept
                    report.conflicts.append(Report.ConflictEntry(
                        sceneID: targetSceneID,
                        shotID: shotID,
                        frame: frame.rawValue,
                        keptSourcePath: kept.sourceURL.path,
                        ignoredSourcePath: ignored.sourceURL.path
                    ))
                } else {
                    candidates[key] = candidate
                }
            }
        }

        for candidate in candidates.values {
            let dest = paths.shotStoryboardImage(
                sceneID: candidate.target.sceneID,
                shotID: candidate.target.shotID,
                frame: candidate.target.frame
            )
            if shouldSkipCopy(source: candidate, destination: dest) {
                report.skippedExistingNewerOrSame += 1
                continue
            }

            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = dest.deletingLastPathComponent()
                    .appendingPathComponent("\(dest.lastPathComponent).migration-\(UUID().uuidString).tmp")
                try fm.copyItem(at: candidate.sourceURL, to: tmp)
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: dest)
                }
                report.copied.append(Report.CopiedEntry(
                    sourcePath: candidate.sourceURL.path,
                    destinationPath: dest.path,
                    sceneID: candidate.target.sceneID,
                    shotID: candidate.target.shotID,
                    frame: candidate.target.frame.rawValue,
                    sourceModifiedAt: candidate.modifiedAt,
                    sourceSize: candidate.size
                ))
            } catch {
                report.errors.append("\(candidate.sourceURL.path): \(error.localizedDescription)")
            }
        }

        if report.didChangeProject {
            writeReport(report, projectRoot: projectRoot)
        }
        return report
    }

    private static func isNewer(_ lhs: Candidate, than rhs: Candidate) -> Bool {
        let lhsTime = lhs.modifiedAt ?? .distantPast
        let rhsTime = rhs.modifiedAt ?? .distantPast
        if lhsTime != rhsTime {
            return lhsTime > rhsTime
        }
        return lhs.size > rhs.size
    }

    private static func shouldSkipCopy(source: Candidate, destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path) else {
            return false
        }
        let destTime = attrs[.modificationDate] as? Date ?? .distantPast
        let destSize = attrs[.size] as? NSNumber
        let sourceTime = source.modifiedAt ?? .distantPast
        if destTime > sourceTime {
            return true
        }
        if destTime == sourceTime, destSize?.int64Value == source.size {
            return true
        }
        return false
    }

    private static func writeReport(_ report: Report, projectRoot: URL) {
        do {
            let url = ProjectPaths(root: projectRoot).scenes
                .appendingPathComponent("storyboard-scene-id-migration-report.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[StoryboardMigration] Failed to write migration report: %@", error.localizedDescription)
        }
    }
}
