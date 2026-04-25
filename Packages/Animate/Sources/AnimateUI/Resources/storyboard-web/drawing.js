/**
 * drawing.js — Canvas drawing engine for Storyboard Tool
 * Handles: pointer events, perfect-freehand strokes, eraser,
 * undo/redo, pinch-zoom/pan, auto-save dirty flag.
 *
 * Backing store is always 1920x1080 (16:9).
 * The on-screen canvas element is scaled/translated via CSS transform.
 */

import getStroke from './vendor/perfect-freehand.min.js';

// ─── Constants ────────────────────────────────────────────────────────────

const BACKING_W = 1920;
const BACKING_H = 1080;
const MAX_UNDO = 50;
const PEN_TOUCH_REJECTION_MS = 700;
const PALM_RADIUS_PX = 28;

// ─── Module state ─────────────────────────────────────────────────────────

let canvas = null;
let ctx = null;
let onDirty = null;      // callback from app.js when canvas becomes dirty

// Tool state
let currentTool = 'pencil';   // 'pencil' | 'eraser'
let pencilBrushSize = 8;
let eraserBrushSize = 18;
let activeBrushSize = pencilBrushSize;

// Undo stacks — stored as ImageData for reliability
// Per-frame stacks managed by app.js calling resetUndoStacks()
let undoStack = [];
let redoStack = [];

// Pointer / stroke state
let activePointerId = null;
let penInFlight = false;
let currentPoints = [];   // [{x,y,pressure,opacity}]
let lastPenEventAt = -Infinity;

// Transform: canvas-space → screen-space
// The canvas element is positioned at its natural 16:9 CSS size,
// then scaled/translated via a CSS matrix transform.
let scale = 1;    // current zoom
let panX = 0;     // pan offset in backing pixels
let panY = 0;
let fitScale = 1; // "fit to screen" scale, recalculated on layout change
let hasLaidOut = false;

// Touch gesture state (pinch/pan)
let touchA = null;  // {id, x, y}
let touchB = null;
let gestureStartDist = 0;
let gestureStartScale = 1;
let gestureStartPanX = 0;
let gestureStartPanY = 0;
let gestureStartMidX = 0;
let gestureStartMidY = 0;

// rAF rendering
let rafPending = false;
let strokeSnapshot = null; // ImageData taken at stroke start for live preview

// ─── Init ──────────────────────────────────────────────────────────────────

/**
 * @param {HTMLCanvasElement} canvasEl
 * @param {function} dirtyCallback - called when canvas content changes
 */
export function initDrawing(canvasEl, dirtyCallback) {
  canvas = canvasEl;
  ctx = canvas.getContext('2d', { willReadFrequently: true });
  onDirty = dirtyCallback;

  // Set backing resolution
  canvas.width = BACKING_W;
  canvas.height = BACKING_H;

  // White background
  clearToWhite();

  // Pointer events
  canvas.addEventListener('pointerdown', onPointerDown, { passive: false });
  canvas.addEventListener('pointermove', onPointerMove, { passive: false });
  canvas.addEventListener('pointerup', onPointerUp, { passive: false });
  canvas.addEventListener('pointercancel', onPointerCancel, { passive: false });
  canvas.addEventListener('lostpointercapture', onPointerCancel, { passive: false });

  // Touch events for pinch/pan (on the canvas-area container)
  const area = canvasEl.parentElement;
  area.addEventListener('touchstart', onTouchStart, { passive: false });
  area.addEventListener('touchmove', onTouchMove, { passive: false });
  area.addEventListener('touchend', onTouchEnd, { passive: false });
  area.addEventListener('touchcancel', onTouchEnd, { passive: false });
}

// ─── Layout / transform ───────────────────────────────────────────────────

/**
 * Call whenever the canvas-area size changes (sidebar toggle, toolbar toggle,
 * window resize). Recalculates fitScale and re-clamps current scale/pan.
 */
