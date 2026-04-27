import CryptoKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
struct ContinuityBuilderService {
    var store: AnimateStore

    nonisolated static let currentGenerationPolicyMarker = "Subject isolation hard rule:"
    nonisolated static let currentGenerationCategoryMarker = "Review category:"
    nonisolated static let generatedCandidateSource = "Continuity Builder generated candidate"
    nonisolated static let editSourceCandidateSource = "Continuity Builder edit source"

    func loadOrCreateSession(projectRoot: URL) async -> ContinuityBuilderSession {
        if var existing = readLatestSession(projectRoot: projectRoot) {
            if existing.hasStarted, existing.turns.isEmpty {
                existing.turns = await seedTurns(projectRoot: projectRoot)
                existing.updatedAt = Date()
                try? writeSession(existing, projectRoot: projectRoot)
            } else if !existing.hasStarted, (!existing.turns.isEmpty || !existing.feedback.isEmpty || !existing.notes.isEmpty) {
                existing.activeTurnIndex = 0
                existing.turns = []
                existing.feedback = []
                existing.notes = ""
                existing.updatedAt = Date()
                try? writeSession(existing, projectRoot: projectRoot)
            }
            var hydrated = Self.runtimeSession(Self.sessionWithLatestGeneratedCandidates(existing, projectRoot: projectRoot), projectRoot: projectRoot)
            Self.restoreReferenceCandidatesForUngeneratedTurns(
                &hydrated,
                projectRoot: projectRoot,
                backgrounds: store.backgrounds,
                characters: store.characters
            )
            return hydrated
        }
        let session = ContinuityBuilderSession(projectRoot: projectRoot.path)
        try? writeSession(session, projectRoot: projectRoot)
        try? writeLatestPointer(sessionID: session.id, projectRoot: projectRoot)
        var hydrated = Self.runtimeSession(Self.sessionWithLatestGeneratedCandidates(session, projectRoot: projectRoot), projectRoot: projectRoot)
        Self.restoreReferenceCandidatesForUngeneratedTurns(
            &hydrated,
            projectRoot: projectRoot,
            backgrounds: store.backgrounds,
            characters: store.characters
        )
        return hydrated
    }

    func begin(session: ContinuityBuilderSession, projectRoot: URL) async throws -> ContinuityBuilderSession {
        let backgrounds = store.backgrounds
        let characters = store.characters
        var updated = session
        updated.startedAt = updated.startedAt ?? Date()
        updated.activeTurnIndex = 0
        updated.feedback = []
        updated.notes = ""
        updated.turns = await Task.detached(priority: .userInitiated) {
            Array(Self.seedTurns(projectRoot: projectRoot, backgrounds: backgrounds, characters: characters).prefix(1))
        }.value
        updated.updatedAt = Date()
        try writeSession(updated, projectRoot: projectRoot)
        return Self.runtimeSession(Self.sessionWithLatestGeneratedCandidates(updated, projectRoot: projectRoot), projectRoot: projectRoot)
    }

    func recordFeedback(
        session: ContinuityBuilderSession,
        turn: ContinuityBuilderTurn,
        selectedLabel: ContinuityBuilderCandidateLabel?,
        closenessPercent: Int,
        notes: String,
        transcriptAudioPath: String?,
        projectRoot: URL
    ) async throws -> ContinuityBuilderSession {
        let feedback = ContinuityBuilderFeedback(
            sessionID: session.id,
            turnID: turn.id,
            selectedCandidateLabel: selectedLabel,
            closenessPercent: closenessPercent,
            notes: notes,
            transcriptAudioPath: transcriptAudioPath,
            interpretedFocus: Self.interpretedFocus(from: notes, turn: turn)
        )
        var updated = session
        updated.feedback.removeAll { $0.turnID == turn.id }
        updated.feedback.append(feedback)
        let currentIndex = updated.turns.firstIndex(where: { $0.id == turn.id }) ?? updated.activeTurnIndex
        let completedPrefix = updated.turns.indices.contains(currentIndex)
            ? Array(updated.turns.prefix(currentIndex + 1))
            : updated.turns
        let futureTurns = updated.turns.indices.contains(currentIndex)
            ? Array(updated.turns.dropFirst(currentIndex + 1))
            : []
        let nextTurn: ContinuityBuilderTurn
        if let editTurn = editTurn(after: turn, feedback: feedback, projectRoot: projectRoot) {
            nextTurn = editTurn
        } else {
            let bufferedChoice = Self.selectBufferedTurn(from: futureTurns, after: turn, feedback: feedback, projectRoot: projectRoot)
            nextTurn = bufferedChoice ?? nextStreamTurn(after: turn, feedback: feedback, projectRoot: projectRoot)
        }
        let remainingFuture = futureTurns.filter { $0.id != nextTurn.id }
        updated.turns = completedPrefix + [nextTurn] + Array(remainingFuture.prefix(4))
        updated.activeTurnIndex = completedPrefix.count
        updated.updatedAt = Date()
        try writeFeedback(feedback, sessionID: session.id, projectRoot: projectRoot)
        try writeSession(updated, projectRoot: projectRoot)
        try writeIndex(projectRoot: projectRoot)
        return updated
    }

