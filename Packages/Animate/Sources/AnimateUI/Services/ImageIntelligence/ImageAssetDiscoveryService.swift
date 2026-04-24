import Foundation
import ProjectKit

/// Discovers all image assets from the various app sources.
/// Mirrors the logic in AllProjectImagesWorkspace but produces structured
/// discovery results for the image intelligence system.
@available(macOS 26.0, *)
@MainActor
public final class ImageAssetDiscoveryService {

    public struct DiscoveredAsset: Sendable {
        public let resolvedPath: String
        public let projectRelativePath: String?
        public let linkKind: ImageAssetLinkKind
        public let ownerID: String?
        public let ownerParentID: String?
        public let moment: String?
        public let workflow: String?
        public let context: [String: String]

        public init(
            resolvedPath: String,
            projectRelativePath: String? = nil,
            linkKind: ImageAssetLinkKind,
            ownerID: String? = nil,
            ownerParentID: String? = nil,
            moment: String? = nil,
            workflow: String? = nil,
            context: [String: String] = [:]
        ) {
            self.resolvedPath = resolvedPath
            self.projectRelativePath = projectRelativePath
            self.linkKind = linkKind
            self.ownerID = ownerID
            self.ownerParentID = ownerParentID
            self.moment = moment
            self.workflow = workflow
            self.context = context
        }
    }

    public struct DiscoveryResult: Sendable {
        public let assets: [DiscoveredAsset]
        public let totalCount: Int
        public let byKind: [ImageAssetLinkKind: Int]

        public init(assets: [DiscoveredAsset]) {
            self.assets = assets
            self.totalCount = assets.count
            self.byKind = assets.reduce(into: [:]) { counts, asset in
                counts[asset.linkKind, default: 0] += 1
            }
        }
    }

    private let store: AnimateStore

    internal init(store: AnimateStore) {
        self.store = store
    }

    /// Discover all image assets in the current project.
    public func discoverAll() -> DiscoveryResult {
        var assets: [DiscoveredAsset] = []

        discoverPlaces(into: &assets)
        discoverPlacesWorkflowLibrary(into: &assets)
        discoverCanvasGenerations(into: &assets)
        discoverCharacters(into: &assets)
        discoverSceneShots(into: &assets)

        // Preserve multiple links to the same asset when they point at different owners/contexts.
        let deduplicated = Dictionary(grouping: assets) {
            [
                $0.resolvedPath,
                $0.linkKind.rawValue,
                $0.ownerID ?? "",
                $0.ownerParentID ?? "",
                $0.moment ?? "",
                $0.workflow ?? ""
            ].joined(separator: "|")
        }
            .compactMap { $0.value.first }

        return DiscoveryResult(assets: deduplicated)
    }

    // MARK: - Places

    private func discoverPlaces(into assets: inout [DiscoveredAsset]) {
        for place in store.backgrounds {
            for path in place.imagePaths {
                if let resolved = resolvePath(path) {
                    assets.append(DiscoveredAsset(
                        resolvedPath: resolved,
                        projectRelativePath: relativePath(resolved),
                        linkKind: .placeReference,
                        ownerID: place.id.uuidString,
                        workflow: "photorealistic"
                    ))
                }
            }

            for path in place.animatedImagePaths {
                if let resolved = resolvePath(path) {
                    assets.append(DiscoveredAsset(
                        resolvedPath: resolved,
                        projectRelativePath: relativePath(resolved),
                        linkKind: .placeReference,
                        ownerID: place.id.uuidString,
                        workflow: "animated"
                    ))
                }
            }

            for refImage in place.referenceImages {
                if let resolved = resolvePath(refImage.imagePath) {
                    assets.append(DiscoveredAsset(
                        resolvedPath: resolved,
                        projectRelativePath: relativePath(resolved),
                        linkKind: .placeReference,
                        ownerID: place.id.uuidString,
                        context: ["isReference": "true"]
                    ))
                }
            }
        }
    }

    // MARK: - Places Workflow Library

