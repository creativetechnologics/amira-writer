import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const state = {
  scene: null,
  camera: null,
  renderer: null,
  controls: null,
  layers: { terrain: null, buildings: null, roads: null, water: null },
  heightmapFn: null,
  sceneData: null,
};

init();

async function init() {
  const app = document.getElementById('app');
  state.renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
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
  state.scene.fog = new THREE.Fog(0x2a3340, 7000, 22000);

  state.camera = new THREE.PerspectiveCamera(55, window.innerWidth / window.innerHeight, 1, 20000);
  state.controls = new OrbitControls(state.camera, state.renderer.domElement);
  state.controls.enableDamping = true;
  state.controls.dampingFactor = 0.08;
  state.controls.minDistance = 100;
  state.controls.maxDistance = 8000;

  window.addEventListener('resize', onResize);
  bindHUD();

  setInfo('Loading scene.json…');
  const sceneResp = await fetch('scene.json');
  if (!sceneResp.ok) { setInfo('scene.json not found — run 04_compose_scene.py first.'); return; }
  state.sceneData = await sceneResp.json();

  setInfo('Loading textures…');
  const loader = new THREE.TextureLoader();
  const [tex, hmapImg] = await Promise.all([
    loadTexture(loader, state.sceneData.assets.texture_url),
    loadImageData(state.sceneData.assets.heightmap_url),
  ]);

  state.heightmapFn = makeHeightmapSampler(hmapImg, state.sceneData);

  buildLights(state.sceneData);
  state.layers.terrain = buildTerrain(state.sceneData, tex);
  state.scene.add(state.layers.terrain);
  state.layers.buildings = buildBuildings(state.sceneData);
  state.scene.add(state.layers.buildings);
  state.layers.roads = buildRoadsFromLineStrings(state.sceneData);
  state.scene.add(state.layers.roads);
  state.layers.water = buildWater(state.sceneData);
  state.scene.add(state.layers.water);
  bindBuildingPicker();

  resetView();
  renderInfoSummary();
  animate();
}

function loadTexture(loader, url) {
  return new Promise((res, rej) => {
    loader.load(url, (t) => { t.colorSpace = THREE.SRGBColorSpace; res(t); }, undefined, rej);
  });
}

function loadImageData(url) {
  return new Promise((res, rej) => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => {
      const canvas = document.createElement('canvas');
      canvas.width = img.naturalWidth; canvas.height = img.naturalHeight;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(img, 0, 0);
      const d = ctx.getImageData(0, 0, canvas.width, canvas.height);
      res({ width: d.width, height: d.height, data: d.data });
    };
    img.onerror = rej;
    img.src = url;
  });
}

function makeHeightmapSampler(hm, scene) {
  const { width, height, data } = hm;
  const peak = scene.world.peak_alt_m;
  // 8-bit PNG (browser re-decoded). Heightmap stored as 16-bit, but most
  // browsers decode to 8-bit via the 2D canvas. Use G channel as the height
  // proxy; for a 16-bit grayscale, G=high byte. Sufficient for terrain.
  return function sampleWorld(worldX, worldZ) {
    // world -> image px
    const mpp = scene.world.meters_per_pixel;
    const imgW = scene.world.image_w_px;
    const imgH = scene.world.image_h_px;
    const px = (worldX / mpp) + imgW / 2;
    const py = (worldZ / mpp) + imgH / 2;
    // -> heightmap px
    const hx = (px / imgW) * width;
    const hy = (py / imgH) * height;
    return sampleHeightmapPx(hx, hy, width, height, data, peak);
  };
}

function sampleHeightmapPx(hx, hy, w, h, data, peak) {
  // Bilinear sampling on the packed R=high G=low 16-bit heightmap.
  const fx = Math.max(0, Math.min(w - 1, hx));
  const fy = Math.max(0, Math.min(h - 1, hy));
  const x0 = Math.floor(fx), y0 = Math.floor(fy);
  const x1 = Math.min(w - 1, x0 + 1), y1 = Math.min(h - 1, y0 + 1);
  const tx = fx - x0, ty = fy - y0;
  const samp = (x, y) => {
    const i = (y * w + x) * 4;
    return (data[i] * 256 + data[i + 1]) / 65535.0;
  };
  const a = samp(x0, y0), b = samp(x1, y0), c = samp(x0, y1), d = samp(x1, y1);
  const v = a * (1 - tx) * (1 - ty) + b * tx * (1 - ty) + c * (1 - tx) * ty + d * tx * ty;
  return v * peak;
}

