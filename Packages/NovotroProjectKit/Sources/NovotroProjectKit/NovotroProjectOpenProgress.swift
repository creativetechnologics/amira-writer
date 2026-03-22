import Combine
import Foundation

public struct NPProjectAssetSummary: Codable, Sendable, Hashable {
    public var assetCount: Int
    public var totalBytes: Int64

    public init(assetCount: Int, totalBytes: Int64) {
        self.assetCount = assetCount
        self.totalBytes = totalBytes
    }
}

@MainActor
public final class NovotroProjectOpenProgressCenter: ObservableObject {
    public struct Snapshot: Equatable, Sendable {
        public var projectPath: String
        public var projectName: String
        public var phaseTitle: String
        public var detail: String
        public var startedAt: Date
        public var updatedAt: Date
        public var completedUnitCount: Int?
        public var totalUnitCount: Int?
        public var completedBytes: Int64?
        public var totalBytes: Int64?
        public var currentItemPath: String?

        public init(
            projectPath: String,
            projectName: String,
            phaseTitle: String,
            detail: String,
            startedAt: Date,
            updatedAt: Date,
            completedUnitCount: Int? = nil,
            totalUnitCount: Int? = nil,
            completedBytes: Int64? = nil,
            totalBytes: Int64? = nil,
            currentItemPath: String? = nil
        ) {
            self.projectPath = projectPath
            self.projectName = projectName
            self.phaseTitle = phaseTitle
            self.detail = detail
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.completedUnitCount = completedUnitCount
            self.totalUnitCount = totalUnitCount
            self.completedBytes = completedBytes
            self.totalBytes = totalBytes
            self.currentItemPath = currentItemPath
        }

        public var fractionCompleted: Double? {
            if let totalBytes, totalBytes > 0, let completedBytes {
                return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
            }
            if let totalUnitCount, totalUnitCount > 0, let completedUnitCount {
                return min(max(Double(completedUnitCount) / Double(totalUnitCount), 0), 1)
            }
            return nil
        }

        public var progressSummary: String? {
            var components: [String] = []

            if let completedUnitCount, let totalUnitCount, totalUnitCount > 0 {
                components.append("\(completedUnitCount) of \(totalUnitCount) files")
            }

            if let completedBytes, let totalBytes, totalBytes > 0 {
                components.append("\(Self.byteString(completedBytes)) of \(Self.byteString(totalBytes))")
            } else if let totalBytes, totalBytes > 0 {
                components.append(Self.byteString(totalBytes))
            }

            return components.isEmpty ? nil : components.joined(separator: " • ")
        }

        public func elapsedDescription(referenceDate: Date = Date()) -> String {
            let elapsed = max(Int(referenceDate.timeIntervalSince(startedAt)), 0)
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            return String(format: "%d:%02d elapsed", minutes, seconds)
        }

        private static func byteString(_ value: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
            formatter.countStyle = .file
            formatter.includesUnit = true
            formatter.isAdaptive = true
            return formatter.string(fromByteCount: value)
        }
    }

    public static let shared = NovotroProjectOpenProgressCenter()

    @Published public private(set) var snapshotsByProjectPath: [String: Snapshot] = [:]

    private init() {}

    public func snapshot(for projectPath: String?) -> Snapshot? {
        guard let projectPath else { return nil }
        return snapshotsByProjectPath[projectPath]
    }

    public func start(
        projectURL: URL,
        phaseTitle: String,
        detail: String,
        completedUnitCount: Int? = nil,
        totalUnitCount: Int? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        currentItemPath: String? = nil
    ) {
        let now = Date()
        let normalizedURL = normalizedProjectURL(projectURL)
        let snapshot = Snapshot(
            projectPath: normalizedURL.path,
            projectName: normalizedURL.deletingPathExtension().lastPathComponent,
            phaseTitle: phaseTitle,
            detail: detail,
            startedAt: now,
            updatedAt: now,
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            currentItemPath: currentItemPath
        )
        snapshotsByProjectPath[normalizedURL.path] = snapshot
    }

    public func update(
        projectURL: URL,
        phaseTitle: String? = nil,
        detail: String? = nil,
        completedUnitCount: Int? = nil,
        totalUnitCount: Int? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        currentItemPath: String? = nil
    ) {
        let normalizedURL = normalizedProjectURL(projectURL)
        let path = normalizedURL.path
        let now = Date()
        let startedAt = snapshotsByProjectPath[path]?.startedAt ?? now
        let previous = snapshotsByProjectPath[path]

        snapshotsByProjectPath[path] = Snapshot(
            projectPath: path,
            projectName: normalizedURL.deletingPathExtension().lastPathComponent,
            phaseTitle: phaseTitle ?? previous?.phaseTitle ?? "Opening Project",
            detail: detail ?? previous?.detail ?? "Preparing the local mirror.",
            startedAt: startedAt,
            updatedAt: now,
            completedUnitCount: completedUnitCount ?? previous?.completedUnitCount,
            totalUnitCount: totalUnitCount ?? previous?.totalUnitCount,
            completedBytes: completedBytes ?? previous?.completedBytes,
            totalBytes: totalBytes ?? previous?.totalBytes,
            currentItemPath: currentItemPath ?? previous?.currentItemPath
        )
    }

    public func finish(projectURL: URL) {
        snapshotsByProjectPath.removeValue(forKey: normalizedProjectURL(projectURL).path)
    }

    private func normalizedProjectURL(_ projectURL: URL) -> URL {
        projectURL.resolvingSymlinksInPath().standardizedFileURL
    }
}