    private func editTurn(after turn: ContinuityBuilderTurn, feedback: ContinuityBuilderFeedback, projectRoot: URL) -> ContinuityBuilderTurn? {
        guard let editInstruction = Self.editInstruction(from: feedback.notes),
              let selectedLabel = feedback.selectedCandidateLabel,
              let sourceCandidate = turn.candidates.first(where: { $0.label == selectedLabel }),
              let sourcePath = sourceCandidate.imagePath,
              FileManager.default.fileExists(atPath: sourcePath) else { return nil }
        let templates = Self.seedTurns(projectRoot: projectRoot, backgrounds: store.backgrounds, characters: store.characters)
        let templateCandidates = templates.first(where: { $0.category == turn.category })?.candidates ?? []
        let editSource = ContinuityBuilderCandidate(
            label: .single,
            title: "Previous image to edit",
            imagePath: sourcePath,
            source: Self.editSourceCandidateSource,
            referenceRole: "edit_source",
            promptRole: "source image for requested Gemini edit",
            analysisSummary: nil
        )
        var next = turn
        next.id = UUID()
        next.createdAt = Date()
        next.title = "Edit: \(turn.category.displayName)"
        next.question = "Review the edited image. Did the requested change land while preserving everything else that was working?"
        next.priorityReason = "Gary's feedback was interpreted as a direct edit request, so the next candidate edits the displayed image instead of starting from a blank generation."
        next.promptSeed = [
            turn.promptSeed,
            "Edit instruction: \(ContinuityPromptMemoryCompiler.cleaned(editInstruction))",
            "Use the previous displayed image as the edit source. Preserve all correct composition, identity, costume, lighting, style, geometry, and continuity facts not explicitly changed by the edit instruction."
        ].joined(separator: "\n\n")
        next.candidates = [editSource] + templateCandidates
        next.contextTags = Array(Set(turn.contextTags + feedback.interpretedFocus + ["edit", "source-image"])).sorted()
        next.requiresPaidGeneration = false
        next.generationStatus = "ready_for_generation"
        return next
    }

    func move(session: ContinuityBuilderSession, delta: Int, projectRoot: URL) throws -> ContinuityBuilderSession {
        var updated = session
        updated.activeTurnIndex = min(max(updated.activeTurnIndex + delta, 0), max(updated.turns.count - 1, 0))
        updated.updatedAt = Date()
        try writeSession(updated, projectRoot: projectRoot)
        return updated
    }

    func writeSessionForGeneration(_ session: ContinuityBuilderSession, projectRoot: URL) throws {
        try writeSession(session, projectRoot: projectRoot)
        try writeIndex(projectRoot: projectRoot)
    }

    func mergeGeneratedCandidates(
        sessionID: UUID,
        fallbackSession: ContinuityBuilderSession,
        turnID: UUID,
        generatedCandidates: [ContinuityBuilderCandidate],
        projectRoot: URL
    ) throws -> ContinuityBuilderSession {
        var latest = readSession(id: sessionID.uuidString, projectRoot: projectRoot) ?? fallbackSession
        guard let turnIndex = latest.turns.firstIndex(where: { $0.id == turnID }) else {
            return latest
        }
        latest.turns[turnIndex].candidates = generatedCandidates
        latest.turns[turnIndex].requiresPaidGeneration = false
        latest.turns[turnIndex].generationStatus = "generated_candidates_ready_for_feedback"
        latest.updatedAt = Date()
        try writeSession(latest, projectRoot: projectRoot)
        try writeIndex(projectRoot: projectRoot)
        return Self.runtimeSession(latest, projectRoot: projectRoot)
    }

    func ensureBufferedTurn(
        session: ContinuityBuilderSession,
        projectRoot: URL,
        maxBuffered: Int
    ) async throws -> ContinuityBuilderSession {
        guard session.hasStarted,
              let activeTurn = session.activeTurn else { return session }
        let futureTurns = Array(session.turns.dropFirst(session.activeTurnIndex + 1))
        guard futureTurns.count < maxBuffered else { return session }
        if futureTurns.contains(where: { $0.generationStatus == "ready_for_generation" }) {
            return session
        }
        let categoriesAlreadyBuffered = Set(futureTurns.map(\.category))
        let templates = await seedTurns(projectRoot: projectRoot)
        guard let category = Self.bufferCategory(after: activeTurn.category, excluding: categoriesAlreadyBuffered),
              var buffered = templates.first(where: { $0.category == category }) else { return session }
        buffered.id = UUID()
        buffered.createdAt = Date()
        buffered.title = "Continuity stream: \(buffered.category.displayName)"
        buffered.priorityReason = "Pre-buffered in the background from an independent continuity lane so the next image can be ready without waiting."
        buffered.requiresPaidGeneration = false
        buffered.generationStatus = "ready_for_generation"

        var updated = session
        updated.turns.append(buffered)
        let activePrefix = Array(updated.turns.prefix(updated.activeTurnIndex + 1))
        let cappedFuture = Array(updated.turns.dropFirst(updated.activeTurnIndex + 1).prefix(maxBuffered))
        updated.turns = activePrefix + cappedFuture
        updated.updatedAt = Date()
        try writeSession(updated, projectRoot: projectRoot)
        return Self.runtimeSession(updated, projectRoot: projectRoot)
    }

    static func relevantFeedback(projectRoot: URL, query: String, limit: Int = 6) -> [ContinuityBuilderFeedback] {
        let terms = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        guard !terms.isEmpty else { return [] }
        let feedback = loadAllFeedback(projectRoot: projectRoot).filter(
            \.shouldBecomePromptMemory
        )
        var scored: [(ContinuityBuilderFeedback, Int)] = []
        for item in feedback {
            let haystack = ([item.notes] + item.interpretedFocus).joined(separator: "\n").lowercased()
            let score = terms.reduce(0) { partial, term in partial + (haystack.contains(term) ? 1 : 0) }
            if score > 0 { scored.append((item, score)) }
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.submittedAt > rhs.0.submittedAt
        }
        .prefix(max(1, limit))
        .map(\.0)
    }

    static func promptClauses(from feedback: [ContinuityBuilderFeedback]) -> [String] {
        feedback.compactMap { item in
            let prefix: String?
            if item.closenessPercent >= 80 {
                prefix = "Preserve"
            } else if item.closenessPercent <= 40 {
                prefix = "Avoid"
            } else {
                prefix = nil
            }
            return ContinuityPromptMemoryCompiler.visualInstruction(
                from: item.notes,
                prefix: prefix,
                maxCharacters: 180
            )
        }
    }

