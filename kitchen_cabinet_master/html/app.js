(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);

  // Must match EXTENSION_VERSION in kitchen_cabinet_master.rb. If SketchUp is still
  // running older Ruby files than this panel (an update without a restart), the
  // panel says so instead of failing on data the old Ruby never sends.
  const APP_VERSION = '0.25.0';

  const list = (value) => (Array.isArray(value) ? value : []);

  const FALLBACK_LISTS = {
    handle_orientations: [{ id: 'vertical', name: 'Vertical' }, { id: 'horizontal', name: 'Horizontal' }],
    handle_positions: ['top', 'center', 'bottom', 'left', 'right', 'custom']
      .map((id) => ({ id, name: id.charAt(0).toUpperCase() + id.slice(1) })),
    end_panel_sides: [{ id: 'left', name: 'Left' }, { id: 'right', name: 'Right' }]
  };

  const FILLER_FIELD_TO_ELEMENT = {
    width: 'fillerWidth', thickness: 'fillerThickness', height: 'fillerHeight'
  };
  const END_PANEL_FIELD_TO_ELEMENT = { side: 'epSide', depth: 'epDepth', thickness: 'epThickness', height: 'epHeight', material: 'epMaterial' };

  // Server field name -> id of the element that edits it (used to highlight errors).
  const FIELD_TO_ELEMENT = {
    catalog_id: 'catalog',
    handle_id: 'handle',
    handle_material: 'handleMaterial',
    base_material: 'baseMaterial',
    wall_material: 'wallMaterial',
    tall_material: 'tallMaterial',
    material_thickness: 'thickness',
    back_thickness: 'backThickness',
    door_gap: 'doorGap',
    door_distance: 'doorDistance',
    top_panel_style: 'topPanel',
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
    door_distance: 'doorDistance',
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
    carcass_material: 'carcassMaterial',
    top_panel_style: 'topPanel',
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
    touched: new Set(),
    unit: 'mm',
    animate: false // section animations start once the panel is built
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
      // A part is edited with the Cabinet & Extras fields, which need a catalog: use the first if none is chosen.
      if (!$('catalog').value && list(state.meta.catalogs)[0]) {
        setSelect('catalog', list(state.meta.catalogs)[0].id);
        applyCatalogFeatures();
      }
      setBadge(data.part_name);
      if (kind === 'end_panel') applyEndPanelDefaults(data);
      else if (kind === 'toe_kick') applyToeKickDefaults(data);
      else applyFillerDefaults(data);
      // A filler is something an end panel can go on: its front and top are what that panel starts from.
      if (kind === 'filler') followCabinet({ front: data.envelope_depth, top: data.target_category === 'wall' ? data.envelope_top - data.target_base_z : data.envelope_top });
      // Filler, End Panel and Toe Kick are Cabinet Category choices: show the matching fields.
      setSelect('category', kind);
      updateCategoryUi();
    } else if (name === 'cabinet_cleared') {
      state.selectedKind = null;
      setBadge(null);
    } else if (name === 'snap') {
      // A moved cabinet was snapped to a neighbour and / or the wall (or could not be).
      setStatus('ok', data.message);
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
    drawPreview();
  }

  function collectToeKick() {
    return {
      toe_kick_height: mmv('toeHeight'),
      toe_kick_thickness: mmv('toeThickness'),
      toe_kick_material: $('toeMaterial').value,
      toe_kick_piece_length: mmv('pieceLength'),
      toe_kick_pieces: $('pieceCount').value,
      toe_kick_recess: mmv('toeRecess'),
      // Used only when nothing is selected: the carcass depth the toe kick sits under.
      depth: mmv('depth'),
      // A new toe kick follows the Toe Kick tick in the Visibility section.
      visible: $('visToe').checked
    };
  }

  function applyFillerDefaults(d) {
    setText('fillerWidth', d.width);
    setText('fillerThickness', d.thickness);
    setText('fillerHeight', d.height);
    updateChips();
    drawPreview();
  }

  // A filler's height STARTS as the height of the cabinet in the model and follows
  // it as cabinets are selected, until the user types their own. Then it stays
  // put, so "enter the data, select the cabinet, Insert" keeps what was entered.
  // (A filler's material is not a field: it always follows the door material.)
  //
  // An end panel's depth and height start the same way: depth flush with the door
  // front (`front`) and height up to the top (`top`) of what is selected.
  const FOLLOWS_CABINET = ['fillerHeight', 'epDepth', 'epHeight'];

  function followCabinet(cabinet) {
    const set = (id, value) => { if (value && !state.touched.has(id)) setText(id, value); };
    set('fillerHeight', cabinet.height);
    set('epDepth', cabinet.front);
    set('epHeight', cabinet.top);
    drawPreview();
  }

  // After a filler is inserted, the next one starts from the cabinet again.
  function resetFollowing() {
    FOLLOWS_CABINET.forEach((id) => state.touched.delete(id));
  }

  function applyEndPanelDefaults(d) {
    setSelect('epSide', d.side);
    setText('epDepth', d.depth);
    setText('epThickness', d.thickness);
    setText('epHeight', d.height);
    setSelect('epMaterial', d.material_choice || d.material || '__door__');
    updateChips();
    drawPreview();
  }

  function collectFiller() {
    return {
      width: mmv('fillerWidth'),
      thickness: mmv('fillerThickness'),
      height: mmv('fillerHeight'),
      // Untouched, the height is the selected unit's own (a tall, base or wall filler).
      height_auto: !state.touched.has('fillerHeight')
    };
  }

  function collectEndPanel() {
    return {
      side: $('epSide').value,
      depth: mmv('epDepth'),
      depth_auto: !state.touched.has('epDepth'),
      thickness: mmv('epThickness'),
      height: mmv('epHeight'),
      height_auto: !state.touched.has('epHeight'),
      material: $('epMaterial').value
    };
  }

  // Which form an action reads. Each Insert button belongs to its own block;
  // Update follows whatever is selected in the model.
  const COLLECTORS = {
    rotate: () => ({ degrees: $('rotateDegrees').value }),
    cabinet: () => collect(),
    filler: () => collectFiller(),
    end_panel: () => collectEndPanel(),
    toe_kick: () => collectToeKick()
  };

  // Filler, End Panel and Toe Kick are choices in the Cabinet Category list, next
  // to the real cabinet categories.
  const PART_CATEGORIES = ['filler', 'end_panel', 'toe_kick'];

  function categoryKind() {
    const value = $('category').value;
    return PART_CATEGORIES.includes(value) ? value : 'cabinet';
  }

  // The main Insert button inserts whatever the Cabinet Category says; Update
  // follows whatever is selected in the model.
  function formKind(action) {
    if (action === 'insert') return categoryKind();
    if (action === 'update') return state.selectedKind || categoryKind();
    if (action === 'rotate') return 'rotate';
    return null;
  }

  // Cabinets have their own Insert / Update / Delete; a filler, end panel or toe
  // kick has its own Insert and shares one Update / Delete (update_part / delete_part).
  const INSERT_ACTION = { cabinet: 'insert', filler: 'insert_filler', end_panel: 'insert_end_panel', toe_kick: 'insert_toe_kick' };

  function serverAction(action) {
    const isPart = state.selectedKind && state.selectedKind !== 'cabinet';
    if (isPart && action === 'update') return 'update_part';
    if (isPart && action === 'delete') return 'delete_part';
    if (action === 'insert') return INSERT_ACTION[categoryKind()];
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

  /* ---------------------------------------------------------------------- *
   * Units: the panel shows lengths in the chosen unit; SketchUp always gets mm
   * ---------------------------------------------------------------------- */

  const UNITS = {
    mm: { name: 'Millimetres (mm)', label: 'mm', mm: 1, decimals: 1 },
    cm: { name: 'Centimetres (cm)', label: 'cm', mm: 10, decimals: 2 },
    m: { name: 'Metres (m)', label: 'm', mm: 1000, decimals: 4 },
    in: { name: 'Inches (in)', label: 'in', mm: 25.4, decimals: 3 },
    ft: { name: 'Feet (ft)', label: 'ft', mm: 304.8, decimals: 4 }
  };

  // The inputs that hold a length. Each one's text is in the chosen unit.
  const LENGTH_IDS = [
    'doorGap', 'doorReveal', 'doorDistance', 'thickness', 'backThickness',
    'width', 'depth', 'height', 'gap', 'toeHeight', 'handleSide', 'handleVert', 'handleCustomX', 'handleCustomZ',
    'fillerWidth', 'fillerThickness', 'fillerHeight', 'epDepth', 'epThickness', 'epHeight',
    'toeThickness', 'toeRecess', 'pieceLength'
  ];

  function unitInfo() { return UNITS[state.unit] || UNITS.mm; }

  // mm -> text in the chosen unit (no unit label), trimmed of trailing zeros.
  function fmtU(mm) {
    if (!Number.isFinite(mm)) return '';
    const { decimals, mm: factor } = unitInfo();
    const scaled = mm / factor;
    const rounded = Math.round(scaled * 10 ** decimals) / 10 ** decimals;
    return String(rounded);
  }

  function fmtLen(mm) { return `${fmtU(mm)} ${unitInfo().label}`; }

  // The length typed in a field, in mm, as text. A field nobody has edited since it
  // was filled gives back the exact mm it was filled with, so converting to inches
  // and back never drifts the size of a cabinet.
  function mmv(id) {
    const el = $(id);
    const text = el.value.trim();
    if (!text) return '';
    if (el.dataset.mm !== undefined && el.dataset.shown === el.value) return el.dataset.mm;
    const n = num(text);
    return Number.isFinite(n) ? String(Math.round(n * unitInfo().mm * 1e6) / 1e6) : text;
  }

  function showLength(id, mm) {
    const el = $(id);
    el.value = fmtU(mm);
    el.dataset.mm = String(mm);
    el.dataset.shown = el.value;
  }

  function refreshUnitLabels() {
    LENGTH_IDS.forEach((id) => {
      const el = $(id);
      const label = el && el.parentElement && el.parentElement.querySelector('em');
      if (label) label.textContent = unitInfo().label;
    });
  }

  // Switching unit re-writes every length in the new unit (same sizes, other numbers).
  function setUnit(unit) {
    if (!UNITS[unit] || unit === state.unit) return;
    const values = LENGTH_IDS.map((id) => [id, mmv(id)]);
    state.unit = unit;
    values.forEach(([id, mm]) => {
      const n = num(mm);
      if (mm !== '' && Number.isFinite(n)) showLength(id, n);
    });
    refreshUnitLabels();
    fillWidthPreset();
    fillThicknessPresets();
    [...$('handleLength').options].forEach((o) => { if (o.value) o.textContent = fmtLen(Number(o.value)); });
    $('units').value = unit;
    try { localStorage.setItem('kcm.unit', unit); } catch (_) { /* a private window: not remembered */ }
    drawPreview();
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
    if (LENGTH_IDS.includes(id) && typeof value === 'number') {
      showLength(id, value);
      return;
    }
    $(id).value = typeof value === 'number' ? fmt(value) : String(value);
  }

  /* ---------------------------------------------------------------------- *
   * Catalog features: what the selected catalog switches on
   * ---------------------------------------------------------------------- */

  const ALL_FEATURES = [
    'base', 'wall', 'tall', 'corner', 'filler', 'end_panel', 'toe_kick',
    'door_gap', 'door_reveal', 'door_distance', 'top_panel', 'panel_thickness', 'back_thickness',
    'cabinet_extras', 'handle', 'materials', 'door_opening', 'visibility', 'rotate'
  ];

  function currentCatalog() {
    return list(state.meta && state.meta.catalogs).find((c) => c.id === $('catalog').value) || null;
  }

  // A catalog's old id (see "aliases" in its file) means the same catalog.
  function resolveCatalogId(id) {
    const found = list(state.meta && state.meta.catalogs).find((c) => c.id === id || list(c.aliases).includes(id));
    return found ? found.id : id;
  }

  // Only what the selected catalog offers is active: its categories and options,
  // its handle bundles. Everything else stays visible but greyed out and locked.
  function applyCatalogFeatures() {
    const catalog = currentCatalog();
    // No catalog chosen yet: nothing is active except the catalog selection itself.
    const on = new Set(!catalog ? [] : (Array.isArray(catalog.features) ? catalog.features : ALL_FEATURES));

    const categories = [...list(state.meta.categories), { id: 'filler', name: 'Filler' }, { id: 'end_panel', name: 'End Panel' }, { id: 'toe_kick', name: 'Toe Kick' }];
    fillSelect($('category'), categories.filter((c) => on.has(c.id)));

    document.querySelectorAll('[data-feature]').forEach((el) => {
      const off = !on.has(el.dataset.feature);
      el.classList.toggle('feature-off', off);
      el.querySelectorAll('input, select, button:not(.card-head)').forEach((control) => {
        if (off && !control.disabled) {
          control.disabled = true;
          control.dataset.featureLocked = '1';
        } else if (!off && control.dataset.featureLocked) {
          control.disabled = false;
          delete control.dataset.featureLocked;
        }
      });
      if (off && el.classList.contains('card')) toggleCard(el, false);
    });

    const allowed = catalog && Array.isArray(catalog.handle_bundles) ? catalog.handle_bundles : null;
    const before = $('handle').value;
    fillSelect($('handle'), list(state.meta.handle_bundles).filter((b) => !allowed || allowed.includes(b.id)), { placeholder: 'None' });
    if ($('handle').value !== before) onHandleChange(true);
    lockActions();
  }

  // Insert needs a catalog: it builds a cabinet from the selected catalog's style.
  function lockActions() {
    const insert = document.querySelector('[data-action="insert"]');
    if (insert) insert.disabled = state.busy || !currentCatalog();
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
    ['baseMaterial', 'wallMaterial', 'tallMaterial'].forEach((id) => fillSelect($(id), panel));
    fillSelect($('carcassMaterial'), panel, { placeholder: 'Same as door material' });
    fillSelect($('handleMaterial'), panel, { placeholder: "Use the finish's material" });
    fillSelect($('toeMaterial'), toeKick);
    fillSelect($('epMaterial'), [{ id: '__door__', name: 'Same as door material' }, ...panel]);
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
      material_thickness: mmv('thickness'),
      back_thickness: mmv('backThickness'),
      door_gap: mmv('doorGap'),
      door_distance: mmv('doorDistance'),
      top_panel_style: $('topPanel').value,
      door_opening_direction: $('direction').value,
      door_opening_angle: $('angle').value,
      show_opening_direction: $('showDirection').checked,
      show_door_symbol: $('showDoorSymbol').checked,
      door_reveal: mmv('doorReveal'),
      cabinet_category: $('category').value,
      cabinet_type: $('cabinet').value,
      placement_gap: mmv('gap'),
      width: mmv('width'),
      depth: mmv('depth'),
      height: mmv('height'),
      shelf_count: $('shelves').value,
      carcass_material: $('carcassMaterial').value,
      toe_kick_height: mmv('toeHeight'),
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
      // A wall unit stores a toe-kick height of 0 (it hangs); that must not become the
      // starting height of the next base or tall unit, which stand on a 100 mm toe kick.
      if (key === 'toe_kick_height' && p.cabinet_category === 'wall') return;
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
    syncThicknessPresets();
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
    setSoft($('handleOptions'), !bundle);
    if (!bundle) {
      drawPreview();
      return;
    }

    const finishes = list(bundle.finishes);
    fillSelect($('handleLength'), list(bundle.lengths).map((l) => ({ id: String(l), name: fmtLen(l) })));
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
    setSoft($('handleCustom'), position !== 'custom');
    setSoft($('handleOffsets'), position === 'custom');
    setSoft($('handleVertField'), !['top', 'bottom'].includes(position));
  }

  /* ---------------------------------------------------------------------- *
   * Catalog / category / cabinet
   * ---------------------------------------------------------------------- */

  async function refreshCabinets({ selectId = null, keepValues = false } = {}) {
    if (categoryKind() !== 'cabinet') return; // a filler, end panel or toe kick has no catalog cabinets
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
    fillSelect($('widthPreset'), [{ id: 'custom', name: 'Custom' }, ...sizes.map((w) => ({ id: String(w), name: fmtLen(w) }))]);
    syncWidthPreset();
  }

  // Panel and back-panel thickness: a list of the usual boards, and the field beside
  // it for any other thickness. The list follows the field (Custom when it is not a listed size).
  const THICKNESS_SIZES = [6, 9, 12, 18];
  const THICKNESS_PAIRS = [['thicknessPreset', 'thickness'], ['backThicknessPreset', 'backThickness']];

  function fillThicknessPresets() {
    THICKNESS_PAIRS.forEach(([presetId]) => {
      fillSelect($(presetId), [{ id: 'custom', name: 'Custom' }, ...THICKNESS_SIZES.map((t) => ({ id: String(t), name: fmtLen(t) }))]);
    });
    syncThicknessPresets();
  }

  function syncThicknessPresets() {
    THICKNESS_PAIRS.forEach(([presetId, inputId]) => {
      const value = String(num(mmv(inputId)));
      const listed = [...$(presetId).options].some((o) => o.value === value);
      $(presetId).value = listed ? value : 'custom';
    });
  }

  function syncWidthPreset() {
    const value = String(num(mmv('width')));
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

  // The Cabinet Category decides which fields the Cabinet section shows: the
  // cabinet's own (cabinet type, size, shelves, gap) for every real category, or
  // the Filler / End Panel fields when one of those is chosen. Every section (and
  // the front-view picture above) always stays where it is: Catalog, Handle,
  // Material, Toe Kick, Door Opening and Visibility never disappear. A wall unit
  // hangs at height 0, so the toe-kick height does not raise it.
  function updateCategoryUi() {
    const kind = categoryKind();
    document.querySelectorAll('.cabinet-only').forEach((el) => { setSoft(el, kind !== 'cabinet'); });
    document.querySelectorAll('.cabinet-only-btn').forEach((el) => { el.hidden = kind !== 'cabinet'; });
    // The toe-kick height is shared: it raises cabinets and is a toe kick's height.
    document.querySelectorAll('.cabinet-or-toe').forEach((el) => { setSoft(el, kind !== 'cabinet' && kind !== 'toe_kick'); });
    setSoft($('sub-filler'), kind !== 'filler');
    setSoft($('sub-end-panel'), kind !== 'end_panel');
    setSoft($('sub-toe-kick'), kind !== 'toe_kick');
    setSoft($('toeNote'), !(kind === 'cabinet' && $('category').value === 'wall'));
  }

  async function loadCabinet(params) {
    setBadge(params.cabinet_name || params.cabinet_id || null);
    followCabinet({ height: params.height, front: params.envelope_depth, top: params.cabinet_category === 'wall' ? params.top_z - params.base_z : params.top_z });
    setSelect('catalog', resolveCatalogId(params.catalog_id));
    applyCatalogFeatures();
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

  const VBW = 240;
  const VBH = 176;

  // Draws whatever the Cabinet Category is: the cabinet itself, or the filler, end
  // panel or toe kick (shown against the cabinet). It is redrawn on every change
  // to any field, so the picture is always what the model is being given.
  function drawPreview() {
    const kind = categoryKind();
    if (kind === 'cabinet') drawCabinetPreview();
    else drawExtraPreview(kind);
  }

  const numOr = (value, fallback) => (Number.isFinite(num(value)) ? num(value) : fallback);

  // The chosen handle, or null when there is none. Lengths in millimetres.
  function handleSpec() {
    const bundle = currentBundle();
    const length = num($('handleLength').value);
    if (!bundle || !(length > 0)) return null;
    const knob = bundle.profile === 'knob';
    return {
      knob,
      length,
      horizontal: !knob && $('handleOrientation').value === 'horizontal',
      position: $('handlePosition').value || 'top',
      side: numOr(mmv('handleSide'), 0),
      vertical: numOr(mmv('handleVert'), 0),
      customX: numOr(mmv('handleCustomX'), 50),
      customZ: numOr(mmv('handleCustomZ'), 100)
    };
  }

  const HANDLE_SECTION_MM = 10; // a bar's cross-section, as in Defaults::HANDLE_SECTION

  // Where the handle's centre goes on a door and how big it is, in millimetres
  // measured from the door's left edge and bottom (the same rules as
  // HandleManager.placement). `freeEdgeHigh`: the hinge is on the left.
  function handleGeometry(spec, doorW, doorH, freeEdgeHigh) {
    const halfAlong = spec.length / 2;
    const halfAcross = spec.knob ? halfAlong : HANDLE_SECTION_MM / 2;
    const [halfU, halfV] = spec.horizontal ? [halfAlong, halfAcross] : [halfAcross, halfAlong];
    let u;
    switch (spec.position) {
      case 'custom': u = spec.customX; break;
      case 'left': u = spec.side + halfU; break;
      case 'right': u = doorW - spec.side - halfU; break;
      case 'center': u = doorW / 2 - halfU; break;
      default: u = freeEdgeHigh ? doorW - spec.side - halfU : spec.side + halfU;
    }
    let v;
    switch (spec.position) {
      case 'custom': v = spec.customZ; break;
      case 'top': v = doorH - spec.vertical - halfV; break;
      case 'bottom': v = spec.vertical + halfV; break;
      default: v = doorH / 2;
    }
    return { u, v, halfU, halfV };
  }

  function drawCabinetPreview() {
    const svg = $('preview');
    const caption = $('previewCaption');

    const W = num(mmv('width'));
    const H = num(mmv('height'));
    const D = num(mmv('depth'));
    if (!(W > 0 && H > 0)) {
      svg.innerHTML = '';
      caption.textContent = 'Enter width and height to see the front view.';
      return;
    }

    const isWall = $('category').value === 'wall';
    let toe = isWall ? 0 : num(mmv('toeHeight'));
    if (!Number.isFinite(toe) || toe < 0) toe = 0;

    const cabinet = currentCabinet();
    const doors = cabinet ? (cabinet.doors | 0) : 0;
    const shelves = Math.min(20, Math.max(0, parseInt($('shelves').value, 10) || 0));
    const hingeOnLeft = $('direction').value !== 'right';
    const showSwing = $('showDoorSymbol').checked;
    // The Visibility ticks show in the picture too: an unticked part is faded.
    const showDoors = $('visDoor').checked;
    const showToe = $('visToe').checked;
    const carcassClass = $('visCarcass').checked ? 'pv-body' : 'pv-body pv-off';
    const handle = handleSpec();
    const revealMm = numOr(mmv('doorReveal'), 2);
    const gapMm = numOr(mmv('doorGap'), 1.5);

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
      out.push(`<rect class="${showToe ? 'pv-toe' : 'pv-toe pv-off'}" x="${x0 + inset}" y="${bodyBottom}" width="${toeW}" height="${th}"/>`);
    }
    out.push(`<rect class="${carcassClass}" x="${x0}" y="${bodyTop}" width="${bw}" height="${bh}"/>`);

    for (let i = 1; i <= shelves; i += 1) {
      const y = bodyTop + (bh * i) / (shelves + 1);
      out.push(`<line class="pv-shelf" x1="${x0}" y1="${y}" x2="${x0 + bw}" y2="${y}"/>`);
    }

    if (doors > 0 && showDoors) {
      // Schematic, not to scale: fixed insets keep the door outline readable.
      const reveal = 3.5;
      const gap = 3;
      const doorW = (bw - 2 * reveal - (doors - 1) * gap) / doors;
      const doorTop = bodyTop + reveal;
      const doorH = bh - 2 * reveal;
      // The real door size, for placing the handle at true scale on the drawn door.
      const doorWMm = (W - 2 * revealMm - (doors - 1) * gapMm) / doors;
      const doorHMm = H - 2 * revealMm;

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

        if (handle) {
          // Hinge on the left means the free edge (where the handle goes) is the high one.
          const g = handleGeometry(handle, doorWMm, doorHMm, left);
          const cx = dx + g.u * s;
          const cy = doorTop + doorH - g.v * s;
          if (handle.knob) {
            out.push(`<circle class="pv-handle" cx="${cx}" cy="${cy}" r="${Math.max(1.6, g.halfU * s)}"/>`);
          } else {
            const hw = Math.max(1.6, g.halfU * 2 * s);
            const hh = Math.max(1.6, g.halfV * 2 * s);
            out.push(`<rect class="pv-handle" x="${cx - hw / 2}" y="${cy - hh / 2}" width="${hw}" height="${hh}" rx="0.8"/>`);
          }
        }
      }
    }

    out.push(`<text class="pv-dim" x="${VBW / 2}" y="${floorY + 14}" text-anchor="middle">${fmtU(W)}</text>`);
    out.push(`<text class="pv-dim" transform="translate(${x0 + bw + 11} ${(bodyTop + bodyBottom) / 2}) rotate(-90)" text-anchor="middle">${fmtU(H)}</text>`);
    svg.innerHTML = out.join('');

    const depthText = Number.isFinite(D) ? `, D ${fmtU(D)}` : '';
    caption.textContent = `W ${fmtU(W)}${depthText}, H ${fmtU(H)} ${unitInfo().label}. Base Z ${fmtU(toe)} ${unitInfo().label}, top Z ${fmtU(toe + H)} ${unitInfo().label}.`;
  }

  // ---- filler / end panel / toe kick ------------------------------------------------
  // Front view, in millimetres: x along the row, z up from the floor. Each is drawn
  // as a solid part next to a dashed outline of the cabinet, so you can see how it
  // sits (the cabinet's own width, height and toe-kick height come from its fields).

  // Draws `parts` ({ x, z, w, h, cls, label?, joints? }) scaled to fit, on the floor.
  function drawScene(parts, captionText) {
    const svg = $('preview');
    const minX = Math.min(...parts.map((p) => p.x));
    const maxX = Math.max(...parts.map((p) => p.x + p.w));
    const maxZ = Math.max(...parts.map((p) => p.z + p.h));
    const padX = 26;
    const top = 12;
    const bottom = 24;
    const s = Math.min((VBW - 2 * padX) / (maxX - minX), (VBH - top - bottom) / maxZ);
    const x0 = (VBW - (maxX - minX) * s) / 2;
    const floorY = VBH - bottom;
    const px = (x) => x0 + (x - minX) * s;
    const py = (z) => floorY - z * s;

    const out = [`<line class="pv-floor" x1="${x0 - 14}" y1="${floorY}" x2="${x0 + (maxX - minX) * s + 14}" y2="${floorY}"/>`];
    parts.forEach((p) => {
      out.push(`<rect class="${p.cls}" x="${px(p.x)}" y="${py(p.z + p.h)}" width="${Math.max(p.w * s, 1.2)}" height="${Math.max(p.h * s, 1.2)}"/>`);
      (p.joints || []).forEach((jx) => {
        out.push(`<line class="pv-joint" x1="${px(jx)}" y1="${py(p.z + p.h)}" x2="${px(jx)}" y2="${py(p.z)}"/>`);
      });
      if (p.label) {
        out.push(`<text class="pv-dim" x="${px(p.x + p.w / 2)}" y="${floorY + 14}" text-anchor="middle">${p.label}</text>`);
      }
      if (p.heightLabel) {
        out.push(`<text class="pv-dim" transform="translate(${px(p.x + p.w) + 9} ${py(p.z + p.h / 2)}) rotate(-90)" text-anchor="middle">${p.heightLabel}</text>`);
      }
    });
    svg.innerHTML = out.join('');
    $('previewCaption').textContent = captionText;
  }

  // The cabinet the part goes with, as a dashed outline.
  function ghostCabinet(lift) {
    const w = numOr(mmv('width'), 600);
    const h = numOr(mmv('height'), 780);
    return { x: 0, z: lift, w, h, cls: 'pv-ghost' };
  }

  function drawExtraPreview(kind) {
    const svg = $('preview');
    const lift = Math.max(0, numOr(mmv('toeHeight'), 100));
    const cabinet = ghostCabinet(lift);

    if (kind === 'filler') {
      const w = num(mmv('fillerWidth'));
      const t = num(mmv('fillerThickness'));
      const h = num(mmv('fillerHeight'));
      if (!(w > 0 && h > 0)) {
        svg.innerHTML = '';
        $('previewCaption').textContent = 'Enter the filler width and height to see it.';
        return;
      }
      // Beside the cabinet, on the same base height (the wall side is worked out when it is inserted).
      const filler = { x: cabinet.w, z: lift, w, h, cls: 'pv-part', label: fmtU(w), heightLabel: fmtU(h) };
      drawScene([cabinet, filler], `Filler ${fmtU(w)} × ${fmtU(h)} ${unitInfo().label}${Number.isFinite(t) ? `, ${fmtU(t)} thick` : ''}, flush with the door, base Z ${fmtU(lift)} ${unitInfo().label}.`);
    } else if (kind === 'end_panel') {
      const d = num(mmv('epDepth'));
      const t = num(mmv('epThickness'));
      const h = num(mmv('epHeight'));
      if (!(t > 0 && h > 0)) {
        svg.innerHTML = '';
        $('previewCaption').textContent = 'Enter the end panel thickness and height to see it.';
        return;
      }
      const left = $('epSide').value !== 'right';
      const panel = { x: left ? -t : cabinet.w, z: 0, w: t, h, cls: 'pv-part', label: fmtU(t), heightLabel: fmtU(h) };
      drawScene([cabinet, panel], `End panel on the ${left ? 'left' : 'right'}: depth ${Number.isFinite(d) ? fmtU(d) : '?'}, thickness ${fmtU(t)}, height ${fmtU(h)} ${unitInfo().label}.`);
    } else {
      const len = num(mmv('pieceLength'));
      const count = Math.floor(num($('pieceCount').value));
      const h = num(mmv('toeHeight'));
      const t = num(mmv('toeThickness'));
      const recess = num(mmv('toeRecess'));
      if (!(len > 0 && count > 0 && h > 0)) {
        svg.innerHTML = '';
        $('previewCaption').textContent = 'Enter the piece length, number of pieces and height to see the toe kick.';
        return;
      }
      const total = len * count;
      const joints = [];
      for (let i = 1; i < Math.min(count, 60); i += 1) joints.push(len * i);
      const kick = { x: 0, z: 0, w: total, h, cls: 'pv-toe', joints, label: fmtU(total), heightLabel: fmtU(h) };
      // The cabinet stands on it.
      drawScene([{ ...cabinet, z: h }, kick],
        `Toe kick: ${count} × ${fmtU(len)} = ${fmtU(total)} ${unitInfo().label} long, ${fmtU(h)} high${Number.isFinite(t) ? `, ${fmtU(t)} thick` : ''}${Number.isFinite(recess) ? `, recess ${fmtU(recess)} ${unitInfo().label}` : ''}.`);
    }
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

  /* ---------------------------------------------------------------------- *
   * Soft motion: things slide and fade instead of snapping
   * ---------------------------------------------------------------------- */

  const SOFT_MS = 420;
  const SOFT_EASING = 'cubic-bezier(0.45, 0, 0.25, 1)';

  // Shows or hides a block (a group of fields) by easing its height and opacity.
  // Before the panel has finished building, or where the browser cannot animate,
  // it just shows / hides.
  function setSoft(el, hide) {
    if (!el) return;
    const wanted = el.softHide === undefined ? el.hidden : el.softHide;
    if (wanted === hide) return;
    el.softHide = hide;
    if (el.softAnimation) {
      el.softAnimation.cancel();
      el.softAnimation = null;
      el.style.overflow = '';
    }
    if (!state.animate || typeof el.animate !== 'function') {
      el.hidden = hide;
      return;
    }

    if (!hide) el.hidden = false;
    const style = getComputedStyle(el);
    const open = {
      height: `${el.offsetHeight}px`, opacity: 1,
      marginTop: style.marginTop, marginBottom: style.marginBottom,
      paddingTop: style.paddingTop, paddingBottom: style.paddingBottom
    };
    const shut = { height: '0px', opacity: 0, marginTop: '0px', marginBottom: '0px', paddingTop: '0px', paddingBottom: '0px' };
    el.style.overflow = 'hidden';
    el.softAnimation = el.animate(hide ? [open, shut] : [shut, open], { duration: SOFT_MS, easing: SOFT_EASING });
    el.softAnimation.onfinish = () => {
      el.softAnimation = null;
      el.style.overflow = '';
      if (hide) el.hidden = true;
    };
  }

  // Mouse-wheel scrolling that glides to where it is going instead of jumping.
  function enableSmoothScroll(el) {
    let target = el.scrollTop;
    let frame = null;
    const step = () => {
      const distance = target - el.scrollTop;
      if (Math.abs(distance) < 0.5) {
        el.scrollTop = target;
        frame = null;
        return;
      }
      el.scrollTop += distance * 0.13;
      frame = requestAnimationFrame(step);
    };
    el.addEventListener('wheel', (event) => {
      if (event.ctrlKey || event.deltaY === 0) return;
      event.preventDefault();
      const pixels = event.deltaMode === 1 ? event.deltaY * 32 : event.deltaMode === 2 ? event.deltaY * el.clientHeight : event.deltaY;
      const start = frame ? target : el.scrollTop;
      target = Math.max(0, Math.min(el.scrollHeight - el.clientHeight, start + pixels));
      if (!frame) frame = requestAnimationFrame(step);
    }, { passive: false });
    // Dragging the scroll bar, the keyboard or scrollIntoView move it too: follow.
    el.addEventListener('scroll', () => { if (!frame) target = el.scrollTop; });
  }
  // Like an accordion: opening a section closes whichever other one is open.
  function toggleCard(card, open) {
    const collapsed = open === undefined ? !card.classList.contains('collapsed') : !open;
    if (!collapsed) {
      document.querySelectorAll('.card').forEach((other) => {
        if (other !== card && other.querySelector('.card-head') && !other.classList.contains('collapsed')) toggleCard(other, false);
      });
    }
    card.querySelector('.card-head').setAttribute('aria-expanded', String(!collapsed));

    const body = card.querySelector('.card-body');
    const inner = body && body.firstElementChild;
    if (card.classList.contains('collapsed') === collapsed) return;
    if (!body || !inner || !state.animate) {
      card.classList.toggle('collapsed', collapsed);
      if (body) body.style.height = '';
      return;
    }

    // Slide the body down (open) or up (closed) over --collapse-ms. From wherever it
    // is now, so a click in the middle of a slide just turns it round.
    clearTimeout(body.slideTimer);
    const from = body.offsetHeight;
    body.style.height = `${from}px`;
    void body.offsetHeight; // let the browser take that height before it changes
    if (collapsed) {
      card.classList.add('collapsed');
      body.style.height = '0px';
    } else {
      card.classList.remove('collapsed');
      body.style.height = `${inner.scrollHeight}px`;
      // Once open, the height follows the content again (fields that show or hide).
      body.slideTimer = setTimeout(() => {
        if (!card.classList.contains('collapsed')) body.style.height = '';
      }, 1000);
    }
  }

  // Each section body gets an inner box that carries the padding, so the height the
  // slide animates to is exactly the height of the content.
  function wrapCardBodies() {
    document.querySelectorAll('.card-body').forEach((body) => {
      if (body.firstElementChild && body.firstElementChild.classList.contains('card-inner')) return;
      const inner = document.createElement('div');
      inner.className = 'card-inner';
      if (body.classList.contains('checks')) {
        inner.classList.add('checks');
        body.classList.remove('checks');
      }
      while (body.firstChild) inner.appendChild(body.firstChild);
      body.appendChild(inner);
    });
  }

  /* ---------------------------------------------------------------------- *
   * Actions
   * ---------------------------------------------------------------------- */

  function setBusy(busy) {
    state.busy = busy;
    document.querySelectorAll('[data-action]').forEach((b) => { b.disabled = busy; });
    lockActions();
  }

  // `live` is an Update the panel sends by itself while the user edits a field.
  // It leaves the buttons alone and never steals the cursor.
  async function runAction(action, { live = false } = {}) {
    if (state.busy) return;
    if (action === 'undo') clearTimeout(state.liveTimer); // a pending live edit would redo what is being undone
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
  const NO_LIVE_IDS = new Set(['units', 'rotateDegrees', 'visCarcass', 'visDoor', 'visToe', 'showDirection', 'showDoorSymbol', 'catalog', 'category', 'cabinet']);

  // Which kind of item a field edits, so a change to the Filler fields never
  // rewrites the cabinet that happens to be selected. The toe-kick height is both:
  // it raises cabinets and is the height of a toe kick.
  function fieldKinds(el) {
    if (el.closest('#sub-filler')) return ['filler'];
    if (el.closest('#sub-end-panel')) return ['end_panel'];
    if (el.id === 'toeHeight') return ['cabinet', 'toe_kick'];
    if (el.closest('#sub-toe-kick')) return ['toe_kick'];
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

  // Door gap, door reveal, panel and back panel thickness and the Material section
  // are settings for the whole job: editing one changes EVERY cabinet in the model,
  // whether or not one is selected.
  // Only the setting that was edited is sent, so changing the door gap never
  // touches the materials of cabinets, and the other way round.
  const GLOBAL_FIELDS = {
    doorGap: ['door_gap', 'doorGap'],
    doorReveal: ['door_reveal', 'doorReveal'],
    doorDistance: ['door_distance', 'doorDistance'],
    handle: ['handle_id', 'handle'],
    handleLength: ['handle_length', 'handleLength'],
    handleFinish: ['handle_finish', 'handleFinish'],
    handleMaterial: ['handle_material', 'handleMaterial'],
    handleOrientation: ['handle_orientation', 'handleOrientation'],
    handlePosition: ['handle_position', 'handlePosition'],
    handleSide: ['handle_side_offset', 'handleSide'],
    handleVert: ['handle_vertical_offset', 'handleVert'],
    handleCustomX: ['handle_custom_x', 'handleCustomX'],
    handleCustomZ: ['handle_custom_z', 'handleCustomZ'],
    topPanel: ['top_panel_style', 'topPanel'],
    thickness: ['material_thickness', 'thickness'],
    thicknessPreset: ['material_thickness', 'thickness'],
    backThickness: ['back_thickness', 'backThickness'],
    backThicknessPreset: ['back_thickness', 'backThickness'],
    baseMaterial: ['base_material', 'baseMaterial'],
    wallMaterial: ['wall_material', 'wallMaterial'],
    tallMaterial: ['tall_material', 'tallMaterial'],
    carcassMaterial: ['carcass_material', 'carcassMaterial']
  };
  const globalDirty = new Map();

  function scheduleGlobal(delay = LIVE_TYPING_DELAY_MS) {
    clearTimeout(state.globalTimer);
    state.globalTimer = setTimeout(runGlobal, delay);
  }

  async function runGlobal() {
    if (state.busy) {
      scheduleGlobal(); // something else is still running; try again shortly
      return;
    }
    state.busy = true;
    state.liveBusy = true; // the model events this causes must not overwrite what is being typed
    clearInvalid();
    try {
      const payload = {};
      const withHandle = !!$('handle').value;
      globalDirty.forEach((elementId, key) => {
        if (key.startsWith('handle_') && key !== 'handle_id' && !withHandle) payload[key] = ''; // no handle: nothing to set
        else payload[key] = LENGTH_IDS.includes(elementId) ? mmv(elementId) : $(elementId).value;
      });
      globalDirty.clear();
      const res = await call('apply_all', payload);
      if (res.ok) {
        setStatus('ok', res.message);
      } else {
        markInvalid(res.errors, 'cabinet', { focus: false });
        setStatus('error', res.message, (res.errors || []).length > 1 ? res.errors.map((e) => e.message) : []);
      }
    } catch (error) {
      setStatus('error', error.message);
    } finally {
      state.busy = false;
      state.liveBusy = false;
    }
  }

  // A field was edited: update the selected item if this field belongs to it.
  function liveEdit(el) {
    if (GLOBAL_FIELDS[el.id]) {
      const [key, elementId] = GLOBAL_FIELDS[el.id];
      globalDirty.set(key, elementId);
      // A different handle bundle brings its own lengths, finishes and positions
      // (the panel has just refilled them), so they all go along with it.
      if (el.id === 'handle') {
        Object.entries(GLOBAL_FIELDS).filter(([id]) => id.startsWith('handle')).forEach(([, [k, e]]) => globalDirty.set(k, e));
      }
      scheduleGlobal(el.tagName === 'SELECT' ? LIVE_PICK_DELAY_MS : LIVE_TYPING_DELAY_MS);
      return;
    }
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
    // Both start unticked; the user ticks them when wanted.
    $('showDirection').checked = d.show_opening_direction === true;
    $('showDoorSymbol').checked = d.show_door_symbol === true;
    const v = d.visibility_settings || {};
    $('visCarcass').checked = v.carcass !== false;
    $('visDoor').checked = v.door !== false;
    $('visToe').checked = v.toe_kick !== false;
    syncThicknessPresets();
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
    m.filler_defaults = m.filler_defaults || { width: 50, thickness: 18, height: 780, material: 'White' };
    m.end_panel_defaults = m.end_panel_defaults || { side: 'right', thickness: 18, material: 'White' };
    m.toe_kick_defaults = m.toe_kick_defaults || { toe_kick_height: 100, toe_kick_thickness: 18, toe_kick_material: '__door__', toe_kick_piece_length: 2000, toe_kick_pieces: 1, toe_kick_recess: 50 };
    return m;
  }

  async function buildUi() {
    const m = state.meta;
    $('appVersion').textContent = 'v' + (m.version || APP_VERSION);
    fillSelect($('units'), Object.entries(UNITS).map(([id, unit]) => ({ id, name: unit.name })));
    $('units').value = state.unit;
    refreshUnitLabels();
    fillSelect($('topPanel'), [
      { id: '', name: 'By unit type' },
      { id: 'full', name: 'One full panel' }
    ]);
    fillSelect($('catalog'), m.catalogs, { placeholder: m.catalogs.length ? 'Select a model...' : 'No catalogs found' });
    fillSelect($('handle'), m.handle_bundles, { placeholder: 'None' });
    // Filler, End Panel and Toe Kick are choices in the same list as the cabinet categories.
    applyCatalogFeatures(); // fills the Cabinet Category list with what the catalog offers
    fillSelect($('direction'), m.directions);
    fillWidthPreset();
    fillThicknessPresets();
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
      applyCatalogFeatures();
      updateCategoryUi();
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
      if ($('widthPreset').value !== 'custom') {
        setText('width', Number($('widthPreset').value));
        // A standard width comes with the standard depth and height of the cabinet
        // (560 deep, 780 high for a base unit).
        const standard = (currentCabinet() || {}).defaults || {};
        setText('depth', standard.depth);
        setText('height', standard.height);
      }
      drawPreview();
    });
    $('width').addEventListener('input', syncWidthPreset);
    $('units').addEventListener('change', () => setUnit($('units').value));
    THICKNESS_PAIRS.forEach(([presetId, inputId]) => {
      $(presetId).addEventListener('change', () => {
        if ($(presetId).value !== 'custom') setText(inputId, Number($(presetId).value));
        drawPreview();
      });
      $(inputId).addEventListener('input', syncThicknessPresets);
    });
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
    wrapCardBodies();
    enableSmoothScroll($('scroll'));
    wireEvents();
    try {
      const saved = localStorage.getItem('kcm.unit');
      if (UNITS[saved]) state.unit = saved;
    } catch (_) { /* no stored choice: millimetres */ }
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
    // From here on, sections slide open and shut.
    requestAnimationFrame(() => requestAnimationFrame(() => { state.animate = true; }));
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
