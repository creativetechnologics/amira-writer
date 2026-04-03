# 01 — 3D Model Landscape

Date: 2026-04-01

## Executive summary

The current field breaks cleanly into three separate problem classes:

1. **Scene/world generation**
2. **Single asset generation/reconstruction**
3. **Character motion / facial motion**

For Amira, the best research strategy is to combine one strong option from each class instead of looking for one model to do all three.

---

## A. Scene / world generation

### 1) HunyuanWorld
**Best for:** large explorable 3D worlds from text or image  
**Why it matters:** closest match to “build the valley / river / bridge / town as a coherent world”

Key points:
- Official repo describes **immersive, explorable, interactive 3D worlds** from **words or pixels**
- Exports mesh/world outputs for downstream graphics pipelines
- Open-source plan includes inference code, checkpoints, lite version, and related follow-up projects
- Setup is clearly **CUDA/Linux/cloud-oriented**, and model access depends on Hugging Face checkpoints

Implication for Amira:
- Strongest research target for **world-scale generation**
- Not a realistic first local Mac M4 test

Sources:
- https://github.com/Tencent-Hunyuan/HunyuanWorld-1.0
- https://hunyuan.tencent.com/visual

### 2) Matrix-3D
**Best for:** scene-scale panoramic/explorable world generation  
**Why it matters:** strong non-Tencent scene candidate

Key points from repo:
- Generates **large-scale explorable 3D scenes**
- Supports both **text** and **image** input
- Repo says the whole pipeline needs **16 GB minimum VRAM**
- Low-VRAM options are documented:
  - **19 GB** for 720p low-VRAM pipeline
  - **12 GB** for the 5B low-VRAM model
- Currently tested on **Linux + NVIDIA GPU**

Implication for Amira:
- Very promising for a future **cloud scene-blockout branch**
- More open-license-friendly than Tencent

Source:
- https://github.com/SkyworkAI/Matrix-3D

### 3) MIDI-3D
**Best for:** compositional 3D scenes from a single image plus segmentation  
**Why it matters:** unusually relevant if Amira concept art can be broken into meaningful instances

Key points from repo:
- Designed for **single image to 3D scene generation**
- Explicitly targets **multi-instance** scenes with spatial relationships
- Claims generalization to **stylized inputs**
- Textured scene generation may require **about 30 GB VRAM**
- Requires segmentation input, which can be produced via Grounded SAM workflow

Implication for Amira:
- Strong bridge if we want to take existing Nano Banana concept art and turn it into **segmented scene reconstructions**
- More likely a **cloud experiment** than a local one

Source:
- https://github.com/VAST-AI-Research/MIDI-3D

---

## B. Asset generation / reconstruction

### 1) Hunyuan3D-2.1
**Best for:** production-oriented 3D asset generation from images  
**Why it matters:** strongest current Tencent asset candidate

Key points from repo:
- Focused on **high-fidelity 3D assets**
- Supports **macOS, Windows, Linux**
- Reported VRAM:
  - **10 GB** for shape generation
  - **21 GB** for texture generation
  - **29 GB** for shape + texture together
- Includes `--low_vram_mode` in Gradio usage path

Implication for Amira:
- Good for **bridge / houses / rocks / trees / props**
- Local Mac M4 testing is most realistic for **shape-only feasibility**, not the full textured pipeline
- Downstream cel-shading is straightforward because we can ignore/replace generated PBR looks

Source:
- https://github.com/tencent-hunyuan/hunyuan3d-2.1

### 2) TRELLIS
**Best for:** high-quality standalone 3D assets  
**Why it matters:** strong quality benchmark for image-conditioned asset generation

Key points from repo:
- Generates multiple 3D representations including **meshes**
- Strong editing/variant story
- Installation notes say:
  - **Linux only** tested
  - **NVIDIA GPU with at least 16 GB** required for the original repo
- Model weights are hosted on Hugging Face

Implication for Amira:
- Strong quality target for **hero assets**
- Not a local-Mac-first path

Source:
- https://github.com/microsoft/TRELLIS

### 3) Stable Fast 3D
**Best for:** quick single-image mesh reconstruction  
**Why it matters:** most promising “lighter” technical fit for local asset experiments

