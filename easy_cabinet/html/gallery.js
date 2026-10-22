// The pictures of the cabinet gallery (Cabinets and Extras): a front view (2D) or a view from the front left above (3D) of a cabinet, drawn as SVG from the boxes the
// layout of the cabinet is made of (see CabinetGallery in Ruby): soft light on every face, a sheen on the fronts, handles, a plinth and a shadow on the floor.
// Pure functions: no page needed.
//
// A shape: { w, d, h, cat, parts: [{ k: 'body' | 'door' | 'drawer' | 'toe' | 'appl', g: hinge ('left' | 'right' | 'top' | 'center'), o: [x, y, z], e: [dx, dy, dz],
//            r: degrees about Z (optional), p: [[x, y], ...] (optional outline) }] } in millimetres, as in the cabinet's own frame: X depth (0 at the wall, the front at
// the high end), Y along the row, Z up.
(function () {
  'use strict';

  const YAW = (30 * Math.PI) / 180; // the cabinet is seen from the front, turned this far to the left
  const PITCH = (24 * Math.PI) / 180; // and from this far above
  const COLOURS = { body: '#d6c39b', door: '#efe2c4', drawer: '#efe2c4', toe: '#43474f', appl: '#8d98a4', handle: '#8b9199', gola: '#b4b9c1' };
  const ORDER = { body: 0, appl: 1, toe: 1, drawer: 2, door: 3, handle: 4, gola: 4 };
  // What is drawn first: the carcass and what is inside it, then the fronts, then what stands on the fronts (handles, profiles). A big face (a shelf) has a depth in
  // the middle of its length, so by depth alone it could be drawn over a front it is behind.
  const LAYER = { body: 0, appl: 0, toe: 0, drawer: 1, door: 1, handle: 2, gola: 2 };
  const LIGHT = normalize([0.55, -0.35, 0.75]);
  const VIEWER = [Math.cos(YAW) * Math.cos(PITCH), -Math.sin(YAW) * Math.cos(PITCH), Math.sin(PITCH)];
  const STROKE = 'rgba(70, 58, 38, 0.62)';

  function normalize(v) {
    const n = Math.hypot(v[0], v[1], v[2]) || 1;
    return [v[0] / n, v[1] / n, v[2] / n];
  }
  const dot = (a, b) => (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2]);
  const round = (v) => Math.round(v * 100) / 100;

  // The handles of the fronts: [{ k: 'handle', o, e }] a bar on every door and drawer front that is not turned. A door has its handle on the side away from its hinge, a
  // drawer or a lift-up door along its edge; a base unit has it near the top of the front, a wall unit near the bottom, a tall unit at hand height.
  function handles(shape) {
    const out = [];
    if (shape.mode === 'gola' || shape.mode === 'none') return out; // (a Gola profile is in the shape; a model without handles has none)
    const category = shape.cat || 'base';
    (shape.parts || []).forEach((part) => {
      if ((part.k !== 'door' && part.k !== 'drawer') || part.r) return;
      const [x, y, z] = part.o;
      const [dx, dy, dz] = part.e;
      if (dy < 120 || dz < 90) return;
      const front = x + dx;
      const bar = 10;
      const horizontal = part.k === 'drawer' || part.g === 'top' || part.g === 'center' || dy > dz * 1.4;
      if (horizontal) {
        const length = Math.min(Math.max(dy * 0.4, 90), 220);
        const zc = category === 'wall' ? z + 40 : z + dz - 45;
        out.push({ k: 'handle', o: [front, y + ((dy - length) / 2), zc - (bar / 2)], e: [14, length, bar] });
      } else {
        const length = Math.min(Math.max(dz * 0.22, 90), 240);
        const yc = part.g === 'left' ? y + dy - 36 : y + 36; // the hinge is on the other side
        let zc;
        if (category === 'wall') zc = z + 70 + (length / 2);
        else if (category === 'tall') zc = Math.min(Math.max(1050, z + (length / 2) + 40), z + dz - (length / 2) - 40);
        else zc = z + dz - 70 - (length / 2);
        out.push({ k: 'handle', o: [front, yc - (bar / 2), zc - (length / 2)], e: [14, bar, length] });
      }
    });
    return out;
  }

  const hangs = (shape) => shape.cat === 'wall' || shape.cat === 'loft';

  const withHandles = (shape) => ({ ...shape, parts: (shape.parts || []).concat(handles(shape)) });

  // The outline of a part seen from above, turned `r` degrees about the Z axis through its origin: [[x, y], ...], low corner first.
  function footprint(part) {
    const [ox, oy] = part.o;
    if (part.p && part.p.length >= 3) return part.p.map(([x, y]) => [x, y]);
    const [dx, dy] = part.e;
    const turn = ((part.r || 0) * Math.PI) / 180;
    const c = Math.cos(turn);
    const s = Math.sin(turn);
    return [[0, 0], [dx, 0], [dx, dy], [0, dy]].map(([x, y]) => [ox + (x * c) - (y * s), oy + (x * s) + (y * c)]);
  }

  const height = (part) => part.e[2];

  // The faces of a part (a prism on its footprint): [{ points: [[x, y, z], ...], normal: [x, y, z] }, ...].
  function prism(part) {
    const base = footprint(part);
    const z0 = part.o[2];
    const z1 = z0 + height(part);
    // the outline goes anticlockwise seen from above (the order of a box's corners; a polygon is turned that way when it is not)
    let area = 0;
    base.forEach(([x, y], i) => { const [nx, ny] = base[(i + 1) % base.length]; area += (x * ny) - (nx * y); });
    const ring = area < 0 ? base.slice().reverse() : base;
    const faces = [{ points: ring.map(([x, y]) => [x, y, z1]), normal: [0, 0, 1] }];
    ring.forEach(([x, y], i) => {
      const [nx, ny] = ring[(i + 1) % ring.length];
      const length = Math.hypot(nx - x, ny - y);
      if (length < 1e-6) return;
      faces.push({ points: [[x, y, z0], [nx, ny, z0], [nx, ny, z1], [x, y, z1]], normal: [(ny - y) / length, -(nx - x) / length, 0] });
    });
    return faces;
  }

  function view3d(point) {
    const [x, y, z] = point;
    const right = (y * Math.cos(YAW)) + (x * Math.sin(YAW));
    const depth = (x * Math.cos(YAW)) - (y * Math.sin(YAW));
    return { x: right, y: -((z * Math.cos(PITCH)) - (depth * Math.sin(PITCH))), depth };
  }

  function shade(hex, factor) {
    const n = parseInt(hex.slice(1), 16);
    const channel = (shift) => Math.max(0, Math.min(255, Math.round(((n >> shift) & 255) * factor)));
    return `rgb(${channel(16)},${channel(8)},${channel(0)})`;
  }

  // The visible faces of every part, far ones first: [{ points: [{x, y}], fill, kind, sheen }]. `shape` is drawn as it is (see withHandles).
  function faces3d(shape) {
    const out = [];
    (shape.parts || []).forEach((part, index) => {
      prism(part).forEach((face) => {
        if (dot(face.normal, VIEWER) <= 0.001) return; // turned away
        const projected = face.points.map(view3d);
        const depth = projected.reduce((sum, p) => sum + p.depth, 0) / projected.length;
        const lit = 0.66 + (0.34 * Math.max(0, dot(face.normal, LIGHT)));
        const front = face.normal[2] === 0 && dot(face.normal, [1, 0, 0]) > 0.9; // a face looking to the front
        out.push({ points: projected, depth, layer: LAYER[part.k] || 0, order: ORDER[part.k] || 0, index, fill: shade(COLOURS[part.k] || COLOURS.body, lit), kind: part.k, sheen: front && (part.k === 'door' || part.k === 'drawer') });
      });
    });
    // the carcass first, then the fronts, then the handles; each layer from far to near
    return out.sort((a, b) => (a.layer - b.layer) || (a.depth - b.depth) || (a.order - b.order) || (a.index - b.index));
  }

  // The boxes seen from the front: [{ x, y, w, h, kind }] with y up (millimetres), the carcass first and the doors last.
  function rects2d(shape) {
    return (shape.parts || [])
      .map((part, index) => {
        const base = footprint(part);
        const ys = base.map((p) => p[1]);
        return { x: Math.min(...ys), y: part.o[2], w: Math.max(...ys) - Math.min(...ys), h: height(part), kind: part.k, order: ORDER[part.k] || 0, index };
      })
      .filter((r) => r.w > 0.01 && r.h > 0.01)
      .sort((a, b) => (a.order - b.order) || (a.index - b.index));
  }

  function wrap(points, pad) {
    const xs = points.map((p) => p.x);
    const ys = points.map((p) => p.y);
    const x0 = Math.min(...xs) - pad;
    const y0 = Math.min(...ys) - pad;
    const w = (Math.max(...xs) - Math.min(...xs)) + (2 * pad);
    const h = (Math.max(...ys) - Math.min(...ys)) + (2 * pad);
    return { viewBox: `${round(x0)} ${round(y0)} ${round(w)} ${round(h)}`, x0, y0, width: w, height: h };
  }

  // What every picture shares: the sheen on a front (light at the top, darker at the bottom) and the soft shadow on the floor.
  const DEFS = '<defs>'
    + '<linearGradient id="ecSheen" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="#ffffff" stop-opacity="0.50"/><stop offset="0.45" stop-color="#ffffff" stop-opacity="0.08"/><stop offset="1" stop-color="#3a2d14" stop-opacity="0.16"/></linearGradient>'
    + '<radialGradient id="ecShadow"><stop offset="0" stop-color="#1c1608" stop-opacity="0.40"/><stop offset="1" stop-color="#1c1608" stop-opacity="0"/></radialGradient>'
    + '</defs>';

  function shadow(box, floorY, centreX, spread, hangs) {
    if (hangs) return ''; // (a unit that hangs on the wall casts no shadow on the floor)
    const rx = (spread * 0.62) + 6;
    const ry = Math.max(box.height * 0.045, 5);
    return `<ellipse cx="${round(centreX)}" cy="${round(floorY)}" rx="${round(rx)}" ry="${round(ry)}" fill="url(#ecShadow)"/>`;
  }

  function svg3d(plain) {
    const shape = withHandles(plain);
    const faces = faces3d(shape);
    if (!faces.length) return '<svg viewBox="0 0 10 10"></svg>';
    const all = faces.flatMap((f) => f.points);
    const box = wrap(all, 14);
    const strokeWidth = Math.max(box.width, box.height) / 330;
    const floorY = Math.max(...all.map((p) => p.y));
    const centreX = (Math.min(...all.map((p) => p.x)) + Math.max(...all.map((p) => p.x))) / 2;
    const spread = (Math.max(...all.map((p) => p.x)) - Math.min(...all.map((p) => p.x))) / 2;
    const body = faces.map((f) => {
      const points = f.points.map((p) => `${round(p.x)},${round(p.y)}`).join(' ');
      const edge = f.kind === 'handle' || f.kind === 'gola' ? 'rgba(50, 54, 60, 0.7)' : STROKE;
      const base = `<polygon points="${points}" fill="${f.fill}" stroke="${edge}" stroke-width="${round(strokeWidth)}" stroke-linejoin="round"/>`;
      return f.sheen ? `${base}<polygon points="${points}" fill="url(#ecSheen)" stroke="none"/>` : base;
    }).join('');
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box.viewBox}" preserveAspectRatio="xMidYMid meet" role="img">${DEFS}${shadow(box, floorY + (box.height * 0.01), centreX, spread, hangs(plain))}${body}</svg>`;
  }

  function svg2d(plain) {
    const shape = withHandles(plain);
    const rects = rects2d(shape);
    if (!rects.length) return '<svg viewBox="0 0 10 10"></svg>';
    const corners = rects.flatMap((r) => [{ x: r.x, y: -r.y }, { x: r.x + r.w, y: -(r.y + r.h) }]);
    const box = wrap(corners, 14);
    const strokeWidth = Math.max(box.width, box.height) / 300;
    const floorY = Math.max(...corners.map((p) => p.y));
    const left = Math.min(...corners.map((p) => p.x));
    const right = Math.max(...corners.map((p) => p.x));
    const body = rects.map((r) => {
      const front = r.kind === 'door' || r.kind === 'drawer';
      const fill = shade(COLOURS[r.kind] || COLOURS.body, front ? 1.0 : 0.95);
      const edge = r.kind === 'handle' || r.kind === 'gola' ? 'rgba(50, 54, 60, 0.7)' : STROKE;
      const where = `x="${round(r.x)}" y="${round(-(r.y + r.h))}" width="${round(r.w)}" height="${round(r.h)}"`;
      const base = `<rect ${where} fill="${fill}" stroke="${edge}" stroke-width="${round(strokeWidth)}"/>`;
      return front ? `${base}<rect ${where} fill="url(#ecSheen)" stroke="none"/>` : base;
    }).join('');
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box.viewBox}" preserveAspectRatio="xMidYMid meet" role="img">${DEFS}${shadow(box, floorY + (box.height * 0.012), (left + right) / 2, (right - left) / 2, hangs(plain))}${body}</svg>`;
  }

  const api = { svg2d, svg3d, faces3d, rects2d, footprint, handles, withHandles };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else window.EC_GALLERY = api;
}());