function buildLights(sc) {
  const sun = sc.sun;
  const az = THREE.MathUtils.degToRad(sun.azimuth_deg);
  const el = THREE.MathUtils.degToRad(sun.elevation_deg);
  // World: +X east, +Y up, +Z south. Azimuth measured clockwise from north.
  const dir = new THREE.Vector3(
    Math.sin(az) * Math.cos(el),
    Math.sin(el),
    -Math.cos(az) * Math.cos(el)
  );
  const sunLight = new THREE.DirectionalLight(0xfff1dc, 2.2);
  const L = sc.world.image_w_px * sc.world.meters_per_pixel;
  sunLight.position.copy(dir.multiplyScalar(L));
  sunLight.target.position.set(0, 0, 0);
  sunLight.castShadow = true;
  sunLight.shadow.mapSize.width = 2048;
  sunLight.shadow.mapSize.height = 2048;
  const halfW = (sc.world.image_w_px * sc.world.meters_per_pixel) / 2;
  const halfH = (sc.world.image_h_px * sc.world.meters_per_pixel) / 2;
  sunLight.shadow.camera.left = -halfW;
  sunLight.shadow.camera.right = halfW;
  sunLight.shadow.camera.top = halfH;
  sunLight.shadow.camera.bottom = -halfH;
  sunLight.shadow.camera.near = 10;
  sunLight.shadow.camera.far = L * 2.5;
  sunLight.shadow.bias = -0.0006;
  sunLight.shadow.normalBias = 0.5;
  state.scene.add(sunLight);
  state.scene.add(sunLight.target);
  state.scene.add(new THREE.AmbientLight(0xb4c4e0, 0.75));
  state.scene.add(new THREE.HemisphereLight(0xcfe1ff, 0x5a4732, 0.85));
}

function buildTerrain(sc, tex) {
  const { image_w_px, image_h_px, meters_per_pixel, peak_alt_m } = sc.world;
  const W = image_w_px * meters_per_pixel;
  const H = image_h_px * meters_per_pixel;
  const segX = 384, segZ = 203;
  const geom = new THREE.PlaneGeometry(W, H, segX, segZ);
  geom.rotateX(-Math.PI / 2);
  // After rotation: plane lies in X-Z with normal in +Y.
  // Original UVs map (0,0) -> (-W/2, -H/2), (1,1) -> (+W/2, +H/2).
  // But image has y going DOWN (south), and after rotation, positive-Z = south.
  // PlaneGeometry's default UV has V going up; we want V going "down in image" = "south in world" = +Z.
  // Inspect: after rotateX(-π/2), original (x, y) -> (x, 0, -y). So original +y maps to -Z (north).
  // That means V=1 (was top of plane, +y) is now -Z (north). We want V=1 (top of texture = north in IMAGE? No, image top is north). Actually image top-left is (x=0, y=0) and we mapped y=0 -> world Z = -H/2. So world_Z=-H/2 = image_y=0 = image top = north. ✓
  // For UVs: after rotation, UV(u=0,v=1) is at world (-W/2, 0, -H/2) i.e. image top-left. We want texture(u=0,v=1)? Actually TextureLoader with default texture coord means image (0,0) is at UV(0,1) (OpenGL) or (0,0) (flipY false). With default THREE.Texture: flipY=true by default, so image top = v=1. So UV(0,1) should correspond to image top-left = world (-W/2, 0, -H/2). Let's check: after rotateX(-π/2), original (x=-W/2, y=+H/2, 0) becomes (-W/2, 0, -H/2) ✓ and that vertex had UV (0, 1). So UV mapping is correct.

  const pos = geom.attributes.position;
  // Displace each vertex via the heightmap.
  for (let i = 0; i < pos.count; i++) {
    const wx = pos.getX(i);
    const wz = pos.getZ(i);
    const y = state.heightmapFn(wx, wz);
    pos.setY(i, y);
  }
  geom.computeVertexNormals();

  const mat = new THREE.MeshStandardMaterial({
    map: tex,
    roughness: 0.9,
    metalness: 0.0,
  });
  const mesh = new THREE.Mesh(geom, mat);
  mesh.userData.layer = 'terrain';
  mesh.userData.tex = tex;  // remembered so the Map-drape toggle can restore it
  mesh.receiveShadow = true;
  return mesh;
}

