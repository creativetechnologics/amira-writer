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
    var editSourcePath: String?
    var reviewSubjectName: String?
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

    private struct ReferenceSelection {
        var candidates: [ContinuityBuilderCandidate]
        var editSourcePath: String?
        var masterMapPath: String?
        var characterContract: CharacterGenerationContract?
        var blockers: [AutomationBlocker]

        var orderedReferencePaths: [String] {
            var seen = Set<String>()
            var paths: [String] = []
            for path in [editSourcePath, masterMapPath] + candidates.compactMap(\.imagePath) {
                guard let path, !path.isEmpty, seen.insert(path).inserted else { continue }
                paths.append(path)
            }
            return paths
        }
    }

    private struct CharacterGenerationContract {
        var characterName: String
        var costumeName: String
        var wardrobeType: CharacterWardrobeType
        var identityReferenceCount: Int
        var costumeReferenceCount: Int

        var promptClause: String {
            let wardrobeText: String
            switch wardrobeType {
            case .soldier:
                wardrobeText = "This is a soldier character. The character must wear the approved military costume/uniform/camouflage from the attached costume reference: boots, belt/kit, accessories, and camouflage/color blocking must match. Do not put the character in civilian clothing, neutral model-sheet clothing, underwear, or a generic jacket."
            case .civilian:
                wardrobeText = "This is a civilian character. The character must wear the approved plain-clothes costume from the attached costume reference. Do not put the character in military gear unless that exact approved costume reference shows it."
            }
            return [
                "Character costume contract: Target character is \(characterName). Required costume is \(costumeName).",
                "Use the attached identity reference(s) only for \(characterName)'s face, age, hair, proportions, and silhouette.",
                "Use the attached approved costume reference(s) as the hard clothing authority.",
                wardrobeText,
                "Do not invent a generic man/woman/person. Do not substitute a different face. Do not generate an out-of-costume version. Do not include a canonical place background."
            ].joined(separator: " ")
        }
    }

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
        let count = 1
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

        let referenceSelection = referenceSelection(for: turn, projectRoot: request.projectRoot)
        blockers.append(contentsOf: referenceSelection.blockers)
        if !blockers.filter({ $0.severity == "blocking" }).isEmpty {
            return .init(ok: false, mode: normalizedMode, isDryRun: isDryRun, estimatedCostUSD: estimatedCost, maxCostUSD: request.maxCostUSD, records: [], session: session, blockers: blockers)
        }
        let referencePaths = referenceSelection.orderedReferencePaths
        let referenceLoad = await Task.detached(priority: .userInitiated) { () -> (references: [GeminiImageService.ReferenceImage], loadBlockers: [AutomationBlocker]) in
            var references: [GeminiImageService.ReferenceImage] = []
            var loadBlockers: [AutomationBlocker] = []
            for path in referencePaths {
                let url = URL(fileURLWithPath: path)
                let isRequired = path == referenceSelection.editSourcePath || path == referenceSelection.masterMapPath
                if isRequired {
                    do {
                        references.append(try GeminiImageService.requiredReferenceImage(from: url))
                    } catch {
                        let code: AutomationBlockerCode = path == referenceSelection.editSourcePath
                            ? .blockedMissingEditSource
                            : .blockedMissingReferenceRole
                        loadBlockers.append(.init(code: code, message: error.localizedDescription, field: path))
                    }
                } else if let reference = GeminiImageService.referenceImage(from: url) {
                    references.append(reference)
                }
            }
            return (references: references, loadBlockers: loadBlockers)
        }.value
        blockers.append(contentsOf: referenceLoad.loadBlockers)
        if !blockers.filter({ $0.severity == "blocking" }).isEmpty {
            return .init(ok: false, mode: normalizedMode, isDryRun: isDryRun, estimatedCostUSD: estimatedCost, maxCostUSD: request.maxCostUSD, records: [], session: session, blockers: blockers)
        }
        let references = referenceLoad.references
        let isEditRequest = referenceSelection.editSourcePath != nil
        let labels = labels(for: count)
        var records: [ContinuityBuilderGenerationRecord] = []
        var generatedCandidates: [ContinuityBuilderCandidate] = []

        for index in 0..<count {
            let label = labels[index]
            let prompt = executionPrompt(
                turn: turn,
                label: label,
                variantIndex: index,
                imageSize: imageSize,
                aspectRatio: aspectRatio,
                projectRoot: request.projectRoot,
                characterContract: referenceSelection.characterContract,
                isEditRequest: isEditRequest,
                hasMasterMapReference: referenceSelection.masterMapPath != nil
            )
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
                editSourcePath: referenceSelection.editSourcePath,
                reviewSubjectName: referenceSelection.characterContract?.characterName,
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
                store.logGeminiAPICall(endpoint: isEditRequest ? "image-edit" : "image-generation", source: "ContinuityBuilderGenerationService.generate()")
                let result = try await GeminiImageService().generate(
                    request: .init(
                        prompt: prompt,
                        referenceImages: references,
                        model: request.model,
                        aspectRatio: aspectRatio,
                        imageSize: imageSize,
                        referenceImagesFirst: isEditRequest
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
                writeReviewScopeSidecar(for: savedURL.path, turn: turn, characterName: referenceSelection.characterContract?.characterName)
                try writeGenerationSidecars(
                    imageURL: savedURL,
                    prompt: prompt,
                    textResponse: result.textResponse,
                    turn: turn,
                    referencePaths: referencePaths,
                    editSourcePath: referenceSelection.editSourcePath,
                    masterMapPath: referenceSelection.masterMapPath,
                    reviewSubjectName: referenceSelection.characterContract?.characterName
                )
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
                    source: ContinuityBuilderService.generatedCandidateSource,
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
            if let merged = try? ContinuityBuilderService(store: store).mergeGeneratedCandidates(
                sessionID: session.id,
                fallbackSession: session,
                turnID: turn.id,
                generatedCandidates: generatedCandidates,
                projectRoot: request.projectRoot
            ) {
                session = merged
            } else {
                session.turns[turnIndex].candidates = generatedCandidates
                session.turns[turnIndex].requiresPaidGeneration = false
                session.turns[turnIndex].generationStatus = "generated_candidates_ready_for_feedback"
                session.updatedAt = Date()
                try? ContinuityBuilderService(store: store).writeSessionForGeneration(session, projectRoot: request.projectRoot)
            }
        }
        let ok = blockers.filter { $0.severity == "blocking" }.isEmpty && !records.contains { $0.status.hasPrefix("failed") }
        return .init(ok: ok, mode: normalizedMode, isDryRun: isDryRun, estimatedCostUSD: estimatedCost, maxCostUSD: request.maxCostUSD, records: records, session: session, blockers: blockers)
    }

    private func writeReviewScopeSidecar(for path: String, turn: ContinuityBuilderTurn, characterName: String?) {
        var existing = ImageLibraryMetadataSidecarService.load(forImagePath: path)
            ?? ImageLibraryReviewMetadata(rating: nil, isRejected: false, notes: "", updatedAt: nil)
        existing.semanticRole = semanticRole(for: turn.category)
        let contractTags = characterName.map { [$0] } ?? []
        existing.characterTags = Array(Set(existing.characterTags + contractTags + matchingCharacterTags(for: turn))).sorted()
        existing.updatedAt = Date()
        ImageLibraryMetadataSidecarService.save(existing, forImagePath: path)
    }

    private func semanticRole(for category: ContinuityBuilderCategory) -> ImageLibrarySemanticRole? {
        switch category {
        case .worldGeography, .placeTopography, .landmarkBridge, .vehicleProp, .sceneContinuity:
            return .place
        case .characterIdentity, .costumeContinuity:
            return .character
        case .styleContinuity:
            return nil
        }
    }

    private func matchingCharacterTags(for turn: ContinuityBuilderTurn) -> [String] {
        guard semanticRole(for: turn.category) == .character else { return [] }
        let haystack = [turn.title, turn.question, turn.promptSeed, turn.contextTags.joined(separator: " ")]
            .joined(separator: "\n")
            .lowercased()
        return store.characters.compactMap { character in
            let name = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, haystack.contains(name.lowercased()) else { return nil }
            return name
        }
    }

    private func labels(for count: Int) -> [ContinuityBuilderCandidateLabel] {
        [.single]
    }

    private func referenceSelection(for turn: ContinuityBuilderTurn, projectRoot: URL) -> ReferenceSelection {
        var blockers: [AutomationBlocker] = []
        let editSourceCandidate = turn.candidates.first { $0.source == ContinuityBuilderService.editSourceCandidateSource || $0.referenceRole == "edit_source" }
        let editSourcePath = editSourceCandidate?.imagePath.flatMap { ContinuityBuilderService.runtimePath($0, projectRoot: projectRoot) }
        if editSourceCandidate != nil {
            if let editSourcePath, FileManager.default.fileExists(atPath: editSourcePath) {
                // Good: the edit source is allowed even if Gary rejected it, because the
                // rejected image is being used as the pixels-to-repair, not as a positive reference.
            } else {
                blockers.append(.init(code: .blockedMissingEditSource, message: "The requested edit cannot run because the displayed source image is missing.", field: "edit_source"))
            }
        }

        let masterMapPath: String?
        if requiresMasterMap(for: turn.category) {
            masterMapPath = canonicalMasterMapPath(projectRoot: projectRoot)
            if masterMapPath == nil {
                blockers.append(.init(code: .blockedMissingReferenceRole, message: "Place/terrain continuity generation is blocked because the canonical master map reference could not be found in Animate/reference-registry.json.", field: "spatial_map"))
            }
        } else {
            masterMapPath = nil
        }

        let eligibleCandidates = turn.candidates
            .compactMap { candidate -> ContinuityBuilderCandidate? in
                guard let imagePath = candidate.imagePath,
                      FileManager.default.fileExists(atPath: imagePath),
                      candidate.referenceRole != "edit_source" else { return nil }
                if let masterMapPath, imagePath == masterMapPath { return nil }
                let isCanonicalCharacterReference = candidate.source == "Characters/*/rig.json"
                    && (candidate.referenceRole == "character_identity" || candidate.referenceRole == "character_costume")
                    && !ContinuityBuilderService.isRejectedImagePath(imagePath)
                guard ContinuityBuilderService.isReferenceEligibleImagePath(imagePath) || isCanonicalCharacterReference else { return nil }
                return candidate
            }
            .sorted { lhs, rhs in
                let lhsScore = lhs.imagePath.flatMap(ContinuityBuilderService.referencePreferenceScore(forImagePath:)) ?? 0
                let rhsScore = rhs.imagePath.flatMap(ContinuityBuilderService.referencePreferenceScore(forImagePath:)) ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                let lhsDate = lhs.imagePath.flatMap(ImagePreferenceProfileService.referenceUpdatedAt(forImagePath:)) ?? .distantPast
                let rhsDate = rhs.imagePath.flatMap(ImagePreferenceProfileService.referenceUpdatedAt(forImagePath:)) ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

        switch turn.category {
        case .characterIdentity, .costumeContinuity:
            guard let contractSelection = characterReferenceSelection(from: eligibleCandidates, projectRoot: projectRoot) else {
                return .init(
                    candidates: [],
                    editSourcePath: editSourcePath,
                    masterMapPath: masterMapPath,
                    characterContract: nil,
                    blockers: blockers + [
                        .init(
                            code: .blockedMissingReferenceRole,
                            message: "Character continuity generation is blocked until a rated, non-rejected identity reference and a rated, non-rejected approved costume reference exist for the same named character.",
                            field: "character_costume_contract"
                        )
                    ]
                )
            }
            return .init(
                candidates: contractSelection.candidates,
                editSourcePath: editSourcePath,
                masterMapPath: masterMapPath,
                characterContract: contractSelection.contract,
                blockers: blockers
            )
        default:
            return .init(
                candidates: Array(eligibleCandidates.prefix(6)),
                editSourcePath: editSourcePath,
                masterMapPath: masterMapPath,
                characterContract: nil,
                blockers: blockers
            )
        }
    }

    private func requiresMasterMap(for category: ContinuityBuilderCategory) -> Bool {
        switch category {
        case .worldGeography, .placeTopography, .landmarkBridge, .sceneContinuity:
            return true
        case .characterIdentity, .costumeContinuity, .vehicleProp, .styleContinuity:
            return false
        }
    }

    private func canonicalMasterMapPath(projectRoot: URL) -> String? {
        let registryURL = ProjectPaths(root: projectRoot).animate.appendingPathComponent("reference-registry.json")
        guard let data = try? Data(contentsOf: registryURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backgrounds = object["backgrounds"] as? [[String: Any]] else { return nil }
        for entry in backgrounds {
            let name = (entry["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name == "map" else { continue }
            let entryBase = (entry["absolute_path"] as? String).flatMap { ContinuityBuilderService.runtimePath($0, projectRoot: projectRoot) }
            for file in (entry["files"] as? [[String: Any]] ?? []) {
                let rawPath = file["absolute_path"] as? String ?? file["path"] as? String
                var candidates: [String] = []
                if let rawPath,
                   let resolved = ContinuityBuilderService.runtimePath(rawPath, projectRoot: projectRoot) {
                    candidates.append(resolved)
                }
                if let relative = file["relative_to_root"] as? String {
                    if let entryBase {
                        candidates.append(URL(fileURLWithPath: entryBase).appendingPathComponent(relative).path)
                    }
                    candidates.append(ProjectPaths(root: projectRoot).animate.appendingPathComponent(relative).path)
                }
                if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    return found
                }
            }
        }
        return nil
    }

    private func characterReferenceSelection(from candidates: [ContinuityBuilderCandidate], projectRoot: URL) -> (candidates: [ContinuityBuilderCandidate], contract: CharacterGenerationContract)? {
        struct CandidateContract {
            var character: AnimationCharacter
            var costumeName: String
            var identity: [ContinuityBuilderCandidate]
            var costume: [ContinuityBuilderCandidate]
            var score: Double
        }

        let targetNames = Set(candidates
            .filter { $0.referenceRole == "character_identity" || $0.referenceRole == "character_costume" }
            .map { characterName(fromCandidateTitle: $0.title) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() })

        let contracts: [CandidateContract] = store.characters.compactMap { character in
            let characterName = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !characterName.isEmpty else { return nil }
            if !targetNames.isEmpty, !targetNames.contains(characterName.lowercased()) {
                return nil
            }
            var identity = Array(candidates
                .filter { $0.referenceRole == "character_identity" && candidate($0, belongsTo: characterName) }
                .prefix(2))
            if identity.isEmpty, let fallbackIdentity = canonicalIdentityCandidate(for: character, projectRoot: projectRoot) {
                identity = [fallbackIdentity]
            }
            var costumes = candidates
                .filter { $0.referenceRole == "character_costume" && candidate($0, belongsTo: characterName) }
            if costumes.isEmpty, let fallbackCostume = canonicalCostumeCandidate(for: character, projectRoot: projectRoot) {
                costumes = [fallbackCostume]
            }
            guard let firstCostume = costumes.first else { return nil }
            guard !identity.isEmpty else { return nil }
            let costumeName = costumeName(from: firstCostume.title, characterName: characterName)
            let selectedCostumes = Array(costumes.prefix(2))
            let selectedIdentity = Array(identity)
            let score = (selectedIdentity + selectedCostumes)
                .compactMap { $0.imagePath.flatMap(ContinuityBuilderService.referencePreferenceScore(forImagePath:)) }
                .reduce(0, +)
            return CandidateContract(
                character: character,
                costumeName: costumeName,
                identity: selectedIdentity,
                costume: selectedCostumes,
                score: score
            )
        }
        guard let best = contracts.max(by: { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.character.name.localizedCaseInsensitiveCompare(rhs.character.name) == .orderedDescending
        }) else { return nil }
        let contract = CharacterGenerationContract(
            characterName: best.character.name,
            costumeName: best.costumeName,
            wardrobeType: best.character.defaultWardrobeType,
            identityReferenceCount: best.identity.count,
            costumeReferenceCount: best.costume.count
        )
        return (Array((best.identity + best.costume).prefix(4)), contract)
    }

    private func characterName(fromCandidateTitle title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = trimmed.firstIndex(of: ":") {
            return String(trimmed[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func canonicalIdentityCandidate(for character: AnimationCharacter, projectRoot: URL) -> ContinuityBuilderCandidate? {
        let approvedMaster = (character.masterReferenceSheetVariants.first { $0.id == character.approvedMasterReferenceSheetVariantID } ?? character.masterReferenceSheetVariants.last)?.imagePath
        let approvedHead = (character.headTurnaroundSheetVariants.first { $0.id == character.approvedHeadTurnaroundSheetVariantID } ?? character.headTurnaroundSheetVariants.last)?.imagePath
        let rawPaths = [approvedHead, approvedMaster, character.profileImagePath, character.inspirationReferenceImagePath] + character.referenceImagePaths.prefix(2).map(Optional.init)
        guard let path = rawPaths.compactMap({ canonicalReferencePath($0, projectRoot: projectRoot) }).first else { return nil }
        return .init(
            label: .single,
            title: character.name,
            imagePath: path,
            source: "Characters/*/rig.json",
            referenceRole: "character_identity",
            promptRole: "canonical character identity reference"
        )
    }

    private func canonicalCostumeCandidate(for character: AnimationCharacter, projectRoot: URL) -> ContinuityBuilderCandidate? {
        for costume in character.costumeReferenceSets {
            let approved = costume.approvedSheetVariant?.imagePath ?? costume.sheetVariants.last?.imagePath
            let rawPaths = [approved] + costume.costumeReferenceImagePaths.prefix(2).map(Optional.init)
            if let path = rawPaths.compactMap({ canonicalReferencePath($0, projectRoot: projectRoot) }).first {
                return .init(
                    label: .single,
                    title: "\(character.name): \(costume.name)",
                    imagePath: path,
                    source: "Characters/*/rig.json",
                    referenceRole: "character_costume",
                    promptRole: "canonical costume continuity reference"
                )
            }
        }
        return nil
    }

    private func canonicalReferencePath(_ rawPath: String?, projectRoot: URL) -> String? {
        guard let path = ContinuityBuilderService.runtimePath(rawPath, projectRoot: projectRoot),
              FileManager.default.fileExists(atPath: path),
              !ContinuityBuilderService.isRejectedImagePath(path) else { return nil }
        return path
    }

    private func candidate(_ candidate: ContinuityBuilderCandidate, belongsTo characterName: String) -> Bool {
        let lowerTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerName = characterName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowerTitle == lowerName || lowerTitle.hasPrefix(lowerName + ":")
    }

    private func costumeName(from title: String, characterName: String) -> String {
        let prefix = characterName + ":"
        if title.localizedCaseInsensitiveContains(prefix),
           let range = title.range(of: prefix, options: [.caseInsensitive]) {
            return title[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }

    private func executionPrompt(
        turn: ContinuityBuilderTurn,
        label: ContinuityBuilderCandidateLabel,
        variantIndex: Int,
        imageSize: String,
        aspectRatio: String,
        projectRoot: URL,
        characterContract: CharacterGenerationContract?,
        isEditRequest: Bool,
        hasMasterMapReference: Bool
    ) -> String {
        let query = [turn.title, turn.question, turn.promptSeed, turn.contextTags.joined(separator: " ")].joined(separator: "\n")
        let continuityRules = ContinuityRuleExtractionService.relevantPromptClauses(
            projectRoot: projectRoot,
            query: query,
            limit: 12
        )
        let targetedFeedbackClauses = ContinuityBuilderService.promptClauses(
            from: ContinuityBuilderService.relevantFeedback(projectRoot: projectRoot, query: query, limit: 10)
        )
        let recentFeedbackClauses = ContinuityBuilderService.promptClauses(
            from: ContinuityBuilderService.loadAllFeedback(projectRoot: projectRoot)
                .sorted { $0.submittedAt > $1.submittedAt }
                .prefix(8)
                .map { $0 }
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
        let memoryClauses = Array(Self.uniqueClauses(continuityRules + targetedFeedbackClauses + recentFeedbackClauses + preferenceClauses).prefix(30))
        return [
            "Continuity Builder training candidate. Generate a single image for Gary to critique.",
            "Review category: \(turn.category.reviewSubjectLabel).",
            subjectIsolationPrompt(for: turn.category),
            "Candidate label visible to the system: \(label.displayName). Do not render any label text in the image.",
            "Output format: \(aspectRatio) open-matte, \(imageSize). Keep a wider-than-needed field of view so later 21:9/vertical crops and camera moves remain possible.",
            isEditRequest ? "EDIT MODE: the first attached image is the source image to edit. Apply Gary's direct edit request from the prompt seed while preserving everything already correct: composition, layout, identity, costume, lighting, camera, style, and continuity facts. Do not start over from a blank generation unless the source image is impossible to edit." : nil,
            hasMasterMapReference ? "MASTER MAP HARD RULE: the attached master valley top-down map is the canonical geography/layout reference. Follow it for river direction, north-bank settlement placement, town/hill distance from river, bridge/ravine relationship, road approach, cemetery/base placement, and forbidden wrong-side buildings. Do not invent a different town/river/bridge layout." : nil,
            "Human wardrobe hard rule: every visible person must be fully clothed in story-appropriate wardrobe. Soldier characters must wear their approved military uniform/camouflage, boots, belts, and assigned accessories. Civilian characters must wear their approved plain clothes. If an attached reference is an unclothed/neutral/body model sheet, use it only for face/body identity and replace the clothing with the correct approved costume; never copy nudity, underwear, bare torsos, or missing wardrobe into the generated image.",
            characterContract?.promptClause,
            turn.promptSeed,
            "Question this image is meant to answer: \(turn.question)",
            memoryClauses.isEmpty ? nil : [
                "AUTHORITATIVE CONTINUITY MEMORY — these rules override attached images, older generated examples, and any ambiguous visual reference.",
                "Do not reintroduce mistakes called out in negative feedback. If a prior image had a flat bridge and feedback says the bridge must be arched, the new image must use an arched bridge.",
                memoryClauses.joined(separator: "\n")
            ].joined(separator: "\n"),
            "Reference usage: attached images are continuity references, not collage panels. Preserve only the relevant geography/identity/costume/style facts that do not conflict with the authoritative continuity memory.",
            "Character reference usage: identity references control face, age, hair, proportions, and silhouette; costume references and continuity memory control clothing. Do not let an unclothed or neutral character reference override the required costume.",
            characterContract == nil ? nil : "Final character override: if any other instruction or attached image conflicts with the named character/costume contract, follow the character/costume contract. Generate no background landmarks; the image is for character/costume judgment only.",
            "Negative guardrails: \(turn.negativeGuardrails.joined(separator: " | "))",
            "Variant guidance: produce a distinct but plausible candidate \(variantIndex + 1), changing composition only enough to test the continuity question."
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    private static func uniqueClauses(_ clauses: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for clause in clauses {
            let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            unique.append(trimmed)
        }
        return unique
    }

    private func subjectIsolationPrompt(for category: ContinuityBuilderCategory) -> String {
        switch category {
        case .worldGeography, .placeTopography, .landmarkBridge, .sceneContinuity:
            return "Subject isolation hard rule: this is a PLACE training image. Generate geography, architecture, materials, roads, river, bridge, ravine, and other place/landmark facts only. Do not include named characters, character portraits, soldiers, civilians, or full-body people as review subjects. If scale would require people, omit people instead. Gary's like/reject decision applies only to place continuity."
        case .characterIdentity, .costumeContinuity:
            return "Subject isolation hard rule: this is a CHARACTER training image. Generate the character or costume reference only, not a place/landscape shot. Use a plain, neutral, or extremely simple non-canonical background with no recognizable town, bridge, valley, river, road network, or landmark. Gary's like/reject decision applies only to character/costume continuity."
        case .vehicleProp:
            return "Subject isolation hard rule: this is a VEHICLE / PROP training image. Isolate the vehicle or prop; do not include named characters and do not turn it into a canonical place/landscape composition. Gary's like/reject decision applies only to the object."
        case .styleContinuity:
            return "Subject isolation hard rule: this is a STYLE training image. Use a simple unpopulated frame that demonstrates line, color, texture, grain, lighting, and open-matte composition without teaching character identity or place geography."
        }
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

    private func writeGenerationSidecars(
        imageURL: URL,
        prompt: String,
        textResponse: String?,
        turn: ContinuityBuilderTurn,
        referencePaths: [String],
        editSourcePath: String?,
        masterMapPath: String?,
        reviewSubjectName: String?
    ) throws {
        try prompt.write(to: imageURL.deletingPathExtension().appendingPathExtension("prompt.txt"), atomically: true, encoding: .utf8)
        if let textResponse, !textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try textResponse.write(to: imageURL.deletingPathExtension().appendingPathExtension("response.txt"), atomically: true, encoding: .utf8)
        }
        let referenceDetails = referencePaths.map { path -> [String: String] in
            let role: String
            if path == editSourcePath {
                role = "edit_source"
            } else if path == masterMapPath {
                role = "spatial_map"
            } else {
                role = "continuity_reference"
            }
            return ["path": path, "role": role]
        }
        var metadata: [String: Any] = [
            "schemaVersion": 1,
            "workflow": "continuity_builder",
            "turnID": turn.id.uuidString,
            "turnTitle": turn.title,
            "category": turn.category.rawValue,
            "referencePaths": referencePaths,
            "referenceDetails": referenceDetails
        ]
        if let editSourcePath { metadata["editSourcePath"] = editSourcePath }
        if let masterMapPath { metadata["masterMapPath"] = masterMapPath }
        if let reviewSubjectName { metadata["reviewSubjectName"] = reviewSubjectName }
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
