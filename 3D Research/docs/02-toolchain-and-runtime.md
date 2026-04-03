# 02 — Toolchain and Runtime Recommendation

Date: 2026-04-01

## Recommendation in one line

Use **Amira Writer + RealityKit first**, keep **USD** as the canonical asset/package layer, and treat external tools as optional helpers rather than the center of the workflow.

---

## 1. Primary direction: Amira-native RealityKit runtime

### Why RealityKit is the best native target
Apple’s official RealityKit overview says RealityKit 4 supports **iOS, iPadOS, macOS, and visionOS**, and adds **blend shapes, inverse kinematics, skeletal poses, and animation timelines**. Apple also highlights **custom systems** using an Entity Component System and explicit support for animations, physics, and dynamic assets.

That matters because Amira needs:
- scene graph control
- reusable world assets
- skeletal characters
- facial/mouth animation layers
- deterministic camera and lighting systems
- native Swift/SwiftUI integration

RealityKit aligns with that direction far better than trying to build a Blender-centered loop.

### Why not SceneKit
Apple now marks **SceneKit as deprecated** and says to use **RealityKit instead**. Apple’s WWDC25 migration material describes SceneKit as maintenance-mode and recommends RealityKit for new work.

### Important RealityKit caveat
Apple’s USD validation docs say RealityKit **does not use lights included in a USD file** and instead relies on its own renderer behavior. So if Amira uses RealityKit, **lighting must be an Amira-native runtime layer**, not something delegated to imported USD lights.

Implication:
- use USD for geometry, variants, skeletons, and packaging
- keep lights, atmosphere, time of day, and style controls **native to Amira**

Sources:
- https://developer.apple.com/augmented-reality/realitykit/
- https://developer.apple.com/documentation/scenekit/
- https://developer.apple.com/videos/play/wwdc2025/288/
- https://developer.apple.com/documentation/usd/validating-usd-files
- https://developer.apple.com/documentation/usd/creating-usd-files-for-apple-devices

---

## 2. USD

### Why USD still matters
USD remains the right interchange and packaging layer because:
- RealityKit loads USD-family assets
- Apple explicitly positions USD as the standard asset path for Apple 3D pipelines
- variants, references, and package structure are useful even if Amira owns runtime behavior

But USD should hold:
- geometry
- skeletons
- variants
- basic asset packaging

It should **not** be the only place we define:
- lighting
- time of day
- cel-shading logic
- runtime shot state

Those belong in Amira-native runtime state.

Sources:
- https://openusd.org/docs/index.html
- https://developer.apple.com/documentation/usd/creating-usd-files-for-apple-devices
- https://developer.apple.com/documentation/realitykit/loading-entities-from-a-file

---

## 3. Blender as fallback only

### Why Blender still remains useful
- Best fit for **world building**
- Best fit for **camera/layout lookdev**
- Best fit for **stylized/cel-shaded offline output**
- Best fit for **manual cleanup of generated geometry**
- Strong bridge into other tools via **USD** and **glTF**

### Why it matters for Amira
Blender is the easiest place to answer the first real question:

> Can the valley / river / bridge / town look like Amira after cel shading, lighting control, and camera direction?

That question matters more than raw generative novelty.

For this branch, Blender is **not** the preferred center of the workflow. It is only a fallback for:
- mesh cleanup
- emergency asset repair
- optional lookdev comparisons

If Amira-native rendering works well enough, Blender can stay out of the daily pipeline.

Useful references:
- Shader-to-RGB / NPR workflow: https://docs.blender.org/manual/en/latest/render/shader_nodes/converter/shader_to_rgb.html
- USD import/export: https://docs.blender.org/manual/en/latest/files/import_export/usd.html

---

## 4. Unreal Engine as later escape hatch

### Why Unreal stays in the stack
Unreal is still the premium option for:
- Sequencer
- camera rigs and cuts
- higher-end lighting/rendering
- final cinematic passes

Epic’s cinematic docs make it a strong long-term target if Amira’s 3D branch becomes serious.

### Why it is not first
- Heavier on Mac
- More setup friction
- More likely to push work toward stronger hardware or cloud/offload

Useful references:
- Cinematics and movie making: https://dev.epicgames.com/documentation/unreal-engine/cinematics-and-movie-making-in-unreal-engine
- 5.6 platform notes / macOS baseline references: https://dev.epicgames.com/documentation/unreal-engine/unreal-engine-5-6-release-notes

---

## 5. Mapping this stack to Animate concepts

| Animate concept | 3D equivalent |
|---|---|
| Scene plan | Amira-native scene package + USD-backed assets |
| Camera directions | RealityKit entities/components + Amira camera runtime |
| Object placement | referenced assets / entities / transforms |
| Lighting/time of day | explicit environment variants and shot overrides |
| Mouth engine | separate facial track merged into shot package |
| Shot review/apply | preview render + deterministic runtime state diff |

---

## Conclusion

If this branch advances, the most realistic stack is:

1. **Amira Writer + RealityKit** — direct and review the scene natively
2. **USD** — package assets cleanly
3. **External generators** — produce worlds/assets/motion as background workers
4. **Blender / Unreal** — optional fallback or premium offload only when justified
