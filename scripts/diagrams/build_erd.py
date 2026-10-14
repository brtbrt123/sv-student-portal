"""Draws ERD_overview.svg, ERD_detailed.svg and ClassDiagram.svg from docs/database/*.sql.
Run: python -I scripts/diagrams/build_erd.py   (writes into docs/diagrams/)."""
from html import escape
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import schema_model as sm

OUT = sm.ROOT / 'docs' / 'diagrams'
INK, MUTED, PAPER, LINE = '#1b1c26', '#6e6c85', '#faf9fc', '#c9c3d6'
FONT = "font-family=\"'Plus Jakarta Sans', Arial, sans-serif\""

MODULE_COLOR = {
    'Identity & access': '#cfe3f8', 'Academic structure': '#cdeed7', 'Enrollment & grades': '#fbf0b8',
    'Admissions': '#fcd9bd', 'Finance': '#fbd9a8', 'Document requests': '#e3d6f5', 'Clearance': '#f8d0df',
    'Queue': '#c9ece8', 'Notifications': '#d9e6ff', 'Security & audit': '#dcdce4', 'External': '#ffffff',
}

EDGE_COLOR = {
    'Identity & access': '#3f7cc4', 'Academic structure': '#2f9e5b', 'Enrollment & grades': '#b8940a', 'Admissions': '#d9772b',
    'Finance': '#c98a1b', 'Document requests': '#8450c8', 'Clearance': '#c2407a', 'Queue': '#1f9d93', 'Notifications': '#4a73d8',
    'Security & audit': '#7a7692',
}

# Layout: columns of tables (left to right, top to bottom).
COLUMNS = [
    ['auth.users', 'roles', 'profiles', 'students', 'department_staff', 'login_attempts', 'audit_logs'],
    ['departments', 'programs', 'terms', 'subjects', 'sections', 'program_curriculum'],
    ['applications', 'grade_scale', 'enrollments', 'enrollment_items', 'grades'],
    ['fee_types', 'charges', 'payments', 'document_types', 'document_requests'],
    ['clearances', 'clearance_items', 'academic_holds', 'notifications'],
    ['queue_services', 'queue_tickets', 'queue_counters'],
]
# Overview grid (column, row): related tables sit next to each other.
GRID = {
    'roles': (0, 0), 'profiles': (0, 1), 'auth.users': (0, 2), 'notifications': (0, 4), 'audit_logs': (0, 5), 'login_attempts': (0, 6),
    'department_staff': (1, 1), 'students': (1, 3), 'applications': (1, 5),
    'departments': (2, 0), 'subjects': (2, 1), 'sections': (2, 2), 'enrollments': (2, 3), 'grade_scale': (2, 5),
    'programs': (3, 0), 'program_curriculum': (3, 1), 'terms': (3, 2), 'enrollment_items': (3, 3), 'grades': (3, 4),
    'payments': (4, 0), 'charges': (4, 1), 'clearances': (4, 2), 'clearance_items': (4, 3), 'document_requests': (4, 4), 'queue_tickets': (4, 5),
    'fee_types': (5, 1), 'academic_holds': (5, 3), 'document_types': (5, 4), 'queue_services': (5, 5), 'queue_counters': (5, 6),
}
AUTH_USERS = {'cols': [['id', 'uuid', False]], 'pk': ['id'], 'fks': []}


def module_of(name):
    for m, names in sm.MODULES.items():
        if name in names:
            return m
    return 'External'


def t(x, y, s, size=11, weight=400, fill=INK, anchor='start', extra=''):
    return f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}" {extra}>{escape(str(s))}</text>'


