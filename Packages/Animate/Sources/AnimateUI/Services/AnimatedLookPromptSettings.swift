import Foundation

@available(macOS 26.0, *)
enum AnimatedLookPromptSettings {
    static let masterPromptDefaultsKey = "animate.masterAnimatedLookPrompt"
    static let canvasToggleDefaultsKey = "animate.masterAnimatedLook.canvasEnabled"
    static let geminiGenerationToggleDefaultsKey = "animate.masterAnimatedLook.geminiGenerationEnabled"
    static let preflightToggleDefaultsKey = "animate.masterAnimatedLook.preflightEnabled"

    static func loadMasterPrompt(defaults: UserDefaults = .standard) -> String {
        (defaults.string(forKey: masterPromptDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasConfiguredMasterPrompt(defaults: UserDefaults = .standard) -> Bool {
        !loadMasterPrompt(defaults: defaults).isEmpty
    }

    static func compose(
        basePrompt: String,
        includeMasterPrompt: Bool,
        defaults: UserDefaults = .standard
    ) -> String {
        let trimmedBasePrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard includeMasterPrompt else { return trimmedBasePrompt }

        let masterPrompt = loadMasterPrompt(defaults: defaults)
        guard !masterPrompt.isEmpty else { return trimmedBasePrompt }
        guard !trimmedBasePrompt.isEmpty else { return masterPrompt }

        return [masterPrompt, trimmedBasePrompt].joined(separator: "\n\n")
    }
}
