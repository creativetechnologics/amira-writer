import Foundation

/// Generates image-generation prompts for scene shots via OpenAI Responses API,
/// falling back to GPT 5.4 xhigh (codex CLI) when no OpenAI key is configured.
///
/// Archived: MiniMax M2.7 implementation removed 2026-04-05 — replaced with GPT 5.4 xhigh
/// via `codex exec` for higher quality scene-aware prompts.
@available(macOS 26.0, *)
@MainActor
final class ImagineScenePromptService {
    enum SubjectStyle: Sendable {
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
        subjectStyle: SubjectStyle = .neutralSubjects
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
        let workflowMode = "for the Scenes imagine begin/middle/end triplet workflow"
        let styleExamplesBlock = successfulPromptExamples()
        let existingTripletBlock = buildExistingTripletPromptBlock(sceneID: scene.id, shotIndex: shotIndex)

        let instruction = """
        You are writing production image prompts for GPT Image / Nano Banana shot-frame generation \(workflowMode).

        TARGET QUALITY:
        - Match the caliber and specificity of the approved prompts Gary liked from the May 2 Overture image pass.
        - These are not captions. They are full image-generation prompts with enough cinematic, geographic, lighting, object, and style detail to make a strong first frame without further project memory.
        - The final prompt should feel authored by a film production designer and cinematographer, not summarized by a metadata parser.

        WORKFLOW MODEL:
        - Each shot belongs to a prompt triplet: Beginning, Middle, End.
        - These are three continuity-locked stills from the SAME shot.
        - Keep camera placement, lens feel, framing logic, screen direction, geography, lighting, wardrobe logic, and subject identity consistent across the triplet.
        - Only change the visible beat inside the frame for the selected moment.

        OUTPUT FORMAT:
        - Return ONLY the final prompt text.
        - Use one polished image-generation prompt, usually one compact paragraph.
        - 110 to 240 words total unless the shot is a very simple insert.
        - No bullets, no labels, no markdown, no JSON.

        PROMPT RECIPE:
        1. Start with "Create..." plus the scene/shot/moment and the target look.
        2. State aspect/framing and camera placement or movement.
        3. Lock continuity from the surrounding shot sequence.
        4. Describe the visible geography, room, vehicle, props, or characters in concrete detail.
        5. Describe light, atmosphere, palette, and physical materials.
        6. End with a compact "No..." guardrail list that blocks the most likely wrong additions.

        STYLE RULES:
        - Start with the exact camera/framing and the main visible geography or action.
        - Then add the setting, screen direction, light, atmosphere, wardrobe/vehicle/prop details only when they are actually in this shot.
        - Keep it literal, visual, and production-ready.
        - Front-load the most important visual information.
        - Use plain descriptive language, not screenplay language.
        - Use positive framing only.

        ABSOLUTE RULES:
        1. The STAGE DIRECTIONS field is the highest priority. Follow it literally.
        2. Do not output placeholder labels such as subject_1, subject_2, person_1, or character names unless the context provides an actual visible named character for this shot.
        3. This prompt must stay inside the SAME SHOT as the companion moments. Do NOT invent a new angle, reverse angle, lens change, location change, time-of-day change, or subject swap.
        4. If the stage directions imply screen-left, screen-right, foreground, background, facing left, or facing right, keep those directions explicit in the prompt.
        5. Give each visible character one distinct physical action clause.
        6. Use only visible expression words such as frown, neutral face, looking away, eyes down, jaw tense. Do NOT write motivations, longing, symbolism, metaphor, subtext, or backstory.
        7. LYRIC/DIALOGUE may inform only visible expression or posture. Never depict singing, microphones, stage performance, or rendered text.
        8. Keep civilians and soldiers visually distinct using the wardrobe/world notes.
        9. Style must stay as a mature, clean, animated cinematic production frame with grounded, period-accurate Afghanistan detail. Avoid cartoonish, cute, chibi, glossy 3D, and generic Hollywood war-zone styling.
        10. Beginning = opening readable state. Middle = peak readable state. End = resolved readable state.
        11. If companion prompts already exist, stay compatible with them and only advance the beat for the selected moment.
        12. Never write the words "emotion", "motivation", "charged", "poetic", "dangerous openness", "barrier", or "bond".
        13. Never introduce a bridge, clinic, doorway, city street, Humvee interior, character, or vehicle unless the current shot context explicitly says it is visible.
        14. If the context contains a LEARNED VISUAL CANON block, treat it as Gary-approved override guidance when old shot data disagrees with it.

        APPROVED STYLE EXAMPLES:
        \(styleExamplesBlock)

        Write the prompt for this exact scene moment:

        \(contextBlock)

        \(existingTripletBlock)

        The most important thing is to preserve the authored shot description and the exact scene geography for shot \(shotIndex + 1), \(moment.rawValue.lowercased()).
        """

