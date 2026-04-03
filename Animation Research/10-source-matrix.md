# 10 — Source Matrix

Date: 2026-03-30

This file collects the most important primary / official sources that informed the research corpus in this folder.

## AI image / video generation
- Google Gemini structured output docs: https://ai.google.dev/gemini-api/docs/structured-output
- Google Gemini image understanding docs: https://ai.google.dev/gemini-api/docs/vision
- Google Gemini image generation docs: https://ai.google.dev/gemini-api/docs/image-generation
- Google Gemini Batch API docs: https://ai.google.dev/gemini-api/docs/batch-api
- Google File API docs: https://ai.google.dev/api/files
- Google Veo / Vertex best practices: https://docs.cloud.google.com/vertex-ai/generative-ai/docs/video/best-practice
- Google Toongether showcase: https://ai.google.dev/showcase/toongether

## 2D runtime / rig paradigms
- Spine runtime skeletons: https://esotericsoftware.com/spine-runtime-skeletons
- Spine runtime skins: https://esotericsoftware.com/spine-runtime-skins
- Spine C runtime: https://esotericsoftware.com/spine-c
- Live2D Cubism manuals: https://docs.live2d.com/
- Live2D facial expression mechanism: https://docs.live2d.com/4.2/en/cubism-editor-manual/facial-expression-system/

## Cut-out / authoring workflows
- Toon Boom Harmony rigging with deformers: https://docs.toonboom.com/help/harmony-21/premium/deformation/about-rigging-with-deformers.html
- Toon Boom kinematic output: https://docs.toonboom.com/help/harmony-20/essentials/deformation/rig-kinematic-output.html
- Toon Boom multi-pose rig chain: https://docs.toonboom.com/help/harmony-24/premium/deformation/create-main-deformation-chain-multi-pose-rig.html
- Toon Boom additional chain: https://docs.toonboom.com/help/harmony-24/premium/deformation/create-additional-deformation-chain-multi-pose-rig.html

## Lip sync / mouth systems
- Adobe Character Animator prepare artwork: https://helpx.adobe.com/lv/adobe-character-animator/using/prepare-artwork.html
- Adobe Character Animator body / views: https://helpx.adobe.com/fi/adobe-character-animator/using/behaviors/body-directly-controlled.html
- Adobe Animate auto lip sync: https://helpx.adobe.com/lt/animate/how-to/auto-lip-sync-sensei.html
- Rhubarb Lip Sync: https://github.com/DanielSWolf/rhubarb-lip-sync

## Internal project references
- `Packages/Animate/SampleData/CharacterPackages/LukePainterlyV1/character-package.json`
- `Packages/Animate/Sources/AnimateUI/Models/CharacterPackageModels.swift`
- `Packages/Animate/Sources/AnimateUI/Services/GeminiImageService.swift`
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

## How to use this file
When implementation begins, use this file as the starting point for:
- validating tool assumptions
- finding the original docs for package/runtime concepts
- checking current official capabilities before locking product decisions
