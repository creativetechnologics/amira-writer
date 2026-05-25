import AppKit
import AVFoundation
import Foundation
import Observation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
extension MixStore {
    // MARK: - Browser Discovery

    nonisolated static func corruptBackupPath(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Metadata/mix_session.corrupt-\(formatter.string(from: date)).json"
    }

    nonisolated static func scanBrowserRoots(
        selectedScene: MixSceneSummary?,
        workingProjectURL: URL?
    ) async -> [MixBrowserNode] {
        let scanSemaphore = DispatchSemaphore(value: 0)
        let results = MixBrowserScanBox()
        DispatchQueue(label: "com.amira.mix.browserScan", qos: .utility).async {
            results.nodes = Self.candidateBrowserRootsSync(
                selectedScene: selectedScene,
                workingProjectURL: workingProjectURL
            )
            scanSemaphore.signal()
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.amira.mix.browserScanWait", qos: .utility).async {
                let completed = scanSemaphore.wait(timeout: .now() + 3) == .success
                if completed {
                    continuation.resume(returning: results.nodes)
                } else {
                    let fallback = workingProjectURL.map { Self.projectBrowserRootsSync(workingProjectURL: $0) } ?? []
                    continuation.resume(returning: fallback)
                }
            }
        }
    }

    nonisolated static func candidateBrowserRootsSync(
        selectedScene: MixSceneSummary?,
        workingProjectURL: URL?
    ) -> [MixBrowserNode] {
        let roots = candidateBrowserRoots(selectedScene: selectedScene, workingProjectURL: workingProjectURL)
        return roots.compactMap { root in
            buildBrowserNode(at: root, kind: .root, depth: 0)
        }
    }

    nonisolated static func projectBrowserRootsSync(workingProjectURL: URL) -> [MixBrowserNode] {
        let projectCandidates = [
            ProjectPaths(root: workingProjectURL).mixExports,
            ProjectPaths(root: workingProjectURL).mixes,
            workingProjectURL.appendingPathComponent("Renders", isDirectory: true),
            workingProjectURL.appendingPathComponent("Exports", isDirectory: true),
        ]
        var roots: [URL] = []
        for candidate in projectCandidates where pathExistsNoCloud(candidate.path) {
            roots.append(candidate.standardizedFileURL)
        }
        return roots.compactMap { buildBrowserNode(at: $0, kind: .root, depth: 0) }
    }

    nonisolated static func candidateBrowserRoots(
        selectedScene: MixSceneSummary?,
        workingProjectURL: URL?
    ) -> [URL] {
        var roots: [URL] = []
        if let projectURL = workingProjectURL {
            let projectExports = projectURL.appendingPathComponent("Exports", isDirectory: true)
            if Self.pathExistsNoCloud(projectExports.path) {
                roots.append(projectExports)
            }
        }
        if let workingProjectURL {
            let projectCandidates = [
                ProjectPaths(root: workingProjectURL).mixExports,
                ProjectPaths(root: workingProjectURL).mixes,
                workingProjectURL.appendingPathComponent("Renders", isDirectory: true),
                workingProjectURL.appendingPathComponent("Exports", isDirectory: true),
            ]
            for candidate in projectCandidates where !Task.isCancelled && Self.pathExistsNoCloud(candidate.path) {
                roots.append(candidate)
            }
        }
        var deduped: [String: URL] = [:]
        for root in roots {
            deduped[root.standardizedFileURL.path] = root.standardizedFileURL
        }
        return deduped.values.sorted { $0.path < $1.path }
    }

    nonisolated static func pathExistsNoCloud(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    nonisolated static func buildBrowserNode(at url: URL, kind: MixBrowserNode.Kind, depth: Int) -> MixBrowserNode? {
        let fm = FileManager.default
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR

        if isDirectory {
            let displayName: String
            if url.lastPathComponent.lowercased() == "exports" && url.deletingLastPathComponent().lastPathComponent == "Mix" {
                displayName = "Score"
            } else {
                displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            }
            guard depth < 6 else {
                return MixBrowserNode(name: displayName, path: url.path, kind: kind, children: [], fileSize: nil)
            }
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let children = contents.compactMap { childURL -> MixBrowserNode? in
                guard !Task.isCancelled else { return nil }
                let childKind: MixBrowserNode.Kind = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? .folder : .audio
                if childKind == .audio, Self.audioExtensions.contains(childURL.pathExtension.lowercased()) == false {
                    return nil
                }
                return buildBrowserNode(at: childURL, kind: childKind, depth: depth + 1)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            guard kind == .root || children.isEmpty == false else { return nil }
            return MixBrowserNode(
                name: displayName,
                path: url.path,
                kind: kind,
                children: children,
                fileSize: nil
            )
        }

        guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard Self.isBrowsableAudioFile(at: url, fileSize: size) else { return nil }
        return MixBrowserNode(
            name: url.lastPathComponent,
            path: url.path,
            kind: .audio,
            children: [],
            fileSize: size
        )
    }

    nonisolated static func isBrowsableAudioFile(at url: URL, fileSize: Int64?) -> Bool {
        guard let fileSize else { return true }
        if url.pathExtension.lowercased() == "wav", fileSize > 0, fileSize <= 4096 {
            return false
        }
        return true
    }

    nonisolated static func findBrowserNode(in nodes: [MixBrowserNode], path: String) -> MixBrowserNode? {
        for node in nodes {
            if node.path == path {
                return node
            }
            if let match = findBrowserNode(in: node.children, path: path) {
                return match
            }
        }
        return nil
    }

    nonisolated static func findBrowserAncestorPaths(in nodes: [MixBrowserNode], path: String) -> [String]? {
        for node in nodes {
            if node.path == path {
                return []
            }
            if let childMatch = findBrowserAncestorPaths(in: node.children, path: path) {
                return node.isDirectory ? [node.path] + childMatch : childMatch
            }
        }
        return nil
    }

    // MARK: - Audio Utilities

    nonisolated static func audioDurationSync(for url: URL) -> Double? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        let seconds = Double(audioFile.length) / sampleRate
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    nonisolated static func dropPreviewDuration(for url: URL) -> Double? {
        audioDurationSync(for: url)
    }

    nonisolated static func sourceGroupStatic(for fileURL: URL) -> String {
        let path = fileURL.path.lowercased()
        if path.contains("preview") { return "Preview" }
        if path.contains("export") { return "Export" }
        return "Project"
    }

    nonisolated static func colorHexStatic(for fileURL: URL) -> String {
        let path = fileURL.path.lowercased()
        if path.contains("preview") { return "#4A90E2" }
        if path.contains("export") { return "#39C0BA" }
        return "#6B8E6B"
    }

    // MARK: - Session Utilities

    nonisolated static let defaultFadeSeconds = 0.08

    nonisolated static func maximumFadeSeconds(for clip: MixClip) -> Double {
        min(max(clip.durationSeconds * 0.5, 0), 8)
    }

    nonisolated static func applyAutomaticCrossfades(in session: inout MixSceneSession, trackID: UUID) {
        let sortedIndices = session.clips.enumerated()
            .filter { $0.element.trackID == trackID }
            .sorted { lhs, rhs in
                if lhs.element.startSeconds != rhs.element.startSeconds {
                    return lhs.element.startSeconds < rhs.element.startSeconds
                }
                return lhs.element.name.localizedStandardCompare(rhs.element.name) == .orderedAscending
            }
            .map(\.offset)

        guard sortedIndices.count >= 2 else { return }

        var autoCrossfadeIn: Set<Int> = []
        var autoCrossfadeOut: Set<Int> = []

        for pairIndex in 0..<(sortedIndices.count - 1) {
            let currentIndex = sortedIndices[pairIndex]
            let nextIndex = sortedIndices[pairIndex + 1]

            let currentClip = session.clips[currentIndex]
            let nextClip = session.clips[nextIndex]
            let overlap = (currentClip.startSeconds + currentClip.durationSeconds) - nextClip.startSeconds

            if overlap > 0 {
                let currentFade = min(overlap, maximumFadeSeconds(for: currentClip))
                let nextFade = min(overlap, maximumFadeSeconds(for: nextClip))
                session.clips[currentIndex].fadeOutSeconds = max(session.clips[currentIndex].fadeOutSeconds, currentFade)
                session.clips[nextIndex].fadeInSeconds = max(session.clips[nextIndex].fadeInSeconds, nextFade)
                autoCrossfadeOut.insert(currentIndex)
                autoCrossfadeIn.insert(nextIndex)
            }
        }

        for idx in sortedIndices {
            if autoCrossfadeOut.contains(idx) == false {
                let maxFade = maximumFadeSeconds(for: session.clips[idx])
                if session.clips[idx].fadeOutSeconds > defaultFadeSeconds {
                    session.clips[idx].fadeOutSeconds = min(defaultFadeSeconds, maxFade)
                }
            }
            if autoCrossfadeIn.contains(idx) == false {
                let maxFade = maximumFadeSeconds(for: session.clips[idx])
                if session.clips[idx].fadeInSeconds > defaultFadeSeconds {
                    session.clips[idx].fadeInSeconds = min(defaultFadeSeconds, maxFade)
                }
            }
        }
    }

    nonisolated static func clampedTimelinePixelsPerSecond(_ value: Double) -> Double {
        min(max(value, minimumTimelinePixelsPerSecond), maximumTimelinePixelsPerSecond)
    }

    nonisolated static func repairSelection(in session: inout MixSceneSession) {
        if let selectedClipID = session.selectedClipID,
           let clip = session.clips.first(where: { $0.id == selectedClipID }),
           session.tracks.contains(where: { $0.id == clip.trackID }) {
            session.selectedTrackID = clip.trackID
        } else {
            session.selectedClipID = nil
            if session.tracks.contains(where: { $0.id == session.selectedTrackID }) == false {
                session.selectedTrackID = session.tracks.first?.id
            }
        }
    }

    // MARK: - Plugin Discovery

    nonisolated static func discoverPlugins() async -> [MixPluginInfo] {
        await Task.detached(priority: .utility) { () -> [MixPluginInfo] in
            let manager = AVAudioUnitComponentManager.shared()
            let types: [OSType] = [kAudioUnitType_MusicDevice, kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
            var results: [MixPluginInfo] = []
            var seen: Set<String> = []

            for type in types {
                let description = AudioComponentDescription(
                    componentType: type,
                    componentSubType: 0,
                    componentManufacturer: 0,
                    componentFlags: 0,
                    componentFlagsMask: 0
                )
                for component in manager.components(matching: description) {
                    let compDesc = component.audioComponentDescription
                    let identifier = "\(compDesc.componentType)-\(compDesc.componentSubType)-\(compDesc.componentManufacturer)"
                    guard seen.insert(identifier).inserted else { continue }
                    let label: String
                    switch compDesc.componentType {
                    case kAudioUnitType_Effect:
                        label = "Effect"
                    case kAudioUnitType_MusicEffect:
                        label = "Music FX"
                    case kAudioUnitType_MusicDevice:
                        label = "Instrument"
                    default:
                        label = "Audio Unit"
                    }
                    results.append(
                        MixPluginInfo(
                            id: identifier,
                            name: component.name.trimmingCharacters(in: .whitespacesAndNewlines),
                            manufacturerName: component.manufacturerName.trimmingCharacters(in: .whitespacesAndNewlines),
                            formatLabel: label,
                            hasCustomView: component.hasCustomView
                        )
                    )
                }
            }

            return results.sorted { lhs, rhs in
                let manufacturerOrder = lhs.manufacturerName.localizedCaseInsensitiveCompare(rhs.manufacturerName)
                if manufacturerOrder != .orderedSame {
                    return manufacturerOrder == .orderedAscending
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }.value
    }

    nonisolated static let trackPalette = ["#8C8C8C"]
}
