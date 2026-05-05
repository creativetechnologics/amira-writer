# Character Costume Image API Handoff

## Endpoint

`POST http://127.0.0.1:19849/characters/generate-costume-images`

This route runs through the open Animate app API, hydrates the currently loaded project if needed, registers Gemini activity rows in the existing title-bar status badge, and generates via `GeminiImageService.generate(request:apiKey:)` so the selected backend, Vertex credit tracking, auth halt behavior, retries, and the global serial gate all apply.

Outputs are saved under:

`Characters/<slug>/animated/costume-studies/<timestamp>/`

The generated project-relative paths are appended to `character.animatedImagePaths`, XMP sidecars are written with animated/character metadata, and the image is registered as `character_animated` for image intelligence.

## Curl Example

```bash
curl -X POST http://127.0.0.1:19849/characters/generate-costume-images \
  -H 'Content-Type: application/json' \
  -d '{
    "characterSlugs": ["amira"],
    "count": 2,
    "prompt": "Create grounded costume studies suitable for animation production. Emphasize practical fabric layers, readable silhouette, and early-2000s Afghan valley context.",
    "styleInstructions": "Mature 2D anime feature-film realism, clean linework, restrained cel shading, production-ready costume readability.",
    "imageSize": "4K",
    "aspectRatio": "3:4",
    "model": "flash",
    "outputCollection": "animated"
  }'
```

Use all loaded characters:

```bash
curl -X POST http://127.0.0.1:19849/characters/generate-costume-images \
  -H 'Content-Type: application/json' \
  -d '{
    "allCharacters": true,
    "count": 1,
    "prompt": "One clear full-body costume study per character."
  }'
```

Optional explicit references can be shared:

```json
"referencePaths": [
  "Characters/amira/reference/example.png"
]
```

Or keyed per character:

```json
"referencePathsByCharacter": {
  "amira": ["Characters/amira/reference/example.png"],
  "mark": ["Characters/mark/costumes/military/front.png"]
}
```

If no references are supplied, the app auto-selects existing character identity, reference, costume, and inspiration paths.