function buildBuildings(sc) {
  const group = new THREE.Group();
  group.userData.layer = 'buildings';
  const { image_w_px, image_h_px, meters_per_pixel } = sc.world;
  const W = image_w_px * meters_per_pixel;
  const D = image_h_px * meters_per_pixel;
  const tex = state.layers.terrain?.userData.tex;
  // Generate UVs on the top/bottom caps so each rooftop samples the same spot
  // of the map drape → rooftop texture matches the 2D view from above.
  // In extrude local coords (pre-rotateX), vertex.x = worldX and vertex.y = -worldZ,
  // because of how pxRingToShape constructs the Shape.
  const topUvGen = {
    generateTopUV: (_g, vertices, ia, ib, ic) => {
      const uv = (idx) => {
        const x = vertices[idx * 3];
        const y = vertices[idx * 3 + 1];
        const u = (x + W / 2) / W;
        const v = (y + D / 2) / D;
        return new THREE.Vector2(u, v);
      };
      return [uv(ia), uv(ib), uv(ic)];
    },
    generateSideWallUV: (_g, _verts, _ia, _ib, _ic, _id) => ([
      new THREE.Vector2(0, 0),
      new THREE.Vector2(1, 0),
      new THREE.Vector2(1, 1),
      new THREE.Vector2(0, 1),
    ]),
  };
  const roofMat = new THREE.MeshStandardMaterial({
    map: tex,
    roughness: 0.85, metalness: 0.02,
  });
  const wallMat = new THREE.MeshStandardMaterial({
    color: 0x746155,
    roughness: 0.95, metalness: 0.0,
  });
  for (const feat of sc.buildings.features) {
    const rings = feat.geometry.type === 'Polygon'
      ? [feat.geometry.coordinates]
      : feat.geometry.coordinates;
    const height = feat.properties.height_m || 6;
    for (const poly of rings) {
      const outer = poly[0];
      const shape = pxRingToShape(outer, image_w_px, image_h_px, meters_per_pixel);
      for (let h = 1; h < poly.length; h++) {
        shape.holes.push(pxRingToPath(poly[h], image_w_px, image_h_px, meters_per_pixel));
      }
      const geom = new THREE.ExtrudeGeometry(shape, {
        depth: height,
        bevelEnabled: false,
        UVGenerator: topUvGen,
      });
      geom.rotateX(-Math.PI / 2);
      const cx = feat.properties.centroid_px[0];
      const cy = feat.properties.centroid_px[1];
      const wx = (cx - image_w_px / 2) * meters_per_pixel;
      const wz = (cy - image_h_px / 2) * meters_per_pixel;
      const base = state.heightmapFn(wx, wz);
      geom.translate(0, base, 0);
      // ExtrudeGeometry uses material index 0 for front+back caps and 1 for side walls.
      const mesh = new THREE.Mesh(geom, [roofMat, wallMat]);
      mesh.userData.label = feat.properties.label;
      mesh.userData.feature = feat;
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      group.add(mesh);
    }
  }
  return group;
}

function pxRingToShape(ring, W, H, mpp) {
  const shape = new THREE.Shape();
  for (let i = 0; i < ring.length; i++) {
    const [px, py] = ring[i];
    const X = (px - W / 2) * mpp;
    const Yshape = -((py - H / 2) * mpp);  // flip so rotation gives +Z = south
    if (i === 0) shape.moveTo(X, Yshape); else shape.lineTo(X, Yshape);
  }
  return shape;
}

function pxRingToPath(ring, W, H, mpp) {
  const p = new THREE.Path();
  for (let i = 0; i < ring.length; i++) {
    const [px, py] = ring[i];
    const X = (px - W / 2) * mpp;
    const Yshape = -((py - H / 2) * mpp);
    if (i === 0) p.moveTo(X, Yshape); else p.lineTo(X, Yshape);
  }
  return p;
}

