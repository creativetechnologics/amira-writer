import AppKit
import SwiftUI

/// Visual editor for character rig part hierarchy.
///
/// Displays the character's body part tree with pivot points and image assignments.
/// Users can add/remove parts, set pivot points, assign drawing sets, and
/// reorder the hierarchy via drag-and-drop.
@available(macOS 26.0, *)
struct CharacterRigEditor: View {
    @Bindable var store: AnimateStore
    var characterID: UUID

    @State private var selectedPartID: UUID?
    @State private var isAddingPart = false
    @State private var newPartName = ""
    @State private var newPartType: PartType = .accessory
    @State private var selectedAngle: AngleView = .front
    @State private var selectedPackageID: UUID?
    @State private var lastSyncReport: CharacterPackageRigSyncReport?

    private var character: AnimationCharacter? {
        store.characters.first { $0.id == characterID }
    }

    var body: some View {
        HSplitView {
            // Left: Part hierarchy tree
            partHierarchy
                .frame(minWidth: 200, idealWidth: 240)

            // Right: Part detail / image preview
            partDetail
                .frame(minWidth: 300)
        }
        .alert("Add Body Part", isPresented: $isAddingPart) {
            TextField("Part name", text: $newPartName)
            Picker("Type", selection: $newPartType) {
                ForEach(PartType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            Button("Add") {
                if !newPartName.isEmpty {
                    store.addRigPart(
                        to: characterID,
                        name: newPartName,
                        type: newPartType,
                        parentID: selectedPartID
                    )
                    newPartName = ""
                }
            }
            Button("Cancel", role: .cancel) { newPartName = "" }
        }
    }

    // MARK: - Part Hierarchy

    @ViewBuilder
    private var partHierarchy: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Rig Parts", systemImage: "figure.arms.open")
                    .font(.headline)
                Spacer()
                Button(action: { isAddingPart = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add body part")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Tree
            if let character {
                if character.parts.isEmpty {
                    emptyPartsView
                } else {
                    List(selection: $selectedPartID) {
                        partTree(for: character)
                    }
                    .listStyle(.sidebar)
                }
            } else {
                Text("No character selected")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func partTree(for character: AnimationCharacter) -> some View {
        let rootParts = character.parts.filter { $0.parentID == nil }
        ForEach(rootParts) { part in
            partRow(part, character: character, depth: 0)
        }
    }

    private func partRow(_ part: RigPart, character: AnimationCharacter, depth: Int) -> AnyView {
        let children = character.parts.filter { $0.parentID == part.id }

        let label = Label {
            Text(part.name)
                .lineLimit(1)
        } icon: {
            Image(systemName: iconForPartType(part.partType))
                .foregroundStyle(colorForPartType(part.partType))
        }
        .tag(part.id)
        .contextMenu { partContextMenu(part) }

        if children.isEmpty {
            return AnyView(label)
        } else {
            return AnyView(
                DisclosureGroup {
                    ForEach(children) { child in
                        partRow(child, character: character, depth: depth + 1)
                    }
                } label: {
                    label
                }
            )
        }
    }

    @ViewBuilder
    private func partContextMenu(_ part: RigPart) -> some View {
        Button("Add Child Part") {
            selectedPartID = part.id
            isAddingPart = true
        }
        Divider()
        Button("Delete Part", role: .destructive) {
            store.deleteRigPart(from: characterID, partID: part.id)
            if selectedPartID == part.id {
                selectedPartID = nil
            }
        }
    }

    @ViewBuilder
    private var emptyPartsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.arms.open")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("No rig parts defined")
                .foregroundStyle(.secondary)

            Button("Create Default Rig") {
                store.createDefaultRig(for: characterID)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Part Detail

    @ViewBuilder
    private var partDetail: some View {
        if let character,
           let partID = selectedPartID,
           let partIndex = character.parts.firstIndex(where: { $0.id == partID }) {
            let part = character.parts[partIndex]
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    partProperties(part)
                    Divider()
                    pivotEditor(part)
                    Divider()
                    packageSyncSection(character, part: part)
                    Divider()
                    drawingSetSection(part)
                }
                .padding()
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a part to edit properties")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func partProperties(_ part: RigPart) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Part Properties", systemImage: "gearshape")
                .font(.headline)

            LabeledContent("Name") {
                Text(part.name)
            }

            LabeledContent("Type") {
                Text(part.partType.rawValue)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Z-Order") {
                Text("\(part.zOrder)")
                    .monospacedDigit()
            }

            if let parentID = part.parentID,
               let parent = character?.parts.first(where: { $0.id == parentID }) {
                LabeledContent("Parent") {
                    Text(parent.name)
                        .foregroundStyle(.secondary)
                }
            }

            let children = character?.parts.filter { $0.parentID == part.id } ?? []
            if !children.isEmpty {
                LabeledContent("Children") {
                    Text("\(children.count)")
                }
            }
        }
    }

    @ViewBuilder
    private func pivotEditor(_ part: RigPart) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pivot Point", systemImage: "scope")
                .font(.headline)

            HStack(spacing: 16) {
                LabeledContent("X") {
                    Text(String(format: "%.1f", part.pivotPoint.x))
                        .monospacedDigit()
                }

                LabeledContent("Y") {
                    Text(String(format: "%.1f", part.pivotPoint.y))
                        .monospacedDigit()
                }
            }

            Text("Pivot points define rotation joints. Edit in the canvas by holding Option and clicking on the part.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func packageSyncSection(_ character: AnimationCharacter, part: RigPart) -> some View {
        let packages = installedPackages(for: character)
        let selectedPackage = selectedPackage(from: packages)
        let activePackage = activePackage(from: packages, character: character)
        let hasSelectedAnglePackageVariant = selectedPackage.map {
            hasSyncedVariant(for: part, angle: selectedAngle, from: $0)
        } ?? false

        VStack(alignment: .leading, spacing: 12) {
            Label("Package Sync", systemImage: "shippingbox")
                .font(.headline)

            if packages.isEmpty {
                Text("No imported packages found for this character yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                Picker("Package", selection: packageSelectionBinding(packages: packages)) {
                    ForEach(packages) { package in
                        Text(package.manifest.displayName)
                            .tag(Optional(package.id))
                    }
                }
                .pickerStyle(.menu)

                if let selectedPackage {
                    let syncService = CharacterPackageRigSyncService()
                    let coverage = syncService.coverage(for: character, package: selectedPackage)
                    let matchingAssets = syncService.partAssets(for: part.partType, in: selectedPackage)
                    let syncedVariants = syncedPackageVariants(
                        for: part,
                        angle: selectedAngle,
                        package: selectedPackage
                    )

                    HStack(spacing: 16) {
                        LabeledContent("Package Parts") {
                            Text("\(coverage.totalPartAssets)")
                        }
                        LabeledContent("Matched Rig Parts") {
                            Text("\(coverage.matchedRigParts)")
                        }
                        LabeledContent("This Part") {
                            Text("\(matchingAssets.count)")
                        }
                    }
                    .font(.caption)

                    HStack(spacing: 8) {
                        syncStatusBadge(
                            title: character.resolvedRenderMode.displayName,
                            color: character.resolvedRenderMode == .rigDrawingSets ? .green : .secondary,
                            systemImage: character.resolvedRenderMode == .rigDrawingSets ? "square.stack.3d.up.fill" : "shippingbox"
                        )

                        syncStatusBadge(
                            title: selectedPackage.id == activePackage?.id ? "Active on Canvas" : "Preview Only",
                            color: selectedPackage.id == activePackage?.id ? .blue : .secondary,
                            systemImage: selectedPackage.id == activePackage?.id ? "play.circle.fill" : "shippingbox"
                        )

                        syncStatusBadge(
                            title: hasSelectedAnglePackageVariant ? "Selected Angle Synced" : "Selected Angle Missing",
                            color: hasSelectedAnglePackageVariant ? .green : .orange,
                            systemImage: hasSelectedAnglePackageVariant ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                    }

                    if matchingAssets.isEmpty {
                        Text("The selected package does not currently expose any \(part.partType.rawValue) assets.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Best package assets for this part:")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        ForEach(Array(matchingAssets.prefix(3))) { asset in
                            HStack {
                                Text(asset.name)
                                    .font(.caption)
                                Spacer()
                                Text(asset.angle?.rawValue ?? "default")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if !syncedVariants.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Synced source metadata:")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            ForEach(Array(syncedVariants.prefix(3))) { variant in
                                VStack(alignment: .leading, spacing: 2) {
                                    if let sourcePath = sourcePathLabel(for: variant) {
                                        Text(sourcePath)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }

                                    if let placementSummary = placementSummary(for: variant) {
                                        Text(placementSummary)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    } else if hasSelectedAnglePackageVariant {
                        Text("This angle is already synced. Run sync again to attach source path and placement metadata to older variants.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if !coverage.missingRigPartTypes.isEmpty {
                        Text("Missing rig matches: \(coverage.missingRigPartTypes.map(\.rawValue).joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }

                    if let activePackage, activePackage.id != selectedPackage.id {
                        Text("Active canvas package: \(activePackage.manifest.displayName)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Button(selectedPackage?.id == activePackage?.id ? "Sync Active Package to Rig" : "Sync Selected Package to Rig") {
                    lastSyncReport = store.syncCharacterPackageToRig(
                        for: characterID,
                        packageID: selectedPackageID
                    )
                }
                .buttonStyle(.borderedProminent)

                if let lastSyncReport {
                    Text(syncSummary(for: lastSyncReport))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func drawingSetSection(_ part: RigPart) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Drawing Sets", systemImage: "photo.on.rectangle.angled")
                .font(.headline)

            Picker("Angle View", selection: $selectedAngle) {
                ForEach(AngleView.allCases, id: \.self) { angle in
                    Text(angle.rawValue).tag(angle)
                }
            }
            .pickerStyle(.segmented)

            if let drawingSet = part.drawingSets[selectedAngle] {
                if drawingSet.variants.isEmpty {
                    Text("No drawings for this angle.")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                } else {
                    let activeVariantID = drawingSet.resolvedActiveVariant?.id
                    let packageVariants = drawingSet.variants.filter(isPackageDerivedVariant)
                    let manualVariants = drawingSet.variants.filter { !isPackageDerivedVariant($0) }
                    let placedVariants = drawingSet.variants.filter { $0.placement != nil }

                    HStack(spacing: 8) {
                        drawingStatusBadge(
                            title: "\(drawingSet.variants.count) Total",
                            color: .secondary,
                            systemImage: "square.stack.3d.up"
                        )
                        drawingStatusBadge(
                            title: "\(packageVariants.count) Package",
                            color: packageVariants.isEmpty ? .secondary : .blue,
                            systemImage: "shippingbox"
                        )
                        drawingStatusBadge(
                            title: "\(manualVariants.count) Manual",
                            color: manualVariants.isEmpty ? .secondary : .green,
                            systemImage: "hand.draw"
                        )
                        drawingStatusBadge(
                            title: "\(placedVariants.count) Placed",
                            color: placedVariants.isEmpty ? .secondary : .orange,
                            systemImage: "scope"
                        )

                        if let activeVariant = drawingSet.resolvedActiveVariant {
                            drawingStatusBadge(
                                title: "Active: \(activeVariant.name)",
                                color: .purple,
                                systemImage: "checkmark.circle.fill"
                            )
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                        ForEach(drawingSet.variants) { variant in
                            Button {
                                store.setActiveDrawingVariant(
                                    for: characterID,
                                    partID: part.id,
                                    angle: selectedAngle,
                                    variantID: variant.id
                                )
                            } label: {
                                VStack(spacing: 4) {
                                    variantPreview(variant)
                                        .frame(height: 88)

                                    VStack(spacing: 2) {
                                        Text(variant.name)
                                            .font(.caption2)
                                            .lineLimit(1)

                                        Text(packageSourceLabel(for: variant))
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(isPackageDerivedVariant(variant) ? .blue : .green)

                                        if variant.id == activeVariantID {
                                            Text("Active")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.purple)
                                        }

                                        if let sourcePath = sourcePathLabel(for: variant) {
                                            Text(sourcePath)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }

                                        if let placementSummary = placementSummary(for: variant) {
                                            Text(placementSummary)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isPackageDerivedVariant(variant) ? Color.blue.opacity(0.08) : Color.green.opacity(0.08))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        variant.id == activeVariantID ? Color.purple : Color.clear,
                                        lineWidth: 2
                                    )
                            }
                        }
                    }
                }
            } else {
                Text("No drawing set for \(selectedAngle.rawValue) view.")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            }

            HStack {
                Button("Import Drawing...") {
                    importDrawing(for: part)
                }
                .buttonStyle(.bordered)

                if store.geminiAPIKey.isEmpty {
                    Text("Set Gemini API key to generate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Generate with AI...") {
                        store.showGenerationSheet = true
                        store.generationTargetPartID = part.id
                        store.generationTargetAngle = selectedAngle
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Actions

    private func importDrawing(for part: RigPart) {
        let panel = NSOpenPanel()
        panel.title = "Import Drawing for \(part.name)"
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.importDrawing(
                for: characterID,
                partID: part.id,
                angle: selectedAngle,
                from: url
            )
        }
    }

    // MARK: - Helpers

    private func installedPackages(for character: AnimationCharacter) -> [InstalledCharacterPackage] {
        guard let animateURL = store.animateURL else { return [] }
        return CharacterPackageLibrary().installedPackages(for: character.assetFolderSlug, in: animateURL)
    }

    private func activePackage(
        from packages: [InstalledCharacterPackage],
        character: AnimationCharacter
    ) -> InstalledCharacterPackage? {
        guard let activePackageID = store.activePackageID(for: character.owpSlug) else {
            return packages.first
        }

        return packages.first(where: { $0.id == activePackageID }) ?? packages.first
    }

    private func selectedPackage(from packages: [InstalledCharacterPackage]) -> InstalledCharacterPackage? {
        if let selectedPackageID,
           let match = packages.first(where: { $0.id == selectedPackageID }) {
            return match
        }

        return packages.first
    }

    private func packageSelectionBinding(
        packages: [InstalledCharacterPackage]
    ) -> Binding<UUID?> {
        Binding(
            get: {
                if let selectedPackageID,
                   packages.contains(where: { $0.id == selectedPackageID }) {
                    return selectedPackageID
                }
                return packages.first?.id
            },
            set: { newValue in
                selectedPackageID = newValue
            }
        )
    }

    private func syncSummary(for report: CharacterPackageRigSyncReport) -> String {
        var parts: [String] = []
        if report.createdDefaultRig {
            parts.append("created default rig")
        }
        parts.append("imported \(report.importedVariants)")
        if report.skippedExistingVariants > 0 {
            parts.append("skipped \(report.skippedExistingVariants)")
        }
        if !report.missingRigPartTypes.isEmpty {
            parts.append("\(report.missingRigPartTypes.count) unmatched part types")
        }
        return "\(report.packageDisplayName): " + parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func variantPreview(_ variant: DrawingVariant) -> some View {
        if let image = previewImage(for: variant) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.2))
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func previewImage(for variant: DrawingVariant) -> NSImage? {
        guard let character,
              let drawingURL = drawingURL(for: variant, character: character)
        else {
            return nil
        }

        return NSImage(contentsOf: drawingURL)
    }

    private func drawingURL(
        for variant: DrawingVariant,
        character: AnimationCharacter
    ) -> URL? {
        guard let animateURL = store.animateURL else { return nil }

        let partsDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(character.assetFolderSlug)
            .appendingPathComponent("parts")

        let candidate = partsDirectory.appendingPathComponent(variant.filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }

        return candidate
    }

    private func isPackageDerivedVariant(_ variant: DrawingVariant) -> Bool {
        variant.isPackageDerived || variant.name.contains("•")
    }

    private func hasSyncedVariant(
        for part: RigPart,
        angle: AngleView,
        from package: InstalledCharacterPackage
    ) -> Bool {
        guard let drawingSet = part.drawingSets[angle] else { return false }
        return drawingSet.variants.contains { variant in
            variant.sourcePackageID == package.manifest.id ||
            variant.name.hasPrefix("\(package.manifest.displayName) •")
        }
    }

    private func syncedPackageVariants(
        for part: RigPart,
        angle: AngleView,
        package: InstalledCharacterPackage
    ) -> [DrawingVariant] {
        guard let drawingSet = part.drawingSets[angle] else { return [] }
        return drawingSet.variants.filter { $0.sourcePackageID == package.manifest.id }
    }

    private func packageSourceLabel(for variant: DrawingVariant) -> String {
        if let sourcePackageDisplayName = variant.sourcePackageDisplayName {
            return sourcePackageDisplayName
        }

        return isPackageDerivedVariant(variant) ? "Package" : "Manual"
    }

    private func sourcePathLabel(for variant: DrawingVariant) -> String? {
        if let sourceRelativePath = variant.sourceRelativePath, !sourceRelativePath.isEmpty {
            return sourceRelativePath
        }

        return variant.sourceURL?.lastPathComponent
    }

    private func placementSummary(for variant: DrawingVariant) -> String? {
        guard let placement = variant.placement else { return nil }

        var parts: [String] = [placement.resolvedMode == .fullCanvasAligned ? "Full Canvas" : "Framed"]

        if let zOrderOverride = placement.zOrderOverride {
            parts.append("z \(zOrderOverride)")
        }

        if let pivot = placement.normalizedPivot {
            parts.append(String(format: "pivot %.2f, %.2f", pivot.x, pivot.y))
        }

        return parts.joined(separator: " • ")
    }

    private func syncStatusBadge(title: String, color: Color, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private func drawingStatusBadge(title: String, color: Color, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private func iconForPartType(_ type: PartType) -> String {
        switch type {
        case .root: "circle.circle"
        case .hips, .torso, .chest: "figure"
        case .neck: "arrow.up.and.down"
        case .head: "circle.fill"
        case .face: "face.smiling"
        case .eyeLeft, .eyeRight: "eye"
        case .eyebrowLeft, .eyebrowRight: "eyebrow"
        case .mouth: "mouth"
        case .nose: "nose"
        case .hairFront, .hairBack: "wind"
        case .shoulderLeft, .shoulderRight: "arrow.left.and.right"
        case .upperArmLeft, .upperArmRight: "arm.right"
        case .lowerArmLeft, .lowerArmRight: "arm.right"
        case .handLeft, .handRight: "hand.raised"
        case .upperLegLeft, .upperLegRight: "figure.walk"
        case .lowerLegLeft, .lowerLegRight: "figure.walk"
        case .footLeft, .footRight: "shoe"
        case .accessory: "sparkles"
        }
    }

    private func colorForPartType(_ type: PartType) -> Color {
        switch type {
        case .root: .white
        case .hips, .torso, .chest: .blue
        case .neck, .head, .face: .orange
        case .eyeLeft, .eyeRight, .eyebrowLeft, .eyebrowRight: .cyan
        case .mouth, .nose: .pink
        case .hairFront, .hairBack: .purple
        case .shoulderLeft, .shoulderRight, .upperArmLeft, .upperArmRight,
             .lowerArmLeft, .lowerArmRight, .handLeft, .handRight: .green
        case .upperLegLeft, .upperLegRight, .lowerLegLeft, .lowerLegRight,
             .footLeft, .footRight: .yellow
        case .accessory: .mint
        }
    }
}
