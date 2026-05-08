/**
 * app.js — Storyboard Tool main application
 * Handles: shot list, navigation, frame selection, summary editing,
 * auto-save, keyboard shortcuts, sidebar/toolbar toggles.
 */

import {
  initDrawing,
  recalcLayout,
  loadImageURL,
  pasteImageURL,
  exportPNG,
  setTool,
  setBrushSizeForTool,
  getBrushSizeForTool,
  undo,
  redo,
  clearCanvas,
  resetUndoStacks,
} from './drawing.js';



const AUTOSAVE_INTERVAL_MS = 5_000;
const STROKE_END_SAVE_DEBOUNCE_MS = 400;
const SUMMARY_DEBOUNCE_MS = 1_500;
const FRAMES = ['begin', 'middle', 'end'];
const LS_SHOT_KEY = 'storyboard_shotId';
const LS_FRAME_KEY = 'storyboard_frame';
const LS_MODE_KEY = 'storyboard_sidebar_mode';
const LS_PLACE_TARGET_KEY = 'storyboard_place_target';
const LS_SCAFFOLD_ID_KEY = 'storyboard_scaffold_id';
const LS_SCAFFOLD_MODE_KEY = 'storyboard_scaffold_mode';
const LS_PENCIL_SIZE_KEY = 'storyboard_brush_size_pencil';
const LS_ERASER_SIZE_KEY = 'storyboard_brush_size_eraser';
const DEFAULT_PENCIL_BRUSH_SIZE = 6;
const DEFAULT_ERASER_BRUSH_SIZE = 18;
const BRUSH_LIMITS = {
  pencil: { min: 1, max: 12 },
  eraser: { min: 4, max: 50 },
};

// ─── App state ────────────────────────────────────────────────────────────

let shots = [];                // flat array from /api/shots
let places = [];
let landmarks = [];
let scaffolds = [];
let sidebarMode = 'scenes';    // 'scenes' | 'places'
let currentPlaceTarget = null; // { type: 'place'|'landmark', id }
let currentShotId = null;
let currentFrame = 'middle';   // 'begin' | 'middle' | 'end'
let currentTool = 'pencil';
let currentScaffoldId = null;
let currentScaffoldMode = 'bw';
let isDirty = false;
let isSidebarOpen = true;
let isToolbarOpen = true;
let summaryDebounceTimer = null;
let autosaveTimer = null;
let isSaving = false;
let isAddShotOpen = false;
let addPlaceType = 'place';

// ─── DOM refs ─────────────────────────────────────────────────────────────

const canvasEl = document.getElementById('drawing-canvas');
const canvasArea = document.getElementById('canvas-area');
const appStatusEl = document.getElementById('app-status');
const shotListEl = document.getElementById('item-list');
const sidebar = document.getElementById('sidebar');
const mainEl = document.getElementById('main');
const toolbar = document.getElementById('toolbar');
const toolbarShowBtn = document.getElementById('toolbar-show-btn');
const toolbarToggleBtn = document.getElementById('toolbar-toggle-btn');
const addShotBtn = document.getElementById('add-item-btn');
const addShotSheet = document.getElementById('add-shot-sheet');
const addShotForm = document.getElementById('add-shot-form');
const addShotTitleInput = document.getElementById('add-shot-title');
const addShotCloseBtn = document.getElementById('add-shot-close-btn');
const addShotCancelBtn = document.getElementById('add-shot-cancel-btn');
const addShotSceneLabel = document.getElementById('add-shot-scene-label');
const addPlaceTypeRow = document.getElementById('add-place-type-row');
const addTypePlaceBtn = document.getElementById('add-type-place');
const addTypeLandmarkBtn = document.getElementById('add-type-landmark');
const sidebarTabScenes = document.getElementById('sidebar-tab-scenes');
const sidebarTabPlaces = document.getElementById('sidebar-tab-places');
const projectNameEl = document.getElementById('project-name');
const saveStatusEl = document.getElementById('save-status');
const brushLabel = document.getElementById('brush-label');
const summaryEditor = document.getElementById('summary-editor');
const frameBtns = document.querySelectorAll('.frame-btn');
const undoBtn = document.getElementById('undo-btn');
const redoBtn = document.getElementById('redo-btn');
const clearBtn = document.getElementById('clear-btn');
const prevBtn = document.getElementById('prev-btn');
const nextBtn = document.getElementById('next-btn');
const brushSlider = document.getElementById('brush-slider');
const brushValue = document.getElementById('brush-value');
const pencilBtn = document.getElementById('tool-pencil');
const eraserBtn = document.getElementById('tool-eraser');
const brushDecBtn = document.getElementById('brush-decrement');
const brushIncBtn = document.getElementById('brush-increment');
const copyBtn = document.getElementById('copy-btn');
const pasteBtn = document.getElementById('paste-btn');
const scaffoldGroup = document.getElementById('scaffold-group');
const scaffoldSelect = document.getElementById('scaffold-select');
const scaffoldModeColorBtn = document.getElementById('scaffold-mode-color');
const scaffoldModeBWBtn = document.getElementById('scaffold-mode-bw');
const scaffoldRefreshBtn = document.getElementById('scaffold-refresh-btn');
const scaffoldImportBtn = document.getElementById('scaffold-import-btn');

// In-memory clipboard for copy/paste of canvas (latest only, cleared on reload)
let copiedFrameDataURL = null;

// Drag-and-drop reorder state
let dragState = null; // { shotId, sceneId, originRow, placeholderTarget, ... }

// ─── Boot ──────────────────────────────────────────────────────────────────

