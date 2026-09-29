(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);

  // Must match EXTENSION_VERSION in kitchen_cabinet_master.rb. If SketchUp is still
  // running older Ruby files than this panel (an update without a restart), the
  // panel says so instead of failing on data the old Ruby never sends.
  const APP_VERSION = '0.11.2';

  const list = (value) => (Array.isArray(value) ? value : []);

  const FALLBACK_LISTS = {
    handle_orientations: [{ id: 'vertical', name: 'Vertical' }, { id: 'horizontal', name: 'Horizontal' }],
    handle_positions: ['top', 'center', 'bottom', 'left', 'right', 'custom']
      .map((id) => ({ id, name: id.charAt(0).toUpperCase() + id.slice(1) })),
    end_panel_sides: [{ id: 'left', name: 'Left' }, { id: 'right', name: 'Right' }]
  };

  const FILLER_FIELD_TO_ELEMENT = {
    width: 'fillerWidth', thickness: 'fillerThickness', height: 'fillerHeight', material: 'fillerMaterial'
  };
  const END_PANEL_FIELD_TO_ELEMENT = { side: 'epSide', thickness: 'epThickness', material: 'epMaterial' };

  // Server field name -> id of the element that edits it (used to highlight errors).
  const FIELD_TO_ELEMENT = {
    catalog_id: 'catalog',
    handle_id: 'handle',
    handle_material: 'handleMaterial',
    base_material: 'baseMaterial',
    wall_material: 'wallMaterial',
    tall_material: 'tallMaterial',
    corner_material: 'cornerMaterial',
    material_thickness: 'thickness',
    back_thickness: 'backThickness',
    door_gap: 'doorGap',
    door_opening_direction: 'direction',
    door_opening_angle: 'angle',
    cabinet_category: 'category',
    cabinet_type: 'cabinet',
    placement_gap: 'gap',
    width: 'width',
    depth: 'depth',
    height: 'height',
    shelf_count: 'shelves',
    carcass_material: 'carcassMaterial',
    door_reveal: 'doorReveal',
    toe_kick_height: 'toeHeight',
    toe_kick_thickness: 'toeThickness',
    toe_kick_material: 'toeMaterial',
    toe_kick_piece_length: 'pieceLength',
    toe_kick_pieces: 'pieceCount',
    toe_kick_recess: 'toeRecess',
    handle_length: 'handleLength',
    handle_finish: 'handleFinish',
    handle_material: 'handleMaterial',
    handle_orientation: 'handleOrientation',
    handle_position: 'handlePosition',
    handle_side_offset: 'handleSide',
    handle_vertical_offset: 'handleVert',
    handle_custom_x: 'handleCustomX',
    handle_custom_z: 'handleCustomZ'
  };

  // Server parameter -> element id, for filling the form from stored parameters.
  const TEXT_PARAMS = {
    material_thickness: 'thickness',
    back_thickness: 'backThickness',
    door_gap: 'doorGap',
    door_reveal: 'doorReveal',
    door_opening_angle: 'angle',
    placement_gap: 'gap',
    width: 'width',
    depth: 'depth',
    height: 'height',
    shelf_count: 'shelves',
    toe_kick_height: 'toeHeight',
    toe_kick_thickness: 'toeThickness',
    toe_kick_piece_length: 'pieceLength',
    toe_kick_pieces: 'pieceCount',
    toe_kick_recess: 'toeRecess',
    handle_side_offset: 'handleSide',
    handle_vertical_offset: 'handleVert',
    handle_custom_x: 'handleCustomX',
    handle_custom_z: 'handleCustomZ'
  };

  const SELECT_PARAMS = {
    handle_id: 'handle',
    base_material: 'baseMaterial',
    wall_material: 'wallMaterial',
    tall_material: 'tallMaterial',
    corner_material: 'cornerMaterial',
    carcass_material: 'carcassMaterial',
    toe_kick_material: 'toeMaterial',
    door_opening_direction: 'direction',
    handle_length: 'handleLength',
    handle_finish: 'handleFinish',
    handle_orientation: 'handleOrientation',
    handle_position: 'handlePosition'
  };

  const REQUEST_TIMEOUT_MS = 20000;

  const state = {
    meta: null,
    cabinets: [],
    colors: {},
    finishColors: {},
    pending: new Map(),
    seq: 0,
    busy: false,
    lastMaterialRefresh: 0,
    // What is selected in the model: 'cabinet', 'filler', 'end_panel', 'toe_kick' or null.
    selectedKind: null,
    // Filler / end panel fields the user has set themselves (see followCabinet).
    touched: new Set()
  };

  /* ---------------------------------------------------------------------- *
   * Bridge to Ruby
   * ---------------------------------------------------------------------- */

  function call(action, data = {}) {
    return new Promise((resolve, reject) => {
      if (!window.sketchup || typeof window.sketchup.kcm_request !== 'function') {
        reject(new Error('Not connected to SketchUp. Open this panel from Extensions > Kitchen Cabinet Master.'));
        return;
      }
      const id = ++state.seq;
      const timer = setTimeout(() => {
        state.pending.delete(id);
        reject(new Error('SketchUp did not answer in time.'));
      }, REQUEST_TIMEOUT_MS);
      state.pending.set(id, { resolve, timer });
      window.sketchup.kcm_request(JSON.stringify({ id, action, data }));
    });
  }

  // Called by Ruby via dialog.execute_script.
  window.KCM = {
    receive(message) {
      if (!message) return;
      if (message.id !== undefined && message.id !== null && state.pending.has(message.id)) {
        const entry = state.pending.get(message.id);
        state.pending.delete(message.id);
        clearTimeout(entry.timer);
        entry.resolve(message);
      } else if (message.event) {
        handleEvent(message.event, message.data || {});
      }
    }
  };

  // What the user has selected in the model decides which form Update reads and
  // what Update / Delete act on: a cabinet, a filler, an end panel or a toe kick.
  function handleEvent(name, data) {
    // Our own live update re-selects the item it just changed; do not let that
    // overwrite what the user is in the middle of typing.
    if (state.liveBusy && (name === 'cabinet_selected' || name === 'part_selected')) return;

    if (name === 'cabinet_selected') {
      state.selectedKind = 'cabinet';
      loadCabinet(data);
    } else if (name === 'part_selected') {
      const kind = ['end_panel', 'toe_kick'].includes(data.part_kind) ? data.part_kind : 'filler';
      state.selectedKind = kind;
      setBadge(data.part_name);
      if (kind === 'end_panel') applyEndPanelDefaults(data);
      else if (kind === 'toe_kick') applyToeKickDefaults(data);
      else applyFillerDefaults(data);
      // Fillers and end panels are Cabinet Category choices: show the matching fields.
      if (kind !== 'toe_kick') setSelect('category', kind);
      updateCategoryUi();
    } else if (name === 'cabinet_cleared') {
      state.selectedKind = null;
      setBadge(null);
    }
  }

  function applyToeKickDefaults(d) {
    setText('toeHeight', d.toe_kick_height);
    setText('toeThickness', d.toe_kick_thickness);
    setText('pieceLength', d.toe_kick_piece_length);
    setText('pieceCount', d.toe_kick_pieces);
    setText('toeRecess', d.toe_kick_recess);
    const material = d.toe_kick_material === '__cabinet__' ? '__door__' : d.toe_kick_material;
    setSelect('toeMaterial', material || '__door__');
    updateChips();
  }

  function collectToeKick() {
    return {
      toe_kick_height: $('toeHeight').value,
      toe_kick_thickness: $('toeThickness').value,
      toe_kick_material: $('toeMaterial').value,
      toe_kick_piece_length: $('pieceLength').value,
      toe_kick_pieces: $('pieceCount').value,
      toe_kick_recess: $('toeRecess').value,
      // Used only when nothing is selected: the carcass depth the toe kick sits under.
      depth: $('depth').value,
      // A new toe kick follows the Toe Kick tick in the Visibility section.
      visible: $('visToe').checked
    };
  }

  function applyFillerDefaults(d) {
    setText('fillerWidth', d.width);
    setText('fillerThickness', d.thickness);
    setText('fillerHeight', d.height);
    setSelect('fillerMaterial', d.material);
    updateChips();
  }

  // A filler's height, and the material of a filler or end panel, START as those
  // of the cabinet in the model (its height and door material) and follow it as
  // cabinets are selected, until the user types or picks their own. Then they
  // stay put, so "enter the data, select the cabinet, Insert" keeps what was entered.
  const FOLLOWS_CABINET = ['fillerHeight', 'fillerMaterial', 'epMaterial'];

  function followCabinet(cabinet) {
    const set = (id, apply) => { if (!state.touched.has(id)) apply(); };
    if (cabinet.height) set('fillerHeight', () => setText('fillerHeight', cabinet.height));
    if (cabinet.material) {
      set('fillerMaterial', () => setSelect('fillerMaterial', cabinet.material));
      set('epMaterial', () => setSelect('epMaterial', cabinet.material));
    }
    updateChips();
  }

  // After a filler or end panel is inserted, the next one starts from the cabinet again.
  function resetFollowing() {
    FOLLOWS_CABINET.forEach((id) => state.touched.delete(id));
  }

  function applyEndPanelDefaults(d) {
    setSelect('epSide', d.side);
    setText('epThickness', d.thickness);
    setSelect('epMaterial', d.material);
    updateChips();
  }

  function collectFiller() {
    return {
      width: $('fillerWidth').value,
      thickness: $('fillerThickness').value,
      height: $('fillerHeight').value,
      material: $('fillerMaterial').value
    };
  }

  function collectEndPanel() {
    return {
      side: $('epSide').value,
      thickness: $('epThickness').value,
      material: $('epMaterial').value
    };
  }

  // Which form an action reads. Each Insert button belongs to its own block;
  // Update follows whatever is selected in the model.
  const COLLECTORS = {
    cabinet: () => collect(),
    filler: () => collectFiller(),
    end_panel: () => collectEndPanel(),
    toe_kick: () => collectToeKick()
  };

  // Fillers and end panels are choices in the Cabinet Category list. Every other
  // category is a real cabinet.
  function categoryKind() {
    const value = $('category').value;
    return value === 'filler' || value === 'end_panel' ? value : 'cabinet';
  }

  // Insert follows the Cabinet Category (or is the Toe Kick block's own button);
  // Update follows whatever is selected in the model.
  function formKind(action) {
    if (action === 'insert') return categoryKind();
    if (action === 'insert_toe_kick') return 'toe_kick';
    if (action === 'update') return state.selectedKind || categoryKind();
    return null;
  }

  // Cabinets have their own Insert / Update / Delete; a filler, end panel or toe
  // kick has its own Insert and shares one Update / Delete (update_part / delete_part).
  function serverAction(action) {
    const isPart = state.selectedKind && state.selectedKind !== 'cabinet';
    if (isPart && action === 'update') return 'update_part';
    if (isPart && action === 'delete') return 'delete_part';
    if (action === 'insert') return { filler: 'insert_filler', end_panel: 'insert_end_panel' }[categoryKind()] || 'insert';
    return action;
  }

  /* ---------------------------------------------------------------------- *
   * Small helpers
   * ---------------------------------------------------------------------- */

  function num(value) {
    const n = parseFloat(String(value).trim().replace(',', '.'));
    return Number.isFinite(n) ? n : NaN;
  }

  function fmt(n) {
    if (!Number.isFinite(n)) return '';
    return Number.isInteger(n) ? String(n) : String(Math.round(n * 10) / 10);
  }

  function fillSelect(el, items, { placeholder = null } = {}) {
    const previous = el.value;
    el.innerHTML = '';
    if (placeholder) el.append(new Option(placeholder, ''));
    list(items).forEach((item) => el.append(new Option(item.name, item.id)));
    if ([...el.options].some((o) => o.value === previous)) el.value = previous;
  }

  function setSelect(id, value) {
    const el = $(id);
    const text = String(value === undefined || value === null ? '' : value);
    if ([...el.options].some((o) => o.value === text)) el.value = text;
  }

  function setText(id, value) {
    if (value === undefined || value === null) return;
    $(id).value = typeof value === 'number' ? fmt(value) : String(value);
  }

  function currentCabinet() {
    return state.cabinets.find((c) => c.id === $('cabinet').value) || null;
  }

  /* ---------------------------------------------------------------------- *
   * Materials
   * ---------------------------------------------------------------------- */

  function loadMaterials(materials) {
    const panel = list(materials && materials.panel);
    const toeKick = list(materials && materials.toe_kick);
    state.colors = {};
    [...panel, ...toeKick].forEach((m) => {
      if (m.color) state.colors[m.id] = m.color;
    });
    ['baseMaterial', 'wallMaterial', 'tallMaterial', 'cornerMaterial'].forEach((id) => fillSelect($(id), panel));
    fillSelect($('carcassMaterial'), panel, { placeholder: 'Same as door material' });
    fillSelect($('handleMaterial'), panel, { placeholder: "Use the finish's material" });
    fillSelect($('toeMaterial'), toeKick);
    fillSelect($('fillerMaterial'), panel);
    fillSelect($('epMaterial'), panel);
    updateChips();
  }

  function updateChips() {
    document.querySelectorAll('[data-chip-for]').forEach((chip) => {
      const select = $(chip.dataset.chipFor);
      const map = select && select.id === 'handleFinish' ? state.finishColors : state.colors;
      const color = select ? map[select.value] : null;
      if (color) {
        chip.style.background = color;
        chip.dataset.color = color;
      } else {
        chip.style.background = '';
        delete chip.dataset.color;
      }
    });
  }

  async function refreshMaterials() {
    if (!state.meta || Date.now() - state.lastMaterialRefresh < 1500) return;
    state.lastMaterialRefresh = Date.now();
    try {
      const res = await call('get_materials');
      if (res.ok) loadMaterials(res.data.materials);
    } catch (_) { /* the panel keeps working with the list it has */ }
  }

  /* ---------------------------------------------------------------------- *
   * Form <-> parameters
   * ---------------------------------------------------------------------- */

  function collect() {
    const withHandle = !!$('handle').value;
    const handleValue = (id) => (withHandle ? $(id).value : '');
    return {
      catalog_id: $('catalog').value,
      handle_id: $('handle').value,
      base_material: $('baseMaterial').value,
      wall_material: $('wallMaterial').value,
      tall_material: $('tallMaterial').value,
      corner_material: $('cornerMaterial').value,
      material_thickness: $('thickness').value,
      back_thickness: $('backThickness').value,
      door_gap: $('doorGap').value,
      door_opening_direction: $('direction').value,
      door_opening_angle: $('angle').value,
      show_opening_direction: $('showDirection').checked,
      show_door_symbol: $('showDoorSymbol').checked,
      door_reveal: $('doorReveal').value,
      cabinet_category: $('category').value,
      cabinet_type: $('cabinet').value,
      placement_gap: $('gap').value,
      width: $('width').value,
      depth: $('depth').value,
      height: $('height').value,
      shelf_count: $('shelves').value,
      carcass_material: $('carcassMaterial').value,
      toe_kick_height: $('toeHeight').value,
      handle_length: handleValue('handleLength'),
      handle_finish: handleValue('handleFinish'),
      handle_material: handleValue('handleMaterial'),
      handle_orientation: handleValue('handleOrientation'),
      handle_position: handleValue('handlePosition'),
      handle_side_offset: handleValue('handleSide'),
      handle_vertical_offset: handleValue('handleVert'),
      handle_custom_x: handleValue('handleCustomX'),
      handle_custom_z: handleValue('handleCustomZ'),
      visibility_settings: {
        carcass: $('visCarcass').checked,
        door: $('visDoor').checked,
        toe_kick: $('visToe').checked
      }
    };
  }

  function applyParams(stored) {
    const p = stored.toe_kick_material === '__cabinet__' ? Object.assign({}, stored, { toe_kick_material: '__door__' }) : stored;
    if ('handle_id' in p) {
      setSelect('handle', p.handle_id || '');
      onHandleChange(false);
    }
    Object.entries(TEXT_PARAMS).forEach(([key, id]) => {
      if (key in p) setText(id, p[key]);
    });
    Object.entries(SELECT_PARAMS).forEach(([key, id]) => {
      if (key in p) setSelect(id, p[key]);
    });
    if ('show_opening_direction' in p) $('showDirection').checked = !!p.show_opening_direction;
    if ('show_door_symbol' in p) $('showDoorSymbol').checked = !!p.show_door_symbol;
    if (p.visibility_settings && typeof p.visibility_settings === 'object') {
      const v = p.visibility_settings;
      if ('carcass' in v) $('visCarcass').checked = !!v.carcass;
      if ('door' in v) $('visDoor').checked = !!v.door;
      if ('toe_kick' in v) $('visToe').checked = !!v.toe_kick;
    }
    syncHandlePosition();
    syncWidthPreset();
    updateChips();
    drawPreview();
  }

  /* ---------------------------------------------------------------------- *
   * Handle bundle options
   * ---------------------------------------------------------------------- */

  function currentBundle() {
    const id = $('handle').value;
    return (state.meta && list(state.meta.handle_bundles).find((b) => b.id === id)) || null;
  }

  // Fills Length / Finish from the chosen bundle. `useDefaults` also resets
  // orientation, position and offsets to the bundle's own defaults.
  function onHandleChange(useDefaults) {
    const bundle = currentBundle();
    $('handleOptions').hidden = !bundle;
    if (!bundle) {
      drawPreview();
      return;
    }

    const finishes = list(bundle.finishes);
    fillSelect($('handleLength'), list(bundle.lengths).map((l) => ({ id: String(l), name: `${l} mm` })));
    fillSelect($('handleFinish'), finishes);
    state.finishColors = {};
    finishes.forEach((f) => { if (f.color) state.finishColors[f.id] = f.color; });

    if (useDefaults) {
      const d = bundle.defaults || {};
      setSelect('handleLength', bundle.default_length);
      if (finishes[0]) $('handleFinish').value = finishes[0].id;
      setSelect('handleOrientation', d.orientation);
      setSelect('handlePosition', d.position);
      setText('handleSide', d.side_offset);
      setText('handleVert', d.vertical_offset);
      setText('handleCustomX', d.custom_x);
      setText('handleCustomZ', d.custom_z);
    }
    $('handleOrientation').disabled = bundle.profile === 'knob'; // a round knob has no orientation
    syncHandlePosition();
    updateChips();
    drawPreview();
  }

  // Custom shows exact coordinates; otherwise the offsets apply. Only Top and
  // Bottom use the top/bottom offset.
  function syncHandlePosition() {
    const position = $('handlePosition').value;
    $('handleCustom').hidden = position !== 'custom';
    $('handleOffsets').hidden = position === 'custom';
    $('handleVertField').hidden = !['top', 'bottom'].includes(position);
  }

  /* ---------------------------------------------------------------------- *
   * Catalog / category / cabinet
   * ---------------------------------------------------------------------- */

  async function refreshCabinets({ selectId = null, keepValues = false } = {}) {
    if (categoryKind() !== 'cabinet') return; // a filler or end panel has no catalog cabinets
    const catalogId = $('catalog').value;
    const category = $('category').value;
    state.cabinets = [];

    if (catalogId) {
      try {
        const res = await call('get_cabinets', { catalog_id: catalogId, cabinet_category: category });
        state.cabinets = (res.ok && res.data.cabinets) || [];
      } catch (error) {
        setStatus('error', error.message);
      }
    }

    fillSelect($('cabinet'), state.cabinets, {
      placeholder: state.cabinets.length ? null : 'No cabinets in this category'
    });
    $('cabinet').value = selectId && state.cabinets.some((c) => c.id === selectId)
      ? selectId
      : (state.cabinets[0] ? state.cabinets[0].id : '');

    if (!keepValues) applyCabinetDefaults();
    drawPreview();
  }

  // The Standard Width list: a fixed size fills the Width field; Width can still be
  // typed freely, and the list follows it (Custom when it is not a listed size).
  function fillWidthPreset() {
    const sizes = list(state.meta && state.meta.standard_widths);
    fillSelect($('widthPreset'), [{ id: 'custom', name: 'Custom' }, ...sizes.map((w) => ({ id: String(w), name: `${w} mm` }))]);
    syncWidthPreset();
  }

  function syncWidthPreset() {
    const value = String(num($('width').value));
    const listed = [...$('widthPreset').options].some((o) => o.value === value);
    $('widthPreset').value = listed ? value : 'custom';
  }

  function applyCabinetDefaults() {
    const cabinet = currentCabinet();
    if (!cabinet) return;
    const d = cabinet.defaults || {};
    setText('width', d.width);
    syncWidthPreset();
    setText('depth', d.depth);
    setText('height', d.height);
    setText('shelves', cabinet.shelves === undefined ? 0 : cabinet.shelves);
  }

  // The Cabinet Category decides which fields the panel shows: the cabinet form
  // for every real category, or the Filler / End Panel fields when one of those is
  // chosen. (The Toe Kick and Visibility sections are always there.) A wall unit
  // hangs at height 0, so the toe-kick height does not raise it.
  function updateCategoryUi() {
    const kind = categoryKind();
    document.querySelectorAll('.cabinet-only').forEach((el) => { el.hidden = kind !== 'cabinet'; });
    document.querySelectorAll('.cabinet-only-btn').forEach((el) => { el.hidden = kind !== 'cabinet'; });
    $('sub-filler').hidden = kind !== 'filler';
    $('sub-end-panel').hidden = kind !== 'end_panel';
    document.querySelector('.preview').hidden = kind !== 'cabinet';
    $('toeNote').hidden = $('category').value !== 'wall';
  }

  async function loadCabinet(params) {
    setBadge(params.cabinet_name || params.cabinet_id || null);
    followCabinet({ height: params.height, material: params.material });
    setSelect('catalog', params.catalog_id);
    setSelect('category', params.cabinet_category);
    updateCategoryUi();
    await refreshCabinets({ selectId: params.cabinet_type, keepValues: true });
    applyParams(params);
  }

  function setBadge(name) {
    const badge = $('selectionBadge');
    badge.textContent = name || 'Nothing selected';
    badge.classList.toggle('active', !!name);
  }

  /* ---------------------------------------------------------------------- *
   * Live front-view preview
   * ---------------------------------------------------------------------- */

  function drawPreview() {
    const svg = $('preview');
    const caption = $('previewCaption');
    const VBW = 240;
    const VBH = 176;

    const W = num($('width').value);
    const H = num($('height').value);
    const D = num($('depth').value);
    if (!(W > 0 && H > 0)) {
      svg.innerHTML = '';
      caption.textContent = 'Enter width and height to see the front view.';
      return;
    }

    const isWall = $('category').value === 'wall';
    let toe = isWall ? 0 : num($('toeHeight').value);
    if (!Number.isFinite(toe) || toe < 0) toe = 0;

    const cabinet = currentCabinet();
    const doors = cabinet ? (cabinet.doors | 0) : 0;
    const shelves = Math.min(20, Math.max(0, parseInt($('shelves').value, 10) || 0));
    const hingeOnLeft = $('direction').value !== 'right';
    const showSwing = $('showDoorSymbol').checked;

    const padX = 26;
    const top = 12;
    const bottom = 24;
    const s = Math.min((VBW - 2 * padX) / W, (VBH - top - bottom) / (H + toe));
    const bw = W * s;
    const bh = H * s;
    const th = toe * s;
    const x0 = (VBW - bw) / 2;
    const floorY = VBH - bottom;
    const bodyBottom = floorY - th;
    const bodyTop = bodyBottom - bh;

    const out = [];
    out.push(`<line class="pv-floor" x1="${x0 - 14}" y1="${floorY}" x2="${x0 + bw + 14}" y2="${floorY}"/>`);

    if (th > 0) {
      const inset = Math.min(8, bw * 0.05);
      const toeW = bw - 2 * inset;
      out.push(`<rect class="pv-toe" x="${x0 + inset}" y="${bodyBottom}" width="${toeW}" height="${th}"/>`);
    }
    out.push(`<rect class="pv-body" x="${x0}" y="${bodyTop}" width="${bw}" height="${bh}"/>`);

    for (let i = 1; i <= shelves; i += 1) {
      const y = bodyTop + (bh * i) / (shelves + 1);
      out.push(`<line class="pv-shelf" x1="${x0}" y1="${y}" x2="${x0 + bw}" y2="${y}"/>`);
    }

    if (doors > 0) {
      // Schematic, not to scale: fixed insets keep the door outline readable.
      const reveal = 3.5;
      const gap = 3;
      const doorW = (bw - 2 * reveal - (doors - 1) * gap) / doors;
      const doorTop = bodyTop + reveal;
      const doorH = bh - 2 * reveal;

      for (let i = 0; i < doors; i += 1) {
        const dx = x0 + reveal + i * (doorW + gap);
        // One door: hinge on the chosen side. Several doors: hinges on the outer sides.
        const left = doors === 1 ? hingeOnLeft : i < doors / 2;
        const hingeX = left ? dx : dx + doorW;
        const freeX = left ? dx + doorW : dx;
        const midY = doorTop + doorH / 2;

        out.push(`<rect class="pv-door" x="${dx}" y="${doorTop}" width="${doorW}" height="${doorH}"/>`);
        if (showSwing) {
          out.push(`<polyline class="pv-swing" points="${freeX},${doorTop} ${hingeX},${midY} ${freeX},${doorTop + doorH}"/>`);
        }
        out.push(`<circle class="pv-hinge" cx="${hingeX}" cy="${doorTop + doorH * 0.14}" r="1.5"/>`);
        out.push(`<circle class="pv-hinge" cx="${hingeX}" cy="${doorTop + doorH * 0.86}" r="1.5"/>`);
      }
    }

    out.push(`<text class="pv-dim" x="${VBW / 2}" y="${floorY + 14}" text-anchor="middle">${fmt(W)}</text>`);
    out.push(`<text class="pv-dim" transform="translate(${x0 + bw + 11} ${(bodyTop + bodyBottom) / 2}) rotate(-90)" text-anchor="middle">${fmt(H)}</text>`);
    svg.innerHTML = out.join('');

    const depthText = Number.isFinite(D) ? `, D ${fmt(D)}` : '';
    caption.textContent = `W ${fmt(W)}${depthText}, H ${fmt(H)} mm. Base Z ${fmt(toe)} mm, top Z ${fmt(toe + H)} mm.`;
  }

  /* ---------------------------------------------------------------------- *
   * Status + validation display
   * ---------------------------------------------------------------------- */

  function setStatus(kind, message, details = []) {
    const box = $('status');
    box.className = `status ${kind}`;
    box.textContent = '';
    box.hidden = !message;
    if (!message) return;

    box.append(document.createTextNode(message));
    if (details.length) {
      const list = document.createElement('ul');
      details.forEach((text) => {
        const item = document.createElement('li');
        item.textContent = text;
        list.append(item);
      });
      box.append(list);
    }
  }

  function clearInvalid() {
    document.querySelectorAll('.field.invalid').forEach((f) => f.classList.remove('invalid'));
  }

  // `focus: false` (a live update) only marks the fields: it must not scroll the
  // panel or take the cursor away from what the user is typing.
  function markInvalid(errors, kind, { focus = true } = {}) {
    const map = kind === 'filler' ? FILLER_FIELD_TO_ELEMENT
      : kind === 'end_panel' ? END_PANEL_FIELD_TO_ELEMENT : FIELD_TO_ELEMENT;
    let first = null;
    (errors || []).forEach((error) => {
      const id = map[error.field];
      const el = id ? $(id) : null;
      if (!el) return;
      const field = el.closest('.field');
      if (field) field.classList.add('invalid');
      const card = el.closest('.card');
      if (focus && card && card.classList.contains('collapsed')) toggleCard(card, true);
      if (!first) first = el;
    });
    if (focus && first && !first.disabled) {
      first.scrollIntoView({ block: 'center', behavior: 'smooth' });
      first.focus({ preventScroll: true });
    }
  }

  function toggleCard(card, open) {
    const collapsed = open === undefined ? !card.classList.contains('collapsed') : !open;
    card.classList.toggle('collapsed', collapsed);
    card.querySelector('.card-head').setAttribute('aria-expanded', String(!collapsed));
  }

  /* ---------------------------------------------------------------------- *
   * Actions
   * ---------------------------------------------------------------------- */

  function setBusy(busy) {
    state.busy = busy;
    document.querySelectorAll('[data-action]').forEach((b) => { b.disabled = busy; });
  }

  // `live` is an Update the panel sends by itself while the user edits a field.
  // It leaves the buttons alone and never steals the cursor.
  async function runAction(action, { live = false } = {}) {
    if (state.busy) return;
    clearInvalid();
    if (live) {
      state.busy = true;
      state.liveBusy = true;
    } else {
      setBusy(true);
    }
    try {
      const kind = formKind(action);
      const payload = kind ? COLLECTORS[kind]() : {};
      const res = await call(serverAction(action), payload);
      if (res.ok) {
        setStatus('ok', res.message);
        if (action === 'insert' && (kind === 'filler' || kind === 'end_panel')) resetFollowing();
      } else {
        markInvalid(res.errors, kind, { focus: !live });
        setStatus('error', res.message, (res.errors || []).length > 1 ? res.errors.map((e) => e.message) : []);
      }
    } catch (error) {
      setStatus('error', error.message);
    } finally {
      if (live) {
        state.busy = false;
        state.liveBusy = false;
      } else {
        setBusy(false);
      }
    }
  }

  /* ---------------------------------------------------------------------- *
   * Live update: editing a field changes the selected item straight away
   * ---------------------------------------------------------------------- */

  const LIVE_TYPING_DELAY_MS = 450; // wait for a pause while typing a number
  const LIVE_PICK_DELAY_MS = 60; // a list or tick box is a finished choice
  // These have their own live behaviour (Visibility ticks) or need the cabinet
  // list reloaded first (catalog / category / cabinet, see wireEvents).
  const NO_LIVE_IDS = new Set(['visCarcass', 'visDoor', 'visToe', 'showDirection', 'showDoorSymbol', 'catalog', 'category', 'cabinet']);

  // Which kind of item a field edits, so a change to the Filler fields never
  // rewrites the cabinet that happens to be selected. The toe-kick height is both:
  // it raises cabinets and is the height of a toe kick.
  function fieldKinds(el) {
    if (el.closest('#sub-filler')) return ['filler'];
    if (el.closest('#sub-end-panel')) return ['end_panel'];
    if (el.id === 'toeHeight') return ['cabinet', 'toe_kick'];
    if (el.closest('#sec-toe')) return ['toe_kick'];
    return ['cabinet'];
  }

  function scheduleLive(delay = LIVE_TYPING_DELAY_MS) {
    clearTimeout(state.liveTimer);
    state.liveTimer = setTimeout(runLive, delay);
  }

  async function runLive() {
    if (!state.selectedKind) return;
    if (state.busy) {
      scheduleLive(); // something else is still running; try again shortly
      return;
    }
    await runAction('update', { live: true });
  }

  // A field was edited: update the selected item if this field belongs to it.
  function liveEdit(el) {
    if (NO_LIVE_IDS.has(el.id) || !state.selectedKind) return;
    if (!fieldKinds(el).includes(state.selectedKind)) return;
    scheduleLive(el.tagName === 'SELECT' || el.type === 'checkbox' ? LIVE_PICK_DELAY_MS : LIVE_TYPING_DELAY_MS);
  }

  // Carcass / Door / Toe Kick tick boxes act immediately on every cabinet in the model.
  async function applyVisibility() {
    try {
      const res = await call('visibility', {
        carcass: $('visCarcass').checked,
        door: $('visDoor').checked,
        toe_kick: $('visToe').checked,
        opening_direction: $('showDirection').checked, // the plan symbol on the floor
        door_symbol: $('showDoorSymbol').checked // the dashed lines on each door
      });
      setStatus(res.ok ? 'ok' : 'error', res.message);
    } catch (error) {
      setStatus('error', error.message);
    }
  }

  /* ---------------------------------------------------------------------- *
   * Start-up
   * ---------------------------------------------------------------------- */

  function applyDefaults(d) {
    Object.entries(TEXT_PARAMS).forEach(([key, id]) => {
      if (['width', 'depth', 'height', 'shelf_count'].includes(key)) return; // come from the cabinet
      if (key in d) setText(id, d[key]);
    });
    Object.entries(SELECT_PARAMS).forEach(([key, id]) => {
      if (key in d) setSelect(id, d[key]);
    });
    setSelect('category', d.cabinet_category);
    $('showDirection').checked = d.show_opening_direction !== false;
    $('showDoorSymbol').checked = d.show_door_symbol !== false;
    const v = d.visibility_settings || {};
    $('visCarcass').checked = v.carcass !== false;
    $('visDoor').checked = v.door !== false;
    $('visToe').checked = v.toe_kick !== false;
    updateChips();
  }

  // Fills in anything an older Ruby side does not send, so the panel never fails on a missing list.
  function normaliseMeta(raw) {
    const m = Object.assign({}, raw);
    Object.keys(FALLBACK_LISTS).forEach((key) => {
      if (!list(m[key]).length) m[key] = FALLBACK_LISTS[key];
    });
    ['catalogs', 'categories', 'directions', 'warnings'].forEach((key) => { m[key] = list(m[key]); });
    if (!list(m.standard_widths).length) m.standard_widths = [300, 350, 400, 450, 500, 600, 700, 800, 900, 1000, 1200];
    m.handle_bundles = list(m.handle_bundles).map((b) => Object.assign({ lengths: [], finishes: [], defaults: {}, profile: 'bar' }, b));
    m.materials = { panel: list(m.materials && m.materials.panel), toe_kick: list(m.materials && m.materials.toe_kick) };
    m.defaults = m.defaults || {};
    m.filler_defaults = m.filler_defaults || { width: 100, thickness: 18, height: 780, material: 'White' };
    m.end_panel_defaults = m.end_panel_defaults || { side: 'left', thickness: 18, material: 'White' };
    m.toe_kick_defaults = m.toe_kick_defaults || { toe_kick_height: 100, toe_kick_thickness: 18, toe_kick_material: '__door__', toe_kick_piece_length: 600, toe_kick_pieces: 1, toe_kick_recess: 50 };
    return m;
  }

  async function buildUi() {
    const m = state.meta;
    fillSelect($('catalog'), m.catalogs, { placeholder: m.catalogs.length ? null : 'No catalogs found' });
    fillSelect($('handle'), m.handle_bundles, { placeholder: 'None' });
    // Fillers and end panels are choices in the same list as the cabinet categories.
    fillSelect($('category'), [...m.categories, { id: 'filler', name: 'Filler' }, { id: 'end_panel', name: 'End Panel' }]);
    fillSelect($('direction'), m.directions);
    fillWidthPreset();
    fillSelect($('handleOrientation'), m.handle_orientations);
    fillSelect($('handlePosition'), m.handle_positions);
    fillSelect($('epSide'), m.end_panel_sides);
    loadMaterials(m.materials);
    applyDefaults(m.defaults);
    applyFillerDefaults(m.filler_defaults);
    applyEndPanelDefaults(m.end_panel_defaults);
    applyToeKickDefaults(m.toe_kick_defaults);
    updateCategoryUi();
    await refreshCabinets();

    if (m.version !== APP_VERSION) {
      setStatus('error', `SketchUp is still running an older version of the Ruby code (${m.version || 'unknown'}; this panel is ${APP_VERSION}). Close SketchUp completely and reopen it to finish the update.`);
    } else if (m.warnings.length) {
      setStatus('error', 'Some catalog files could not be loaded.', m.warnings);
    }
  }

  function wireEvents() {
    document.querySelectorAll('.card-head').forEach((button) => {
      button.addEventListener('click', () => toggleCard(button.closest('.card')));
    });

    // Catalog / category / cabinet reload the cabinet list (and the sizes that
    // come with a cabinet) first, and only then update the selected cabinet.
    const liveAfterCabinetChange = () => {
      if (state.selectedKind === 'cabinet' && categoryKind() === 'cabinet') scheduleLive(LIVE_PICK_DELAY_MS);
    };
    $('catalog').addEventListener('change', async () => {
      await refreshCabinets();
      liveAfterCabinetChange();
    });
    $('category').addEventListener('change', async () => {
      updateCategoryUi();
      await refreshCabinets();
      liveAfterCabinetChange();
    });
    $('cabinet').addEventListener('change', () => {
      applyCabinetDefaults();
      drawPreview();
      liveAfterCabinetChange();
    });
    $('widthPreset').addEventListener('change', () => {
      if ($('widthPreset').value !== 'custom') setText('width', Number($('widthPreset').value));
      drawPreview();
    });
    $('width').addEventListener('input', syncWidthPreset);
    $('handle').addEventListener('change', () => onHandleChange(true));
    $('handlePosition').addEventListener('change', syncHandlePosition);

    document.querySelectorAll('input, select').forEach((el) => {
      const onEdit = () => {
        const field = el.closest('.field');
        if (field) field.classList.remove('invalid');
        if (el.matches('[data-material]')) updateChips();
        drawPreview();
        liveEdit(el); // update the selected item with what was just entered
        if (FOLLOWS_CABINET.includes(el.id)) state.touched.add(el.id); // the user's own value now
      };
      el.addEventListener('input', onEdit);
      el.addEventListener('change', onEdit);
    });

    document.querySelectorAll('[data-action]').forEach((button) => {
      button.addEventListener('click', () => runAction(button.dataset.action));
    });

    ['visCarcass', 'visDoor', 'visToe', 'showDirection', 'showDoorSymbol'].forEach((id) => $(id).addEventListener('change', applyVisibility));

    window.addEventListener('focus', refreshMaterials);
  }

  async function init() {
    wireEvents();
    // Every section starts closed; the user opens the ones they need.
    document.querySelectorAll('.card').forEach((card) => {
      if (card.querySelector('.card-head')) toggleCard(card, false);
    });
    try {
      const res = await call('init');
      if (!res.ok) throw new Error(res.message || 'The panel could not start.');
      state.meta = normaliseMeta(res.data);
      await buildUi();
    } catch (error) {
      setStatus('error', error.message);
    }
  }

  // Any error the panel itself throws is shown, with where it happened, instead of failing silently.
  function reportError(message, where) {
    const text = `Panel error: ${message}${where ? ` (${where})` : ''}`;
    if (window.console) console.error(text);
    setStatus('error', text);
  }
  window.addEventListener('error', (event) => {
    const file = String(event.filename || '').split('/').pop();
    reportError(event.message, file ? `${file}:${event.lineno}` : '');
  });
  window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason;
    reportError(reason && reason.message ? reason.message : String(reason), (reason && reason.stack || '').split('\n')[1]?.trim());
  });

  window.addEventListener('load', init);
})();
