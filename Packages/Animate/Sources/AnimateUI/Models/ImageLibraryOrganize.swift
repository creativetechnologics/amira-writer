import Foundation

enum ImageLibraryOrganizeCategory: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case costumes
    case props
    case vehicles

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .costumes: "Costumes"
        case .props: "Props"
        case .vehicles: "Vehicles"
        }
    }

    var singularName: String {
        switch self {
        case .costumes: "Costume"
        case .props: "Prop"
        case .vehicles: "Vehicle"
        }
    }

    var systemImage: String {
        switch self {
        case .costumes: "tshirt"
        case .props: "shippingbox"
        case .vehicles: "car"
        }
    }
}

struct ImageLibraryOrganizeItem: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var category: ImageLibraryOrganizeCategory
    var title: String
    var imagePaths: [String]
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        category: ImageLibraryOrganizeCategory,
        title: String,
        imagePaths: [String] = [],
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.imagePaths = imagePaths
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ImageLibraryOrganizeManifest: Codable, Sendable {
    var schemaVersion: Int = 1
    var items: [ImageLibraryOrganizeItem] = []
}
