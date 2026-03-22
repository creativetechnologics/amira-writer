#if canImport(AppKit)
/// Minimal stubs for types referenced by PianoRollViewController/ToolbarView
/// that exist in OperaWriter but are not needed for the Novotro Score piano roll.

import AppKit
import SwiftUI

// MARK: - MeterLevels

struct MeterLevels: Sendable {
    var peakL: Float
    var peakR: Float
    var rmsL: Float
    var rmsR: Float
    var clipped: Bool

    static let zero = MeterLevels(peakL: -160, peakR: -160, rmsL: -160, rmsR: -160, clipped: false)
}

// MARK: - Automation Types (from Novotro Score MixModels)

enum AutomationCurve: String, Codable, CaseIterable, Sendable {
    case linear
    case square
    case slowStart
    case slowEnd
    case sCurve
}

enum AutomationParameter: String, Codable, CaseIterable, Sendable {
    case volume
    case pan
    case mute
}

struct AutomationPoint: Codable, Hashable, Sendable {
    var tick: Int
    var value: Double       // 0.0-1.0 normalized
    var curveType: AutomationCurve

    init(tick: Int, value: Double, curveType: AutomationCurve = .linear) {
        self.tick = max(0, tick)
        self.value = min(max(value, 0), 1)
        self.curveType = curveType
    }
}

struct AutomationLane: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var parameter: AutomationParameter
    var points: [AutomationPoint]
    var visible: Bool
    var armed: Bool

    init(
        id: UUID = UUID(),
        parameter: AutomationParameter,
        points: [AutomationPoint] = [],
        visible: Bool = false,
        armed: Bool = false
    ) {
        self.id = id
        self.parameter = parameter
        self.points = points.sorted { $0.tick < $1.tick }
        self.visible = visible
        self.armed = armed
    }
}

// MARK: - MIDIInputManager

import CoreMIDI

/// MIDI CC callback: (ccNumber, value, channel)
typealias MIDICCCallback = (Int, Int, Int) -> Void

/// Manages CoreMIDI input from all available sources, capturing CC data.
/// MIDI note callback: (pitch, velocity, channel) — velocity 0 = note off
typealias MIDINoteCallback = (Int, Int, Int) -> Void

final class MIDIInputManager: @unchecked Sendable {
    var isConnected: Bool = false
    var midiActivity: Bool = false

    /// Called on every CC message (control change, pitch bend as CC 128, aftertouch as CC 129).
    var onCC: MIDICCCallback?
    /// Called on note on/off messages. Velocity 0 = note off.
    var onNote: MIDINoteCallback?

    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0

    init() {}

    func connectToAll() {
        guard !isConnected else { return }

        let clientName = "NovotroScoreMIDIInput" as CFString
        var status = MIDIClientCreate(clientName, nil, nil, &client)
        guard status == noErr else {
            NSLog("[MIDIInput] Failed to create client: %d", status)
            return
        }

        let portName = "NovotroScoreInputPort" as CFString
        let readBlock: MIDIReadBlock = { [weak self] packetList, _ in
            guard let self else { return }
            self.handlePackets(packetList)
        }
        status = MIDIInputPortCreateWithBlock(client, portName, &inputPort, readBlock)
        guard status == noErr else {
            NSLog("[MIDIInput] Failed to create input port: %d", status)
            return
        }

        let sourceCount = MIDIGetNumberOfSources()
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            let connectStatus = MIDIPortConnectSource(inputPort, source, nil)
            if connectStatus != noErr {
                NSLog("[MIDIInput] Failed to connect source %d: %d", i, connectStatus)
            }
        }