export function recalcLayout(areaW, areaH) {
  const margin = 24;
  const previousFitScale = fitScale;
  const scaleX = (areaW - margin * 2) / BACKING_W;
  const scaleY = (areaH - margin * 2) / BACKING_H;
  fitScale = Math.min(scaleX, scaleY);

  if (!hasLaidOut) {
    // Start fully fitted so the storyboard canvas never boots zoomed in.
    scale = fitScale;
    hasLaidOut = true;
  } else {
    // Preserve the current zoom factor across resizes when possible.
    const zoomFactor = scale / previousFitScale;
    const maxScale = fitScale * 4;
    scale = Math.max(fitScale, Math.min(maxScale, zoomFactor * fitScale));
  }

  clampPan(areaW, areaH);
  applyTransform(areaW, areaH);
}

function clampPan(areaW, areaH) {
  // The canvas at current scale is scale*BACKING_W wide
  const scaledW = scale * BACKING_W;
  const scaledH = scale * BACKING_H;

  // panX/panY are backing-pixel offsets applied before scaling.
  // Compute max pan so canvas edge can't go past area edge.
  const maxPanX = Math.max(0, (scaledW - areaW) / scale / 2);
  const maxPanY = Math.max(0, (scaledH - areaH) / scale / 2);

  panX = Math.max(-maxPanX, Math.min(maxPanX, panX));
  panY = Math.max(-maxPanY, Math.min(maxPanY, panY));
}

function applyTransform(areaW, areaH) {
  // Center the canvas in the area, then apply scale and pan
  const cssW = BACKING_W * fitScale;
  const cssH = BACKING_H * fitScale;

  // Canvas element CSS size = natural (fit) size
  canvas.style.width = cssW + 'px';
  canvas.style.height = cssH + 'px';

  const zoomFactor = scale / fitScale;
  const tx = -panX * scale;
  const ty = -panY * scale;

  canvas.style.transform = `scale(${zoomFactor}) translate(${tx / scale}px, ${ty / scale}px)`;
}

// ─── Coordinate conversion ────────────────────────────────────────────────

/**
 * Convert a clientX/clientY (screen space) to backing-store pixel coords.
 */
function clientToCanvas(clientX, clientY) {
  const rect = canvas.getBoundingClientRect();
  // rect is the on-screen bounding box of the canvas element
  const cssW = rect.width;
  const cssH = rect.height;
  const relX = clientX - rect.left;
  const relY = clientY - rect.top;
  // Scale from CSS pixels to backing pixels
  const bx = (relX / cssW) * BACKING_W;
  const by = (relY / cssH) * BACKING_H;
  return { x: bx, y: by };
}

// ─── Pointer event handlers ───────────────────────────────────────────────

function isDrawablePointer(e) {
  // ALWAYS-ON pencil-only mode: only Apple Pencil (pointerType 'pen') may
  // draw. Mouse and finger touches are ignored.
  return e.pointerType === 'pen';
}

function notePenEvent(e) {
  if (e.pointerType === 'pen') lastPenEventAt = performance.now();
}

function onPointerDown(e) {
  if (!isDrawablePointer(e)) return;
  if (penInFlight) return;

  e.preventDefault();
  notePenEvent(e);
  canvas.setPointerCapture(e.pointerId);
  activePointerId = e.pointerId;
  penInFlight = true;

  currentPoints = [makePointFromEvent(e)];

  // Snapshot current canvas for live-preview compositing
  strokeSnapshot = ctx.getImageData(0, 0, BACKING_W, BACKING_H);

  scheduleRender();
}

function onPointerMove(e) {
  if (!penInFlight || e.pointerId !== activePointerId) return;
  e.preventDefault();
  notePenEvent(e);

  currentPoints.push(makePointFromEvent(e));

  scheduleRender();
}

