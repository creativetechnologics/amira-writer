import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct UniversalImagePickerSheet: View {
    @Bindable var store: AnimateStore
    var maxSelections: Int = 5
    var onConfirm: ([String]) -> Void
    var onCancel: () -> Void

    @State private var allImages: [ImagineImageCategory: [ImagineImagePickerEntry]] = [:]
    @State private var selectedCategory: ImagineImageCategory? = nil
    @State private var selectedPaths: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Reference Images").font(.headline)
                Spacer()
                Text("\(selectedPaths.count)/\(maxSelections) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            HStack(spacing: 0) {
                categorySidebar.frame(width: 180)
                Divider()
                imageGrid.frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            if !selectedPaths.isEmpty { stagingTray }

            Divider()

            HStack {
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Confirm (\(selectedPaths.count))") { onConfirm(selectedPaths) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedPaths.isEmpty)
            }
            .padding()
        }
        .frame(width: 700, height: 550)
        .onAppear { loadAllImages() }
    }

    private var categorySidebar: some View {
        List(selection: $selectedCategory) {
            ForEach(ImagineImageCategory.allCases) { category in
                let count = allImages[category]?.count ?? 0
                Label {
                    VStack(alignment: .leading) {
                        Text(category.rawValue)
                        Text("\(count) images").font(.caption2).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: category.systemImage)
                }
                .tag(category)
            }
        }
        .listStyle(.sidebar)
    }

    private var imageGrid: some View {
        ScrollView {
            if let category = selectedCategory, let entries = allImages[category] {
                if entries.isEmpty {
                    Text("No images in this category").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 100)
                } else {
                    let grouped = Dictionary(grouping: entries, by: \.subcategoryLabel)
                    let sortedKeys = grouped.keys.sorted()

                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sortedKeys, id: \.self) { key in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(key).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 6) {
                                    ForEach(grouped[key] ?? [], id: \.id) { entry in
                                        pickerThumbnail(entry: entry)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Choose a category from the sidebar").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 100)
            }
        }
    }

    @ViewBuilder
    private func pickerThumbnail(entry: ImagineImagePickerEntry) -> some View {
        let isSelected = selectedPaths.contains(entry.path)

        ZStack(alignment: .topTrailing) {
            AsyncImage(url: URL(fileURLWithPath: entry.path)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80).clipped()
                default:
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                        .frame(width: 80, height: 80)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .background(Circle().fill(.ultraThinMaterial).frame(width: 18, height: 18))
                .padding(4)
        }
        .onTapGesture { toggleSelection(entry.path) }
    }

    private var stagingTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedPaths, id: \.self) { path in
                    ZStack(alignment: .topTrailing) {
                        AsyncImage(url: URL(fileURLWithPath: path)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 50, height: 50).clipped()
                            default:
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                                    .frame(width: 50, height: 50)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Button {
                            selectedPaths.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14)).foregroundStyle(.white)
                                .background(Circle().fill(.red).frame(width: 16, height: 16))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 66)
        .background(.bar)
    }

    private func loadAllImages() {
        guard let owpURL = store.fileOWPURL else { return }
        allImages = ImagineProjectStorage.scanAllProjectImages(owpURL: owpURL, characters: store.characters, scenes: store.scenes)
    }

    private func toggleSelection(_ path: String) {
        if let index = selectedPaths.firstIndex(of: path) {
            selectedPaths.remove(at: index)
        } else if selectedPaths.count < maxSelections {
            selectedPaths.append(path)
        }
    }
}