        isConnected = true
        NSLog("[MIDIInput] Connected to %d MIDI sources", sourceCount)
    }

    func disconnect() {
        guard isConnected else { return }
        MIDIPortDispose(inputPort)
        MIDIClientDispose(client)
        inputPort = 0
        client = 0
        isConnected = false
    }

    private func handlePackets(_ packetList: UnsafePointer<MIDIPacketList>) {
        let numPackets = Int(packetList.pointee.numPackets)
        guard numPackets > 0 else { return }
        // Get pointer to first packet in the list
        let firstPacketPtr = UnsafeMutablePointer<MIDIPacket>(
            mutating: UnsafeRawPointer(packetList).advanced(by: MemoryLayout<UInt32>.size)
                .assumingMemoryBound(to: MIDIPacket.self)
        )
        var curPacket = firstPacketPtr
        for _ in 0..<numPackets {
            let length = min(Int(curPacket.pointee.length), 256)
            if length > 0 {
                withUnsafeBytes(of: curPacket.pointee.data) { rawBuf in
                    let bytes = rawBuf.bindMemory(to: UInt8.self)
                    parsePacketBytes(bytes, length: length)
                }
            }
            curPacket = MIDIPacketNext(curPacket)
        }
    }

    private func parsePacketBytes(_ bytes: UnsafeBufferPointer<UInt8>, length: Int) {
        var offset = 0
        while offset < length {
            let statusByte = bytes[offset]
            let messageType = statusByte & 0xF0
            let channel = Int(statusByte & 0x0F)

            // Capture callbacks locally — they are set from @MainActor and invoked
            // here on the CoreMIDI I/O thread, so dispatch to main.
            let ccHandler = onCC
            let noteHandler = onNote

            switch messageType {
            case 0xB0:
                if offset + 2 < length {
                    let cc = Int(bytes[offset + 1]), val = Int(bytes[offset + 2])
                    DispatchQueue.main.async { ccHandler?(cc, val, channel) }
                }
                offset += 3
            case 0xE0:
                if offset + 2 < length {
                    let value = (Int(bytes[offset + 2]) << 7) | Int(bytes[offset + 1])
                    let mapped = Int(Double(value) / 16383.0 * 127.0)
                    DispatchQueue.main.async { ccHandler?(128, mapped, channel) }
                }
                offset += 3
            case 0xD0:
                if offset + 1 < length {
                    let val = Int(bytes[offset + 1])
                    DispatchQueue.main.async { ccHandler?(129, val, channel) }
                }
                offset += 2
            case 0xA0:
                if offset + 2 < length {
                    let val = Int(bytes[offset + 2])
                    DispatchQueue.main.async { ccHandler?(130, val, channel) }
                }
                offset += 3
            case 0x90: // Note On
                if offset + 2 < length {
                    let note = Int(bytes[offset + 1]), vel = Int(bytes[offset + 2])
                    DispatchQueue.main.async { noteHandler?(note, vel, channel) }
                }
                offset += 3
            case 0x80: // Note Off
                if offset + 2 < length {
                    let note = Int(bytes[offset + 1])
                    DispatchQueue.main.async { noteHandler?(note, 0, channel) }
                }
                offset += 3
            case 0xC0:
                offset += 2
            case 0xF0:
                offset = length
            default:
                offset += 1
            }
        }
    }
}

// MARK: - LyricTimingParser (stub)

/// Stub for OperaWriter's lyric timing tag parser. Novotro Score doesn't use timing tags in libretto.
enum LyricTimingParser {
    static func setTiming(in content: String, lineIndex: Int, tick: Int) -> String { content }
    static func removeTiming(in content: String, lineIndex: Int) -> String { content }
}

// MARK: - DirectionParser (stub)

/// Stub for OperaWriter's direction markup parser. Strips `[[...]]` direction blocks from libretto.
enum DirectionParser {
    static func stripDirections(from text: String) -> String {
        text.replacingOccurrences(of: #"\[\[.*?\]\]"#, with: "", options: .regularExpression)
    }
}

// MARK: - AppBundle (stub)

/// Stub for OperaWriter's bundle accessor. Points to the Novotro Score main bundle.
enum AppBundle {
    static let module = Bundle.main
}

// MARK: - MBROLASynthesizer (stub)

/// Stub for OperaWriter's MBROLA voice synthesis engine. Novotro Score does not include vocal synthesis.
final class MBROLASynthesizer: @unchecked Sendable {
    enum RenderState: Sendable {
        case idle
        case rendering(progress: Double, status: String)
        case finished
        case ready
        case error(String)
    }

    struct Voice: Identifiable, Sendable {
        var id: String
        var name: String
    }

    static let mbrolaVoices: [Voice] = [
        Voice(id: "us1", name: "US English Male"),
        Voice(id: "us2", name: "US English Female"),
        Voice(id: "us3", name: "US English Male 2"),
    ]

    var renderStates: [String: RenderState] = [:]

    func renderTrack(trackKey: String, notes: [PianoRollNote], lyrics: String, voiceID: String) async {}
    func cancelAll() {}
}

// MARK: - VoiceSynthesisService (stub)

/// Stub wrapper so toolbar can reference store.voiceSynthesisService.renderStates
@available(macOS 26.0, *)
final class VoiceSynthesisService: @unchecked Sendable {
    var renderStates: [String: MBROLASynthesizer.RenderState] = [:]
}
#endif
