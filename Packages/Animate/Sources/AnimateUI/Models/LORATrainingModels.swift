import Foundation

@available(macOS 26.0, *)
enum LORATrainingModels {
    // Training configuration
    //
    // Defaults reflect 2026 best practices for character LORAs on Flux.2 Klein 9B:
    // - 20-50 character images ideal (our 27-image pose set is in range)
    // - Steps: hard-coded to 3000 for character training (BFL official recommendation)
    // - Learning rate: 1e-4 (BFL recommendation)
    // - Network rank: 64 (higher identity capacity for real-person likeness)
    // - Network alpha: 32 (half of rank is standard)
    // - Resolution: 1024 (matches BFL training example; downscales to 768 if needed)
    struct TrainingConfig: Codable, Sendable {
        var baseModel: BaseModel = .fluxKlein9B
        var preset: TrainingPreset = .high
        var triggerWord: String = ""
        var subjectClassNoun: String = "person"
        var networkDim: Int = 64
        var networkAlpha: Int = 32
        var learningRate: Double = 1e-4
        var resolution: Int = 1024
        var selectedImagePaths: [String] = []

        var steps: Int { TrainingPreset.enforcedSteps }

        enum CodingKeys: String, CodingKey {
            case baseModel
            case preset
            case triggerWord
            case subjectClassNoun
            case networkDim
            case networkAlpha
            case learningRate
            case resolution
            case selectedImagePaths
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            baseModel = try container.decodeIfPresent(BaseModel.self, forKey: .baseModel) ?? .fluxKlein9B
            preset = try container.decodeIfPresent(TrainingPreset.self, forKey: .preset) ?? .high
            triggerWord = try container.decodeIfPresent(String.self, forKey: .triggerWord) ?? ""
            subjectClassNoun = try container.decodeIfPresent(String.self, forKey: .subjectClassNoun) ?? "person"
            networkDim = try container.decodeIfPresent(Int.self, forKey: .networkDim) ?? 64
            networkAlpha = try container.decodeIfPresent(Int.self, forKey: .networkAlpha) ?? 32
            learningRate = try container.decodeIfPresent(Double.self, forKey: .learningRate) ?? 1e-4
            resolution = try container.decodeIfPresent(Int.self, forKey: .resolution) ?? 1024
            selectedImagePaths = try container.decodeIfPresent([String].self, forKey: .selectedImagePaths) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(baseModel, forKey: .baseModel)
            try container.encode(preset, forKey: .preset)
            try container.encode(triggerWord, forKey: .triggerWord)
            try container.encode(subjectClassNoun, forKey: .subjectClassNoun)
            try container.encode(networkDim, forKey: .networkDim)
            try container.encode(networkAlpha, forKey: .networkAlpha)
            try container.encode(learningRate, forKey: .learningRate)
            try container.encode(resolution, forKey: .resolution)
            try container.encode(selectedImagePaths, forKey: .selectedImagePaths)
        }
    }

