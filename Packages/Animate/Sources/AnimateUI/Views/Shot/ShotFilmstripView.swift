import SwiftUI

@available(macOS 26.0, *)
struct ShotFilmstripView: View {
    @Bindable var store: AnimateStore
    let shots: [AnimationSceneShot]
    @Binding var selectedShotIndex: Int?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let idx = selectedShotIndex, idx > 0 { selectedShotIndex = idx - 1 }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(selectedShotIndex == nil || selectedShotIndex == 0)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                            shotChip(index: index, shot: shot)
                                .id(index)
                                .onTapGesture { selectedShotIndex = index }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: selectedShotIndex) { _, newIndex in
                    if let idx = newIndex {
                        withAnimation { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
            }

            Button {
                if let idx = selectedShotIndex, idx < shots.count - 1 { selectedShotIndex = idx + 1 }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(selectedShotIndex == nil || selectedShotIndex == shots.count - 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func shotChip(index: Int, shot: AnimationSceneShot) -> some View {
        let isSelected = selectedShotIndex == index
        let statusText = "··"

        return VStack(spacing: 2) {
            Text("S\(index + 1)")
                .font(.caption.weight(.bold))
            Text(shot.cameraShot?.rawValue ?? "—")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(statusText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}
