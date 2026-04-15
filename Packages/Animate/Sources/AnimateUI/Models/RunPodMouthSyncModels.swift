import Foundation

@available(macOS 26.0, *)
enum RunPodMouthSyncModels {
    struct InferenceConfig: Codable, Sendable {
        var modelVersion: ModelVersion = .museTalkV15
        var gpuProfile: GPUProfile = .rtx4090
        var batchSize: Int = 8
        var extraMargin: Int = 10
        var parsingMode: String = "jaw"
        var useFloat16: Bool = true
        var downloadModelsEachRun: Bool = true

        init() {}
    }

    enum ModelVersion: String, Codable, Sendable, CaseIterable, Identifiable {
        case museTalkV15 = "musetalk-v15"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .museTalkV15: "MuseTalk 1.5"
            }
        }

        var versionArgument: String {
            switch self {
            case .museTalkV15: "v15"
            }
        }

        var repoURL: String {
            "https://github.com/TMElyralab/MuseTalk.git"
        }
    }

    enum GPUProfile: String, Codable, Sendable, CaseIterable, Identifiable {
        case rtx4090 = "rtx-4090"
        case a40 = "a40"
        case l40s = "l40s"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .rtx4090: "RTX 4090"
            case .a40: "A40"
            case .l40s: "L40S"
            }
        }

        var gpuType: String {
            switch self {
            case .rtx4090: "NVIDIA RTX 4090"
            case .a40: "NVIDIA A40"
            case .l40s: "NVIDIA L40S"
            }
        }

        var minVRAMGB: Int {
            switch self {
            case .rtx4090: 24
            case .a40, .l40s: 48
            }
        }

        var containerDiskGB: Int {
            switch self {
            case .rtx4090: 80
            case .a40, .l40s: 100
            }
        }

        var gpuHourlyRateUSD: Double {
            switch self {
            case .rtx4090: 1.10
            case .a40: 1.22
            case .l40s: 1.90
            }
        }
    }

    enum PodStatus: String, Codable, Sendable {
        case inactive
        case creating
        case starting
        case uploading
        case settingUp
        case inferencing
        case downloading
        case stopping
        case error

        var isActive: Bool {
            switch self {
            case .inactive, .error: false
            default: true
            }
        }

        var displayName: String {
            switch self {
            case .inactive: "Inactive"
            case .creating: "Creating Pod..."
            case .starting: "Starting Pod..."
            case .uploading: "Uploading Inputs..."
            case .settingUp: "Setting Up MuseTalk..."
            case .inferencing: "Running MuseTalk..."
            case .downloading: "Downloading Result..."
            case .stopping: "Stopping Pod..."
            case .error: "Error"
            }
        }
    }

    struct InferenceJob: Identifiable, Codable, Sendable {
        var id: UUID
        var sourceVideoPath: String
        var audioPath: String
        var outputVideoPath: String
        var config: InferenceConfig
        var podID: String?
        var status: PodStatus
        var statusMessage: String?
        var errorMessage: String?
        var remoteOutputPath: String?
        var startedAt: Date?
        var completedAt: Date?

        init(
            id: UUID = UUID(),
            sourceVideoPath: String,
            audioPath: String,
            outputVideoPath: String,
            config: InferenceConfig,
            podID: String? = nil,
            status: PodStatus = .inactive,
            statusMessage: String? = nil,
            errorMessage: String? = nil,
            remoteOutputPath: String? = nil,
            startedAt: Date? = nil,
            completedAt: Date? = nil
        ) {
            self.id = id
            self.sourceVideoPath = sourceVideoPath
            self.audioPath = audioPath
            self.outputVideoPath = outputVideoPath
            self.config = config
            self.podID = podID
            self.status = status
            self.statusMessage = statusMessage
            self.errorMessage = errorMessage
            self.remoteOutputPath = remoteOutputPath
            self.startedAt = startedAt
            self.completedAt = completedAt
        }
    }
}
