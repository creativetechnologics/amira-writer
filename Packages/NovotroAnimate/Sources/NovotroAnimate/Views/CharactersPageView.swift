import SwiftUI
import AppKit
import NovotroProjectKit

@available(macOS 26.0, *)
struct CharactersPageView: View {
    @Bindable var store: AnimateStore
    @State private var packageImportPreview: CharacterPackageImportPreview?
    @State private var packageImportErrorMessage: String?
    @State private var previewImageIndex: Int?
    @State private var previewImagePaths: [String] = []
    @State private var thumbnailBaseSize: CGFloat = 120
    @State private var showInspirationGallery: Bool = false
    @State private var showReferenceImages: Bool = false
    var showSidebar: Bool = true

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if showSidebar {
                    characterList
                        .frame(width: min(geo.size.width * 0.3, 280))

                    Divider()
                }

                characterDetail
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $packageImportPreview) { preview in
            CharacterPackageImportSheet(
                preview: preview,
                onImport: {
                    performPackageImport(preview)
                }
            )
        }
        .alert("Character Package Import", isPresented: packageImportAlertBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(packageImportErrorMessage ?? "Unknown import error.")
        }
        .overlay {
            if let index = previewImageIndex {
                ImagePreviewOverlay(
                    paths: previewImagePaths,
                    currentIndex: Binding(
                        get: { index },
                        set: { previewImageIndex = $0 }
                    ),
                    onDismiss: { previewImageIndex = nil }
                )
            }
        }
        .sheet(isPresented: $showInspirationGallery) {
            if let character = store.selectedCharacter {
                InspirationGallerySheet(
                    character: character,
                    store: store,
                    onDismiss: { showInspirationGallery = false }
                )
            }
        }
        .sheet(isPresented: $showReferenceImages) {
            if let character = store.selectedCharacter {
                ReferenceImagesSheet(
                    character: character,
                    store: store,
                    onDismiss: { showReferenceImages = false }
                )
            }
        }
        .sheet(isPresented: $store.showImageCropper) {
            if let imagePath = store.pendingCropImagePath,
               let characterID = store.pendingCropCharacterID {
                ImageCropperView(
                    imagePath: imagePath,
                    onCrop: { cropRect in
                        store.cropAndSetProfileImage(cropRect: cropRect, for: characterID)
                    },
                    onCancel: {
                        store.cancelImageCrop()
                    }
                )
            }
        }
    }

    // MARK: - Character List

    @ViewBuilder
    private var characterList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Characters")
                    .font(.headline)
                Spacer()
                OperaChromeActionButton(
                    title: "Import Package",
                    systemImage: "shippingbox"
                ) {
                    openCharacterPackagePicker()
                }
                .disabled(store.animateURL == nil || store.selectedCharacter == nil)
                Text("\(store.characters.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if store.characters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No characters — open a project")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedCharacterID) {
                    ForEach(store.characters) { character in
                        characterRow(character)
                            .tag(character.id)
                            .draggable(character.id.uuidString)
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
                    .onMove { from, to in
                        store.moveCharacter(from: from, to: to)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(OperaChromeTheme.panelBackground)
                .dropDestination(for: String.self) { items, location in
                    guard let uuidString = items.first,
                          let characterID = UUID(uuidString: uuidString) else {
                        return false
                    }
                    store.moveCharacterToEnd(characterID: characterID)
                    return true
                }
            }
        }
    }

    @ViewBuilder
    private func characterRow(_ character: AnimationCharacter) -> some View {
        let owpChar = store.owpCharacter(for: character)
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(character.name)
                    if let colorHex = owpChar?.colorHex {
                        Circle()
                            .fill(ColorHex.color(from: colorHex) ?? .gray)
                            .frame(width: 8, height: 8)
                    }
                }
                if !character.parts.isEmpty {
                    Text("\(character.parts.count) parts")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } icon: {
            characterThumbnail(character)
        }
    }

    @ViewBuilder
    private func characterThumbnail(_ character: AnimationCharacter) -> some View {
        let owpChar = store.owpCharacter(for: character)
        if let profilePath = character.profileImagePath,
           let image = NSImage(contentsOfFile: profilePath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else if let owpChar,
                  let imageDir = store.owpCharacterImageDirectory(for: owpChar),
                  let firstImage = owpChar.images.first {
            let imageURL = imageDir.appendingPathComponent(firstImage.filename)
            AsyncImage(url: imageURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
            } placeholder: {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "person.fill")
        }
    }

    // MARK: - Character Detail

    @ViewBuilder
    private var characterDetail: some View {
        if let character = store.selectedCharacter {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    characterHeader(character)

                    Divider()

                    textInfoSection(character)

                    Divider()

                    inspirationImagesSection(character)

                    Divider()

                    animatedImagesSection(character)

                    Divider()

                    characterPackagesSection(character)
                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.2")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a character to view details")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Character Header

    @ViewBuilder
    private func characterHeader(_ character: AnimationCharacter) -> some View {
        let owpChar = store.owpCharacter(for: character)

        HStack(spacing: 16) {
            Button {
                store.setCharacterProfileImageFromPicker(for: character.id)
            } label: {
                profileImageView(character: character, owpChar: owpChar)
            }
            .buttonStyle(.plain)
            .help("Click to select and crop profile image")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(character.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    if let colorHex = owpChar?.colorHex {
                        Circle()
                            .fill(ColorHex.color(from: colorHex) ?? .gray)
                            .frame(width: 12, height: 12)
                    }
                }

                if !character.description.isEmpty {
                    Text(character.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            inspirationReferenceView(character: character)
        }
    }

    @ViewBuilder
    private func inspirationReferenceView(character: AnimationCharacter) -> some View {
        Button {
            showReferenceImages = true
        } label: {
            HStack(spacing: 8) {
                Text("Reference Images")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let refPath = character.inspirationReferenceImagePath,
                   let image = NSImage(contentsOfFile: refPath) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "photo.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(4)
                                .background(.ultraThinMaterial, in: Circle())
                                .offset(x: 4, y: 4)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "photo.fill")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "plus.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(4)
                                .background(.ultraThinMaterial, in: Circle())
                                .offset(x: 4, y: 4)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .help("Click to manage reference images")
    }

    @ViewBuilder
    private func profileImageView(character: AnimationCharacter, owpChar: OPWCharacter?) -> some View {
        if let profilePath = character.profileImagePath,
           let image = NSImage(contentsOfFile: profilePath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .offset(x: 4, y: 4)
                }
        } else if let owpChar,
                  let imageDir = store.owpCharacterImageDirectory(for: owpChar),
                  let firstImage = owpChar.images.first {
            let imageURL = imageDir.appendingPathComponent(firstImage.filename)
            AsyncImage(url: imageURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } placeholder: {
                placeholderProfileImage
            }
        } else {
            placeholderProfileImage
        }
    }

    private var placeholderProfileImage: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.quaternary)
            .frame(width: 64, height: 64)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "camera.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(.ultraThinMaterial, in: Circle())
                    .offset(x: 4, y: 4)
            }
    }

    // MARK: - Text Info Section

    @ViewBuilder
    private func textInfoSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            textEditorRow(
                title: "Backstory",
                icon: "book.fill",
                text: character.backstory,
                placeholder: "Enter character backstory, history, and origin...",
                onChange: { store.updateCharacterBackstory($0, for: character.id) }
            )

            textEditorRow(
                title: "Personality",
                icon: "brain.fill",
                text: character.personality,
                placeholder: "Describe personality traits, mannerisms, and behaviors...",
                onChange: { store.updateCharacterPersonality($0, for: character.id) }
            )

            textEditorRow(
                title: "Notes",
                icon: "note.text",
                text: character.notes,
                placeholder: "General notes about the character...",
                onChange: { store.updateCharacterNotes($0, for: character.id) }
            )
        }
    }

    private func textEditorRow(
        title: String,
        icon: String,
        text: String,
        placeholder: String,
        onChange: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { text },
                    set: onChange
                ))
                .font(.body)
                .frame(minHeight: 100, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))

                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Inspiration Images Section

    @ViewBuilder
    private func inspirationImagesSection(_ character: AnimationCharacter) -> some View {
        ImageGallerySection(
            title: "Inspiration Images",
            icon: "photo.stack",
            paths: character.inspirationImagePaths,
            thumbnailBaseSize: $thumbnailBaseSize,
            onImport: { store.importInspirationImages(for: character.id) },
            onRemove: { index in store.removeInspirationImage(at: index, for: character.id) },
            onPreview: { index, paths in
                previewImageIndex = index
                previewImagePaths = paths
            }
        )
    }

    // MARK: - Animated Images Section

    @ViewBuilder
    private func animatedImagesSection(_ character: AnimationCharacter) -> some View {
        ImageGallerySection(
            title: "Animated Images",
            icon: "figure.walk.motion",
            paths: character.animatedImagePaths,
            thumbnailBaseSize: $thumbnailBaseSize,
            onImport: { store.importAnimatedImages(for: character.id) },
            onRemove: { index in store.removeAnimatedImage(at: index, for: character.id) },
            onPreview: { index, paths in
                previewImageIndex = index
                previewImagePaths = paths
            }
        )
    }

    // MARK: - Character Packages Section

    @ViewBuilder
    private func characterPackagesSection(_ character: AnimationCharacter) -> some View {
        let packages = installedPackages(for: character)
        let activePackageID = activePackageID(for: character)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Character Packages", systemImage: "shippingbox")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(packages.count) packages")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button("Import Package...") {
                    openCharacterPackagePicker()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.animateURL == nil)
            }

            Text("Character Packages contain all the parts and pieces needed for animation—rig assets, blueprints, poses, and generation configs. Import packages to build your character's animation library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if packages.isEmpty {
                emptyStateMessage(
                    icon: "shippingbox",
                    message: "No imported packages yet. Import a package to add animation assets."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(packages) { package in
                        CharacterPackageCardView(
                            package: package,
                            previewURL: primaryAssetURL(for: package),
                            isActive: package.id == activePackageID,
                            onSetActive: {
                                setActivePackage(package.id, for: character)
                            },
                            onDelete: {
                                deletePackage(package.id, for: character)
                            }
                        )
                    }
                }
            }
        }
    }

    private func deletePackage(_ packageID: UUID, for character: AnimationCharacter) {
        let packages = installedPackages(for: character)
        guard let package = packages.first(where: { $0.id == packageID }) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete Character Package?"
        alert.informativeText = "This will permanently delete '\(package.manifest.displayName)' and all its assets. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let success = CharacterPackageLibrary().deletePackage(
            packageID,
            for: character.owpSlug,
            in: store.animateURL!
        )

        if success {
            if store.activePackageID(for: character.owpSlug) == packageID {
                store.setActivePackage(nil, for: character.owpSlug)
            }
            store.statusMessage = "Deleted package: \(package.manifest.displayName)"
        } else {
            store.statusMessage = "Failed to delete package"
        }
    }

    // MARK: - Image Gallery Components

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

    // MARK: - Helpers

    private var packageImportAlertBinding: Binding<Bool> {
        Binding(
            get: { packageImportErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    packageImportErrorMessage = nil
                }
            }
        )
    }

    private func openCharacterPackagePicker() {
        guard let animateURL = store.animateURL else {
            packageImportErrorMessage = "Open a project before importing a character package."
            return
        }
        guard let character = store.selectedCharacter else {
            packageImportErrorMessage = "Select a character before importing a character package."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import Character Package for \(character.name)"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let packageURL = panel.url else { return }
            prepareImportPreview(for: packageURL, animateURL: animateURL)
        }
    }

    private func prepareImportPreview(for packageURL: URL, animateURL: URL) {
        let service = CharacterPackageImportService()
        let targetCharacterSlug = store.selectedCharacter?.owpSlug

        do {
            let bundle = try service.loadPackage(from: packageURL)
            let blockingIssues = bundle.validationReport.issues.filter { $0.severity == .error }

            var importPlan: CharacterPackageImportPlan?
            var importErrorMessage: String?

            if blockingIssues.isEmpty {
                do {
                    importPlan = try service.makeImportPlan(
                        from: packageURL,
                        into: animateURL,
                        targetCharacterSlug: targetCharacterSlug
                    )
                } catch {
                    importErrorMessage = error.localizedDescription
                }
            }

            packageImportPreview = CharacterPackageImportPreview(
                bundle: bundle,
                importPlan: importPlan,
                importErrorMessage: importErrorMessage
            )
        } catch {
            packageImportErrorMessage = error.localizedDescription
        }
    }

    private func performPackageImport(_ preview: CharacterPackageImportPreview) {
        guard let plan = preview.importPlan else { return }

        do {
            try CharacterPackageImportService().execute(plan)
            if let character = store.selectedCharacter {
                store.setActivePackage(plan.manifest.id, for: character.owpSlug)
            }
            if let character = store.selectedCharacter {
                store.statusMessage = "Imported character package for \(character.name): \(preview.bundle.manifest.displayName)"
            } else {
                store.statusMessage = "Imported character package: \(preview.bundle.manifest.displayName)"
            }
            packageImportPreview = nil
        } catch {
            packageImportErrorMessage = error.localizedDescription
        }
    }

    private func installedPackages(for character: AnimationCharacter) -> [InstalledCharacterPackage] {
        guard let animateURL = store.animateURL else { return [] }
        return CharacterPackageLibrary().installedPackages(
            for: character.owpSlug,
            in: animateURL,
            preferredActivePackageID: store.activePackageID(for: character.owpSlug)
        )
    }

    private func primaryAssetURL(for package: InstalledCharacterPackage) -> URL? {
        CharacterPackageLibrary().primaryAssetURL(for: package)
    }

    private func activePackageID(for character: AnimationCharacter) -> UUID? {
        let packages = installedPackages(for: character)

        if let explicitID = store.activePackageID(for: character.owpSlug),
           packages.contains(where: { $0.id == explicitID }) {
            return explicitID
        }

        return packages.first?.id
    }

    private func setActivePackage(_ packageID: UUID, for character: AnimationCharacter) {
        store.setActivePackage(packageID, for: character.owpSlug)
        if let package = installedPackages(for: character).first(where: { $0.id == packageID }) {
            store.statusMessage = "Active package for \(character.name): \(package.manifest.displayName)"
        } else {
            store.statusMessage = "Active package updated for \(character.name)"
        }
    }
}

