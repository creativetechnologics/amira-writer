import Foundation
import ProjectKit

@available(macOS 26.0, *)
enum AnimateLLMPromptTarget: Sendable {
    case masterSheet
    case headSheet
    case headSlot(pose: String)
    case costumeSheet(costumeName: String)
    case costumeSlot(costumeName: String, pose: String)
    case accessory(costumeName: String, accessoryName: String)
}

@available(macOS 26.0, *)
enum AnimateLLMGenerationTarget: Sendable {
    case masterSheet
    case headSheet
    case headPoses
    case costumeSheet(costumeName: String)
    case costumePoses(costumeName: String)
    case accessory(costumeName: String, accessoryName: String)
    case inspiration
}

@available(macOS 26.0, *)
enum AnimateLLMAction: Sendable {
    case editPrompt(target: AnimateLLMPromptTarget, newPrompt: String)
    case generate(target: AnimateLLMGenerationTarget, count: Int)
    case batchSubmit(wardrobe: String, count: Int)
    case toggleCurated(filename: String)
    case setReference(filename: String)
    case approveVariant(target: String, index: Int)
    case updateCharacter(field: String, value: String)
}

@available(macOS 26.0, *)
@MainActor
enum AnimateLLMAgent {

    // MARK: - System Prompt

    static func buildSystemPrompt(for character: AnimationCharacter, store: AnimateStore) -> String {
        // Build a comprehensive system prompt including:
        // 1. Role description
        // 2. Character context (name, gender, age, wardrobe)
        // 3. Workflow status (counts of inspiration images, approved sheets, etc.)
        // 4. Current prompts (master sheet, head sheet, costume sheets)
        // 5. Available action format with [ACTION] blocks
        // 6. Instructions to be concise (inspector panel)

        var parts: [String] = []

        parts.append("""
        You are an assistant for character asset generation in an animation production tool. \
        You help edit prompts, trigger image generations, and manage the character reference workflow. \
        Keep responses concise — this is a narrow inspector panel.
        """)

        // Character info
        parts.append("""
        Current character: \(character.name)
        Gender: \(character.genderType.displayName)
        Age: \(character.age.map { String($0) } ?? "unset")
        Default wardrobe: \(character.defaultWardrobeType.displayName)
        """)

        // Workflow status
        let curatedCount = character.curatedInspirationImagePaths.count
        let hasApprovedMaster = character.approvedMasterReferenceSheetVariant != nil
        let masterVariantCount = character.masterReferenceSheetVariants.count
        let hasApprovedHeadSheet = character.approvedHeadTurnaroundSheetVariant != nil
        let approvedHeadPoses = character.headTurnaroundSlots.filter { $0.approvedVariant != nil }.count

        parts.append("""
        Workflow status:
        - Inspiration images: \(character.inspirationImagePaths.count) total, \(curatedCount) curated
        - Inspiration reference: \(character.inspirationReferenceImagePath != nil ? "set" : "not set")
        - Master sheet: \(hasApprovedMaster ? "approved" : "not approved") (\(masterVariantCount) variant\(masterVariantCount == 1 ? "" : "s"))
        - Head turnaround sheet: \(hasApprovedHeadSheet ? "approved" : "not approved")
        - Head poses: \(approvedHeadPoses)/\(character.headTurnaroundSlots.count) approved
        """)

        // Costume status
        for costume in character.costumeReferenceSets {
            let approvedSheet = costume.approvedSheetVariant != nil
            let approvedPoses = costume.fullBodySlots.filter { $0.approvedVariant != nil }.count
            let approvedAccessories = costume.accessorySlots.filter { $0.approvedVariant != nil }.count
            parts.append("- Costume \"\(costume.name)\": sheet \(approvedSheet ? "approved" : "not approved"), \(approvedPoses)/\(costume.fullBodySlots.count) poses, \(approvedAccessories)/\(costume.accessorySlots.count) accessories")
        }

        // Current prompts (truncated for context window)
        let masterPrompt = character.masterReferenceSheetPrompt
        if !masterPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let truncated = masterPrompt.count > 500 ? String(masterPrompt.prefix(500)) + "..." : masterPrompt
            parts.append("\nCurrent master sheet prompt:\n\(truncated)")
        }