async function boot() {
  // Init drawing engine
  initDrawing(canvasEl, markDirty);

  loadBrushSizes();
  installInputGuards();
  setupToolbar();
  setupSidebar();
  setupAddShotSheet();
  setupFramePicker();
  setupSummary();
  setupKeyboard();
  setupWindowResize();

  // Load project info
  try {
    const proj = await apiFetch('/api/project');
    if (proj && proj.name) {
      document.title = proj.name + ' — Storyboard';
      projectNameEl.textContent = proj.name;
    }
  } catch (_) { /* non-fatal */ }

  // Load shots
  await refreshShots();
  await refreshPlaces();
  await refreshScaffolds();
  await refreshCharacterParts();

  // Init character parts layer
  initPartsLayer('#canvas-area', () => {
    markDirty();
  });
  loadCharacterParts();

  // Restore last position from localStorage
  const savedMode = localStorage.getItem(LS_MODE_KEY);
  const shouldRestorePlacesMode = savedMode === 'places';
  if (shouldRestorePlacesMode) sidebarMode = 'places';
  const savedShotId = localStorage.getItem(LS_SHOT_KEY);
  const savedFrame = localStorage.getItem(LS_FRAME_KEY);
  if (savedFrame && FRAMES.includes(savedFrame)) {
    currentFrame = savedFrame;
  }

  // Pick the shot to open
  let targetShot = shots.find((s) => s.shotId === savedShotId);
  if (!targetShot && shots.length > 0) targetShot = shots[0];

  if (targetShot) {
    await navigateTo(targetShot.shotId, currentFrame, false);
  }
  if (shouldRestorePlacesMode) sidebarMode = 'places';

  const savedPlaceTarget = parseStoredPlaceTarget();
  if (savedPlaceTarget && findPlaceTarget(savedPlaceTarget.type, savedPlaceTarget.id)) {
    currentPlaceTarget = savedPlaceTarget;
  } else if (places.length > 0) {
    currentPlaceTarget = { type: 'place', id: places[0].id };
  } else if (landmarks.length > 0) {
    currentPlaceTarget = { type: 'landmark', id: landmarks[0].id };
  }
  if (sidebarMode === 'places' && currentPlaceTarget) {
    await navigateToPlaceTarget(currentPlaceTarget.type, currentPlaceTarget.id, false);
  }
  renderSidebar();

  selectTool('pencil', { syncSlider: true });
  updateLayout();
  startAutosave();
  installSaveOnExitHooks();
  clearAppStatus();
}

// ─── API helpers ──────────────────────────────────────────────────────────

async function apiFetch(path, options = {}) {
  const res = await fetch(path, options);
  if (!res.ok) throw new Error(`HTTP ${res.status} ${path}`);
  if (res.status === 204) return null;
  const ct = res.headers.get('content-type') || '';
  if (ct.includes('application/json')) return res.json();
  return res;
}

function brushLimits(tool) {
  return BRUSH_LIMITS[tool] || BRUSH_LIMITS.pencil;
}

function clampBrushSize(tool, value) {
  const { min, max } = brushLimits(tool);
  return Math.max(min, Math.min(max, Number(value) || min));
}

function readStoredBrushSize(key, fallback, tool) {
  const value = Number.parseInt(localStorage.getItem(key) || '', 10);
  return Number.isFinite(value) ? clampBrushSize(tool, value) : fallback;
}

function loadBrushSizes() {
  const pencilSize = readStoredBrushSize(LS_PENCIL_SIZE_KEY, DEFAULT_PENCIL_BRUSH_SIZE, 'pencil');
  const eraserSize = readStoredBrushSize(LS_ERASER_SIZE_KEY, DEFAULT_ERASER_BRUSH_SIZE, 'eraser');
  setBrushSizeForTool('pencil', pencilSize);
  setBrushSizeForTool('eraser', eraserSize);
}

function persistBrushSize(tool, size) {
  const key = tool === 'eraser' ? LS_ERASER_SIZE_KEY : LS_PENCIL_SIZE_KEY;
  localStorage.setItem(key, String(size));
}

function syncBrushUi(tool) {
  currentTool = tool;
  setTool(tool);
  pencilBtn.classList.toggle('tool-btn--active', tool === 'pencil');
  eraserBtn.classList.toggle('tool-btn--active', tool === 'eraser');

  const label = tool === 'eraser' ? 'Eraser' : 'Pencil';
  const size = getBrushSizeForTool(tool);
  brushLabel.textContent = label;
  const limits = brushLimits(tool);
  const oldMax = parseInt(brushSlider.max, 10) || limits.max;
  if (size <= oldMax) {
    brushSlider.value = String(size);
    brushSlider.min = String(limits.min);
    brushSlider.max = String(limits.max);
  } else {
    brushSlider.min = String(limits.min);
    brushSlider.max = String(limits.max);
    brushSlider.value = String(size);
  }
  brushSlider.setAttribute('aria-label', `${label} size`);
  brushValue.textContent = String(size);
}

function selectTool(tool, { syncSlider = true } = {}) {
  if (currentTool !== tool) {
    currentTool = tool;
    setTool(tool);
  }

  pencilBtn.classList.toggle('tool-btn--active', tool === 'pencil');
  eraserBtn.classList.toggle('tool-btn--active', tool === 'eraser');

  if (syncSlider) {
    syncBrushUi(tool);
  } else {
    const size = getBrushSizeForTool(tool);
    brushLabel.textContent = tool === 'eraser' ? 'Eraser' : 'Pencil';
    const limits2 = brushLimits(tool);
    const oldMax2 = parseInt(brushSlider.max, 10) || limits2.max;
    if (size <= oldMax2) {
      brushSlider.value = String(size);
      brushSlider.min = String(limits2.min);
      brushSlider.max = String(limits2.max);
    } else {
      brushSlider.min = String(limits2.min);
      brushSlider.max = String(limits2.max);
      brushSlider.value = String(size);
    }
    brushSlider.setAttribute('aria-label', `${tool === 'eraser' ? 'Eraser' : 'Pencil'} size`);
    brushValue.textContent = String(size);
  }
}

function setActiveBrushSize(size) {
  const normalized = clampBrushSize(currentTool, size);
  setBrushSizeForTool(currentTool, normalized);
  persistBrushSize(currentTool, normalized);
  brushValue.textContent = String(normalized);
}

function adjustBrush(delta) {
  const current = getBrushSizeForTool(currentTool);
  const next = clampBrushSize(currentTool, current + delta);
  setActiveBrushSize(next);
  brushSlider.value = String(next);
}

// ─── Shot list ────────────────────────────────────────────────────────────

async function refreshShots() {
  try {
    shots = await apiFetch('/api/shots');
    renderSidebar();
    refreshAddShotSceneLabel();
  } catch (err) {
    shotListEl.innerHTML = '<div class="shot-list-loading">Failed to load shots.</div>';
  }
}

async function refreshPlaces() {
  try {
    const [placeList, landmarkList] = await Promise.all([
      apiFetch('/api/places'),
      apiFetch('/api/landmarks'),
    ]);
    places = Array.isArray(placeList) ? placeList : [];
    landmarks = Array.isArray(landmarkList) ? landmarkList : [];
    renderSidebar();
  } catch (err) {
    if (sidebarMode === 'places') {
      shotListEl.innerHTML = '<div class="shot-list-loading">Failed to load places.</div>';
    }
  }
}

async function refreshScaffolds() {
  if (scaffoldRefreshBtn) scaffoldRefreshBtn.disabled = true;
  try {
    const list = await apiFetch('/api/scaffolds');
    scaffolds = Array.isArray(list) ? list : [];
  } catch (err) {
    scaffolds = [];
  } finally {
    if (scaffoldRefreshBtn) scaffoldRefreshBtn.disabled = false;
  }
  renderScaffoldControls();
}

