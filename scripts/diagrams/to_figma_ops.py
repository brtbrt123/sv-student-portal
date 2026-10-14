"""Compiles the diagram SVGs in docs/diagrams into compact JSON drawing instructions that a small
Figma Plugin API script redraws as native, editable layers (rectangles, ellipses, lines, text).
Usage: python -I scripts/diagrams/to_figma_ops.py <outdir>     (writes <name>.json per diagram)
Only handles the SVG elements the generators here produce."""
import json
import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SRC = Path(__file__).resolve().parents[2] / 'docs' / 'diagrams'
NAMES = ['ERD_overview', 'ERD_detailed', 'ClassDiagram', 'DFD_level1', 'UseCase_Diagram', 'ActivityDiagram_Clearance']
NS = '{http://www.w3.org/2000/svg}'


def num(v, d=0.0):
    return float(v) if v not in (None, '') else d


def r(v):
    v = round(v, 1)
    return int(v) if v == int(v) else v


class Compiler:
    def __init__(self):
        self.pal = []
        self.ops = []

    def col(self, c):
        if c in (None, 'none', ''):
            return -1
        if c not in self.pal:
            self.pal.append(c)
        return self.pal.index(c)

    def style(self, e, group):
        a = dict(group)
        a.update({k: v for k, v in e.attrib.items()})
        return a

    def poly_points(self, d):
        """Absolute M/L/C/Q/H/V commands -> (points, last_tangent, first_tangent)."""
        toks = re.findall(r'[MLCQHVZ]|-?\d*\.?\d+', d)
        pts, i, cmd, cur = [], 0, None, (0, 0)
        ctrl_first = None
        ctrl_last = None
        while i < len(toks):
            t = toks[i]
            if t.isalpha():
                cmd = t
                i += 1
                if cmd == 'Z':
                    continue
                continue
            if cmd in ('M', 'L'):
                cur = (float(toks[i]), float(toks[i + 1]))
                i += 2
                if ctrl_first is None and pts:
                    ctrl_first = cur
                pts.append(cur)
                ctrl_last = None
            elif cmd == 'H':
                cur = (float(toks[i]), cur[1]); i += 1; pts.append(cur)
            elif cmd == 'V':
                cur = (cur[0], float(toks[i])); i += 1; pts.append(cur)
            elif cmd == 'C':
                c1 = (float(toks[i]), float(toks[i + 1])); c2 = (float(toks[i + 2]), float(toks[i + 3]))
                cur = (float(toks[i + 4]), float(toks[i + 5])); i += 6
                if ctrl_first is None and pts:
                    ctrl_first = c1
                ctrl_last = c2
                pts.append(cur)
            elif cmd == 'Q':
                c1 = (float(toks[i]), float(toks[i + 1]))
                cur = (float(toks[i + 2]), float(toks[i + 3])); i += 4
                if ctrl_first is None and pts:
                    ctrl_first = c1
                ctrl_last = c1
                pts.append(cur)
            else:
                i += 1
        start_dir = (ctrl_first or (pts[1] if len(pts) > 1 else pts[0]))
        end_dir = ctrl_last or (pts[-2] if len(pts) > 1 else pts[0])
        return pts, start_dir, end_dir

    def marker(self, kind, tip, frm, color_i):
        """Arrow heads and crow's feet at `tip`, pointing along frm -> tip."""
        dx, dy = tip[0] - frm[0], tip[1] - frm[1]
        ln = math.hypot(dx, dy) or 1
        ux, uy = dx / ln, dy / ln
        px, py = -uy, ux
        if kind in ('ah', 'ahg'):
            s = 8
            a = (tip[0] - ux * s + px * s * 0.45, tip[1] - uy * s + py * s * 0.45)
            b = (tip[0] - ux * s - px * s * 0.45, tip[1] - uy * s - py * s * 0.45)
            self.ops.append(['g', r(tip[0]), r(tip[1]), r(a[0]), r(a[1]), r(b[0]), r(b[1]), color_i])
        elif kind == 'crow':  # crow's foot: converges on the line, fans out at the table
            s = 11
            base = (tip[0] - ux * s, tip[1] - uy * s)
            for off in (-6, 0, 6):
                end = (tip[0] + px * off, tip[1] + py * off)
                self.ops.append(['l', r(base[0]), r(base[1]), r(end[0]), r(end[1]), color_i, 1.2, 0, 1])
        elif kind == 'one':
            s = 9
            c = (tip[0] - ux * 9, tip[1] - uy * 9)
            self.ops.append(['l', r(c[0] + px * 6), r(c[1] + py * 6), r(c[0] - px * 6), r(c[1] - py * 6), color_i, 1.8, 0, 1])

    def walk(self, node, group):
        for e in node:
            tag = e.tag.replace(NS, '')
            if tag in ('defs', 'metadata', 'title'):
                continue
            if tag == 'g':
                g = dict(group)
                g.update(e.attrib)
                self.walk(e, g)
                continue
            a = self.style(e, group)
            op = num(a.get('opacity'), 1)
            dash = 0
            if a.get('stroke-dasharray'):
                dash = int(float(a['stroke-dasharray'].split()[0]))
            sw = num(a.get('stroke-width'), 1)
            fill = self.col(a.get('fill', '#000000' if tag in ('rect', 'text', 'circle', 'ellipse', 'polygon') else 'none')) if tag != 'text' else self.col(a.get('fill'))
            stroke = self.col(a.get('stroke'))
            if tag == 'rect':
                self.ops.append(['r', r(num(a.get('x'))), r(num(a.get('y'))), r(num(a['width'])), r(num(a['height'])), r(num(a.get('rx'))), fill, stroke, sw, dash, op])
            elif tag in ('ellipse', 'circle'):
                rx = num(a.get('rx', a.get('r')))
                ry = num(a.get('ry', a.get('r')))
                self.ops.append(['e', r(num(a['cx']) - rx), r(num(a['cy']) - ry), r(rx * 2), r(ry * 2), fill, stroke, sw, dash, op])
            elif tag == 'line':
                p1 = (num(a['x1']), num(a['y1']))
                p2 = (num(a['x2']), num(a['y2']))
                self.ops.append(['l', r(p1[0]), r(p1[1]), r(p2[0]), r(p2[1]), stroke, sw, dash, op])
                self._markers(a, [p1, p2], p2, p1, p1, p2, stroke)
            elif tag == 'polygon':
                pts = [tuple(float(v) for v in p.split(',')) for p in a['points'].split()]
                d = 'M' + ' L'.join(f'{r(x)} {r(y)}' for x, y in pts) + ' Z'
                self.ops.append(['p', d, fill, stroke, sw, dash, op, 1])
            elif tag == 'path':
                d = a['d']
                pts, sdir, edir = self.poly_points(d)
                self.ops.append(['p', re.sub(r'(\d+\.\d)\d+', r'\1', d), -1 if a.get('fill') in (None, 'none') else fill, stroke, sw, dash, op, 0])
                self._markers(a, pts, pts[-1], edir, pts[0], sdir, stroke)
            elif tag == 'text':
                size = num(a.get('font-size'), 11)
                self.ops.append(['t', r(num(a['x'])), r(num(a['y'])), (e.text or ''), size, int(num(a.get('font-weight'), 400)), fill,
                                 {'middle': 1, 'end': 2}.get(a.get('text-anchor'), 0)])

    def _markers(self, a, pts, end, end_from, start, start_from, stroke):
        """Attach marker info to the op just written: [startKind, endKind, tipS, fromS, tipE, fromE]; the
        Figma script draws the heads (kinds: 1 arrow, 3 crow's foot, 4 one-bar)."""
        codes = {'ah': 1, 'ahg': 1, 'crow': 3, 'one': 4}
        m_end = (a.get('marker-end') or '').replace('url(#', '').replace(')', '')
        m_start = (a.get('marker-start') or '').replace('url(#', '').replace(')', '')
        if not (m_end or m_start):
            return
        self.ops[-1].extend([codes.get(m_start, 0), codes.get(m_end, 0), r(start[0]), r(start[1]), r(start_from[0]), r(start_from[1]),
                             r(end[0]), r(end[1]), r(end_from[0]), r(end_from[1])])


def compile_file(name):
    root = ET.parse(SRC / f'{name}.svg').getroot()
    vb = [float(v) for v in root.attrib['viewBox'].split()]
    c = Compiler()
    c.walk(root, {})
    # the first rect is the page background
    return {'n': name, 'w': r(vb[2]), 'h': r(vb[3]), 'pal': c.pal, 'ops': c.ops}


if __name__ == '__main__':
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for n in NAMES:
        d = compile_file(n)
        txt = json.dumps(d, separators=(',', ':'), ensure_ascii=False)
        (out / f'{n}.json').write_text(txt, encoding='utf-8')
        print(n, len(d['ops']), 'ops', len(txt), 'bytes')