Key points from model/repo:
- Generates a **UV-unwrapped textured mesh asset** from one image
- MPS support was tested on **Apple Silicon**
- Official notes recommend **CPU** instead of MPS if the machine has **less than 32 GB unified memory**
- Repo/model are open, but practical checkpoint access still goes through Hugging Face

Implication for Amira:
- Good **sanity-check baseline**
- Likely usable only in limited/testing form on a 16 GB Mac

Sources:
- https://github.com/Stability-AI/stable-fast-3d
- https://huggingface.co/stabilityai/stable-fast-3d

### 4) InstantMesh / TripoSR / Wonder3D
**Best for:** fallback asset reconstruction baselines

Notes:
- **InstantMesh** is Apache-2.0 and strong for image-to-mesh, but repo guidance is CUDA-heavy
- **TripoSR** is a useful baseline class even if it is less likely to be the final choice
- **Wonder3D** remains relevant as a comparative open benchmark

Sources:
- https://github.com/TencentARC/InstantMesh
- https://github.com/VAST-AI-Research/TripoSR
- https://github.com/xxlong0/Wonder3D

---

## C. Character motion / face / lip

### 1) HY-Motion-1.0
**Best for:** text-to-3D human motion  
**Why it matters:** closest direct match to the Tencent motion idea you referenced

Key points from repo:
- Generates **skeleton-based 3D character animation** from text
- Supports **macOS, Windows, Linux**
- Reported minimum VRAM:
  - **26 GB** for standard
  - **24 GB** for Lite

Implication for Amira:
- Excellent **motion-source** candidate
- Effectively a **cloud GPU** tool for serious use
- Should be treated as upstream motion generation, not final art

Sources:
- https://github.com/Tencent-Hunyuan/HY-Motion-1.0
- https://hunyuan.tencent.com/motion/en?tabIndex=0

### 2) PantoMatrix
**Best for:** speech-to-body-plus-face research branch  
**Why it matters:** likely valuable later for retargetable performance data

Status:
- Promising from initial parallel research
- Needs a dedicated verification pass before being promoted to first-tier recommendation

Source for follow-up:
- https://github.com/PantoMatrix/PantoMatrix

### 3) LivePortrait
**Best for:** fast facial performance / portrait-control feasibility  
**Why it matters:** easiest plausible no-cost Apple Silicon facial test path

Key points from repo:
- Includes a dedicated `requirements_macOS.txt`
- States that **macOS with Apple Silicon** is supported for the human workflow
- macOS note says **Animals mode is not supported**, but human mode works

Implication for Amira:
- Good close-up acting / expression / mouth-reference branch
- Not a full-body animation system

Source:
- https://github.com/KlingAIResearch/LivePortrait

### 4) LatentSync
**Best for:** audio-driven lip sync  
**Why it matters:** strong no-cost lip-sync feasibility candidate

Key points from repo:
- Reported minimum inference VRAM:
  - **8 GB** for v1.5
  - **18 GB** for v1.6

Implication for Amira:
- Good lip-sync benchmark
- More promising as a **reference or assist system** than a final authoritative mouth engine

Source:
- https://github.com/bytedance/LatentSync

### 5) EchoMimic / MotionCtrl
**Best for:** secondary comparison branches

Notes:
- **EchoMimic** is worth a later face-animation comparison pass
- **MotionCtrl** is more useful for camera/object-video control than for final 3D animation authoring

Sources:
- https://github.com/antgroup/echomimic
- https://github.com/TencentARC/MotionCtrl

---

## D. Licensing and practical recommendations

### Cleaner open-license tier
- Matrix-3D — MIT
- MIDI-3D — Apache-2.0
- TRELLIS — MIT
- InstantMesh — Apache-2.0
- LivePortrait — MIT

### Source-available / community-license tier
- HunyuanWorld
- Hunyuan3D-2.1
- HY-Motion-1.0

### Practical first-tier recommendation

If we were choosing today:

1. **Worlds:** HunyuanWorld, Matrix-3D, MIDI-3D
2. **Assets:** Hunyuan3D-2.1, TRELLIS, Stable Fast 3D
3. **Motion:** HY-Motion-1.0
4. **Face/lip:** LivePortrait, LatentSync

