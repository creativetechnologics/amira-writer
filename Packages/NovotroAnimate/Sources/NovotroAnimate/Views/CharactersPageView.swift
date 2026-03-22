import SwiftUI
import NovotroProjectKit

@available(macOS 26.0, *)
struct CharactersPageView: View {
    @Bindable var store: AnimateStore
    @State private var packageImportPreview: CharacterPackageImportPreview?
    @State private var packageImportErrorMessage: String?

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                characterList
                    .frame(width: min(geo.size.width * 0.3, 280))

                Divider()

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
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(OperaChromeTheme.panelBackground)
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
        if let owpChar,
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

                    // OWP Gallery Images
                    owpImageGallery(character)

                    Divider()

                    characterPackagesSection(character)

                    Divider()

                    canvasRenderSection(character)

                    Divider()

                    // Rig info
                    if !character.parts.isEmpty {
                        angleCoverageSection(character)
                        Divider()
                    }

                    // Actions
                    actionsSection(character)
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

    @ViewBuilder
    private func characterHeader(_ character: AnimationCharacter) -> some View {
        let owpChar = store.owpCharacter(for: character)
        HStack(spacing: 12) {
            // Large thumbnail from OWP
            if let owpChar,
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
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        }
                }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
            }

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
                HStack(spacing: 12) {
                    LabeledContent("Parts") {
                        Text("\(character.parts.count)")
                    }
                    .font(.caption)
                    LabeledContent("Packages") {
                        Text("\(installedPackages(for: character).count)")
                    }
                    .font(.caption)
                    if let owpChar {
                        LabeledContent("Project Images") {
                            Text("\(owpChar.images.count)")
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - OWP Image Gallery

    @ViewBuilder
    private func owpImageGallery(_ character: AnimationCharacter) -> some View {
        let owpChar = store.owpCharacter(for: character)

        VStack(alignment: .leading, spacing: 8) {
            Label("Project Character Images", systemImage: "photo.on.rectangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let owpChar, let imageDir = store.owpCharacterImageDirectory(for: owpChar), !owpChar.images.isEmpty {
                // Group by category
                let categories = Dictionary(grouping: owpChar.images, by: \.category)
                ForEach(Array(categories.keys.sorted()), id: \.self) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.capitalized)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                            ForEach(categories[category] ?? []) { image in
                                let url = imageDir.appendingPathComponent(image.filename)
                                VStack(spacing: 4) {
                                    AsyncImage(url: url) { loaded in
                                        loaded
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxHeight: 100)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(.quaternary)
                                            .frame(height: 100)
                                            .overlay {
                                                Image(systemName: "photo")
                                                    .foregroundStyle(.tertiary)
                                            }
                                    }
                                    Text(image.filename)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("No project images for this character yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Character Packages

    @ViewBuilder
    private func characterPackagesSection(_ character: AnimationCharacter) -> some View {
        let packages = installedPackages(for: character)
        let activePackageID = activePackageID(for: character)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Character Packages", systemImage: "shippingbox")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Import Package...") {
                    openCharacterPackagePicker()
                }
                .buttonStyle(.bordered)
                .disabled(store.animateURL == nil)
            }

            if packages.isEmpty {
                Text("No imported packages yet. Import a package for this character to test the Novotro package pipeline.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                Text(character.resolvedRenderMode == .packagePreview
                     ? "Choose which imported package should drive canvas rendering for this character. If you do not choose one, Novotro falls back to the newest valid package."
                     : "Choose which imported package should stay active for preview/reference purposes. Rig Drawing Sets mode renders synced rig art on the canvas instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(packages) { package in
                        CharacterPackageCardView(
                            package: package,
                            previewURL: primaryAssetURL(for: package),
                            isActive: package.id == activePackageID,
                            onSetActive: {
                                setActivePackage(package.id, for: character)
                            }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func canvasRenderSection(_ character: AnimationCharacter) -> some View {
        let rigVariantCount = rigVariantCount(for: character)

        VStack(alignment: .leading, spacing: 8) {
            Label("Canvas Render", systemImage: "play.rectangle.on.rectangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Render Mode", selection: renderModeBinding(for: character)) {
                ForEach(CharacterCanvasRenderMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Preferred Angle", selection: preferredAngleBinding(for: character)) {
                Text("Automatic").tag(nil as AngleView?)
                ForEach(AngleView.allCases, id: \.self) { angle in
                    Text(angle.rawValue).tag(Optional(angle))
                }
            }

            if character.resolvedRenderMode == .packagePreview {
                Text("Canvas uses the selected active package preview for this character.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if rigVariantCount > 0 {
                Text("Canvas uses synced rig drawing variants for this character. \(rigVariantCount) rig variants are currently available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Rig Drawing Sets is selected, but this character does not have synced rig drawings yet.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Angle Coverage

    @ViewBuilder
    private func angleCoverageSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rig Angle Coverage", systemImage: "rotate.3d")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let coverage = angleCoverage(for: character)
            ForEach(AngleView.allCases, id: \.self) { angle in
                HStack {
                    Text(angle.rawValue)
                        .font(.caption)
                    Spacer()
                    let count = coverage[angle] ?? 0
                    Text("\(count) drawings")
                        .font(.caption)
                        .foregroundStyle(count > 0 ? Color.green : Color.gray)
                }
            }
        }
    }

    private func renderModeBinding(
        for character: AnimationCharacter
    ) -> Binding<CharacterCanvasRenderMode> {
        Binding(
            get: { character.resolvedRenderMode },
            set: { newValue in
                store.setCharacterRenderMode(newValue, for: character.id)
            }
        )
    }

    private func preferredAngleBinding(
        for character: AnimationCharacter
    ) -> Binding<AngleView?> {
        Binding(
            get: { character.preferredViewAngle },
            set: { newValue in
                store.setCharacterPreferredViewAngle(newValue, for: character.id)
            }
        )
    }

    private func rigVariantCount(for character: AnimationCharacter) -> Int {
        character.parts.reduce(into: 0) { total, part in
            for drawingSet in part.drawingSets.values {
                total += drawingSet.variants.count
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionsSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Actions", systemImage: "figure.arms.open")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Edit Rig") {
                    store.showRigEditor = true
                }
                .buttonStyle(.bordered)

                Button("Save Rig") {
                    store.saveCharacterRig(character.id)
                }
                .buttonStyle(.bordered)
            }

            Button("Import Character Package...") {
                openCharacterPackagePicker()
            }
            .buttonStyle(.bordered)
            .disabled(store.animateURL == nil || store.selectedCharacter == nil)

            if character.parts.isEmpty {
                Button("Create Default Rig") {
                    store.createDefaultRig(for: character.id)
                }
                .buttonStyle(.bordered)
            }

            if !store.geminiAPIKey.isEmpty {
                Button("Generate Assets...") {
                    store.showGenerationSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
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

    private func angleCoverage(for character: AnimationCharacter) -> [AngleView: Int] {
        var result: [AngleView: Int] = [:]
        for angle in AngleView.allCases {
            var count = 0
            for part in character.parts {
                if let set = part.drawingSets[angle] {
                    count += set.variants.count
                }
            }
            result[angle] = count
        }
        return result
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
