# 3D Shot Package Scaffold

Purpose: define a future-neutral package format for one 3D shot.

The package should stay independent from:
- any specific model vendor
- any specific engine
- any future Amira UI implementation

## Draft structure

```text
shot-package/
  shot.json
  world/
    world-instance.usda
  cameras/
    camera-main.usda
  animation/
    body.fbx
    face.json
    mouth.json
  style/
    toon-style.json
  renders/
    preview/
```

## Design principles

1. **Reference by asset ID**, not by fragile file paths where possible
2. Keep **body**, **face**, and **mouth** as separate layers
3. Keep **world** and **style** separable from performance
4. Allow either **USD**, **glTF**, or engine-specific derivatives downstream
5. Prefer explicit shot metadata over hidden tool-specific defaults

