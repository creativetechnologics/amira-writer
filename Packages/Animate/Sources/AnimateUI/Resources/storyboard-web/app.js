/**
 * app.js — Storyboard Tool main application
 * Handles: shot list, navigation, frame selection, summary editing,
 * auto-save, keyboard shortcuts, sidebar/toolbar toggles.
 */

import {
  initDrawing,
  recalcLayout,
  loadImageURL,
  exportPNG,
  setTool,
  setBrushSize,
  undo,
  redo,
  clearCanvas,
  resetUndoStacks,
  enrichLastPointWithTilt,
} from './drawing.js';

// ─── Constants ────────────────────────────────────────────────────────────

const AUTOSAVE_INTERVAL_MS = 30_000;
const SUMMARY_DEBOUNCE_MS = 1_500;
const FRAMES = ['begin', 'middle', 'end'];
const LS_SHOT_KEY = 'storyboard_shotId';
const LS_FRAME_KEY = 'storyboard_frame';

// ─── App state ────────────────────────────────────────────────────────────

let shots = [];                // flat array from /api/shots
let currentShotId = null;
let currentFrame = 'middle';   // 'begin' | 'middle' | 'end'
let isDirty = false;
let isSidebarOpen = true;
let isToolbarOpen = true;
let summaryDebounceTimer = null;
let autosaveTimer = null;
let isSaving = false;

// ─── DOM refs ─────────────────────────────────────────────────────────────

const canvasEl = document.getElementById('drawing-canvas');
const canvasArea = document.getElementById('canvas-area');
const shotListEl = document.getElementById('shot-list');
const sidebar = document.getElementById('sidebar');
const mainEl = document.getElementById('main');
const toolbar = document.getElementById('toolbar');
const toolbarShowBtn = document.getElementById('toolbar-show-btn');
const toolbarToggleBtn = document.getElementById('toolbar-toggle-btn');
const sidebarToggleBtn = document.getElementById('sidebar-toggle-btn');
const sidebarCloseBtn = document.getElementById('sidebar-close-btn');
const projectNameEl = document.getElementById('project-name');
const saveStatusEl = document.getElementById('save-status');
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

// ─── Boot ──────────────────────────────────────────────────────────────────

