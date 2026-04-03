import Foundation
import Testing
@testable import Amira3DEngine

struct RegistryLoaderTests {
    @Test
    func loaderDecodesKnownScaffoldingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "world-catalog"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "asset-registry"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "face-rigs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "expression-profiles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "mouth-profiles"), withIntermediateDirectories: true)

        let worldJSON = """
        {
          "schemaVersion": "0.1",
          "project": "Amira",
          "worlds": [
            {
              "worldId": "world.valley.main",
              "title": "Main Valley",
              "description": "Primary world.",
              "coreAssetIds": ["bridge_main"],
              "defaultCameraPresetIds": ["extreme_wide_establishing"],
              "defaultStyleProfileId": "amira_toon_v001",
              "defaultTimeOfDayPresetId": "sunrise_warm"
            }
          ],
          "timeOfDayPresets": ["sunrise_warm"],
          "styleProfiles": ["amira_toon_v001"]
        }
        """
        let assetJSON = """
        {
          "schemaVersion": "0.1",
          "project": "Amira",
          "assets": [
            {
              "assetId": "bridge_main",
              "category": "environment.structure",
              "sourceType": "generated_then_cleaned",
              "preferredFormat": "usd",
              "alternateFormats": ["glb"],
              "styleStatus": "toon_ready",
              "originNotes": "ok"
            }
          ]
        }
        """
        let faceRigJSON = """
        {
          "schemaVersion": "0.1",
          "project": "Amira",
          "faceRigs": [
            {
              "faceRigId": "face_rig.luke.01",
              "title": "Luke Rig",
              "description": "Anime performance face rig.",
              "skeletonProfileId": "skeleton.humanoid.basic",
              "faceNodeName": "Face",
              "jawNodeName": "Jaw",
              "mouthNodeName": "Mouth",
              "leftEyeNodeName": "Eye_L",
              "rightEyeNodeName": "Eye_R",
              "browNodeNames": ["Brow_L", "Brow_R"],
              "defaultExpressionProfileId": "expr_profile.luke.01",
              "defaultMouthProfileId": "mouth_profile.luke.01",
              "supportedExpressionProfileIds": ["expr_profile.luke.01"],
              "supportedMouthProfileIds": ["mouth_profile.luke.01"],
              "notes": "ok"
            }
          ]
        }
        """
        let expressionJSON = """
        {
          "schemaVersion": "0.1",
          "project": "Amira",
          "expressionProfiles": [
            {
              "schemaVersion": "0.1",
              "expressionProfileId": "expr_profile.luke.01",
              "faceRigId": "face_rig.luke.01",
              "title": "Luke Expressions",
              "defaultExpressionId": "neutral",
              "expressions": [
                {
                  "expressionId": "neutral",
                  "label": "Neutral",
                  "category": "rest",
                  "blendshapeWeights": { "smile": 0.0 },
                  "jawOpen": 0.0,
                  "eyeOpen": 1.0,
                  "browRaise": 0.0,
                  "mouthCue": "rest",
                  "visemeCue": "rest",
                  "notes": "ok"
                }
              ],
              "notes": "ok"
            }
          ]
        }
        """
        let mouthJSON = """
        {
          "schemaVersion": "0.1",
          "project": "Amira",
          "mouthProfiles": [
            {
              "schemaVersion": "0.1",
              "mouthProfileId": "mouth_profile.luke.01",
              "faceRigId": "face_rig.luke.01",
              "title": "Luke Mouth",
              "driverType": "preston_blair",
              "neutralVisemeToken": "rest",
              "fallbackVisemeToken": "consonant",
              "visemes": [
                { "token": "rest", "blendshape": "rest", "jawOpen": 0.0 }
              ],
              "notes": "ok"
            }
          ]
        }
        """

        try worldJSON.data(using: .utf8)?.write(to: root.appending(path: "world-catalog/world-catalog.example.json"))
        try assetJSON.data(using: .utf8)?.write(to: root.appending(path: "asset-registry/asset-registry.example.json"))
        try faceRigJSON.data(using: .utf8)?.write(to: root.appending(path: "face-rigs/face-rigs.example.json"))
        try expressionJSON.data(using: .utf8)?.write(to: root.appending(path: "expression-profiles/expression-profiles.example.json"))
        try mouthJSON.data(using: .utf8)?.write(to: root.appending(path: "mouth-profiles/mouth-profiles.example.json"))

        let bundle = try RegistryLoader().loadBundle(from: root)

        #expect(bundle.worldCatalog?.worlds.first?.worldID == "world.valley.main")
        #expect(bundle.assetRegistry?.assets.first?.assetID == "bridge_main")
        #expect(bundle.faceRigCatalog?.faceRigs.first?.faceRigID == "face_rig.luke.01")
        #expect(bundle.expressionProfileCatalog?.expressionProfiles.first?.expressionProfileID == "expr_profile.luke.01")
        #expect(bundle.mouthProfileCatalog?.mouthProfiles.first?.mouthProfileID == "mouth_profile.luke.01")
    }
}