        return try await generateAndRepairPromptIfNeeded(
            instruction: instruction,
            scene: scene,
            shot: shot,
            shotIndex: shotIndex,
            moment: moment
        )
    }

    /// Diagnostic: generates a prompt with a fixed test instruction. Used to verify
    /// that codex CLI is wired up correctly. Does NOT require a store.
    static func runDiagnosticTest() async throws -> String {
        try await Self.runCodexExecStatic(instruction:
            "Write a one-sentence photorealistic image prompt describing a soldier at dawn. No explanation, just the prompt."
        )
    }

    private func generateAndRepairPromptIfNeeded(
        instruction: String,
        scene: AnimationScene,
        shot: AnimationSceneShot,
        shotIndex: Int,
        moment: ImagineShotMoment
    ) async throws -> String {
        let first = try await completePromptInstruction(instruction)
        let cleanedFirst = cleanedLLMPromptOutput(first)
        let failures = promptQualityFailures(
            cleanedFirst,
            scene: scene,
            shot: shot,
            shotIndex: shotIndex
        )
        guard !failures.isEmpty else { return cleanedFirst }

        let repairInstruction = """
        \(instruction)

        The previous output failed these quality checks:
        \(failures.map { "- \($0)" }.joined(separator: "\n"))

        Previous output:
        \(cleanedFirst)

        Rewrite it now. Return ONLY the final prompt. Make it as specific and cinematic as the approved style examples. Do not mention these checks.
        """
        let repaired = try await completePromptInstruction(repairInstruction)
        let cleanedRepaired = cleanedLLMPromptOutput(repaired)
        return cleanedRepaired.isEmpty ? cleanedFirst : cleanedRepaired
    }

    private func completePromptInstruction(_ instruction: String) async throws -> String {
        let openAIKey = store.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !openAIKey.isEmpty {
            return try await OpenAITextGenerationService().generateText(
                instruction: instruction,
                apiKey: openAIKey
            )
        }

        return try await runCodexExec(instruction: instruction)
    }

    private func promptQualityFailures(
        _ prompt: String,
        scene: AnimationScene,
        shot: AnimationSceneShot,
        shotIndex: Int
    ) -> [String] {
        let lower = prompt.lowercased()
        var failures: [String] = []

        if promptWordCount(prompt) < 85 {
            failures.append("The prompt is too short and lacks production-design detail.")
        }
        if lower.range(of: #"\b(subject|person|character)_\d+\b"#, options: .regularExpression) != nil {
            failures.append("The prompt still contains placeholder subject tokens.")
        }
        if !contextAllowsClinic(scene: scene, shot: shot), lower.contains("clinic") {
            failures.append("The prompt invents a clinic or clinic street not present in this shot.")
        }
        if !contextAllowsHumveeInterior(shot: shot),
           (
            lower.contains("humvee interior") ||
            lower.contains("inside a dusty early-2000s humvee") ||
            lower.contains("inside the same dusty")
           ) {
            failures.append("The prompt invents a Humvee interior not present in this shot.")
        }
        if isOvertureOpeningBeforeBridge(scene: scene, shot: shot, shotIndex: shotIndex),
           lower.contains("bridge"),
           !lower.contains("no bridge") {
            failures.append("The prompt shows the bridge too early in the Overture.")
        }
        if !lower.contains("animated") && !lower.contains("2d") && !lower.contains("anime") {
            failures.append("The prompt does not lock the approved animated production-design style.")
        }

        return failures
    }

