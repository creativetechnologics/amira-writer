import AppKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
struct ContinuityBuilderGenerationRecord: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var sessionID: UUID
    var turnID: UUID
    var candidateID: UUID?
    var label: ContinuityBuilderCandidateLabel
    var provider: String
    var model: String
    var imageSize: String
    var aspectRatio: String
    var status: String
    var estimatedCostUSD: Double
    var prompt: String
    var promptPath: String?
    var responsePath: String?
    var imagePath: String?
    var referencePaths: [String]
    var errorMessage: String?
    var blockers: [AutomationBlocker]
}

@available(macOS 26.0, *)
struct ContinuityBuilderGenerationResult: Codable, Sendable, Hashable {
    var ok: Bool
    var mode: String
    var isDryRun: Bool
    var estimatedCostUSD: Double
    var maxCostUSD: Double
    var records: [ContinuityBuilderGenerationRecord]
    var session: ContinuityBuilderSession
    var blockers: [AutomationBlocker]
}

@available(macOS 26.0, *)
@MainActor
struct ContinuityBuilderGenerationService {
    var store: AnimateStore

    struct Request: Sendable {
        var session: ContinuityBuilderSession
        var turnID: UUID?
        var projectRoot: URL
        var mode: String
        var maxCostUSD: Double
        var candidateCount: Int
        var model: GeminiModel
        var imageSize: String
        var aspectRatio: String
        var apiKey: String
    }

