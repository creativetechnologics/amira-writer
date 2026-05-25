import Foundation

struct OWPSongStub: Identifiable, Codable, Sendable {
    var id: UUID
    var title: String
    var owsPath: String
    var durationTicks: Int?
}
