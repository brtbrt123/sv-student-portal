"""Builds docs/Project-Documentation.pdf: the submission document, with the sections in the order the course requires:
Title Page, Table of Contents, SDLC Plan, System Modeling Diagrams, UI/UX Screen Designs & Wireframes, Database Design,
Software Testing Plan, Ethical Analysis, Prototype Link & Source Code, References (IEEE), Verification Reports,
Team Monitoring Sheet. Diagrams, wireframes and the full test cases are links, so the document stays short.
Needs: pip install markdown, Microsoft Edge (headless print to PDF), pdftotext (to fill the contents page numbers).
Run: python scripts/pdf/build_documentation_pdf.py [temp folder for the HTML]"""
import re
import subprocess
import sys
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'docs' / 'documentation.md'
OUT_PDF = ROOT / 'docs' / 'Project-Documentation.pdf'
TMP = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'docs'
EDGE = r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'

LIVE = 'https://cabuyaouni.vercel.app'
REPO = 'https://github.com/brtbrt123/sv-student-portal'
TESTS = REPO + '/blob/main/docs/testing-plan.md'
SQLTESTS = REPO + '/tree/main/docs/database'
UNITTESTS = REPO + '/tree/main/tests/unit'
FIG_DIAG = 'https://www.figma.com/design/caIH5zcYI3ursQ9c2iYFJg'
FIG_WIRE = 'https://www.figma.com/design/ZtlUFDtPCuTFA1V2SCIlrb'
NODE = {'ERD_overview': '4-2', 'ERD_detailed': '5-2', 'DFD_level1': '10-2', 'UseCase_Diagram': '8-2',
        'ActivityDiagram_Clearance': '10-522', 'ClassDiagram': '12-2'}


def diag(name):
    return f'{FIG_DIAG}?node-id={NODE[name]}'


lines = SRC.read_text(encoding='utf-8').replace('\r\n', '\n').split('\n')


def find(prefix, start=0):
    for i in range(start, len(lines)):
        if lines[i].startswith(prefix):
            return i
    raise SystemExit('missing ' + prefix)


def block(start_prefix, end_prefix, begin=0):
    s = find(start_prefix, begin)
    e = find(end_prefix, s + 1)
    return '\n'.join(lines[s:e]).split('\n', 1)[1].strip()


i_p1, i_p3 = find('## Part 1:'), find('## Part 3:')
summary = block('### 1. Executive Summary', '### 2. Project Objectives', i_p1)
objectives = block('### 2. Project Objectives', '### 3. Project Scope', i_p1)
scope = block('### 3. Project Scope', '### 4. Team Structure', i_p1)
team = block('### 4. Team Structure', '### 5. Deliverable Ownership', i_p1).replace(
    ' first on mock data for rapid prototyping; the mock data files were deleted on Oct 14, 2026 because every screen now reads live data.',
    ' that read live data from the database.')
why_agile = block('#### 7.1 Why Agile', '#### 7.2 Phases', i_p1).replace(' (originally Oct 12, now Oct 15, 2026)', ' (Oct 15, 2026)')
phases = block('#### 7.2 Phases', '#### 7.3 Sprints', i_p1)
roles = block('#### 7.4 Roles', '#### 7.5 Backlog', i_p1)
backlog = block('#### 7.5 Backlog by dependency', '#### 7.6 Branching', i_p1)
risks_full = block('#### 7.7 Testing approach and risks', '#### 7.8 Known gaps', i_p1).split('\n')
risks = '\n'.join(risks_full[risks_full.index('| Risk | Mitigation |'):]).replace('record carry-over in the Revision Log', 're-prioritize at each sprint review')

p3 = lines[i_p3:find('## Part 4:')]


def sub3(prefix):
    s = next(i for i, ln in enumerate(p3) if ln.startswith(prefix))
    e = next((i for i in range(s + 1, len(p3)) if p3[i].startswith('### ')), len(p3))
    return '\n'.join(p3[s:e]).split('\n', 1)[1].strip()


def clean(text, *drop_starts):
    text = re.sub(r'!\[[^\]]*\]\([^)]*\)\s*', '', text)
    text = re.sub(r'\[`?(\w+)\.svg`?\]\(diagrams/\w+\.svg\)', r'`\1.svg`', text)
    text = text.replace('`Database_Design_ERD_3NF.docx`', 'the database design file')
    return '\n\n'.join(p for p in text.split('\n\n') if not p.startswith(('*Figure',) + drop_starts))