async function refreshCharacterParts() {
  try {
    loadCharacterParts();
  } catch (_) {}
}

function renderSidebar() {
  updateSidebarModeUI();
  if (sidebarMode === 'places') renderPlaceList();
  else renderShotList();
}

function updateSidebarModeUI() {
  sidebarTabScenes?.classList.toggle('sidebar-tab--active', sidebarMode === 'scenes');
  sidebarTabPlaces?.classList.toggle('sidebar-tab--active', sidebarMode === 'places');
  sidebarTabScenes?.setAttribute('aria-selected', sidebarMode === 'scenes' ? 'true' : 'false');
  sidebarTabPlaces?.setAttribute('aria-selected', sidebarMode === 'places' ? 'true' : 'false');
  addShotBtn?.setAttribute('title', sidebarMode === 'places' ? 'Add place or landmark' : 'Add shot');
  addShotBtn?.setAttribute('aria-label', sidebarMode === 'places' ? 'Add place or landmark' : 'Add shot');
}

function renderShotList() {
  if (!shots || shots.length === 0) {
    shotListEl.innerHTML = '<div class="shot-list-loading">No shots yet.</div>';
    return;
  }

  // Group by sceneId
  const sceneMap = new Map();
  for (const shot of shots) {
    if (!sceneMap.has(shot.sceneId)) {
      sceneMap.set(shot.sceneId, { name: shot.sceneName, shots: [] });
    }
    sceneMap.get(shot.sceneId).shots.push(shot);
  }

  const frag = document.createDocumentFragment();
  for (const [, scene] of sceneMap) {
    const group = document.createElement('div');
    group.className = 'scene-group';

    const label = document.createElement('div');
    label.className = 'scene-label';
    label.textContent = scene.name;
    group.appendChild(label);

    for (const shot of scene.shots) {
      const row = document.createElement('div');
      row.className = 'shot-row';
      row.dataset.shotId = shot.shotId;
      row.dataset.sceneId = shot.sceneId;
      if (shot.shotId === currentShotId) row.classList.add('shot-row--active');

      const name = document.createElement('div');
      name.className = 'shot-name';
      name.textContent = shot.shotName;

      const bme = document.createElement('div');
      bme.className = 'shot-bme';
      for (const f of FRAMES) {
        const dot = document.createElement('div');
        dot.className = 'shot-bme-dot';
        if (shot.hasFrames && shot.hasFrames[f]) dot.classList.add('shot-bme-dot--filled');
        bme.appendChild(dot);
      }

      const handle = document.createElement('div');
      handle.className = 'shot-drag-handle';
      handle.setAttribute('aria-label', 'Reorder shot');
      handle.title = 'Drag to reorder';
      attachShotReorderHandlers(handle, row, shot);

      row.appendChild(name);
      row.appendChild(bme);
      row.appendChild(handle);

      row.addEventListener('click', async (event) => {
        // Don't navigate if a drag just finished or originated from the handle
        if (event.target.closest('.shot-drag-handle')) return;
        if (shot.shotId === currentShotId) return;
        await saveIfDirty();
        await navigateTo(shot.shotId, currentFrame, true);
      });

      group.appendChild(row);
    }

    frag.appendChild(group);
  }

  shotListEl.innerHTML = '';
  shotListEl.appendChild(frag);
}

function renderPlaceList() {
  if ((!places || places.length === 0) && (!landmarks || landmarks.length === 0)) {
    shotListEl.innerHTML = '<div class="shot-list-loading">No places or landmarks yet.</div>';
    return;
  }

  const frag = document.createDocumentFragment();
  appendPlaceSection(frag, 'Places', places, 'place');
  appendPlaceSection(frag, 'Landmarks', landmarks, 'landmark');

  shotListEl.innerHTML = '';
  shotListEl.appendChild(frag);
}

function appendPlaceSection(frag, labelText, items, type) {
  if (!items || items.length === 0) return;
  const group = document.createElement('div');
  group.className = 'scene-group';

  const label = document.createElement('div');
  label.className = 'scene-label';
  label.textContent = labelText;
  group.appendChild(label);

  for (const item of items) {
    const row = document.createElement('div');
    row.className = 'shot-row place-row';
    row.dataset.targetType = type;
    row.dataset.targetId = item.id;
    if (currentPlaceTarget?.type === type && currentPlaceTarget?.id === item.id) {
      row.classList.add('shot-row--active');
    }

    const name = document.createElement('div');
    name.className = 'shot-name';
    name.textContent = type === 'landmark' ? item.title : item.name;

    const meta = document.createElement('div');
    meta.className = 'place-meta';
    meta.textContent = item.hasSketch ? '●' : '○';
    meta.title = item.hasSketch ? 'Has iPad sketch' : 'No iPad sketch yet';

    row.appendChild(name);
    row.appendChild(meta);
    row.addEventListener('click', async () => {
      if (currentPlaceTarget?.type === type && currentPlaceTarget?.id === item.id) return;
      await navigateToPlaceTarget(type, item.id, true);
    });
    group.appendChild(row);
  }

  frag.appendChild(group);
}

// ─── Shot reordering (drag handle) ───────────────────────────────────────

function attachShotReorderHandlers(handle, row, shot) {
  handle.addEventListener('pointerdown', (e) => {
    // Only Apple Pencil (or mouse for desktop debugging) can drag — finger
    // touches are already blocked at the document-level pointer guard.
    if (e.pointerType === 'touch') return;
    e.preventDefault();
    e.stopPropagation();
    beginShotDrag(e, handle, row, shot);
  });
}

function beginShotDrag(e, handle, row, shot) {
  if (!shot.sceneId) return;
  try { handle.setPointerCapture(e.pointerId); } catch (_) { /* ignore */ }

  dragState = {
    pointerId: e.pointerId,
    handle,
    row,
    shotId: shot.shotId,
    sceneId: shot.sceneId,
    startY: e.clientY,
    targetIndex: null,
    moved: false,
  };

  row.classList.add('shot-row--dragging');

  const onMove = (event) => {
    if (!dragState || event.pointerId !== dragState.pointerId) return;
    if (Math.abs(event.clientY - dragState.startY) > 3) dragState.moved = true;
    updateShotDropIndicator(event.clientY);
  };

  const onUp = async (event) => {
    if (!dragState || event.pointerId !== dragState.pointerId) return;
    handle.removeEventListener('pointermove', onMove);
    handle.removeEventListener('pointerup', onUp);
    handle.removeEventListener('pointercancel', onUp);
    try { handle.releasePointerCapture(event.pointerId); } catch (_) { /* ignore */ }

    const moved = dragState.moved;
    const newIndex = dragState.targetIndex;
    const sceneId = dragState.sceneId;
    const shotId = dragState.shotId;
    clearShotDropIndicator();
    row.classList.remove('shot-row--dragging');

    if (moved && newIndex != null) {
      await commitShotReorder(sceneId, shotId, newIndex);
    }

    dragState = null;
  };

  handle.addEventListener('pointermove', onMove);
  handle.addEventListener('pointerup', onUp);
  handle.addEventListener('pointercancel', onUp);
}