function onPointerUp(e) {
  if (!penInFlight || e.pointerId !== activePointerId) return;
  e.preventDefault();
  notePenEvent(e);

  currentPoints.push(makePointFromEvent(e));

  commitStroke();
  penInFlight = false;
  activePointerId = null;
  currentPoints = [];
  strokeSnapshot = null;
}

function onPointerCancel(e) {
  if (!penInFlight || e.pointerId !== activePointerId) return;
  notePenEvent(e);

  // Restore pre-stroke snapshot on cancel
  if (strokeSnapshot) {
    ctx.putImageData(strokeSnapshot, 0, 0);
    strokeSnapshot = null;
  }
  penInFlight = false;
  activePointerId = null;
  currentPoints = [];
}

function clampPressure(raw) {
  // PointerEvent.pressure is normalized to [0, 1]; keep within that range so
  // perfect-freehand receives predictable Apple Pencil values.
  return Math.max(0.05, Math.min(1.0, raw || 0.5));
}

function clampOpacity(raw) {
  return Math.max(0.12, Math.min(0.98, raw));
}

function getAltitudeAngle(e) {
  if (typeof e.altitudeAngle === 'number' && Number.isFinite(e.altitudeAngle)) {
    return Math.max(0, Math.min(Math.PI / 2, e.altitudeAngle));
  }

  if (typeof e.tiltX === 'number' && typeof e.tiltY === 'number') {
    const tiltMagnitude = Math.min(90, Math.hypot(e.tiltX, e.tiltY));
    return (Math.PI / 2) * (1 - tiltMagnitude / 90);
  }

  return Math.PI / 2;
}

function makePointFromEvent(e) {
  const { x, y } = clientToCanvas(e.clientX, e.clientY);
  const basePressure = clampPressure(typeof e.pressure === 'number' ? e.pressure : 0.5);
  const altitudeAngle = getAltitudeAngle(e);
  const flatness = 1 - (altitudeAngle / (Math.PI / 2));
  const contactSize = Math.max(
    typeof e.width === 'number' ? e.width : 0,
    typeof e.height === 'number' ? e.height : 0
  );
  const contactBoost = contactSize > 0 ? Math.min(0.25, contactSize / 48) : 0;

  // Flat Pencil strokes should widen noticeably, but stay bounded.
  const widthPressure = clampPressure(basePressure + flatness * 0.35 + contactBoost);

  // Blend pressure and tilt into opacity so flatter strokes read darker/softer.
  const opacity = clampOpacity(0.22 + basePressure * 0.58 + flatness * 0.18 + contactBoost * 0.2);

  return { x, y, pressure: widthPressure, opacity };
}

// ─── Touch gesture handlers (pinch + 2-finger pan) ────────────────────────

function getTouchById(touches, id) {
  for (let i = 0; i < touches.length; i++) {
    if (touches[i].identifier === id) return touches[i];
  }
  return null;
}

function resetTouchGesture() {
  touchA = null;
  touchB = null;
}

function recentPenActivity() {
  return performance.now() - lastPenEventAt < PEN_TOUCH_REJECTION_MS;
}

function hasPalmLikeTouch(touches) {
  for (let i = 0; i < touches.length; i++) {
    const touch = touches[i];
    const radius = Math.max(touch.radiusX || 0, touch.radiusY || 0);
    if (radius >= PALM_RADIUS_PX) return true;
  }
  return false;
}

function onTouchStart(e) {
  // ALWAYS-ON pencil-only mode: every finger touch on the canvas is dropped.
  // Apple Pencil drawing flows through the pointer event path. Two-finger
  // pinch / pan is intentionally disabled to keep the gesture surface clean
  // — the user explicitly asked for finger input to be off everywhere.
  e.preventDefault();
  resetTouchGesture();
}