    enum BaseModel: String, Codable, Sendable, CaseIterable, Identifiable {
        case fluxKlein4B = "flux2-klein-4b"
        case fluxKlein9B = "flux2-klein-base-9b"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .fluxKlein4B: "FLUX.2 Klein 4B Base"
            case .fluxKlein9B: "FLUX.2 Klein 9B Base"
            }
        }

        var shortLabel: String {
            switch self {
            case .fluxKlein4B: "4B"
            case .fluxKlein9B: "9B"
            }
        }

        var supportsDrawThingsActivation: Bool { true }

        /// Recommended GPU targets for reliable 1024px LoRA training.
        var gpuType: String {
            switch self {
            case .fluxKlein4B:
                return "NVIDIA RTX A6000"
            case .fluxKlein9B:
                return "NVIDIA A100 80GB PCIe"
            }
        }

        var minVRAM: Int {
            switch self {
            case .fluxKlein4B: 24
            case .fluxKlein9B: 80
            }
        }

        var containerDiskGB: Int {
            switch self {
            case .fluxKlein4B: 80
            case .fluxKlein9B: 160
            }
        }

        /// RunPod on-demand community cloud rate for the GPU this base model targets.
        /// A6000 community cloud is ~$0.49/hr; A100 80GB PCIe is ~$1.39/hr as of 2026-04.
        var gpuHourlyRateUSD: Double {
            switch self {
            case .fluxKlein4B: 0.49
            case .fluxKlein9B: 1.39
            }
        }

        var modelVersion: String {
            switch self {
            case .fluxKlein4B: "klein-base-4b"
            case .fluxKlein9B: "klein-base-9b"
            }
        }

        var modelRepoID: String {
            switch self {
            case .fluxKlein4B: "black-forest-labs/FLUX.2-klein-base-4B"
            case .fluxKlein9B: "black-forest-labs/FLUX.2-klein-base-9B"
            }
        }

        var modelFilename: String {
            switch self {
            case .fluxKlein4B: "flux-2-klein-base-4b.safetensors"
            case .fluxKlein9B: "flux-2-klein-base-9b.safetensors"
            }
        }

        var textEncoderRepoID: String {
            switch self {
            case .fluxKlein4B: "black-forest-labs/FLUX.2-klein-4B"
            case .fluxKlein9B: "black-forest-labs/FLUX.2-klein-9B"
            }
        }

        var primaryTextEncoderShard: String {
            switch self {
            case .fluxKlein4B: "text_encoder/model-00001-of-00002.safetensors"
            case .fluxKlein9B: "text_encoder/model-00001-of-00004.safetensors"
            }
        }

        var textEncoderFilenames: [String] {
            switch self {
            case .fluxKlein4B:
                return [
                    "text_encoder/config.json",
                    "text_encoder/generation_config.json",
                    "text_encoder/model-00001-of-00002.safetensors",
                    "text_encoder/model-00002-of-00002.safetensors",
                    "text_encoder/model.safetensors.index.json"
                ]
            case .fluxKlein9B:
                return [
                    "text_encoder/config.json",
                    "text_encoder/generation_config.json",
                    "text_encoder/model-00001-of-00004.safetensors",
                    "text_encoder/model-00002-of-00004.safetensors",
                    "text_encoder/model-00003-of-00004.safetensors",
                    "text_encoder/model-00004-of-00004.safetensors",
                    "text_encoder/model.safetensors.index.json"
                ]
            }
        }

        var qwenTokenizerRepoID: String {
            switch self {
            case .fluxKlein4B: "Qwen/Qwen3-4B"
            case .fluxKlein9B: "Qwen/Qwen3-8B"
            }
        }

        var outputFilenameSuffix: String? {
            switch self {
            case .fluxKlein4B:
                return nil
            case .fluxKlein9B:
                return rawValue
            }
        }

        func outputFilename(for triggerWord: String) -> String {
            let stem = triggerWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "recovered-lora"
                : triggerWord.trimmingCharacters(in: .whitespacesAndNewlines)
            if let suffix = outputFilenameSuffix {
                return "\(stem)-\(suffix).safetensors"
            }
            return "\(stem).safetensors"
        }
    }
    
    enum TrainingPreset: String, Codable, Sendable, CaseIterable, Identifiable {
        case quick = "quick"
        case standard = "standard"  
        case high = "high"

        static let enforcedSteps = 3000
        static let enforcedTimeoutSeconds = 9000
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .quick: "Legacy Quick (forced to 3000 steps)"
            case .standard: "Legacy Standard (forced to 3000 steps)"
            case .high: "High Quality (3000 steps, ~90 min)"
            }
        }
        
        var steps: Int { Self.enforcedSteps }
        
        var timeoutSeconds: Int { Self.enforcedTimeoutSeconds }
    }
    
    // Pod state
    enum PodStatus: String, Codable, Sendable {
        case inactive
        case creating
        case starting
        case running
        case uploading
        case training
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
            case .creating: "Creating Pod…"
            case .starting: "Starting…"
            case .running: "Running"
            case .uploading: "Uploading Images…"
            case .training: "Training LORA…"
            case .downloading: "Downloading LORA…"
            case .stopping: "Stopping Pod…"
            case .error: "Error"
            }
        }
    }
    
    struct TrainingJob: Identifiable, Codable, Sendable {
        var id: UUID = UUID()
        var characterName: String
        var characterSlug: String
        var triggerWord: String
        var config: TrainingConfig
        var animateDirectoryPath: String?
        var podID: String?
        var status: PodStatus = .inactive
        var currentStep: Int = 0
        var totalSteps: Int = 0
        var errorMessage: String?
        var startedAt: Date?
        var completedAt: Date?
        var outputLORAPath: String?
        var resolvedGPUHourlyRateUSD: Double?
        var latestRecoveredCheckpointRemotePath: String?
        var latestRecoveredCheckpointLocalPath: String?
        
        var progress: Double {
            guard totalSteps > 0 else { return 0 }
            return Double(currentStep) / Double(totalSteps)
        }

        /// Elapsed cost estimate based on the live RunPod GPU hourly rate captured at submission time
        /// when available, otherwise the configured base model fallback hourly rate.
        /// Meters from `startedAt` until `completedAt` (or now if still running).
        /// Returns 0 before startedAt is set.
        var estimatedCostUSD: Double {
            guard let start = startedAt else { return 0 }
            let end = completedAt ?? Date()
            let hours = end.timeIntervalSince(start) / 3600.0
            return max(0, hours * (resolvedGPUHourlyRateUSD ?? config.baseModel.gpuHourlyRateUSD))
        }

        /// Elapsed runtime formatted as "Xm Ys" (or "Xh Ym" if >= 1h). "--" if not started.
        var elapsedDisplay: String {
            guard let start = startedAt else { return "--" }
            let end = completedAt ?? Date()
            let secs = Int(end.timeIntervalSince(start))
            if secs >= 3600 {
                return "\(secs / 3600)h \((secs % 3600) / 60)m"
            } else {
                return "\(secs / 60)m \(secs % 60)s"
            }
        }
    }

    struct QueuedTrainingJob: Identifiable, Codable, Sendable {
        var id: UUID = UUID()
        var characterName: String
        var characterSlug: String
        var triggerWord: String
        var config: TrainingConfig
        var imagePaths: [String]
        var animateDirectoryPath: String
        var queuedAt: Date = Date()

        var summaryLabel: String {
            "\(config.baseModel.shortLabel) • \(imagePaths.count) imgs • trig \(triggerWord)"
        }
    }
    
    // Trigger word generation (from LORA Maker)
    static func generateTriggerWord(for name: String) -> String {
        let cleaned = name.lowercased().filter { $0.isLetter }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        let consonants = cleaned.filter { !vowels.contains($0) }
        let base: String
        if cleaned.count <= 4 {
            base = cleaned.padding(toLength: 4, withPad: "x", startingAt: 0)
        } else {
            let consonantStr = String(consonants.prefix(4))
            base = consonantStr.count >= 4 ? consonantStr : String(cleaned.prefix(4))
        }
        // Add 2-char hash for uniqueness
        let hash = String(format: "%02x", abs(name.lowercased().hashValue) % 256)
        return base + hash
    }
}