function updateShotDropIndicator(clientY) {
  if (!dragState) return;
  const sceneRows = Array.from(
    shotListEl.querySelectorAll(`.shot-row[data-scene-id="${dragState.sceneId}"]`)
  );
  if (sceneRows.length === 0) return;

  // Clear all visual hints
  sceneRows.forEach((r) => {
    r.classList.remove('shot-row--drop-before', 'shot-row--drop-after');
  });

  // Find the row whose vertical midpoint is nearest the pointer.
  // We compute targetIndex against the array of *other* shots (the source
  // shot is removed before reinsertion in commitShotReorder), so the index
  // we want is the position within sceneRows-without-dragState.row.
  const others = sceneRows.filter((r) => r !== dragState.row);
  let targetIndex = others.length; // default: drop at end
  let chosenRow = null;
  let chosenBefore = false;
  for (let i = 0; i < others.length; i++) {
    const r = others[i];
    const rect = r.getBoundingClientRect();
    const mid = rect.top + rect.height / 2;
    if (clientY < mid) {
      chosenRow = r;
      chosenBefore = true;
      targetIndex = i;
      break;
    }
  }
  if (!chosenRow && others.length > 0) {
    // After the last non-drag row — targetIndex stays others.length
    chosenRow = others[others.length - 1];
    chosenBefore = false;
  }

  if (chosenRow) {
    chosenRow.classList.add(chosenBefore ? 'shot-row--drop-before' : 'shot-row--drop-after');
  }

  dragState.targetIndex = targetIndex;
}

function clearShotDropIndicator() {
  shotListEl.querySelectorAll('.shot-row--drop-before, .shot-row--drop-after')
    .forEach((r) => r.classList.remove('shot-row--drop-before', 'shot-row--drop-after'));
}

async function commitShotReorder(sceneId, shotId, newIndex) {
  // Build current scene-shot order from in-memory `shots`
  const sceneShots = shots.filter((s) => s.sceneId === sceneId);
  const currentIndex = sceneShots.findIndex((s) => s.shotId === shotId);
  if (currentIndex === -1) return;
  if (newIndex === currentIndex) return;

  const reordered = sceneShots.slice();
  const [moving] = reordered.splice(currentIndex, 1);
  reordered.splice(Math.min(newIndex, reordered.length), 0, moving);

  // Optimistically update `shots` array: replace the slice for this scene
  const newShots = [];
  let placedScene = false;
  for (const s of shots) {
    if (s.sceneId === sceneId) {
      if (!placedScene) {
        newShots.push(...reordered);
        placedScene = true;
      }
    } else {
      newShots.push(s);
    }
  }
  shots = newShots;
  renderSidebar();

  try {
    await apiFetch('/api/shots/reorder', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sceneId, shotIds: reordered.map((s) => s.shotId) }),
    });
  } catch (err) {
    console.error('Reorder failed:', err);
    setAppStatus('Failed to reorder shots.', 'error');
    await refreshShots();
  }
}

function updateShotListActive() {
  const rows = shotListEl.querySelectorAll('.shot-row');
  rows.forEach((row) => {
    if (sidebarMode === 'places') {
      row.classList.toggle(
        'shot-row--active',
        row.dataset.targetType === currentPlaceTarget?.type && row.dataset.targetId === currentPlaceTarget?.id
      );
    } else {
      row.classList.toggle('shot-row--active', row.dataset.shotId === currentShotId);
    }
  });
}

function updateShotBME(shotId, frame, filled) {
  const row = shotListEl.querySelector(`.shot-row[data-shot-id="${shotId}"]`);
  if (!row) return;
  const dots = row.querySelectorAll('.shot-bme-dot');
  const idx = FRAMES.indexOf(frame);
  if (idx >= 0 && dots[idx]) {
    dots[idx].classList.toggle('shot-bme-dot--filled', filled);
  }
}

// ─── Deterministic scaffolds ──────────────────────────────────────────────

function renderScaffoldControls() {
  if (!scaffoldGroup || !scaffoldSelect) return;
  const usable = scaffolds.filter((item) => item.hasColor || item.hasBW);
  scaffoldGroup.hidden = usable.length === 0;
  if (scaffoldRefreshBtn) scaffoldRefreshBtn.disabled = false;
  scaffoldImportBtn.disabled = usable.length === 0;
  scaffoldSelect.innerHTML = '';
  if (usable.length === 0) return;

  const storedID = localStorage.getItem(LS_SCAFFOLD_ID_KEY);
  const storedMode = localStorage.getItem(LS_SCAFFOLD_MODE_KEY);
  if (storedMode === 'color' || storedMode === 'bw') currentScaffoldMode = storedMode;

  let selected = usable.find((item) => item.id === storedID) || usable[0];
  currentScaffoldId = selected.id;
  localStorage.setItem(LS_SCAFFOLD_ID_KEY, currentScaffoldId);

  for (const scaffold of usable) {
    const option = document.createElement('option');
    option.value = scaffold.id;
    option.textContent = scaffold.name || scaffold.id;
    option.selected = scaffold.id === currentScaffoldId;
    scaffoldSelect.appendChild(option);
  }
  syncScaffoldModeUI();
}

function selectedScaffold() {
  return scaffolds.find((item) => item.id === currentScaffoldId) || null;
}

function syncScaffoldModeUI() {
  const scaffold = selectedScaffold();
  const colorAvailable = Boolean(scaffold?.hasColor);
  const bwAvailable = Boolean(scaffold?.hasBW);
  if (currentScaffoldMode === 'color' && !colorAvailable && bwAvailable) {
    currentScaffoldMode = 'bw';
  }
  if (currentScaffoldMode === 'bw' && !bwAvailable && colorAvailable) {
    currentScaffoldMode = 'color';
  }

  scaffoldModeColorBtn?.classList.toggle('mode-chip--active', currentScaffoldMode === 'color');
  scaffoldModeBWBtn?.classList.toggle('mode-chip--active', currentScaffoldMode === 'bw');
  if (scaffoldModeColorBtn) scaffoldModeColorBtn.disabled = !colorAvailable;
  if (scaffoldModeBWBtn) scaffoldModeBWBtn.disabled = !bwAvailable;
  if (scaffoldImportBtn) scaffoldImportBtn.disabled = !scaffold || (!colorAvailable && !bwAvailable);
  localStorage.setItem(LS_SCAFFOLD_MODE_KEY, currentScaffoldMode);
}