    func generate(_ request: Request) async -> ContinuityBuilderGenerationResult {
        let normalizedMode = request.mode.lowercased() == "execute" ? "execute" : "dry_run"
        let isDryRun = normalizedMode != "execute"
        let count = min(max(request.candidateCount, 1), 2)
        let imageSize = request.imageSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1K" : request.imageSize
        let aspectRatio = request.aspectRatio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "4:3" : request.aspectRatio
        let estimatedCost = Double(count) * request.model.estimatedCost(for: imageSize)
        var blockers: [AutomationBlocker] = []
        guard let turnIndex = request.session.turns.firstIndex(where: { $0.id == (request.turnID ?? request.session.activeTurn?.id) }) else {
            blockers.append(.init(code: .needsManualReview, message: "Continuity Builder turn not found.", field: "turnID"))
            return .init(ok: false, mode: normalizedMode, isDryRun: isDryRun, estimatedCostUSD: estimatedCost, maxCostUSD: request.maxCostUSD, records: [], session: request.session, blockers: blockers)
        }
        var session = request.session
        let turn = session.turns[turnIndex]
        if !isDryRun, estimatedCost > request.maxCostUSD {
            blockers.append(.init(code: .blockedCostCap, message: "Estimated Vertex image cost $\(String(format: "%.3f", estimatedCost)) exceeds maxCostUSD $\(String(format: "%.3f", request.maxCostUSD)).", field: "maxCostUSD"))
        }
        if normalizedMode == "execute", let availability = store.geminiImageGenerationAvailabilityError {
            blockers.append(.init(code: .failedProviderError, message: availability.localizedDescription, field: "gemini"))
        }
        if !blockers.filter({ $0.severity == "blocking" }).isEmpty {
            return .init(ok: false, mode: normalizedMode, isDryRun: isDryRun, estimatedCostUSD: estimatedCost, maxCostUSD: request.maxCostUSD, records: [], session: session, blockers: blockers)
        }

        let referencePaths = Array(turn.candidates.compactMap(\.imagePath).filter {
            FileManager.default.fileExists(atPath: $0) && ContinuityBuilderService.isReferenceEligibleImagePath($0)
        }.sorted { lhs, rhs in
            let lhsRating = ContinuityBuilderService.referenceRating(forImagePath: lhs) ?? 0
            let rhsRating = ContinuityBuilderService.referenceRating(forImagePath: rhs) ?? 0
            if lhsRating != rhsRating { return lhsRating > rhsRating }
            return lhs < rhs
        }.prefix(6))
        let references = await Task.detached(priority: .userInitiated) {
            referencePaths.compactMap { GeminiImageService.referenceImage(from: URL(fileURLWithPath: $0)) }
        }.value
        let labels = labels(for: count)
        var records: [ContinuityBuilderGenerationRecord] = []
        var generatedCandidates: [ContinuityBuilderCandidate] = []

        for index in 0..<count {
            let label = labels[index]
            let prompt = executionPrompt(turn: turn, label: label, variantIndex: index, imageSize: imageSize, aspectRatio: aspectRatio, projectRoot: request.projectRoot)
            var record = ContinuityBuilderGenerationRecord(
                id: UUID(),
                createdAt: Date(),
                updatedAt: Date(),
                sessionID: session.id,
                turnID: turn.id,
                candidateID: nil,
                label: label,
                provider: "gemini",
                model: request.model.rawValue,
                imageSize: imageSize,
                aspectRatio: aspectRatio,
                status: isDryRun ? "planned" : "running",
                estimatedCostUSD: request.model.estimatedCost(for: imageSize),
                prompt: prompt,
                promptPath: nil,
                responsePath: nil,
                imagePath: nil,
                referencePaths: referencePaths,
                errorMessage: nil,
                blockers: []
            )
            do {
                try writeRecord(record, projectRoot: request.projectRoot)
                guard !isDryRun else {
                    records.append(record)
                    continue
                }
                let activityID = store.registerGeminiActivity(
                    kind: .immediate,
                    title: "Continuity Builder • \(turn.title) • \(label.displayName)",
                    source: "Continuity Builder"
                )
                store.logGeminiAPICall(endpoint: "image-generation", source: "ContinuityBuilderGenerationService.generate()")
                let result = try await GeminiImageService().generate(
                    request: .init(
                        prompt: prompt,
                        referenceImages: references,
                        model: request.model,
                        aspectRatio: aspectRatio,
                        imageSize: imageSize
                    ),
                    apiKey: request.apiKey
                )
                let savedURL = try await saveContinuityImage(
                    data: result.imageData,
                    prompt: prompt,
                    projectRoot: request.projectRoot,
                    turn: turn,
                    label: label
                )
                try writeGenerationSidecars(imageURL: savedURL, prompt: prompt, textResponse: result.textResponse, turn: turn, referencePaths: referencePaths)
                let generation = AnimateStore.CanvasGeneration(
                    createdAt: Date(),
                    prompt: "Continuity Builder — \(turn.title)\n\n\(prompt)",
                    model: request.model,
                    aspectRatio: aspectRatio,
                    imageSize: imageSize,
                    imagePath: savedURL.path,
                    referenceCount: referencePaths.count
                )
                store.appendCanvasGeneration(generation)
                let candidate = ContinuityBuilderCandidate(
                    label: label,
                    title: "Generated \(label.displayName): \(turn.title)",
                    imagePath: savedURL.path,
                    source: "Continuity Builder generated candidate",
                    referenceRole: "generated_candidate",
                    promptRole: "candidate for Gary feedback",
                    analysisSummary: nil
                )
                record.status = "completed"
                record.updatedAt = Date()
                record.candidateID = candidate.id
                record.imagePath = savedURL.path
                record.promptPath = savedURL.deletingPathExtension().appendingPathExtension("prompt.txt").path
                record.responsePath = savedURL.deletingPathExtension().appendingPathExtension("response.txt").path
                generatedCandidates.append(candidate)
                store.updateGeminiActivity(activityID, status: .completed, outputFilename: savedURL.lastPathComponent)
            } catch {
                record.status = "failed_provider_error"
                record.updatedAt = Date()
                record.errorMessage = error.localizedDescription
                record.blockers.append(.init(code: .failedProviderError, message: error.localizedDescription, field: "provider"))
            }
            try? writeRecord(record, projectRoot: request.projectRoot)
            records.append(record)
        }

        if !generatedCandidates.isEmpty {
            session.turns[turnIndex].candidates = generatedCandidates
            session.turns[turnIndex].requiresPaidGeneration = false
            session.turns[turnIndex].generationStatus = "generated_candidates_ready_for_feedback"
            session.updatedAt = Date()
            try? ContinuityBuilderService(store: store).writeSessionForGeneration(session, projectRoot: request.projectRoot)
        }
        let ok = blockers.filter { $0.severity == "blocking" }.isEmpty && !records.contains { $0.status.hasPrefix("failed") }
        return .init(ok: ok, mode: normalizedMode, isDryRun: isDryRun, estimatedCostUSD: estimatedCost, maxCostUSD: request.maxCostUSD, records: records, session: session, blockers: blockers)
    }

    private func labels(for count: Int) -> [ContinuityBuilderCandidateLabel] {
        switch count {
        case 1: return [.single]
        default: return [.left, .right]
        }
    }

