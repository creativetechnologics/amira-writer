import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct CharacterNotesSectionView: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Character Type", systemImage: "person.crop.rectangle")
                        .font(.headline)

                    Picker(
                        "Character Type",
                        selection: Binding(
                            get: { character.defaultWardrobeType },
                            set: { store.updateCharacterDefaultWardrobeType($0, for: character.id) }
                        )
                    ) {
                        ForEach(CharacterWardrobeType.allCases) { wardrobe in
                            Text(wardrobe.displayName).tag(wardrobe)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Gender", systemImage: "figure.stand")
                        .font(.headline)

                    Picker(
                        "Gender",
                        selection: Binding(
                            get: { character.genderType },
                            set: { store.updateCharacterGenderType($0, for: character.id) }
                        )
                    ) {
                        ForEach(CharacterGenderType.allCases) { gender in
                            Text(gender.displayName).tag(gender)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Age", systemImage: "number")
                        .font(.headline)

                    TextField(
                        "Age",
                        text: Binding(
                            get: { character.age.map(String.init) ?? "" },
                            set: { newValue in
                                let digits = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                if digits.isEmpty {
                                    store.updateCharacterAge(nil, for: character.id)
                                } else {
                                    store.updateCharacterAge(Int(digits), for: character.id)
                                }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 88)
                }
            }

            Text("Image generation uses Character Type, Gender, Age, and Prompt Notes when writing prompts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            DebouncedTextEditorRow(
                title: "Prompt Notes",
                icon: "sparkles",
                storeValue: character.promptNotes,
                placeholder: "Canonical visual and costume rules for future character image generation...",
                onChange: { store.updateCharacterPromptNotes($0, for: character.id) }
            )

            DebouncedTextEditorRow(
                title: "Backstory",
                icon: "book.fill",
                storeValue: character.backstory,
                placeholder: "Enter character backstory, history, and origin...",
                onChange: { store.updateCharacterBackstory($0, for: character.id) }
            )

            DebouncedTextEditorRow(
                title: "Personality",
                icon: "brain.fill",
                storeValue: character.personality,
                placeholder: "Describe personality traits, mannerisms, and behaviors...",
                onChange: { store.updateCharacterPersonality($0, for: character.id) }
            )

            DebouncedTextEditorRow(
                title: "Notes",
                icon: "note.text",
                storeValue: character.notes,
                placeholder: "General notes about the character...",
                onChange: { store.updateCharacterNotes($0, for: character.id) }
            )
        }
    }
}