// MARK: - Image Gallery Section

@available(macOS 26.0, *)
struct ImageGallerySection: View {
    let title: String
    let icon: String
    let paths: [String]
    @Binding var thumbnailBaseSize: CGFloat
    let onImport: () -> Void
    let onRemove: (Int) -> Void
    let onPreview: (Int, [String]) -> Void

    private let minThumbnailSize: CGFloat = 80
    private let maxThumbnailSize: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            if paths.isEmpty {
                emptyStateView
            } else {
                galleryGrid
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(paths.count) images")
                .font(.caption)
                .foregroundStyle(.tertiary)

            zoomControls

            Button(action: onImport) {
                Label("Import", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                thumbnailBaseSize = max(minThumbnailSize, thumbnailBaseSize - 20)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(thumbnailBaseSize <= minThumbnailSize)

            Slider(value: $thumbnailBaseSize, in: minThumbnailSize...maxThumbnailSize, step: 20)
                .frame(width: 80)

            Button {
                thumbnailBaseSize = min(maxThumbnailSize, thumbnailBaseSize + 20)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(thumbnailBaseSize >= maxThumbnailSize)
        }
    }

    private var emptyStateView: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
            Text("No images yet. Click Import to add images.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private var galleryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: thumbnailBaseSize, maximum: thumbnailBaseSize), spacing: 12)],
            spacing: 12
        ) {
            ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                ImageGalleryThumbnail(
                    path: path,
                    tileWidth: thumbnailBaseSize,
                    onRemove: { onRemove(index) },
                    onPreview: { onPreview(index, paths) }
                )
            }
        }
    }
}

