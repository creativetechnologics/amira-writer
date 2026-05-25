import Foundation

@available(macOS 26.0, *)
struct MixBrowserNode: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case root
        case folder
        case audio
    }

    var id: String { path }
    var name: String
    var path: String
    var kind: Kind
    var children: [MixBrowserNode]
    var fileSize: Int64?

    var isDirectory: Bool {
        kind != .audio
    }
}

@available(macOS 26.0, *)
struct MixPluginInfo: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var manufacturerName: String
    var formatLabel: String
    var hasCustomView: Bool
}

@available(macOS 26.0, *)
struct MixInputDevice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var uniqueID: String?
    var isConnected: Bool
}

@available(macOS 26.0, *)
enum MixMicrophonePermissionState: String, Sendable {
    case unknown
    case notDetermined
    case denied
    case restricted
    case authorized
}
