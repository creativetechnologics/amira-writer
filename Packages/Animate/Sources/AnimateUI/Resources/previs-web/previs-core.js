import * as THREE from './vendor/three/three.module.js';
import { OrbitControls } from './vendor/three/addons/controls/OrbitControls.js';
import { GLTFLoader } from './vendor/three/addons/loaders/GLTFLoader.js';
import { TransformControls } from './vendor/three/addons/controls/TransformControls.js';
import { setupEnvironment, setupLighting } from './previs-environment.js';
import { bindToolbar } from './previs-controls.js';
import { loadCharacter, removeCharacter } from './previs-character.js';

console.log('[previs] core init, THREE r' + (THREE.REVISION ?? '?'));

function reportBootError(err) {
  const info = document.getElementById('info');
  const msg = (err && (err.stack || err.message)) || String(err);
  if (info) {
    info.style.color = '#ff8080';
    info.innerText = 'Viewer error: ' + msg;
  }
  try { window.webkit?.messageHandlers?.previsLog?.postMessage('error: ' + msg); } catch {}
  console.error('[previs]', err);
}
window.addEventListener('error', (e) => reportBootError(e.error || e.message));
window.addEventListener('unhandledrejection', (e) => reportBootError(e.reason));

const state = {
  scene: null,
  camera: null,
  renderer: null,
  controls: null,
  transformControls: null,
  currentMode: 'select',
  selectedObject: null,
  activeKeyframe: 'middle',
  characters: new Map(),
  objects: new Map(),
  sceneData: null,
  ground: null,
  grid: null,
};

// Expose state for other modules and native bridge
window.__previs_state = state;
window.loadCharacter = loadCharacter;
window.removeCharacter = removeCharacter;
window.setupLighting = setupLighting;

init();

async function init() {
  const app = document.getElementById('app');
  state.renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: false });
  state.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  state.renderer.setSize(window.innerWidth, window.innerHeight);
  state.renderer.outputColorSpace = THREE.SRGBColorSpace;
  state.renderer.toneMapping = THREE.ACESFilmicToneMapping;
  state.renderer.toneMappingExposure = 1.35;
  state.renderer.shadowMap.enabled = true;
  state.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  app.appendChild(state.renderer.domElement);

  state.scene = new THREE.Scene();
  state.scene.background = new THREE.Color(0x1a1f27);

  state.camera = new THREE.PerspectiveCamera(50, window.innerWidth / window.innerHeight, 0.1, 500);
  state.camera.position.set(2, 1.6, 3);

  state.controls = new OrbitControls(state.camera, state.renderer.domElement);
  state.controls.enableDamping = true;
  state.controls.dampingFactor = 0.08;
  state.controls.minDistance = 0.5;
  state.controls.maxDistance = 50;
  state.controls.target.set(0, 1.2, 0);
  state.controls.update();

  state.transformControls = new TransformControls(state.camera, state.renderer.domElement);
  state.transformControls.setMode('translate');
  state.transformControls.setSize(0.5);
  state.transformControls.addEventListener('dragging-changed', (event) => {
    state.controls.enabled = !event.value;
  });
  state.scene.add(state.transformControls);

  window.addEventListener('resize', onResize);

  setupEnvironment();
  setupLighting('golden-hour');
  bindToolbar();

  document.getElementById('info').innerText = 'Ready';

  animate();
}

function animate() {
  requestAnimationFrame(animate);
  state.controls.update();
  state.renderer.render(state.scene, state.camera);
}

function onResize() {
  const w = window.innerWidth;
  const h = window.innerHeight;
  state.camera.aspect = w / h;
  state.camera.updateProjectionMatrix();
  state.renderer.setSize(w, h);
}
