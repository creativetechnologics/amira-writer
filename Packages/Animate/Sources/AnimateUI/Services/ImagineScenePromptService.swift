import Foundation

/// Generates image-generation prompts for scene shots via GPT 5.4 xhigh (codex CLI).
///
/// Archived: MiniMax M2.7 implementation removed 2026-04-05 — replaced with GPT 5.4 xhigh
/// via `codex exec` for higher quality scene-aware prompts.
@available(macOS 26.0, *)
@MainActor
final class ImagineScenePromptService {
    enum SubjectStyle: Sendable {
        case loraTokens
        case neutralSubjects
    }

    private let store: AnimateStore

    init(store: AnimateStore) {
        self.store = store
    }

    func generatePrompt(
        scene: AnimationScene,
        shotIndex: Int,
        moment: ImagineShotMoment,
        subjectStyle: SubjectStyle = .loraTokens
    ) async throws -> String {
        guard shotIndex >= 0, shotIndex < scene.shots.count else {
            throw PromptError.invalidShot
        }

        let shot = scene.shots[shotIndex]
        let contextBlock = buildContextBlock(
            scene: scene,
            shot: shot,
            shotIndex: shotIndex,
            moment: moment,
            subjectStyle: subjectStyle
        )
        let workflowMode: String
        let goodStyleExample: String
        switch subjectStyle {
        case .loraTokens:
            workflowMode = "using character LoRA trigger tokens"
            goodStyleExample = "\"lkhr27 on screen-left reaches left arm toward mrnza5 on screen-right. slight frown, looking away, medium shot, clinic courtyard at dusk, photoreal documentary still.\""
        case .neutralSubjects:
            workflowMode = "for reference-image scene editing with neutral subject labels"
            goodStyleExample = "\"subject_1 on screen-left reaches left arm toward subject_2 on screen-right. slight frown, looking away, medium shot, clinic courtyard at dusk, photoreal documentary still.\""
        }

        let instruction = """
        You are writing production prompts for FLUX.2 [klein] in Draw Things \(workflowMode).

        OUTPUT FORMAT:
        - Return ONLY the final prompt text.
        - Use 1 or 2 natural-language sentences.
        - 20 to 60 words total.
        - No bullets, no labels, no markdown, no JSON.

        STYLE RULES:
        - Start with subject token + visible action + exact screen blocking.
        - Then add only the most important visible details: gaze, expression, pose, shot size, setting, lighting.
        - Keep it short, literal, and visual.
        - Front-load the most important visual information.
        - Use plain descriptive language, not screenplay language.
        - Use positive framing only.

        ABSOLUTE RULES:
        1. The STAGE DIRECTIONS field is the highest priority. Follow it literally.
        2. Use ONLY the character identifier tokens provided in the context. NEVER write human names.
        3. If the stage directions imply screen-left, screen-right, foreground, background, facing left, or facing right, keep those directions explicit in the prompt.
        4. Give each visible character one distinct physical action clause.
        5. Use only visible expression words such as frown, neutral face, looking away, eyes down, jaw tense. Do NOT write motivations, longing, symbolism, metaphor, subtext, or backstory.
        6. LYRIC/DIALOGUE may inform only visible expression or posture. Never depict singing, microphones, stage performance, or rendered text.
        7. Keep civilians and soldiers visually distinct using the wardrobe/world notes.
        8. Style must stay photorealistic documentary cinema with grounded, period-accurate detail.
        9. Prefer one clear composition over many secondary details.
        10. Never write the words "emotion", "motivation", "charged", "poetic", "dangerous openness", "barrier", or "bond".

        GOOD STYLE EXAMPLE:
        \(goodStyleExample)

        Write the prompt for this exact scene moment:

        \(contextBlock)

        The most important thing is to preserve the authored blocking and who-does-what for shot \(shotIndex + 1), \(moment.rawValue.lowercased()).
        """

        return try await runCodexExec(instruction: instruction)
    }