async function boot() {
  // Init drawing engine
  initDrawing(canvasEl, markDirty);

  // Wire tilt enrichment into pointer events on the canvas
  canvasEl.addEventListener('pointermove', (e) => {
    if (e.pointerType === 'pen' && e.altitudeAngle != null) {
      enrichLastPointWithTilt(e.altitudeAngle);
    }
  }, { passive: true });

  setupToolbar();
  setupSidebar();
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

  // Restore last position from localStorage
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

  updateLayout();
  startAutosave();
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

// ─── Shot list ────────────────────────────────────────────────────────────

async function refreshShots() {
  try {
    shots = await apiFetch('/api/shots');
    renderShotList();
  } catch (err) {
    shotListEl.innerHTML = '<div class="shot-list-loading">Failed to load shots.</div>';
  }
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

      row.appendChild(name);
      row.appendChild(bme);

      row.addEventListener('click', async () => {
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

function updateShotListActive() {
  const rows = shotListEl.querySelectorAll('.shot-row');
  rows.forEach((row) => {
    row.classList.toggle('shot-row--active', row.dataset.shotId === currentShotId);
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

// ─── Navigation ───────────────────────────────────────────────────────────

/**
 * Navigate to a shot + frame. Saves current canvas if dirty first.
 * @param {string} shotId
 * @param {string} frame - 'begin'|'middle'|'end'
 * @param {boolean} save - whether to save current frame first
 */
async function navigateTo(shotId, frame, save) {
  if (save) await saveIfDirty();

  currentShotId = shotId;
  currentFrame = frame;

  localStorage.setItem(LS_SHOT_KEY, shotId);
  localStorage.setItem(LS_FRAME_KEY, frame);

  updateFramePickerUI();
  updateShotListActive();
  updateSummaryEditor();

  // Load canvas image
  resetUndoStacks();
  await loadImageURL(`/api/storyboard/${shotId}/${frame}`);
  clearDirty();
}

async function navigateFrame(frame) {
  if (frame === currentFrame) return;
  await saveIfDirty();
  currentFrame = frame;
  localStorage.setItem(LS_FRAME_KEY, frame);
  updateFramePickerUI();
  resetUndoStacks();
  await loadImageURL(`/api/storyboard/${currentShotId}/${frame}`);
  clearDirty();
}

/** Move to prev/next frame across all shots */
async function navigateStep(direction) {
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
  await loadImageURL(`/api/storyboard/${shotId}/${frame}`);
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

function markDirty() {
  isDirty = true;
  setSaveStatus('unsaved');
}

function clearDirty() {
  isDirty = false;
  setSaveStatus('saved');
}

async function saveIfDirty() {
  if (!isDirty || !currentShotId) return;
  await performSave();
}

async function performSave() {
  if (isSaving || !currentShotId) return;
  isSaving = true;
  setSaveStatus('saving');

  try {
    const blob = await exportPNG();
    await apiFetch(`/api/storyboard/${currentShotId}/${currentFrame}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'image/png' },
      body: blob,
    });
    clearDirty();
    // Update sidebar dot
    updateShotBME(currentShotId, currentFrame, true);
    // Update local shots cache
    const shot = shots.find((s) => s.shotId === currentShotId);
    if (shot && shot.hasFrames) shot.hasFrames[currentFrame] = true;
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

// ─── Summary editor ───────────────────────────────────────────────────────

function updateSummaryEditor() {
  const shot = shots.find((s) => s.shotId === currentShotId);
  summaryEditor.value = shot ? (shot.summary || '') : '';
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
    setTool('pencil');
    pencilBtn.classList.add('tool-btn--active');
    eraserBtn.classList.remove('tool-btn--active');
  });

  eraserBtn.addEventListener('click', () => {
    setTool('eraser');
    eraserBtn.classList.add('tool-btn--active');
    pencilBtn.classList.remove('tool-btn--active');
  });

  // Brush slider
  brushSlider.addEventListener('input', () => {
    const val = parseInt(brushSlider.value, 10);
    brushValue.textContent = val;
    setBrushSize(val);
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
}

// ─── Sidebar ──────────────────────────────────────────────────────────────

function setupSidebar() {
  sidebarCloseBtn.addEventListener('click', () => {
    isSidebarOpen = false;
    sidebar.classList.add('sidebar--closed');
    sidebarToggleBtn.classList.remove('hidden');
    updateLayout();
  });

  sidebarToggleBtn.addEventListener('click', () => {
    isSidebarOpen = true;
    sidebar.classList.remove('sidebar--closed');
    sidebarToggleBtn.classList.add('hidden');
    updateLayout();
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
        setTool('eraser');
        eraserBtn.classList.add('tool-btn--active');
        pencilBtn.classList.remove('tool-btn--active');
        break;
      case 'p':
      case 'P':
        setTool('pencil');
        pencilBtn.classList.add('tool-btn--active');
        eraserBtn.classList.remove('tool-btn--active');
        break;
      case '[':
        adjustBrush(-2);
        break;
      case ']':
        adjustBrush(2);
        break;
      case 's':
        if (cmd) { e.preventDefault(); await performSave(); }
        break;
    }
  });
}

function adjustBrush(delta) {
  const cur = parseInt(brushSlider.value, 10);
  const next = Math.max(2, Math.min(40, cur + delta));
  brushSlider.value = next;
  brushValue.textContent = next;
  setBrushSize(next);
}

// ─── Start ────────────────────────────────────────────────────────────────

boot().catch((err) => {
  console.error('Storyboard boot failed:', err);
  shotListEl.innerHTML = '<div class="shot-list-loading">Error loading app.</div>';
});
