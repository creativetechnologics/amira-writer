import Foundation

/// Parses bracketed scene direction markup from script text.
///
/// Format: `[tag: "primary_value" | key=value | key=value]`
///
/// The parser extracts all bracketed directions from the text, preserving
/// line numbers for error reporting. Non-direction text (dialogue, lyrics)
/// is preserved as-is for display purposes.
struct SceneDirectionParser: Sendable {

    // MARK: - Types

    struct ParseResult: Sendable {
        var directions: [SceneDirection]
        var scriptLines: [ScriptLine]
        var errors: [ParseError]
    }

    struct ScriptLine: Identifiable, Sendable {
        var id = UUID()
        var lineNumber: Int
        var text: String
        var isDirection: Bool
        var direction: SceneDirection?
    }

    struct ParseError: Error, Sendable {
        var lineNumber: Int
        var message: String
    }

    // MARK: - Parsing

    /// Parse a full script text, extracting all bracketed directions.
    static func parse(_ text: String) -> ParseResult {
        var directions: [SceneDirection] = []
        var scriptLines: [ScriptLine] = []
        var errors: [ParseError] = []

        let lines = text.components(separatedBy: .newlines)

        for (lineIndex, line) in lines.enumerated() {
            let lineNumber = lineIndex + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                scriptLines.append(ScriptLine(lineNumber: lineNumber, text: "", isDirection: false))
                continue
            }

            // Check for bracketed direction(s) in this line
            let directionMatches = extractDirections(from: trimmed, lineNumber: lineNumber)

            if directionMatches.isEmpty {
                // Plain script text (dialogue, lyrics, stage directions in prose)
                scriptLines.append(ScriptLine(lineNumber: lineNumber, text: trimmed, isDirection: false))
            } else {
                for match in directionMatches {
                    switch match {
                    case .success(let dir):
                        directions.append(dir)
                        scriptLines.append(ScriptLine(lineNumber: lineNumber, text: trimmed, isDirection: true, direction: dir))
                    case .failure(let err):
                        errors.append(err)
                        scriptLines.append(ScriptLine(lineNumber: lineNumber, text: trimmed, isDirection: false))
                    }
                }
            }
        }