erd_text = clean(sub3('### 1.'), 'The full reference ERD', 'All six diagrams', 'The ERD files are')
dfd_text, uc_text, act_text, cls_text = (clean(sub3('### 2.')), clean(sub3('### 3.')), clean(sub3('### 4.')), clean(sub3('### 5.')))

# ------------------------------------------------------------------------------------------------ sections
SECTIONS = [
    ('sdlc', 'SDLC Plan'),
    ('model', 'System Modeling Diagrams (DFD, Use Case, Activity, Class)'),
    ('ui', 'UI/UX Screen Designs & Wireframes'),
    ('db', 'Database Design (ERD / Normalization)'),
    ('test', 'Software Testing Plan'),
    ('ethics', 'Ethical Analysis'),
    ('proto', 'Prototype Link & Source Code'),
    ('refs', 'References'),
    ('verif', 'Verification Reports'),
    ('team', 'Team Monitoring Sheet'),
]


def toc_html(pages):
    rows = ''.join(f'<tr><td class="n">{i}.</td><td>{t}</td><td class="pg">{pages.get(k, "")}</td></tr>' for i, (k, t) in enumerate(SECTIONS, 1))
    return f'<div class="tocpage"><h1 class="plain">Table of Contents</h1><table class="toc">{rows}</table></div>'


TITLE = f"""
<div class="cover">
<div class="inst">Pamantasan ng Cabuyao (Cabuyao University)<br>Bachelor of Science in Computer Science</div>
<div class="ptitle">Centralized Student Portal and Automated Clearance System</div>
<div class="psub">System Requirements &amp; Project Documentation</div>
<table class="teamcover">
<tr><th>Member</th><th>Role</th></tr>
<tr><td>Abarquez, Justinbril</td><td>Project Manager / Systems Analyst</td></tr>
<tr><td>Cruzante, Aaron</td><td>Back-End Developer</td></tr>
<tr><td>Canayong, Ron</td><td>Back-End Developer</td></tr>
<tr><td>Esgana, Justine</td><td>Front-End Developer</td></tr>
<tr><td>Espedilon, Arvien</td><td>Front-End Developer</td></tr>
<tr><td>Dominado, Byrone</td><td>Front-End Developer</td></tr>
</table>
<div class="meta"><b>Tech stack:</b> Next.js, Tailwind CSS, Supabase (PostgreSQL), Vercel<br>
<b>Project duration:</b> 12 days (Agile, short sprints)<br>
<b>Prototype:</b> {LIVE}<br>
<b>Source code:</b> {REPO}<br>
<b>Date:</b> October 2026</div>
</div>
"""

SDLC = f"""
# 1. SDLC Plan

## 1.1 Project overview

{summary}

## 1.2 Objectives

{objectives}

## 1.3 Scope

{scope}

## 1.4 Team and roles

{team}

## 1.5 Selected model: Agile (Scrum-style)

{why_agile} The process follows the Scrum Guide [6].

## 1.6 SDLC phases

{phases}

## 1.7 Sprints

| Sprint | Goal | Outcome |
| --- | --- | --- |
| Sprint 1 | System modeling, ERD/3NF design, UI/UX wireframes, database initialization | Diagrams, schema and wireframes |
| Sprint 2 | Authentication and role routing, ERD v3 migration, shared UI and dashboard shell, SQL files, SDLC plan | Role-based login and the app shell |
| Sprint 3 | Clearance logic first (holds, department approval, Cashier auto-clear, final approval as database triggers), then the Registrar, Cashier and Department modules and the Admin audit log | The clearance chain on live data |
| Sprint 4 | Enrollment, grades, document requests, virtual queue, notifications, applications; Admin screens and dashboards; login lockout, rate limiting and security hardening; testing plan; release | Complete system on the live site |

## 1.8 Team roles in the process

{roles}

## 1.9 Backlog by dependency

{backlog}

## 1.10 Branching and deployment flow

1. Nobody codes directly on `main` or `dev`.
2. Each task gets a branch from `dev` named `feature/<task>` (or `chore/<task>`, `docs/<task>`).
3. The author opens a pull request into `dev`.
4. When `dev` is tested, the Project Manager merges `dev` into `main`.
5. Vercel deploys every change to `main` automatically. Secret keys stay in server-only code (SEC-06).

## 1.11 Risks and mitigation

{risks}
"""

