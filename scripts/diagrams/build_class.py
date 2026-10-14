"""Draws ClassDiagram.svg: a UML class diagram of the portal (classes with attributes and operations,
generalization, associations with multiplicities, composition). Hand-laid on a grid; standard library only.
Run: python -I scripts/diagrams/build_class.py   (writes docs/diagrams/ClassDiagram.svg)."""
import sys
from html import escape
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / 'docs' / 'diagrams' / 'ClassDiagram.svg'
INK, MUTED, PAPER = '#1b1c26', '#6e6c85', '#faf9fc'
FONT = "font-family=\"'Plus Jakarta Sans', Arial, sans-serif\""
COL = {'user': '#cfe3f8', 'acad': '#cdeed7', 'enr': '#fbf0b8', 'adm': '#fcd9bd', 'fin': '#fbd9a8',
       'doc': '#e3d6f5', 'clr': '#f8d0df', 'que': '#c9ece8', 'not': '#d9e6ff', 'aud': '#dcdce4'}
W, ROW_H, HEAD, LINE_H, PAD = 250, 16, 30, 16, 8
STEP_X, GAP_Y, X0, Y0 = 310, 110, 40, 100

# name: (module, attributes, operations, column, row)
C = {
 'Notification': ('not', ['kind: String', 'title: String', 'body: String', 'link: String', 'readAt: DateTime'], ['markAsRead()'], 2, 0),
 'User': ('user', ['userId: UUID', 'firstName: String', 'lastName: String', 'email: String', 'isActive: Boolean'],
          ['login()', 'logout()', 'setPassword()', 'viewNotifications()'], 3, 0),
 'AuditLog': ('aud', ['action: String', 'tableName: String', 'recordId: String', 'oldData: JSON', 'newData: JSON', 'createdAt: DateTime'], ['(written by triggers only)'], 4, 0),
 'Student': ('user', ['studentNumber: String'], ['viewGrades()', 'submitEnrollment()', 'requestClearance()', 'requestDocument()', 'getQueueTicket()', 'holdTicket()', 'cancelTicket()'], 1, 1),
 'Registrar': ('user', [], ['reviewApplication()', 'reviewEnrollment()', 'dropSubject()', 'encodeGrade()', 'processDocument()', 'issueFinalClearance()', 'runQueueWindow()'], 2, 1),
 'Cashier': ('user', [], ['viewBalance()', 'logPayment()', 'tagCharge()'], 3, 1),
 'DepartmentHead': ('user', ['departmentId: Long'], ['viewPendingStudents()', 'placeHold()', 'liftHold()', 'approveItem()'], 4, 1),
 'Admin': ('user', [], ['createStaffAccount()', 'changeRole()', 'deactivateUser()', 'maintainCatalog()', 'viewAuditLog()'], 5, 1),
 'Enrollment': ('enr', ['yearLevel: Integer', 'status: String', 'submittedAt: DateTime', 'reviewedAt: DateTime', 'remarks: String'], ['submit()', 'approve()', 'reject()'], 1, 2),
 'Clearance': ('clr', ['createdAt: DateTime', 'approvedAt: DateTime'], ['approve()', 'isReady()'], 2, 2),
 'AcademicHold': ('clr', ['reason: String', 'placedAt: DateTime', 'liftedAt: DateTime'], ['lift()', 'isActive()'], 3, 2),
 'Charge': ('fin', ['amount: Decimal', 'dueDate: Date', 'status: String'], ['tagCleared()', 'tagWaived()', 'balance()'], 4, 2),
 'DocumentRequest': ('doc', ['ticketNumber: String', 'documentType: String', 'purpose: String', 'copies: Integer', 'status: String'], ['process()', 'release()', 'reject()'], 5, 2),
 'QueueTicket': ('que', ['ticketCode: Integer', 'status: String', 'queueDate: Date', 'heldAt: DateTime'], ['issue()', 'callNext()', 'hold()', 'finish()', 'cancel()'], 6, 2),
 'Application': ('adm', ['firstName: String', 'lastName: String', 'email: String', 'applicantType: String', 'status: String'], ['submit()', 'accept()', 'reject()'], 7, 2),
 'Grade': ('enr', ['gradeCode: String', 'encodedAt: DateTime'], ['post()'], 0, 3),
 'EnrollmentItem': ('enr', [], ['remove()'], 1, 3),
 'ClearanceItem': ('clr', ['clearedAt: DateTime', 'remarks: String'], ['clear()'], 2, 3),
 'Payment': ('fin', ['amountPaid: Decimal', 'paidAt: DateTime', 'receiptNumber: String'], ['record()'], 4, 3),
 'QueueService': ('que', ['serviceCode: String', 'serviceName: String', 'isOpen: Boolean'], ['openClose()'], 6, 3),
 'Program': ('acad', ['code: String', 'name: String'], [], 7, 3),
 'GradeScale': ('enr', ['numericValue: Decimal', 'isPassing: Boolean'], [], 0, 4),
 'Section': ('acad', ['sectionCode: String', 'schedule: String', 'capacity: Integer'], ['hasFreeSeat()'], 1, 4),
 'Subject': ('acad', ['code: String', 'title: String', 'units: Integer'], [], 2, 4),
 'Department': ('acad', ['code: String', 'name: String', 'departmentType: String'], [], 3, 4),
 'Term': ('acad', ['schoolYear: String', 'semester: String', 'startDate: Date', 'endDate: Date', 'isCurrent: Boolean'], ['makeCurrent()'], 1, 5),
 'ProgramCurriculum': ('acad', ['yearLevel: Integer', 'semester: String'], [], 2, 5),
}

