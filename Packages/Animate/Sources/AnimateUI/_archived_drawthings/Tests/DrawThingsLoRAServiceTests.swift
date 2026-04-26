import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class DrawThingsLoRAServiceTests: XCTestCase {
    func testPreparePromptRegistersImportedLoRAInCustomRegistry() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelsDirectory = tempRoot.appendingPathComponent("Models", isDirectory: true)
        let animateURL = tempRoot.appendingPathComponent("Animate", isDirectory: true)
        let loraDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("amira-nazari")
            .appendingPathComponent("lora", isDirectory: true)

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loraDirectory, withIntermediateDirectories: true)
        try "[]".write(
            to: modelsDirectory.appendingPathComponent("custom_lora.json"),
            atomically: true,
            encoding: .utf8
        )
        try Data("dummy".utf8).write(
            to: modelsDirectory.appendingPathComponent("flux_2_klein_9b_q8p.ckpt")
        )

        let sourceFilename = "mrnza5-flux2-klein-base-9b.safetensors"
        try Data("lora".utf8).write(
            to: loraDirectory.appendingPathComponent(sourceFilename)
        )

        let previousModelsDir = ProcessInfo.processInfo.environment["DRAWTHINGS_MODELS_DIR"]
        setenv("DRAWTHINGS_MODELS_DIR", modelsDirectory.path, 1)
        defer {
            if let previousModelsDir {
                setenv("DRAWTHINGS_MODELS_DIR", previousModelsDir, 1)
            } else {
                unsetenv("DRAWTHINGS_MODELS_DIR")
            }
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let character = AnimationCharacter(
            id: UUID(),
            name: "Amira Nazari",
            description: "",
            owpSlug: "amira-nazari",
            parts: [],
            activeLORAFilename: sourceFilename,
            activeLORATriggerWord: "mrnza5",
            activeLORAWeight: 0.9
        )

        let prepared = try await DrawThingsLoRAService().preparePrompt(
            prompt: "Amira waits in the doorway.",
            characters: [character],
            animateURL: animateURL,
            config: DrawThingsPlaceConfig(apiPort: 9)
        )

        XCTAssertEqual(
            prepared.loras.map(\.file),
            ["amira__amira-nazari__mrnza5-flux2-klein-base-9b.safetensors"]
        )
        XCTAssertEqual(prepared.loras.map(\.mode), ["all"])

        let registryURL = modelsDirectory.appendingPathComponent("custom_lora.json")
        let data = try Data(contentsOf: registryURL)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let entry = try XCTUnwrap(json.first(where: {
            ($0["file"] as? String) == "amira__amira-nazari__mrnza5-flux2-klein-base-9b.safetensors"
        }))

        XCTAssertEqual(entry["name"] as? String, "Amira Nazari")
        XCTAssertEqual(entry["prefix"] as? String, "mrnza5 ")
        XCTAssertEqual(entry["version"] as? String, "flux2_9b")
        XCTAssertEqual(entry["is_lo_ha"] as? Bool, false)
    }

    func testPreparePromptPrefersExistingNativeDrawThingsArtifactAndItsPromptPrefix() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelsDirectory = tempRoot.appendingPathComponent("Models", isDirectory: true)
        let animateURL = tempRoot.appendingPathComponent("Animate", isDirectory: true)
        let loraDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("matt-quill")
            .appendingPathComponent("lora", isDirectory: true)

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loraDirectory, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(
            to: modelsDirectory.appendingPathComponent("flux_2_klein_9b_q8p.ckpt")
        )
        try Data("native".utf8).write(
            to: modelsDirectory.appendingPathComponent("mttq39_flux2_klein_base_9b_lora_f16.ckpt")
        )
        try """
        [
          {
            "file": "mttq39_flux2_klein_base_9b_lora_f16.ckpt",
            "name": "Matt Quill",
            "prefix": "mttq39 ",
            "version": "flux2_9b",
            "is_lo_ha": false
          }
        ]
        """.write(
            to: modelsDirectory.appendingPathComponent("custom_lora.json"),
            atomically: true,
            encoding: .utf8
        )

        let sourceFilename = "mttq39-flux2-klein-base-9b.safetensors"
        try Data("source".utf8).write(
            to: loraDirectory.appendingPathComponent(sourceFilename)
        )

        let previousModelsDir = ProcessInfo.processInfo.environment["DRAWTHINGS_MODELS_DIR"]
        setenv("DRAWTHINGS_MODELS_DIR", modelsDirectory.path, 1)
        defer {
            if let previousModelsDir {
                setenv("DRAWTHINGS_MODELS_DIR", previousModelsDir, 1)
            } else {
                unsetenv("DRAWTHINGS_MODELS_DIR")
            }
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let character = AnimationCharacter(
            id: UUID(),
            name: "Matt Quill",
            description: "",
            owpSlug: "matt-quill",
            parts: [],
            activeLORAFilename: sourceFilename,
            activeLORATriggerWord: "legacy-trigger",
            activeLORAWeight: 1.0
        )

        let prepared = try await DrawThingsLoRAService().preparePrompt(
            prompt: "Matt checks the doorway before sunrise.",
            characters: [character],
            animateURL: animateURL,
            config: DrawThingsPlaceConfig(apiPort: 9)
        )

        XCTAssertEqual(
            prepared.loras.map(\.file),
            ["mttq39_flux2_klein_base_9b_lora_f16.ckpt"]
        )
        XCTAssertEqual(prepared.loras.map(\.mode), ["all"])
        XCTAssertEqual(
            prepared.prompt,
            "mttq39 checks the doorway before sunrise."
        )
    }

    func testPreparePromptRejectsStaleNativeArtifactWithWrongTriggerPrefix() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelsDirectory = tempRoot.appendingPathComponent("Models", isDirectory: true)
        let animateURL = tempRoot.appendingPathComponent("Animate", isDirectory: true)
        let loraDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("luke-hart")
            .appendingPathComponent("lora", isDirectory: true)

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loraDirectory, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(
            to: modelsDirectory.appendingPathComponent("flux_2_klein_9b_q8p.ckpt")
        )
        try Data("stale".utf8).write(
            to: modelsDirectory.appendingPathComponent("lkhr25_flux2_klein_base_9b_lora_f16.ckpt")
        )
        try """
        [
          {
            "file": "lkhr25_flux2_klein_base_9b_lora_f16.ckpt",
            "name": "Luke Hart",
            "prefix": "lkhr25 ",
            "version": "flux2_9b",
            "is_lo_ha": false
          }
        ]
        """.write(
            to: modelsDirectory.appendingPathComponent("custom_lora.json"),
            atomically: true,
            encoding: .utf8
        )

        let sourceFilename = "lkhr27-flux2-klein-base-9b.safetensors"
        try Data("source".utf8).write(
            to: loraDirectory.appendingPathComponent(sourceFilename)
        )

        let previousModelsDir = ProcessInfo.processInfo.environment["DRAWTHINGS_MODELS_DIR"]
        setenv("DRAWTHINGS_MODELS_DIR", modelsDirectory.path, 1)
        defer {
            if let previousModelsDir {
                setenv("DRAWTHINGS_MODELS_DIR", previousModelsDir, 1)
            } else {
                unsetenv("DRAWTHINGS_MODELS_DIR")
            }
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke Hart",
            description: "",
            owpSlug: "luke-hart",
            parts: [],
            activeLORAFilename: sourceFilename,
            activeLORATriggerWord: "lkhr27",
            activeLORAWeight: 1.0
        )

        let prepared = try await DrawThingsLoRAService().preparePrompt(
            prompt: "Luke moves through the clinic courtyard.",
            characters: [character],
            animateURL: animateURL,
            config: DrawThingsPlaceConfig(apiPort: 9)
        )

        XCTAssertEqual(
            prepared.loras.map(\.file),
            ["amira__luke-hart__lkhr27-flux2-klein-base-9b.safetensors"]
        )
        XCTAssertEqual(prepared.loras.map(\.mode), ["all"])
        XCTAssertEqual(
            prepared.prompt,
            "lkhr27 moves through the clinic courtyard."
        )
    }

    func testInjectTriggersPlacesRandomTokenBesideMatchedCharacterName() {
        let prompt = "Luke stands on screen-left while Matt watches from screen-right."
        let result = DrawThingsPromptIdentityInjector.injectTriggers(
            into: prompt,
            mappings: [
                DrawThingsPromptTriggerMapping(characterTokens: ["Luke Hart", "Luke"], triggerWord: "luke"),
                DrawThingsPromptTriggerMapping(characterTokens: ["Matt Quill", "Matt"], triggerWord: "mttq39")
            ]
        )

        XCTAssertEqual(
            result,
            "luke stands on screen-left while mttq39 watches from screen-right."
        )
    }

    func testInjectTriggersDoesNotDuplicateSameNameTriggerOrExistingToken() {
        let prompt = "Luke stands beside Matt mttq39 near the clinic doorway."
        let result = DrawThingsPromptIdentityInjector.injectTriggers(
            into: prompt,
            mappings: [
                DrawThingsPromptTriggerMapping(characterTokens: ["Luke Hart", "Luke"], triggerWord: "luke"),
                DrawThingsPromptTriggerMapping(characterTokens: ["Matt Quill", "Matt"], triggerWord: "mttq39")
            ]
        )

        XCTAssertEqual(result, "luke stands beside mttq39 near the clinic doorway.")
    }

    func testInjectTriggersReplacesAllNameMentionsWithTriggerOnly() {
        let prompt = "Luke looks at Luke's reflection in the window."
        let result = DrawThingsPromptIdentityInjector.injectTriggers(
            into: prompt,
            mappings: [
                DrawThingsPromptTriggerMapping(characterTokens: ["Luke Hart", "Luke"], triggerWord: "lkhr27")
            ]
        )

        XCTAssertEqual(result, "lkhr27 looks at lkhr27's reflection in the window.")
    }

    func testPreparePromptMatchesTriggerOnlyPromptToActiveLoRA() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelsDirectory = tempRoot.appendingPathComponent("Models", isDirectory: true)
        let animateURL = tempRoot.appendingPathComponent("Animate", isDirectory: true)
        let loraDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("luke-hart")
            .appendingPathComponent("lora", isDirectory: true)

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loraDirectory, withIntermediateDirectories: true)
        try "[]".write(
            to: modelsDirectory.appendingPathComponent("custom_lora.json"),
            atomically: true,
            encoding: .utf8
        )
        try Data("dummy".utf8).write(
            to: modelsDirectory.appendingPathComponent("flux_2_klein_9b_q8p.ckpt")
        )

        let sourceFilename = "lkhr27-flux2-klein-base-9b.safetensors"
        try Data("lora".utf8).write(
            to: loraDirectory.appendingPathComponent(sourceFilename)
        )

        let previousModelsDir = ProcessInfo.processInfo.environment["DRAWTHINGS_MODELS_DIR"]
        setenv("DRAWTHINGS_MODELS_DIR", modelsDirectory.path, 1)
        defer {
            if let previousModelsDir {
                setenv("DRAWTHINGS_MODELS_DIR", previousModelsDir, 1)
            } else {
                unsetenv("DRAWTHINGS_MODELS_DIR")
            }
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke Hart",
            description: "",
            owpSlug: "luke-hart",
            parts: [],
            activeLORAFilename: sourceFilename,
            activeLORATriggerWord: "lkhr27",
            activeLORAWeight: 1.0
        )

        let prepared = try await DrawThingsLoRAService().preparePrompt(
            prompt: "lkhr27 on screen-left reaches toward the doorway.",
            characters: [character],
            animateURL: animateURL,
            config: DrawThingsPlaceConfig(apiPort: 9)
        )

        XCTAssertEqual(
            prepared.loras.map(\.file),
            ["amira__luke-hart__lkhr27-flux2-klein-base-9b.safetensors"]
        )
        XCTAssertEqual(
            prepared.prompt,
            "lkhr27 on screen-left reaches toward the doorway."
        )
    }

    func testInjectTriggersFallsBackToPrefixWhenNoCharacterTokenMatches() {
        let prompt = "Two medics cross the dusty street at dawn."
        let result = DrawThingsPromptIdentityInjector.injectTriggers(
            into: prompt,
            mappings: [
                DrawThingsPromptTriggerMapping(characterTokens: ["Matt Quill", "Matt"], triggerWord: "mttq39")
            ]
        )

        XCTAssertEqual(result, "mttq39, Two medics cross the dusty street at dawn.")
    }
}
