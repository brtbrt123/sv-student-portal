"""Draws DFD_level1.svg and UseCase_Diagram.svg (hand-laid, standard library only).
Run: python -I scripts/diagrams/build_flows.py   (writes into docs/diagrams/)."""
from html import escape
from pathlib import Path
import math

OUT = Path(__file__).resolve().parents[2] / 'docs' / 'diagrams'
INK, MUTED, PAPER, LINE = '#1b1c26', '#6e6c85', '#faf9fc', '#c9c3d6'
FONT = "font-family=\"'Plus Jakarta Sans', Arial, sans-serif\""
LILAC, GOLD, TEAL, ROSE = '#ebddf6', '#fbf0b8', '#cdeed7', '#f8d0df'


def txt(x, y, s, size=11, weight=400, fill=INK, anchor='middle'):
    return f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{escape(s)}</text>'


def lines(x, y, s, size=11, weight=400, fill=INK, lh=14):
    parts = s.split('\n')
    y0 = y - (len(parts) - 1) * lh / 2 + size * 0.35
    return ''.join(txt(x, y0 + i * lh, p, size, weight, fill) for i, p in enumerate(parts))


DEFS = ('<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">'
        f'<path d="M0 0 10 5 0 10z" fill="{INK}"/></marker>'
        '<marker id="ahg" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">'
        '<path d="M0 0 10 5 0 10z" fill="#8a86a0"/></marker></defs>')