SUBS = ['Student', 'Registrar', 'Cashier', 'DepartmentHead', 'Admin']

# (a, b, mult_a, mult_b, kind) kind: assoc | comp (diamond at a)
EDGES = [
 ('User', 'Notification', '1', '*', 'assoc'),
 ('User', 'AuditLog', '1', '*', 'assoc'),
 ('Student', 'Enrollment', '1', '*', 'assoc'),
 ('Student', 'Clearance', '1', '*', 'assoc'),
 ('Student', 'AcademicHold', '1', '*', 'assoc'),
 ('Student', 'Charge', '1', '*', 'assoc'),
 ('Student', 'DocumentRequest', '1', '*', 'assoc'),
 ('Student', 'QueueTicket', '1', '*', 'assoc'),
 ('Student', 'Application', '0..1', '0..1', 'assoc'),
 ('Enrollment', 'EnrollmentItem', '1', '1..*', 'comp'),
 ('EnrollmentItem', 'Grade', '1', '0..1', 'assoc'),
 ('Grade', 'GradeScale', '*', '1', 'assoc'),
 ('EnrollmentItem', 'Section', '*', '1', 'assoc'),
 ('Section', 'Subject', '*', '1', 'assoc'),
 ('Section', 'Term', '*', '1', 'assoc'),
 ('Clearance', 'ClearanceItem', '1', '1..*', 'comp'),
 ('ClearanceItem', 'Department', '*', '1', 'assoc'),
 ('AcademicHold', 'Department', '*', '1', 'assoc'),
 ('Charge', 'Payment', '1', '*', 'assoc'),
 ('QueueTicket', 'QueueService', '*', '1', 'assoc'),
 ('Application', 'Program', '*', '1', 'assoc'),
 ('Program', 'Department', '*', '1', 'assoc'),
 ('Subject', 'Department', '*', '1', 'assoc'),
 ('Program', 'ProgramCurriculum', '1', '*', 'side'),
 ('ProgramCurriculum', 'Subject', '*', '1', 'assoc'),
]


def height(name):
    _m, attrs, ops, _c, _r = C[name]
    return HEAD + PAD + len(attrs) * LINE_H + PAD + len(ops) * LINE_H + PAD


# layout
row_y = {}
y = Y0
for r in range(6):
    row_y[r] = y
    y += max(height(n) for n, v in C.items() if v[4] == r) + GAP_Y
BOX = {}
for n, (_m, _a, _o, c, r) in C.items():
    BOX[n] = (X0 + c * STEP_X, row_y[r], W, height(n))
CANVAS_W = X0 * 2 + 7 * STEP_X + W
CANVAS_H = y + 20 - GAP_Y + 40

