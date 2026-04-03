# 03 — Feasibility and Experiment Plan

Date: 2026-04-01

## Local baseline

Observed local environment on 2026-04-01:
- **Apple M4**
- **16 GB unified memory**
- `torch` not installed
- Blender / Godot / Unreal CLIs not currently available in PATH

Implication:
- this machine is fine for **planning, scaffolding, and lightweight lookdev**
- it is not a reliable primary box for **heavy world-model inference**

---

## Feasibility tiers

### Tier 1 — immediate local / no-cost

#### A. Blender lookdev proof
Goal:
- prove that Amira’s world can survive a **cel-shaded 3D treatment**

What to test:
- one environment still
- one simple bridge/town blockout
- day / dusk / night lighting
- outline thickness and stylization
- near / medium / wide camera framing

Signal:
- if this fails aesthetically, model research matters less

#### B. LivePortrait face branch
Goal:
- get an Apple-Silicon-friendly early read on **expression / mouth / facial control**

Signal:
- tells us how useful AI-driven face reference may be before custom viseme integration

#### C. Shape-only asset branch
Goal:
- one image → one rough 3D asset

Best early targets:
- Stable Fast 3D
- Hunyuan3D shape-only branch

Signal:
- tests whether existing Amira artwork can become usable 3D proxies

---

### Tier 2 — cloud-first research branch

#### A. Scene/world branch
Priority order:
1. HunyuanWorld
2. Matrix-3D
3. MIDI-3D

Goal:
- one concept-art scene → explorable blockout world

#### B. Motion branch
Priority order:
1. HY-Motion-1.0
2. PantoMatrix

Goal:
- one prompt or one speech clip → retargetable motion source

---

## Model-by-model practicality

| Tool | Local Mac M4 16GB | Cloud likely | Notes |
|---|---:|---:|---|
| Blender | Yes | No | first lookdev tool |
| LivePortrait | Yes, likely | No | best first face test |
| Stable Fast 3D | Maybe, constrained | Maybe | MPS exists but 16 GB is tight |
| Hunyuan3D-2.1 shape | Maybe | Yes | shape-only first |
| Hunyuan3D-2.1 texture | No | Yes | 21 GB reported |
| HunyuanWorld | No | Yes | world-model branch |
| Matrix-3D | No | Yes | Linux/NVIDIA repo path |
| MIDI-3D | No | Yes | ~30 GB textured scene path |
| HY-Motion-1.0 | No | Yes | 24–26 GB reported |
| TRELLIS | No | Yes | Linux + NVIDIA-heavy |

---

## No-cost experiment ladder

### Experiment 1 — visual truth
- Tool: Blender
- Cost: none
- Success criterion: one shot of Amira world looks plausibly “right”

### Experiment 2 — object truth
- Tool: Stable Fast 3D or Hunyuan3D shape-only
- Cost: none if run locally
- Success criterion: one usable rough asset enters Blender and survives stylization

### Experiment 3 — scene truth
- Tool: Matrix-3D or HunyuanWorld
- Cost: none only if using free/local compute; otherwise defer
- Success criterion: one explorable valley/town blockout with coherent spatial feel

### Experiment 4 — facial truth
- Tool: LivePortrait / LatentSync
- Cost: none
- Success criterion: one line of dialogue yields useful expression or mouth-reference material

### Experiment 5 — package truth
- Tool: scaffold only
- Cost: none
- Success criterion: a shot package can express environment, camera, lights, characters, and mouth track separately

---

## Decision rule

Promote the 3D branch only if these five things are all true:

1. The **look** is good enough in cel-shaded form
2. The **world** can be blocked coherently
3. The **assets** are clean enough after repair/stylization
4. The **character motion** can be retargeted
5. The **shot package** can stay modular enough to coexist with current Animate thinking

