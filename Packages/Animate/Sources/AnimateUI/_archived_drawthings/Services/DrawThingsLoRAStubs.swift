import Foundation

@available(macOS 26.0, *)
public struct DrawThingsPromptTriggerMapping: Sendable {
    public let characterTokens: [String]
    public let triggerWord: String
}

@available(macOS 26.0, *)
public enum DrawThingsPromptIdentityInjector {
    public static func injectTriggers(
        into prompt: String,
        mappings: [DrawThingsPromptTriggerMapping]
    ) -> String {
        var result = prompt
        for mapping in mappings {
            for token in mapping.characterTokens {
                result = result.replacingOccurrences(of: token, with: mapping.triggerWord)
            }
        }
        return result
    }
}

@available(macOS 26.0, *)
public actor DrawThingsLoRAService {
    public struct LoRA: Sendable {
        public let file: String
        public let weight: Double
        public let mode: String
    }

    public struct LoRAPreparation: Sendable {
        public let prompt: String
        public let loras: [LoRA]
    }

    public init() {}

    func preparePrompt(
        prompt: String,
        characters: [AnimationCharacter],
        animateURL: Foundation.URL,
        config: DrawThingsPlaceConfig
    ) async throws -> LoRAPreparation {
        LoRAPreparation(prompt: prompt, loras: [])
    }
}
