(() => {
  'use strict';

  /* The Customize window: a picture of one cabinet (orbit, zoom, pan; click a part to select it), the list of its
   * parts, and fields to change the size of the selected part and to move it. Every change goes to SketchUp at once
   * (action "set"), which rebuilds the cabinet and sends the parts back. Sizes are in millimetres.
   * The picture is drawn here with plain canvas maths (no libraries, so it works offline). */

  const $ = (id) => document.getElementById(id);
  const GROUP_NAMES = { carcass: 'Carcass', part: 'Board', door: 'Doors', drawer: 'Drawer fronts', drawer_box: 'Drawer boxes', appliance: 'Appliances' };
  const GROUP_COLORS = { carcass: '#c6cad1', part: '#d6c7a6', door: '#e7d8bb', drawer: '#e2d0ad', drawer_box: '#d3b685', appliance: '#9aa3ae' };
  const DARK_PARTS = /glass|_panel|display/;

  const state = {
    name: '', parts: [], selected: null, hover: null,
    yaw: -35, pitch: 24, zoom: 1, pan: [0, 0],
    groups: { carcass: true, part: true, door: true, drawer: true, drawer_box: true, appliance: true },
    ghost: true, isolate: false,
    pending: new Map(), seq: 0, faces: [], busy: false
  };

  /* ---- talking to SketchUp ---------------------------------------------------------------- */

  function call(action, data) {
    return new Promise((resolve, reject) => {
      const id = ++state.seq;
      const timer = setTimeout(() => { if (state.pending.delete(id)) reject(new Error('SketchUp did not answer.')); }, 20000);
      state.pending.set(id, (message) => { clearTimeout(timer); resolve(message); });
      window.sketchup.kcm_cust(JSON.stringify({ id, action, data: data || {} }));
    });
  }

  window.KCM = {
    receive(message) {
      if (!message) return;
      const waiting = state.pending.get(message.id);
      if (waiting) { state.pending.delete(message.id); waiting(message); } else if (message.event === 'snapshot') load(message.data);
    }
  };

  function setStatus(text, error) {
    const el = $('status');
    el.textContent = text || '';
    el.className = error ? 'error' : '';
  }

  async function send(action, data, doneText) {
    if (state.busy) return;
    state.busy = true;
    try {
      const reply = await call(action, data);
      if (reply.ok) { if (reply.data) load(reply.data); setStatus(doneText || reply.message || ''); } else { setStatus(reply.message || 'That did not work.', true); await refresh(); }
    } catch (error) {
      setStatus(error.message, true);
    } finally {
      state.busy = false;
    }
  }

  async function refresh() {
    try { const reply = await call('get'); if (reply.ok) load(reply.data); else setStatus(reply.message, true); } catch (error) { setStatus(error.message, true); }
  }

  /* ---- data -------------------------------------------------------------------------------- */

  function load(data) {
    const first = state.parts.length === 0;
    state.name = data.name || '';
    state.parts = data.parts || [];
    if (state.selected && !state.parts.some((part) => part.key === state.selected)) state.selected = null;
    $('title').textContent = `Customize: ${state.name}`;
    $('size').textContent = `${fmt(data.width)} wide x ${fmt(data.depth)} deep x ${fmt(data.height)} high`;
    buildList();
    fillEditor();
    if (first) { fit(); setView('iso'); }
    draw();
  }

  const part = () => state.parts.find((p) => p.key === state.selected) || null;

  function fmt(n) {
    if (n === null || n === undefined || !Number.isFinite(Number(n))) return '';
    return String(Math.round(Number(n) * 10) / 10);
  }

  function num(text) {
    const n = parseFloat(String(text).trim().replace(',', '.'));
    return Number.isFinite(n) ? n : NaN;
  }

  /* ---- the list and the editor -------------------------------------------------------------- */

  function buildList() {
    const list = $('list');
    list.textContent = '';
    Object.keys(GROUP_NAMES).forEach((group) => {
      const items = state.parts.filter((p) => p.group === group);
      if (!items.length) return;
      const heading = document.createElement('h2');
      heading.textContent = GROUP_NAMES[group];
      list.appendChild(heading);
      items.forEach((p) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = p.name;
        if (p.custom) { const dot = document.createElement('span'); dot.className = 'dot'; dot.textContent = '●'; dot.title = 'Changed'; button.appendChild(dot); }
        if (p.key === state.selected) button.classList.add('sel');
        button.addEventListener('click', () => select(p.key));
        list.appendChild(button);
      });
    });
  }

  function select(key) {
    state.selected = key;
    buildList();
    fillEditor();
    draw();
  }

  // The thickness of a board is its smallest side.
  function thinAxis(p) {
    if (p.shaped) return 2;
    return p.size.indexOf(Math.min(...p.size));
  }

  const AXES = ['Depth', 'Width', 'Height'];

  function fillEditor() {
    const p = part();
    $('noSel').hidden = !!p;
    $('form').hidden = !p;
    if (!p) return;
    $('partName').textContent = p.name;
    $('partInfo').textContent = `${GROUP_NAMES[p.group] || ''}${p.custom ? ' - changed' : ''}${p.shaped ? ' - shaped board: its outline follows the cabinet, only its thickness can be changed' : ''}`;
    ['sx', 'sy', 'sz'].forEach((id, axis) => { $(id).value = fmt(p.size[axis]); $(id).disabled = p.shaped && axis < 2; });
    const thin = thinAxis(p);
    $('stLabel').textContent = `Thickness (its ${AXES[thin].toLowerCase()})`;
    $('st').value = fmt(p.size[thin]);
    ['mx', 'my', 'mz'].forEach((id, axis) => { $(id).value = fmt(p.move[axis]); });
    $('resetPart').disabled = !p.custom;
  }

  // Sends a size / place for the selected part. A size equal to the cabinet's own (base_size) is sent as nothing,
  // so that axis keeps following the cabinet.
  function change(sizes, move) {
    const p = part();
    if (!p) return;
    const extent = sizes.map((value, axis) => (Math.abs(value - p.base_size[axis]) < 0.05 ? null : value));
    send('set', { key: p.key, extent, move }, 'Changed.');
  }

  function readSizes(p) {
    const sizes = ['sx', 'sy', 'sz'].map((id) => num($(id).value));
    if (sizes.some((value) => !(value > 0))) { setStatus('A size must be a number above 0.', true); fillEditor(); return null; }
    return sizes.map((value, axis) => (p.shaped && axis < 2 ? p.size[axis] : value));
  }

  function readMove() {
    const move = ['mx', 'my', 'mz'].map((id) => num($(id).value));
    if (move.some((value) => !Number.isFinite(value))) { setStatus('A move must be a number.', true); fillEditor(); return null; }
    return move;
  }

  function wireEditor() {
    ['sx', 'sy', 'sz'].forEach((id) => $(id).addEventListener('change', () => {
      const p = part(); const sizes = p && readSizes(p); const move = p && readMove();
      if (sizes && move) change(sizes, move);
    }));
    $('st').addEventListener('change', () => {
      const p = part(); if (!p) return;
      const value = num($('st').value);
      if (!(value > 0)) { setStatus('The thickness must be a number above 0.', true); fillEditor(); return; }
      const sizes = p.size.slice();
      sizes[thinAxis(p)] = value;
      const move = readMove();
      if (move) change(sizes, move);
    });
    ['mx', 'my', 'mz'].forEach((id) => $(id).addEventListener('change', () => {
      const p = part(); const sizes = p && readSizes(p); const move = p && readMove();
      if (sizes && move) change(sizes, move);
    }));
    document.querySelectorAll('[data-move]').forEach((button) => button.addEventListener('click', () => {
      const p = part(); if (!p) return;
      const step = num($('step').value) || 10;
      const direction = button.dataset.move.split(',').map(Number);
      const move = p.move.map((value, axis) => Math.round((value + (direction[axis] * step)) * 100) / 100);
      change(p.size.slice(), move);
    }));
    $('resetPart').addEventListener('click', () => { const p = part(); if (p) send('reset', { key: p.key }, 'Put back.'); });
    $('resetAll').addEventListener('click', () => send('reset_all', {}, 'Every part put back.'));
  }

  /* ---- the picture --------------------------------------------------------------------------- */

  const canvas = $('view');
  const ctx = canvas.getContext('2d');

  // The corners of every part as faces: { pts: [[x, y, z]...], normal: [x, y, z], key }, in the cabinet's frame.
  function facesOf(p) {
    const faces = [];
    if (p.shaped && p.points && p.points.length >= 3) {
      const z0 = p.origin[2]; const z1 = z0 + p.size[2];
      let area = 0;
      p.points.forEach(([x, y], i) => { const [x2, y2] = p.points[(i + 1) % p.points.length]; area += (x * y2) - (x2 * y); });
      const ring = area < 0 ? p.points.slice().reverse() : p.points; // counter-clockwise seen from above
      faces.push({ pts: ring.map(([x, y]) => [x, y, z1]), normal: [0, 0, 1], key: p.key });
      faces.push({ pts: ring.slice().reverse().map(([x, y]) => [x, y, z0]), normal: [0, 0, -1], key: p.key });
      ring.forEach(([x, y], i) => {
        const [x2, y2] = ring[(i + 1) % ring.length];
        const length = Math.hypot(x2 - x, y2 - y) || 1;
        faces.push({ pts: [[x, y, z0], [x2, y2, z0], [x2, y2, z1], [x, y, z1]], normal: [(y2 - y) / length, -(x2 - x) / length, 0], key: p.key });
      });
      return faces;
    }
    const [ox, oy, oz] = p.origin; const [dx, dy, dz] = p.size;
    const angle = ((p.rot || 0) * Math.PI) / 180; const c = Math.cos(angle); const s = Math.sin(angle);
    const at = (lx, ly, lz) => [ox + (lx * c) - (ly * s), oy + (lx * s) + (ly * c), oz + lz];
    const turn = (n) => [(n[0] * c) - (n[1] * s), (n[0] * s) + (n[1] * c), n[2]];
    const quad = (a, b, cc, d, normal) => faces.push({ pts: [at(...a), at(...b), at(...cc), at(...d)], normal: turn(normal), key: p.key });
    quad([0, 0, 0], [0, dy, 0], [dx, dy, 0], [dx, 0, 0], [0, 0, -1]);
    quad([0, 0, dz], [dx, 0, dz], [dx, dy, dz], [0, dy, dz], [0, 0, 1]);
    quad([dx, 0, 0], [dx, dy, 0], [dx, dy, dz], [dx, 0, dz], [1, 0, 0]);
    quad([0, 0, 0], [0, 0, dz], [0, dy, dz], [0, dy, 0], [-1, 0, 0]);
    quad([0, dy, 0], [0, dy, dz], [dx, dy, dz], [dx, dy, 0], [0, 1, 0]);
    quad([0, 0, 0], [dx, 0, 0], [dx, 0, dz], [0, 0, dz], [0, -1, 0]);
    return faces;
  }

  function visible(p) {
    if (!state.groups[p.group]) return false;
    return !(state.isolate && state.selected && p.key !== state.selected);
  }

  function bounds() {
    const lo = [Infinity, Infinity, Infinity]; const hi = [-Infinity, -Infinity, -Infinity];
    state.parts.forEach((p) => facesOf(p).forEach((f) => f.pts.forEach((pt) => pt.forEach((v, i) => { lo[i] = Math.min(lo[i], v); hi[i] = Math.max(hi[i], v); }))));
    return state.parts.length ? { lo, hi } : { lo: [0, 0, 0], hi: [1, 1, 1] };
  }

  // The camera: looks at the middle of the cabinet from azimuth `yaw` (0 = in front of it) and elevation `pitch`.
  function camera() {
    const phi = (state.yaw * Math.PI) / 180; const theta = (state.pitch * Math.PI) / 180;
    const D = [-Math.cos(theta) * Math.cos(phi), -Math.cos(theta) * Math.sin(phi), -Math.sin(theta)]; // away from the viewer
    const R = [-Math.sin(phi), Math.cos(phi), 0];
    const U = [(R[1] * D[2]) - (R[2] * D[1]), (R[2] * D[0]) - (R[0] * D[2]), (R[0] * D[1]) - (R[1] * D[0])];
    return { D, R, U };
  }

  const dot = (a, b) => (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2]);

  function size() {
    const rect = canvas.getBoundingClientRect(); const ratio = window.devicePixelRatio || 1;
    if (canvas.width !== Math.round(rect.width * ratio) || canvas.height !== Math.round(rect.height * ratio)) {
      canvas.width = Math.round(rect.width * ratio); canvas.height = Math.round(rect.height * ratio);
    }
    return { w: rect.width, h: rect.height, ratio };
  }

  let baseScale = 0.3;
  function fit() {
    const { w, h } = size();
    const { lo, hi } = bounds();
    const diagonal = Math.hypot(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]) || 1;
    baseScale = (Math.min(w, h) * 0.8) / diagonal;
    state.zoom = 1; state.pan = [0, 0];
  }

  function shade(hex, factor, alpha) {
    const n = parseInt(hex.slice(1), 16);
    const channel = (shift) => Math.max(0, Math.min(255, Math.round(((n >> shift) & 255) * factor)));
    return `rgba(${channel(16)},${channel(8)},${channel(0)},${alpha})`;
  }

  function colorOf(p) {
    if (p.group === 'appliance' && DARK_PARTS.test(p.key)) return '#2b3038';
    if (p.group === 'appliance' && /fridge_1_body|free_body/.test(p.key)) return '#e6e9ed';
    return GROUP_COLORS[p.group] || '#bbbbbb';
  }

  function draw() {
    const { w, h, ratio } = size();
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.clearRect(0, 0, w, h);
    if (!state.parts.length) return;

    const { lo, hi } = bounds();
    const centre = [(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2];
    const { D, R, U } = camera();
    const scale = baseScale * state.zoom;
    const project = (pt) => {
      const rel = [pt[0] - centre[0], pt[1] - centre[1], pt[2] - centre[2]];
      return [(w / 2) + state.pan[0] + (dot(rel, R) * scale), (h / 2) + state.pan[1] - (dot(rel, U) * scale), dot(rel, D)];
    };
    const light = [0.45, -0.3, 0.85];

    const drawn = [];
    state.parts.forEach((p) => {
      if (!visible(p)) return;
      const front = p.group === 'door' || p.group === 'drawer';
      facesOf(p).forEach((face) => {
        if (dot(face.normal, D) >= 0) return; // turned away from the viewer
        const projected = face.pts.map(project);
        drawn.push({ face, p, projected, depth: projected.reduce((sum, q) => sum + q[2], 0) / projected.length, front });
      });
    });
    drawn.sort((a, b) => b.depth - a.depth); // far to near

    drawn.forEach((item) => {
      const { face, p, projected, front } = item;
      const selected = p.key === state.selected;
      const factor = 0.62 + (0.38 * Math.max(0, dot(face.normal, light)));
      const ghost = state.ghost && front && !selected;
      ctx.beginPath();
      projected.forEach((q, i) => (i ? ctx.lineTo(q[0], q[1]) : ctx.moveTo(q[0], q[1])));
      ctx.closePath();
      ctx.fillStyle = shade(selected ? '#3b82f6' : colorOf(p), selected ? 0.8 + (0.3 * factor) : factor, ghost ? 0.3 : 1);
      ctx.fill();
      ctx.lineWidth = selected ? 1.6 : 0.8;
      ctx.strokeStyle = selected ? '#1d4ed8' : (p.key === state.hover ? '#f59e0b' : 'rgba(40,48,60,0.55)');
      ctx.stroke();
    });
    state.faces = drawn;
  }

  function pick(x, y) {
    for (let i = state.faces.length - 1; i >= 0; i -= 1) { // nearest first
      const poly = state.faces[i].projected;
      let inside = false;
      for (let a = 0, b = poly.length - 1; a < poly.length; b = a, a += 1) {
        const crosses = (poly[a][1] > y) !== (poly[b][1] > y) && x < (((poly[b][0] - poly[a][0]) * (y - poly[a][1])) / (poly[b][1] - poly[a][1])) + poly[a][0];
        if (crosses) inside = !inside;
      }
      if (inside) return state.faces[i].p.key;
    }
    return null;
  }

  const VIEWS = { front: [0, 0], back: [180, 0], left: [-90, 0], right: [90, 0], top: [0, 89], iso: [-35, 24] };
  function setView(name) {
    [state.yaw, state.pitch] = VIEWS[name];
    draw();
  }

  function wireView() {
    let drag = null;
    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    canvas.addEventListener('pointerdown', (e) => {
      canvas.setPointerCapture(e.pointerId);
      drag = { x: e.clientX, y: e.clientY, moved: false, pan: e.shiftKey || e.button === 2 || e.button === 1 };
      canvas.classList.add('drag');
    });
    canvas.addEventListener('pointermove', (e) => {
      const rect = canvas.getBoundingClientRect();
      if (!drag) {
        const key = pick(e.clientX - rect.left, e.clientY - rect.top);
        if (key !== state.hover) { state.hover = key; draw(); }
        return;
      }
      const dx = e.clientX - drag.x; const dy = e.clientY - drag.y;
      if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true;
      drag.x = e.clientX; drag.y = e.clientY;
      if (drag.pan) { state.pan[0] += dx; state.pan[1] += dy; } else {
        state.yaw -= dx * 0.5;
        state.pitch = Math.max(-89, Math.min(89, state.pitch + (dy * 0.5)));
      }
      draw();
    });
    canvas.addEventListener('pointerup', (e) => {
      canvas.classList.remove('drag');
      if (drag && !drag.moved) {
        const rect = canvas.getBoundingClientRect();
        const key = pick(e.clientX - rect.left, e.clientY - rect.top);
        if (key) select(key);
      }
      drag = null;
    });
    canvas.addEventListener('wheel', (e) => {
      e.preventDefault();
      state.zoom = Math.max(0.2, Math.min(8, state.zoom * (e.deltaY < 0 ? 1.12 : 1 / 1.12)));
      draw();
    }, { passive: false });
    document.querySelectorAll('[data-view]').forEach((b) => b.addEventListener('click', () => setView(b.dataset.view)));
    $('fit').addEventListener('click', () => { fit(); draw(); });
    document.querySelectorAll('[data-group]').forEach((box) => box.addEventListener('change', () => { state.groups[box.dataset.group] = box.checked; draw(); }));
    $('ghost').addEventListener('change', () => { state.ghost = $('ghost').checked; draw(); });
    $('isolate').addEventListener('change', () => { state.isolate = $('isolate').checked; draw(); });
    window.addEventListener('resize', () => { fit(); draw(); });
  }

  wireEditor();
  wireView();
  refresh().then(() => setStatus('Ready. Changes are applied to the cabinet as you make them.'));
})();
