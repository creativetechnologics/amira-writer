import * as THREE from './vendor/three/three.module.js';

if (!window.__previs_state) throw new Error('previs-core must load first');
const state = window.__previs_state;

export function saveCameraToKeyframe() {
  const label = state.activeKeyframe || 'middle';
  const pos = state.camera.position.toArray();
  const target = state.controls.target.toArray();
  const fov = state.camera.fov;

  const keyframe = { label, position: pos, lookAt: target, fov };

  if (!state.sceneData) state.sceneData = { keyframes: [] };
  state.sceneData.keyframes = state.sceneData.keyframes.filter(k => k.label !== label);
  state.sceneData.keyframes.push(keyframe);
}

export function loadKeyframe(label) {
  if (!state.sceneData) return;
  const kf = state.sceneData.keyframes.find(k => k.label === label);
  if (!kf) return;

  state.camera.position.fromArray(kf.position);
  state.controls.target.fromArray(kf.lookAt);
  state.camera.fov = kf.fov;
  state.camera.updateProjectionMatrix();
  state.controls.update();
}

export function setCameraShotType(shotType) {
  const presets = {
    'extreme_wide': { distance: 8, fov: 60 },
    'wide': { distance: 5, fov: 55 },
    'medium': { distance: 3, fov: 50 },
    'medium_close': { distance: 2, fov: 45 },
    'close': { distance: 1, fov: 35 },
    'extreme_close': { distance: 0.5, fov: 25 },
  };

  const preset = presets[shotType];
  if (!preset) return;

  const dir = new THREE.Vector3();
  state.camera.getWorldDirection(dir);
  state.camera.position.copy(state.controls.target).add(dir.multiplyScalar(-preset.distance));
  state.camera.fov = preset.fov;
  state.camera.updateProjectionMatrix();
  state.controls.update();
}