function scaffoldAssetURL(scaffold) {
  if (!scaffold) return null;
  if (currentScaffoldMode === 'color' && scaffold.colorURL) return scaffold.colorURL;
  if (currentScaffoldMode === 'bw' && scaffold.bwURL) return scaffold.bwURL;
  return scaffold.bwURL || scaffold.colorURL || null;
}

async function importSelectedScaffold() {
  const scaffold = selectedScaffold();
  const url = scaffoldAssetURL(scaffold);
  if (!scaffold || !url) return;
  if (isDirty && !confirm('Replace this unsaved frame with the selected scaffold?')) return;
  try {
    await pasteImageURL(url);
    markDirty();
  } catch (err) {
    console.error('Scaffold import failed:', err);
    setAppStatus('Failed to place scaffold.', 'error');
  }
}

function currentSceneName() {
  return shots.find((s) => s.shotId === currentShotId)?.sceneName
    || shots[0]?.sceneName
    || 'Selected scene';
}

function currentSceneId() {
  return shots.find((s) => s.shotId === currentShotId)?.sceneId
    || shots[0]?.sceneId
    || null;
}

function refreshAddShotSceneLabel() {
  if (!addShotSceneLabel) return;
  if (sidebarMode === 'places') {
    addShotSceneLabel.textContent = 'Adds to Places page';
  } else {
    addShotSceneLabel.textContent = `Adds to ${currentSceneName()}`;
  }
}

function openAddShotSheet() {
  if (!addShotSheet) return;
  refreshAddShotSceneLabel();
  addShotTitleInput.value = '';
  addPlaceType = 'place';
  syncAddTypeUI();
  document.getElementById('add-shot-heading').textContent = sidebarMode === 'places' ? 'Add place or landmark' : 'Add shot';
  addPlaceTypeRow.hidden = sidebarMode !== 'places';
  addShotTitleInput.placeholder = sidebarMode === 'places' ? 'Name' : 'Shot N';
  addShotSheet.classList.remove('hidden');
  addShotSheet.hidden = false;
  addShotSheet.setAttribute('aria-hidden', 'false');
  isAddShotOpen = true;
  requestAnimationFrame(() => {
    addShotTitleInput.focus();
    addShotTitleInput.select();
  });
}

function closeAddShotSheet() {
  if (!addShotSheet) return;
  addShotSheet.hidden = true;
  addShotSheet.classList.add('hidden');
  addShotSheet.setAttribute('aria-hidden', 'true');
  isAddShotOpen = false;
}

function setupAddShotSheet() {
  if (!addShotBtn || !addShotSheet || !addShotForm || !addShotTitleInput) return;

  addShotBtn.addEventListener('click', openAddShotSheet);
  addShotCloseBtn?.addEventListener('click', closeAddShotSheet);
  addShotCancelBtn?.addEventListener('click', closeAddShotSheet);

  addShotSheet.addEventListener('click', (e) => {
    if (e.target === addShotSheet) closeAddShotSheet();
  });

  addTypePlaceBtn?.addEventListener('click', () => {
    addPlaceType = 'place';
    syncAddTypeUI();
  });

  addTypeLandmarkBtn?.addEventListener('click', () => {
    addPlaceType = 'landmark';
    syncAddTypeUI();
  });

  addShotForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    await createShotFromSheet();
  });
}

