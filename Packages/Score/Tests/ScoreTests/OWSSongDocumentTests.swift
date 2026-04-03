import Foundation
import Testing
@testable import ScoreUI

@Suite("OWS Song Document")
struct OWSSongDocumentTests {
    @Test func loadsPlaybackFromPlaybackSnapshotWhenPlaybackFieldIsAbsent() throws {
        let now = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 10))
        let versionID = UUID()
        let json: [String: Any] = [
            "songID": UUID().uuidString,
            "title": "Snapshot Only",
            "canonicalTitle": "snapshot only",
            "notes": "",
            "updatedAt": now,
            "activeVersionID": versionID.uuidString,
            "versions": [[
                "id": versionID.uuidString,
                "label": "Version 1",
                "createdAt": now,
                "updatedAt": now,
                "lyrics": "",
                "saveType": "manual",
                "isBookmarked": false,
                "playbackSnapshot": [
                    "notes": [[
                        "id": UUID().uuidString,
                        "trackIndex": 0,
                        "channel": 0,
                        "pitch": 64,
                        "velocity": 90,
                        "startTick": 0,
                        "duration": 240,
                        "muted": false,
                    ]],
                    "trackNames": ["0": "Lead"],
                    "channelPrograms": ["0": 1],
                    "trackChannelPrograms": ["0": ["0": 1]],
                    "lyricCues": [],
                    "audioClips": [],
                    "tempoEvents": [],
                    "ticksPerQuarter": 480,
                    "lengthTicks": 480,
                    "initialTempoBPM": 120,
                ],
            ]],
        ]

        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let document = try OWSSongDocument.fromJSON(data: data)

        #expect(document.activeVersion()?.playback?.notes.count == 1)
        #expect(document.activeVersion()?.playback?.trackNames[0] == "Lead")
    }
}
