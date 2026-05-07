import { captureJPEG } from './previs-export.js';
import { saveCameraToKeyframe, loadKeyframe } from './previs-camera.js';

if (!window.__previs_state) throw new Error('previs-core must load first');
const state = window.__previs_state;

export function bindToolbar() {
  document.querySelectorAll('.mode-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.mode-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      const mode = btn.dataset.mode;
      if (mode === 'select') {
        state.transformControls.detach();
        state.currentMode = 'select';
        state.renderer.domElement.style.cursor = 'default';
      } else if (mode === 'poseBone') {
        state.transformControls.setMode('rotate');
        state.currentMode = 'poseBone';
        state.renderer.domElement.style.cursor = 'crosshair';
      } else {
        state.transformControls.setMode(mode);
        state.currentMode = mode;
        state.renderer.domElement.style.cursor = 'move';
      }
    });
  });

  document.querySelectorAll('.kf-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.kf-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      state.activeKeyframe = btn.dataset.kf;
      loadKeyframe(btn.dataset.kf);
    });
  });

  document.getElementById('capture-btn').addEventListener('click', () => {
    captureJPEG(state.activeKeyframe || 'capture');
  });
}