# ------------------------------------------------------------------------------------------- DFD
class Dfd:
    def __init__(self):
        self.out = []
        self.nodes = {}  # key -> (cx, cy, w, h)

    def node(self, key, kind, cx, cy, label, w=None, h=None):
        if kind == 'entity':
            w, h = w or 130, h or 40
            self.out.append(f'<rect x="{cx - w / 2}" y="{cy - h / 2}" width="{w}" height="{h}" fill="#ffffff" stroke="{INK}" stroke-width="1.4"/>')
            self.out.append(f'<rect x="{cx - w / 2 + 4}" y="{cy - h / 2 + 4}" width="{w - 8}" height="{h - 8}" fill="none" stroke="{LINE}"/>')
            self.out.append(lines(cx, cy, label, 11.5, 700))
        elif kind == 'process':
            w, h = w or 180, h or 64
            self.out.append(f'<rect x="{cx - w / 2}" y="{cy - h / 2}" width="{w}" height="{h}" rx="14" fill="{LILAC}" stroke="{INK}" stroke-width="1.4"/>')
            self.out.append(lines(cx, cy, label, 12, 800))
        elif kind == 'store':
            w, h = w or 190, h or 38
            self.out.append(f'<rect x="{cx - w / 2}" y="{cy - h / 2}" width="{w}" height="{h}" fill="{GOLD}" stroke="{INK}" stroke-width="1.4"/>')
            self.out.append(f'<path d="M{cx - w / 2 + 34} {cy - h / 2} V{cy + h / 2}" stroke="{INK}" stroke-width="1.4"/>')
            import re as _re
            if _re.match(r'^D\d+ ', label):
                head_, tail_ = label.split(' ', 1)
                self.out.append(txt(cx - w / 2 + 17, cy + 4, head_, 11, 800))
                self.out.append(txt(cx + 17, cy + 4, tail_, 11, 600))
            else:
                self.out.append(lines(cx, cy, label, 10.5, 600))
        self.nodes[label] = (cx, cy, w, h)
        return label

    @staticmethod
    def _clip(c, toward):
        cx, cy, w, h = c
        dx, dy = toward[0] - cx, toward[1] - cy
        if dx == 0 and dy == 0:
            return cx, cy
        sx = (w / 2) / abs(dx) if dx else 1e9
        sy = (h / 2) / abs(dy) if dy else 1e9
        s = min(sx, sy)
        return cx + dx * s, cy + dy * s

    def flow(self, a, b, label='', dashed=False, bend=0, both=False, lx=0, ly=0):
        ca, cb = self.nodes[a], self.nodes[b]
        p1 = self._clip(ca, (cb[0], cb[1]))
        p2 = self._clip(cb, (ca[0], ca[1]))
        mx, my = (p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2
        dx, dy = p2[0] - p1[0], p2[1] - p1[1]
        ln = math.hypot(dx, dy) or 1
        nx, ny = -dy / ln, dx / ln
        col = '#8a86a0' if dashed else INK
        dash = ' stroke-dasharray="6 4"' if dashed else ''
        marker = 'ahg' if dashed else 'ah'
        start = f' marker-start="url(#{marker})"' if both else ''
        if bend:
            cx_, cy_ = mx + nx * bend, my + ny * bend
            self.out.append(f'<path d="M{p1[0]:.1f} {p1[1]:.1f} Q{cx_:.1f} {cy_:.1f} {p2[0]:.1f} {p2[1]:.1f}" fill="none" stroke="{col}" stroke-width="1.3"{dash} marker-end="url(#{marker})"{start}/>')
            lxp, lyp = (mx + cx_) / 2, (my + cy_) / 2
        else:
            self.out.append(f'<line x1="{p1[0]:.1f}" y1="{p1[1]:.1f}" x2="{p2[0]:.1f}" y2="{p2[1]:.1f}" stroke="{col}" stroke-width="1.3"{dash} marker-end="url(#{marker})"{start}/>')
            lxp, lyp = mx, my
        if label:
            parts = label.split('\n')
            w = max(len(p) for p in parts) * 5.4 + 8
            h = len(parts) * 12 + 4
            self.out.append(f'<rect x="{lxp + lx - w / 2:.1f}" y="{lyp + ly - h / 2:.1f}" width="{w:.1f}" height="{h}" rx="3" fill="{PAPER}" opacity="0.92"/>')
            self.out.append(lines(lxp + lx, lyp + ly, label, 9.5, 500, '#3a3950', 12))


def dfd():
    d = Dfd()
    W, H = 2300, 1830
    d.out.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" {FONT}>{DEFS}')
    d.out.append(f'<rect width="{W}" height="{H}" fill="{PAPER}"/>')
    d.out.append(txt(40, 44, 'Data Flow Diagram, Level 1: Centralized Student Portal', 22, 800, INK, 'start'))
    d.out.append(txt(40, 66, '13 processes, 14 data stores, 10 sections. Same entity or store can appear in several sections. Dashed arrows are automatic changes made by database triggers.', 12, 400, MUTED, 'start'))

    def section(x, y, w, h, title):
        d.out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="#ffffff" stroke="{LINE}" stroke-width="1.3"/>')
        d.out.append(f'<rect x="{x}" y="{y}" width="{w}" height="30" rx="12" fill="{LILAC}" stroke="{LINE}"/>')
        d.out.append(f'<rect x="{x}" y="{y + 16}" width="{w}" height="14" fill="{LILAC}"/>')
        d.out.append(txt(x + 20, y + 20, title, 13, 800, INK, 'start'))

    # unique node keys: use "<section>:<label>" so repeated entities and stores are separate drawings
    def ent(sec, cx, cy, label, **kw):
        d.node(f'{sec}:{label}', 'entity', cx, cy, label, **kw)
        d.nodes[f'{sec}:{label}'] = d.nodes.pop(label)
        return f'{sec}:{label}'

    def proc(sec, cx, cy, label, **kw):
        d.node(f'{sec}:{label}', 'process', cx, cy, label, **kw)
        d.nodes[f'{sec}:{label}'] = d.nodes.pop(label)
        return f'{sec}:{label}'

    def store(sec, cx, cy, label, **kw):
        d.node(f'{sec}:{label}', 'store', cx, cy, label, **kw)
        d.nodes[f'{sec}:{label}'] = d.nodes.pop(label)
        return f'{sec}:{label}'

    X0, Y0, CW, CH, G = 40, 90, 725, 410, 20

    def cell(col, row, span=1):
        return X0 + col * (CW + G), Y0 + row * (CH + G), CW * span + G * (span - 1), CH

    # A. Authentication ------------------------------------------------------------------
    x, y, w, h = cell(0, 0)
    section(x, y, w, h, 'A. Authentication')
    u = ent('A', x + 116, y + 120, 'User\n(any role)')
    p = proc('A', x + 370, y + 120, '1.0\nAuthenticate\nusers', h=76)
    sa = ent('A', x + 370, y + 335, 'Supabase Auth', w=150)
    d2 = store('A', x + 580, y + 215, 'D2 Login attempts', w=170)
    d1 = store('A', x + 580, y + 60 + 25, 'D1 Accounts', w=170)
    d.flow(u, p, 'student ID or email,\npassword', ly=-12)
    d.flow(p, u, 'session or\nlockout notice', bend=-34, ly=14)
    d.flow(p, sa, 'credentials', lx=-36)
    d.flow(sa, p, 'verified user', bend=26, lx=52)
    d.flow(p, d2, 'attempts, lock check', both=True)
    d.flow(d1, p, 'role, active flag')

    # B. Admissions ----------------------------------------------------------------------
    x, y, w, h = cell(1, 0)
    section(x, y, w, h, 'B. Admissions (public apply form)')
    ap = ent('B', x + 109, y + 90, 'Applicant\n(New or Transferee)', w=130)
    rg = ent('B', x + 109, y + 300, 'Registrar')
    p = proc('B', x + 362, y + 195, '2.0\nProcess\nadmissions', h=76)
    d11 = store('B', x + 594, y + 62, 'D11 Applications', w=160)
    d3 = store('B', x + 594, y + 128, 'D3 Academic catalog', w=160)
    d12 = store('B', x + 594, y + 194, 'D12 Program curriculum', w=160)
    d1 = store('B', x + 594, y + 276, 'D1 Accounts', w=160)
    d4 = store('B', x + 594, y + 350, 'D4 Enrollments', w=160)
    d.flow(ap, p, 'application: name, email,\nprogram, new or transfer', lx=-30, ly=-22)
    d.flow(p, ap, 'acceptance email: student ID,\nset-password link', bend=-44, lx=40, ly=34)
    d.flow(rg, p, 'accept or\nreject, remarks')
    d.flow(p, d11, 'application,\nstatus', both=True)
    d.flow(d3, p, 'programs')
    d.flow(d12, p, 'first-year\nsubjects')
    d.flow(p, d1, 'new student\naccount')
    d.flow(p, d4, 'Pending first-year\nenrollment (trigger)', dashed=True)

    # C. Enrollment ----------------------------------------------------------------------
    x, y, w, h = cell(2, 0)
    section(x, y, w, h, 'C. Enrollment')
    st = ent('C', x + 109, y + 105, 'Student')
    rg = ent('C', x + 109, y + 285, 'Registrar')
    p = proc('C', x + 362, y + 195, '3.0\nManage\nenrollment', h=76)
    d4 = store('C', x + 594, y + 110, 'D4 Enrollments', w=160)
    d3 = store('C', x + 594, y + 285, 'D3 Academic catalog', w=160)
    d.flow(st, p, 'subjects and sections', ly=-6)
    d.flow(p, st, 'enrollment status', bend=-30, ly=12)
    d.flow(rg, p, 'approve, reject,\ndrop subject')
    d.flow(p, d4, 'enrollment,\nitems', both=True)
    d.flow(d3, p, 'sections,\ncapacity')

    # D. Grades --------------------------------------------------------------------------
    x, y, w, h = cell(0, 1)
    section(x, y, w, h, 'D. Grades')
    rg = ent('D', x + 109, y + 105, 'Registrar')
    st = ent('D', x + 109, y + 285, 'Student')
    p = proc('D', x + 362, y + 195, '4.0\nManage\ngrades', h=76)
    d5 = store('D', x + 594, y + 110, 'D5 Grades', w=160)
    d4 = store('D', x + 594, y + 285, 'D4 Enrollments', w=160)
    d.flow(rg, p, 'grade codes')
    d.flow(p, st, 'grades, GWA', ly=8)
    d.flow(p, d5, 'grades,\ngrade scale', both=True)
    d.flow(d4, p, 'approved items')

    # E. Payments ------------------------------------------------------------------------
    x, y, w, h = cell(1, 1)
    section(x, y, w, h, 'E. Payments and finance clearance')
    cs = ent('E', x + 109, y + 120, 'Cashier')
    p = proc('E', x + 362, y + 200, '5.0\nProcess\npayments', h=76)
    st = ent('E', x + 109, y + 300, 'Student')
    d6 = store('E', x + 594, y + 110, 'D6 Finance', w=160)
    d7 = store('E', x + 594, y + 300, 'D7 Clearances', w=160)
    d.flow(cs, p, 'payments, charge\nstatus', ly=-8)
    d.flow(p, st, 'balance', ly=6)
    d.flow(p, d6, 'charges,\npayments', both=True)
    d.flow(p, d7, 'Finance item cleared\n(trigger)', dashed=True)

    # F. Clearance (spans two columns) ---------------------------------------------------
    x, y, w, h = cell(0, 2, 2)
    section(x, y, w, h, 'F. Clearance (request, department approval, final approval)')
    st = ent('F', x + 109, y + 90, 'Student')
    dh = ent('F', x + 109, y + 220, 'Department\nHead')
    rg = ent('F', x + 109, y + 340, 'Registrar')
    p5 = proc('F', x + 420, y + 90, '6.0\nInitiate and track\nclearance', h=76, w=190)
    p6 = proc('F', x + 420, y + 220, '7.0\nClear departments,\nmanage holds', h=76, w=190)
    p7 = proc('F', x + 420, y + 340, '8.0\nIssue final\nclearance', h=70, w=190)
    d7 = store('F', x + 1015, y + 130, 'D7 Clearances', w=170)
    d8 = store('F', x + 1015, y + 220, 'D8 Academic holds', w=170)
    d1 = store('F', x + 1015, y + 330, 'D1 Accounts', w=150)
    d.flow(st, p5, 'request clearance', ly=-8)
    d.flow(p5, st, 'status per office', bend=-26, ly=12)
    d.flow(p5, d7, 'clearance, one item\nper department', dashed=False, lx=8, ly=-14)
    d.flow(dh, p6, 'place or lift hold,\napprove item')
    d.flow(p6, d8, 'holds', both=True)
    d.flow(p6, d7, 'item cleared', lx=-4, ly=-20)
    d.flow(d1, p6, 'department of head')
    d.flow(rg, p7, 'final approval')
    d.flow(p7, d7, 'approved (all items\ncleared, trigger)', dashed=True, lx=34, ly=22)

    # G. Document requests ---------------------------------------------------------------
    x, y, w, h = cell(2, 1)
    section(x, y, w, h, 'G. Document requests')
    st = ent('G', x + 109, y + 110, 'Student')
    rg = ent('G', x + 109, y + 290, 'Registrar')
    p = proc('G', x + 362, y + 200, '9.0\nProcess document\nrequests', h=76, w=170)
    d9 = store('G', x + 594, y + 110, 'D9 Document requests', w=160)
    d.flow(st, p, 'request (1 to 5\ndocuments), purpose', ly=-4)
    d.flow(p, st, 'ticket number,\nstatus', bend=-30, ly=14)
    d.flow(rg, p, 'process, reject,\nrelease')
    d.flow(p, d9, 'requests', both=True)

    # H. Queue ---------------------------------------------------------------------------
    x, y, w, h = cell(2, 2)
    section(x, y, w, h, 'H. Virtual queue (Registrar window)')
    st = ent('H', x + 109, y + 110, 'Student')
    rg = ent('H', x + 109, y + 295, 'Registrar')
    p = proc('H', x + 362, y + 200, '10.0\nManage the\nqueue', h=76)
    d13 = store('H', x + 594, y + 110, 'D13 Queue', w=160)
    d1 = store('H', x + 594, y + 300, 'D1 Accounts', w=160)
    d.flow(st, p, 'get ticket,\ncancel ticket', ly=-6)
    d.flow(p, st, 'ticket number,\nQR, status', bend=-30, ly=14)
    d.flow(rg, p, 'scan QR, call next,\nhold, no-show, done')
    d.flow(p, d13, 'tickets, counters', both=True)
    d.flow(d1, p, 'student card')

    # I. Notifications -------------------------------------------------------------------
    x, y, w, h = cell(0, 3)
    section(x, y, w, h, 'I. Notifications')
    us = ent('I', x + 109, y + 200, 'Student or\nstaff user')
    p = proc('I', x + 362, y + 200, '11.0\nSend and show\nnotifications', h=76)
    d14 = store('I', x + 594, y + 110, 'D14 Notifications', w=160)
    ev = store('I', x + 594, y + 300, 'D4, D7, D9, D13, D5, D8, D11', w=170, h=44)
    d.flow(ev, p, 'events: status\nchanges (trigger)', dashed=True)
    d.flow(p, d14, 'notification', both=False)
    d.flow(p, us, 'bell, unread count,\nlist', bend=-30, ly=14)
    d.flow(us, p, 'mark as read', ly=-8)

    # J. Administration and audit --------------------------------------------------------
    x, y, w, h = cell(1, 3, 2)
    section(x, y, w, h, 'J. Administration and audit trail')
    ad = ent('J', x + 109, y + 110, 'Admin')
    p9 = proc('J', x + 420, y + 110, '12.0\nManage accounts,\nroles and catalog', h=76, w=190)
    p10 = proc('J', x + 420, y + 300, '13.0\nRecord audit\ntrail', h=76, w=170)
    d1 = store('J', x + 800, y + 70, 'D1 Accounts', w=150)
    d3 = store('J', x + 800, y + 150, 'D3 Academic catalog', w=180)
    d10 = store('J', x + 800, y + 300, 'D10 Audit log', w=160)
    ch = store('J', x + 109, y + 370, 'Critical changes in\nD1, D3, D4, D5, D6, D7', w=200, h=44)
    d.flow(ad, p9, 'users, roles,\ncatalog changes', ly=-18)
    d.flow(p9, ad, 'confirmation', bend=-24, ly=26)
    d.flow(p9, d1, 'accounts', both=True)
    d.flow(p9, d3, 'catalog', both=True)
    d.flow(ch, p10, 'row changes (trigger)', dashed=True)
    d.flow(p10, d10, 'audit entries\n(append only)')
    d.flow(p10, ad, 'audit log\n(read-only)', lx=-30)

    d.out.append('</svg>')
    return '\n'.join(d.out)


# ----------------------------------------------------------------------------------- Use cases
def usecase():
    out = []
    W, H = 1840, 1260
    out.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" {FONT}>{DEFS}')
    out.append(f'<rect width="{W}" height="{H}" fill="{PAPER}"/>')
    out.append(txt(40, 44, 'Use Case Diagram: Centralized Student Portal', 22, 800, INK, 'start'))
    out.append(txt(40, 66, '6 actors. Solid line: association. Dashed arrow: include or extend. Orange line: every signed-in actor logs in with Supabase Auth. Blue line: every signed-in actor sees notifications.', 12, 400, MUTED, 'start'))
    bx, by, bw, bh = 250, 90, 1330, 1130
    out.append(f'<rect x="{bx}" y="{by}" width="{bw}" height="{bh}" rx="14" fill="#ffffff" stroke="{LINE}" stroke-width="1.5"/>')
    out.append(txt(bx + 16, by + 20, 'Centralized Student Portal and Automated Clearance System', 13, 800, MUTED, 'start'))

    cases = {}

    def uc(key, cx, cy, label, w=280, h=46, fill='#ffffff'):
        out.append(f'<ellipse cx="{cx}" cy="{cy}" rx="{w / 2}" ry="{h / 2}" fill="{fill}" stroke="{INK}" stroke-width="1.3"/>')
        out.append(lines(cx, cy, label, 11, 500))
        cases[key] = (cx, cy, w / 2, h / 2)

    def clip(key, toward):
        cx, cy, rx, ry = cases[key]
        dx, dy = toward[0] - cx, toward[1] - cy
        k = 1 / math.sqrt((dx / rx) ** 2 + (dy / ry) ** 2) if (dx or dy) else 0
        return cx + dx * k, cy + dy * k

    def assoc(start, key):
        x2, y2 = clip(key, start)
        out.append(f'<line x1="{start[0]}" y1="{start[1]}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{INK}" stroke-width="1.2"/>')

    def poly(points, color, width=1.4, opacity=0.8):
        d = 'M' + ' L'.join(f'{x} {y}' for x, y in points)
        out.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}" opacity="{opacity}"/>')

    def dep(src, dst, label):
        sx, sy = cases[src][0], cases[src][1]
        dx_, dy_ = cases[dst][0], cases[dst][1]
        a = clip(src, (dx_, dy_))
        b = clip(dst, (sx, sy))
        out.append(f'<line x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}" stroke="#55526b" stroke-width="1.2" stroke-dasharray="6 4" marker-end="url(#ah)"/>')
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        out.append(f'<rect x="{mx - 30}" y="{my - 17}" width="60" height="14" rx="3" fill="#ffffff"/>')
        out.append(txt(mx, my - 6, label, 9.5, 600, '#55526b'))

    def actor(cx, cy, name, fill):
        out.append(f'<circle cx="{cx}" cy="{cy - 34}" r="11" fill="{fill}" stroke="{INK}" stroke-width="1.4"/>')
        out.append(f'<path d="M{cx} {cy - 23} V{cy + 12} M{cx - 22} {cy - 10} H{cx + 22} M{cx} {cy + 12} L{cx - 17} {cy + 40} M{cx} {cy + 12} L{cx + 17} {cy + 40}" stroke="{INK}" stroke-width="1.6" fill="none"/>')
        out.append(txt(cx, cy + 60, name, 12.5, 800))

    LX, RX, SX = 480, 1090, 760
    # shared use cases
    uc('login', 915, 130, 'Log in (Supabase Auth,\nstudent ID or email)', 300, 52, '#ffe9c7')
    uc('setpw', 915, 214, 'Set Password (first login,\n8 to 72 characters)', 280, 46)
    # applicant + student (left column)
    uc('apply', LX, 190, 'Apply for Admission\n(New student or Transferee)', 290, 50)
    stu = [('enr_v', 'View Enrollment Status'), ('enr_s', 'Submit Online Enrollment'), ('gr_v', 'View Academic Grades'),
           ('clr_r', 'Request Clearance'), ('clr_s', 'Check Clearance Status'), ('doc_s', 'Submit Document Request\n(1 to 5 documents)'),
           ('doc_t', 'Track Document Request'), ('q_get', 'Get Queue Ticket (QR code)'), ('q_can', 'Cancel Queue Ticket'),
           ('notif', 'View Notifications (bell)')]
    for i, (k, lbl) in enumerate(stu):
        uc(k, LX, 340 + i * 80, lbl)
    # staff (right column), one block per actor
    rows = {}
    y = 300
    blocks = [
        ('reg', [('app_r', 'Review Applications\n(Accept or Reject)'), ('enr_r', 'Review Enrollments\n(Approve or Reject)'), ('drop', 'Drop a Subject from a\nFirst-Year Enrollment'),
                 ('gr_e', 'Encode and Update Grades'), ('doc_p', 'Process Document Requests'), ('clr_f', 'Issue Final Clearance'),
                 ('q_run', 'Run the Queue Window\n(call, hold, no-show, done)')]),
        ('csh', [('bal', 'View Financial Balances'), ('pay', 'Log Payments and\nTag Charges Cleared')]),
        ('dpt', [('pend', 'View Students Pending Clearance'), ('hold', 'Place or Lift Academic Holds'), ('dclr', 'Approve Departmental Clearance')]),
        ('adm', [('acct', 'Create, Update and\nDeactivate Accounts'), ('role', 'Assign Roles (RBAC)'), ('cat', 'Maintain Academic Catalog'), ('audit', 'View Audit Logs')]),
    ]
    for actor_key, items in blocks:
        rows[actor_key] = []
        for k, lbl in items:
            uc(k, RX, y, lbl, 290, 44)
            rows[actor_key].append((k, y))
            y += 52
        y += 8
    # included or extending cases sit to the left of their base case
    sub = [('mkacct', 'app_r', 'Create Student Account\n(sends acceptance email)', '«include»'),
           ('reject', 'doc_p', 'Reject Document Request', '«extend»'),
           ('verify', 'clr_f', 'Verify All Departments\nand Finance Cleared', '«include»'),
           ('scan', 'q_run', 'Scan Student QR Code', '«include»'),
           ('fin', 'pay', 'Update Finance Clearance\n(automatic, REQ-CSH-03)', '«include»'),
           ('chk', 'dclr', 'Check Active Holds', '«include»')]
    for k, base, lbl, _rel in sub:
        uc(k, SX, cases[base][1], lbl, 230, 46, '#eef8f0')

    # actors
    a_app, a_stu = (110, 190), (110, 700)
    actor(*a_app, 'Applicant', '#fcd9bd')
    out.append(txt(110, 270, '(not signed in)', 10, 400, MUTED))
    actor(*a_stu, 'Student', '#cfe3f8')
    staff = {'reg': (1700, 470, 'Registrar', '#fbf0b8'), 'csh': (1700, 800, 'Cashier', '#fbd9a8'), 'dpt': (1700, 905, 'Department Head', '#f8d0df'),
             'adm': (1700, 1070, 'Admin', '#dcdce4')}
    # actors sit at the middle of their blocks
    for key, (ax, ay, name, fill) in staff.items():
        mid = rows[key][len(rows[key]) // 2][1] if len(rows[key]) % 2 else (rows[key][0][1] + rows[key][-1][1]) / 2
        staff[key] = (ax, mid, name, fill)
        actor(ax, mid, name, fill)

    ORANGE, BLUE = '#e8890c', '#4a73d8'
    # sign-in bus: left (Student) and right (staff) lines end at Log in
    poly([(88, a_stu[1] - 12), (60, a_stu[1] - 12), (60, 130), (765, 130)], ORANGE)
    rx_login, rx_notif = 1612, 1648
    right_ys = [staff[k][1] for k in staff]
    for k in staff:
        poly([(1678, staff[k][1] - 14), (rx_login, staff[k][1] - 14)], ORANGE)
    poly([(rx_login, max(right_ys) - 14), (rx_login, 130), (1065, 130)], ORANGE)
    # notifications bus: every staff actor, down the right side and along the bottom into the Student's notification case
    for k in staff:
        poly([(1678, staff[k][1] + 16), (rx_notif, staff[k][1] + 16)], BLUE)
    poly([(rx_notif, min(right_ys) + 16), (rx_notif, 1196), (cases['notif'][0], 1196), (cases['notif'][0], cases['notif'][1] + 23)], BLUE)
    # set-password and login belong to the Student too (extend arrow below)
    assoc((a_app[0] + 24, a_app[1]), 'apply')
    for k, _ in stu:
        assoc((a_stu[0] + 24, a_stu[1]), k)
    for key, (ax, ay, _n, _f) in staff.items():
        for k, _y in rows[key]:
            assoc((ax - 24, ay), k)

    for k, base, _lbl, rel in sub:
        dep(k, base, rel) if rel == '«extend»' else dep(base, k, rel)
    dep('setpw', 'login', '«extend»')
    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    (OUT / 'DFD_level1.svg').write_text(dfd(), encoding='utf-8')
    (OUT / 'UseCase_Diagram.svg').write_text(usecase(), encoding='utf-8')
    print('written')