    private func executionPrompt(turn: ContinuityBuilderTurn, label: ContinuityBuilderCandidateLabel, variantIndex: Int, imageSize: String, aspectRatio: String, projectRoot: URL) -> String {
        let query = [turn.title, turn.question, turn.promptSeed, turn.contextTags.joined(separator: " ")].joined(separator: "\n")
        let continuityRules = ContinuityRuleExtractionService.relevantPromptClauses(
            projectRoot: projectRoot,
            query: query,
            limit: 12
        )
        let recentFeedbackClauses = ContinuityBuilderService.promptClauses(
            from: ContinuityBuilderService.relevantFeedback(projectRoot: projectRoot, query: query, limit: 10)
        )
        let semanticRoles: [ImageLibrarySemanticRole]? = {
            switch turn.category {
            case .worldGeography, .landmarkBridge, .placeTopography, .vehicleProp, .sceneContinuity:
                return [.place]
            case .characterIdentity, .costumeContinuity:
                return [.character]
            case .styleContinuity:
                return nil
            }
        }()
        let preferenceClauses = ImagePreferenceProfileService.relevantPromptClauses(
            projectRoot: projectRoot,
            query: query,
            semanticRoles: semanticRoles,
            limit: 10
        )
        let memoryClauses = Array((continuityRules + recentFeedbackClauses + preferenceClauses).prefix(22))
        return [
            "Continuity Builder training candidate. Generate a single image for Gary to critique.",
            "Candidate label visible to the system: \(label.displayName). Do not render any label text in the image.",
            "Output format: \(aspectRatio) open-matte, \(imageSize). Keep a wider-than-needed field of view so later 21:9/vertical crops and camera moves remain possible.",
            turn.promptSeed,
            "Question this image is meant to answer: \(turn.question)",
            memoryClauses.isEmpty ? nil : [
                "AUTHORITATIVE CONTINUITY MEMORY — these rules override attached images, older generated examples, and any ambiguous visual reference.",
                "Do not reintroduce mistakes called out in negative feedback. If a prior image had a flat bridge and feedback says the bridge must be arched, the new image must use an arched bridge.",
                memoryClauses.joined(separator: "\n")
            ].joined(separator: "\n"),
            "Reference usage: attached images are continuity references, not collage panels. Preserve only the relevant geography/identity/costume/style facts that do not conflict with the authoritative continuity memory.",
            "Negative guardrails: \(turn.negativeGuardrails.joined(separator: " | "))",
            "Variant guidance: produce a distinct but plausible candidate \(variantIndex + 1), changing composition only enough to test the continuity question."
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    private func saveContinuityImage(data: Data, prompt: String, projectRoot: URL, turn: ContinuityBuilderTurn, label: ContinuityBuilderCandidateLabel) async throws -> URL {
        let dir = ProjectPaths(root: projectRoot).animateCanvasDir
        return try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let slug = turn.title.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(5).joined(separator: "-")
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let filename = "\(timestamp)-continuity-builder-\(label.rawValue)-\(slug.isEmpty ? "candidate" : slug).png"
            let url = dir.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    private func writeGenerationSidecars(imageURL: URL, prompt: String, textResponse: String?, turn: ContinuityBuilderTurn, referencePaths: [String]) throws {
        try prompt.write(to: imageURL.deletingPathExtension().appendingPathExtension("prompt.txt"), atomically: true, encoding: .utf8)
        if let textResponse, !textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try textResponse.write(to: imageURL.deletingPathExtension().appendingPathExtension("response.txt"), atomically: true, encoding: .utf8)
        }
        let metadata: [String: Any] = [
            "schemaVersion": 1,
            "workflow": "continuity_builder",
            "turnID": turn.id.uuidString,
            "turnTitle": turn.title,
            "category": turn.category.rawValue,
            "referencePaths": referencePaths
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: imageURL.deletingPathExtension().appendingPathExtension("continuity.json"), options: .atomic)
    }

    private func writeRecord(_ record: ContinuityBuilderGenerationRecord, projectRoot: URL) throws {
        let dir = ContinuityBuilderService.continuityDirectory(projectRoot: projectRoot)
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(record.sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(record.turnID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeCodable(record, to: dir.appendingPathComponent("\(record.id.uuidString).json"))
    }
}
