import Foundation

@available(macOS 26.0, *)
@MainActor
final class CharacterExpressionStore {
    unowned let parent: AnimateStore
    init(parent: AnimateStore) { self.parent = parent }

    func setExpressionCue(_ expression: String?, for characterName: String, at frame: Int? = nil) {
        parent.setSemanticCue(expression, trackSuffix: "expression", for: characterName, at: frame)
    }

    func setExpressionCue(_ expression: String?, for characterID: UUID, at frame: Int? = nil) {
        guard let character = parent.characters.first(where: { $0.id == characterID }) else { return }
        parent.setSemanticCue(expression, trackSuffix: "expression", for: character.name, characterID: characterID, at: frame)
    }

    func setActionCue(_ action: String?, for characterName: String, at frame: Int? = nil) {
        parent.setSemanticCue(action, trackSuffix: "action", for: characterName, at: frame)
    }

    func setActionCue(_ action: String?, for characterID: UUID, at frame: Int? = nil) {
        guard let character = parent.characters.first(where: { $0.id == characterID }) else { return }
        parent.setSemanticCue(action, trackSuffix: "action", for: character.name, characterID: characterID, at: frame)
    }
}