    private func promptWordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func cleanedLLMPromptOutput(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```text", with: "")
                .replacingOccurrences(of: "```markdown", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let forbiddenPrefixes = ["Prompt:", "Final prompt:", "Image prompt:"]
        for prefix in forbiddenPrefixes where text.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func contextAllowsClinic(scene: AnimationScene, shot: AnimationSceneShot) -> Bool {
        let context = [
            scene.name,
            sceneDisplayName(scene),
            shot.name,
            shot.notes,
            shot.sourceLyricExcerpt ?? "",
            scene.directionTemplate?.notes ?? ""
        ].joined(separator: "\n").lowercased()
        return context.contains("clinic")
    }

    private func contextAllowsHumveeInterior(shot: AnimationSceneShot) -> Bool {
        let context = [
            shot.name,
            shot.notes,
            shot.sourceLyricExcerpt ?? "",
            shot.shotFrameGeneration?.animationStyleNotes ?? ""
        ].joined(separator: "\n").lowercased()
        return context.contains("humvee") || context.contains("cabin") || context.contains("driver") || context.contains("passenger seat") || context.contains("back row")
    }

    private func isOvertureOpeningBeforeBridge(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        shotIndex: Int
    ) -> Bool {
        guard sceneDisplayName(scene).localizedCaseInsensitiveContains("Overture") ||
                scene.name.localizedCaseInsensitiveContains("Overture") else {
            return false
        }
        if shot.name.localizedCaseInsensitiveContains("bridge") {
            return false
        }
        return shotIndex < 6
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
        subjectStyle: SubjectStyle = .neutralSubjects
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
        parts.append("WORLD: \(CharacterPromptWorldContext.amiraWorldAnchor)")
        parts.append("SCENE NAME: \(sceneDisplayName(scene))")
        parts.append("LOCATION / PLACE CONTEXT: \(locationContext(scene: scene, shot: shot))")
        if let canon = learnedVisualCanon(scene: scene, shot: shot, shotIndex: shotIndex) {
            parts.append("LEARNED VISUAL CANON (GARY-APPROVED OVERRIDE): \(canon)")
        }

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
            parts.append("TEMPORAL MOMENT: BEGINNING of this shot's action. Show the opening readable state while preserving the locked shot geography.")
        case .middle:
            parts.append("TEMPORAL MOMENT: MIDDLE/PEAK of this shot's action. Show the clearest peak beat while preserving the same shot.")
        case .end:
            parts.append("TEMPORAL MOMENT: END of this shot's action. Show the resolved closing readable state while preserving the same shot.")
        }

        // === STYLE ===
        parts.append("STYLE TARGET: mature animated feature-film still, cinematic painterly realism, grounded early-2000s Afghanistan detail, clean unmarked surfaces, realistic wardrobe/vehicles/architecture when present, continuity-locked shot framing.")

        return parts.joined(separator: "\n")
    }

    private func successfulPromptExamples() -> String {
        """
        Example A — empty opening geography:
        Create a cinematic opening-establishing shot for an animated opera in a grounded premium 2D animated production-design style. Wide 16:9 landscape. Same geography as the previous shot, but the camera is much farther away, higher in the sky like a quiet drone, and slightly farther back. Viewpoint faces west, away from the sunrise; the unseen sunrise is behind the viewer, giving the valley ahead low early dawn back-wash, pale rim light, and long soft shadows stretching westward. A vast dry mountain valley fills the frame, with a cold river cutting through the valley floor below. No bridge is visible anywhere. A narrow dusty gravel and compacted-earth road climbs along the valley side, but there are no vehicles yet and no people anywhere. The road should be readable as the future route into the valley: dusty ruts, eroded shoulders, scrub brush, exposed stones, and pale dawn dust. No vehicles, no trucks, no Humvees, no bridge, no modern city, no asphalt highway, no futuristic technology, no tanks, no heroic action-poster composition, no foreground people, no readable text, no logos, no 3D render, no photorealism.

        Example B — exterior convoy geography:
        Create a cinematic opening shot for an animated opera in a grounded premium 2D animated production-design style. Wide 16:9 landscape. Viewpoint faces west, away from the sunrise; the unseen sunrise is behind the viewer, so the valley ahead is lit by low early dawn back-wash and long soft shadows moving westward. A vast dry mountain valley stretches into the distance, with a cold river cutting through the valley floor below. No bridge is visible anywhere. A narrow dusty gravel and compacted-earth road climbs along the valley side, and three practical early-2000s dusty Humvees/trucks are coming up the road toward the ridge, small in the composition but clearly readable. The world feels fictional early-2000s highland war zone: scrub brush, exposed stones, tire ruts, eroded shoulders, dust hanging low, muted dawn palette, documentary restraint. No modern city, no asphalt highway, no steel bridge, no stone bridge, no futuristic military tech, no tanks, no heroic action-poster composition, no people in foreground, no readable text, no logos, no 3D render, no photorealism.

        Example C — Humvee interior:
        Create Overture first frame for an animated opera in a grounded premium 2D animated production-design style. Wide 16:9 cinematic frame. Cut inside a dusty early-2000s Humvee climbing the mountain valley road before dawn. Medium shot of a tired young military medic/passenger writing in a notebook against the dirty narrow Humvee window. The cabin is cramped, worn, brown and utilitarian: scratched metal, canvas straps, analog radio cable, paper map edges, scuffed seat fabric, dust on every surface. Outside the window only blurred dawn valley slope and road dust are visible, no bridge. Light comes from cold pre-dawn haze and faint vehicle/headlight glow, with muted blue-gold rim light. Serious documentary restraint, hand-painted animated background quality, not photorealistic. No touchscreen, no modern SUV, no luxury interior, no logos, no readable text, no action-poster drama, no 3D render.
        """
    }

