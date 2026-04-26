import Foundation

// MARK: - StoryboardAnalysisKnownEntity

@available(macOS 26.0, *)
public struct StoryboardAnalysisKnownEntity: Codable, Equatable, Sendable, Hashable {
    public var identifier: String?
    public var name: String
    public var notes: String?

    public init(identifier: String? = nil, name: String, notes: String? = nil) {
        self.identifier = identifier
        self.name = name
        self.notes = notes
    }
}

// MARK: - StoryboardAnalysisPromptContext

@available(macOS 26.0, *)
public struct StoryboardAnalysisPromptContext: Codable, Equatable, Sendable, Hashable {
    public var sceneID: String
    public var shotID: String
    public var frame: String
    public var directionText: String?
    public var actionText: String?
    public var cameraText: String?
    public var shotSummary: String?
    public var knownCharacters: [StoryboardAnalysisKnownEntity]
    public var knownPlaces: [StoryboardAnalysisKnownEntity]
    public var knownLandmarks: [StoryboardAnalysisKnownEntity]
    public var timeOfDay: String?
    public var orientationNotes: String?

    public init(
        sceneID: String,
        shotID: String,
        frame: String,
        directionText: String? = nil,
        actionText: String? = nil,
        cameraText: String? = nil,
        shotSummary: String? = nil,
        knownCharacters: [StoryboardAnalysisKnownEntity] = [],
        knownPlaces: [StoryboardAnalysisKnownEntity] = [],
        knownLandmarks: [StoryboardAnalysisKnownEntity] = [],
        timeOfDay: String? = nil,
        orientationNotes: String? = nil
    ) {
        self.sceneID = sceneID
        self.shotID = shotID
        self.frame = frame
        self.directionText = directionText
        self.actionText = actionText
        self.cameraText = cameraText
        self.shotSummary = shotSummary
        self.knownCharacters = knownCharacters
        self.knownPlaces = knownPlaces
        self.knownLandmarks = knownLandmarks
        self.timeOfDay = timeOfDay
        self.orientationNotes = orientationNotes
    }
}

// MARK: - StoryboardAnalysisPromptBuilder

@available(macOS 26.0, *)
public enum StoryboardAnalysisPromptBuilder {
    public static func buildPrompt(context: StoryboardAnalysisPromptContext) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let contextJSON = Self.encodeJSON(context, encoder: encoder) ?? Self.manualContextJSON(context)

