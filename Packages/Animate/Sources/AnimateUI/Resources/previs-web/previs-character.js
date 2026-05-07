import * as THREE from './vendor/three/three.module.js';
import { GLTFLoader } from './vendor/three/addons/loaders/GLTFLoader.js';

if (!window.__previs_state) throw new Error('previs-core must load first');
const state = window.__previs_state;

const loader = new GLTFLoader();

const BONE_COLORS = {
  head: 0x00ffff,
  neck: 0x00cccc,
  spine: 0xff0000,
  chest: 0xff4444,
  upperArmL: 0x4488ff,
  upperArmR: 0x4488ff,
  lowerArmL: 0x4488ff,
  lowerArmR: 0x4488ff,
  handL: 0x4488ff,
  handR: 0x4488ff,
  upperLegL: 0x44ff44,
  upperLegR: 0x44ff44,
  lowerLegL: 0x44ff44,
  lowerLegR: 0x44ff44,
  footL: 0x44ff44,
  footR: 0x44ff44,
};

export async function loadCharacter(slug, glbPath) {
  if (state.characters.has(slug)) {
    console.log('[previs] character already loaded:', slug);
    return;
  }

  document.getElementById('status').innerText = `Loading ${slug}...`;

  try {
    const gltf = await loader.loadAsync(glbPath);
    const model = gltf.scene;

    model.position.set(0, 0, 0);
    model.scale.set(1, 1, 1);
    state.scene.add(model);

    const skeleton = extractSkeleton(model);
    const boneHandles = createBoneHandles(skeleton);
    boneHandles.forEach(h => state.scene.add(h));

    state.characters.set(slug, {
      model,
      skeleton,
      boneHandles,
      position: [0, 0, 0],
      rotation: [0, 0, 0],
      scale: 1,
    });

    document.getElementById('status').innerText = '';
    console.log('[previs] loaded character:', slug);
  } catch (err) {
    document.getElementById('status').innerText = `Failed to load ${slug}`;
    console.error('[previs] load error:', err);
  }
}

function extractSkeleton(model) {
  const bones = [];
  model.traverse(node => {
    if (node.isBone) {
      bones.push(node);
    }
  });

  const named = {};
  bones.forEach(b => {
    const lower = b.name.toLowerCase();
    if (lower.includes('head')) named.head = b;
    else if (lower.includes('neck')) named.neck = b;
    else if (lower.includes('spine') && !lower.includes('lower') && !lower.includes('upper')) named.spine = b;
    else if (lower.includes('chest') || lower.includes('upper') && lower.includes('spine')) named.chest = b;
    else if (lower.includes('upper') && (lower.includes('arm') || lower.includes('shoulder')) && (lower.includes('left') || lower.includes('l'))) named.upperArmL = b;
    else if (lower.includes('upper') && (lower.includes('arm') || lower.includes('shoulder')) && (lower.includes('right') || lower.includes('r'))) named.upperArmR = b;
    else if (lower.includes('lower') && lower.includes('arm') && (lower.includes('left') || lower.includes('l'))) named.lowerArmL = b;
    else if (lower.includes('lower') && lower.includes('arm') && (lower.includes('right') || lower.includes('r'))) named.lowerArmR = b;
    else if (lower.includes('hand') && (lower.includes('left') || lower.includes('l'))) named.handL = b;
    else if (lower.includes('hand') && (lower.includes('right') || lower.includes('r'))) named.handR = b;
    else if (lower.includes('upper') && (lower.includes('leg') || lower.includes('thigh')) && (lower.includes('left') || lower.includes('l'))) named.upperLegL = b;
    else if (lower.includes('upper') && (lower.includes('leg') || lower.includes('thigh')) && (lower.includes('right') || lower.includes('r'))) named.upperLegR = b;
    else if (lower.includes('lower') && lower.includes('leg') && (lower.includes('left') || lower.includes('l'))) named.lowerLegL = b;
    else if (lower.includes('lower') && lower.includes('leg') && (lower.includes('right') || lower.includes('r'))) named.lowerLegR = b;
    else if ((lower.includes('foot') || lower.includes('heel')) && (lower.includes('left') || lower.includes('l'))) named.footL = b;
    else if ((lower.includes('foot') || lower.includes('heel')) && (lower.includes('right') || lower.includes('r'))) named.footR = b;
  });

  return named;
}

function createBoneHandles(skeleton) {
  const handles = [];
  for (const [name, bone] of Object.entries(skeleton)) {
    if (!bone) continue;

    const color = BONE_COLORS[name] || 0xffffff;
    const sphere = new THREE.Mesh(
      new THREE.SphereGeometry(0.04, 8, 8),
      new THREE.MeshBasicMaterial({ color, wireframe: true })
    );
    sphere.position.copy(bone.position);
    sphere.userData.boneName = name;
    sphere.userData.boneRef = bone;
    sphere.userData.isBoneHandle = true;
    handles.push(sphere);
  }
  return handles;
}

export function removeCharacter(slug) {
  const entry = state.characters.get(slug);
  if (!entry) return;
  state.scene.remove(entry.model);
  entry.boneHandles.forEach(h => state.scene.remove(h));
  state.characters.delete(slug);
}