    private func learnedVisualCanon(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        shotIndex: Int
    ) -> String? {
        guard sceneDisplayName(scene).localizedCaseInsensitiveContains("Overture") ||
                scene.name.localizedCaseInsensitiveContains("Overture") else {
            return nil
        }

        let lowerShotName = shot.name.lowercased()
        var lines: [String] = [
            "Overture opening visual language is grounded premium 2D animated production design, not photorealism.",
            "The early valley/road/cabin sequence faces west away from the sunrise when outside; the unseen sunrise is behind the viewer, giving low dawn back-wash, pale rim light, muted dust, and long soft shadows.",
            "Do not show the bridge until a shot explicitly asks for the bridge crossing motif or a later valley-overlook shot needs it. Early road and Humvee-cabin shots should say no bridge visible."
        ]

        if lowerShotName.contains("valley") && !lowerShotName.contains("convoy") {
            lines.append("For the opening valley-establishing beat, prioritize a high-wide empty valley with river and road; no vehicles and no people unless the shot note explicitly says they have entered.")
        }
        if lowerShotName.contains("convoy") || lowerShotName.contains("road") {
            lines.append("For convoy-road beats, show three practical early-2000s dusty Humvees/trucks as small, grounded vehicles on a narrow gravel and compacted-earth mountain road; avoid heroic action-poster framing.")
        }
        if contextAllowsHumveeInterior(shot: shot) {
            lines.append("For Humvee-cabin beats, use a cramped dusty early-2000s military vehicle interior with analog radio gear, canvas straps, scuffed metal, dirty windows, paper maps or notebooks, and blurred dawn valley slope outside.")
        }
        if lowerShotName.contains("bridge") || shotIndex >= 6 {
            lines.append("If this shot explicitly reaches the bridge motif, the bridge may appear as the required story geography; keep it old, stone, distant or grounded, never a modern steel bridge.")
        }

        return lines.joined(separator: " ")
    }

    private func buildExistingTripletPromptBlock(
        sceneID: UUID,
        shotIndex: Int
    ) -> String {
        guard let gallery = store.imagineGallery(for: sceneID, shotIndex: shotIndex) else {
            return "EXISTING STORED SHOT TRIPLET PROMPTS: none"
        }

        let entries = ImagineShotMoment.allCases.compactMap { moment -> String? in
            let prompt = gallery.prompt(for: moment).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            return "\(moment.rawValue.uppercased()): \(prompt)"
        }

        guard !entries.isEmpty else {
            return "EXISTING STORED SHOT TRIPLET PROMPTS: none"
        }

        return "EXISTING STORED SHOT TRIPLET PROMPTS:\n" + entries.joined(separator: "\n")
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
            Self.containsPromptToken($0, in: text)
        }
    }

    private static func containsPromptToken(_ token: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text.localizedCaseInsensitiveContains(token)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func promptTokens(
        for character: AnimationCharacter
    ) -> [String] {
        var seen: Set<String> = []
        let tokens = [
            character.name,
            character.name.split(separator: " ").first.map(String.init) ?? "",
            character.owpSlug
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
        switch subjectStyle {
        case .neutralSubjects:
            let trimmedName = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                return trimmedName
            }
            return "visible person \(ordinal)"
        }
    }

    private func sceneDisplayName(_ scene: AnimationScene) -> String {
        let stem = URL(fileURLWithPath: scene.owpSongPath).deletingPathExtension().lastPathComponent
        return stem.isEmpty ? scene.name : stem
    }

    private func locationContext(
        scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> String {
        var fragments: [String] = []

        if let backgroundID = scene.backgroundID,
           let place = store.backgrounds.first(where: { $0.id == backgroundID }) {
            let placeFields = [
                place.name,
                place.visualBrief,
                place.coreIdentity,
                place.geographicPlacement,
                place.physicalLayoutAndTopography,
                place.visualContinuityAnchors,
                place.cameraFramingNotes,
                place.imageGenerationGuardrails
            ]
            for field in placeFields {
                let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    fragments.append(trimmed)
                }
            }
        }

        let shotHints = [
            shot.name,
            shot.notes,
            shot.sourceLyricExcerpt ?? "",
            shot.shotFrameGeneration?.animationStyleNotes ?? ""
        ]
        for hint in shotHints {
            let cleaned = hint
                .replacingOccurrences(of: "Seeded from script line \\d+ · ", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                fragments.append(cleaned)
            }
        }

        let deduped = dedupePromptFragments(fragments)
        if deduped.isEmpty {
            return CharacterPromptWorldContext.settingSummary
        }
        return deduped.prefix(8).joined(separator: " | ")
    }

    private func dedupePromptFragments(_ fragments: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for fragment in fragments {
            let collapsed = fragment
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let key = collapsed.lowercased()
            guard !collapsed.isEmpty, seen.insert(key).inserted else { continue }
            result.append(collapsed)
        }
        return result
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
                Self.containsPromptToken($0, in: stageDirections)
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