function buildRoads(sc) {
  const group = new THREE.Group();
  group.userData.layer = 'roads';
  const { image_w_px, image_h_px, meters_per_pixel } = sc.world;
  for (const feat of sc.roads.features) {
    const rings = feat.geometry.type === 'Polygon'
      ? [feat.geometry.coordinates]
      : feat.geometry.coordinates;
    const kind = feat.properties.road_kind || 'road';
    const color = kind === 'bridge' ? 0x8c7a5a : 0x4a3f30;
    for (const poly of rings) {
      const outer = poly[0];
      const shape = pxRingToShape(outer, image_w_px, image_h_px, meters_per_pixel);
      for (let h = 1; h < poly.length; h++) {
        shape.holes.push(pxRingToPath(poly[h], image_w_px, image_h_px, meters_per_pixel));
      }
      const geom = new THREE.ShapeGeometry(shape, 32);
      geom.rotateX(-Math.PI / 2);
      // Drape by sampling terrain at each vertex and lifting slightly.
      const pos = geom.attributes.position;
      const lift = kind === 'bridge' ? 3.0 : 0.8;
      for (let i = 0; i < pos.count; i++) {
        const wx = pos.getX(i);
        const wz = pos.getZ(i);
        pos.setY(i, state.heightmapFn(wx, wz) + lift);
      }
      geom.computeVertexNormals();
      const mat = new THREE.MeshStandardMaterial({
        color, roughness: 0.95, metalness: 0.0,
        transparent: true, opacity: 0.9,
        polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -1,
      });
      const mesh = new THREE.Mesh(geom, mat);
      mesh.userData.label = feat.properties.label;
      group.add(mesh);
    }
  }
  return group;
}

function buildWater(sc) {
  const group = new THREE.Group();
  group.userData.layer = 'water';
  const { image_w_px, image_h_px, meters_per_pixel } = sc.world;
  const water_base = sc.world.river_alt_m;
  for (const feat of sc.water.features) {
    const rings = feat.geometry.type === 'Polygon'
      ? [feat.geometry.coordinates]
      : feat.geometry.coordinates;
    for (const poly of rings) {
      const outer = poly[0];
      const shape = pxRingToShape(outer, image_w_px, image_h_px, meters_per_pixel);
      for (let h = 1; h < poly.length; h++) {
        shape.holes.push(pxRingToPath(poly[h], image_w_px, image_h_px, meters_per_pixel));
      }
      const geom = new THREE.ShapeGeometry(shape, 32);
      geom.rotateX(-Math.PI / 2);
      const pos = geom.attributes.position;
      for (let i = 0; i < pos.count; i++) {
        // River surface is a flat plane at river altitude; but to follow the
        // valley floor subtly, sample terrain and take the lower of (river, terrain+0).
        const wx = pos.getX(i);
        const wz = pos.getZ(i);
        const terrain = state.heightmapFn(wx, wz);
        pos.setY(i, Math.min(water_base + 2.0, terrain + 0.5));
      }
      geom.computeVertexNormals();
      const mat = new THREE.MeshStandardMaterial({
        color: 0x2a4a6a, roughness: 0.2, metalness: 0.1,
        transparent: true, opacity: 0.85,
      });
      const mesh = new THREE.Mesh(geom, mat);
      group.add(mesh);
    }
  }
  return group;
}

function bindHUD() {
  for (const cb of document.querySelectorAll('[data-layer]')) {
    cb.addEventListener('change', (e) => {
      const name = e.target.dataset.layer;
      if (name === 'wireframe') {
        toggleWireframe(e.target.checked);
      } else if (name === 'texture') {
        const terrain = state.layers.terrain;
        if (terrain) {
          terrain.material.map = e.target.checked ? terrain.userData.tex : null;
          terrain.material.needsUpdate = true;
        }
      } else if (state.layers[name]) {
        state.layers[name].visible = e.target.checked;
      }
    });
  }
  document.getElementById('resetView').addEventListener('click', resetView);
  document.getElementById('topView').addEventListener('click', topView);
  document.getElementById('captureCard').addEventListener('click', captureGroundingCard);
  const saveBtn = document.getElementById('saveCameraForDraft');
  if (saveBtn) {
    saveBtn.addEventListener('click', saveCameraForDraft);
    // Hide the draft-save button when not running inside the Amira app's
    // WKWebView — it has no meaningful target in a normal browser.
    if (!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.amiraMapCamera)) {
      saveBtn.style.display = 'none';
    }
  }
  window.addEventListener('keydown', (e) => {
    if ((e.key === 'c' || e.key === 'C') && !e.metaKey && !e.ctrlKey && !e.altKey) {
      if (e.target === document.body) captureGroundingCard();
    }
  });
}

function toggleWireframe(on) {
  const walk = (obj) => {
    obj.traverse((o) => { if (o.isMesh && o.material && 'wireframe' in o.material) o.material.wireframe = on; });
  };
  for (const key of Object.keys(state.layers)) if (state.layers[key]) walk(state.layers[key]);
}