        // Inspiration image filenames (for toggle/set commands)
        if !character.inspirationImagePaths.isEmpty {
            let filenames = character.inspirationImagePaths.suffix(20).map { URL(fileURLWithPath: $0).lastPathComponent }
            parts.append("\nInspiration image filenames (most recent):\n\(filenames.joined(separator: "\n"))")
        }

        // Action format
        parts.append("""

        You can take actions by including [ACTION] blocks in your response. Include them AFTER your conversational response.

        Free actions (execute immediately):
          [ACTION type="edit_prompt" target="master_sheet"]full new prompt text[/ACTION]
          [ACTION type="edit_prompt" target="head_sheet"]full new prompt text[/ACTION]
          [ACTION type="edit_prompt" target="costume_sheet" costume="Military"]full new prompt text[/ACTION]
          [ACTION type="toggle_curated" file="filename.png"][/ACTION]
          [ACTION type="set_reference" file="filename.png"][/ACTION]
          [ACTION type="approve_variant" target="master_sheet" index="0"][/ACTION]
          [ACTION type="update_character" field="age" value="30"][/ACTION]

        Paid actions (require user confirmation before running):
          [ACTION type="generate" target="master_sheet" count="3"][/ACTION]
          [ACTION type="generate" target="head_sheet" count="1"][/ACTION]
          [ACTION type="generate" target="costume_sheet" costume="Military" count="1"][/ACTION]
          [ACTION type="generate" target="head_poses" count="6"][/ACTION]
          [ACTION type="generate" target="costume_poses" costume="Military" count="6"][/ACTION]
          [ACTION type="generate" target="inspiration" count="1"][/ACTION]
          [ACTION type="batch_submit" wardrobe="soldier" count="27"][/ACTION]

        When editing prompts, ALWAYS output the COMPLETE replacement prompt text.
        When the user asks to generate something, determine the correct target and count.
        For questions about status or workflow, respond conversationally without action blocks.
        Do not include character names in prompts — use "this character" instead.
        """)

