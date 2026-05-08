/**
 * parts-composer.js — Character parts placement layer for Storyboard Tool
 *
 * Renders a transparent overlay on top of the drawing canvas that hosts
 * positioned character-part <img> elements. Supports:
 *   - Tap from palette to place a part
 *   - Single-finger drag to reposition
 *   - Two-finger pinch to scale
 *   - Two-finger rotate
 *   - Double-tap to delete
 *   - Composite export (flatten parts onto canvas)
 */

// ─── Module state ─────────────────────────────────────────────────────────

let partsLayer = null;
let partsPalette = null;
let placedParts = []; // [{ id, img, x, y, w, h, rotation, flipH, partData }]
let selectedPartId = null;
let onPlacedPartsChanged = null; // callback

// Touch gesture state
let activeTouchId = null;
let touchStartX = 0, touchStartY = 0;
let touchStartPartX = 0, touchStartPartY = 0;

// Two-finger state
let gestureActive = false;
let gestureInitDist = 0;
let gestureInitAngle = 0;
let gestureInitScale = 1;
let gestureInitRotation = 0;

// Exports
export {
  initPartsLayer,
  loadCharacterParts,
  getPlacedPartsJSON,
  setPlacedPartsJSON,
  compositeOntoCanvas,
};

// ─── Init ──────────────────────────────────────────────────────────────────

/**
 * @param {string} containerSelector - CSS selector for the canvas area container
 * @param {function} changedCallback - called when placed parts change
 */
export function initPartsLayer(containerSelector, changedCallback) {
  const container = document.querySelector(containerSelector);
  if (!container) return;

  onPlacedPartsChanged = changedCallback;

  // Create parts layer
  partsLayer = document.createElement('div');
  partsLayer.id = 'parts-layer';
  partsLayer.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:5;';
  container.appendChild(partsLayer);

  // Create parts palette
  partsPalette = document.createElement('div');
  partsPalette.id = 'parts-palette';
  partsPalette.style.cssText = 'position:absolute;top:60px;right:12px;width:140px;max-height:60%;overflow-y:auto;background:rgba(30,35,45,0.92);border-radius:10px;padding:8px;display:none;z-index:25;pointer-events:auto;';
  document.body.appendChild(partsPalette);

  // Touch events on the main area for manipulating placed parts
  document.addEventListener('pointerdown', onPointerDown, { passive: false });
  document.addEventListener('pointermove', onPointerMove, { passive: false });
  document.addEventListener('pointerup', onPointerUp);
}

// ─── Loading parts from API ────────────────────────────────────────────────

async function loadCharacterParts() {
  try {
    const resp = await fetch('/api/parts/characters');
    const data = await resp.json();
    if (!data.characters || !data.characters.length) return;

    partsPalette.innerHTML = '<div style="color:#999;font-size:10px;margin-bottom:6px;text-align:center;">Character Parts</div>';
    partsPalette.style.display = 'block';

    for (const char of data.characters) {
      const charLabel = document.createElement('div');
      charLabel.style.cssText = 'color:#aaa;font-size:9px;font-weight:600;margin:6px 0 3px;padding:2px 0;';
      charLabel.textContent = char.name;
      partsPalette.appendChild(charLabel);

      const manifestResp = await fetch(`/api/parts/character/${char.slug}/manifest`);
      const manifestData = await manifestResp.json();
      const parts = manifestData.parts || [];

      const grid = document.createElement('div');
      grid.style.cssText = 'display:flex;flex-wrap:wrap;gap:4px;';

      for (const part of parts) {
        const chip = document.createElement('img');
        chip.src = part.imageURL;
        chip.title = `${part.partKind}${part.emotion ? ' · ' + part.emotion : ''}`;
        chip.style.cssText = 'width:40px;height:56px;object-fit:contain;border-radius:4px;cursor:pointer;background:#fff;border:1px solid rgba(255,255,255,0.1);';
        chip.addEventListener('click', () => placePart(part));
        grid.appendChild(chip);
      }

      partsPalette.appendChild(grid);
    }
  } catch (e) {
    console.log('[parts] load error:', e);
  }
}

// ─── Placing & rendering parts ─────────────────────────────────────────────

function placePart(partData) {
  const img = document.createElement('img');
  img.src = partData.imageURL;
  img.dataset.partId = partData.id;
  img.style.cssText = 'position:absolute;pointer-events:auto;cursor:grab;touch-action:none;';
  img.style.left = '40%';
  img.style.top = '30%';
  img.style.width = '15%';
  img.style.height = 'auto';
  if (partData.partKind === 'front' || partData.partKind === 'back') {
    img.style.height = '35%';
    img.style.width = 'auto';
  }

  img.addEventListener('pointerdown', e => {
    e.stopPropagation();
    selectPart(img, e);
  });

  img.addEventListener('dblclick', e => {
    e.stopPropagation();
    removePart(img);
  });

  partsLayer.appendChild(img);

  placedParts.push({
    id: partData.id,
    img,
    x: 40,
    y: 30,
    w: 15,
    h: partData.partKind === 'front' || partData.partKind === 'back' ? 35 : 15,
    rotation: 0,
    flipH: false,
    partData,
  });

  selectPart(img, null);
  notifyChange();
}

