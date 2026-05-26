import AppKit
import UniformTypeIdentifiers
import Foundation

@available(macOS 26.0, *)
@MainActor
final class PlacesStore {
    unowned let parent: AnimateStore
    init(parent: AnimateStore) { self.parent = parent }

    @discardableResult
    func upsertWorldPlaceAnchor(placeID: UUID, title: String, mapPoint: WorldMapPoint, role: PlaceWorldNodeRole = .landmark, shouldSave: Bool = true) -> UUID {
        if let index = parent.placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.placeID == placeID && $0.routeID == nil && $0.role == .landmark }) {
            parent.placesWorkflowLibrary.worldGraph.nodes[index].title = title
            parent.placesWorkflowLibrary.worldGraph.nodes[index].mapPoint = mapPoint
            let nodeID = parent.placesWorkflowLibrary.worldGraph.nodes[index].id
            parent.adoptGeneratedBackgroundRecords(for: placeID, nodeID: nodeID)
            if shouldSave { parent.scheduleDebouncedSave(writePlaces: true) }
            return nodeID
        }
        let node = PlaceWorldNode(routeID: nil, placeID: placeID, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Anchor" : title, sequenceIndex: 0, role: role, mapPoint: mapPoint)
        parent.placesWorkflowLibrary.worldGraph.nodes.append(node)
        parent.adoptGeneratedBackgroundRecords(for: placeID, nodeID: node.id)
        if shouldSave { parent.scheduleDebouncedSave(writePlaces: true) }
        return node.id
    }

    func updateWorldNodeSequenceIndex(_ sequenceIndex: Int, nodeID: UUID) {
        guard let index = parent.placesWorkflowLibrary.worldGraph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        parent.placesWorkflowLibrary.worldGraph.nodes[index].sequenceIndex = max(0, sequenceIndex)
        parent.scheduleDebouncedSave(writePlaces: true)
    }

    func setPlaceInteriorLink(_ interiorPlaceID: UUID?, for placeID: UUID) {
        guard let index = parent.backgrounds.firstIndex(where: { $0.id == placeID }) else { return }
        // interior link managed via PlaceWorldNode linkage
        parent.scheduleDebouncedSave(writePlaces: true)
    }

    func setPlaceImageRating(path: String, rating: Int, placeID: UUID) {
        parent.placeGenerationStatusByID[placeID] = "Rating: \(rating)"
    }

    func deletePlace(_ placeID: UUID) {
        parent.backgrounds.removeAll { $0.id == placeID }
        parent.placesWorkflowLibrary.worldGraph.nodes.removeAll { $0.placeID == placeID }
        parent.placesWorkflowLibrary.worldGraph.routes = parent.placesWorkflowLibrary.worldGraph.routes.filter { route in
            true
        }
        parent.placesWorkflowLibrary.generatedImageRecords.removeAll { $0.linkedPlaceID == placeID }
        parent.scheduleDebouncedSave(writePlaces: true)
    }

    func addPlaceReferenceImagesFromPicker(placeID: UUID, category: PlaceReferenceImage.Category = .misc) {
        let panel = NSOpenPanel()
        panel.title = "Add Reference Images for Place"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg]
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls { self.addPlaceReferenceImage(from: url, placeID: placeID, category: category) }
        }
    }

    func addPlaceReferenceImage(from url: URL, placeID: UUID, category: PlaceReferenceImage.Category = .misc) {
        guard parent.backgrounds.first(where: { $0.id == placeID }) != nil else { return }
        // Place reference images saved via sidecar persistence
        parent.scheduleDebouncedSave(writePlaces: true)
    }

    func removePlaceReferenceImage(_ referenceID: UUID, placeID: UUID) {
        parent.scheduleDebouncedSave(writePlaces: true)
    }

    func removePlaceImage(at imageIndex: Int, placeID: UUID) {
        guard let place = parent.backgrounds.first(where: { $0.id == placeID }) else { return }
        guard imageIndex >= 0, imageIndex < place.angleImages.count else { return }
        let path = place.angleImages[imageIndex].imagePath
        parent.backgrounds[parent.backgrounds.firstIndex(where: { $0.id == placeID })!].angleImages.remove(at: imageIndex)
        parent.scheduleDebouncedSave(writePlaces: true)
    }
}