MODEL = f"""
# 2. System Modeling Diagrams (DFD, Use Case, Activity, Class)

The system is modeled with a Data Flow Diagram, a Use Case Diagram, an Activity Diagram and a Class Diagram, all drawn from the real requirements and database design. They are kept in one Figma file with editable layers: {FIG_DIAG}

| Diagram | What it shows | Link |
| --- | --- | --- |
| Data Flow Diagram, level 1 | 13 processes, 14 data stores, 10 sections | {diag('DFD_level1')} |
| Use Case Diagram | 6 actors and their use cases | {diag('UseCase_Diagram')} |
| Activity Diagram (term clearance) | 5 swimlanes: Student, Department, Cashier, Registrar, System | {diag('ActivityDiagram_Clearance')} |
| Class Diagram | 28 classes with attributes, operations, generalization and multiplicities | {diag('ClassDiagram')} |

## 2.1 Functional requirements (basis of the models)

| Module | Requirements |
| --- | --- |
| Student | REQ-STU-01 sign in with student ID or email; REQ-STU-02 see enrollment status and grades; REQ-STU-03 see clearance across all departments; REQ-STU-04 request documents and track them; REQ-STU-05 submit an online enrollment; REQ-STU-06 request the term clearance |
| Registrar | REQ-REG-01 encode and update grades; REQ-REG-02 process document requests; REQ-REG-03 final clearance only when every item is cleared; REQ-REG-04 review, approve or reject enrollments |
| Cashier | REQ-CSH-01 view balances; REQ-CSH-02 log payments, tag charges Cleared or Waived; REQ-CSH-03 Finance clearance updates automatically |
| Department | REQ-DPT-01 see only own students; REQ-DPT-02 place and lift holds; REQ-DPT-03 approve departmental clearance when holds are lifted |
| Admin | REQ-ADM-01 manage user accounts; REQ-ADM-02 role-based access control; REQ-ADM-03 read-only audit log; REQ-ADM-04 maintain the academic catalog |
| Document requests | REQ-DOC-01 unique ticket per request (one to five documents); REQ-DOC-02 status updates when the Registrar processes it |
| Admissions | REQ-APP-01 public application form; REQ-APP-02 Registrar accepts or rejects and the account is created; REQ-APP-03 automatic first-year enrollment for new students |
| Virtual queue | REQ-QUE-01 rotating QR queue pass; REQ-QUE-02 Registrar scans, calls next, Done or No-show; REQ-QUE-03 place in line, hold and cancel; REQ-QUE-04 every ticket change is role-checked and audited |
| Notifications | REQ-NOT-01 in-app inbox for every role |
| Security and performance | SEC-01 to SEC-08 (authentication, RLS, lockout, rate limiting, SQL injection, secrets, password rules, headers); PER-01 pages under 2.5 s; PER-02 queries under 500 ms; PER-03 continuous deployment |

Requirements follow the IDs and style of ISO/IEC/IEEE 29148 [7].

## 2.2 Data Flow Diagram (level 1)

{dfd_text}

## 2.3 Use Case Diagram

{uc_text}

## 2.4 Activity Diagram (term clearance)

{act_text}

## 2.5 Class Diagram

{cls_text}
"""

