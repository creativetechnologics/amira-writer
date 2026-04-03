#if canImport(AppKit)
import AVFoundation
import AudioToolbox
import CoreAudioKit
import Foundation

/// Discovers and manages Audio Unit instrument plugins installed on the system.
/// All scanning runs on a background thread to avoid blocking the UI.
@available(macOS 26.0, *)
@MainActor
final class AudioUnitManager {
    struct AUInstrumentInfo: Identifiable, Hashable, Sendable {
        var id: String { "\(componentType)-\(componentSubType)-\(manufacturer)" }
        var name: String
        var manufacturerName: String
        var componentType: UInt32
        var componentSubType: UInt32
        var manufacturer: UInt32
        var hasCustomView: Bool

        var audioComponentDescription: AudioComponentDescription {
            AudioComponentDescription(
                componentType: componentType,
                componentSubType: componentSubType,
                componentManufacturer: manufacturer,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        }

        /// FourCC string representation for display
        var subTypeString: String {
            fourCC(componentSubType)
        }

        var manufacturerCode: String {
            fourCC(manufacturer)
        }

        private func fourCC(_ value: UInt32) -> String {
            let fallback = UnicodeScalar(0x3F)! // '?'
            let chars: [Character] = [
                Character(UnicodeScalar((value >> 24) & 0xFF) ?? fallback),
                Character(UnicodeScalar((value >> 16) & 0xFF) ?? fallback),
                Character(UnicodeScalar((value >> 8) & 0xFF) ?? fallback),
                Character(UnicodeScalar(value & 0xFF) ?? fallback),
            ]
            return String(chars)
        }
    }

    private(set) var instruments: [AUInstrumentInfo] = []
    private(set) var isScanning = false

    func scanInstalledAudioUnits() async {
        guard !isScanning else { return }
        isScanning = true

        let found = await Task.detached(priority: .utility) {
            let manager = AVAudioUnitComponentManager.shared()
            let instrumentTypes: [OSType] = [
                kAudioUnitType_MusicDevice,
                kAudioUnitType_Generator,
            ]

            var deduped: [String: AUInstrumentInfo] = [:]

            for type in instrumentTypes {
                let desc = AudioComponentDescription(
                    componentType: type,
                    componentSubType: 0,
                    componentManufacturer: 0,
                    componentFlags: 0,
                    componentFlagsMask: 0
                )

                for component in manager.components(matching: desc) {
                    let compDesc = component.audioComponentDescription
                    let info = AUInstrumentInfo(
                        name: component.name.trimmingCharacters(in: .whitespacesAndNewlines),
                        manufacturerName: component.manufacturerName.trimmingCharacters(in: .whitespacesAndNewlines),
                        componentType: compDesc.componentType,
                        componentSubType: compDesc.componentSubType,
                        manufacturer: compDesc.componentManufacturer,
                        hasCustomView: component.hasCustomView
                    )
                    deduped[info.id] = info
                }
            }

            return deduped.values.sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.manufacturerName.localizedCaseInsensitiveCompare(rhs.manufacturerName) == .orderedAscending
            }
        }.value

        instruments = found
        isScanning = false
        NSLog("[AudioUnitManager] Found %d Audio Unit instruments", found.count)
    }

    /// Instantiate an Audio Unit asynchronously on a background thread.
    /// Returns the AVAudioUnit ready to be attached to an engine.
    static func instantiate(description: AudioComponentDescription) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess) { audioUnit, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let audioUnit {
                    nonisolated(unsafe) let unit = audioUnit
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AudioUnitManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to instantiate Audio Unit"]
                    ))
                }
            }
        }
    }
}
#endif
