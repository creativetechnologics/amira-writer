# Image intelligence architecture plan

## Recommendation

Use a hybrid Gemini pipeline:

1. **Gemini 3 Flash Preview** (`gemini-3-flash-preview`) for structured visual interpretation and database-ready tagging.
2. **Gemini Embedding 2** (`gemini-embedding-2`) for image vectors, semantic metadata vectors, similarity search, clustering, and outlier detection.
3. **Nano Banana 2** (`gemini-3.1-flash-image-preview`) remains the downstream image-generation model that will consume selected reference images.

Do not choose only one model. The tagging problem and vector search problem are different.

## Data storage decision

Use sidecar database/index storage as the source of truth.

### Store in database/vector index

- Analysis job state.
- Structured visual metadata JSON.
- Normalized tags.
- Tag confidence and source.
- Vectors.
- Vector model/dimension metadata.
- Quality flags.
- Similarity/outlier flags.
- Generation provenance.

### Optionally embed into image metadata

Only minimal portable metadata:

- asset ID
- content hash
- analysis ID
- schema version
- source generation ID

Do not embed full tags, vectors, private script info, scoring, or secrets into image files.

## End-to-end pipeline

```text
Image imported/generated
        |
        v
Persist image asset immediately
        |
        v
Emit image.created / enqueueImageAnalysis(imageAssetId)
        |
        v
Background worker
        |
        +--> local inspection: dimensions, hash, pHash, EXIF
        |
        +--> Gemini 3 Flash visual analysis -> structured JSON
        |
        +--> normalize tags -> image_tags / image_tag_assignments
        |
        +--> Gemini Embedding 2 image embedding -> vector index
        |
        +--> Gemini Embedding 2 semantic metadata embedding -> vector index
        |
        +--> QC flags / nearest-neighbor precompute where feasible
        |
        v
Image is now searchable/selectable by agents
```

## How future prompt-builder agents should use the index

For each shot/start-frame/end-frame request:

1. Parse shot direction into structured requirements:
   - characters
   - location/setting
   - time of day
   - weather/season
   - topography
   - foliage
   - props
   - action
   - camera/composition
   - visual style/mood
2. Use hard filters for must-have tags.
3. Use `gemini-embedding-2` to embed the shot direction as a text query.
4. Search semantic metadata vectors for candidate images.
5. Use visual vectors to check consistency with approved images or chosen references.
6. Select a role-diverse set of references:
   - character reference
   - location/background reference
   - prop reference
   - style/lighting reference
   - continuity/start/end reference
7. Attach references to Nano Banana 2 prompt generation.
8. Store which images were attached and why.

## Reference image categories

Every image may have one or more role candidates:

```text
character_reference
location_reference
prop_reference
background_plate
style_reference
shot_start_frame
shot_end_frame
texture_reference
continuity_reference
unknown
```

The selector should not simply choose the top five by vector similarity. It should choose a balanced set based on the shot’s needs.

## Canonical entities

Gemini can describe visible people, but it should not be trusted to know project-specific character names unless the app provides context.

Create or reuse canonical records for:

- characters
- locations
- props
- styles
- shot groups / sequences

The model can produce descriptive tags. The app should map those tags to canonical records using:

1. Existing image metadata.
2. Original generation prompt.
3. Manual assignments.
4. Project character/location registries.
5. Similarity to approved reference images.

## Retrieval strategy

Use three retrieval layers:

### 1. Structured filters

Fast database filters:

- character IDs
- location IDs
- required tags
- excluded tags
- quality status
- asset role
- source
- approval status

### 2. Semantic vector search

Use `semantic_metadata` embeddings for text-to-image retrieval from script/shot directions.

This is best when the query is like:

```text
night exterior in a sparse pine forest, low moonlight, wet ground, protagonist holding a lantern, tense mood
```

### 3. Visual vector search

Use `image_visual` embeddings for:

- finding visually similar images
- clustering
- consistency checking
- duplicate detection
- detecting outliers versus an approved reference set

## Wrong-image detection

Combine rule checks and vector checks.

### Rule examples

- Shot requires `night`; image tag says `midday`.
- Shot requires `dense_forest`; image tag says `desert` or `no_foliage`.
- Shot requires `coastal_cliff`; image topography says `flat_interior`.
- Shot requires character A; image lacks canonical character A or includes wrong character.

### Vector examples

- Image is far from approved images for the same location.
- Image is far from approved images for the same character.
- Image is a near-duplicate of an already used frame when novelty is required.
- Image clusters with a different setting/sequence than expected.

## Backfill strategy

For the existing image library:

1. Add migrations first.
2. Add backfill command in dry-run mode.
3. Count images requiring analysis.
4. Enqueue jobs in small batches.
5. Rate limit workers.
6. Persist partial completion.
7. Resume from the database after crashes.
8. Let operators re-run only failed or stale images.

## Suggested first milestone

Implement the minimum useful version:

1. Settings field for Image Analysis Gemini API Key.
2. Gemini Developer API client with no Vertex path.
3. Image analysis queue.
4. Import/generated-image hooks.
5. `gemini-3-flash-preview` structured tagging.
6. `gemini-embedding-2` image and semantic vectors.
7. Backfill command.
8. Basic tag search and similar-image search.

## Suggested second milestone

Add prompt-builder integration:

1. Shot requirement parser/schema.
2. Reference image selector.
3. Scoring and explanation.
4. Nano Banana 2 reference attachment handoff.
5. QC flags for mismatches.
6. Admin review UI.

## Important implementation cautions

- Do not block UI/image generation while waiting for analysis.
- Do not store API keys in logs or client-side code.
- Do not store vectors in image files.
- Do not compare vectors across models or dimensions.
- Do not trust model-generated character names without app context.
- Do not auto-delete images based on model analysis.
- Do not hardcode free-tier pricing assumptions.
- Do not use Vertex for this feature.

## Useful model facts from official docs

- `gemini-3-flash-preview` accepts text, image, video, audio, and PDF inputs and outputs text. It supports structured outputs.
- `gemini-embedding-2` maps text, images, video, audio, and PDFs into a unified embedding space.
- `gemini-embedding-2` supports flexible output dimensions from 128 to 3072; recommended dimensions include 768, 1536, and 3072.
- Gemini Developer API keys can be created/managed in Google AI Studio and supplied explicitly to the GenAI SDK.
- The Gemini API REST path uses `generativelanguage.googleapis.com` and `x-goog-api-key`.
- Nano Banana 2 is `gemini-3.1-flash-image-preview`.

## Documentation links

- https://ai.google.dev/gemini-api/docs/api-key
- https://ai.google.dev/api
- https://ai.google.dev/gemini-api/docs/image-understanding
- https://ai.google.dev/gemini-api/docs/structured-output
- https://ai.google.dev/gemini-api/docs/models/gemini-3-flash-preview
- https://ai.google.dev/gemini-api/docs/gemini-3
- https://ai.google.dev/gemini-api/docs/embeddings
- https://ai.google.dev/gemini-api/docs/pricing
- https://ai.google.dev/gemini-api/docs/image-generation