UI = f"""
# 3. UI/UX Screen Designs & Wireframes

Mid-fidelity wireframes of every screen, grouped by role, are in one Figma file: {FIG_WIRE}

| Group | Screens |
| --- | --- |
| Public (5) | Landing, Login (Student and Staff tabs), Apply for admission, Application received, Set password |
| Student (7) | Dashboard, Enrollment with queue pass, Grades, Clearance, Document requests, Queue, Notifications |
| Registrar (7) | Dashboard, Applications, Enrollments, Encode grades, Queue desk, Final clearance, Document requests |
| Cashier (4) | Dashboard, Charges, Payments, Finance clearance |
| Department (3) | Dashboard, Clearance items, Academic holds |
| Admin (4) | Dashboard, Users, Academic setup, Audit log |

## 3.1 Consistent UI/UX

Every signed-in role uses the same layout: a sidebar with the links of that role, a top bar with the notification count, and a content area made of cards and tables. The same shared components (buttons, inputs, cards, tables, status badges) appear on every screen, and colors come from design tokens (light and dark theme, one font family). The final screens follow the wireframes and are live at {LIVE}.

## 3.2 UX principles

- **Clear status:** status is shown as a word badge (Pending, Cleared, Approved), never by color alone; a student sees every clearance office, who is holding it up, the reason, and the next step.
- **Safe actions:** a button that cannot be used is disabled and says why; destructive actions are red and ask for confirmation.
- **Plain messages:** database rules return fixed messages that the app turns into sentences, for example "Approval is blocked. Lift the active hold first."
- **Every state designed:** loading, empty and error states on each screen.
- **Phone and accessibility:** every page works at phone width (lists replace wide tables, touch targets of 44 px), keyboard focus is visible, and a dark theme is available.

## 3.3 Screen overview by role

| Role | What the screens let the user do |
| --- | --- |
| Applicant | Apply for admission as a new student or a transferee; receive the account by email |
| Student | See clearance status per office, grades and GWA per term, enroll, request documents, get and hold a queue ticket, read notifications |
| Registrar | Accept applications, approve enrollments, encode grades, process documents, run the queue window, issue final clearance |
| Cashier | See balances, record payments, tag charges; the Finance clearance item updates by itself |
| Department head | See only own students, place and lift holds, approve the department's clearance item |
| Admin | Manage staff accounts and roles, maintain terms, programs, departments, subjects and sections, read the audit log |
"""

DB = f"""
# 4. Database Design (ERD / Normalization)

Entity Relationship Diagrams: Overview {diag('ERD_overview')} and Detailed, with every column, type and key, {diag('ERD_detailed')}

{erd_text}

## 4.1 Normalization to the Third Normal Form

- **1NF:** every column holds one value; repeating groups are separate tables (`enrollment_items` for the subjects of an enrollment, `clearance_items` for the offices of a clearance, `queue_tickets` for the tickets of a service).
- **2NF:** tables with a composite key keep only attributes that depend on the whole key (`program_curriculum` is keyed by program, year, semester and subject; `queue_counters` by service and day).
- **3NF:** no attribute depends on another non-key attribute. A grade stores only the grade code, and its numeric value and pass flag are in `grade_scale`; a balance is computed from `charges` and `payments`; the status of a clearance, item or hold is derived from timestamps in views; a department's type is stored once in `departments`; a student's program is stored once in `students`.

The schema follows the relational model [5].
"""