// MARK: - Image Gallery Thumbnail

@available(macOS 26.0, *)
struct ImageGalleryThumbnail: View {
    let path: String
    let tileWidth: CGFloat
    let onRemove: () -> Void
    let onPreview: () -> Void

    private var imageBoxHeight: CGFloat {
        max(88, tileWidth * 0.68)
    }

    var body: some View {
        let url = URL(fileURLWithPath: path)

        VStack(spacing: 4) {
            thumbnailImage
                .contextMenu {
                    Button("Remove Image", systemImage: "trash", role: .destructive) {
                        onRemove()
                    }
                }

            Text(url.lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onTapGesture(count: 2) {
            onPreview()
        }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.22))
                .frame(width: tileWidth, height: imageBoxHeight)

            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: tileWidth, height: imageBoxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
                    .frame(width: tileWidth, height: imageBoxHeight)
            }
        }
        .frame(width: tileWidth, height: imageBoxHeight)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Image Preview Overlay

@available(macOS 26.0, *)
struct ImagePreviewOverlay: View {
    let paths: [String]
    @Binding var currentIndex: Int
    let onDismiss: () -> Void

    @State private var previewImage: NSImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(spacing: 0) {
                headerBar

                Spacer()

                imageDisplay

                Spacer()

                navigationBar
            }
        }
        .keyboardShortcut(.escape, modifiers: [])
        .onAppear {
            loadCurrentImage()
        }
        .onChange(of: currentIndex) { _, _ in
            loadCurrentImage()
        }
        .focusable()
        .onKeyPress(.leftArrow) {
            navigatePrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigateNext()
            return .handled
        }
    }

    private var headerBar: some View {
        HStack {
            Text("\(currentIndex + 1) of \(paths.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let path = paths[safe: currentIndex] {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary, .primary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var imageDisplay: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(1.5)
        } else if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Failed to load image")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 24) {
            Button {
                navigatePrevious()
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(currentIndex > 0 ? .white : .gray, .primary)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex <= 0)

            Spacer()

            Button {
                navigateNext()
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(currentIndex < paths.count - 1 ? .white : .gray, .primary)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex >= paths.count - 1)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func navigatePrevious() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    private func navigateNext() {
        guard currentIndex < paths.count - 1 else { return }
        currentIndex += 1
    }

    private func loadCurrentImage() {
        guard let path = paths[safe: currentIndex] else { return }
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let image = NSImage(contentsOfFile: path)
            DispatchQueue.main.async {
                self.previewImage = image
                self.isLoading = false
            }
        }
    }
}