    /// Diagnostic: generates a prompt with a fixed test instruction. Used to verify
    /// that codex CLI is wired up correctly. Does NOT require a store.
    static func runDiagnosticTest() async throws -> String {
        try await Self.runCodexExecStatic(instruction:
            "Write a one-sentence photorealistic image prompt describing a soldier at dawn. No explanation, just the prompt."
        )
    }

    // MARK: - Codex CLI (GPT 5.4 xhigh)
    //
    // Uses `codex exec` with `--output-last-message` to get clean prompt output
    // without any of the status banner / token count / header noise.
    //
    // Key flags:
    //   --ephemeral              — don't persist a session file
    //   --skip-git-repo-check    — don't require the workdir to be a git repo
    //   --color never            — no ANSI codes in stdout
    //   --sandbox read-only      — prevent the agent from writing anything
    //   --output-last-message    — write the final assistant message to a file
    //
    // This implementation calls codex EXCLUSIVELY. No OpenCode fallback.

    private nonisolated func runCodexExec(instruction: String) async throws -> String {
        try await Self.runCodexExecStatic(instruction: instruction)
    }

    /// Static, fully standalone codex CLI runner — no store dependency.
    /// This is the ONE canonical codex implementation.
    static func runCodexExecStatic(instruction: String) async throws -> String {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Volumes/Storage VIII/Users/gary/.local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex"
        ]
        var codexPath: String?
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            codexPath = c
            break
        }

        // Fall back to `which codex`
        if codexPath == nil {
            let whichProcess = Process()
            whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            whichProcess.arguments = ["codex"]
            var whichEnv = ProcessInfo.processInfo.environment
            whichEnv["PATH"] = "/Volumes/Storage VIII/Users/gary/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin"
            whichProcess.environment = whichEnv
            let pipe = Pipe()
            whichProcess.standardOutput = pipe
            if (try? whichProcess.run()) != nil {
                whichProcess.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let resolved = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !resolved.isEmpty,
                   FileManager.default.fileExists(atPath: resolved) {
                    codexPath = resolved
                }
            }
        }

        guard let resolvedCodex = codexPath else {
            throw PromptError.codexNotFound
        }

        return try await runCodexExec(instruction: instruction, codexPath: resolvedCodex)
    }

    private static func runCodexExec(instruction: String, codexPath: String) async throws -> String {
        // Write the final response to a temp file so we get clean output
        let outputPath = "/tmp/amira-codex-output-\(UUID().uuidString).txt"
        let stdoutPath = "/tmp/amira-codex-stdout-\(UUID().uuidString).txt"
        let stderrPath = "/tmp/amira-codex-stderr-\(UUID().uuidString).txt"
        defer {
            try? FileManager.default.removeItem(atPath: outputPath)
            try? FileManager.default.removeItem(atPath: stdoutPath)
            try? FileManager.default.removeItem(atPath: stderrPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = [
            "-C", "/tmp",
            "-a", "never",
            "-s", "read-only",
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--color", "never",
            "-m", "gpt-5.4",
            "-c", "reasoning_effort=\"xhigh\"",
            "--output-last-message", outputPath,
            instruction
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

        FileManager.default.createFile(atPath: stdoutPath, contents: nil)
        FileManager.default.createFile(atPath: stderrPath, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutPath))
        let stderrHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
        let stdinHandle = FileHandle.nullDevice
        process.standardInput = stdinHandle
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/Volumes/Storage VIII/Users/gary/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        // Ensure HOME is set (codex needs it for session/memory dir even in ephemeral)
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        process.environment = env

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    defer {
                        try? stdoutHandle.close()
                        try? stderrHandle.close()
                    }

                    try process.run()
                    process.waitUntilExit()

                    // Primary path: read the output file
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: outputPath)),
                       let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty {
                        continuation.resume(returning: text)
                        return
                    }

                    // Fallback: scrape stdout for the last codex message
                    let stdoutData = (try? Data(contentsOf: URL(fileURLWithPath: stdoutPath))) ?? Data()
                    let stderrData = (try? Data(contentsOf: URL(fileURLWithPath: stderrPath))) ?? Data()
                    let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        NSLog("[codex] exit \(process.terminationStatus). stderr: \(stderrText.suffix(500))")
                        continuation.resume(throwing: PromptError.codexFailed(exitCode: Int(process.terminationStatus), stderr: String(stderrText.suffix(500))))
                        return
                    }

                    // Extract final response from the stdout stream
                    let cleaned = Self.extractLastCodexMessage(stdoutText)
                    if cleaned.isEmpty {
                        continuation.resume(throwing: PromptError.codexFailed(exitCode: 0, stderr: "Empty output"))
                    } else {
                        continuation.resume(returning: cleaned)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fallback parser for when --output-last-message didn't write.
    /// Codex prints status → "codex\n<response>\ntokens used\n<count>\n<response again>"
    /// We take everything between the LAST "codex\n" and "tokens used\n", or the last line if neither is found.
    private nonisolated static func extractLastCodexMessage(_ stdout: String) -> String {
        if let tokensRange = stdout.range(of: "tokens used", options: .backwards),
           let codexRange = stdout.range(of: "codex\n", options: .backwards, range: stdout.startIndex..<tokensRange.lowerBound) {
            let response = stdout[codexRange.upperBound..<tokensRange.lowerBound]
            return String(response).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Last resort: find last non-metadata line
        let lines = stdout.components(separatedBy: .newlines).reversed()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("tokens used") { continue }
            if trimmed.allSatisfy({ $0.isNumber || $0 == "," }) { continue }
            return trimmed
        }
        return ""
    }

    // MARK: - Pre-filled Prompt (bypass LLM, use template)

    /// Returns a pre-filled prompt based purely on the script context, without calling any LLM.
    /// Useful for manual editing or when you don't want to wait for generation.
    func prefillPrompt(
        scene: AnimationScene,
        shotIndex: Int,
        moment: ImagineShotMoment,
        subjectStyle: SubjectStyle = .loraTokens
    ) -> String {
        guard shotIndex >= 0, shotIndex < scene.shots.count else { return "" }
        let shot = scene.shots[shotIndex]
        let sceneCharacters = orderedSceneCharacters(
            for: scene,
            shot: shot,
            focusSlug: shot.focusCharacterSlug
        )
        let blockingSentence = prefillBlockingSentence(
            shot: shot,
            characters: sceneCharacters,
            moment: moment,
            subjectStyle: subjectStyle
        )

        var detailFragments: [String] = ["photoreal documentary still"]
        if let camera = shot.cameraShot ?? scene.directionTemplate?.defaultCameraShot {
            detailFragments.append(cameraPromptPhrase(for: camera))
        }
        detailFragments.append(environmentPromptPhrase(scene: scene, shot: shot))
        if let clarity = positiveClarityPhrase(for: sceneCharacters.count) {
            detailFragments.append(clarity)
        }

        let detailSentence = sentenceNormalized(
            detailFragments
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )

        return [blockingSentence, detailSentence]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Context Builder (script-direction-driven)

    private func buildContextBlock(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        shotIndex: Int,
        moment: ImagineShotMoment,
        subjectStyle: SubjectStyle
    ) -> String {
        var parts: [String] = []

        // === WORLD CONTEXT ===
        parts.append("WORLD: \(CharacterPromptWorldContext.settingSummary)")
        parts.append("LOCATION: \(CharacterPromptWorldContext.cityClinicEnvironment)")

        let sceneCharacters = orderedSceneCharacters(
            for: scene,
            shot: shot,
            focusSlug: shot.focusCharacterSlug
        )

        // === SCENE-LEVEL DIRECTIONS ===
        if let template = scene.directionTemplate, !template.notes.isEmpty {
            parts.append("SCENE OVERVIEW (from script): \(sanitizedPromptText(template.notes, characters: sceneCharacters, subjectStyle: subjectStyle))")
        }

        // === CHARACTERS — full physical descriptions ===
        let subjectIdentifiers = promptIdentifiers(for: sceneCharacters, subjectStyle: subjectStyle)

        if !sceneCharacters.isEmpty {
            for (index, char) in sceneCharacters.enumerated() {
                let identifier = subjectIdentifiers[index]
                let isFocus = char.owpSlug == shot.focusCharacterSlug
                var desc = isFocus ? "FOCUS SUBJECT TOKEN: \(identifier) — " : "SECONDARY SUBJECT TOKEN: \(identifier) — "

                if !char.description.isEmpty {
                    desc += sanitizedPromptText(char.description, characters: sceneCharacters, subjectStyle: subjectStyle)
                } else {
                    desc += "\(char.genderType.rawValue)"
                    if let age = char.age { desc += ", ~\(age) years old" }
                    let clothing = char.defaultWardrobeType == .soldier
                        ? CharacterPromptWorldContext.militaryClothing
                        : CharacterPromptWorldContext.civilianClothing
                    desc += ". Wearing: \(clothing)"
                }
                parts.append(desc)
            }
        }

        // === SHOT DIRECTIONS ===
        if let camera = shot.cameraShot {
            parts.append("CAMERA (from script): \(camera.rawValue)")
        } else if let defaultCam = scene.directionTemplate?.defaultCameraShot {
            parts.append("CAMERA (scene default): \(defaultCam.rawValue)")
        }

        if let intent = shot.shotIntent {
            parts.append("SHOT INTENT (from script): \(intent.rawValue)")
        }

        if !shot.sourceDirectionTags.isEmpty {
            parts.append("ACTIVE DIRECTION TAGS: \(shot.sourceDirectionTags.joined(separator: ", "))")
        }

        if !shot.notes.isEmpty {
            parts.append("STAGE DIRECTIONS (PRIMARY — FOLLOW LITERALLY): \(sanitizedPromptText(shot.notes, characters: sceneCharacters, subjectStyle: subjectStyle))")
        }

        if let lyric = shot.sourceLyricExcerpt, !lyric.isEmpty {
            parts.append("LYRIC/DIALOGUE AT THIS BEAT: \"\(sanitizedPromptText(lyric, characters: sceneCharacters, subjectStyle: subjectStyle))\" — use only for visible expression or posture, do NOT render as text.")
        }

        // === SURROUNDING SHOTS ===
        let totalShots = scene.shots.count
        parts.append("SHOT \(shotIndex + 1) OF \(totalShots)")

        if shotIndex > 0 {
            let prev = scene.shots[shotIndex - 1]
            var prevDesc = "PREVIOUS SHOT: "
            if let cam = prev.cameraShot { prevDesc += "\(cam.rawValue), " }
            if !prev.notes.isEmpty { prevDesc += sanitizedPromptText(prev.notes, characters: sceneCharacters, subjectStyle: subjectStyle) }
            parts.append(prevDesc)
        }

        if shotIndex < totalShots - 1 {
            let next = scene.shots[shotIndex + 1]
            var nextDesc = "NEXT SHOT: "
            if let cam = next.cameraShot { nextDesc += "\(cam.rawValue), " }
            if !next.notes.isEmpty { nextDesc += sanitizedPromptText(next.notes, characters: sceneCharacters, subjectStyle: subjectStyle) }
            parts.append(nextDesc)
        }

        // === MOMENT ===
        switch moment {
        case .beginning:
            parts.append("TEMPORAL MOMENT: BEGINNING of this shot's action. Show the opening state.")
        case .middle:
            parts.append("TEMPORAL MOMENT: MIDDLE/PEAK of this shot's action. Full intensity.")
        case .end:
            parts.append("TEMPORAL MOMENT: END of this shot's action. Resolution/transition.")
        }

        // === STYLE ===
        parts.append("STYLE TARGET: Photorealistic cinematic documentary photography with grounded, period-accurate Afghanistan detail, natural skin texture, clean unmarked surfaces, and realistic wardrobe.")

        return parts.joined(separator: "\n")
    }

    private func orderedSceneCharacters(
        for scene: AnimationScene,
        shot: AnimationSceneShot,
        focusSlug: String?
    ) -> [AnimationCharacter] {
        let searchableContext = [
            shot.name,
            shot.notes,
            shot.sourceLyricExcerpt ?? "",
            scene.directionTemplate?.notes ?? ""
        ]
        .joined(separator: "\n")

        let sceneCharacters = store.characters.filter {
            scene.characterSlugs.contains($0.owpSlug) ||
            $0.owpSlug == focusSlug ||
            characterIsMentioned($0, in: searchableContext)
        }
        guard let focusSlug else { return sceneCharacters }
        return sceneCharacters.sorted { lhs, rhs in
            if lhs.owpSlug == focusSlug { return true }
            if rhs.owpSlug == focusSlug { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func characterIsMentioned(
        _ character: AnimationCharacter,
        in text: String
    ) -> Bool {
        promptTokens(for: character).contains {
            DrawThingsPromptIdentityInjector.containsPromptToken($0, in: text)
        }
    }

    private func promptTokens(
        for character: AnimationCharacter
    ) -> [String] {
        var seen: Set<String> = []
        let filenameStem = character.activeLORAFilename.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        } ?? ""
        let tokens = [
            character.name,
            character.name.split(separator: " ").first.map(String.init) ?? "",
            character.owpSlug,
            character.activeLORATriggerWord ?? "",
            filenameStem
        ]
        return tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func promptIdentifiers(
        for characters: [AnimationCharacter],
        subjectStyle: SubjectStyle
    ) -> [String] {
        let baseIdentifiers = characters.enumerated().map { index, character in
            promptIdentifier(
                for: character,
                ordinal: index + 1,
                subjectStyle: subjectStyle
            )
        }
        var duplicateCounts: [String: Int] = [:]
        for identifier in baseIdentifiers {
            duplicateCounts[identifier, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        return baseIdentifiers.enumerated().map { index, identifier in
            guard duplicateCounts[identifier, default: 0] > 1 else { return identifier }
            seen[identifier, default: 0] += 1
            return "\(identifier)-\(seen[identifier] ?? (index + 1))"
        }
    }

    private func promptIdentifier(
        for character: AnimationCharacter,
        ordinal: Int,
        subjectStyle: SubjectStyle
    ) -> String {
        if subjectStyle == .neutralSubjects {
            return "subject_\(ordinal)"
        }

        if let trigger = character.activeLORATriggerWord?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !trigger.isEmpty {
            return trigger
        }

        if let filename = character.activeLORAFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !filename.isEmpty {
            return URL(fileURLWithPath: filename)
                .deletingPathExtension()
                .lastPathComponent
        }

        let base: String
        if character.defaultWardrobeType == .soldier {
            base = character.genderType == .female ? "female-soldier" : "male-soldier"
        } else {
            switch character.genderType {
            case .female:
                base = "woman"
            case .male:
                base = "man"
            default:
                base = "person"
            }
        }
        return "\(base)-\(ordinal)"
    }

    private func sanitizedPromptText(
        _ text: String,
        characters: [AnimationCharacter],
        subjectStyle: SubjectStyle
    ) -> String {
        let identifiers = promptIdentifiers(for: characters, subjectStyle: subjectStyle)
        var updated = text
        for (index, character) in characters.enumerated() {
            let replacement = identifiers[index]
            for token in promptTokens(for: character) {
                updated = replacePromptToken(
                    token,
                    with: replacement,
                    in: updated
                )
            }
        }
        return updated
    }

    private func replacePromptToken(
        _ token: String,
        with replacement: String,
        in prompt: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return prompt
        }

        let nsRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        return regex.stringByReplacingMatches(
            in: prompt,
            options: [],
            range: nsRange,
            withTemplate: replacement
        )
    }

    private func prefillBlockingSentence(
        shot: AnimationSceneShot,
        characters: [AnimationCharacter],
        moment: ImagineShotMoment,
        subjectStyle: SubjectStyle
    ) -> String {
        let identifiers = promptIdentifiers(for: characters, subjectStyle: subjectStyle)
        let stageDirections = sanitizedPromptText(
            cleanedVisualBeat(from: shot),
            characters: characters,
            subjectStyle: subjectStyle
        )

        if !stageDirections.isEmpty {
            let alreadyNamesCharacters = identifiers.contains {
                DrawThingsPromptIdentityInjector.containsPromptToken($0, in: stageDirections)
            }
            if alreadyNamesCharacters || identifiers.isEmpty {
                return sentenceNormalized(stageDirections)
            }
            return sentenceNormalized("\(subjectList(identifiers)), \(stageDirections)")
        }

        if !identifiers.isEmpty {
            let momentLead: String
            switch moment {
            case .beginning:
                momentLead = "at the opening beat"
            case .middle:
                momentLead = "at the peak of the action"
            case .end:
                momentLead = "at the closing beat"
            }
            return "\(subjectList(identifiers)) in frame \(momentLead)."
        }

        return "Photoreal scene frame."
    }

    private func cleanedVisualBeat(
        from shot: AnimationSceneShot
    ) -> String {
        let candidates = [
            shot.notes,
            shot.sourceLyricExcerpt ?? "",
            shot.name
        ]

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let leadingClause = trimmed
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
            guard !leadingClause.isEmpty else { continue }
            return leadingClause
        }

        return ""
    }

    private func cameraPromptPhrase(
        for camera: CameraShot
    ) -> String {
        switch camera {
        case .extremeWide:
            return "extreme-wide frame with clear left-to-right geography"
        case .wide:
            return "wide eye-level frame with readable blocking"
        case .medium:
            return "medium frame with readable posture and eyelines"
        case .mediumClose:
            return "medium-close frame with both faces clearly readable"
        case .close:
            return "close frame with controlled intimacy and realistic facial detail"
        case .extremeClose:
            return "extreme close-up with precise focus on the key detail"
        }
    }

    private func environmentPromptPhrase(
        scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> String {
        if let anchor = extractedSceneAnchor(from: shot.shotFrameGeneration?.animationStyleNotes ?? "") {
            return "\(anchor), grounded practical light and realistic environmental texture"
        }

        let sceneOverview = scene.directionTemplate?.notes
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sceneOverview.isEmpty {
            let clause = sceneOverview
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? sceneOverview
            return "\(clause), grounded practical light and realistic props"
        }

        return "early-2000s Afghanistan realism with practical light and authentic environmental detail"
    }

    private func positiveClarityPhrase(
        for characterCount: Int
    ) -> String? {
        switch characterCount {
        case ..<1:
            return nil
        case 1:
            return "one fully visible person with a clear body silhouette and unobstructed face"
        default:
            return "\(characterCount) fully visible people with clear separation, distinct posture, and unobstructed faces"
        }
    }

    private func extractedSceneAnchor(
        from animationStyleNotes: String
    ) -> String? {
        guard let range = animationStyleNotes.range(of: "Scene anchor:") else {
            return nil
        }
        let tail = animationStyleNotes[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }

        let rawAnchor = tail
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawAnchor.isEmpty else { return nil }

        return rawAnchor
            .replacingOccurrences(of: "/", with: ", ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func subjectList(
        _ items: [String]
    ) -> String {
        switch items.count {
        case 0:
            return ""
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head), and \(items.last ?? "")"
        }
    }

    private func sentenceNormalized(
        _ text: String
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
            return trimmed
        }
        return "\(trimmed)."
    }

    enum PromptError: LocalizedError {
        case invalidShot
        case codexNotFound
        case codexFailed(exitCode: Int, stderr: String)

        var errorDescription: String? {
            switch self {
            case .invalidShot:
                return "Invalid shot index."
            case .codexNotFound:
                return "Codex CLI not found. Install from https://github.com/openai/codex-cli or add to PATH."
            case .codexFailed(let code, let stderr):
                return "Codex exit \(code): \(stderr.isEmpty ? "no output" : stderr)"
            }
        }
    }
}