function onTouchMove(e) {
  if (penInFlight || recentPenActivity() || hasPalmLikeTouch(e.touches)) {
    e.preventDefault();
    resetTouchGesture();
    return;
  }

  if (touchA === null || touchB === null) {
    // Single-finger touch while no gesture — prevent scroll
    e.preventDefault();
    return;
  }
  e.preventDefault();

  const ta = getTouchById(e.touches, touchA.id);
  const tb = getTouchById(e.touches, touchB.id);
  if (!ta || !tb) return;

  const area = canvas.parentElement;
  const areaW = area.clientWidth;
  const areaH = area.clientHeight;

  // Pinch zoom
  const dist = Math.hypot(ta.clientX - tb.clientX, ta.clientY - tb.clientY);
  const rawScale = gestureStartScale * (dist / gestureStartDist);
  const maxScale = fitScale * 4;
  scale = Math.max(fitScale, Math.min(maxScale, rawScale));

  // 2-finger pan: delta of midpoint from gesture start
  const midX = (ta.clientX + tb.clientX) / 2;
  const midY = (ta.clientY + tb.clientY) / 2;
  const dMidX = gestureStartMidX - midX;
  const dMidY = gestureStartMidY - midY;

  panX = gestureStartPanX + dMidX / scale;
  panY = gestureStartPanY + dMidY / scale;

  clampPan(areaW, areaH);
  applyTransform(areaW, areaH);
}

function onTouchEnd(e) {
  if (e.touches.length < 2) {
    resetTouchGesture();
  }
}

// ─── Rendering ────────────────────────────────────────────────────────────

function scheduleRender() {
  if (rafPending) return;
  rafPending = true;
  requestAnimationFrame(renderStroke);
}

function renderStroke() {
  rafPending = false;
  if (!penInFlight || currentPoints.length === 0) return;

  // Restore snapshot so each rAF redraws cleanly
  if (strokeSnapshot) {
    ctx.putImageData(strokeSnapshot, 0, 0);
  }

  drawStroke(currentPoints, false);
}

function commitStroke() {
  // Push current state to undo stack BEFORE committing
  if (strokeSnapshot) {
    pushUndo(strokeSnapshot);
  }

  // Draw final stroke (isComplete = true for better end cap)
  if (strokeSnapshot) {
    ctx.putImageData(strokeSnapshot, 0, 0);
  }
  drawStroke(currentPoints, true);

  onDirty && onDirty();
}

function drawStroke(points, isComplete) {
  if (points.length === 0) return;

  const isEraser = currentTool === 'eraser';

  // Build perfect-freehand options
  const pfOptions = {
    size: activeBrushSize,
    smoothing: 0.55,
    thinning: isEraser ? 0 : 0.55,
    streamline: 0.45,
    easing: (t) => t,
    last: isComplete,
    simulatePressure: false,
    start: { cap: true, taper: 0, easing: (t) => t },
    end: { cap: true, taper: 0, easing: (t) => t },
  };

  const inputPoints = points.map((pt) => [pt.x, pt.y, pt.pressure]);

  const outlinePoints = getStroke(inputPoints, pfOptions);
  if (outlinePoints.length < 2) return;

  ctx.save();

  if (isEraser) {
    ctx.globalCompositeOperation = 'destination-out';
    ctx.fillStyle = 'rgba(0,0,0,1)';
  } else {
    ctx.globalCompositeOperation = 'source-over';
    // Graphite: pressure already mapped to opacity in points via color calc below
    ctx.fillStyle = '#141414';
  }

  ctx.beginPath();
  ctx.moveTo(outlinePoints[0][0], outlinePoints[0][1]);
  for (let i = 1; i < outlinePoints.length; i++) {
    ctx.lineTo(outlinePoints[i][0], outlinePoints[i][1]);
  }
  ctx.closePath();

  if (!isEraser) {
    // Vary opacity based on average pressure/tilt for a more tactile graphite feel.
    const avgOpacity = points.reduce((s, p) => s + (p.opacity || 0), 0) / points.length;
    ctx.globalAlpha = avgOpacity;
  }

  ctx.fill();
  ctx.restore();
}

