// Redraws a compiled diagram (see to_figma_ops.py) as native Figma layers. Paste after `const D = {...};`
// and run with use_figma. Ops: r rect, e ellipse, l line, p path/polygon, t text; markers are drawn from the
// trailing marker fields (1 arrow, 3 crow's foot, 4 one-bar).
const FONT = 'Plus Jakarta Sans';
const STY = (w) => (w >= 800 ? 'ExtraBold' : w >= 700 ? 'Bold' : w >= 600 ? 'SemiBold' : w >= 500 ? 'Medium' : 'Regular');
await Promise.all(['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold'].map((s) => figma.loadFontAsync({ family: FONT, style: s })));
const hex = (h) => ({ r: parseInt(h.slice(1, 3), 16) / 255, g: parseInt(h.slice(3, 5), 16) / 255, b: parseInt(h.slice(5, 7), 16) / 255 });
const pal = D.pal.map(hex);
const paint = (i) => (i < 0 ? [] : [{ type: 'SOLID', color: pal[i] }]);
let top = 0;
for (const c of figma.currentPage.children) top = Math.max(top, c.y + c.height);
const frame = figma.createFrame();
frame.name = D.n.replace(/_/g, ' ');
frame.resize(D.w, D.h);
frame.x = 0;
frame.y = top ? top + 160 : 0;
frame.clipsContent = true;
frame.fills = [];
const put = (n) => { frame.appendChild(n); return n; };
const strokeIt = (n, si, sw, dash, op) => {
  if (si >= 0) { n.strokes = paint(si); n.strokeWeight = sw; n.strokeAlign = 'CENTER'; if (dash) n.dashPattern = [dash, Math.round(dash * 0.8)]; } else n.strokes = [];
  if (op !== undefined && op !== 1) n.opacity = op;
};
const vec = (d, fillI, strokeI, sw, dash, op, closed) => {
  const v = figma.createVector();
  v.vectorPaths = [{ windingRule: closed ? 'NONZERO' : 'NONE', data: d }];
  v.fills = paint(fillI);
  strokeIt(v, strokeI, sw, dash, op);
  return put(v);
};
const line = (x1, y1, x2, y2, si, sw, dash, op) => vec(`M ${x1} ${y1} L ${x2} ${y2}`, -1, si, sw, dash, op, false);
const head = (kind, tip, from, ci) => {
  const dx = tip[0] - from[0], dy = tip[1] - from[1];
  const ln = Math.hypot(dx, dy) || 1, ux = dx / ln, uy = dy / ln, px = -uy, py = ux;
  if (kind === 1) {
    const s = 8;
    vec(`M ${tip[0]} ${tip[1]} L ${tip[0] - ux * s + px * s * 0.45} ${tip[1] - uy * s + py * s * 0.45} L ${tip[0] - ux * s - px * s * 0.45} ${tip[1] - uy * s - py * s * 0.45} Z`, ci, -1, 0, 0, 1, true);
  } else if (kind === 3) {
    const bx = tip[0] - ux * 11, by = tip[1] - uy * 11;
    for (const o of [-6, 0, 6]) line(bx, by, tip[0] + px * o, tip[1] + py * o, ci, 1.2, 0, 1);
  } else if (kind === 4) {
    const cx = tip[0] - ux * 9, cy = tip[1] - uy * 9;
    line(cx + px * 6, cy + py * 6, cx - px * 6, cy - py * 6, ci, 1.8, 0, 1);
  }
};
const heads = (o, at, ci) => {
  const [ms, me, sx, sy, sfx, sfy, ex, ey, efx, efy] = o.slice(at);
  if (ms) head(ms, [sx, sy], [sfx, sfy], ci);
  if (me) head(me, [ex, ey], [efx, efy], ci);
};
let count = 0;
for (const o of D.ops) {
  const k = o[0];
  if (k === 'r') {
    const n = figma.createRectangle(); put(n);
    n.x = o[1]; n.y = o[2]; n.resize(Math.max(o[3], 0.01), Math.max(o[4], 0.01)); n.cornerRadius = o[5];
    n.fills = paint(o[6]); strokeIt(n, o[7], o[8], o[9], o[10]);
  } else if (k === 'e') {
    const n = figma.createEllipse(); put(n);
    n.x = o[1]; n.y = o[2]; n.resize(o[3], o[4]);
    n.fills = paint(o[5]); strokeIt(n, o[6], o[7], o[8], o[9]);
  } else if (k === 'l') {
    line(o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8]);
    if (o.length > 9) heads(o, 9, o[5]);
  } else if (k === 'p') {
    vec(o[1], o[2], o[3], o[4], o[5], o[6], !!o[7]);
    if (o.length > 8) heads(o, 8, o[3]);
  } else if (k === 't') {
    const n = figma.createText(); put(n);
    n.fontName = { family: FONT, style: STY(o[5]) };
    n.fontSize = o[4];
    n.lineHeight = { unit: 'PIXELS', value: Math.round(o[4] * 1.25) };
    n.characters = o[3];
    n.fills = paint(o[6]);
    n.x = o[7] === 1 ? o[1] - n.width / 2 : o[7] === 2 ? o[1] - n.width : o[1];
    n.y = o[2] - Math.round(o[4] * 1.25) / 2 - o[4] * 0.35;
  }
  count++;
}
return { frameId: frame.id, name: frame.name, ops: count, children: frame.children.length, w: frame.width, h: frame.height, y: frame.y };