    private func discoverPlacesWorkflowLibrary(into assets: inout [DiscoveredAsset]) {
        for record in store.placesWorkflowLibrary.generatedImageRecords {
            let path = record.activePath
            guard !path.isEmpty else { continue }

            let isMap3D = record.keywords.contains("map3d-capture")
            let kind: ImageAssetLinkKind = isMap3D ? .map3DCapture : .placeGenerated

            if let resolved = resolvePath(path) {
                var context: [String: String] = [
                    "recordID": record.id.uuidString,
                    "keywords": record.keywords.joined(separator: ", "),
                    "summary": record.summary
                ]
                if let placeID = record.linkedPlaceID {
                    context["linkedPlaceID"] = placeID.uuidString
                }

                assets.append(DiscoveredAsset(
                    resolvedPath: resolved,
                    projectRelativePath: relativePath(resolved),
                    linkKind: kind,
                    ownerID: record.id.uuidString,
                    ownerParentID: record.linkedPlaceID?.uuidString,
                    workflow: record.workflow.rawValue,
                    context: context
                ))
            }

            // Prior versions
            for prior in record.priorVersions {
                if let resolved = resolvePath(prior.path) {
                    assets.append(DiscoveredAsset(
                        resolvedPath: resolved,
                        projectRelativePath: relativePath(resolved),
                        linkKind: kind,
                        ownerID: record.id.uuidString,
                        ownerParentID: record.linkedPlaceID?.uuidString,
                        context: ["isPriorVersion": "true", "versionPath": prior.path]
                    ))
                }
            }
        }

        // Landmark references
        for landmark in store.placesWorkflowLibrary.landmarkReferences {
            if let resolved = resolvePath(landmark.imagePath) {
                assets.append(DiscoveredAsset(
                    resolvedPath: resolved,
                    projectRelativePath: relativePath(resolved),
                    linkKind: .placeLandmarkReference,
                    context: ["landmarkName": landmark.title]
                ))
            }
        }

        // Master map
        if let masterMapPath = store.placesWorkflowLibrary.masterMapImagePath,
           let resolved = resolvePath(masterMapPath) {
            assets.append(DiscoveredAsset(
                resolvedPath: resolved,
                projectRelativePath: relativePath(resolved),
                linkKind: .placeMasterMap
            ))
        }
    }

    // MARK: - Canvas Generations

    private func discoverCanvasGenerations(into assets: inout [DiscoveredAsset]) {
        for generation in store.canvasGenerations {
            if let resolved = resolvePath(generation.imagePath) {
                assets.append(DiscoveredAsset(
                    resolvedPath: resolved,
                    projectRelativePath: relativePath(resolved),
                    linkKind: .canvasGeneration,
                    ownerID: generation.id.uuidString,
                    context: [
                        "prompt": generation.prompt,
                        "model": generation.model.rawValue,
                        "aspectRatio": generation.aspectRatio,
                        "imageSize": generation.imageSize
                    ]
                ))
            }
        }
    }

    // MARK: - Characters