async function createShotFromSheet() {
  const title = addShotTitleInput.value.trim();
  if (sidebarMode === 'places') {
    await createPlaceTargetFromSheet(title);
    return;
  }
  const sceneId = currentSceneId();
  const payload = {};
  if (sceneId) payload.sceneId = sceneId;
  if (title) payload.title = title;

  try {
    await saveIfDirty();
    const created = await apiFetch('/api/shots', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    closeAddShotSheet();
    await refreshShots();
    if (created?.shotId) {
      await navigateTo(created.shotId, 'middle', false);
    }
  } catch (err) {
    console.error('Add shot failed:', err);
    setAppStatus('Failed to add shot.', 'error');
  }
}

async function createPlaceTargetFromSheet(title) {
  const endpoint = addPlaceType === 'landmark' ? '/api/landmarks' : '/api/places';
  const payload = addPlaceType === 'landmark'
    ? { title: title || 'New Landmark' }
    : { name: title || 'New Place' };

  try {
    await saveIfDirty();
    const created = await apiFetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    closeAddShotSheet();
    await refreshPlaces();
    const id = created?.id;
    if (id) {
      await navigateToPlaceTarget(addPlaceType, id, false);
    }
  } catch (err) {
    console.error('Add place/landmark failed:', err);
    setAppStatus('Failed to add place or landmark.', 'error');
  }
}

function syncAddTypeUI() {
  addTypePlaceBtn?.classList.toggle('add-type-btn--active', addPlaceType === 'place');
  addTypeLandmarkBtn?.classList.toggle('add-type-btn--active', addPlaceType === 'landmark');
}

// ─── Navigation ───────────────────────────────────────────────────────────

/**
 * Navigate to a shot + frame. Saves current canvas if dirty first.
 * @param {string} shotId
 * @param {string} frame - 'begin'|'middle'|'end'
 * @param {boolean} save - whether to save current frame first
 */
async function navigateTo(shotId, frame, save) {
  cancelStrokeEndSave();
  if (save) await saveIfDirty();

  sidebarMode = 'scenes';
  currentShotId = shotId;
  currentFrame = frame;

  localStorage.setItem(LS_MODE_KEY, sidebarMode);
  localStorage.setItem(LS_SHOT_KEY, shotId);
  localStorage.setItem(LS_FRAME_KEY, frame);

  renderSidebar();
  updateFramePickerUI();
  updateShotListActive();
  updateSummaryEditor();

  // Load canvas image
  resetUndoStacks();
  await loadImageURL(storyboardEndpoint(shotId, frame));
  clearDirty();
}

async function navigateToPlaceTarget(type, id, save) {
  cancelStrokeEndSave();
  if (save) await saveIfDirty();

  sidebarMode = 'places';
  currentPlaceTarget = { type, id };
  localStorage.setItem(LS_MODE_KEY, sidebarMode);
  localStorage.setItem(LS_PLACE_TARGET_KEY, JSON.stringify(currentPlaceTarget));

  renderSidebar();
  updateShotListActive();
  updateSummaryEditor();
  resetUndoStacks();
  const endpoint = placeSketchEndpoint(type, id);
  await loadImageURL(endpoint);
  clearDirty();
}

function parseStoredPlaceTarget() {
  try {
    const parsed = JSON.parse(localStorage.getItem(LS_PLACE_TARGET_KEY) || 'null');
    if ((parsed?.type === 'place' || parsed?.type === 'landmark') && parsed?.id) return parsed;
  } catch (_) { /* ignore */ }
  return null;
}

function findPlaceTarget(type, id) {
  return type === 'landmark'
    ? landmarks.find((item) => item.id === id)
    : places.find((item) => item.id === id);
}

function placeSketchEndpoint(type, id) {
  return type === 'landmark'
    ? `/api/landmarks/${id}/sketch`
    : `/api/places/${id}/sketch`;
}

function storyboardEndpoint(shotId, frame) {
  const shot = shots.find((s) => s.shotId === shotId);
  if (shot?.sceneId) {
    return `/api/scenes/${encodeURIComponent(shot.sceneId)}/shots/${encodeURIComponent(shotId)}/storyboard/${encodeURIComponent(frame)}`;
  }
  return `/api/storyboard/${encodeURIComponent(shotId)}/${encodeURIComponent(frame)}`;
}

async function navigateFrame(frame) {
  if (sidebarMode === 'places') return;
  if (frame === currentFrame) return;
  await saveIfDirty();
  currentFrame = frame;
  localStorage.setItem(LS_FRAME_KEY, frame);
  updateFramePickerUI();
  resetUndoStacks();
  await loadImageURL(storyboardEndpoint(currentShotId, frame));
  clearDirty();
}

/** Move to prev/next frame across all shots */
async function navigateStep(direction) {
  if (sidebarMode === 'places') return;
  const flatFrames = buildFlatFrameList();
  const current = flatFrames.findIndex(
    (f) => f.shotId === currentShotId && f.frame === currentFrame
  );
  if (current === -1) return;

  const target = current + direction;
  if (target < 0 || target >= flatFrames.length) return;

  await saveIfDirty();
  const { shotId, frame } = flatFrames[target];

  if (shotId !== currentShotId) {
    currentShotId = shotId;
    updateShotListActive();
    updateSummaryEditor();
  }
  currentFrame = frame;
  localStorage.setItem(LS_SHOT_KEY, shotId);
  localStorage.setItem(LS_FRAME_KEY, frame);

  updateFramePickerUI();
  resetUndoStacks();
  await loadImageURL(storyboardEndpoint(shotId, frame));
  clearDirty();
}

function buildFlatFrameList() {
  const list = [];
  for (const shot of shots) {
    for (const f of FRAMES) {
      list.push({ shotId: shot.shotId, frame: f });
    }
  }
  return list;
}

// ─── Save logic ───────────────────────────────────────────────────────────

let strokeEndSaveTimer = null;

function cancelStrokeEndSave() {
  if (strokeEndSaveTimer) {
    clearTimeout(strokeEndSaveTimer);
    strokeEndSaveTimer = null;
  }
}

function markDirty() {
  isDirty = true;
  setSaveStatus('unsaved');
  // Drawings are precious — schedule a debounced save right after the stroke
  // ends so we don't rely on the slower interval-based autosave catching up.
  if (strokeEndSaveTimer) clearTimeout(strokeEndSaveTimer);
  strokeEndSaveTimer = setTimeout(() => {
    strokeEndSaveTimer = null;
    if (isDirty && !isSaving) performSave();
  }, STROKE_END_SAVE_DEBOUNCE_MS);
}

function clearDirty() {
  isDirty = false;
  setSaveStatus('saved');
}

async function saveIfDirty() {
  // Always cancel the pending stroke-end debounce — once we commit to a save
  // (or a navigation calls us), there's no reason to let the timer fire later
  // against potentially-different state.
  cancelStrokeEndSave();
  if (!isDirty) return;
  if (sidebarMode === 'places' && !currentPlaceTarget) return;
  if (sidebarMode !== 'places' && !currentShotId) return;
  await performSave();
}

// The Fetch spec caps keepalive request bodies at 64 KB — and since our
// PNGs routinely exceed that, blindly setting keepalive: true on a backgrounded
// save would silently drop the body. Keep this just under the limit so we can
// reliably fall back to a non-keepalive fetch when the page is still alive.
const KEEPALIVE_MAX_BODY_BYTES = 60_000;

async function performSave({ keepalive = false } = {}) {
  if (isSaving) return;
  if (sidebarMode === 'places' && !currentPlaceTarget) return;
  if (sidebarMode !== 'places' && !currentShotId) return;
  isSaving = true;
  setSaveStatus('saving');

  // Snapshot the destination at request-build time so a mid-flight shot/frame
  // switch can't redirect the bytes we already exported.
  const sidebarSnapshot = sidebarMode;
  const placeSnapshot = currentPlaceTarget;
  const shotSnapshot = currentShotId;
  const frameSnapshot = currentFrame;

  try {
    const blob = await exportPNG();
    const endpoint = sidebarSnapshot === 'places'
      ? placeSketchEndpoint(placeSnapshot.type, placeSnapshot.id)
      : storyboardEndpoint(shotSnapshot, frameSnapshot);
    // keepalive bodies are capped at ~64 KB. PNG blobs of real drawings are
    // always larger, so only set keepalive when the document is genuinely
    // being torn down AND the blob is small enough to actually go out.
    const oversized = blob.size > KEEPALIVE_MAX_BODY_BYTES;
    const useKeepalive = keepalive && !oversized;
    if (keepalive && oversized) {
      console.warn(
        '[storyboard] save during page-hide skipped keepalive — blob is',
        blob.size, 'bytes (limit', KEEPALIVE_MAX_BODY_BYTES, ').',
        'Falling back to a normal fetch; if the page is being unloaded the',
        'browser may cancel it. The 5s autosave should already have caught it.'
      );
    }
    await apiFetch(endpoint, {
      method: 'PUT',
      headers: { 'Content-Type': 'image/png' },
      body: blob,
      keepalive: useKeepalive,
    });
    // Only mark this destination as clean if the user hasn't already moved on.
    if (
      sidebarMode === sidebarSnapshot &&
      currentShotId === shotSnapshot &&
      currentFrame === frameSnapshot &&
      currentPlaceTarget?.id === placeSnapshot?.id
    ) {
      clearDirty();
    }
    if (sidebarSnapshot === 'places') {
      const item = findPlaceTarget(placeSnapshot.type, placeSnapshot.id);
      if (item) item.hasSketch = true;
      renderSidebar();
    } else {
      // Update sidebar dot
      updateShotBME(shotSnapshot, frameSnapshot, true);
      // Update local shots cache
      const shot = shots.find((s) => s.shotId === shotSnapshot);
      if (shot && shot.hasFrames) shot.hasFrames[frameSnapshot] = true;
    }
  } catch (err) {
    setSaveStatus('error');
    console.error('Save failed:', err);
  } finally {
    isSaving = false;
  }
}

function setSaveStatus(state) {
  const labels = { saved: 'Saved', saving: 'Saving…', unsaved: 'Unsaved', error: 'Save failed' };
  saveStatusEl.dataset.state = state;
  saveStatusEl.textContent = labels[state] || '';
}

function startAutosave() {
  if (autosaveTimer) clearInterval(autosaveTimer);
  autosaveTimer = setInterval(() => {
    if (isDirty && !isSaving) performSave();
  }, AUTOSAVE_INTERVAL_MS);
}

// Save on every event that means "this page may be torn down soon" — PWA
// backgrounded, tab closed, iPad locked, app switcher, etc. keepalive: true
// lets the in-flight request finish even if the document is being unloaded.
function installSaveOnExitHooks() {
  // Synchronous reentrancy guard. `pagehide` and `visibilitychange→hidden`
  // can both fire in the same task on iOS Safari; without this both would
  // pass `isSaving === false` (which is only set after `await exportPNG()`)
  // and double-save the same canvas.
  let isFlushPending = false;

  const flush = () => {
    if (isFlushPending || !isDirty || isSaving) return;
    isFlushPending = true;
    cancelStrokeEndSave();
    Promise.resolve(performSave({ keepalive: true })).finally(() => {
      isFlushPending = false;
    });
  };

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') flush();
  });
  window.addEventListener('pagehide', flush);
  window.addEventListener('beforeunload', flush);

  // iOS Safari fires window `blur` for both real app-switches AND for
  // intra-page focus changes (e.g., focusing the summary textarea). Defer
  // by one tick and only flush if no element inside the document took focus
  // — that's the difference between "user left" and "user tapped a textarea".
  window.addEventListener('blur', () => {
    setTimeout(() => {
      if (document.hasFocus()) return;
      const active = document.activeElement;
      if (active && active !== document.body && active !== document.documentElement) {
        return; // intra-page focus transfer — not an exit signal
      }
      flush();
    }, 0);
  });
}

