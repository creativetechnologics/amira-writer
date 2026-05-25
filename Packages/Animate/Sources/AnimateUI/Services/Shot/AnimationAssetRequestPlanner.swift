import Foundation

@available(macOS 26.0, *)
struct AnimationAssetRequest: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, Hashable {
        case visemeSheet
        case expressionVariant
        case poseVariant
        case angleCoverage
    }

    var id: UUID
    var characterID: UUID?
    var characterName: String
    var kind: Kind
    var target: String
    var reason: String

    init(
        id: UUID = UUID(),
        characterID: UUID?,
        characterName: String,
        kind: Kind,
        target: String,
        reason: String
    ) {
        self.id = id
        self.characterID = characterID
        self.characterName = characterName
        self.kind = kind
        self.target = target
        self.reason = reason
    }
}

@available(macOS 26.0, *)
struct AnimationAssetRequestPlanner: Sendable {
    func missingRequests(
        for plan: LLMAnimationPlan,
        characters: [AnimationCharacter]
    ) -> [AnimationAssetRequest] {
        var requests: [AnimationAssetRequest] = []
        var seenKeys = Set<String>()

        let expressionNeeds = collectExpressionNeeds(from: plan)
        let poseNeeds = collectPoseNeeds(from: plan)
        let angleNeeds = collectAngleNeeds(from: plan)
        let dialogueCharacters = Set(plan.dialogueBeats.map { normalizedName($0.characterName) })

        for character in characters {
            let normalizedCharacterName = normalizedName(character.name)
            guard !normalizedCharacterName.isEmpty else { continue }

            if dialogueCharacters.contains(normalizedCharacterName),
               !hasVisemeCoverage(for: character) {
                appendRequest(
                    &requests,
                    seenKeys: &seenKeys,
                    request: AnimationAssetRequest(
                        characterID: character.id,
                        characterName: character.name,
                        kind: .visemeSheet,
                        target: "mouth-visemes",
                        reason: "Dialogue beats exist for \(character.name), but the rig has no viseme-tagged mouth coverage yet."
                    )
                )
            }

            for expression in expressionNeeds[normalizedCharacterName, default: []] where !hasExpressionCoverage(expression, for: character) {
                appendRequest(
                    &requests,
                    seenKeys: &seenKeys,
                    request: AnimationAssetRequest(
                        characterID: character.id,
                        characterName: character.name,
                        kind: .expressionVariant,
                        target: expression,
                        reason: "The plan asks \(character.name) to play expression '\(expression)', but no matching expression coverage was found."
                    )
                )
            }

            for pose in poseNeeds[normalizedCharacterName, default: []] where !hasPoseCoverage(pose, for: character) {
                appendRequest(
                    &requests,
                    seenKeys: &seenKeys,
                    request: AnimationAssetRequest(
                        characterID: character.id,
                        characterName: character.name,
                        kind: .poseVariant,
                        target: pose.rawValue,
                        reason: "The plan asks \(character.name) for pose '\(pose.rawValue)', but no matching pose coverage was found."
                    )
                )
            }

            for angle in angleNeeds[normalizedCharacterName, default: []] where !hasAngleCoverage(angle, for: character) {
                appendRequest(
                    &requests,
                    seenKeys: &seenKeys,
                    request: AnimationAssetRequest(
                        characterID: character.id,
                        characterName: character.name,
                        kind: .angleCoverage,
                        target: angle.rawValue,
                        reason: "The plan asks \(character.name) for the '\(angle.rawValue)' angle, but no matching angle coverage was found."
                    )
                )
            }
        }

        return requests.sorted {
            if $0.characterName == $1.characterName {
                if $0.kind == $1.kind {
                    return $0.target < $1.target
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.characterName < $1.characterName
        }
    }

    private func collectExpressionNeeds(from plan: LLMAnimationPlan) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]

        for expression in plan.expressions {
            insertNormalized(expression.expression, into: &result, for: expression.characterName)
        }

        for placement in plan.characterPlacements {
            insertNormalized(placement.emotion, into: &result, for: placement.characterName)
        }

        for beat in plan.dialogueBeats {
            insertNormalized(beat.expression, into: &result, for: beat.characterName)
        }

        for application in plan.shotPresetApplications {
            for override in application.characterOverrides {
                insertNormalized(override.expression, into: &result, for: override.characterName)
            }
        }

        return result
    }