function resetView() {
  const W = state.sceneData.world.image_w_px * state.sceneData.world.meters_per_pixel;
  // Orbital aerial view — south-south-west, well above the peaks.
  state.camera.position.set(-W * 0.25, W * 1.3, W * 1.1);
  state.controls.target.set(0, 200, 0);
  state.controls.update();
}

function topView() {
  const W = state.sceneData.world.image_w_px * state.sceneData.world.meters_per_pixel;
  state.camera.position.set(0, W * 1.2, 0.01);
  state.controls.target.set(0, 0, 0);
  state.controls.update();
}

function renderInfoSummary() {
  const sc = state.sceneData;
  const nB = sc.buildings.features.length;
  const nR = sc.roads.features.length;
  const nW = sc.water.features.length;
  const sun = sc.sun;
  const shadowLine = (sun.n_buildings_with_shadow !== undefined)
    ? `Shadow-derived heights: ${sun.n_buildings_with_shadow}/${sun.n_buildings_total}`
    : `Sun: placeholder (no building shadow source yet)`;
  setInfo(
`Source: ${sc.source_image || 'unknown'}
World ${sc.world.image_w_px}×${sc.world.image_h_px} px · ${sc.world.meters_per_pixel.toFixed(2)} m/px
Valley ≈ ${(sc.world.image_w_px * sc.world.meters_per_pixel / 1000).toFixed(2)} km across · peak ${sc.world.peak_alt_m} m
Sun az ${sun.azimuth_deg}° · el ${sun.elevation_deg}°
${shadowLine}
Layers: ${nB} buildings · ${nR} roads · ${nW} water`);
}

function setInfo(t) { document.getElementById('info').textContent = t; }

function onResize() {
  state.renderer.setSize(window.innerWidth, window.innerHeight);
  state.camera.aspect = window.innerWidth / window.innerHeight;
  state.camera.updateProjectionMatrix();
}

function animate() {
  requestAnimationFrame(animate);
  state.controls.update();
  state.renderer.render(state.scene, state.camera);
}

// ---------- Grounding-card capture ----------
// Snapshots the current camera + scene into a PNG + structured JSON package
// that can be fed into Gemini image generation to produce canon-consistent
// new imagery from this exact viewpoint.

// Post the current camera state back to the Swift host app (Amira Writer) so
// it can attach it to a Gemini-generation draft. Invoked by the "💾 Save
// camera for draft" button. Only works when the viewer is hosted inside
// WKWebView with a `amiraMapCamera` message handler registered.
function saveCameraForDraft() {
  try {
    const meta = buildGroundingCardMetadata('camera_for_draft', 'Camera for draft');
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.amiraMapCamera) {
      window.webkit.messageHandlers.amiraMapCamera.postMessage(meta);
      const info = document.getElementById('info');
      if (info) {
        const prev = info.textContent;
        info.textContent = 'Camera sent to draft ✓\n\n' + prev;
        setTimeout(() => { info.textContent = prev; }, 2500);
      }
    }
  } catch (err) {
    console.error('saveCameraForDraft failed:', err);
  }
}

function captureGroundingCard() {
  const defaultName = `view_${Math.floor(Date.now() / 1000)}`;
  const name = prompt('Name this view (used for filenames):', defaultName);
  if (!name) return;
  const slug = name.replace(/[^a-z0-9_\-]/gi, '_').toLowerCase() || defaultName;

  // Force one render so the drawing buffer is fresh.
  state.renderer.render(state.scene, state.camera);
  const pngDataUrl = state.renderer.domElement.toDataURL('image/png');

  const meta = buildGroundingCardMetadata(slug, name);
  const jsonBlob = new Blob([JSON.stringify(meta, null, 2)], { type: 'application/json' });

  triggerDownload(pngDataUrl, `${slug}.png`);
  triggerDownload(URL.createObjectURL(jsonBlob), `${slug}.json`);

  const info = document.getElementById('info');
  if (info) {
    const prev = info.textContent;
    info.textContent = `Captured → ${slug}.png + ${slug}.json\n\n` + prev;
    setTimeout(() => { info.textContent = prev; }, 4500);
  }
}

