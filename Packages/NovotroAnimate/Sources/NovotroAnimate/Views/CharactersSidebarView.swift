import SwiftUI
import NovotroProjectKit

@available(macOS 26.0, *)
struct CharactersSidebarView: View {
    @Bindable var store: AnimateStore

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
                        if !store.geminiAPIKey.isEmpty {
                            Button("Generate Assets...") {
                                store.selectedCharacterID = character.id
                                store.showGenerationSheet = true
                            }
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
    }

    @ViewBuilder
    private func characterRow(_ character: AnimationCharacter) -> some View {
        let owpChar = store.owpCharacter(for: character)
        HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
            // Thumbnail
            if let profileURL = store.resolvedCharacterAssetURL(for: character.profileImagePath),
               let image = NSImage(contentsOf: profileURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
            } else if let owpChar,
               let imageDir = store.owpCharacterImageDirectory(for: owpChar),
               let firstImage = owpChar.images.first {
                let imageURL = imageDir.appendingPathComponent(firstImage.filename)
                AsyncImage(url: imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                } placeholder: {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }

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
