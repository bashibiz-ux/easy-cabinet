// The drawing of the cabinet gallery (html/gallery.js): a front view and a 3D view from boxes. Run:  node test/gallery_test.js
'use strict';
const assert = require('assert');
const path = require('path');
const gallery = require(path.join(__dirname, '..', 'easy_cabinet', 'html', 'gallery.js'));

const unit = {
  w: 600, d: 560, h: 780,
  parts: [
    { k: 'body', o: [0, 0, 100], e: [560, 18, 780] }, // left side
    { k: 'body', o: [0, 582, 100], e: [560, 18, 780] }, // right side
    { k: 'body', o: [0, 18, 100], e: [18, 564, 780] }, // back
    { k: 'door', o: [562, 2, 102], e: [18, 596, 776] },
    { k: 'toe', o: [60, 0, 0], e: [470, 600, 100] }
  ]
};

// the front view: every box as a rectangle, the carcass first and the door last
const rects = gallery.rects2d(unit);
assert.strictEqual(rects.length, 5);
assert.strictEqual(rects[rects.length - 1].kind, 'door', 'the door is drawn over the carcass');
const door = rects.find((r) => r.kind === 'door');
assert.deepStrictEqual([door.x, door.y, door.w, door.h], [2, 102, 596, 776]);

const flat = gallery.svg2d(unit);
assert.ok(flat.startsWith('<svg') && flat.includes('<rect'), 'an SVG of rectangles');
assert.ok((flat.match(/<rect /g) || []).length > 5, 'the boxes, a sheen on the front and a handle');
assert.ok(flat.includes('ecSheen') && flat.includes('ecShadow'), 'a sheen on the fronts and a shadow on the floor');

// the 3D view: only the faces turned to the viewer (front, left, top), far ones first
const faces = gallery.faces3d(unit);
assert.ok(faces.length > 0 && faces.length <= unit.parts.length * 3, 'at most three faces of a box');
for (let i = 1; i < faces.length; i += 1) {
  assert.ok(faces[i].layer >= faces[i - 1].layer, 'the carcass, then the fronts, then the handles');
  if (faces[i].layer === faces[i - 1].layer) assert.ok(faces[i].depth >= faces[i - 1].depth - 1e-9, 'each layer from far to near');
}
const solid = gallery.svg3d(unit);
assert.ok(solid.includes('<polygon') && solid.includes('viewBox'));

// a door gets a handle on the side away from its hinge, a drawer a bar along its edge, a wall unit near the bottom
const handled = gallery.handles({ cat: 'base', parts: [{ k: 'door', g: 'left', o: [562, 2, 102], e: [18, 596, 776] }, { k: 'drawer', o: [562, 2, 102], e: [18, 596, 200] }] });
assert.strictEqual(handled.length, 2);
assert.ok(handled[0].o[1] > 300, 'the door hinged on the left has its handle on the right');
assert.ok(handled[1].e[1] > handled[1].e[2], 'a drawer handle is a horizontal bar');
const wall = gallery.handles({ cat: 'wall', parts: [{ k: 'door', g: 'right', o: [300, 0, 1400], e: [18, 400, 700] }] });
assert.ok(wall[0].o[2] < 1400 + 200, 'a wall unit has its handle near the bottom of the door');

// a board with an outline (a corner unit's shelf) and a door turned about Z
const corner = { w: 800, d: 800, h: 780, parts: [
  { k: 'body', o: [0, 0, 100], e: [0, 0, 18], p: [[0, 0], [800, 0], [800, 300], [300, 800], [0, 800]] },
  { k: 'door', o: [800, 300, 100], e: [18, 400, 700], r: 135 }
] };
assert.ok(gallery.svg3d(corner).includes('<polygon'));
const turned = gallery.rects2d(corner).find((r) => r.kind === 'door');
assert.ok(turned.w > 0 && turned.h === 700, 'a turned door is as wide as its footprint along Y');

// nothing to draw gives an empty picture, not an error
assert.ok(gallery.svg3d({ parts: [] }).startsWith('<svg'));
assert.ok(gallery.svg2d({ parts: [] }).startsWith('<svg'));
console.log('gallery: all good');