out = []
lines_geo = []  # (x1, y1, x2, y2, owner_a, owner_b) for the collision check


def t(x, y_, s, size=11, weight=400, fill=INK, anchor='start'):
    return f'<text x="{x:.1f}" y="{y_:.1f}" font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{escape(s)}</text>'


def seg(x1, y1, x2, y2, a, b, dash=False):
    d = ' stroke-dasharray="6 4"' if dash else ''
    out.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="#4a4860" stroke-width="1.3"{d}/>')
    lines_geo.append((x1, y1, x2, y2, a, b))


def poly_line(points, a, b):
    for p, q in zip(points, points[1:]):
        seg(p[0], p[1], q[0], q[1], a, b)


def diamond(x, y_, direction):
    """Filled diamond at the whole end; direction = 'down' (line leaves downward) or 'up'."""
    dy = 12 if direction == 'down' else -12
    pts = f'{x},{y_} {x - 6},{y_ + dy / 2} {x},{y_ + dy} {x + 6},{y_ + dy / 2}'
    out.append(f'<polygon points="{pts}" fill="#4a4860" stroke="#4a4860" stroke-width="1"/>')


def mult(x, y_, s, anchor='start'):
    out.append(t(x, y_, s, 10.5, 600, '#3a3950', anchor))


# edges: elbow routes from the bottom of the upper box to the top of the lower box, or side to side
def route(a, b, ma, mb, kind, idx_a, idx_b, ch):
    ax, ay, aw, ah = BOX[a]
    bx, by, bw, bh = BOX[b]
    ca, cb = ax + aw / 2, bx + bw / 2
    # same row, neighbours: straight horizontal
    if abs(ay - by) < 1:
        left, right = (a, b) if ax < bx else (b, a)
        la, lb = (ma, mb) if left == a else (mb, ma)
        lx, ly, lw, lh = BOX[left]
        rx, ry, rw, rh = BOX[right]
        yy = min(ly, ry) + 20 + idx_a * 0
        seg(lx + lw, yy, rx, yy, a, b)
        mult(lx + lw + 6, yy - 5, la)
        mult(rx - 6, yy - 5, lb, 'end')
        return
    upper, lower = (a, b) if ay < by else (b, a)
    ux, uy, uw, uh = BOX[upper]
    lx, ly, lw, lh = BOX[lower]
    mu, ml = (ma, mb) if upper == a else (mb, ma)
    xu = ux + uw / 2 + idx_a
    xl = lx + lw / 2 + idx_b
    y1 = uy + uh
    if kind == 'side':
        cy = ly + lh / 2
        poly_line([(xu, y1), (xu, cy), (lx + lw, cy)], a, b)
        mult(xu + 5, y1 + 14, mu)
        mult(lx + lw + 6, cy - 5, ml)
        return
    if abs(xu - xl) < 1:
        if kind == 'comp':
            diamond(xu, y1, 'down')
        seg(xu, y1, xl, ly, a, b)
        if not (a == 'Student' and ma == '1'):
            mult(xu + 5, y1 + 14, mu)
        mult(xl + 5, ly - 5, ml)
        return
    ych = ch
    pts = [(xu, y1), (xu, ych), (xl, ych), (xl, ly)]
    if kind == 'comp' and upper == a:
        diamond(xu, y1, 'down')
    poly_line(pts, a, b)
    if not (a == 'Student' and ma == '1'):
        mult(xu + 5, y1 + 14, mu)
    mult(xl + 5, ly - 5, ml)


