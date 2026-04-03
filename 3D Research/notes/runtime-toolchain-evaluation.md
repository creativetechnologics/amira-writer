# 3D Runtime / Toolchain Evaluation

## Working Thesis

The most practical near-term path for Amira is:

1. **Blender** for world asset creation, cel-shaded lookdev, camera/layout prototyping, and final offline renders.
2. **USD** as the interchange / shot-assembly backbone between tools.
3. **Godot** as the most feasible open-source realtime runtime on Mac M4 16GB for interactive staging.
4. **Unreal Engine 5** as the higher-end cinematic runtime/offload option when a stronger machine or cloud GPU is available.

## Why this looks promising

- Blender has native Apple Silicon support, low friction setup, and a toon pipeline that can be built with `Shader to RGB` / Eevee plus Grease Pencil and export paths to USD and glTF.
- USD is strong at composition, variants, references, and skeletal animation, which makes it a good “scene language” for shots, sets, lighting variants, and camera-driven sequences.
- Godot is the lightest realistic editor/runtime on Mac for custom 3D toolchains and supports camera, environment, shader, and animation control with much lower hardware pressure than UE.
- Unreal is the strongest cinematic renderer / sequence toolchain, but it is heavier and more likely to need offload for comfortable work on a 16 GB Mac.

## Known caveats

- Blender’s USD exporter is intentionally simpler than full USD composition; it exports visible supported objects and does not yet preserve all USD-native composition features.
- Unreal is excellent for cinematics, but Mac support and high-end rendering features can become memory / workflow heavy on 16 GB.
- Godot is feasible, but would require more custom tooling to reach a film-like linear animation workflow.
- O3DE exists as an open-source alternative, but macOS support is experimental and it is not the best fit for an M4 laptop-first workflow.

## Mapping to Animate concepts

- **Scene plan** → USD layers / Blender scene collections / engine-level level sequences.
- **Camera directions** → camera rigs in Blender, Sequencer in Unreal, Timeline/Cinemachine in Unity, AnimationPlayer/Camera3D in Godot.
- **Object placement** → USD references or engine scene nodes/actors.
- **Lighting + time of day** → environment/sky systems in Blender, UE, Unity, or Godot; best represented as explicit shot parameters.
- **Mouth engine / visemes** → separate character-animation stage that writes facial or bone animation tracks into the final shot package.

## Next experiments

1. Build a tiny valley / bridge / town test scene in Blender.
2. Prototype a cel-shaded render in Eevee.
3. Export the same scene to USD and glTF and compare fidelity.
4. Test a minimal Godot import / camera / light setup on Mac M4.
5. If needed, compare against Unreal Sequencer + Movie Render Queue on a stronger machine or cloud GPU.

## Sources

- Blender requirements: https://www.blender.org/download/requirements/
- Blender toon / shader docs: https://docs.blender.org/manual/en/latest/render/shader_nodes/converter/shader_to_rgb.html
- Blender USD export: https://docs.blender.org/manual/en/latest/files/import_export/usd.html
- Blender Grease Pencil: https://docs.blender.org/manual/en/latest/grease_pencil/introduction.html
- OpenUSD intro: https://openusd.org/docs/index.html
- Unreal cinematics: https://dev.epicgames.com/documentation/unreal-engine/cinematics-and-movie-making-in-unreal-engine
- Unreal macOS requirements: https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-engine-5-6-release-notes
- Unity system requirements: https://docs.unity3d.com/6000.0/Documentation/Manual/system-requirements.html
- Godot system requirements: https://docs.godotengine.org/en/stable/about/system_requirements.html