    private func discoverCharacters(into assets: inout [DiscoveredAsset]) {
        for character in store.characters {
            let charID = character.id.uuidString

            // Profile image
            if let path = character.profileImagePath,
               let resolved = resolvePath(path) {
                assets.append(DiscoveredAsset(
                    resolvedPath: resolved,
                    projectRelativePath: relativePath(resolved),
                    linkKind: .characterProfile,
                    ownerID: charID
                ))
            }

            // Inspiration images
            for path in character.inspirationImagePaths {
                if let resolved = resolvePath(path) {
                    let rating = character.inspirationRatings?[path]
                    let isRejected = character.inspirationRejectedPaths.contains(path)
                    let notes = character.inspirationNotes?[path]

                    var context: [String: String] = [:]
                    if let rating = rating {
                        context["rating"] = String(rating)
                    }
                    context["isRejected"] = String(isRejected)
                    if let notes = notes {
                        context["notes"] = notes
                    }

                    assets.append(DiscoveredAsset(
                        resolvedPath: resolved,
                        projectRelativePath: relativePath(resolved),
                        linkKind: .characterInspiration,
                        ownerID: charID,
                        context: context
                    ))
                }
            }

            // Inspiration reference
            if let path = character.inspirationReferenceImagePath,
               let resolved = resolvePath(path) {
                assets.append(DiscoveredAsset(
                    resolvedPath: resolved,
                    projectRelativePath: relativePath(resolved),
                    linkKind: .characterReference,
                    ownerID: charID
                ))
            }

            // Reference images
            for path in character.referenceImagePaths {
                if let resolved = resolvePath(path) {
                    assets.append(DiscoveredAsset(
                        resolvedPath: resolved,
                        projectRelativePath: relativePath(resolved),
                        linkKind: .characterReference,
                        ownerID: charID
                    ))
                }
            }

            // Animated images
            for path in character.animatedImagePaths {
                if let resolved = resolvePath(path) {
                    assets.append(DiscoveredAsset(
                        resolvedPath: resolved,
                        projectRelativePath: relativePath(resolved),
                        linkKind: .characterAnimated,
                        ownerID: charID
                    ))
                }
            }

            // Master reference source images
            for path in character.masterReferenceSourceImagePaths {
                if let resolved = resolvePath(path) {
                    assets.append(DiscoveredAsset(
                        resolvedPath: resolved,
                        projectRelativePath: relativePath(resolved),
                        linkKind: .characterMasterSource,
                        ownerID: charID
                    ))
                }
            }

            // Master reference sheet variants
            for variant in character.masterReferenceSheetVariants {
                if let resolved = resolvePath(variant.imagePath) {
                    assets.append(DiscoveredAsset(
                        resolvedPath: resolved,
                        projectRelativePath: relativePath(resolved),
                        linkKind: .characterMasterSheetVariant,
                        ownerID: charID,
                        context: ["variantID": variant.id.uuidString]
                    ))
                }
            }

            // Head turnaround variants
            for variant in character.headTurnaroundSheetVariants {
                if let resolved = resolvePath(variant.imagePath) {
                    assets.append(DiscoveredAsset(
                        resolvedPath: resolved,
                        projectRelativePath: relativePath(resolved),
                        linkKind: .characterHeadSheetVariant,
                        ownerID: charID,
                        context: ["variantID": variant.id.uuidString]
                    ))
                }
            }

            // Look development slots
            for slot in character.lookDevelopmentSlots {
                for variant in slot.variants {
                    if let resolved = resolvePath(variant.imagePath) {
                        assets.append(DiscoveredAsset(
                            resolvedPath: resolved,
                            projectRelativePath: relativePath(resolved),
                            linkKind: .characterLookdevVariant,
                            ownerID: charID,
                            ownerParentID: slot.id.uuidString,
                            context: ["slotTitle": slot.title, "variantID": variant.id.uuidString]
                        ))
                    }
                }
            }

            // Head turnaround slots
            for slot in character.headTurnaroundSlots {
                for variant in slot.variants {
                    if let resolved = resolvePath(variant.imagePath) {
                        assets.append(DiscoveredAsset(
                            resolvedPath: resolved,
                            projectRelativePath: relativePath(resolved),
                            linkKind: .characterHeadTurnVariant,
                            ownerID: charID,
                            ownerParentID: slot.id.uuidString,
                            context: ["slotTitle": slot.title, "variantID": variant.id.uuidString]
                        ))
                    }
                }
            }

            // Costume reference sets
            for costume in character.costumeReferenceSets {
                let costumeID = costume.id.uuidString

                // Sheet variants
                for variant in costume.sheetVariants {
                    if let resolved = resolvePath(variant.imagePath) {
                        assets.append(DiscoveredAsset(
                            resolvedPath: resolved,
                            projectRelativePath: relativePath(resolved),
                            linkKind: .characterCostumeSheetVariant,
                            ownerID: charID,
                            ownerParentID: costumeID,
                            context: ["variantID": variant.id.uuidString, "costumeName": costume.name]
                        ))
                    }
                }

                // Full body slots
                for slot in costume.fullBodySlots {
                    for variant in slot.variants {
                        if let resolved = resolvePath(variant.imagePath) {
                            assets.append(DiscoveredAsset(
                                resolvedPath: resolved,
                                projectRelativePath: relativePath(resolved),
                                linkKind: .characterCostumeFullbodyVariant,
                                ownerID: charID,
                                ownerParentID: costumeID,
                                context: [
                                    "slotTitle": slot.title,
                                    "variantID": variant.id.uuidString,
                                    "costumeName": costume.name
                                ]
                            ))
                        }
                    }
                }

                // Accessory slots
                for slot in costume.accessorySlots {
                    for variant in slot.variants {
                        if let resolved = resolvePath(variant.imagePath) {
                            assets.append(DiscoveredAsset(
                                resolvedPath: resolved,
                                projectRelativePath: relativePath(resolved),
                                linkKind: .characterCostumeAccessoryVariant,
                                ownerID: charID,
                                ownerParentID: costumeID,
                                context: [
                                    "slotTitle": slot.title,
                                    "variantID": variant.id.uuidString,
                                    "costumeName": costume.name
                                ]
                            ))
                        }
                    }
                }

                // Reference images
                for path in costume.costumeReferenceImagePaths {
                    if let resolved = resolvePath(path) {
                        assets.append(DiscoveredAsset(
                            resolvedPath: resolved,
                            projectRelativePath: relativePath(resolved),
                            linkKind: .characterCostumeReference,
                            ownerID: charID,
                            ownerParentID: costumeID,
                            context: ["costumeName": costume.name]
                        ))
                    }
                }

                // Generated variations
                for path in costume.generatedVariationImagePaths {
                    if let resolved = resolvePath(path) {
                        assets.append(DiscoveredAsset(
                            resolvedPath: resolved,
                            projectRelativePath: relativePath(resolved),
                            linkKind: .characterCostumeVariation,
                            ownerID: charID,
                            ownerParentID: costumeID,
                            context: ["costumeName": costume.name]
                        ))
                    }
                }
            }
        }
    }