// MARK: - Image Cropper View

@available(macOS 26.0, *)
struct ImageCropperView: View {
    let imagePath: String
    let onCrop: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var cropRect: CGRect = .zero
    @State private var hasInitializedCrop = false
    @State private var dragStartOrigin: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            imageCanvas
            controlBar
        }
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerBar: some View {
        HStack {
            Text("Crop Profile Image")
                .font(.headline)
            Spacer()
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var imageCanvas: some View {
        GeometryReader { geo in
            ZStack {
                if let image = NSImage(contentsOfFile: imagePath) {
                    imageCropView(image: image, geo: geo)
                        .onAppear {
                            initializeCropIfNeeded(for: image)
                        }
                } else {
                    Text("Failed to load image")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.1))
    }

    @ViewBuilder
    private func imageCropView(image: NSImage, geo: GeometryProxy) -> some View {
        let imageAspectRatio = image.size.width / image.size.height
        let displaySize = calculateDisplaySize(aspectRatio: imageAspectRatio, containerSize: geo.size)
        let offset = CGPoint(
            x: (geo.size.width - displaySize.width) / 2,
            y: (geo.size.height - displaySize.height) / 2
        )
        let displayCropRect = CGRect(
            x: offset.x + displaySize.width * cropRect.minX,
            y: offset.y + displaySize.height * cropRect.minY,
            width: displaySize.width * cropRect.width,
            height: displaySize.height * cropRect.height
        )

        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: displaySize.width, height: displaySize.height)

            Rectangle()
                .strokeBorder(Color.blue, lineWidth: 2)
                .frame(width: displayCropRect.width, height: displayCropRect.height)
                .contentShape(Rectangle())
                .position(x: displayCropRect.midX, y: displayCropRect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let startOrigin = dragStartOrigin ?? cropRect.origin
                            if dragStartOrigin == nil {
                                dragStartOrigin = cropRect.origin
                            }
                            let newX = max(0, min(1 - cropRect.width, startOrigin.x + value.translation.width / displaySize.width))
                            let newY = max(0, min(1 - cropRect.height, startOrigin.y + value.translation.height / displaySize.height))
                            cropRect.origin = CGPoint(x: newX, y: newY)
                        }
                        .onEnded { _ in
                            dragStartOrigin = nil
                        }
                )
        }
        .frame(width: geo.size.width, height: geo.size.height)
    }

    private func calculateDisplaySize(aspectRatio: CGFloat, containerSize: CGSize) -> CGSize {
        let maxWidth = containerSize.width * 0.9
        let maxHeight = containerSize.height * 0.9

        if aspectRatio > 1 {
            let width = min(maxWidth, maxHeight * aspectRatio)
            return CGSize(width: width, height: width / aspectRatio)
        } else {
            let height = min(maxHeight, maxWidth / aspectRatio)
            return CGSize(width: height * aspectRatio, height: height)
        }
    }

    private var controlBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Drag the square to position the crop area")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 16) {
                Button("1:1 Square") {
                    if let image = NSImage(contentsOfFile: imagePath) {
                        makeSquareCrop(for: image)
                    }
                }
                .buttonStyle(.bordered)

                Button("Crop & Save") {
                    onCrop(cropRect)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func initializeCropIfNeeded(for image: NSImage) {
        guard !hasInitializedCrop else { return }
        hasInitializedCrop = true
        let aspectRatio = image.size.width / image.size.height
        let squarePixelFraction: CGFloat = 0.7
        let width = squarePixelFraction * min(1, 1 / aspectRatio)
        let height = squarePixelFraction * min(1, aspectRatio)
        cropRect = CGRect(
            x: (1 - width) / 2,
            y: (1 - height) / 2,
            width: width,
            height: height
        )
    }

    private func makeSquareCrop(for image: NSImage) {
        let imageAspectRatio = image.size.width / image.size.height

        let centerX = cropRect.midX
        let centerY = cropRect.midY
        let maxWidth = 2 * min(centerX, 1 - centerX)
        let maxHeight = 2 * min(centerY, 1 - centerY)
        let squareWidth = min(maxWidth, maxHeight / imageAspectRatio)
        let squareHeight = squareWidth * imageAspectRatio

        cropRect = CGRect(
            x: centerX - squareWidth / 2,
            y: centerY - squareHeight / 2,
            width: squareWidth,
            height: squareHeight
        )
    }
}

