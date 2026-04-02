import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class LLMAnimationPlanGeneratorTests: XCTestCase {

    // MARK: - Prompt Content

    func testPromptContainsCharacterInfo() {
        let context = LLMAnimationPlanGenerator.SceneContext(
            sceneText: "Luke enters the room and speaks to Amira.",
            characters: [
                .init(name: "Luke", slug: "luke", description: "A young soldier"),
                .init(name: "Amira", slug: "amira", description: "A healer"),
            ],
            sceneName: "Act 1 Scene 3",
            durationBars: 16,
            fps: 24,
            stageWidth: 4.0,
            stageDepth: 3.0
        )

        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)

        XCTAssertTrue(prompt.contains("Luke"), "Prompt should mention character Luke")
        XCTAssertTrue(prompt.contains("Amira"), "Prompt should mention character Amira")
        XCTAssertTrue(prompt.contains("luke"), "Prompt should include Luke's slug")
        XCTAssertTrue(prompt.contains("young soldier"), "Prompt should include Luke's description")
        XCTAssertTrue(prompt.contains("healer"), "Prompt should include Amira's description")
        XCTAssertTrue(prompt.contains("Act 1 Scene 3"), "Prompt should include the scene name")
        XCTAssertTrue(prompt.contains("24"), "Prompt should include FPS")
    }

    func testPromptContainsExpressionPresets() {
        let context = makeMinimalContext()
        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)

        // Core emotion presets should be listed so the LLM uses correct identifiers.
        XCTAssertTrue(prompt.contains("joy"), "Prompt should list expression: joy")
        XCTAssertTrue(prompt.contains("determined"), "Prompt should list expression: determined")
        XCTAssertTrue(prompt.contains("bittersweet"), "Prompt should list expression: bittersweet")
        XCTAssertTrue(prompt.contains("neutral"), "Prompt should list expression: neutral")
        XCTAssertTrue(prompt.contains("nervousExcitement"), "Prompt should list expression: nervousExcitement")
    }

    func testPromptContainsCorrectEasingValues() {
        let context = makeMinimalContext()
        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)

        // Must use underscore format that matches LLMAnimationEasing raw values.
        XCTAssertTrue(prompt.contains("ease_in_out"), "Prompt should use ease_in_out (underscore) not easeInOut")
        XCTAssertTrue(prompt.contains("ease_in"), "Prompt should list ease_in")
        XCTAssertTrue(prompt.contains("ease_out"), "Prompt should list ease_out")
        XCTAssertTrue(prompt.contains("linear"), "Prompt should list linear")
        XCTAssertTrue(prompt.contains("stepped"), "Prompt should list stepped")
    }

    func testPromptContainsCorrectCameraMovementValues() {
        let context = makeMinimalContext()
        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)

        // Must use underscore format that matches CameraMovement raw values.
        XCTAssertTrue(prompt.contains("zoom_in"), "Prompt should list zoom_in")
        XCTAssertTrue(prompt.contains("pan_left"), "Prompt should list pan_left")
        XCTAssertTrue(prompt.contains("hold"), "Prompt should list hold")
    }

    func testPromptContainsCorrectCameraShotValues() {
        let context = makeMinimalContext()
        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)

        // Must use underscore format that matches CameraShot raw values.
        XCTAssertTrue(prompt.contains("extreme_wide"), "Prompt should list extreme_wide")
        XCTAssertTrue(prompt.contains("medium_close"), "Prompt should list medium_close")
        XCTAssertTrue(prompt.contains("extreme_close"), "Prompt should list extreme_close")
    }

    func testPromptContainsCorrectFacingValues() {
        let context = makeMinimalContext()
        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)

        XCTAssertTrue(prompt.contains("\"camera\""), "Prompt should list facing: camera")
        XCTAssertTrue(prompt.contains("\"away\""), "Prompt should list facing: away")
        XCTAssertTrue(prompt.contains("\"left\""), "Prompt should list facing: left")
        XCTAssertTrue(prompt.contains("\"right\""), "Prompt should list facing: right")
    }

    func testPromptIncludesStageConstraints() {
        let context = LLMAnimationPlanGenerator.SceneContext(
            sceneText: "Test",
            characters: [],
            sceneName: "Test",
            durationBars: nil,
            fps: 30,
            stageWidth: 5.0,
            stageDepth: 4.0
        )

        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)
        XCTAssertTrue(prompt.contains("5.0m wide"), "Prompt should include stage width")
        XCTAssertTrue(prompt.contains("4.0m deep"), "Prompt should include stage depth")
    }

    func testPromptIncludesDurationWhenProvided() {
        let context = LLMAnimationPlanGenerator.SceneContext(
            sceneText: "Test",
            characters: [],
            sceneName: "Test",
            durationBars: 32,
            fps: 24,
            stageWidth: 4.0,
            stageDepth: 3.0
        )

        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)
        XCTAssertTrue(prompt.contains("32"), "Prompt should include bar count when provided")
    }

    func testPromptOmitsDurationWhenAbsent() {
        let context = LLMAnimationPlanGenerator.SceneContext(
            sceneText: "Test",
            characters: [],
            sceneName: "Test",
            durationBars: nil,
            fps: 24,
            stageWidth: 4.0,
            stageDepth: 3.0
        )

        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)
        XCTAssertFalse(prompt.contains("Duration:"), "Prompt should omit Duration line when nil")
    }

    func testPromptContainsSceneText() {
        let sceneText = "The soldiers march across the dusty plain."
        let context = LLMAnimationPlanGenerator.SceneContext(
            sceneText: sceneText,
            characters: [],
            sceneName: "March",
            durationBars: nil,
            fps: 24,
            stageWidth: 4.0,
            stageDepth: 3.0
        )

        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)
        XCTAssertTrue(prompt.contains(sceneText), "Prompt should include the scene text verbatim")
    }

    func testPromptIncludesSchemaVersion() {
        let context = makeMinimalContext()
        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)

        // Schema version 8 is LLMAnimationPlan.currentSchemaVersion
        XCTAssertTrue(prompt.contains("\"schemaVersion\": 8"), "Prompt should declare the current schema version")
    }

    func testPromptIncludesFieldNamesMatchingCompiler() {
        let context = makeMinimalContext()
        let prompt = LLMAnimationPlanGenerator.buildPrompt(context: context)

        // These must match the CodingKeys in LLMAnimationPlan exactly.
        XCTAssertTrue(prompt.contains("characterPlacements"), "Prompt should reference characterPlacements")
        XCTAssertTrue(prompt.contains("motions"), "Prompt should reference motions")
        XCTAssertTrue(prompt.contains("expressions"), "Prompt should reference expressions")
        XCTAssertTrue(prompt.contains("dialogueBeats"), "Prompt should reference dialogueBeats")
        XCTAssertTrue(prompt.contains("cameraMoves"), "Prompt should reference cameraMoves")
        XCTAssertTrue(prompt.contains("objectPlacements"), "Prompt should reference objectPlacements")
        XCTAssertTrue(prompt.contains("shotPresetApplications"), "Prompt should reference shotPresetApplications")
    }

    // MARK: - JSON Extraction

    func testExtractJSONFromCleanJSON() {
        let json = "{\"test\": true}"
        let result = LLMAnimationPlanGenerator.extractJSON(from: json)
        XCTAssertEqual(result, json, "Clean JSON should be returned as-is")
    }

    func testExtractJSONFromMarkdownFence() {
        let json = "{\"test\": true}"
        let fenced = "```json\n\(json)\n```"
        let result = LLMAnimationPlanGenerator.extractJSON(from: fenced)
        XCTAssertEqual(result, json, "JSON should be extracted from markdown fences")
    }

    func testExtractJSONFromJsonFenceUpperCase() {
        let json = "{\"test\": true}"
        let fenced = "```JSON\n\(json)\n```"
        let result = LLMAnimationPlanGenerator.extractJSON(from: fenced)
        XCTAssertEqual(result, json, "JSON should be extracted from uppercase JSON fence")
    }

    func testExtractJSONFromBareCodeFence() {
        let json = "{\"test\": true}"
        let fenced = "```\n\(json)\n```"
        let result = LLMAnimationPlanGenerator.extractJSON(from: fenced)
        XCTAssertEqual(result, json, "JSON should be extracted from bare code fences")
    }

    func testExtractJSONFromTextWithSurroundingProse() {
        let json = "{\"test\": true}"
        let text = "Here is the JSON:\n\(json)\n\nThat's the result."
        let result = LLMAnimationPlanGenerator.extractJSON(from: text)
        XCTAssertEqual(result, json, "JSON should be extracted from surrounding prose via brace scanning")
    }

    func testExtractJSONFromInvalidTextReturnsEmpty() {
        let result = LLMAnimationPlanGenerator.extractJSON(from: "This is not JSON at all.")
        XCTAssertEqual(result, "", "Non-JSON text should return empty string")
    }

    func testExtractJSONFromEmptyStringReturnsEmpty() {
        let result = LLMAnimationPlanGenerator.extractJSON(from: "")
        XCTAssertEqual(result, "", "Empty input should return empty string")
    }

    func testExtractedJSONIsValidForParsing() {
        // Verify that JSON matching the LLMAnimationPlan schema can round-trip through the compiler.
        let json = """
        {
          "schemaVersion": 8,
          "sceneName": "Test Scene",
          "characterPlacements": [
            {
              "characterName": "Luke",
              "frame": 0,
              "position": { "x": 0.3, "y": 0.56 },
              "facing": "right",
              "emotion": "neutral"
            }
          ],
          "motions": [],
          "expressions": [],
          "dialogueBeats": [],
          "cameraMoves": [],
          "objectPlacements": [],
          "objectMotions": [],
          "shadowCues": [],
          "objectStateCues": [],
          "shotPresetApplications": [],
          "notes": []
        }
        """

        let extracted = LLMAnimationPlanGenerator.extractJSON(from: json)
        XCTAssertFalse(extracted.isEmpty, "Valid JSON should be extracted successfully")

        let compiler = LLMAnimationPlanCompiler()
        XCTAssertNoThrow(try compiler.parse(json: extracted), "Extracted JSON should parse without error")
    }

    func testExtractedJSONWithMotionsAndCameraMoveParsesCorrectly() {
        let json = """
        {
          "schemaVersion": 8,
          "sceneName": "March Scene",
          "characterPlacements": [
            {
              "characterName": "Luke",
              "frame": 0,
              "position": { "x": 0.2, "y": 0.56 },
              "facing": "camera",
              "emotion": "determined"
            }
          ],
          "motions": [
            {
              "characterName": "Luke",
              "startFrame": 24,
              "endFrame": 72,
              "from": { "x": 0.2, "y": 0.56 },
              "to": { "x": 0.7, "y": 0.56 },
              "easing": "ease_in_out",
              "facing": "right",
              "movementStyle": "walk"
            }
          ],
          "expressions": [
            {
              "characterName": "Luke",
              "frame": 72,
              "expression": "tired"
            }
          ],
          "dialogueBeats": [],
          "cameraMoves": [
            {
              "movement": "hold",
              "startFrame": 0,
              "endFrame": 96,
              "fromShot": "medium",
              "toShot": "medium",
              "easing": "linear"
            }
          ],
          "objectPlacements": [],
          "objectMotions": [],
          "shadowCues": [],
          "objectStateCues": [],
          "shotPresetApplications": [],
          "notes": ["Generated by LLMAnimationPlanGenerator"]
        }
        """

        let extracted = LLMAnimationPlanGenerator.extractJSON(from: json)
        XCTAssertFalse(extracted.isEmpty)

        let compiler = LLMAnimationPlanCompiler()
        let plan = try? compiler.parse(json: extracted)
        XCTAssertNotNil(plan, "Plan should parse correctly")
        XCTAssertEqual(plan?.sceneName, "March Scene")
        XCTAssertEqual(plan?.characterPlacements.count, 1)
        XCTAssertEqual(plan?.motions.count, 1)
        XCTAssertEqual(plan?.cameraMoves.count, 1)
        XCTAssertEqual(plan?.cameraMoves.first?.movement, .hold)
        XCTAssertEqual(plan?.motions.first?.easing, .easeInOut)
    }

    // MARK: - Helpers

    private func makeMinimalContext() -> LLMAnimationPlanGenerator.SceneContext {
        LLMAnimationPlanGenerator.SceneContext(
            sceneText: "Test scene.",
            characters: [],
            sceneName: "Test",
            durationBars: nil,
            fps: 24,
            stageWidth: 4.0,
            stageDepth: 3.0
        )
    }
}
