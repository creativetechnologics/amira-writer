import CryptoKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
struct ContinuityBuilderService {
    var store: AnimateStore

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
            return Self.runtimeSession(Self.sessionWithLatestGeneratedCandidates(existing, projectRoot: projectRoot), projectRoot: projectRoot)
        }
        let session = ContinuityBuilderSession(projectRoot: projectRoot.path)
        try? writeSession(session, projectRoot: projectRoot)
        try? writeLatestPointer(sessionID: session.id, projectRoot: projectRoot)
        return Self.runtimeSession(Self.sessionWithLatestGeneratedCandidates(session, projectRoot: projectRoot), projectRoot: projectRoot)
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
        if updated.turns.indices.contains(currentIndex) {
            updated.turns = Array(updated.turns.prefix(currentIndex + 1))
        }
        updated.turns.append(nextStreamTurn(after: turn, feedback: feedback, projectRoot: projectRoot))
        updated.activeTurnIndex = max(updated.turns.count - 1, 0)
        updated.updatedAt = Date()
        try writeFeedback(feedback, sessionID: session.id, projectRoot: projectRoot)
        try writeSession(updated, projectRoot: projectRoot)
        try writeIndex(projectRoot: projectRoot)
        return updated
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
            let notes = item.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notes.isEmpty else { return nil }
            let label = item.selectedCandidateLabel?.displayName ?? "shown candidate"
            return "Continuity Builder feedback for \(label) (\(item.closenessPercent)% close): \(notes)"
        }
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
        turns.append(
            ContinuityBuilderTurn(
                category: .characterIdentity,
                title: "Character identity anchors",
                question: "Which identity details must be preserved? Mention face angle, age, hair/headgear, accessories, and whether this is the right type of reference for close-up vs full body.",
                priorityReason: "Character identity references should be classified before they are reused as generation references.",
                promptSeed: "Extract durable character identity rules from the shown reference candidates. Prefer close-up/head-turn refs for face angle and full-body refs for silhouette.",
                negativeGuardrails: ["Do not mix characters.", "Do not use a full-frame scene as a face identity reference if a tighter head reference exists."],
                candidates: characterCandidates,
                contextTags: ["character", "identity", "head", "face", "turnaround"]
            )
        )

        turns.append(
            ContinuityBuilderTurn(
                category: .costumeContinuity,
                title: "Costume / accessory continuity",
                question: "What clothing, camouflage, satchels, belts, cameras, footwear, dirt/wear, or accessories must be exact every time?",
                priorityReason: "Costume/accessory drift is one of the easiest continuity breaks for viewers to notice.",
                promptSeed: "Extract script-supervisor costume continuity rules. Treat camouflage pattern, color blocking, accessories, and carried objects as hard constraints.",
                negativeGuardrails: ["Do not simplify camouflage into generic green texture.", "Do not move carried objects to the neck/hand if the continuity rule says belt/satchel."],
                candidates: firstCostumeCandidates(characters: characters, projectRoot: projectRoot, limit: 3, fallback: characterCandidates),
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
        next.promptSeed = [
            next.promptSeed,
            "Latest Gary feedback to repair or preserve: \(feedback.notes)",
            "Selected candidate label: \(feedback.selectedCandidateLabel?.displayName ?? "shown candidate"). Closeness score: \(feedback.closenessPercent)%.",
            "Next generated candidate should specifically respond to that feedback while preserving any accepted continuity facts."
        ].joined(separator: "\n\n")
        next.contextTags = Array(Set(next.contextTags + feedback.interpretedFocus)).sorted()
        next.requiresPaidGeneration = false
        next.generationStatus = "ready_for_generation"
        return next
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

    nonisolated private static func nextTitle(for category: ContinuityBuilderCategory, feedback: ContinuityBuilderFeedback) -> String {
        let focus = feedback.interpretedFocus.prefix(3).joined(separator: " / ")
        return focus.isEmpty ? "Next continuity judgment: \(category.displayName)" : "Next continuity judgment: \(focus)"
    }

    nonisolated private static func nextQuestion(for category: ContinuityBuilderCategory, feedback: ContinuityBuilderFeedback) -> String {
        let note = feedback.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let repaired = note.isEmpty ? "the last continuity judgment" : "this note: \(note)"
        return "What is still wrong or right after applying \(repaired)? Give concrete visual rules that future prompts can reuse."
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
        return withLabels(Array(candidates.prefix(3))).isEmpty ? fallback : withLabels(Array(candidates.prefix(3)))
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
        return withLabels(candidates)
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
        return withLabels(candidates)
    }

    nonisolated private static func firstCharacterCandidates(characters: [AnimationCharacter], projectRoot: URL, limit: Int) -> [ContinuityBuilderCandidate] {
        var candidates: [ContinuityBuilderCandidate] = []
        for character in characters {
            let approvedMaster = (character.masterReferenceSheetVariants.first { $0.id == character.approvedMasterReferenceSheetVariantID } ?? character.masterReferenceSheetVariants.last)?.imagePath
            let approvedHead = (character.headTurnaroundSheetVariants.first { $0.id == character.approvedHeadTurnaroundSheetVariantID } ?? character.headTurnaroundSheetVariants.last)?.imagePath
            let raw = [approvedHead, approvedMaster, character.profileImagePath, character.inspirationReferenceImagePath] + character.referenceImagePaths.prefix(2).map(Optional.init)
            if let path = acceptedExistingPath(raw, projectRoot: projectRoot) {
                candidates.append(.init(label: .single, title: character.name, imagePath: path, source: "Characters/*/rig.json", referenceRole: "character_identity", promptRole: "character identity candidate"))
            }
            if candidates.count >= limit { break }
        }
        return withLabels(candidates)
    }

    nonisolated private static func firstCostumeCandidates(characters: [AnimationCharacter], projectRoot: URL, limit: Int, fallback: [ContinuityBuilderCandidate]) -> [ContinuityBuilderCandidate] {
        var candidates: [ContinuityBuilderCandidate] = []
        for character in characters {
            for costume in character.costumeReferenceSets {
                let approved = costume.approvedSheetVariant?.imagePath ?? costume.sheetVariants.last?.imagePath
                let raw = [approved] + costume.costumeReferenceImagePaths.prefix(2).map(Optional.init)
                if let path = acceptedExistingPath(raw, projectRoot: projectRoot) {
                    candidates.append(.init(label: .single, title: "\(character.name): \(costume.name)", imagePath: path, source: "Characters/*/rig.json", referenceRole: "character_costume", promptRole: "costume continuity candidate"))
                }
                if candidates.count >= limit { break }
            }
            if candidates.count >= limit { break }
        }
        return withLabels(candidates.isEmpty ? fallback : candidates)
    }

    nonisolated private static func resolvedPath(_ rawPath: String?, projectRoot: URL) -> String? {
        runtimePath(rawPath, projectRoot: projectRoot)
    }

    nonisolated private static func acceptedExistingPath(_ rawPaths: [String?], projectRoot: URL) -> String? {
        rawPaths.compactMap { acceptedExistingPath($0, projectRoot: projectRoot) }.first
    }

    nonisolated private static func acceptedExistingPath(_ rawPath: String?, projectRoot: URL) -> String? {
        guard let path = resolvedPath(rawPath, projectRoot: projectRoot),
              FileManager.default.fileExists(atPath: path),
              !isRejectedImagePath(path) else { return nil }
        return path
    }

    nonisolated static func isRejectedImagePath(_ path: String) -> Bool {
        ImageLibraryMetadataSidecarService.load(forImagePath: path)?.isRejected == true
    }

    nonisolated private static func withLabels(_ candidates: [ContinuityBuilderCandidate]) -> [ContinuityBuilderCandidate] {
        let labels: [ContinuityBuilderCandidateLabel]
        switch candidates.count {
        case 0: labels = []
        case 1: labels = [.single]
        case 2: labels = [.left, .right]
        default: labels = [.left, .middle, .right]
        }
        return candidates.enumerated().map { index, candidate in
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
                if let imagePath = candidate.imagePath, isRejectedImagePath(imagePath) {
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
            var urls = (try? FileManager.default.contentsOfDirectory(at: currentTurnDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

            let completedForCurrentTurn = urls.contains { url in
                guard url.pathExtension == "json",
                      let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(ContinuityBuilderGenerationRecord.self, from: data) else { return false }
                return record.status == "completed"
            }

            if !completedForCurrentTurn,
               let turnDirs = try? FileManager.default.contentsOfDirectory(at: sessionGenerationsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                let titleNeedle = turn.title.lowercased()
                let slugNeedle = turn.title.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(5).joined(separator: "-")
                var fallbackURLs: [URL] = []
                for dir in turnDirs where dir.lastPathComponent != turnID {
                    guard let recordURLs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                    for url in recordURLs where url.pathExtension == "json" {
                        guard let data = try? Data(contentsOf: url),
                              let record = try? decoder.decode(ContinuityBuilderGenerationRecord.self, from: data),
                              record.status == "completed" else { continue }
                        let haystack = [record.prompt, record.imagePath ?? ""].joined(separator: " ").lowercased()
                        if haystack.contains(titleNeedle) || (!slugNeedle.isEmpty && haystack.contains(slugNeedle)) {
                            fallbackURLs.append(url)
                        }
                    }
                }
                urls.append(contentsOf: fallbackURLs)
            }

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
                    source: "Continuity Builder generated candidate",
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