// ─── Summary editor ───────────────────────────────────────────────────────

function updateSummaryEditor() {
  if (sidebarMode === 'places') {
    const item = currentPlaceTarget ? findPlaceTarget(currentPlaceTarget.type, currentPlaceTarget.id) : null;
    summaryEditor.value = item ? (item.notes || '') : '';
    summaryEditor.placeholder = currentPlaceTarget?.type === 'landmark' ? 'Landmark notes…' : 'Place notes…';
    summaryEditor.disabled = true;
    frameBtns.forEach((btn) => { btn.disabled = true; });
    autoGrowTextarea(summaryEditor);
    return;
  }
  const shot = shots.find((s) => s.shotId === currentShotId);
  summaryEditor.value = shot ? (shot.summary || '') : '';
  summaryEditor.placeholder = 'Shot summary…';
  summaryEditor.disabled = false;
  frameBtns.forEach((btn) => { btn.disabled = false; });
  autoGrowTextarea(summaryEditor);
}

function setupSummary() {
  summaryEditor.addEventListener('input', () => {
    autoGrowTextarea(summaryEditor);
    if (summaryDebounceTimer) clearTimeout(summaryDebounceTimer);
    summaryDebounceTimer = setTimeout(() => saveSummary(), SUMMARY_DEBOUNCE_MS);
  });

  summaryEditor.addEventListener('blur', () => {
    if (summaryDebounceTimer) clearTimeout(summaryDebounceTimer);
    saveSummary();
  });

  // Prevent keyboard shortcuts from firing while typing
  summaryEditor.addEventListener('keydown', (e) => {
    e.stopPropagation();
  });
}

async function saveSummary() {
  if (sidebarMode === 'places') return;
  if (!currentShotId) return;
  const text = summaryEditor.value;

  // Update local cache
  const shot = shots.find((s) => s.shotId === currentShotId);
  if (shot) shot.summary = text;

  try {
    await apiFetch(`/api/shots/${currentShotId}/summary`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ summary: text }),
    });
  } catch (err) {
    console.error('Summary save failed:', err);
  }
}

function autoGrowTextarea(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 72) + 'px';
}

function isCanvasTarget(target) {
  if (!(target instanceof Element)) return false;
  return Boolean(target.closest('#drawing-canvas, .canvas-area'));
}

function installInputGuards() {
  // Suppress iOS pinch/zoom gestures on the drawing canvas only. Finger taps
  // on regular UI elements (buttons, toolbar, sidebar rows) are allowed
  // through — pencil-only enforcement happens inside drawing.js, which
  // filters by pointerType on the canvas itself.
  ['gesturestart', 'gesturechange', 'gestureend'].forEach((eventName) => {
    document.addEventListener(eventName, (e) => {
      if (isCanvasTarget(e.target)) e.preventDefault();
    }, { capture: true, passive: false });
  });

  // Block the long-press context menu on the canvas (would interrupt drawing).
  document.addEventListener('contextmenu', (e) => {
    if (isCanvasTarget(e.target)) e.preventDefault();
  }, { capture: true });
}

// ─── Frame picker ─────────────────────────────────────────────────────────

function setupFramePicker() {
  frameBtns.forEach((btn) => {
    btn.addEventListener('click', async () => {
      const frame = btn.dataset.frame;
      if (frame === currentFrame) return;
      await navigateFrame(frame);
    });
  });
}

function updateFramePickerUI() {
  frameBtns.forEach((btn) => {
    btn.classList.toggle('frame-btn--active', btn.dataset.frame === currentFrame);
  });
}

// ─── Toolbar ──────────────────────────────────────────────────────────────