    private func collectPoseNeeds(from plan: LLMAnimationPlan) -> [String: Set<CharacterPackagePose>] {
        var result: [String: Set<CharacterPackagePose>] = [:]

        for placement in plan.characterPlacements {
            insert(placement.pose, into: &result, for: placement.characterName)
        }

        for motion in plan.motions {
            insert(motion.pose, into: &result, for: motion.characterName)
        }

        for application in plan.shotPresetApplications {
            for override in application.characterOverrides {
                insert(override.pose, into: &result, for: override.characterName)
            }
        }

        return result
    }

    private func collectAngleNeeds(from plan: LLMAnimationPlan) -> [String: Set<AngleView>] {
        var result: [String: Set<AngleView>] = [:]

        for placement in plan.characterPlacements {
            insert(placement.viewAngle, into: &result, for: placement.characterName)
        }

        for motion in plan.motions {
            insert(motion.viewAngle, into: &result, for: motion.characterName)
        }

        for application in plan.shotPresetApplications {
            for override in application.characterOverrides {
                insert(override.viewAngle, into: &result, for: override.characterName)
            }
        }

        return result
    }

    private func hasVisemeCoverage(for character: AnimationCharacter) -> Bool {
        character.parts.contains { part in
            part.partType == .mouth &&
            part.drawingSets.values.contains { drawingSet in
                drawingSet.variants.contains { variant in
                    let searchable = searchableText(for: variant)
                    return variant.sourceAssetRole == .viseme ||
                        searchable.contains("viseme") ||
                        searchable.contains("mbp") ||
                        searchable.contains("rest")
                }
            }
        }
    }

    private func hasExpressionCoverage(_ expression: String, for character: AnimationCharacter) -> Bool {
        character.parts.contains { part in
            part.drawingSets.values.contains { drawingSet in
                drawingSet.variants.contains { variant in
                    searchableText(for: variant).contains(expression)
                }
            }
        }
    }

    private func hasPoseCoverage(_ pose: CharacterPackagePose, for character: AnimationCharacter) -> Bool {
        character.parts.contains { part in
            part.drawingSets.values.contains { drawingSet in
                drawingSet.variants.contains { variant in
                    variant.sourcePose == pose || searchableText(for: variant).contains(pose.rawValue)
                }
            }
        }
    }

    private func hasAngleCoverage(_ angle: AngleView, for character: AnimationCharacter) -> Bool {
        character.parts.contains { part in
            if let drawingSet = part.drawingSets[angle], !drawingSet.variants.isEmpty {
                return true
            }

            return part.drawingSets.values.contains { drawingSet in
                drawingSet.variants.contains { $0.sourceAngle == angle }
            }
        }
    }

    private func searchableText(for variant: DrawingVariant) -> String {
        (
            (variant.sourceTags ?? []) +
            [
                variant.name,
                variant.sourceAssetName,
                variant.sourceAssetRole?.rawValue,
                variant.sourcePose?.rawValue,
                variant.sourceAngle?.rawValue,
                variant.sourceNotes
            ]
            .compactMap { $0 }
        )
        .joined(separator: " ")
        .lowercased()
    }

    private func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
    }

    private func insertNormalized(
        _ value: String?,
        into result: inout [String: Set<String>],
        for characterName: String
    ) {
        guard let normalized = value?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty
        else {
            return
        }

        result[normalizedName(characterName), default: []].insert(normalized)
    }

    private func insert<T: Hashable>(
        _ value: T?,
        into result: inout [String: Set<T>],
        for characterName: String
    ) {
        guard let value else { return }
        result[normalizedName(characterName), default: []].insert(value)
    }

    private func appendRequest(
        _ requests: inout [AnimationAssetRequest],
        seenKeys: inout Set<String>,
        request: AnimationAssetRequest
    ) {
        let key = "\(request.characterName.lowercased())|\(request.kind.rawValue)|\(request.target.lowercased())"
        guard seenKeys.insert(key).inserted else { return }
        requests.append(request)
    }
}