        return ParseResult(directions: directions, scriptLines: scriptLines, errors: errors)
    }

    /// Extract all `[...]` direction blocks from a single line.
    private static func extractDirections(from line: String, lineNumber: Int) -> [Result<SceneDirection, ParseError>] {
        var results: [Result<SceneDirection, ParseError>] = []

        // Match all [...] blocks
        let pattern = #"\[([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))

        for match in matches {
            let content = nsLine.substring(with: match.range(at: 1))
            let result = parseDirection(content, lineNumber: lineNumber)
            results.append(result)
        }

        return results
    }

    /// Parse the content inside brackets: `tag: "primary" | key=value | key=value`
    private static func parseDirection(_ content: String, lineNumber: Int) -> Result<SceneDirection, ParseError> {
        // Split by pipe to get segments
        let segments = content.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }

        guard let first = segments.first, !first.isEmpty else {
            return .failure(ParseError(lineNumber: lineNumber, message: "Empty direction"))
        }

        // First segment: "tag: primary_value"
        let tagParts = first.split(separator: ":", maxSplits: 1)
        guard let tagString = tagParts.first else {
            return .failure(ParseError(lineNumber: lineNumber, message: "Missing tag in direction"))
        }

        let tagName = tagString.trimmingCharacters(in: .whitespaces).lowercased()
        guard let tag = DirectionTag(rawValue: tagName) else {
            return .failure(ParseError(lineNumber: lineNumber, message: "Unknown direction tag: \(tagName)"))
        }

        let primaryValue: String
        if tagParts.count > 1 {
            primaryValue = tagParts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } else {
            primaryValue = ""
        }

        // Remaining segments: key=value pairs
        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            let kvParts = segment.split(separator: "=", maxSplits: 1)
            if kvParts.count == 2 {
                let key = kvParts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = kvParts[1]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                parameters[key] = value
            } else {
                // Bare value without key — treat as "description" for action tags
                let value = segment.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if parameters["description"] == nil {
                    parameters["description"] = value
                }
            }
        }

        let direction = SceneDirection(
            tag: tag,
            primaryValue: primaryValue,
            parameters: parameters,
            sourceLineNumber: lineNumber
        )

        return .success(direction)
    }

    // MARK: - Compilation

    /// Compile parsed directions into a scene with frame-based keyframes.
    static func compile(
        directions: [SceneDirection],
        fps: Int,
        bpm: Double = 120,
        beatsPerBar: Int = 4
    ) -> CompiledScene {
        var scene = CompiledScene()
        var currentFrame = 0
        let _ = Double(fps) * 60.0 / bpm

        for direction in directions {
            switch direction.tag {
            case .scene:
                scene.name = direction.primaryValue
                scene.backgroundName = direction.parameters["bg"] ?? direction.parameters["background"]
                scene.lighting = direction.parameters["lighting"] ?? direction.parameters["time"]

            case .enter:
                let charName = direction.primaryValue
                let posStr = direction.parameters["position"] ?? "center"
                let position = StagePosition.from(posStr)?.normalizedX ?? 0.5
                let facingStr = direction.parameters["facing"] ?? "camera"
                let facing = FacingDirection(rawValue: facingStr) ?? .camera
                let emotion = direction.parameters["emotion"] ?? "neutral"

                let enterFrame: Int
                if let bars = direction.parameters["bar"] ?? direction.parameters["bars"] {
                    let timing = DirectionTiming.parse(bars)
                    enterFrame = timing.toFrameRange(fps: fps, bpm: bpm, beatsPerBar: beatsPerBar)?.start ?? currentFrame
                } else {
                    enterFrame = currentFrame
                }

                let setup = CharacterSetup(
                    characterName: charName,
                    initialPosition: position,
                    initialFacing: facing,
                    initialEmotion: emotion,
                    enterFrame: enterFrame
                )
                scene.characterSetups.append(setup)

                // Generate enter keyframes
                let trackName = "\(charName):transform"
                let scaleX: Double = (facing == .left) ? -1 : 1
                let transform = CharacterTransform(
                    x: position, y: 0.5, rotation: 0,
                    scaleX: scaleX, scaleY: 1, opacity: 1, zOrder: scene.characterSetups.count
                )
                let kf = TimelineKeyframe(frame: enterFrame, kind: .transform, value: .transform(transform))
                scene.tracks[trackName, default: []].append(kf)

                // Expression keyframe
                let exprTrack = "\(charName):expression"
                let exprKF = TimelineKeyframe(frame: enterFrame, kind: .expression, easing: .stepped, value: .expression(name: emotion))
                scene.tracks[exprTrack, default: []].append(exprKF)

            case .exit:
                let charName = direction.primaryValue
                let exitDir = direction.parameters["direction"] ?? "fade"

                let exitFrame: Int
                if let bars = direction.parameters["bar"] ?? direction.parameters["bars"] {
                    let timing = DirectionTiming.parse(bars)
                    exitFrame = timing.toFrameRange(fps: fps, bpm: bpm, beatsPerBar: beatsPerBar)?.start ?? currentFrame
                } else {
                    exitFrame = currentFrame
                }

                // Update character setup with exit frame
                if let idx = scene.characterSetups.firstIndex(where: { $0.characterName == charName }) {
                    scene.characterSetups[idx].exitFrame = exitFrame
                }

                let trackName = "\(charName):transform"
                if exitDir == "fade" {
                    let visTrack = "\(charName):visibility"
                    let fadeKFs = AnimationEngine.generateFade(
                        fadeIn: false, startFrame: exitFrame, endFrame: exitFrame + fps / 2
                    )
                    scene.tracks[visTrack, default: []].append(contentsOf: fadeKFs)
                } else {
                    let exitX: Double = (exitDir == "left") ? -0.15 : 1.15
                    // Get current position or default
                    let currentPos = scene.characterSetups.first(where: { $0.characterName == charName })?.initialPosition ?? 0.5
                    let fromTransform = CharacterTransform(x: currentPos, y: 0.5, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 0)
                    let toTransform = CharacterTransform(x: exitX, y: 0.5, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 0)
                    let moveKFs = AnimationEngine.generateMovement(
                        from: fromTransform, to: toTransform,
                        startFrame: exitFrame, endFrame: exitFrame + fps
                    )
                    scene.tracks[trackName, default: []].append(contentsOf: moveKFs)
                }

            case .move:
                let charName = direction.primaryValue
                let toStr = direction.parameters["to"] ?? "center"
                let toX = StagePosition.from(toStr)?.normalizedX ?? 0.5
                let fromStr = direction.parameters["from"]
                let fromX = fromStr.flatMap { StagePosition.from($0)?.normalizedX }
                    ?? scene.characterSetups.first(where: { $0.characterName == charName })?.initialPosition ?? 0.5

                let easingStr = direction.parameters["easing"] ?? "ease_in_out"
                let easing = parseEasing(easingStr)

                let frameRange: (start: Int, end: Int)
                if let bars = direction.parameters["bars"] {
                    let timing = DirectionTiming.parse(bars)
                    frameRange = timing.toFrameRange(fps: fps, bpm: bpm, beatsPerBar: beatsPerBar) ?? (currentFrame, currentFrame + fps * 2)
                } else {
                    frameRange = (currentFrame, currentFrame + fps * 2)
                }

                let trackName = "\(charName):transform"
                let fromTransform = CharacterTransform(x: fromX, y: 0.5, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 0)
                let toTransform = CharacterTransform(x: toX, y: 0.5, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 0)
                let moveKFs = AnimationEngine.generateMovement(
                    from: fromTransform, to: toTransform,
                    startFrame: frameRange.start, endFrame: frameRange.end,
                    easing: easing
                )
                scene.tracks[trackName, default: []].append(contentsOf: moveKFs)
                currentFrame = max(currentFrame, frameRange.end)

            case .emotion:
                let charName = direction.primaryValue
                let expression = direction.parameters["expression"] ?? "neutral"

                let frame: Int
                if let bar = direction.parameters["bar"] {
                    let timing = DirectionTiming.parse(bar)
                    frame = timing.toFrameRange(fps: fps, bpm: bpm, beatsPerBar: beatsPerBar)?.start ?? currentFrame
                } else {
                    frame = currentFrame
                }

                let trackName = "\(charName):expression"
                let kf = AnimationEngine.generateExpressionChange(expression: expression, at: frame)
                scene.tracks[trackName, default: []].append(kf)

            case .action:
                let charName = direction.primaryValue
                let _ = direction.parameters["description"] ?? ""

                if let bars = direction.parameters["bars"] {
                    let timing = DirectionTiming.parse(bars)
                    if let range = timing.toFrameRange(fps: fps, bpm: bpm, beatsPerBar: beatsPerBar) {
                        currentFrame = max(currentFrame, range.end)
                    }
                }

                // Actions are descriptive — they become notes on the timeline
                // A future LLM integration could expand these into specific keyframes
                let trackName = "\(charName):action"
                let kf = TimelineKeyframe(
                    frame: currentFrame,
                    kind: .expression,
                    easing: .stepped,
                    value: .expression(name: direction.parameters["description"] ?? "action")
                )
                scene.tracks[trackName, default: []].append(kf)

            case .gesture:
                let charName = direction.primaryValue
                let _ = direction.parameters["type"] ?? ""

                if let bars = direction.parameters["bars"] {
                    let timing = DirectionTiming.parse(bars)
                    if let range = timing.toFrameRange(fps: fps, bpm: bpm, beatsPerBar: beatsPerBar) {
                        currentFrame = max(currentFrame, range.end)
                    }
                }

                // Gestures translate to drawing swap keyframes
                let trackName = "\(charName):gesture"
                let kf = TimelineKeyframe(
                    frame: currentFrame,
                    kind: .drawing,
                    easing: .stepped,
                    value: .expression(name: direction.parameters["type"] ?? "gesture")
                )
                scene.tracks[trackName, default: []].append(kf)

            case .camera:
                let cameraType = direction.primaryValue.lowercased()
                let movement = CameraMovement(rawValue: cameraType) ?? .hold
                let fromShot = direction.parameters["from"].flatMap { CameraShot(rawValue: $0) }
                let toShot = direction.parameters["to"].flatMap { CameraShot(rawValue: $0) }
                let easing = parseEasing(direction.parameters["easing"] ?? "ease_in_out")

                let frameRange: (start: Int, end: Int)
                if let bars = direction.parameters["bars"] {
                    let timing = DirectionTiming.parse(bars)
                    frameRange = timing.toFrameRange(fps: fps, bpm: bpm, beatsPerBar: beatsPerBar) ?? (currentFrame, currentFrame + fps * 4)
                } else {
                    frameRange = (currentFrame, currentFrame + fps * 4)
                }

                // Camera keyframes use transform with zoom encoded in scale
                let startZoom = fromShot?.zoomLevel ?? 1.0
                let endZoom = toShot?.zoomLevel ?? startZoom
                var panX = 0.0
                switch movement {
                case .panLeft: panX = -0.2
                case .panRight: panX = 0.2
                default: break
                }

                let camStart = CharacterTransform(x: 0, y: 0, rotation: 0, scaleX: startZoom, scaleY: startZoom, opacity: 1, zOrder: 0)
                let camEnd = CharacterTransform(x: panX, y: 0, rotation: 0, scaleX: endZoom, scaleY: endZoom, opacity: 1, zOrder: 0)

                let camKFs = AnimationEngine.generateMovement(
                    from: camStart, to: camEnd,
                    startFrame: frameRange.start, endFrame: frameRange.end,
                    easing: easing
                )
                scene.cameraKeyframes.append(contentsOf: camKFs)
                currentFrame = max(currentFrame, frameRange.end)

            case .lipsync:
                let charName = direction.primaryValue
                let _ = direction.parameters["mode"] ?? "singing"
                // Lip sync directions are markers — actual keyframes are generated
                // by the LipSyncEngine when OWP data or audio is loaded
                let trackName = "\(charName):lipsync"
                let kf = TimelineKeyframe(
                    frame: currentFrame,
                    kind: .expression,
                    easing: .stepped,
                    value: .expression(name: "lipsync:active")
                )
                scene.tracks[trackName, default: []].append(kf)

            case .pause:
                if let bars = direction.parameters["bars"] {
                    let timing = DirectionTiming.parse("bars:\(bars)")
                    if let range = timing.toFrameRange(fps: fps, bpm: bpm, beatsPerBar: beatsPerBar) {
                        currentFrame += (range.end - range.start)
                    }
                } else if let beats = direction.parameters["beats"] {
                    let timing = DirectionTiming.parse("beats:\(beats)")
                    if let range = timing.toFrameRange(fps: fps, bpm: bpm, beatsPerBar: beatsPerBar) {
                        currentFrame += (range.end - range.start)
                    }
                } else if let frames = direction.parameters["frames"] {
                    currentFrame += Int(frames) ?? 0
                }

            case .sfx:
                // Sound effect markers — stored for future audio integration
                break

            case .transition:
                // Scene transitions — stored for export compositing
                break
            }
        }

        scene.totalFrames = currentFrame
        return scene
    }

    // MARK: - Helpers

    private static func parseEasing(_ string: String) -> EasingCurve {
        switch string.lowercased().trimmingCharacters(in: .whitespaces) {
        case "linear": return .linear
        case "ease_in", "easein": return .easeIn
        case "ease_out", "easeout": return .easeOut
        case "ease_in_out", "easeinout": return .easeInOut
        case "stepped", "hold": return .stepped
        default: return .easeInOut
        }
    }
}
