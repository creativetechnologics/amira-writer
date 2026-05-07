import * as THREE from './vendor/three/three.module.js';

if (!window.__previs_state) throw new Error('previs-core must load first');
const state = window.__previs_state;

export function captureJPEG(label) {
  state.renderer.preserveDrawingBuffer = true;
  state.renderer.render(state.scene, state.camera);

  const width = 1280;
  const height = 720;
  const aspect = width / height;
  const origSize = new THREE.Vector2();
  state.renderer.getSize(origSize);

  state.renderer.setSize(width, height);
  state.camera.aspect = aspect;
  state.camera.updateProjectionMatrix();
  state.renderer.render(state.scene, state.camera);

  const dataURL = state.renderer.domElement.toDataURL('image/jpeg', 0.85);

  state.renderer.setSize(origSize.x, origSize.y);
  state.camera.aspect = origSize.x / origSize.y;
  state.camera.updateProjectionMatrix();
  state.renderer.preserveDrawingBuffer = false;

  try {
    window.webkit?.messageHandlers?.previsCapture?.postMessage({ label, dataURL });
    console.log('[previs] captured:', label);
  } catch (e) {
    console.error('[previs] capture failed:', e);
  }

  return dataURL;
}