def build():
    out.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CANVAS_W:.0f} {CANVAS_H:.0f}" width="{CANVAS_W:.0f}" height="{CANVAS_H:.0f}" {FONT}>')
    out.append(f'<rect width="{CANVAS_W:.0f}" height="{CANVAS_H:.0f}" fill="{PAPER}"/>')
    out.append(t(40, 44, 'Class Diagram: Centralized Student Portal', 22, 800))
    out.append(t(40, 66, 'Classes of the portal with attributes (-) and operations (+). Hollow triangle: generalization. Filled diamond: composition. Line: association with multiplicities. The tables behind the classes are in the ERD.', 12, 400, MUTED))

    # generalization: User <- 5 subclasses
    ux, uy, uw, uh = BOX['User']
    cx = ux + uw / 2
    base = uy + uh
    out.append(f'<polygon points="{cx},{base} {cx - 10},{base + 18} {cx + 10},{base + 18}" fill="#ffffff" stroke="#4a4860" stroke-width="1.4"/>')
    bus_y = base + 18 + (GAP_Y - 18) / 2
    seg(cx, base + 18, cx, bus_y, 'User', 'bus')
    xs = [BOX[n][0] + W / 2 for n in SUBS]
    seg(min(xs), bus_y, max(xs), bus_y, 'User', 'bus')
    for n, x in zip(SUBS, xs):
        seg(x, bus_y, x, BOX[n][1], 'User', n)

    # associations: channels per gap
    chans = {}
    for i, (a, b, ma, mb, kind) in enumerate(EDGES):
        ra, rb = C[a][4], C[b][4]
        upper_row = min(ra, rb)
        lower_row = max(ra, rb)
        # channel y below the tallest box of the upper row
        tallest = max(BOX[n][1] + BOX[n][3] for n, v in C.items() if v[4] == upper_row)
        k = chans.get(upper_row, 0)
        chans[upper_row] = k + 1
        ch = tallest + 16 + k * 9
        ia = (k % 5 - 2) * 9 if C[a][4] < C[b][4] or a == 'Student' else (k % 5 - 2) * 9
        ib = (k % 5 - 2) * 9
        route(a, b, ma, mb, kind, ia, ib, ch)

    # boxes on top
    for n, (m, attrs, ops, c, r) in C.items():
        x, y_, w, h = BOX[n]
        out.append(f'<rect x="{x}" y="{y_}" width="{w}" height="{h}" rx="4" fill="#ffffff" stroke="{INK}" stroke-width="1.3"/>')
        out.append(f'<rect x="{x}" y="{y_}" width="{w}" height="{HEAD}" rx="4" fill="{COL[m]}" stroke="{INK}" stroke-width="1.3"/>')
        out.append(f'<rect x="{x + 1}" y="{y_ + HEAD - 6}" width="{w - 2}" height="6" fill="{COL[m]}"/>')
        out.append(f'<line x1="{x}" y1="{y_ + HEAD}" x2="{x + w}" y2="{y_ + HEAD}" stroke="{INK}" stroke-width="1.3"/>')
        style = 'italic' if n == 'User' else 'normal'
        out.append(f'<text x="{x + w / 2}" y="{y_ + 20}" font-size="13" font-weight="800" fill="{INK}" text-anchor="middle" font-style="{style}">{escape(n)}</text>')
        yy = y_ + HEAD + PAD + 12
        for a in attrs:
            out.append(t(x + 10, yy, '- ' + a, 10.5))
            yy += LINE_H
        sep = y_ + HEAD + PAD + len(attrs) * LINE_H + PAD / 2 + 1
        out.append(f'<line x1="{x}" y1="{sep}" x2="{x + w}" y2="{sep}" stroke="{INK}" stroke-width="1"/>')
        yy = sep + PAD / 2 + 12
        for o in ops:
            out.append(t(x + 10, yy, '+ ' + o if not o.startswith('(') else o, 10.5, 400, INK if not o.startswith('(') else MUTED))
            yy += LINE_H
    out.append('</svg>')


def check():
    """Report line segments that cross a box other than their own two ends."""
    bad = []
    for x1, y1, x2, y2, a, b in lines_geo:
        for n, (bx, by, bw, bh) in BOX.items():
            if n in (a, b):
                continue
            lo_x, hi_x = min(x1, x2), max(x1, x2)
            lo_y, hi_y = min(y1, y2), max(y1, y2)
            if hi_x > bx + 1 and lo_x < bx + bw - 1 and hi_y > by + 1 and lo_y < by + bh - 1:
                bad.append((a, b, n))
    return bad


if __name__ == '__main__':
    build()
    OUT.write_text('\n'.join(out), encoding='utf-8')
    bad = check()
    print('written', int(CANVAS_W), 'x', int(CANVAS_H), '; lines through other boxes:', sorted(set(bad)))
