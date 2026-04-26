import Combine
import Foundation

@available(macOS 26.0, *)
@MainActor
final class StoryboardServerStatusModel: ObservableObject {
    enum RuntimeState: Equatable {
        case stopped
        case starting
        case live
        case failed(String)
    }

    static let shared = StoryboardServerStatusModel()

    @Published private(set) var state: RuntimeState = .stopped
    @Published private(set) var port: UInt16 = StoryboardAPIServer.configuredPortValue
    @Published private(set) var url: URL = StoryboardAPIServer.currentConfiguredURL()
    @Published private(set) var lastSaveToken: UInt64 = 0
    @Published private(set) var lastSaveDate: Date?
    @Published private(set) var lastSaveDescription: String?
    @Published private(set) var lastRecoveryToken: UInt64 = 0
    @Published private(set) var lastRecoveryDate: Date?
    @Published private(set) var lastRecoveryDescription: String?
    @Published private(set) var lastRecoveryError: String?

    var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    var displayURL: URL {
        url
    }

    var statusText: String {
        switch state {
        case .stopped:
            return "iPad server stopped"
        case .starting:
            return "iPad server starting"
        case .live:
            return "iPad server live"
        case .failed(let message):
            return "iPad server error: \(message)"
        }
    }

    var shortStatusText: String {
        switch state {
        case .stopped:
            return "iPad Offline"
        case .starting:
            return "iPad Starting"
        case .live:
            return "iPad Live"
        case .failed:
            return "iPad Error"
        }
    }

    var detailStatusText: String? {
        if let lastRecoveryError {
            return "Recovery error: \(lastRecoveryError)"
        }
        if let lastRecoveryDescription {
            return "Recovery: \(lastRecoveryDescription)"
        }

        switch state {
        case .stopped:
            return "Storyboard recovery is offline."
        case .starting:
            return "Storyboard recovery will resume after launch."
        case .live:
            if let lastSaveDescription {
                return "Last save: \(lastSaveDescription)"
            }
            return "Storyboard recovery is ready."
        case .failed(let message):
            return "Server error: \(message)"
        }
    }

    var recoveryQueueText: String {
        if lastRecoveryError != nil {
            return "Analysis recovery needs attention"
        }
        if lastRecoveryDate != nil {
            return "Analysis recovery updated"
        }

        switch state {
        case .stopped:
            return "Analysis recovery offline"
        case .starting:
            return "Analysis recovery pending startup"
        case .live:
            return "Analysis recovery pending"
        case .failed:
            return "Analysis recovery paused"
        }
    }

    var statusSymbolName: String {
        switch state {
        case .live:
            return "checkmark.circle.fill"
        case .starting:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .stopped:
            return "xmark.circle.fill"
        }
    }

    private init() {}

    func setStarting(port: UInt16, url: URL) {
        self.port = port
        self.url = url
        self.state = .starting
    }

    func setLive(port: UInt16, url: URL) {
        self.port = port
        self.url = url
        self.state = .live
    }

    func setStopped(port: UInt16, url: URL) {
        self.port = port
        self.url = url
        self.state = .stopped
    }

    func setFailed(_ message: String, port: UInt16, url: URL) {
        self.port = port
        self.url = url
        self.state = .failed(message)
    }

    func recordIPadSave(_ description: String) {
        lastSaveToken &+= 1
        lastSaveDate = Date()
        lastSaveDescription = description
    }

    func recordStoryboardRecovery(_ description: String) {
        lastRecoveryToken &+= 1
        lastRecoveryDate = Date()
        lastRecoveryDescription = description
        lastRecoveryError = nil
    }

    func recordStoryboardRecoveryError(_ message: String) {
        lastRecoveryToken &+= 1
        lastRecoveryDate = Date()
        lastRecoveryDescription = nil
        lastRecoveryError = message
    }
}