// ─── Brush state API ──────────────────────────────────────────────────────

// ─── Undo / Redo ──────────────────────────────────────────────────────────

function pushUndo(imageData) {
  undoStack.push(imageData);
  if (undoStack.length > MAX_UNDO) undoStack.shift();
  redoStack = []; // clear redo on new action
  updateUndoRedoUI();
}

export function undo() {
  if (undoStack.length === 0) return;
  const current = ctx.getImageData(0, 0, BACKING_W, BACKING_H);
  redoStack.push(current);
  if (redoStack.length > MAX_UNDO) redoStack.shift();

  const prev = undoStack.pop();
  ctx.putImageData(prev, 0, 0);
  updateUndoRedoUI();
  onDirty && onDirty();
}

export function redo() {
  if (redoStack.length === 0) return;
  const current = ctx.getImageData(0, 0, BACKING_W, BACKING_H);
  undoStack.push(current);

  const next = redoStack.pop();
  ctx.putImageData(next, 0, 0);
  updateUndoRedoUI();
  onDirty && onDirty();
}

function updateUndoRedoUI() {
  const undoBtn = document.getElementById('undo-btn');
  const redoBtn = document.getElementById('redo-btn');
  if (undoBtn) undoBtn.disabled = undoStack.length === 0;
  if (redoBtn) redoBtn.disabled = redoStack.length === 0;
}

export function resetUndoStacks() {
  undoStack = [];
  redoStack = [];
  updateUndoRedoUI();
}

// ─── Canvas content ───────────────────────────────────────────────────────

export function clearCanvas() {
  const snap = ctx.getImageData(0, 0, BACKING_W, BACKING_H);
  pushUndo(snap);
  clearToWhite();
  onDirty && onDirty();
}

function clearToWhite() {
  ctx.save();
  ctx.globalCompositeOperation = 'source-over';
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, BACKING_W, BACKING_H);
  ctx.restore();
}

/**
 * Load an image blob/url onto the canvas, clearing first.
 */
export function loadImageURL(url) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => {
      clearToWhite();
      ctx.drawImage(img, 0, 0, BACKING_W, BACKING_H);
      resetUndoStacks();
      resolve();
    };
    img.onerror = () => {
      // 404 or error — just leave canvas white
      clearToWhite();
      resetUndoStacks();
      resolve();
    };
    img.src = url;
  });
}

/**
 * Export canvas as PNG blob at backing resolution.
 */
export function exportPNG() {
  return new Promise((resolve) => {
    canvas.toBlob((blob) => resolve(blob), 'image/png');
  });
}

// ─── Tool / brush API ─────────────────────────────────────────────────────

export function setTool(tool) {
  currentTool = tool;
  activeBrushSize = currentTool === 'eraser' ? eraserBrushSize : pencilBrushSize;
}

export function setBrushSize(size) {
  const normalized = Math.max(2, Number(size) || 2);
  if (currentTool === 'eraser') {
    eraserBrushSize = normalized;
  } else {
    pencilBrushSize = normalized;
  }
  activeBrushSize = normalized;
}

export function setBrushSizeForTool(tool, size) {
  const normalized = Math.max(2, Number(size) || 2);
  if (tool === 'eraser') {
    eraserBrushSize = normalized;
  } else {
    pencilBrushSize = normalized;
  }
  if (tool === currentTool) {
    activeBrushSize = normalized;
  }
}

export function getBrushSizeForTool(tool) {
  return tool === 'eraser' ? eraserBrushSize : pencilBrushSize;
}

export function getCurrentTool() {
  return currentTool;
}

export function getCurrentBrushSize() {
  return activeBrushSize;
}

export function resetZoom() {
  const area = canvas.parentElement;
  scale = fitScale;
  panX = 0;
  panY = 0;
  applyTransform(area.clientWidth, area.clientHeight);
}
