import CryptoKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
struct ContinuityBuilderService {
    var store: AnimateStore

    func loadOrCreateSession(projectRoot: URL) async -> ContinuityBuilderSession {
        if var existing = readLatestSession(projectRoot: projectRoot) {
            if existing.turns.isEmpty {
                existing.turns = await seedTurns(projectRoot: projectRoot)
                existing.updatedAt = Date()
                try? writeSession(existing, projectRoot: projectRoot)
            }
            return existing
        }
        var session = ContinuityBuilderSession(projectRoot: projectRoot.path)
        session.turns = await seedTurns(projectRoot: projectRoot)
        try? writeSession(session, projectRoot: projectRoot)
        try? writeLatestPointer(sessionID: session.id, projectRoot: projectRoot)
        return session
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
        updated.activeTurnIndex = min(session.activeTurnIndex + 1, max(updated.turns.count - 1, 0))
        if updated.activeTurnIndex == session.activeTurnIndex, updated.turns.count <= session.activeTurnIndex + 1 {
            updated.turns.append(followUpTurn(after: turn, feedback: feedback, projectRoot: projectRoot))
            updated.activeTurnIndex = updated.turns.count - 1
        }
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
        var warnings: [String] = []
        let world = AutomationSourceResolver.worldContext(projectRoot: projectRoot, warnings: &warnings)
        let styleLock = animatedLookPrompt(projectRoot: projectRoot) ?? ""
        let geographyPrompt = [
            "Build a canonical 4:3 open-matte continuity reference for the Persian-Afghan highland valley world.",
            "World period: \(world?.timePeriod ?? "UNKNOWN — read Places/places-world-context.json before paid generation.")",
            "Environmental rules: \(world?.environmental ?? "Use canonical Places/places-world-context.json cues.")",
            "Style lock: \(styleLock.isEmpty ? "Use Settings/animated-look-prompt.json before paid generation." : styleLock)",
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
                candidates: registryCandidates(projectRoot: projectRoot, names: ["map"], fallback: firstPlaceCandidates(projectRoot: projectRoot, limit: 3)),
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
                candidates: registryCandidates(projectRoot: projectRoot, names: ["bridge", "map"], fallback: bridgePlaceCandidates(projectRoot: projectRoot, limit: 3)),
                contextTags: ["bridge", "ravine", "flood", "river", "town"]
            )
        )

        let placeCandidates = firstPlaceCandidates(projectRoot: projectRoot, limit: 3)
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

        let characterCandidates = firstCharacterCandidates(projectRoot: projectRoot, limit: 3)
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
                candidates: firstCostumeCandidates(projectRoot: projectRoot, limit: 3, fallback: characterCandidates),
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

    private func followUpTurn(after turn: ContinuityBuilderTurn, feedback: ContinuityBuilderFeedback, projectRoot: URL) -> ContinuityBuilderTurn {
        ContinuityBuilderTurn(
            category: turn.category,
            title: "Follow-up: \(turn.category.displayName)",
            question: "Based on your last note, what correction should become a hard rule and what can remain flexible?",
            priorityReason: "Follow-up turns turn raw speech feedback into reusable prompt memory before any more paid generation.",
            promptSeed: [turn.promptSeed, "Last feedback: \(feedback.notes)", "Next generated candidate should specifically repair that feedback while preserving accepted details."].joined(separator: "\n\n"),
            negativeGuardrails: turn.negativeGuardrails,
            candidates: turn.candidates,
            contextTags: Array(Set(turn.contextTags + feedback.interpretedFocus)).sorted(),
            requiresPaidGeneration: false,
            generationStatus: "needs_execute_approval_before_paid_generation"
        )
    }