    nonisolated static func editInstruction(from notes: String) -> String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }
        let lower = trimmed.lowercased()
        let editMarkers = [
            "edit this", "edit it", "change this", "change it", "make this", "make it",
            "fix this", "fix it", "adjust this", "adjust it", "replace ", "remove ",
            "add ", "move ", "turn this", "turn it", "keep everything else",
            "preserve everything", "same image but", "same picture but"
        ]
        if editMarkers.contains(where: { lower.contains($0) }) {
            return trimmed
        }
        if lower.contains("should be") || lower.contains("should not") || lower.contains("needs to") || lower.contains("too ") {
            return trimmed
        }
        return nil
    }

    nonisolated static func isCurrentGeneratedCandidate(_ candidate: ContinuityBuilderCandidate, projectRoot: URL) -> Bool {
        guard candidate.source == generatedCandidateSource,
              let imagePath = candidate.imagePath else { return false }
        let promptURL = promptURL(forImagePath: imagePath, projectRoot: projectRoot)
        guard let prompt = try? String(contentsOf: promptURL, encoding: .utf8) else { return false }
        return prompt.contains(currentGenerationPolicyMarker) && prompt.contains(currentGenerationCategoryMarker)
    }

    nonisolated static func turnHasCurrentGeneratedCandidate(_ turn: ContinuityBuilderTurn, projectRoot: URL) -> Bool {
        turn.generationStatus == "generated_candidates_ready_for_feedback"
            && turn.candidates.contains { isCurrentGeneratedCandidate($0, projectRoot: projectRoot) }
    }

    nonisolated private static func promptURL(forImagePath imagePath: String, projectRoot: URL) -> URL {
        let imageURL = imagePath.hasPrefix("/")
            ? URL(fileURLWithPath: imagePath)
            : projectRoot.appendingPathComponent(imagePath)
        return imageURL.deletingPathExtension().appendingPathExtension("prompt.txt")
    }

    private func seedTurns(projectRoot: URL) async -> [ContinuityBuilderTurn] {
        Self.seedTurns(projectRoot: projectRoot, backgrounds: store.backgrounds, characters: store.characters)
    }

    nonisolated private static func seedTurns(
        projectRoot: URL,
        backgrounds: [BackgroundPlate],
        characters: [AnimationCharacter]
    ) -> [ContinuityBuilderTurn] {
        var warnings: [String] = []
        let world = AutomationSourceResolver.worldContext(projectRoot: projectRoot, warnings: &warnings)
        let styleLock = animatedLookPrompt(projectRoot: projectRoot) ?? ""
        let geographyPrompt = [
            "Build a canonical 4:3 open-matte continuity reference for the Persian-Afghan highland valley world.",
            "World period: \(world?.timePeriod ?? "UNKNOWN — read Places/places-world-context.json before generation.")",
            "Environmental rules: \(world?.environmental ?? "Use canonical Places/places-world-context.json cues.")",
            "Style lock: \(styleLock.isEmpty ? "Use Settings/animated-look-prompt.json before generation." : styleLock)",
            "Emphasize river direction, north-bank settlement only, bridge/ravine relationship, hill placement, sparse early-2000s infrastructure, and camera-room for later 21:9 crops."
        ].joined(separator: "\n")

        var turns: [ContinuityBuilderTurn] = []
        turns.append(
            ContinuityBuilderTurn(
                category: .worldGeography,
                title: "World map / valley baseline",
                question: "What is wrong or right about the overall geography? Call out river direction, hill/town placement, bridge/ravine depth, sun direction, and forbidden buildings.",
                priorityReason: "World geography mistakes poison every later scene prompt, so this is the first knowledge pathway.",
                promptSeed: geographyPrompt,
                negativeGuardrails: baseNegativeGuardrails(world: world),
                candidates: registryCandidates(projectRoot: projectRoot, names: ["map"], fallback: firstPlaceCandidates(backgrounds: backgrounds, projectRoot: projectRoot, limit: 3)),
                contextTags: ["map", "river", "bridge", "ravine", "town", "topography"]
            )
        )

        turns.append(
            ContinuityBuilderTurn(
                category: .landmarkBridge,
                title: "Bridge / ravine continuity",
                question: "What has to be fixed about the bridge, ravine, water/flood logic, nearby soil, road approach, and whether the town is too close to the river?",
                priorityReason: "The bridge/ravine/town relationship is a high-frequency continuity anchor and a story-critical geography rule.",
                promptSeed: [geographyPrompt, "Now isolate the bridge as the landmark: it sits down in a ravine, can become impassable in flooding, and should not create a forest of extra bridges."].joined(separator: "\n\n"),
                negativeGuardrails: baseNegativeGuardrails(world: world) + ["No extra bridges unless explicitly requested.", "No buildings on the wrong side of the river."],
                candidates: registryCandidates(projectRoot: projectRoot, names: ["bridge", "map"], fallback: bridgePlaceCandidates(backgrounds: backgrounds, projectRoot: projectRoot, limit: 3)),
                contextTags: ["bridge", "ravine", "flood", "river", "town"]
            )
        )

        let placeCandidates = firstPlaceCandidates(backgrounds: backgrounds, projectRoot: projectRoot, limit: 3)
        turns.append(
            ContinuityBuilderTurn(
                category: .placeTopography,
                title: "Town / place topography",
                question: "What place/topography details are wrong? Mention whether the town belongs uphill, what materials/roads/signage should look like, and what should be forbidden.",
                priorityReason: "Place-level correction memory lets future shot prompts retrieve exact geography/material constraints instead of generic town imagery.",
                promptSeed: [geographyPrompt, "Use the shown place references only as candidates; extract correction rules that future prompts can apply."].joined(separator: "\n\n"),
                negativeGuardrails: baseNegativeGuardrails(world: world),
                candidates: placeCandidates,
                contextTags: ["place", "town", "topography", "materials", "signage"]
            )
        )

        let characterCandidates = firstCharacterCandidates(characters: characters, projectRoot: projectRoot, limit: 3)
        let costumeCandidates = firstCostumeCandidates(characters: characters, projectRoot: projectRoot, limit: 3, fallback: [])
        turns.append(
            ContinuityBuilderTurn(
                category: .characterIdentity,
                title: "Character identity anchors",
                question: "Which identity details must be preserved? Mention face angle, age, hair/headgear, accessories, and whether this is the right type of reference for close-up vs full body.",
                priorityReason: "Character identity references should be classified before they are reused as generation references.",
                promptSeed: [
                    "Extract durable character identity rules from the shown reference candidates. Prefer close-up/head-turn refs for face angle and full-body refs for silhouette.",
                    "Every generated person must be fully clothed in story-appropriate wardrobe. Soldier characters must wear their approved military uniform/camouflage, boots, belts, and assigned accessories; civilian characters must wear their approved plain clothes."
                ].joined(separator: "\n"),
                negativeGuardrails: [
                    "Do not mix characters.",
                    "Do not use a full-frame scene as a face identity reference if a tighter head reference exists.",
                    "No nudity, underwear, unclothed model-sheet bodies, bare torsos, or missing wardrobe.",
                    "Do not copy unclothed/neutral reference clothing state into a generated continuity image."
                ],
                candidates: characterCandidates + costumeCandidates,
                contextTags: ["character", "identity", "head", "face", "turnaround", "costume", "uniform"]
            )
        )

        turns.append(
            ContinuityBuilderTurn(
                category: .costumeContinuity,
                title: "Costume / accessory continuity",
                question: "What clothing, camouflage, satchels, belts, cameras, footwear, dirt/wear, or accessories must be exact every time?",
                priorityReason: "Costume/accessory drift is one of the easiest continuity breaks for viewers to notice.",
                promptSeed: "Extract script-supervisor costume continuity rules. Treat camouflage pattern, color blocking, accessories, and carried objects as hard constraints. Every generated person must be fully clothed; soldiers must always be in the approved uniform/camouflage unless a later explicit story rule says otherwise.",
                negativeGuardrails: [
                    "Do not simplify camouflage into generic green texture.",
                    "Do not move carried objects to the neck/hand if the continuity rule says belt/satchel.",
                    "No nudity, underwear, unclothed model-sheet bodies, bare torsos, or missing wardrobe."
                ],
                candidates: costumeCandidates.isEmpty ? characterCandidates : costumeCandidates,
                contextTags: ["costume", "camouflage", "accessory", "satchel", "polaroid"]
            )
        )

        turns.append(
            ContinuityBuilderTurn(
                category: .styleContinuity,
                title: "Animated style lock check",
                question: "What makes this fit or not fit the current animated style? Mention grain, lens, texture, palette, CGI smoothness, and whether the 4:3 open-matte frame gives enough crop room.",
                priorityReason: "Style drift should be corrected separately from geography and subject identity so future prompts can keep a stable look.",
                promptSeed: ["Use Settings/animated-look-prompt.json as the style lock.", styleLock].joined(separator: "\n"),
                negativeGuardrails: ["No HDR punch.", "No CGI-smooth plastic look.", "No narrow 21:9-only composition during training; keep 4:3 open matte."],
                candidates: placeCandidates + characterCandidates.prefix(max(0, 3 - placeCandidates.count)),
                contextTags: ["style", "grain", "lens", "palette", "open-matte", "4:3"]
            )
        )
        return turns
    }

    private func nextStreamTurn(after turn: ContinuityBuilderTurn, feedback: ContinuityBuilderFeedback, projectRoot: URL) -> ContinuityBuilderTurn {
        let category = Self.nextCategory(after: turn, feedback: feedback)
        let templates = Self.seedTurns(projectRoot: projectRoot, backgrounds: store.backgrounds, characters: store.characters)
        var next = templates.first(where: { $0.category == category }) ?? turn
        next.id = UUID()
        next.createdAt = Date()
        next.title = Self.nextTitle(for: category, feedback: feedback)
        next.question = Self.nextQuestion(for: category, feedback: feedback)
        next.priorityReason = "Chosen dynamically from the latest continuity note and accumulated prompt-memory tags; this is one continuous stream, not a separate sidebar track."
        let feedbackInstruction = ContinuityPromptMemoryCompiler.visualInstruction(
            from: feedback.notes,
            prefix: feedback.closenessPercent >= 80 ? "Preserve" : "Repair",
            maxCharacters: 180
        )
        next.promptSeed = [
            next.promptSeed,
            feedbackInstruction,
            "Carry forward established accepted continuity facts."
        ].compactMap { $0 }.joined(separator: "\n\n")
        next.contextTags = Array(Set(next.contextTags + feedback.interpretedFocus)).sorted()
        next.requiresPaidGeneration = false
        next.generationStatus = "ready_for_generation"
        return next
    }

    nonisolated private static func bufferCategory(
        after category: ContinuityBuilderCategory,
        excluding excluded: Set<ContinuityBuilderCategory>
    ) -> ContinuityBuilderCategory? {
        let candidates: [ContinuityBuilderCategory]
        switch category {
        case .worldGeography, .placeTopography, .landmarkBridge, .vehicleProp, .sceneContinuity:
            candidates = [.costumeContinuity, .characterIdentity, .styleContinuity]
        case .characterIdentity, .costumeContinuity:
            candidates = [.landmarkBridge, .placeTopography, .worldGeography, .styleContinuity]
        case .styleContinuity:
            candidates = [.worldGeography, .characterIdentity, .landmarkBridge, .costumeContinuity]
        }
        return candidates.first { !excluded.contains($0) }
    }

    nonisolated private static func nextCategory(after turn: ContinuityBuilderTurn, feedback: ContinuityBuilderFeedback) -> ContinuityBuilderCategory {
        let haystack = ([feedback.notes] + feedback.interpretedFocus).joined(separator: " ").lowercased()
        let categoryMatches: [(ContinuityBuilderCategory, [String])] = [
            (.landmarkBridge, ["bridge", "ravine", "flood", "river", "water", "bank"]),
            (.placeTopography, ["town", "hill", "slope", "road", "building", "north", "south", "soil", "topography"]),
            (.characterIdentity, ["face", "head", "hair", "johnny", "amira", "character", "identity"]),
            (.costumeContinuity, ["costume", "camouflage", "satchel", "polaroid", "belt", "uniform", "accessory", "boots"]),
            (.vehicleProp, ["vehicle", "humvee", "truck", "prop", "camera", "weapon"]),
            (.styleContinuity, ["style", "grain", "palette", "lens", "lighting", "anime", "cgi", "texture"]),
            (.worldGeography, ["map", "geography", "valley", "sun", "direction", "mountain"])
        ]
        if let match = categoryMatches.max(by: { lhs, rhs in
            lhs.1.filter { haystack.contains($0) }.count < rhs.1.filter { haystack.contains($0) }.count
        }), match.1.contains(where: { haystack.contains($0) }) {
            return match.0
        }
        switch turn.category {
        case .worldGeography: return .landmarkBridge
        case .landmarkBridge: return .placeTopography
        case .placeTopography: return .characterIdentity
        case .characterIdentity: return .costumeContinuity
        case .costumeContinuity: return .styleContinuity
        case .vehicleProp: return .styleContinuity
        case .sceneContinuity: return .styleContinuity
        case .styleContinuity: return .worldGeography
        }
    }

    nonisolated private static func selectBufferedTurn(
        from futureTurns: [ContinuityBuilderTurn],
        after turn: ContinuityBuilderTurn,
        feedback: ContinuityBuilderFeedback,
        projectRoot: URL
    ) -> ContinuityBuilderTurn? {
        let desiredNext = nextCategory(after: turn, feedback: feedback)
        let currentRole = semanticLane(for: turn.category)
        let desiredRole = semanticLane(for: desiredNext)
        return futureTurns
            .filter { turnHasCurrentGeneratedCandidate($0, projectRoot: projectRoot) }
            .sorted { lhs, rhs in lhs.createdAt < rhs.createdAt }
            .first { buffered in
                guard buffered.category != desiredNext else { return false }
                let bufferedRole = semanticLane(for: buffered.category)
                if bufferedRole == currentRole || bufferedRole == desiredRole {
                    return false
                }
                return true
            }
    }

    nonisolated private static func semanticLane(for category: ContinuityBuilderCategory) -> ImageLibrarySemanticRole? {
        switch category {
        case .worldGeography, .placeTopography, .landmarkBridge, .vehicleProp, .sceneContinuity:
            return .place
        case .characterIdentity, .costumeContinuity:
            return .character
        case .styleContinuity:
            return nil
        }
    }

    nonisolated private static func nextTitle(for category: ContinuityBuilderCategory, feedback: ContinuityBuilderFeedback) -> String {
        let focus = feedback.interpretedFocus.prefix(3).joined(separator: " / ")
        return focus.isEmpty ? "Next continuity judgment: \(category.displayName)" : "Next continuity judgment: \(focus)"
    }

    nonisolated private static func nextQuestion(for category: ContinuityBuilderCategory, feedback: ContinuityBuilderFeedback) -> String {
        let note = feedback.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let repaired = note.isEmpty ? "the last continuity judgment" : "this note: \(note)"
        return "The next generated image should respond to \(repaired). Once it appears, what is still wrong or right? Give concrete visual rules that future prompts can reuse."
    }

    nonisolated private static func registryCandidates(projectRoot: URL, names: [String], fallback: [ContinuityBuilderCandidate]) -> [ContinuityBuilderCandidate] {
        let url = ProjectPaths(root: projectRoot).animate.appendingPathComponent("reference-registry.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backgrounds = object["backgrounds"] as? [[String: Any]] else { return fallback }
        let wanted = Set(names.map { $0.lowercased() })
        var candidates: [ContinuityBuilderCandidate] = []
        for entry in backgrounds {
            let name = (entry["name"] as? String ?? "").lowercased()
            guard wanted.contains(name) else { continue }
            for file in (entry["files"] as? [[String: Any]] ?? []) {
                let rawPath = file["path"] as? String ?? file["absolute_path"] as? String
                let path = Self.acceptedExistingPath(rawPath, projectRoot: projectRoot)
                guard let path else { continue }
                candidates.append(.init(label: .single, title: "Registry \(name)", imagePath: path, source: "reference-registry.json", referenceRole: name == "map" ? "spatial_map" : "landmark_design", promptRole: "continuity candidate"))
            }
        }
        let ranked = rankedRatedCandidates(candidates)
        return withLabels(ranked).isEmpty ? fallback : withLabels(ranked)
    }

    nonisolated private static func firstPlaceCandidates(backgrounds: [BackgroundPlate], projectRoot: URL, limit: Int) -> [ContinuityBuilderCandidate] {
        var candidates: [ContinuityBuilderCandidate] = []
        for place in backgrounds {
            let rawPaths = [place.resolvedAnimatedApprovedImagePath, place.resolvedApprovedImagePath] + place.referenceImages.prefix(2).map { Optional($0.imagePath) }
            if let path = acceptedExistingPath(rawPaths, projectRoot: projectRoot) {
                candidates.append(.init(label: .single, title: place.name, imagePath: path, source: "Places/places.json", referenceRole: "location_identity", promptRole: "place/topography candidate"))
            }
            if candidates.count >= limit { break }
        }
        return withLabels(rankedRatedCandidates(candidates))
    }

    nonisolated private static func bridgePlaceCandidates(backgrounds: [BackgroundPlate], projectRoot: URL, limit: Int) -> [ContinuityBuilderCandidate] {
        let matches = backgrounds.filter { place in
            [place.name, place.visualBrief, place.physicalLayoutAndTopography, place.geographicPlacement, place.imageGenerationGuardrails]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains("bridge")
        }
        var candidates: [ContinuityBuilderCandidate] = []
        for place in matches {
            if let path = acceptedExistingPath([place.resolvedAnimatedApprovedImagePath, place.resolvedApprovedImagePath], projectRoot: projectRoot) {
                candidates.append(.init(label: .single, title: place.name, imagePath: path, source: "Places/places.json", referenceRole: "landmark_design", promptRole: "bridge/ravine candidate"))
            }
            if candidates.count >= limit { break }
        }
        return withLabels(rankedRatedCandidates(candidates))
    }

    nonisolated private static func firstCharacterCandidates(characters: [AnimationCharacter], projectRoot: URL, limit: Int) -> [ContinuityBuilderCandidate] {
        var candidates: [ContinuityBuilderCandidate] = []
        for character in characters {
            let approvedMaster = (character.masterReferenceSheetVariants.first { $0.id == character.approvedMasterReferenceSheetVariantID } ?? character.masterReferenceSheetVariants.last)?.imagePath
            let approvedHead = (character.headTurnaroundSheetVariants.first { $0.id == character.approvedHeadTurnaroundSheetVariantID } ?? character.headTurnaroundSheetVariants.last)?.imagePath
            let raw = [approvedHead, approvedMaster, character.profileImagePath, character.inspirationReferenceImagePath] + character.referenceImagePaths.prefix(2).map(Optional.init)
            if let path = acceptedExistingPath(raw, projectRoot: projectRoot) ?? canonicalExistingPath(raw, projectRoot: projectRoot) {
                candidates.append(.init(label: .single, title: character.name, imagePath: path, source: "Characters/*/rig.json", referenceRole: "character_identity", promptRole: "character identity candidate"))
            }
            if candidates.count >= limit { break }
        }
        return withLabels(rankedRatedCandidates(candidates))
    }

    nonisolated private static func firstCostumeCandidates(characters: [AnimationCharacter], projectRoot: URL, limit: Int, fallback: [ContinuityBuilderCandidate]) -> [ContinuityBuilderCandidate] {
        var candidates: [ContinuityBuilderCandidate] = []
        for character in characters {
            for costume in character.costumeReferenceSets {
                let approved = costume.approvedSheetVariant?.imagePath ?? costume.sheetVariants.last?.imagePath
                let raw = [approved] + costume.costumeReferenceImagePaths.prefix(2).map(Optional.init)
                if let path = acceptedExistingPath(raw, projectRoot: projectRoot) ?? canonicalExistingPath(raw, projectRoot: projectRoot) {
                    candidates.append(.init(label: .single, title: "\(character.name): \(costume.name)", imagePath: path, source: "Characters/*/rig.json", referenceRole: "character_costume", promptRole: "costume continuity candidate"))
                }
                if candidates.count >= limit { break }
            }
            if candidates.count >= limit { break }
        }
        let ranked = rankedRatedCandidates(candidates)
        return withLabels(ranked.isEmpty ? fallback : ranked)
    }

    nonisolated private static func resolvedPath(_ rawPath: String?, projectRoot: URL) -> String? {
        runtimePath(rawPath, projectRoot: projectRoot)
    }

    nonisolated private static func acceptedExistingPath(_ rawPaths: [String?], projectRoot: URL) -> String? {
        rawPaths.compactMap { acceptedExistingRatedPath($0, projectRoot: projectRoot) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.updatedAt != rhs.updatedAt { return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast) }
                return lhs.path < rhs.path
            }
            .map(\.path)
            .first
    }

    nonisolated private static func acceptedExistingPath(_ rawPath: String?, projectRoot: URL) -> String? {
        acceptedExistingRatedPath(rawPath, projectRoot: projectRoot)?.path
    }

    nonisolated private static func canonicalExistingPath(_ rawPaths: [String?], projectRoot: URL) -> String? {
        rawPaths.compactMap { canonicalExistingPath($0, projectRoot: projectRoot) }.first
    }

    nonisolated private static func canonicalExistingPath(_ rawPath: String?, projectRoot: URL) -> String? {
        guard let path = resolvedPath(rawPath, projectRoot: projectRoot),
              FileManager.default.fileExists(atPath: path),
              !isRejectedImagePath(path) else { return nil }
        return path
    }

    nonisolated private static func acceptedExistingRatedPath(_ rawPath: String?, projectRoot: URL) -> (path: String, score: Double, updatedAt: Date?)? {
        guard let path = resolvedPath(rawPath, projectRoot: projectRoot),
              FileManager.default.fileExists(atPath: path),
              let score = referencePreferenceScore(forImagePath: path) else { return nil }
        return (path, score, ImagePreferenceProfileService.referenceUpdatedAt(forImagePath: path))
    }

    nonisolated static func isRejectedImagePath(_ path: String) -> Bool {
        ImageLibraryMetadataSidecarService.load(forImagePath: path)?.isRejected == true
    }

    nonisolated static func referenceRating(forImagePath path: String) -> Int? {
        ImagePreferenceProfileService.referenceRating(forImagePath: path)
    }

    nonisolated static func referencePreferenceScore(forImagePath path: String) -> Double? {
        ImagePreferenceProfileService.referencePreferenceScore(forImagePath: path)
    }

    nonisolated static func isReferenceEligibleImagePath(_ path: String) -> Bool {
        referencePreferenceScore(forImagePath: path) != nil
    }

    nonisolated private static func restoreReferenceCandidatesForUngeneratedTurns(
        _ session: inout ContinuityBuilderSession,
        projectRoot: URL,
        backgrounds: [BackgroundPlate],
        characters: [AnimationCharacter]
    ) {
        guard session.hasStarted else { return }
        let templates = seedTurns(projectRoot: projectRoot, backgrounds: backgrounds, characters: characters)
        for index in session.turns.indices {
            guard !turnHasCurrentGeneratedCandidate(session.turns[index], projectRoot: projectRoot) else { continue }
            let onlyGeneratedCandidates = session.turns[index].candidates.isEmpty
                || session.turns[index].candidates.allSatisfy { $0.source == generatedCandidateSource }
            guard onlyGeneratedCandidates,
                  let template = templates.first(where: { $0.category == session.turns[index].category }) else { continue }
            session.turns[index].candidates = template.candidates
        }
    }

    nonisolated private static func rankedRatedCandidates(_ candidates: [ContinuityBuilderCandidate]) -> [ContinuityBuilderCandidate] {
        candidates
            .compactMap { candidate -> (ContinuityBuilderCandidate, Double, Date?)? in
                guard let path = candidate.imagePath,
                      let score = referencePreferenceScore(forImagePath: path) else { return nil }
                return (candidate, score, ImagePreferenceProfileService.referenceUpdatedAt(forImagePath: path))
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.2 != rhs.2 { return (lhs.2 ?? .distantPast) > (rhs.2 ?? .distantPast) }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    nonisolated private static func withLabels(_ candidates: [ContinuityBuilderCandidate]) -> [ContinuityBuilderCandidate] {
        let limited = Array(candidates.prefix(2))
        let labels: [ContinuityBuilderCandidateLabel]
        switch limited.count {
        case 0: labels = []
        case 1: labels = [.single]
        default: labels = [.left, .right]
        }
        return limited.enumerated().map { index, candidate in
            var copy = candidate
            if labels.indices.contains(index) { copy.label = labels[index] }
            return copy
        }
    }

    nonisolated private static func baseNegativeGuardrails(world: AutomationWorldContext?) -> [String] {
        var rules = [
            "No future technology in frame.",
            "No generic modern skyline or glossy contemporary architecture.",
            "No extra bridges or wrong-side settlement unless explicitly requested.",
            "No soldiers/vehicles in a scene before the story calls for them.",
            "No narrow crop-only composition; generate 4:3 open matte with wider-than-needed camera FOV."
        ]
        if let world {
            rules.append(contentsOf: world.timePeriod.components(separatedBy: .newlines).dropFirst())
        }
        return rules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func interpretedFocus(from notes: String, turn: ContinuityBuilderTurn) -> [String] {
        let lower = notes.lowercased()
        var tags = Set(turn.contextTags)
        let dictionary = [
            "river", "bridge", "ravine", "town", "hill", "sun", "lighting", "vehicle", "humvee", "soldier", "camouflage", "satchel", "polaroid", "camera", "costume", "face", "head", "map", "style", "grain", "palette", "crop", "4:3"
        ]
        for token in dictionary where lower.contains(token) { tags.insert(token) }
        return Array(tags).sorted()
    }

    private func readLatestSession(projectRoot: URL) -> ContinuityBuilderSession? {
        let pointer = continuityDirectory(projectRoot: projectRoot).appendingPathComponent("latest-session.txt")
        guard let id = try? String(contentsOf: pointer, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return readSession(id: id, projectRoot: projectRoot)
    }

    private func readSession(id: String, projectRoot: URL) -> ContinuityBuilderSession? {
        let url = sessionDirectory(projectRoot: projectRoot, sessionID: id).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ContinuityBuilderSession.self, from: data) else { return nil }
        return Self.runtimeSession(decoded, projectRoot: projectRoot)
    }

    private func writeSession(_ session: ContinuityBuilderSession, projectRoot: URL) throws {
        let dir = sessionDirectory(projectRoot: projectRoot, sessionID: session.id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeCodable(Self.portableSession(session, projectRoot: projectRoot), to: dir.appendingPathComponent("session.json"))
        try writeLatestPointer(sessionID: session.id, projectRoot: projectRoot)
    }

    private func writeLatestPointer(sessionID: UUID, projectRoot: URL) throws {
        let dir = continuityDirectory(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sessionID.uuidString.write(to: dir.appendingPathComponent("latest-session.txt"), atomically: true, encoding: .utf8)
    }

    private func writeFeedback(_ feedback: ContinuityBuilderFeedback, sessionID: UUID, projectRoot: URL) throws {
        let dir = sessionDirectory(projectRoot: projectRoot, sessionID: sessionID.uuidString).appendingPathComponent("feedback", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeCodable(feedback, to: dir.appendingPathComponent("\(feedback.turnID.uuidString).json"))
    }

    private func writeIndex(projectRoot: URL) throws {
        let feedback = Self.loadAllFeedback(projectRoot: projectRoot).sorted { $0.submittedAt > $1.submittedAt }
        try writeCodable(feedback, to: continuityDirectory(projectRoot: projectRoot).appendingPathComponent("continuity-feedback-index.json"))
    }

    private func continuityDirectory(projectRoot: URL) -> URL {
        Self.continuityDirectory(projectRoot: projectRoot)
    }

    private func sessionDirectory(projectRoot: URL, sessionID: String) -> URL {
        Self.continuityDirectory(projectRoot: projectRoot)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    static func loadAllFeedback(projectRoot: URL) -> [ContinuityBuilderFeedback] {
        let sessionsDir = continuityDirectory(projectRoot: projectRoot).appendingPathComponent("sessions", isDirectory: true)
        guard let sessionDirs = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var all: [ContinuityBuilderFeedback] = []
        for dir in sessionDirs {
            let feedbackDir = dir.appendingPathComponent("feedback", isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(at: feedbackDir, includingPropertiesForKeys: nil) else { continue }
            all.append(contentsOf: urls.filter { $0.pathExtension == "json" }.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ContinuityBuilderFeedback.self, from: data)
            })
        }
        return all
    }

    nonisolated static func continuityDirectory(projectRoot: URL) -> URL {
        ProjectPaths(root: projectRoot).metadata
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("continuity-builder", isDirectory: true)
    }

    nonisolated static func runtimePath(_ rawPath: String?, projectRoot: URL) -> String? {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else { return nil }
        if !rawPath.hasPrefix("/") {
            return projectRoot.appendingPathComponent(rawPath).path
        }
        let projectPath = projectRoot.standardizedFileURL.path
        if rawPath == projectPath || rawPath.hasPrefix(projectPath + "/") {
            return rawPath
        }
        if let range = rawPath.range(of: "/\(projectRoot.lastPathComponent)/") {
            return projectRoot.appendingPathComponent(String(rawPath[range.upperBound...])).path
        }
        if let animateRange = rawPath.range(of: "/Animate/") {
            return projectRoot.appendingPathComponent("Animate").appendingPathComponent(String(rawPath[animateRange.upperBound...])).path
        }
        return rawPath
    }

    nonisolated static func portablePath(_ rawPath: String?, projectRoot: URL) -> String? {
        guard let runtime = runtimePath(rawPath, projectRoot: projectRoot) else { return nil }
        let projectPath = projectRoot.standardizedFileURL.path
        if runtime == projectPath { return nil }
        if runtime.hasPrefix(projectPath + "/") {
            return String(runtime.dropFirst(projectPath.count + 1))
        }
        return rawPath
    }

    nonisolated static func runtimeSession(_ session: ContinuityBuilderSession, projectRoot: URL) -> ContinuityBuilderSession {
        var copy = session
        copy.projectRoot = projectRoot.path
        for turnIndex in copy.turns.indices {
            var retained: [ContinuityBuilderCandidate] = []
            for candidateIndex in copy.turns[turnIndex].candidates.indices {
                var candidate = copy.turns[turnIndex].candidates[candidateIndex]
                candidate.imagePath = runtimePath(candidate.imagePath, projectRoot: projectRoot)
                if let imagePath = candidate.imagePath,
                   candidate.source != editSourceCandidateSource,
                   candidate.referenceRole != "edit_source",
                   isRejectedImagePath(imagePath) {
                    continue
                }
                retained.append(candidate)
            }
            copy.turns[turnIndex].candidates = withLabels(retained)
        }
        return copy
    }

    nonisolated static func portableSession(_ session: ContinuityBuilderSession, projectRoot: URL) -> ContinuityBuilderSession {
        var copy = session
        copy.projectRoot = projectRoot.lastPathComponent
        for turnIndex in copy.turns.indices {
            for candidateIndex in copy.turns[turnIndex].candidates.indices {
                copy.turns[turnIndex].candidates[candidateIndex].imagePath = portablePath(
                    copy.turns[turnIndex].candidates[candidateIndex].imagePath,
                    projectRoot: projectRoot
                )
            }
        }
        return copy
    }

    nonisolated static func sessionWithLatestGeneratedCandidates(_ session: ContinuityBuilderSession, projectRoot: URL) -> ContinuityBuilderSession {
        var copy = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessionGenerationsDir = continuityDirectory(projectRoot: projectRoot)
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(copy.id.uuidString, isDirectory: true)

        for turnIndex in copy.turns.indices {
            let turn = copy.turns[turnIndex]
            let turnID = turn.id.uuidString
            let currentTurnDir = sessionGenerationsDir.appendingPathComponent(turnID, isDirectory: true)
            let urls = (try? FileManager.default.contentsOfDirectory(at: currentTurnDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

            // Do not borrow generated images from older turns. Each continuity judgment must
            // either show references honestly or display a fresh image generated for this exact turn.

            let records = urls
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> ContinuityBuilderGenerationRecord? in
                    guard let data = try? Data(contentsOf: url),
                          let record = try? decoder.decode(ContinuityBuilderGenerationRecord.self, from: data),
                          record.status == "completed",
                          let imagePath = runtimePath(record.imagePath, projectRoot: projectRoot),
                          FileManager.default.fileExists(atPath: imagePath),
                          !isRejectedImagePath(imagePath) else { return nil }
                    var copy = record
                    copy.imagePath = imagePath
                    return copy
                }
                .sorted { lhs, rhs in
                    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                    return lhs.createdAt > rhs.createdAt
                }
            guard !records.isEmpty else { continue }
            var latestByLabel: [ContinuityBuilderCandidateLabel: ContinuityBuilderGenerationRecord] = [:]
            for record in records where latestByLabel[record.label] == nil {
                latestByLabel[record.label] = record
            }
            let orderedLabels: [ContinuityBuilderCandidateLabel] = records.count == 1
                ? [.single, .left, .middle, .right]
                : [.left, .middle, .right, .single]
            let generated = orderedLabels.compactMap { label -> ContinuityBuilderCandidate? in
                guard let record = latestByLabel[label],
                      let imagePath = record.imagePath else { return nil }
                return ContinuityBuilderCandidate(
                    id: record.candidateID ?? UUID(),
                    label: label,
                    title: "Generated \(label.displayName): \(copy.turns[turnIndex].title)",
                    imagePath: imagePath,
                    source: generatedCandidateSource,
                    referenceRole: "generated_candidate",
                    promptRole: "candidate for Gary feedback",
                    analysisSummary: nil
                )
            }
            if !generated.isEmpty {
                copy.turns[turnIndex].candidates = withLabels(generated)
                copy.turns[turnIndex].requiresPaidGeneration = false
                copy.turns[turnIndex].generationStatus = "generated_candidates_ready_for_feedback"
            }
        }
        return copy
    }

}