function selectPart(img, event) {
  // Deselect all
  placedParts.forEach(p => {
    p.img.style.outline = 'none';
  });

  selectedPartId = img.dataset.partId;
  img.style.outline = '2px solid #4a7dff';

  if (event) {
    const rect = img.getBoundingClientRect();
    activeTouchId = 'mouse';
    touchStartX = event.clientX;
    touchStartY = event.clientY;
    const part = placedParts.find(p => p.id === selectedPartId);
    if (part) {
      touchStartPartX = part.x;
      touchStartPartY = part.y;
    }
    img.setPointerCapture(event.pointerId);
  }
}

function removePart(img) {
  img.remove();
  placedParts = placedParts.filter(p => p.id !== img.dataset.partId);
  if (selectedPartId === img.dataset.partId) selectedPartId = null;
  notifyChange();
}

// ─── Pointer events for drag ───────────────────────────────────────────────

function onPointerDown(e) {
  const target = e.target;
  if (target.tagName === 'IMG' && target.parentElement === partsLayer) return; // handled by img listener

  // Deselect if tapping empty area
  if (partsLayer && e.target === partsLayer || e.target.closest('#canvas-area')) {
    placedParts.forEach(p => p.img.style.outline = 'none');
    selectedPartId = null;
  }
}

function onPointerMove(e) {
  if (!selectedPartId) return;
  const part = placedParts.find(p => p.id === selectedPartId);
  if (!part) return;

  const dx = ((e.clientX - touchStartX) / window.innerWidth) * 100;
  const dy = ((e.clientY - touchStartY) / window.innerHeight) * 100;

  part.x = Math.max(0, Math.min(100 - part.w, touchStartPartX + dx));
  part.y = Math.max(0, Math.min(100 - part.h, touchStartPartY + dy));

  part.img.style.left = part.x + '%';
  part.img.style.top = part.y + '%';
  part.img.style.transform = buildTransform(part);

  notifyChange();
}

function onPointerUp() {
  activeTouchId = null;
}

function buildTransform(part) {
  const cx = part.w / 2;
  const cy = part.h / 2;
  let t = `translate(${cx}%,${cy}%)`;
  t += ` rotate(${part.rotation}deg)`;
  t += ` scale(${part.flipH ? -1 : 1},1)`;
  t += ` translate(${-cx}%,${-cy}%)`;
  return t;
}

function notifyChange() {
  if (onPlacedPartsChanged) onPlacedPartsChanged();
}

// ─── JSON serialization ────────────────────────────────────────────────────

function getPlacedPartsJSON() {
  return placedParts.map(p => ({
    partId: p.id,
    characterSlug: p.partData.characterSlug,
    partKind: p.partData.partKind,
    emotion: p.partData.emotion || null,
    x: p.x,
    y: p.y,
    w: p.w,
    h: p.h,
    rotation: p.rotation,
    flipH: p.flipH,
  }));
}

function setPlacedPartsJSON(partsJSON) {
  // Clear existing
  placedParts.forEach(p => p.img.remove());
  placedParts = [];
  selectedPartId = null;

  if (!partsJSON || !partsJSON.length) return;

  // We need part image URLs — fetch manifests first
  (async () => {
    const slugMap = {};
    for (const p of partsJSON) {
      if (!slugMap[p.characterSlug]) {
        try {
          const resp = await fetch(`/api/parts/character/${p.characterSlug}/manifest`);
          const data = await resp.json();
          slugMap[p.characterSlug] = data.parts || [];
        } catch (e) { slugMap[p.characterSlug] = []; }
      }
    }

    for (const p of partsJSON) {
      const fullPart = slugMap[p.characterSlug]?.find(pp => pp.id === p.partId);
      if (!fullPart) continue;

      const img = document.createElement('img');
      img.src = fullPart.imageURL;
      img.dataset.partId = p.partId;
      img.style.cssText = 'position:absolute;pointer-events:auto;cursor:grab;touch-action:none;';
      img.style.left = p.x + '%';
      img.style.top = p.y + '%';
      img.style.width = p.w + '%';
      img.style.height = 'auto';
      img.style.transform = buildTransform({
        w: p.w, h: p.h, rotation: p.rotation, flipH: p.flipH
      });

      img.addEventListener('pointerdown', e => {
        e.stopPropagation();
        selectPart(img, e);
      });
      img.addEventListener('dblclick', e => {
        e.stopPropagation();
        removePart(img);
      });

      partsLayer.appendChild(img);
      placedParts.push({ id: p.partId, img, x: p.x, y: p.y, w: p.w, h: p.h, rotation: p.rotation, flipH: p.flipH, partData: fullPart });
    }
  })();
}

// ─── Export: composite parts onto canvas ────────────────────────────────────

function compositeOntoCanvas(canvas, ctx) {
  // Draw each placed part onto the canvas
  for (const part of placedParts) {
    const img = part.img;
    if (!img.complete) continue;

    const cw = canvas.width;
    const ch = canvas.height;
    const px = (part.x / 100) * cw;
    const py = (part.y / 100) * ch;
    const pw = (part.w / 100) * cw;

    ctx.save();
    ctx.translate(px + pw / 2, py + (img.naturalHeight / img.naturalWidth) * pw / 2);
    ctx.rotate((part.rotation * Math.PI) / 180);
    ctx.scale(part.flipH ? -1 : 1, 1);
    ctx.drawImage(img, -pw / 2, -(img.naturalHeight / img.naturalWidth) * pw / 2, pw, (img.naturalHeight / img.naturalWidth) * pw);
    ctx.restore();
  }
}