TEST = f"""
# 5. Software Testing Plan

The full test cases, steps, expected results and recorded results are in the repository: {TESTS}

## 5.1 Test levels

| Level | What is tested and how | Tools and location |
| --- | --- | --- |
| Unit | Pure functions: password rules, student ID and login input, queue QR token and line, notification text, CSV, catalog validation, schedule parsing | Vitest, UT-01 to UT-128 ({UNITTESTS}) |
| Integration | Database rules and the app-to-database path: triggers, grants, Row Level Security, lockout, grades, documents, enrollment, applications, queue, notifications, admin. Each change is rehearsed in a rolled-back transaction, run live, then the regression script is re-run | SQL suites TC-01 to TC-259 ({SQLTESTS}) |
| System (end to end) | Browser walks of the real screens as each role: the clearance chain, grades, documents, enrollment, queue, first-year enrollment, Admin screens and dashboards; phone width, dark mode and accessibility; a check of the deployed site after each release | E2E-01 to E2E-13, S-01 to S-12 and the system tests of the full plan |
| Acceptance | One check per requirement on the live site (section 5.3) | ACC-01 to ACC-10 |
| Performance | PER-01: the main page of each role loads in under 2.5 s. PER-02: grade and clearance queries under 500 ms | PERF-01, PERF-02 |
| Security | Isolation, grants, authentication, lockout, rate limiting, headers, injection and cross-user tests | V-1 to V-7, local security checks, live header tests |

## 5.2 Test case groups

| Test cases | What is checked |
| --- | --- |
| TC-12 to TC-71 | Clearance chain: a department cannot clear an item while it has an active hold; the Finance item clears by itself when every charge is Cleared or Waived; final clearance only when every item is cleared; a department cannot read or approve another department's items |
| TC-72 to TC-82 | Login lockout: 5 failures lock the account with exponential backoff; the check runs before the password; anonymous users cannot call private functions |
| TC-83 to TC-122 | Grades only for items of an Approved enrollment; document status flow Pending, Processing, Ready, Released; enrollment rules (one per student and term, free seat, final decisions) |
| TC-123 to TC-166 | Applications (accept and reject, duplicate emails give no hint), student ID sign-in, the virtual queue (ticket rules, random codes, status flow) |
| TC-167 to TC-259 | Notifications (a failing notification never blocks the action), queue hold and No-show, academic catalog, Admin user accounts, automatic first-year enrollment |
| UT-01 to UT-128 | Unit tests of the pure functions listed above |
| E2E and S series | Browser steps per role with the expected screen text and the audit rows written |
| PERF-01, PERF-02 | Page load per role and query time per view |

## 5.3 Acceptance test script

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ACC-01 | REQ-STU-01 | A student signs in with the student ID and lands on the student home |
| ACC-02 | REQ-STU-02, REQ-REG-01 | A student sees their own grades; the Registrar encodes a grade |
| ACC-03 | REQ-STU-03, REQ-STU-06 | A student requests clearance and sees every office |
| ACC-04 | REQ-STU-04, REQ-DOC-01, REQ-DOC-02 | A student requests a document, gets a ticket, and the Registrar moves it to Released |
| ACC-05 | REQ-STU-05, REQ-REG-04 | A student submits an enrollment; the Registrar approves or rejects it |
| ACC-06 | REQ-DPT-01 to REQ-DPT-03 | A department lifts a hold and approves only its own students |
| ACC-07 | REQ-CSH-01 to REQ-CSH-03 | The Cashier logs a payment; Finance clears by itself |
| ACC-08 | REQ-REG-03 | The Registrar can issue the final clearance only when every office has cleared |
| ACC-09 | REQ-ADM-02, REQ-ADM-03 | A role cannot open another role's module; the Admin reads the audit log |
| ACC-10 | REQ-APP-01 to REQ-APP-03, REQ-QUE-01 to REQ-QUE-03 | An applicant applies, the Registrar accepts, the student gets a queue ticket |

## 5.4 Performance results

| Test | Result | Limit |
| --- | --- | --- |
| PERF-02: grade and clearance queries (30 runs each, as a student, Row Level Security on) | 0.09 to 1.46 ms per query | 500 ms |
| PERF-01: full page load of the main page of each role on the live site | 0.93 to 2.18 s | 2.5 s |

## 5.5 Security tests: vulnerabilities and solutions

| ID | Vulnerability | Solution | Test evidence |
| --- | --- | --- | --- |
| V-1 | A Supabase helper function was executable by the anonymous role | EXECUTE revoked from `anon` | TC-81 failed before the fix and passes after it |
| V-2 | Brute-force on the login | Login lockout with exponential backoff (5 failures, 60 s doubling, cap 15 min), checked before the password | TC-72 to TC-82; 5 wrong passwords lock the account in the app |
| V-3 | Request flooding and denial of service | Vercel firewall rule: 20 POST requests per minute per IP, then HTTP 429 | Live test: 40 POSTs gave 20 allowed and 20 blocked |
| V-4 | A rule conflict blocked document remarks while Pending | The database sets the fields itself | 14 cases pass |
| V-5 | SQL injection | Only parameterized Supabase calls; no SQL built from user input | Injection payloads in the login, purpose, remarks, hold reason, receipt number and the Data API were stored as plain text and no table was changed |
| V-6 | Queue QR forgery, replay and sharing | Signed token (HMAC-SHA256, server secret) that changes every 15 seconds | Unit tests UT-50 to UT-66 |
| V-7 | Proxy queuing | Random 7-digit ticket codes; the Registrar checks the student ID at the window | Queue checks Q-01 to Q-09 |

Other security results: 24 of 24 local repository checks; 0 known vulnerabilities in production dependencies; the 7 security headers present on the live site; the anonymous Data API refused on 17 of 17 probes; reads between two student accounts refused on 9 of 9 probes; other roles' pages redirect for a signed-in Student, Cashier and Registrar. The security design follows common web guidance [10].
"""

