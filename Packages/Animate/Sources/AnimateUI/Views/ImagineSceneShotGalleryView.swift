import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct ImagineSceneShotGalleryView: View {
    let imagePaths: [String]
    let thumbnailSize: CGFloat
    let onSelect: (String) -> Void
    let onImport: () -> Void
    let onDelete: (String) -> Void
    var selectedPath: String? = nil

    @State private var isDragTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(imagePaths.count) images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onImport()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .controlSize(.mini)
            }

            if imagePaths.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize))], spacing: 6) {
                    ForEach(imagePaths, id: \.self) { path in
                        thumbnail(for: path)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDragTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.03))
            .frame(minHeight: 60)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("Drop images here or click Import")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
    }

    @ViewBuilder
    private func thumbnail(for path: String) -> some View {
        let isSelected = selectedPath == path
        let url = URL(fileURLWithPath: path)

        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailSize, height: thumbnailSize)
                    .clipped()
            default:
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: thumbnailSize, height: thumbnailSize)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            onSelect(path)
        }
        .contextMenu {
            Button("Show in Finder") {
                ImagineProjectStorage.revealInFinder(path)
            }
            Button("Copy Image") {
                if let image = NSImage(contentsOfFile: path) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDelete(path)
            }
        }
        .draggable(url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let urlString = String(data: data, encoding: .utf8),
                      let url = URL(string: urlString) else { return }
                let ext = url.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "webp", "tiff"].contains(ext) else { return }
                DispatchQueue.main.async {
                    onSelect(url.path)
                }
            }
            handled = true
        }
        return handled
    }
}