        return """
        You are analyzing a storyboard frame PNG for an iPad storyboard system.

        Return ONLY strict JSON. Do not wrap the answer in markdown, code fences, comments, or prose.
        The JSON must match the storyboard frame analysis shape used by the app:

        {
          "schemaVersion": 1,
          "sceneID": "string",
          "shotID": "string",
          "frame": "string",
          "imagePath": "string or empty string",
          "projectRelativePath": "string or null",
          "contentHash": "string or null",
          "status": "pending|analyzing|complete|needsReview|conflicted|failed",
          "summary": "string or null",
          "detectedEntities": [
            {
              "identifier": "string or null",
              "targetID": "string or null",
              "kind": "string or null",
              "label": "string or null",
              "boundingBox": { "x": 0, "y": 0, "width": 0, "height": 0 } or null,
              "gridCell": "string or null",
              "confidence": 0.0,
              "source": "string or null",
              "notes": "string or null"
            }
          ],
          "compositionGrid": {
            "rows": 0 or null,
            "columns": 0 or null,
            "focus": "string or null",
            "highlightedCells": ["string"],
            "notes": "string or null"
          } or null,
          "cameraRead": {
            "shotSize": "string or null",
            "angle": "string or null",
            "movement": "string or null",
            "lens": "string or null",
            "notes": "string or null"
          } or null,
          "motionVectors": [
            {
              "label": "string or null",
              "from": { "x": 0, "y": 0 } or null,
              "to": { "x": 0, "y": 0 } or null,
              "confidence": 0.0 or null,
              "notes": "string or null"
            }
          ],
          "visibleTextLabels": [
            {
              "text": "string",
              "boundingBox": { "x": 0, "y": 0, "width": 0, "height": 0 } or null,
              "confidence": 0.0 or null,
              "notes": "string or null"
            }
          ],
          "conflicts": [
            {
              "field": "string or null",
              "expected": "string or null",
              "observed": "string or null",
              "severity": "string or null",
              "notes": "string or null"
            }
          ],
          "timestamps": {
            "createdAt": "ISO-8601 string or null",
            "updatedAt": "ISO-8601 string or null",
            "analyzedAt": "ISO-8601 string or null",
            "reviewedAt": "ISO-8601 string or null"
          },
          "analysisBackend": "string or null",
          "analysisModel": "string or null"
        }

        Analysis rules:
        - Treat the storyboard drawing as visual authority whenever the drawing is clear.
        - Use the script context as semantic guidance, but record a conflict whenever the drawing clearly contradicts the supplied direction, action, camera, or shot summary.
        - Compare the drawing against the known characters, places, and landmarks below. Prefer exact matches to the named world state; if the drawing appears to show a different entity, say so explicitly.
        - Identify composition structure, including an optional composition grid, the dominant focal area, and normalized bounding boxes for visible people, objects, text, and landmarks.
        - Bounding boxes must use normalized coordinates in the range 0.0 to 1.0 with origin at the top-left of the image.
        - If a thing is partially visible or uncertain, lower confidence rather than inventing details.
        - Use the conflicts array for every important mismatch between the storyboard drawing and the supplied context.
        - Keep the JSON internally consistent: the same entity should not be named differently across fields without a conflict entry explaining the mismatch.

        Known story context:
        \(contextJSON)

        Additional guidance:
        - sceneID: \(context.sceneID)
        - shotID: \(context.shotID)
        - frame: \(context.frame)
        - directionText: \(context.directionText ?? "")
        - actionText: \(context.actionText ?? "")
        - cameraText: \(context.cameraText ?? "")
        - shotSummary: \(context.shotSummary ?? "")
        - timeOfDay: \(context.timeOfDay ?? "")
        - orientationNotes: \(context.orientationNotes ?? "")

        If the image is ambiguous, prefer a concise, cautious answer over speculation. Output JSON only.
        """
    }

    private static func encodeJSON<T: Encodable>(_ value: T, encoder: JSONEncoder) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func manualContextJSON(_ context: StoryboardAnalysisPromptContext) -> String {
        let characters = context.knownCharacters.map { Self.manualEntityJSON($0) }.joined(separator: ",\n")
        let places = context.knownPlaces.map { Self.manualEntityJSON($0) }.joined(separator: ",\n")
        let landmarks = context.knownLandmarks.map { Self.manualEntityJSON($0) }.joined(separator: ",\n")

        return """
        {
          "sceneID": "\(Self.escape(context.sceneID))",
          "shotID": "\(Self.escape(context.shotID))",
          "frame": "\(Self.escape(context.frame))",
          "directionText": \(Self.jsonStringOrNull(context.directionText)),
          "actionText": \(Self.jsonStringOrNull(context.actionText)),
          "cameraText": \(Self.jsonStringOrNull(context.cameraText)),
          "shotSummary": \(Self.jsonStringOrNull(context.shotSummary)),
          "knownCharacters": [\(characters)],
          "knownPlaces": [\(places)],
          "knownLandmarks": [\(landmarks)],
          "timeOfDay": \(Self.jsonStringOrNull(context.timeOfDay)),
          "orientationNotes": \(Self.jsonStringOrNull(context.orientationNotes))
        }
        """
    }

    private static func manualEntityJSON(_ entity: StoryboardAnalysisKnownEntity) -> String {
        """
        {
          "identifier": \(Self.jsonStringOrNull(entity.identifier)),
          "name": "\(Self.escape(entity.name))",
          "notes": \(Self.jsonStringOrNull(entity.notes))
        }
        """
    }

    private static func jsonStringOrNull(_ value: String?) -> String {
        guard let value else { return "null" }
        return "\"\(escape(value))\""
    }

    private static func escape(_ value: String) -> String {
        var escaped = String()
        escaped.reserveCapacity(value.count + 8)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\u{08}":
                escaped += "\\b"
            case "\u{0C}":
                escaped += "\\f"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(format: "%04X", scalar.value)
                    escaped += "\\u\(hex)"
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }

        return escaped
    }
}