function buildGroundingCardMetadata(slug, displayName) {
  const sc = state.sceneData;
  const cam = state.camera;
  const tgt = state.controls.target;

  const camPos = cam.position.clone();
  const lookAt = tgt.clone();
  const forward = new THREE.Vector3().subVectors(lookAt, camPos).normalize();
  const distance = camPos.distanceTo(lookAt);
  const { meters_per_pixel, image_w_px, image_h_px } = sc.world;

  // Sample terrain altitude directly under the camera.
  const terrainUnderCam = state.heightmapFn(camPos.x, camPos.z);

  // Compass heading (0° north, 90° east). World: +X east, +Z south.
  const headingRad = Math.atan2(forward.x, -forward.z);
  const headingDeg = ((headingRad * 180 / Math.PI) + 360) % 360;
  const headingName = cardinalName(headingDeg);

  // Visible features: project building centroids into camera NDC.
  const visibleBuildings = [];
  const ndc = new THREE.Vector3();
  for (const feat of sc.buildings.features) {
    const c = feat.properties.centroid_px;
    if (!c || c.length !== 2) continue;
    const wx = (c[0] - image_w_px / 2) * meters_per_pixel;
    const wz = (c[1] - image_h_px / 2) * meters_per_pixel;
    const base = state.heightmapFn(wx, wz);
    ndc.set(wx, base + (feat.properties.height_m || 6) / 2, wz).project(cam);
    if (ndc.z < -1 || ndc.z > 1) continue;
    if (ndc.x < -1.2 || ndc.x > 1.2) continue;
    if (ndc.y < -1.2 || ndc.y > 1.2) continue;
    const dist = Math.hypot(camPos.x - wx, camPos.y - (base + 4), camPos.z - wz);
    visibleBuildings.push({
      label: feat.properties.label || feat.properties.id || `building_${feat.properties.index ?? ''}`,
      centroid_px: c,
      height_m: feat.properties.height_m,
      distance_m: Math.round(dist),
      ndc_x: +ndc.x.toFixed(3),
      ndc_y: +ndc.y.toFixed(3),
    });
  }
  visibleBuildings.sort((a, b) => a.distance_m - b.distance_m);

  const visibleWater = [];
  for (const feat of sc.water.features) {
    const ring = feat.geometry.type === 'Polygon' ? feat.geometry.coordinates[0] : feat.geometry.coordinates[0][0];
    if (!ring || !ring.length) continue;
    let sx = 0, sy = 0;
    for (const [x, y] of ring) { sx += x; sy += y; }
    sx /= ring.length; sy /= ring.length;
    const wx = (sx - image_w_px / 2) * meters_per_pixel;
    const wz = (sy - image_h_px / 2) * meters_per_pixel;
    ndc.set(wx, sc.world.river_alt_m + 2, wz).project(cam);
    if (ndc.z < -1 || ndc.z > 1) continue;
    if (Math.abs(ndc.x) > 1.2 || Math.abs(ndc.y) > 1.2) continue;
    const dist = Math.hypot(camPos.x - wx, camPos.y, camPos.z - wz);
    visibleWater.push({
      label: feat.properties.label || `water_${feat.properties.index ?? 0}`,
      distance_m: Math.round(dist),
    });
  }
  visibleWater.sort((a, b) => a.distance_m - b.distance_m);

  // Find ground hit point ahead of the camera (what the viewer is "looking at").
  let focalPoint = null;
  try {
    const raycaster = new THREE.Raycaster(camPos, forward, 1, 50000);
    const candidates = [];
    if (state.layers.terrain) candidates.push(state.layers.terrain);
    const hits = raycaster.intersectObjects(candidates, false);
    if (hits.length) {
      const p = hits[0].point;
      focalPoint = {
        world_m: [+p.x.toFixed(1), +p.y.toFixed(1), +p.z.toFixed(1)],
        distance_m: Math.round(hits[0].distance),
      };
    }
  } catch { /* raycast is best-effort */ }

  const promptLines = [
    `Generate a photograph of the Amira valley scene taken from this exact camera position.`,
    `The camera stands at world coordinates (X=${camPos.x.toFixed(0)}, Y=${camPos.y.toFixed(0)}, Z=${camPos.z.toFixed(0)}) — approximately ${(camPos.y - terrainUnderCam).toFixed(0)} m above local ground, at an elevation of ${camPos.y.toFixed(0)} m ASL.`,
    `Looking toward (X=${lookAt.x.toFixed(0)}, Y=${lookAt.y.toFixed(0)}, Z=${lookAt.z.toFixed(0)}), compass heading ${headingDeg.toFixed(0)}° (${headingName}), field of view ${cam.fov}°.`,
    `Scene context: Himalayan-style valley, world width ≈ ${(sc.world.world_width_m / 1000).toFixed(1)} km, peak mountain ≈ ${Math.round(sc.world.peak_alt_m)} m above the river.`,
  ];
  if (visibleBuildings.length) {
    const names = visibleBuildings.slice(0, 6).map(b => `${b.label} (${b.distance_m}m)`).join(', ');
    promptLines.push(`In frame — buildings (closest first): ${names}.`);
  }
  if (visibleWater.length) {
    promptLines.push(`Water in frame: ${visibleWater.slice(0, 3).map(w => `${w.label} @ ~${w.distance_m}m`).join(', ')}.`);
  }
  promptLines.push(`Match the existing master-map aesthetic (weathered stone houses, ochre dirt, blue glacial meltwater, scrubby mountain vegetation).`);

  return {
    schema_version: 1,
    created_at: new Date().toISOString(),
    name: displayName,
    slug,
    source_map: sc.source_image || null,
    camera: {
      position_m: [+camPos.x.toFixed(2), +camPos.y.toFixed(2), +camPos.z.toFixed(2)],
      look_at_m: [+lookAt.x.toFixed(2), +lookAt.y.toFixed(2), +lookAt.z.toFixed(2)],
      fov_deg: cam.fov,
      elevation_asl_m: +camPos.y.toFixed(1),
      altitude_above_ground_m: +(camPos.y - terrainUnderCam).toFixed(1),
      compass_heading_deg: +headingDeg.toFixed(1),
      heading_name: headingName,
      focal_distance_m: distance,
    },
    world: {
      image_w_px: sc.world.image_w_px,
      image_h_px: sc.world.image_h_px,
      meters_per_pixel: sc.world.meters_per_pixel,
      world_width_m: sc.world.world_width_m,
      peak_alt_m: sc.world.peak_alt_m,
      river_alt_m: sc.world.river_alt_m,
    },
    sun: sc.sun,
    visible_in_frame: {
      buildings: visibleBuildings,
      water: visibleWater,
      focal_point: focalPoint,
    },
    gemini_prompt_template: promptLines.join(' '),
  };
}