// MARK: - Inspiration Gallery Sheet

@available(macOS 26.0, *)
struct InspirationGallerySheet: View {
    let character: AnimationCharacter
    let store: AnimateStore
    let onDismiss: () -> Void

    @State private var thumbnailBaseSize: CGFloat = 150
    @State private var previewImageIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if character.inspirationImagePaths.isEmpty {
                        emptyState
                    } else {
                        galleryGrid
                    }
                }
                .padding()
            }
        }
        .frame(width: 700, height: 600)
        .overlay {
            if let index = previewImageIndex {
                ImagePreviewOverlay(
                    paths: character.inspirationImagePaths,
                    currentIndex: Binding(
                        get: { index },
                        set: { previewImageIndex = $0 }
                    ),
                    onDismiss: { previewImageIndex = nil }
                )
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Label("Inspiration Images", systemImage: "photo.stack")
                .font(.headline)

            Text("for \(character.name)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No inspiration images yet")
                .font(.headline)
            Text("Import images to build your character's inspiration gallery.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Import Images") {
                store.importInspirationImages(for: character.id)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var galleryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailBaseSize, maximum: thumbnailBaseSize), spacing: 12)], spacing: 12) {
            ForEach(Array(character.inspirationImagePaths.enumerated()), id: \.offset) { index, path in
                galleryThumbnail(path: path, index: index)
            }
        }
    }

    @ViewBuilder
    private func galleryThumbnail(path: String, index: Int) -> some View {
        VStack(spacing: 4) {
            thumbnailImage(for: path)
                .contextMenu {
                    Button("Remove Image", systemImage: "trash", role: .destructive) {
                        store.removeInspirationImage(at: index, for: character.id)
                    }
                }
                .onTapGesture(count: 2) {
                    previewImageIndex = index
                }

            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func thumbnailImage(for path: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.22))
                .frame(width: thumbnailBaseSize, height: max(96, thumbnailBaseSize * 0.68))

            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: thumbnailBaseSize, height: max(96, thumbnailBaseSize * 0.68))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: thumbnailBaseSize, height: max(96, thumbnailBaseSize * 0.68))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: thumbnailBaseSize, height: max(96, thumbnailBaseSize * 0.68))
    }
}

