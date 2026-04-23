import Foundation
import os

/// Centralized signpost logger so Instruments can measure the four hottest
/// Amira Writer code paths without us hand-plumbing `OSSignposter` at every
/// call site.
///
/// Usage:
/// ```
/// let token = PerfSignposts.begin(.projectOpen)
/// defer { PerfSignposts.end(.projectOpen, token: token) }
/// ```
/// `PerfSignposts.event` is for one-shot markers (e.g. "hydration finished").
public enum PerfSignposts {
    public enum Area: String {
        case projectOpen = "Project.Open"
        case modeSwitch = "Mode.Switch"
        case allImagesRebuild = "AllImages.Rebuild"
        case inspectorSelection = "Inspector.Selection"
    }

    nonisolated(unsafe) public static let log = OSLog(
        subsystem: "com.amira.writer",
        category: "Perf"
    )

    nonisolated(unsafe) public static let signposter = OSSignposter(logHandle: log)

    public static func begin(_ area: Area, _ detail: String = "") -> OSSignpostIntervalState {
        let name: StaticString
        switch area {
        case .projectOpen: name = "Project.Open"
        case .modeSwitch: name = "Mode.Switch"
        case .allImagesRebuild: name = "AllImages.Rebuild"
        case .inspectorSelection: name = "Inspector.Selection"
        }
        return signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(detail)")
    }

    public static func end(_ area: Area, token: OSSignpostIntervalState) {
        let name: StaticString
        switch area {
        case .projectOpen: name = "Project.Open"
        case .modeSwitch: name = "Mode.Switch"
        case .allImagesRebuild: name = "AllImages.Rebuild"
        case .inspectorSelection: name = "Inspector.Selection"
        }
        signposter.endInterval(name, token)
    }

    public static func event(_ area: Area, _ detail: String) {
        let name: StaticString
        switch area {
        case .projectOpen: name = "Project.Open"
        case .modeSwitch: name = "Mode.Switch"
        case .allImagesRebuild: name = "AllImages.Rebuild"
        case .inspectorSelection: name = "Inspector.Selection"
        }
        signposter.emitEvent(name, "\(detail)")
    }
}