ETHICS = """
# 6. Ethical Analysis

The system holds student records: grades, enrollment, balances, holds, document requests and clearance. A wrong or leaked record can hurt a real person, so each theme asks what the principle requires, what the system does, and what we propose. Principles come from the ACM and IEEE codes of ethics [1], [2] and the Data Privacy Act of 2012 [8].

## 6.1 Stakeholders and possible harm

| Stakeholder | Need | Possible harm |
| --- | --- | --- |
| Students | Correct, private records; a fair clearance; clear reasons for holds | Another person reads their grades or balance; a wrong hold or grade delays clearance |
| Registrar, Cashier, Department staff | Tools to do their job | Blamed for changes they did not make if the log is weak |
| Admin | Manage accounts, catalog and the audit log | Holds much power, so their own actions must be visible |
| The university | Trustworthy records and legal compliance | A data breach, loss of trust, complaints under the Data Privacy Act |

## 6.2 Codes of ethics applied

The ACM Code of Ethics and Professional Conduct (2018) and the IEEE Code of Ethics are applied by theme: avoid harm, respect privacy and confidentiality, be honest about what was built, be accountable, and give proper credit.

## 6.3 Data Privacy Act of 2012 (RA 10173): principles and how the system meets them

| Principle | How the system meets it |
| --- | --- |
| Transparency | Students see their own records, status and the reason for a hold |
| Legitimate purpose | Data is used only for enrollment, grades, documents and clearance; no analytics and no third-party sharing |
| Proportionality | A minimal schema, column-level grants, no hard deletes, fictional seed data |
| Confidentiality | Row Level Security on all 29 tables; each student reads only their own rows; each department sees only its own items |
| Integrity | Database triggers enforce the rules for every role; the audit log is append-only and nobody, including the Admin, can edit it |
| Availability | Hosted on Vercel and Supabase; performance measured against PER-01 and PER-02 |
| Access control | Supabase Auth, login lockout, rate limiting, password rules, security headers |
| Accountability | Every critical change is written to the audit log by database triggers |

## 6.4 Fairness and accessibility

The same rules apply to every role because the database enforces them, so there is no silent exception. Every screen works at phone width, has visible keyboard focus and a dark theme, and shows status in words and not by color alone.

## 6.5 Use of AI assistance

An AI coding assistant helped draft code, SQL, tests and documents. The team reviewed and tested every output (type check, lint, build, rolled-back SQL rehearsals and browser tests), approved every change to the live database, never gave the assistant any secret key, and commits made with it carry a co-author line.

## 6.6 Proposed solutions and safeguards

| Risk | Proposed solution |
| --- | --- |
| A student does not know what data is kept | A short privacy notice for students and a notice about the audit log for staff |
| A data breach | A written incident procedure that names who notifies the National Privacy Commission |
| Sensitive reads are not logged | Read logging for sensitive tables |
| The Cashier can edit amounts | Keep every edit audited and add a second approver for amount changes |
| Old login attempts and notifications pile up | Automatic retention (delete after a set time) |
| A wrong hold or grade | A correction request flow for students |
| Real data later | A review by the university's data protection contact before any real data is loaded |
"""

PROTO = f"""
# 7. Prototype Link & Source Code

| Item | Link |
| --- | --- |
| Live deployment (working prototype) | {LIVE} |
| GitHub repository (source code) | {REPO} |
| Test cases (full list) | {TESTS} |
| System diagrams | {FIG_DIAG} |
| Wireframes | {FIG_WIRE} |

## 7.1 About the prototype

| Item | Detail |
| --- | --- |
| Architecture | Next.js 16 (App Router, TypeScript) and Tailwind CSS on Vercel; Supabase for PostgreSQL, Authentication and Row Level Security; functions run in the same region as the database [9] |
| Roles | Student, Registrar, Cashier, Department head, Admin, and a public application site for applicants |
| Features | Public application and enrollment site; automatic first-year enrollment; student enrollment, grades, clearance and document requests; virtual queue with a rotating QR pass, hold and No-show; in-app notifications; Registrar, Cashier, Department and Admin screens; academic setup and user accounts; audit log; login lockout, rate limiting, security headers and password rules |
| Deployment | Every merge into the `main` branch deploys automatically to Vercel |

## 7.2 Test accounts

Students sign in on the Student tab with their 8-digit student ID; staff sign in on the Staff tab with their email. The accounts hold fictional data only.

| Role | Sign-in |
| --- | --- |
| Admin | `admin@pnc.test` |
| Registrar | `registrar@pnc.test` |
| Cashier | `cashier@pnc.test` |
| Department head | `dept@pnc.test` |
| Students | 20260001, 20260002, 20260003 |

Passwords are given to the evaluators by the Project Manager.

## 7.3 Quick walkthrough

1. Sign in as a student and request clearance: four offices appear.
2. Sign in as `cashier@pnc.test` and record a payment: the Finance office clears by itself.
3. Sign in as `dept@pnc.test`, lift a hold and approve the department.
4. Sign in as `registrar@pnc.test` and issue the final clearance.
5. Sign in as `admin@pnc.test` and open the audit log to see every step recorded.

## 7.4 Run the source code

```
git clone {REPO}.git
cd sv-student-portal
npm install
npm run dev
```

The project needs a `.env.local` file with the Supabase URL and anon key (given by the Project Manager). The database scripts are in `docs/database`.
"""

