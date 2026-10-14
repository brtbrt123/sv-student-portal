"""Reads the table definitions from docs/database/*.sql into a small model (tables, columns, keys,
foreign keys). Used by build_diagrams.py. Standard library only."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DB = ROOT / 'docs' / 'database'

# Files that create tables, in the order they ran.
SOURCES = ['schema.sql', 'applications_rules.sql', 'first_year_curriculum.sql', 'queue_rules.sql', 'notifications_rules.sql']

# Columns added later by ALTER TABLE ... ADD COLUMN (the CREATE TABLE text does not show them).
EXTRA_COLUMNS = {
    'applications': [('applicant_type', 'text', False)],
    'queue_tickets': [('held_at', 'timestamptz', True)],
}

MODULES = {
    'Identity & access': ['roles', 'profiles', 'students', 'department_staff'],
    'Academic structure': ['departments', 'terms', 'programs', 'subjects', 'sections', 'program_curriculum'],
    'Enrollment & grades': ['grade_scale', 'enrollments', 'enrollment_items', 'grades'],
    'Admissions': ['applications'],
    'Finance': ['fee_types', 'charges', 'payments'],
    'Document requests': ['document_types', 'document_requests'],
    'Clearance': ['clearances', 'clearance_items', 'academic_holds'],
    'Queue': ['queue_services', 'queue_tickets', 'queue_counters'],
    'Notifications': ['notifications'],
    'Security & audit': ['audit_logs', 'login_attempts'],
}

SHORT_TYPES = {
    'character varying': 'varchar', 'timestamp with time zone': 'timestamptz', 'timestamp without time zone': 'timestamp',
    'bigint': 'bigint', 'smallint': 'smallint', 'integer': 'int', 'boolean': 'bool', 'uuid': 'uuid', 'text': 'text',
    'numeric': 'numeric', 'date': 'date', 'inet': 'inet', 'jsonb': 'jsonb', 'json': 'json',
}


def short_type(t):
    t = re.sub(r'\(\d+(,\d+)?\)', '', t.strip())
    return SHORT_TYPES.get(t, t)


def split_top(body):
    parts, depth, cur = [], 0, ''
    for ch in body:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def load():
    tables = {}
    for name in SOURCES:
        text = (DB / name).read_text(encoding='utf-8')
        text = re.sub(r'--[^\n]*', '', text)
        for m in re.finditer(r'CREATE TABLE (?:IF NOT EXISTS )?public\.(\w+)\s*\((.*?)\n\);', text, re.S):
            tname, body = m.group(1), m.group(2)
            t = {'cols': [], 'pk': [], 'fks': []}
            for part in split_top(body):
                up = part.upper()
                if up.startswith('CONSTRAINT'):
                    pk = re.search(r'PRIMARY KEY \(([^)]*)\)', part)
                    fk = re.search(r'FOREIGN KEY \((\w+)\) REFERENCES (?:public\.)?(\w+)\((\w+)\)', part)
                    if pk:
                        t['pk'] = [c.strip() for c in pk.group(1).split(',')]
                    if fk:
                        t['fks'].append((fk.group(1), fk.group(2), fk.group(3)))
                    continue
                cm = re.match(r'(\w+)\s+((?:character varying|timestamp with time zone|timestamp without time zone|\w+)(?:\(\d+(?:,\d+)?\))?)', part)
                if not cm:
                    continue
                notnull = 'NOT NULL' in up
                t['cols'].append([cm.group(1), short_type(cm.group(2)), not notnull and 'PRIMARY KEY' not in up])
                inline_ref = re.search(r'REFERENCES (?:public\.)?(\w+)\((\w+)\)', part)
                if inline_ref:
                    t['fks'].append((cm.group(1), inline_ref.group(1), inline_ref.group(2)))
            tables[tname] = t
    for tname, cols in EXTRA_COLUMNS.items():
        for c in cols:
            tables[tname]['cols'].append(list(c))
    return tables


if __name__ == '__main__':
    tb = load()
    print(len(tb), 'tables;', sum(len(t['fks']) for t in tb.values()), 'foreign keys')
    for n, t in tb.items():
        print(n, len(t['cols']), 'cols; pk', t['pk'], '; fks', [f[0] + '->' + f[1] for f in t['fks']])