function cardinalName(deg) {
  const directions = ['N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW'];
  return directions[Math.round(((deg % 360) / 22.5)) % 16];
}

// ---------- Road rendering (flat gray overlay, Google-Earth style) ----------
// Each LineString is densely resampled along the terrain, then a thin flat
// ribbon is generated by offsetting each point perpendicular to the path.
// The ribbon sits a few cm above the terrain and uses an unlit material with
// polygonOffset to avoid z-fighting.

function buildRoadsFromLineStrings(sc) {
  const group = new THREE.Group();
  group.userData.layer = 'roads';
  const { image_w_px, image_h_px, meters_per_pixel } = sc.world;
  const RIBBON_HALF_WIDTH_M = 2.0;
  const RIBBON_LIFT_M = 2.0;
  const mat = new THREE.MeshBasicMaterial({
    color: 0x9a9a9a,
    transparent: true,
    opacity: 0.7,
    side: THREE.DoubleSide,
    depthWrite: false,
    polygonOffset: true,
    polygonOffsetFactor: -4,
    polygonOffsetUnits: -4,
  });
  const roadFeats = sc.roads?.features || [];
  for (const feat of roadFeats) {
    const geom = feat.geometry;
    if (!geom) continue;
    const lines = geom.type === 'MultiLineString' ? geom.coordinates
                 : geom.type === 'LineString' ? [geom.coordinates] : [];
    for (const coords of lines) {
      if (!coords || coords.length < 2) continue;
      const pts = [];
      for (const [px, py] of coords) {
        const x = (px - image_w_px / 2) * meters_per_pixel;
        const z = (py - image_h_px / 2) * meters_per_pixel;
        pts.push({ x, z });
      }
      const mesh = buildFlatRibbon(pts, RIBBON_HALF_WIDTH_M, RIBBON_LIFT_M, mat);
      if (mesh) {
        mesh.userData.feature = feat;
        group.add(mesh);
      }
    }
  }
  return group;
}