// MARK: - Reference Images Sheet

struct ReferenceImagesSheet: View {
    let character: AnimationCharacter
    let store: AnimateStore
    let onDismiss: () -> Void

    @State private var thumbnailBaseSize: CGFloat = 120
    @State private var previewImageIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    mainReferenceImageSection
                    Divider()
                    referenceImageGallerySection
                }
                .padding()
            }
        }
        .frame(width: 600, height: 650)
        .overlay {
            if let index = previewImageIndex {
                ImagePreviewOverlay(
                    paths: character.referenceImagePaths,
                    currentIndex: Binding(
                        get: { index },
                        set: { previewImageIndex = $0 }
                    ),
                    onDismiss: { previewImageIndex = nil }
                )
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Label("Reference Images", systemImage: "photo.on.rectangle")
                .font(.headline)

            Text("for \(character.name)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var mainReferenceImageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Main Reference Image")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            if let refPath = character.inspirationReferenceImagePath,
               let image = NSImage(contentsOfFile: refPath) {
                VStack(spacing: 12) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.quaternary, lineWidth: 1)
                        )

                    HStack {
                        Text(URL(fileURLWithPath: refPath).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Replace") {
                            store.setInspirationReferenceImageFromPicker(for: character.id)
                        }
                        .buttonStyle(.bordered)

                        Button("Remove", role: .destructive) {
                            store.setInspirationReferenceImage(nil, for: character.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary.opacity(0.3))
                        .frame(height: 160)
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.tertiary)
                                Text("No main reference image set")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                    Button("Choose Reference Image") {
                        store.setInspirationReferenceImageFromPicker(for: character.id)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("Shown in the character header. Use for the primary visual reference.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var referenceImageGallerySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reference Image Gallery")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(character.referenceImagePaths.count) images")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                zoomControls

                Button(action: {
                    store.importReferenceImages(for: character.id)
                }) {
                    Label("Import", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if character.referenceImagePaths.isEmpty {
                emptyGalleryState
            } else {
                galleryGrid
            }

            Text("Additional reference images for personal use and Gemini prompts.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                thumbnailBaseSize = max(80, thumbnailBaseSize - 20)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(thumbnailBaseSize <= 80)

            Slider(value: $thumbnailBaseSize, in: 80...200, step: 20)
                .frame(width: 60)

            Button {
                thumbnailBaseSize = min(200, thumbnailBaseSize + 20)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(thumbnailBaseSize >= 200)
        }
    }

    private var emptyGalleryState: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .foregroundStyle(.tertiary)
            Text("No reference images yet. Click Import to add images.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var galleryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: thumbnailBaseSize, maximum: thumbnailBaseSize), spacing: 12)],
            spacing: 12
        ) {
            ForEach(Array(character.referenceImagePaths.enumerated()), id: \.offset) { index, path in
                referenceGalleryThumbnail(path: path, index: index)
            }
        }
    }

    @ViewBuilder
    private func referenceGalleryThumbnail(path: String, index: Int) -> some View {
        VStack(spacing: 4) {
            thumbnailImage(for: path)
                .contextMenu {
                    Button("Remove Image", systemImage: "trash", role: .destructive) {
                        store.removeReferenceImage(at: index, for: character.id)
                    }
                }
                .onTapGesture(count: 2) {
                    previewImageIndex = index
                }

            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func thumbnailImage(for path: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.22))
                .frame(width: thumbnailBaseSize, height: max(88, thumbnailBaseSize * 0.68))

            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: thumbnailBaseSize, height: max(88, thumbnailBaseSize * 0.68))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: thumbnailBaseSize, height: max(88, thumbnailBaseSize * 0.68))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: thumbnailBaseSize, height: max(88, thumbnailBaseSize * 0.68))
    }
}

// MARK: - Array Safe Subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