REFS = """
# 8. References

1. ACM, "ACM Code of Ethics and Professional Conduct," Association for Computing Machinery, 2018.
2. IEEE, "IEEE Code of Ethics," IEEE Policies, Section 7.8.
3. Supabase Inc., "Supabase Documentation: Database and Auth," 2026. [Online]. Available: https://supabase.com/docs
4. PostgreSQL Global Development Group, "PostgreSQL Documentation: Row Security Policies," 2026. [Online]. Available: https://www.postgresql.org/docs/
5. E. F. Codd, "A relational model of data for large shared data banks," *Commun. ACM*, vol. 13, no. 6, pp. 377-387, Jun. 1970.
6. K. Schwaber and J. Sutherland, "The Scrum Guide," Nov. 2020.
7. ISO/IEC/IEEE, "Systems and software engineering: Life cycle processes: Requirements engineering," ISO/IEC/IEEE 29148:2018, 2018.
8. Republic of the Philippines, "Data Privacy Act of 2012," Republic Act No. 10173, Aug. 2012.
9. Vercel Inc., "Next.js Documentation," 2026. [Online]. Available: https://nextjs.org/docs
10. OWASP Foundation, "OWASP Top 10: 2021," 2021. [Online]. Available: https://owasp.org/Top10/
"""

VERIF = """
# 9. Verification Reports

The reports below are attached as screenshots or exported files after the checks are run on the final document. Each result is recorded in the tables.

## 9.1 Plagiarism Checker Results

| Item | Entry |
| --- | --- |
| Tool used | |
| Document checked | System Requirements & Project Documentation |
| Date checked | |
| Similarity result | % |
| Sources flagged and how they were handled | |
| Checked by | |
| Report attached | (insert screenshot or file name) |

## 9.2 AI / Anti-AI Detector Results

| Item | Entry |
| --- | --- |
| Tool used | |
| Document checked | System Requirements & Project Documentation |
| Date checked | |
| Result (percentage likely AI-generated / human-written) | |
| Notes on how the work was produced (see section 6.5, Use of AI assistance) | |
| Checked by | |
| Report attached | (insert screenshot or file name) |
"""

MEMBERS = ['Abarquez, Justinbril', 'Cruzante, Aaron', 'Canayong, Ron', 'Esgana, Justine', 'Espedilon, Arvien', 'Dominado, Byrone']
peer_rows = ''.join(f'| {m} |  |  |  |  |  |  |  |\n' for m in MEMBERS)
task_rows = ''.join(f'| {m} |  |  |  |  |\n' for m in MEMBERS)
TEAM = f"""
# 10. Team Monitoring Sheet

The Team Monitoring Sheet records the work of each member and the peer evaluation (team member grading). The full workbook (Team-Monitoring-Sheet.xlsx: task tracker, weekly progress, meeting log, peer evaluation and an automatic summary) is submitted with this document. The tables below are its printable summary.

## 10.1 Contribution summary

| Member | Main tasks and deliverables | Tasks done | Hours | Remarks |
| --- | --- | --- | --- | --- |
{task_rows}
## 10.2 Peer evaluation (team member grading)

Each member rates every teammate except themselves from 1 to 5 (5 = Excellent, 4 = Good, 3 = Satisfactory, 2 = Needs improvement, 1 = Poor). The table shows the average rating each member received.

| Member evaluated | Contribution | Quality of work | Reliability | Communication | Teamwork | Initiative | Average |
| --- | --- | --- | --- | --- | --- | --- | --- |
{peer_rows}
Evaluator signatures: ______________________________________________________________________
"""

