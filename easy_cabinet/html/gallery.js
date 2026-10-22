// The pictures of the cabinet gallery (Cabinets and Extras): a front view (2D) or a view from the front left above (3D) of a cabinet, drawn as SVG from the boxes the
// layout of the cabinet is made of (see CabinetGallery in Ruby). Pure functions: no page needed.
//
// A shape: { w, d, h, parts: [{ k: 'body' | 'door' | 'drawer' | 'toe' | 'appl', o: [x, y, z], e: [dx, dy, dz], r: degrees about Z (optional), p: [[x, y], ...] (optional outline) }] }
// in millimetres, as in the cabinet's own frame: X depth (0 at the wall, the front at the high end), Y along the row, Z up.
(function () {
  'use strict';

  const YAW = (30 * Math.PI) / 180; // the cabinet is seen from the front, turned this far to the left
  const PITCH = (24 * Math.PI) / 180; // and from this far above
  const COLOURS = { body: '#d8c8a4', door: '#f0e6cf', drawer: '#f0e6cf', toe: '#4a4e56', appl: '#8f99a4' };
  const ORDER = { body: 0, appl: 1, toe: 1, drawer: 2, door: 3 };
  const LIGHT = normalize([0.55, -0.35, 0.75]);
  const VIEWER = [Math.cos(YAW) * Math.cos(PITCH), -Math.sin(YAW) * Math.cos(PITCH), Math.sin(PITCH)];

  function normalize(v) {
    const n = Math.hypot(v[0], v[1], v[2]) || 1;
    return [v[0] / n, v[1] / n, v[2] / n];
  }
  const dot = (a, b) => (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2]);
  const round = (v) => Math.round(v * 100) / 100;

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

  function height(part) {
    return part.p && part.p.length >= 3 ? part.e[2] : part.e[2];
  }

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

  // The visible faces of every part, far ones first: [{ points: [{x, y}], fill, kind }].
  function faces3d(shape) {
    const out = [];
    (shape.parts || []).forEach((part, index) => {
      prism(part).forEach((face) => {
        if (dot(face.normal, VIEWER) <= 0.001) return; // turned away
        const projected = face.points.map(view3d);
        const depth = projected.reduce((sum, p) => sum + p.depth, 0) / projected.length;
        const lit = 0.66 + (0.34 * Math.max(0, dot(face.normal, LIGHT)));
        out.push({ points: projected, depth, order: ORDER[part.k] || 0, index, fill: shade(COLOURS[part.k] || COLOURS.body, lit), kind: part.k });
      });
    });
    // a part is drawn after what is behind it; parts of the same depth by kind (the doors over the carcass)
    return out.sort((a, b) => (a.depth - b.depth) || (a.order - b.order) || (a.index - b.index));
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

  function wrap(points, pad, fillClass) {
    const xs = points.map((p) => p.x);
    const ys = points.map((p) => p.y);
    const x0 = Math.min(...xs) - pad;
    const y0 = Math.min(...ys) - pad;
    const w = (Math.max(...xs) - Math.min(...xs)) + (2 * pad);
    const h = (Math.max(...ys) - Math.min(...ys)) + (2 * pad);
    return { viewBox: `${round(x0)} ${round(y0)} ${round(w)} ${round(h)}`, width: w, height: h, class: fillClass };
  }

  const STROKE = '#5b5444';

  function svg3d(shape) {
    const faces = faces3d(shape);
    if (!faces.length) return '<svg viewBox="0 0 10 10"></svg>';
    const all = faces.flatMap((f) => f.points);
    const box = wrap(all, 12);
    const strokeWidth = Math.max(box.width, box.height) / 220;
    const body = faces.map((f) => `<polygon points="${f.points.map((p) => `${round(p.x)},${round(p.y)}`).join(' ')}" fill="${f.fill}" stroke="${STROKE}" stroke-width="${round(strokeWidth)}" stroke-linejoin="round"/>`).join('');
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box.viewBox}" preserveAspectRatio="xMidYMid meet" role="img">${body}</svg>`;
  }

  function svg2d(shape) {
    const rects = rects2d(shape);
    if (!rects.length) return '<svg viewBox="0 0 10 10"></svg>';
    const corners = rects.flatMap((r) => [{ x: r.x, y: -r.y }, { x: r.x + r.w, y: -(r.y + r.h) }]);
    const box = wrap(corners, 12);
    const strokeWidth = Math.max(box.width, box.height) / 200;
    const body = rects.map((r) => {
      const fill = shade(COLOURS[r.kind] || COLOURS.body, r.kind === 'door' || r.kind === 'drawer' ? 1.0 : 0.96);
      return `<rect x="${round(r.x)}" y="${round(-(r.y + r.h))}" width="${round(r.w)}" height="${round(r.h)}" fill="${fill}" stroke="${STROKE}" stroke-width="${round(strokeWidth)}"/>`;
    }).join('');
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box.viewBox}" preserveAspectRatio="xMidYMid meet" role="img">${body}</svg>`;
  }

  const api = { svg2d, svg3d, faces3d, rects2d, footprint };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else window.EC_GALLERY = api;
}());