    // MARK: - Scene Shots

    private func discoverSceneShots(into assets: inout [DiscoveredAsset]) {
        for (_, galleries) in store.imagineSceneGalleries {
            for gallery in galleries {
                let galleryID = gallery.id.uuidString

                for path in gallery.beginningImagePaths {
                    if let resolved = resolvePath(path) {
                        assets.append(DiscoveredAsset(
                            resolvedPath: resolved,
                            projectRelativePath: relativePath(resolved),
                            linkKind: .sceneShotImage,
                            ownerID: galleryID,
                            moment: "beginning"
                        ))
                    }
                }

                for path in gallery.middleImagePaths {
                    if let resolved = resolvePath(path) {
                        assets.append(DiscoveredAsset(
                            resolvedPath: resolved,
                            projectRelativePath: relativePath(resolved),
                            linkKind: .sceneShotImage,
                            ownerID: galleryID,
                            moment: "middle"
                        ))
                    }
                }

                for path in gallery.endImagePaths {
                    if let resolved = resolvePath(path) {
                        assets.append(DiscoveredAsset(
                            resolvedPath: resolved,
                            projectRelativePath: relativePath(resolved),
                            linkKind: .sceneShotImage,
                            ownerID: galleryID,
                            moment: "end"
                        ))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func resolvePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Use AnimateStore's resolution if available
        if let resolvedURL = store.resolvedCharacterAssetURL(for: trimmed) {
            return resolvedURL.path
        }

        // Check if absolute path exists
        if FileManager.default.fileExists(atPath: trimmed) {
            return trimmed
        }

        // Try relative to project
        if let projectURL = store.owpURL {
            let relativeURL = projectURL.appendingPathComponent(trimmed)
            if FileManager.default.fileExists(atPath: relativeURL.path) {
                return relativeURL.path
            }
        }

        // Return as-is even if not found (will be marked missing later)
        return trimmed
    }

    private func relativePath(_ resolvedPath: String) -> String? {
        guard let projectURL = store.owpURL else { return nil }
        let projectPath = projectURL.path

        if resolvedPath.hasPrefix(projectPath) {
            let relative = String(resolvedPath.dropFirst(projectPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative
        }

        return nil
    }
}
