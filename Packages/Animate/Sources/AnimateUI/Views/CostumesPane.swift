import AppKit
import SwiftUI

/// Characters-page collapsible that surfaces the character's existing costume
/// reference sets and lets the user generate Gemini variations for any one of
/// them inline. Wraps `CostumeSectionView` (the full generation UI) below a
/// selector row.
@available(macOS 26.0, *)
struct CostumesPane: View {
    @Bindable var store: AnimateStore
    let characterID: UUID

    @State private var selectedCostumeID: UUID?

    private var character: AnimationCharacter? {
        store.characters.first(where: { $0.id == characterID })
    }

    private var costumes: [CharacterCostumeReferenceSet] {
        character?.costumeReferenceSets ?? []
    }

    private var selectedCostume: CharacterCostumeReferenceSet? {
        guard let id = selectedCostumeID else { return costumes.first }
        return costumes.first(where: { $0.id == id }) ?? costumes.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Costume Sets", systemImage: "tshirt")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.addCostumeReferenceSet(for: characterID)
                } label: {
                    Label("Add Costume", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if costumes.isEmpty {
                emptyState
            } else {
                costumeSelectorStrip
                Divider()
                if let costume = selectedCostume {
                    CostumeSectionView(store: store, characterID: characterID, costume: costume)
                        .id(costume.id)  // rebuild when switching costumes
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No costumes defined yet", systemImage: "tshirt")
                .font(.callout.weight(.medium))
            Text("Add a costume set here, then generate or import sheet and pose variations for it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var costumeSelectorStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(costumes) { costume in
                    costumeChip(costume)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func costumeChip(_ costume: CharacterCostumeReferenceSet) -> some View {
        let isSelected = (selectedCostume?.id == costume.id)
        Button {
            selectedCostumeID = costume.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tshirt")
                    .font(.caption)
                Text(costume.name.isEmpty ? "Untitled" : costume.name)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(costume.fullBodySlots.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? AnyShapeStyle(Color.accentColor.opacity(0.20))
                    : AnyShapeStyle(.quaternary.opacity(0.20)),
                in: Capsule())
            .overlay(
                Capsule().stroke(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
