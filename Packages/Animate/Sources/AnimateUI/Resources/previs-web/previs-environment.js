import * as THREE from './vendor/three/three.module.js';

if (!window.__previs_state) throw new Error('previs-core must load before previs-environment');
const state = window.__previs_state;

export function setupEnvironment() {
  const grid = new THREE.GridHelper(20, 20, 0x555555, 0x333333);
  grid.position.y = 0;
  state.scene.add(grid);

  const groundGeo = new THREE.PlaneGeometry(20, 20);
  const groundMat = new THREE.ShadowMaterial({ opacity: 0.3 });
  const ground = new THREE.Mesh(groundGeo, groundMat);
  ground.rotation.x = -Math.PI / 2;
  ground.position.y = -0.01;
  ground.receiveShadow = true;
  state.scene.add(ground);

  state.ground = ground;
  state.grid = grid;
}

export function setupLighting(preset) {
  const presets = {
    'golden-hour': { color: 0xffaa66, intensity: 1.5, fillColor: 0x6688ff, fillIntensity: 0.3, ambient: 0.2 },
    'noon': { color: 0xffffff, intensity: 1.8, fillColor: 0x8899cc, fillIntensity: 0.4, ambient: 0.3 },
    'night-interior': { color: 0x4466aa, intensity: 0.8, fillColor: 0x442266, fillIntensity: 0.2, ambient: 0.1 },
    'overcast': { color: 0xaabbcc, intensity: 0.6, fillColor: 0x99aabb, fillIntensity: 0.4, ambient: 0.5 },
  };

  const cfg = presets[preset] || presets['golden-hour'];

  // Clear existing lights
  const toRemove = [];
  state.scene.children.forEach(c => {
    if (c.isLight || c.isAmbientLight || c.isDirectionalLight || c.isHemisphereLight) toRemove.push(c);
  });
  toRemove.forEach(c => state.scene.remove(c));

  const ambient = new THREE.AmbientLight(0x888888, cfg.ambient);
  state.scene.add(ambient);

  const hemi = new THREE.HemisphereLight(0xffffff, 0x444444, 0.4);
  state.scene.add(hemi);

  const sun = new THREE.DirectionalLight(cfg.color, cfg.intensity);
  sun.position.set(5, 10, 5);
  sun.castShadow = true;
  sun.shadow.mapSize.width = 1024;
  sun.shadow.mapSize.height = 1024;
  const d = 10;
  sun.shadow.camera.left = -d;
  sun.shadow.camera.right = d;
  sun.shadow.camera.top = d;
  sun.shadow.camera.bottom = -d;
  sun.shadow.camera.near = 1;
  sun.shadow.camera.far = 20;
  state.scene.add(sun);

  const fill = new THREE.DirectionalLight(cfg.fillColor, cfg.fillIntensity);
  fill.position.set(-3, 2, -4);
  state.scene.add(fill);

  const rim = new THREE.DirectionalLight(0xffffff, 0.3);
  rim.position.set(-2, 1, 5);
  state.scene.add(rim);
}