function setupToolbar() {
  // Tool buttons
  pencilBtn.addEventListener('click', () => {
    selectTool('pencil');
  });

  eraserBtn.addEventListener('click', () => {
    selectTool('eraser');
  });

  // Brush slider
  brushSlider.addEventListener('input', () => {
    const val = parseInt(brushSlider.value, 10);
    setActiveBrushSize(val);
  });

  // Brush +/- step buttons
  brushDecBtn?.addEventListener('click', (e) => {
    e.preventDefault();
    adjustBrush(-1);
  });
  brushIncBtn?.addEventListener('click', (e) => {
    e.preventDefault();
    adjustBrush(1);
  });

  // Copy / paste in-memory clipboard
  copyBtn?.addEventListener('click', () => {
    try {
      copiedFrameDataURL = canvasEl.toDataURL('image/png');
      if (pasteBtn) pasteBtn.disabled = false;
      setSaveStatus(isDirty ? 'unsaved' : 'saved');
    } catch (err) {
      console.error('Copy failed:', err);
    }
  });

  pasteBtn?.addEventListener('click', async () => {
    if (!copiedFrameDataURL) return;
    try {
      await pasteImageURL(copiedFrameDataURL);
      markDirty();
    } catch (err) {
      console.error('Paste failed:', err);
    }
  });

  scaffoldSelect?.addEventListener('change', () => {
    currentScaffoldId = scaffoldSelect.value;
    localStorage.setItem(LS_SCAFFOLD_ID_KEY, currentScaffoldId);
    syncScaffoldModeUI();
  });

  scaffoldModeColorBtn?.addEventListener('click', () => {
    currentScaffoldMode = 'color';
    syncScaffoldModeUI();
  });

  scaffoldModeBWBtn?.addEventListener('click', () => {
    currentScaffoldMode = 'bw';
    syncScaffoldModeUI();
  });

  scaffoldRefreshBtn?.addEventListener('click', () => {
    refreshScaffolds();
  });

  scaffoldImportBtn?.addEventListener('click', () => {
    importSelectedScaffold();
  });

  // Undo / redo
  undoBtn.addEventListener('click', () => { undo(); });
  redoBtn.addEventListener('click', () => { redo(); });

  // Clear
  clearBtn.addEventListener('click', () => {
    if (confirm('Clear this frame?')) {
      clearCanvas();
    }
  });

  // Nav
  prevBtn.addEventListener('click', () => navigateStep(-1));
  nextBtn.addEventListener('click', () => navigateStep(1));

  // Toolbar toggle
  toolbarToggleBtn.addEventListener('click', () => {
    isToolbarOpen = false;
    toolbar.classList.add('toolbar--closed');
    toolbarShowBtn.classList.remove('hidden');
    toolbarToggleBtn.classList.add('hidden');
    updateLayout();
  });

  toolbarShowBtn.addEventListener('click', () => {
    isToolbarOpen = true;
    toolbar.classList.remove('toolbar--closed');
    toolbarShowBtn.classList.add('hidden');
    toolbarToggleBtn.classList.remove('hidden');
    updateLayout();
  });

  // Initial undo/redo state
  undoBtn.disabled = true;
  redoBtn.disabled = true;

  syncBrushUi(currentTool);
}

// ─── Sidebar ──────────────────────────────────────────────────────────────

function setupSidebar() {
  sidebarTabScenes?.addEventListener('click', async () => {
    if (sidebarMode === 'scenes') return;
    await saveIfDirty();
    sidebarMode = 'scenes';
    localStorage.setItem(LS_MODE_KEY, sidebarMode);
    renderSidebar();
    updateSummaryEditor();
    if (currentShotId) {
      resetUndoStacks();
      await loadImageURL(storyboardEndpoint(currentShotId, currentFrame));
      clearDirty();
    }
  });

  sidebarTabPlaces?.addEventListener('click', async () => {
    if (sidebarMode === 'places') return;
    await saveIfDirty();
    sidebarMode = 'places';
    localStorage.setItem(LS_MODE_KEY, sidebarMode);
    if (!places.length && !landmarks.length) await refreshPlaces();
    if (!currentPlaceTarget) {
      if (places[0]) currentPlaceTarget = { type: 'place', id: places[0].id };
      else if (landmarks[0]) currentPlaceTarget = { type: 'landmark', id: landmarks[0].id };
    }
    renderSidebar();
    updateSummaryEditor();
    if (currentPlaceTarget) {
      resetUndoStacks();
      await loadImageURL(placeSketchEndpoint(currentPlaceTarget.type, currentPlaceTarget.id));
      clearDirty();
    } else {
      clearCanvas();
      clearDirty();
    }
  });

}

// ─── Layout ───────────────────────────────────────────────────────────────

function updateLayout() {
  // Trigger recalcLayout after transitions settle
  requestAnimationFrame(() => {
    const rect = canvasArea.getBoundingClientRect();
    recalcLayout(rect.width, rect.height);
  });
}

function setupWindowResize() {
  const ro = new ResizeObserver(() => updateLayout());
  ro.observe(canvasArea);
}

// ─── Keyboard ─────────────────────────────────────────────────────────────

function setupKeyboard() {
  document.addEventListener('keydown', async (e) => {
    if (isAddShotOpen) {
      if (e.key === 'Escape') {
        e.preventDefault();
        closeAddShotSheet();
      }
      return;
    }

    // Don't intercept when focus is in a text field
    if (e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT') return;

    const cmd = e.metaKey || e.ctrlKey;

    switch (e.key) {
      case 'ArrowLeft':
        e.preventDefault();
        await navigateStep(-1);
        break;
      case 'ArrowRight':
        e.preventDefault();
        await navigateStep(1);
        break;
      case 'z':
        if (cmd && e.shiftKey) { e.preventDefault(); redo(); }
        else if (cmd) { e.preventDefault(); undo(); }
        break;
      case 'e':
      case 'E':
        e.preventDefault();
        selectTool('eraser');
        break;
      case 'p':
      case 'P':
        e.preventDefault();
        selectTool('pencil');
        break;
      case '[':
        e.preventDefault();
        adjustBrush(-2);
        break;
      case ']':
        e.preventDefault();
        adjustBrush(2);
        break;
      case 's':
        if (cmd) { e.preventDefault(); await performSave(); }
        break;
    }
  });
}

// ─── Start ────────────────────────────────────────────────────────────────

boot().catch((err) => {
  console.error('Storyboard boot failed:', err);
  setAppStatus('Storyboard failed to load.', 'error');
  shotListEl.innerHTML = '<div class="shot-list-loading">Error loading app.</div>';
});

function clearAppStatus() {
  if (!appStatusEl) return;
  appStatusEl.hidden = true;
}

function setAppStatus(message, state = 'loading') {
  if (!appStatusEl) return;
  appStatusEl.hidden = false;
  appStatusEl.textContent = message;
  appStatusEl.dataset.state = state;
}