function buildFlatRibbon(pts, halfWidth, lift, material) {
  const n = pts.length;
  if (n < 2) return null;
  const positions = new Float32Array(n * 2 * 3);
  for (let i = 0; i < n; i++) {
    // Compute perpendicular direction in the XZ plane.
    let dx, dz;
    if (i === 0) {
      dx = pts[1].x - pts[0].x;
      dz = pts[1].z - pts[0].z;
    } else if (i === n - 1) {
      dx = pts[n - 1].x - pts[n - 2].x;
      dz = pts[n - 1].z - pts[n - 2].z;
    } else {
      dx = pts[i + 1].x - pts[i - 1].x;
      dz = pts[i + 1].z - pts[i - 1].z;
    }
    const len = Math.hypot(dx, dz) || 1;
    // Perpendicular (rotate 90° in XZ plane): (-dz, dx) normalised.
    const nx = -dz / len;
    const nz = dx / len;
    const left = { x: pts[i].x + nx * halfWidth, z: pts[i].z + nz * halfWidth };
    const right = { x: pts[i].x - nx * halfWidth, z: pts[i].z - nz * halfWidth };
    const yL = state.heightmapFn(left.x, left.z) + lift;
    const yR = state.heightmapFn(right.x, right.z) + lift;
    positions[i * 6 + 0] = left.x;
    positions[i * 6 + 1] = yL;
    positions[i * 6 + 2] = left.z;
    positions[i * 6 + 3] = right.x;
    positions[i * 6 + 4] = yR;
    positions[i * 6 + 5] = right.z;
  }
  const indices = [];
  for (let i = 0; i < n - 1; i++) {
    const a = i * 2, b = a + 1, c = a + 2, d = a + 3;
    indices.push(a, c, b);
    indices.push(b, c, d);
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  geo.setIndex(indices);
  geo.computeVertexNormals();
  const mesh = new THREE.Mesh(geo, material);
  mesh.castShadow = false;
  mesh.receiveShadow = false;
  mesh.renderOrder = 2;  // draw after terrain
  return mesh;
}

// ---------- Click-to-label buildings ----------

function bindBuildingPicker() {
  const raycaster = new THREE.Raycaster();
  const mouse = new THREE.Vector2();
  state.renderer.domElement.addEventListener('click', (evt) => {
    if (!state.layers.buildings) return;
    const rect = state.renderer.domElement.getBoundingClientRect();
    mouse.x = ((evt.clientX - rect.left) / rect.width) * 2 - 1;
    mouse.y = -((evt.clientY - rect.top) / rect.height) * 2 + 1;
    raycaster.setFromCamera(mouse, state.camera);
    const hits = raycaster.intersectObjects(state.layers.buildings.children, false);
    if (!hits.length) { clearSelection(); return; }
    const hit = hits[0];
    showBuildingLabel(hit.object, hit.point);
  });
}

function clearSelection() {
  const el = document.getElementById('selection-label');
  if (el) el.remove();
}

function showBuildingLabel(mesh, worldPoint) {
  const feat = mesh.userData.feature;
  const props = feat ? feat.properties : { label: mesh.userData.label };
  clearSelection();
  const el = document.createElement('div');
  el.id = 'selection-label';
  el.style.cssText = `position: fixed; z-index: 20; background: rgba(18,20,24,0.9); backdrop-filter: blur(10px); padding: 10px 12px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.12); color: #e8eaed; font-size: 12px; max-width: 280px; pointer-events: auto;`;
  const title = props.label || 'Unnamed building';
  const kind = props.canonical_kind ? `<div style="color:#9ae6b4; font-size:10px; text-transform:uppercase; letter-spacing:0.04em; margin-bottom:4px;">${props.canonical_kind}</div>` : '';
  const near = props.nearest_landmark ? `<div style="color:#8a8f96; margin-top:6px;">Nearest landmark: ${props.nearest_landmark.title} (${Math.round(props.nearest_landmark.distance_m)} m)</div>` : '';
  el.innerHTML = `
    ${kind}
    <div style="font-weight:600; margin-bottom:4px;">${title}</div>
    <div style="color:#8a8f96; font-size:11px;">
      height ${props.height_m ?? '?'} m · area ${props.area_m2 ?? '?'} m² · slope ${props.slope_deg ?? '?'}°
    </div>
    ${near}
    <button id="dismiss-sel" style="margin-top:8px; background:#2a2d33; color:#d0d3d8; border:1px solid rgba(255,255,255,0.08); border-radius:4px; padding:3px 8px; font-size:10px; cursor:pointer;">Dismiss</button>
  `;
  const rect = state.renderer.domElement.getBoundingClientRect();
  // Place near the cursor or near the top-right.
  el.style.top = '14px';
  el.style.right = '14px';
  document.body.appendChild(el);
  document.getElementById('dismiss-sel')?.addEventListener('click', clearSelection);
}

function triggerDownload(href, filename) {
  const a = document.createElement('a');
  a.href = href;
  a.download = filename;
  a.style.display = 'none';
  document.body.appendChild(a);
  a.click();
  setTimeout(() => a.remove(), 100);
}