        return parts.joined(separator: "\n\n")
    }

    static func buildShowSystemPrompt(store: AnimateStore) -> String {
        var parts: [String] = []

        parts.append("""
        You are an assistant for character asset generation in an animation production tool. \
        You are in show-wide mode — you can see all characters and perform cross-character operations. \
        Keep responses concise — this is a narrow inspector panel.
        """)

        parts.append("Characters in this project:")
        for character in store.characters {
            let hasApprovedMaster = character.approvedMasterReferenceSheetVariant != nil
            let curatedCount = character.curatedInspirationImagePaths.count
            parts.append("- \(character.name): \(character.inspirationImagePaths.count) inspiration (\(curatedCount) curated), master sheet \(hasApprovedMaster ? "approved" : "needed")")
        }

        // Same action format as character mode
        parts.append("""

        You can take actions using [ACTION] blocks. For show-wide mode, specify which character:
          [ACTION type="generate" target="master_sheet" character="Character Name" count="3"][/ACTION]
          [ACTION type="edit_prompt" target="master_sheet" character="Character Name"]new prompt[/ACTION]

        When no character is specified, actions apply to all characters.
        For questions about status, respond conversationally without action blocks.
        """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Action Parsing

    static func parseActions(from response: String) -> [AnimateLLMAction] {
        let pattern = #"\[ACTION\s+([^\]]*)\](.*?)\[/ACTION\]"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)

        let nsString = response as NSString
        let matches = regex.matches(in: response, range: NSRange(location: 0, length: nsString.length))

        var actions: [AnimateLLMAction] = []

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let attributes = nsString.substring(with: match.range(at: 1))
            let body = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

            guard let type = extractAttribute("type", from: attributes) else { continue }

            switch type {
            case "edit_prompt":
                if let target = parsePromptTarget(from: attributes), !body.isEmpty {
                    actions.append(.editPrompt(target: target, newPrompt: body))
                }

            case "generate":
                if let target = parseGenerationTarget(from: attributes) {
                    let count = Int(extractAttribute("count", from: attributes) ?? "1") ?? 1
                    actions.append(.generate(target: target, count: count))
                }

            case "batch_submit":
                let wardrobe = extractAttribute("wardrobe", from: attributes) ?? "soldier"
                let count = Int(extractAttribute("count", from: attributes) ?? "27") ?? 27
                actions.append(.batchSubmit(wardrobe: wardrobe, count: count))

            case "toggle_curated":
                if let file = extractAttribute("file", from: attributes) {
                    actions.append(.toggleCurated(filename: file))
                }

            case "set_reference":
                if let file = extractAttribute("file", from: attributes) {
                    actions.append(.setReference(filename: file))
                }

            case "approve_variant":
                if let target = extractAttribute("target", from: attributes) {
                    let index = Int(extractAttribute("index", from: attributes) ?? "0") ?? 0
                    actions.append(.approveVariant(target: target, index: index))
                }

            case "update_character":
                if let field = extractAttribute("field", from: attributes),
                   let value = extractAttribute("value", from: attributes) {
                    actions.append(.updateCharacter(field: field, value: value))
                }

            default:
                break
            }
        }

        return actions
    }

    // MARK: - Action Execution (free actions)

    static func executeAction(_ action: AnimateLLMAction, on store: AnimateStore, characterID: UUID) -> String {
        switch action {
        case .editPrompt(let target, let newPrompt):
            switch target {
            case .masterSheet:
                store.updateMasterReferenceSheetPrompt(newPrompt, for: characterID)
                return "Updated master sheet prompt."
            case .headSheet:
                store.updateHeadTurnaroundSheetPrompt(newPrompt, for: characterID)
                return "Updated head turnaround sheet prompt."
            case .costumeSheet(let name):
                if let costumeID = store.characters.first(where: { $0.id == characterID })?
                    .costumeReferenceSets.first(where: { $0.name == name })?.id {
                    store.updateCostumeSheetPrompt(newPrompt, costumeID: costumeID, for: characterID)
                    return "Updated \(name) costume sheet prompt."
                }
                return "Costume \"\(name)\" not found."
            default:
                return "Prompt target not yet supported for direct editing."
            }

        case .toggleCurated(let filename):
            if let character = store.characters.first(where: { $0.id == characterID }),
               let path = character.inspirationImagePaths.first(where: { $0.hasSuffix(filename) }) {
                store.toggleCuratedInspirationImage(path, for: characterID)
                let isCurated = store.characters.first(where: { $0.id == characterID })?
                    .curatedInspirationImagePaths.contains(path) ?? false
                return isCurated ? "Added \(filename) to curated references." : "Removed \(filename) from curated references."
            }
            return "Image \"\(filename)\" not found."

        case .setReference(let filename):
            if let character = store.characters.first(where: { $0.id == characterID }),
               let path = character.inspirationImagePaths.first(where: { $0.hasSuffix(filename) }) {
                store.setInspirationReferenceImage(path, for: characterID)
                return "Set \(filename) as the inspiration reference image."
            }
            return "Image \"\(filename)\" not found."

        case .updateCharacter(let field, let value):
            return executeCharacterUpdate(field: field, value: value, characterID: characterID, store: store)

        default:
            return "Action requires confirmation."
        }
    }

    private static func executeCharacterUpdate(field: String, value: String, characterID: UUID, store: AnimateStore) -> String {
        guard let index = store.characters.firstIndex(where: { $0.id == characterID }) else {
            return "Character not found."
        }

        switch field.lowercased() {
        case "age":
            store.characters[index].age = Int(value)
            store.save()
            return "Updated age to \(value)."
        case "name":
            store.characters[index].name = value
            store.save()
            return "Updated name to \(value)."
        case "wardrobe", "wardrobetype", "defaultwardrobetype":
            if let wt = CharacterWardrobeType(rawValue: value.lowercased()) {
                store.characters[index].defaultWardrobeType = wt
                store.save()
                return "Updated wardrobe type to \(wt.displayName)."
            }
            return "Unknown wardrobe type: \(value)"
        default:
            return "Unknown character field: \(field)"
        }
    }

    /// Check whether an action is free (immediate) or paid (needs preflight).
    static func isFreeAction(_ action: AnimateLLMAction) -> Bool {
        switch action {
        case .editPrompt, .toggleCurated, .setReference, .approveVariant, .updateCharacter:
            return true
        case .generate, .batchSubmit:
            return false
        }
    }

    /// Describe an action for the chat history.
    static func describeAction(_ action: AnimateLLMAction) -> String {
        switch action {
        case .editPrompt(let target, _):
            switch target {
            case .masterSheet: return "Edit master sheet prompt"
            case .headSheet: return "Edit head sheet prompt"
            case .costumeSheet(let name): return "Edit \(name) costume sheet prompt"
            default: return "Edit prompt"
            }
        case .generate(let target, let count):
            switch target {
            case .masterSheet: return "Generate \(count) master sheet\(count == 1 ? "" : "s")"
            case .headSheet: return "Generate head turnaround sheet"
            case .headPoses: return "Generate \(count) head poses"
            case .costumeSheet(let name): return "Generate \(name) costume sheet"
            case .costumePoses(let name): return "Generate \(name) full-body poses"
            case .inspiration: return "Generate \(count) inspiration image\(count == 1 ? "" : "s")"
            case .accessory(let costume, let accessory): return "Generate \(accessory) for \(costume)"
            }
        case .batchSubmit(let wardrobe, let count):
            return "Submit \(count)-image \(wardrobe) inspiration batch"
        case .toggleCurated(let file): return "Toggle curated: \(file)"
        case .setReference(let file): return "Set reference: \(file)"
        case .approveVariant(let target, let index): return "Approve variant #\(index + 1) of \(target)"
        case .updateCharacter(let field, let value): return "Update \(field) to \(value)"
        }
    }

    // MARK: - Private Helpers

    private static func extractAttribute(_ name: String, from attributes: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"="([^"]*)""#
        // escapedPattern output is always valid — only fail path is malformed pattern, which cannot happen here.
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        return (attributes as NSString).substring(with: match.range(at: 1))
    }

    private static func parsePromptTarget(from attributes: String) -> AnimateLLMPromptTarget? {
        guard let target = extractAttribute("target", from: attributes) else { return nil }
        switch target {
        case "master_sheet": return .masterSheet
        case "head_sheet": return .headSheet
        default:
            if target.hasPrefix("costume_sheet") {
                if let costume = extractAttribute("costume", from: attributes) {
                    return .costumeSheet(costumeName: costume)
                }
            }
            return nil
        }
    }

    private static func parseGenerationTarget(from attributes: String) -> AnimateLLMGenerationTarget? {
        guard let target = extractAttribute("target", from: attributes) else { return nil }
        switch target {
        case "master_sheet": return .masterSheet
        case "head_sheet": return .headSheet
        case "head_poses": return .headPoses
        case "inspiration": return .inspiration
        default:
            if target == "costume_sheet", let costume = extractAttribute("costume", from: attributes) {
                return .costumeSheet(costumeName: costume)
            }
            if target == "costume_poses", let costume = extractAttribute("costume", from: attributes) {
                return .costumePoses(costumeName: costume)
            }
            return nil
        }
    }
}