def build(tables, mode):
    """mode: 'overview' (names only), 'detailed' (columns + types, all FK links) or 'class' (UML style)."""
    tb = dict(tables)
    tb['auth.users'] = AUTH_USERS
    colw = {'overview': 190, 'detailed': 250, 'class': 250}[mode]
    gapx = {'overview': 120, 'detailed': 130, 'class': 130}[mode]
    gapy = {'overview': 22, 'detailed': 34, 'class': 34}[mode]
    head, row = {'overview': (30, 0), 'detailed': (26, 15), 'class': (34, 15)}[mode]
    top = 110
    pos = {}
    if mode == 'overview':
        for name, (c, r) in GRID.items():
            pos[name] = (50 + c * (colw + 90), top + r * 74, colw, head)
        COLS = []
    else:
        COLS = COLUMNS
    for ci, col in enumerate(COLS):
        y = top
        x = 50 + ci * (colw + gapx)
        for name in col:
            n = len(tb[name]['cols'])
            h = head + (n * row + 8 if row else 0)
            pos[name] = (x, y, colw, h)
            y += h + gapy
    width = 50 + (6 if mode == 'overview' else len(COLUMNS)) * (colw + (90 if mode == 'overview' else gapx)) - (90 if mode == 'overview' else gapx) + 50
    height = max(p[1] + p[3] for p in pos.values()) + 150
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}" {FONT}>',
           f'<rect width="{width}" height="{height}" fill="{PAPER}"/>']
    title = {'overview': 'Overview ERD', 'detailed': 'Detailed ERD', 'class': 'Class Diagram'}[mode]
    sub = {
        'overview': '29 tables and auth.users, colored by module. Actor links to profiles (reviewed_by, cleared_by, ...) are left out; see the detailed ERD.',
        'detailed': 'Every column with type, keys and nullable marks (PK primary key, FK foreign key, ? nullable). Dashed lines are the "who did it" links to profiles.',
        'class': 'One class per table, generated from docs/database/*.sql. Actor links to profiles stay as FK attributes.',
    }[mode]
    out.append(t(50, 44, f'{title}: Centralized Student Portal', 22, 800))
    out.append(t(50, 66, sub, 12, 400, MUTED))

    # Legend
    lx = 50
    for m, c in MODULE_COLOR.items():
        if m == 'External':
            continue
        out.append(f'<rect x="{lx}" y="80" width="14" height="14" rx="3" fill="{c}" stroke="{LINE}"/>')
        out.append(t(lx + 20, 91, m, 11, 400, INK))
        lx += 20 + len(m) * 6.2 + 22

    actor_cols = {'reviewed_by', 'cleared_by', 'placed_by', 'lifted_by', 'recorded_by', 'encoded_by', 'processed_by',
                  'approved_by', 'actor_id', 'handled_by'}

    def edge_pts(a, b, idx, total):
        ax, ay, aw, ah = pos[a]
        bx, by, bw, bh = pos[b]
        acx, bcx = ax + aw / 2, bx + bw / 2
        # spread the attachment point along the side so links do not overlap
        off = (idx - (total - 1) / 2) * 6
        if mode == 'overview':
            if abs(acx - bcx) < 5:
                lo, hi = (a, b) if ay < by else (b, a)
                if abs(ay - by) <= 80:  # neighbours: straight vertical link
                    return f'M{acx + off:.1f} {pos[lo][1] + pos[lo][3]:.1f} L{acx + off:.1f} {pos[hi][1]:.1f}', None
                xr = ax + aw + 30
                return f'M{ax + aw:.1f} {ay + ah / 2 + off:.1f} C{xr + 30:.1f} {ay + ah / 2:.1f} {xr + 30:.1f} {by + bh / 2:.1f} {bx + bw:.1f} {by + bh / 2 + off:.1f}', None
            if acx < bcx:
                x1, x2 = ax + aw, bx
            else:
                x1, x2 = ax, bx + bw
            return f'M{x1:.1f} {ay + ah / 2 + off:.1f} L{x2:.1f} {by + bh / 2 + off:.1f}', None
        if abs(acx - bcx) < 5:  # same column: loop out on the right side
            y1, y2 = ay + ah / 2 + off, by + bh / 2 + off
            xr = ax + aw + 26 + (idx % 3) * 8
            return f'M{ax + aw:.1f} {y1:.1f} C{xr + 40:.1f} {y1:.1f} {xr + 40:.1f} {y2:.1f} {bx + bw:.1f} {y2:.1f}', None
        if acx < bcx:
            x1, x2 = ax + aw, bx
        else:
            x1, x2 = ax, bx + bw
        y1, y2 = ay + ah / 2 + off, by + bh / 2 + off
        mid = (x1 + x2) / 2
        return f'M{x1:.1f} {y1:.1f} C{mid:.1f} {y1:.1f} {mid:.1f} {y2:.1f} {x2:.1f} {y2:.1f}', None

    edges = []
    for name, d in tb.items():
        for (col, ref, _rc) in d['fks']:
            actor = col in actor_cols and ref == 'profiles'
            if actor and mode != 'detailed':
                continue
            edges.append((name, ref, col, actor))
    edges.append(('profiles', 'auth.users', 'profile_id', False))
    seen = {}
    for e in edges:
        seen[e[0]] = seen.get(e[0], 0) + 1
    counters = {}
    out.append('<defs><marker id="crow" viewBox="0 0 12 12" refX="11" refY="6" markerWidth="9" markerHeight="9" orient="auto"><path d="M0 0 L11 6 L0 12" fill="none" stroke="#7a7692" stroke-width="1.2"/></marker>'
               '<marker id="one" viewBox="0 0 12 12" refX="6" refY="6" markerWidth="9" markerHeight="9" orient="auto"><path d="M6 1 V11" stroke="#7a7692" stroke-width="1.6"/></marker></defs>')
    for (a, b, col, actor) in edges:
        i = counters.get(a, 0)
        counters[a] = i + 1
        path, _ = edge_pts(a, b, i, seen[a])
        dash = ' stroke-dasharray="5 4"' if actor else ''
        out.append(f'<path d="{path}" fill="none" stroke="{"#b6b0c8" if actor else EDGE_COLOR.get(module_of(a), "#7a7692")}" stroke-width="1.2"{dash} marker-start="url(#crow)" marker-end="url(#one)" opacity="0.9"/>')

    # Boxes on top of the lines
    for name, (x, y, w, h) in pos.items():
        d = tb[name]
        m = module_of(name)
        color = MODULE_COLOR[m]
        pk = set(d['pk'])
        fk = {c for c, _r, _x in d['fks']}
        out.append(f'<g><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="#ffffff" stroke="{INK}" stroke-width="1.2"/>')
        out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{head}" rx="8" fill="{color}" stroke="{INK}" stroke-width="1.2"/>')
        out.append(f'<rect x="{x + 1}" y="{y + head - 9}" width="{w - 2}" height="9" fill="{color}"/>')
        out.append(f'<line x1="{x}" y1="{y + head}" x2="{x + w}" y2="{y + head}" stroke="{INK}" stroke-width="1.2"/>')
        if mode == 'class':
            out.append(t(x + w / 2, y + 13, '«table»', 9.5, 400, MUTED, 'middle'))
            out.append(t(x + w / 2, y + 28, name, 13, 800, INK, 'middle'))
        else:
            out.append(t(x + w / 2, y + head / 2 + 5, name, 13 if mode == 'overview' else 12.5, 800, INK, 'middle'))
        if row:
            for i, (cname, ctype, nullable) in enumerate(d['cols']):
                cy = y + head + 15 + i * row - 2
                keys = ('PK' if cname in pk else '') + (' FK' if cname in fk else '')
                label = (('+ ' + cname) if mode == 'class' else cname)
                out.append(t(x + 10, cy, label, 10.5, 700 if cname in pk else 400))
                right = ctype + ('?' if nullable and cname not in pk else '')
                if mode == 'class':
                    right = (': ' if False else '') + right
                out.append(t(x + w - 10, cy, right, 10, 400, MUTED, 'end'))
                if keys.strip():
                    out.append(t(x + w - 10 - len(right) * 5.4 - 8, cy, keys.strip(), 8.5, 800, '#9a5b00' if 'PK' in keys else '#3b5bdb', 'end'))
        out.append('</g>')
    out.append('</svg>')
    return '\n'.join(out), width, height


def main():
    tables = sm.load()
    placed = {n for col in COLUMNS for n in col} - {'auth.users'}
    assert placed == set(tables), (placed ^ set(tables))
    for mode, fname in [('overview', 'ERD_overview.svg'), ('detailed', 'ERD_detailed.svg')]:
        svg, w, h = build(tables, mode)
        (OUT / fname).write_text(svg, encoding='utf-8')
        print(fname, w, 'x', h)


if __name__ == '__main__':
    main()
