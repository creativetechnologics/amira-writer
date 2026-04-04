import AppKit
import ProjectKit
import SwiftUI

@available(macOS 26.0, *)
struct Character3DAssetLibraryView: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter

    private let service = Animate3DCharacterAssetService()
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use this panel to organize the 3D files that the production engine expects beside each character. Keep the body model, face rig, mouth profile, expressions, motions, and materials together so the preview can wire them up automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            registryScaffoldCard

            if let animateURL = store.animateURL {
                let inventory = service.inventory(for: character.assetFolderSlug, in: animateURL)

                summaryCard(for: inventory)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Animate3DCharacterAssetCategory.allCases) { category in
                        categoryCard(
                            category,
                            files: inventory.files(for: category)
                        )
                    }
                }
            } else {
                emptyStateMessage(
                    icon: "folder.badge.gearshape",
                    message: "Open a project to manage 3D sidecars."
                )
            }
        }
    }

    private var registryScaffoldCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Project 3D Registry", systemImage: "shippingbox.and.arrow.down")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                    Text("Creates Animate/3d/asset-registry, character-registry, motion-registry, world-catalog, style-profiles, camera-presets, light-rigs, and atmosphere-presets.")
                        .font(.caption2)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Button("Create Registry Folders") {
                        scaffoldRegistry()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.animateURL == nil)

                    Button("Open Registry Root") {
                        openRegistryRoot()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.animateURL == nil)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.45))
        )
    }

    private func summaryCard(for inventory: Animate3DCharacterAssetInventory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(inventory.totalFileCount) sidecar file\(inventory.totalFileCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Text("\(inventory.categoryCount) populated folder\(inventory.categoryCount == 1 ? "" : "s") under \(character.assetFolderSlug)")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text("Recommended 3D folders")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text("models, face-rigs, mouth-profiles, expressions, motions, materials")
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.35))
        )
    }

    private func categoryCard(
        _ category: Animate3DCharacterAssetCategory,
        files: [Animate3DCharacterAssetFile]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(category.displayName, systemImage: category.iconName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Spacer()

                Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Import…") {
                    importAssets(for: category)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.animateURL == nil)

                Button("Open Folder") {
                    openFolder(for: category)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.animateURL == nil)
            }

            Text(category.importHint)
                .font(.caption2)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if files.isEmpty {
                emptyStateMessage(
                    icon: category.iconName,
                    message: "No \(category.displayName.lowercased()) imported yet."
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(files) { file in
                        fileRow(category: category, file: file)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.25))
        )
    }

    private func fileRow(
        category: Animate3DCharacterAssetCategory,
        file: Animate3DCharacterAssetFile
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: category.iconName)
                .font(.system(size: 17))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(1)

                Text(file.relativePath)
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .lineLimit(1)

                Text(fileMetadataLine(for: file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Reveal") {
                    revealFile(category: category, file: file)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    removeFile(category: category, file: file)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.12))
        )
    }

    private func fileMetadataLine(for file: Animate3DCharacterAssetFile) -> String {
        let size = Self.byteCountFormatter.string(fromByteCount: file.fileSize)
        let date = file.modificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date"
        return "\(size) • \(date)"
    }

    private func importAssets(for category: Animate3DCharacterAssetCategory) {
        guard let animateURL = store.animateURL else {
            store.statusMessage = "Open a project before importing 3D sidecars."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import \(category.displayName)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = category.allowedContentTypes

        panel.begin { [weak panel] response in
            guard response == .OK else { return }
            let sourceURLs = panel?.urls ?? []
            guard !sourceURLs.isEmpty else { return }

            Task { @MainActor in
                do {
                    let imported = try service.importFiles(
                        for: character.assetFolderSlug,
                        category: category,
                        from: sourceURLs,
                        in: animateURL
                    )
                    store.statusMessage = "Imported \(imported.count) \(category.displayName.lowercased()) file\(imported.count == 1 ? "" : "s")"
                } catch {
                    store.statusMessage = "Failed to import \(category.displayName.lowercased()): \(error.localizedDescription)"
                }
            }
        }
    }

    private func removeFile(
        category: Animate3DCharacterAssetCategory,
        file: Animate3DCharacterAssetFile
    ) {
        guard let animateURL = store.animateURL else { return }

        do {
            try service.removeFile(
                for: character.assetFolderSlug,
                category: category,
                relativePath: file.relativePath,
                in: animateURL
            )
            store.statusMessage = "Removed \(category.displayName.lowercased()) file: \(file.fileName)"
        } catch {
            store.statusMessage = "Failed to remove \(category.displayName.lowercased()) file: \(error.localizedDescription)"
        }
    }

    private func openFolder(for category: Animate3DCharacterAssetCategory) {
        guard let animateURL = store.animateURL else { return }
        do {
            try service.ensureFolders(for: character.assetFolderSlug, in: animateURL)
            let folderURL = service.categoryFolderURL(
                for: character.assetFolderSlug,
                category: category,
                in: animateURL
            )
            NSWorkspace.shared.activateFileViewerSelecting([folderURL])
        } catch {
            store.statusMessage = "Failed to open \(category.displayName.lowercased()) folder: \(error.localizedDescription)"
        }
    }

    private func revealFile(
        category: Animate3DCharacterAssetCategory,
        file: Animate3DCharacterAssetFile
    ) {
        guard let animateURL = store.animateURL,
              let url = service.fileURL(
                  for: character.assetFolderSlug,
                  category: category,
                  relativePath: file.relativePath,
                  in: animateURL
              ) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func scaffoldRegistry() {
        guard let animateURL = store.animateURL else { return }
        do {
            try service.ensureFolders(for: character.assetFolderSlug, in: animateURL)
            guard let projectURL = store.animateURL?.deletingLastPathComponent() else { return }
            ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)
            store.statusMessage = "Created 3D registry scaffold for \(character.name)"
        } catch {
            store.statusMessage = "Failed to scaffold 3D registry: \(error.localizedDescription)"
        }
    }

    private func openRegistryRoot() {
        guard let projectURL = store.animateURL?.deletingLastPathComponent() else { return }
        let registryRoot = projectURL.appendingPathComponent("Animate/3d")
        if !FileManager.default.fileExists(atPath: registryRoot.path) {
            ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)
        }
        NSWorkspace.shared.activateFileViewerSelecting([registryRoot])
    }

    @ViewBuilder
    private func emptyStateMessage(icon: String, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }
}
