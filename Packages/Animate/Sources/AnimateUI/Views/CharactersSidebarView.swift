import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct CharactersSidebarView: View {
    @Bindable var store: AnimateStore
    @State private var renamingCharacter: AnimationCharacter?
    @State private var renameDraft: String = ""

    var body: some View {
        OperaChromeSidebarList {
            if store.characters.isEmpty {
                OperaChromeSidebarRow {
                    Text("No characters — open a project")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            } else {
                ForEach(store.characters) { character in
                    Button {
                        store.selectedCharacterID = character.id
                    } label: {
                        OperaChromeSidebarRow(
                            isSelected: store.selectedCharacterID == character.id
                        ) {
                            characterRow(character)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit Rig") {
                            store.selectedCharacterID = character.id
                            store.showRigEditor = true
                        }
                        if store.canGenerateGeminiImagesImmediately {
                            Button("Generate Assets...") {
                                store.selectedCharacterID = character.id
                                store.showGenerationSheet = true
                            }
                        }
                        Button("Rename…") {
                            renamingCharacter = character
                            renameDraft = character.name
                        }
                        Button("Save Rig") {
                            store.saveCharacterRig(character.id)
                        }
                        Button("Import Package...") {
                            store.selectedCharacterID = character.id
                            openCharacterPackagePicker()
                        }
                    }
                }
            }
        }
        .sheet(item: $renamingCharacter) { character in
            RenameCharacterSheet(
                initialName: character.name,
                draft: $renameDraft,
                onCancel: { renamingCharacter = nil },
                onSave: {
                    store.renameCharacter(renameDraft, for: character.id)
                    renamingCharacter = nil
                }
            )
        }
        .task(id: store.owpURL?.path) {
            store.recoverMissingPersistedCharactersIfNeeded()
        }
    }

    @ViewBuilder
    private func characterRow(_ character: AnimationCharacter) -> some View {
        let owpChar = store.owpCharacter(for: character)
        HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
            // Thumbnail — async load so selecting a character never blocks
            // the sidebar on a fresh image decode.
            AsyncStoreThumbnailImage(
                store: store,
                path: character.profileImagePath,
                maxSize: 48,
                width: 24,
                height: 24,
                contentMode: .fill,
                cornerRadius: 12
            ) {
                ZStack {
                    Circle().fill(.quaternary.opacity(0.22))
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            }
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(character.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .lineLimit(1)
                    if let colorHex = owpChar?.colorHex {
                        Circle()
                            .fill(ColorHex.color(from: colorHex) ?? .gray)
                            .frame(width: 6, height: 6)
                    }
                }
                if !character.parts.isEmpty {
                    Text("\(character.parts.count) parts")
                        .font(.system(size: 10))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            }
        }
    }

    private func openCharacterPackagePicker() {
        // This is a simplified version - the full implementation would need
        // access to the import preview state, which is managed in CharactersPageView
        // For now, we'll just set a notification or callback
        NotificationCenter.default.post(
            name: Notification.Name("OpenCharacterPackagePicker"),
            object: store.selectedCharacterID
        )
    }
}

@available(macOS 26.0, *)
private struct RenameCharacterSheet: View {
    let initialName: String
    @Binding var draft: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Character")
                .font(.headline)

            TextField("Character Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onAppear {
                    if draft.isEmpty {
                        draft = initialName
                    }
                }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