    private func registryCandidates(projectRoot: URL, names: [String], fallback: [ContinuityBuilderCandidate]) -> [ContinuityBuilderCandidate] {
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
                let path = file["absolute_path"] as? String ?? file["path"] as? String
                guard let path, FileManager.default.fileExists(atPath: path) else { continue }
                candidates.append(.init(label: .single, title: "Registry \(name)", imagePath: path, source: "reference-registry.json", referenceRole: name == "map" ? "spatial_map" : "landmark_design", promptRole: "continuity candidate"))
            }
        }
        return withLabels(Array(candidates.prefix(3))).isEmpty ? fallback : withLabels(Array(candidates.prefix(3)))
    }

    private func firstPlaceCandidates(projectRoot: URL, limit: Int) -> [ContinuityBuilderCandidate] {
        var candidates: [ContinuityBuilderCandidate] = []
        for place in store.backgrounds {
            let rawPaths = [place.resolvedAnimatedApprovedImagePath, place.resolvedApprovedImagePath] + place.referenceImages.prefix(2).map { Optional($0.imagePath) }
            if let path = rawPaths.compactMap({ resolvedPath($0, projectRoot: projectRoot) }).first(where: { FileManager.default.fileExists(atPath: $0) }) {
                candidates.append(.init(label: .single, title: place.name, imagePath: path, source: "Places/places.json", referenceRole: "location_identity", promptRole: "place/topography candidate"))
            }
            if candidates.count >= limit { break }
        }
        return withLabels(candidates)
    }

    private func bridgePlaceCandidates(projectRoot: URL, limit: Int) -> [ContinuityBuilderCandidate] {
        let matches = store.backgrounds.filter { place in
            [place.name, place.visualBrief, place.physicalLayoutAndTopography, place.geographicPlacement, place.imageGenerationGuardrails]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains("bridge")
        }
        var candidates: [ContinuityBuilderCandidate] = []
        for place in matches {
            if let path = [place.resolvedAnimatedApprovedImagePath, place.resolvedApprovedImagePath]
                .compactMap({ resolvedPath($0, projectRoot: projectRoot) })
                .first(where: { FileManager.default.fileExists(atPath: $0) }) {
                candidates.append(.init(label: .single, title: place.name, imagePath: path, source: "Places/places.json", referenceRole: "landmark_design", promptRole: "bridge/ravine candidate"))
            }
            if candidates.count >= limit { break }
        }
        return withLabels(candidates)
    }

    private func firstCharacterCandidates(projectRoot: URL, limit: Int) -> [ContinuityBuilderCandidate] {
        var candidates: [ContinuityBuilderCandidate] = []
        for character in store.characters {
            let approvedMaster = (character.masterReferenceSheetVariants.first { $0.id == character.approvedMasterReferenceSheetVariantID } ?? character.masterReferenceSheetVariants.last)?.imagePath
            let approvedHead = (character.headTurnaroundSheetVariants.first { $0.id == character.approvedHeadTurnaroundSheetVariantID } ?? character.headTurnaroundSheetVariants.last)?.imagePath
            let raw = [approvedHead, approvedMaster, character.profileImagePath, character.inspirationReferenceImagePath] + character.referenceImagePaths.prefix(2).map(Optional.init)
            if let path = raw.compactMap({ resolvedPath($0, projectRoot: projectRoot) }).first(where: { FileManager.default.fileExists(atPath: $0) }) {
                candidates.append(.init(label: .single, title: character.name, imagePath: path, source: "Characters/*/rig.json", referenceRole: "character_identity", promptRole: "character identity candidate"))
            }
            if candidates.count >= limit { break }
        }
        return withLabels(candidates)
    }

    private func firstCostumeCandidates(projectRoot: URL, limit: Int, fallback: [ContinuityBuilderCandidate]) -> [ContinuityBuilderCandidate] {
        var candidates: [ContinuityBuilderCandidate] = []
        for character in store.characters {
            for costume in character.costumeReferenceSets {
                let approved = costume.approvedSheetVariant?.imagePath ?? costume.sheetVariants.last?.imagePath
                let raw = [approved] + costume.costumeReferenceImagePaths.prefix(2).map(Optional.init)
                if let path = raw.compactMap({ resolvedPath($0, projectRoot: projectRoot) }).first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    candidates.append(.init(label: .single, title: "\(character.name): \(costume.name)", imagePath: path, source: "Characters/*/rig.json", referenceRole: "character_costume", promptRole: "costume continuity candidate"))
                }
                if candidates.count >= limit { break }
            }
            if candidates.count >= limit { break }
        }
        return withLabels(candidates.isEmpty ? fallback : candidates)
    }

    private func withLabels(_ candidates: [ContinuityBuilderCandidate]) -> [ContinuityBuilderCandidate] {
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

    private func baseNegativeGuardrails(world: AutomationWorldContext?) -> [String] {
        var rules = [
            "No future technology in frame.",
            "No generic modern skyline or glossy contemporary architecture.",
            "No extra bridges or wrong-side settlement unless explicitly approved.",
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
        return try? decoder.decode(ContinuityBuilderSession.self, from: data)
    }

    private func writeSession(_ session: ContinuityBuilderSession, projectRoot: URL) throws {
        let dir = sessionDirectory(projectRoot: projectRoot, sessionID: session.id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeCodable(session, to: dir.appendingPathComponent("session.json"))
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

    static func continuityDirectory(projectRoot: URL) -> URL {
        ProjectPaths(root: projectRoot).metadata
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("continuity-builder", isDirectory: true)
    }
}