CSS = """
@page { size: A4; margin: 22mm 20mm 22mm 20mm; @bottom-center { content: counter(page); font: 9pt Calibri, Arial, sans-serif; color: #555; } }
@page :first { @bottom-center { content: ""; } }
body { font-family: Calibri, Carlito, Arial, sans-serif; font-size: 10.5pt; line-height: 1.32; color: #111; }
.cover { text-align: center; padding-top: 30mm; break-after: page; }
.inst { font-size: 14pt; color: #333; margin-bottom: 46mm; line-height: 1.5; }
.ptitle { font-size: 28pt; font-weight: 700; line-height: 1.15; margin-bottom: 8pt; }
.psub { font-size: 15pt; color: #444; margin-bottom: 14mm; }
.teamcover { width: 70%; margin: 0 auto 12mm; font-size: 10.5pt; }
.meta { font-size: 10.5pt; line-height: 1.7; text-align: left; width: 78%; margin: 0 auto; }
.tocpage { break-after: page; }
h1 { font-size: 17pt; margin: 0 0 8pt; border-bottom: 1.5px solid #333; padding-bottom: 3pt; break-before: page; break-after: avoid; }
h1.plain { break-before: auto; margin-bottom: 16pt; }
h2 { font-size: 13pt; margin: 11pt 0 4pt; break-after: avoid; }
h3 { font-size: 11.5pt; margin: 8pt 0 3pt; break-after: avoid; }
p { margin: 4pt 0; } ul, ol { margin: 3pt 0 5pt 0; padding-left: 20pt; } li { margin: 1.5pt 0; }
table { border-collapse: collapse; width: 100%; margin: 6pt 0 8pt; font-size: 9.3pt; }
tr { break-inside: avoid; }
th, td { border: 0.75pt solid #777; padding: 2.5pt 5pt; vertical-align: top; text-align: left; overflow-wrap: break-word; }
th { background: #e9e9ee; font-weight: 700; }
table.toc { border: none; font-size: 12pt; } table.toc td { border: none; border-bottom: 0.5pt dotted #999; padding: 6pt 4pt; }
table.toc td.n { width: 8%; } table.toc td.pg { width: 10%; text-align: right; }
table.teamcover th, table.teamcover td { text-align: left; }
code { font-family: Consolas, 'Courier New', monospace; font-size: 8.8pt; background: #f1f1f4; padding: 0 2pt; word-break: break-word; }
pre { background: #f6f6f8; border: 0.5pt solid #ccc; padding: 6pt; font-size: 8.8pt; white-space: pre-wrap; }
pre code { background: none; padding: 0; }
blockquote { margin: 5pt 0; padding: 4pt 8pt; background: #f3f3f6; border-left: 3pt solid #666; }
a { color: #0b4fa8; text-decoration: underline; word-break: break-all; }
"""


def render(pages):
    md_all = '\n\n'.join([SDLC, MODEL, UI, DB, TEST, ETHICS, PROTO, REFS, VERIF, TEAM])
    body = markdown.markdown(md_all, extensions=['tables', 'fenced_code', 'sane_lists', 'md_in_html'])
    body = re.sub(r'(?<![">])(https://[^\s<)]+)', r'<a href="\1">\1</a>', body)
    body = body.replace('<table>\n<thead>\n<tr>\n<th>Member evaluated', '<table>\n<thead>\n<tr>\n<th>Member evaluated')
    html = f'<!doctype html><html><head><meta charset="utf-8"><title>System Requirements and Project Documentation</title><style>{CSS}</style></head><body>{TITLE}{toc_html(pages)}{body}</body></html>'
    hp = TMP / 'Project-Documentation.html'
    hp.write_text(html, encoding='utf-8')
    subprocess.run([EDGE, '--headless=new', '--disable-gpu', '--no-pdf-header-footer', f'--print-to-pdf={OUT_PDF}', hp.as_uri()], check=True, timeout=180)


def page_numbers():
    txt = subprocess.run(['pdftotext', '-layout', str(OUT_PDF), '-'], capture_output=True, text=True, encoding='utf-8', errors='ignore').stdout
    pages = txt.split('\f')
    found = {}
    for i, (key, title) in enumerate(SECTIONS, 1):
        pat = re.compile(rf'^\s*{i}\.\s+{re.escape(title)}\s*$', re.M)
        for pn, p in enumerate(pages, 1):
            if pn > 2 and pat.search(p):
                found[key] = pn
                break
    return found


render({})
pages = page_numbers()
render(pages)
pages2 = page_numbers()
if pages2 != pages:
    render(pages2)
    pages = pages2
print('sections on pages:', pages)
print('wrote', OUT_PDF, OUT_PDF.stat().st_size, 'bytes')
