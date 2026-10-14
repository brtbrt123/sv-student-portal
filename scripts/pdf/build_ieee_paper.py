"""Builds docs/IEEE-Paper.pdf: the project paper in the two-column IEEE conference style.
Needs Microsoft Edge (headless print to PDF). Run: python scripts/pdf/build_ieee_paper.py [temp folder]"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_PDF = ROOT / 'docs' / 'IEEE-Paper.pdf'
TMP = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'docs'
EDGE = r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'

FIG_ARCH = """
<svg viewBox="0 0 360 292" xmlns="http://www.w3.org/2000/svg" font-family="Arial, sans-serif" font-size="10">
<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 10 5 0 10z" fill="#222"/></marker></defs>
<rect x="6" y="8" width="348" height="52" rx="4" fill="#f2f2f2" stroke="#222"/>
<text x="180" y="25" text-anchor="middle" font-weight="bold">Browser (phone or desktop)</text>
<text x="180" y="43" text-anchor="middle">Applicant | Student | Registrar | Cashier | Department | Admin</text>
<line x1="180" y1="60" x2="180" y2="84" stroke="#222" marker-end="url(#a)"/><text x="190" y="76" font-size="9">HTTPS</text>
<rect x="6" y="86" width="348" height="78" rx="4" fill="#fff" stroke="#222"/>
<text x="180" y="103" text-anchor="middle" font-weight="bold">Vercel: Next.js 16 (App Router, TypeScript)</text>
<rect x="16" y="112" width="102" height="44" rx="3" fill="#f2f2f2" stroke="#555"/><text x="67" y="130" text-anchor="middle" font-size="9">Proxy: session,</text><text x="67" y="143" text-anchor="middle" font-size="9">role routing</text>
<rect x="129" y="112" width="102" height="44" rx="3" fill="#f2f2f2" stroke="#555"/><text x="180" y="130" text-anchor="middle" font-size="9">Server Components</text><text x="180" y="143" text-anchor="middle" font-size="9">and Server Actions</text>
<rect x="242" y="112" width="102" height="44" rx="3" fill="#f2f2f2" stroke="#555"/><text x="293" y="130" text-anchor="middle" font-size="9">Email (Resend):</text><text x="293" y="143" text-anchor="middle" font-size="9">acceptance mail</text>
<line x1="180" y1="164" x2="180" y2="186" stroke="#222" marker-end="url(#a)"/><text x="190" y="179" font-size="9">user session (anon key)</text>
<rect x="6" y="188" width="348" height="98" rx="4" fill="#fff" stroke="#222"/>
<text x="180" y="204" text-anchor="middle" font-weight="bold">Supabase</text>
<rect x="16" y="212" width="100" height="66" rx="3" fill="#f2f2f2" stroke="#555"/><text x="66" y="229" text-anchor="middle" font-size="9" font-weight="bold">Auth</text><text x="66" y="243" text-anchor="middle" font-size="9">bcrypt passwords,</text><text x="66" y="256" text-anchor="middle" font-size="9">sessions, lockout</text><text x="66" y="269" text-anchor="middle" font-size="9">check</text>
<rect x="124" y="212" width="222" height="66" rx="3" fill="#f2f2f2" stroke="#555"/><text x="235" y="229" text-anchor="middle" font-size="9" font-weight="bold">PostgreSQL (29 tables, 4 views)</text><text x="235" y="243" text-anchor="middle" font-size="9">Row Level Security on every table</text><text x="235" y="256" text-anchor="middle" font-size="9">triggers enforce the business rules</text><text x="235" y="269" text-anchor="middle" font-size="9">append-only audit log</text>
</svg>"""

FIG_FLOW = """
<svg viewBox="0 0 740 150" xmlns="http://www.w3.org/2000/svg" font-family="Arial, sans-serif" font-size="10">
<defs><marker id="b" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 10 5 0 10z" fill="#222"/></marker></defs>
<rect x="4" y="48" width="104" height="50" rx="4" fill="#fff" stroke="#222"/><text x="56" y="68" text-anchor="middle">Student requests</text><text x="56" y="82" text-anchor="middle">term clearance</text>
<line x1="108" y1="73" x2="136" y2="73" stroke="#222" marker-end="url(#b)"/>
<rect x="138" y="48" width="112" height="50" rx="4" fill="#f2f2f2" stroke="#222" stroke-dasharray="4 3"/><text x="194" y="68" text-anchor="middle">System creates one</text><text x="194" y="82" text-anchor="middle">item per department</text>
<line x1="250" y1="64" x2="288" y2="34" stroke="#222" marker-end="url(#b)"/><line x1="250" y1="82" x2="288" y2="112" stroke="#222" marker-end="url(#b)"/>
<rect x="290" y="8" width="136" height="50" rx="4" fill="#fff" stroke="#222"/><text x="358" y="28" text-anchor="middle">Department approves</text><text x="358" y="42" text-anchor="middle">(no active hold)</text>
<rect x="290" y="92" width="136" height="50" rx="4" fill="#fff" stroke="#222"/><text x="358" y="108" text-anchor="middle">Cashier logs payment;</text><text x="358" y="122" text-anchor="middle">Finance clears by itself</text>
<line x1="426" y1="34" x2="466" y2="64" stroke="#222" marker-end="url(#b)"/><line x1="426" y1="116" x2="466" y2="84" stroke="#222" marker-end="url(#b)"/>
<rect x="468" y="48" width="122" height="50" rx="4" fill="#fff" stroke="#222"/><text x="529" y="68" text-anchor="middle">Registrar approves</text><text x="529" y="82" text-anchor="middle">(all items cleared)</text>
<line x1="590" y1="73" x2="614" y2="73" stroke="#222" marker-end="url(#b)"/>
<rect x="616" y="48" width="118" height="50" rx="4" fill="#f2f2f2" stroke="#222" stroke-dasharray="4 3"/><text x="675" y="68" text-anchor="middle">Clearance Approved;</text><text x="675" y="82" text-anchor="middle">audit log written</text>
</svg>"""


FIG_DB = """
<svg viewBox="0 0 740 120" xmlns="http://www.w3.org/2000/svg" font-family="Arial, sans-serif" font-size="10">
""" + "".join(
    f'<rect x="{4 + (i % 5) * 146}" y="{4 + (i // 5) * 58}" width="138" height="50" rx="4" fill="#f2f2f2" stroke="#222"/>'
    f'<text x="{4 + (i % 5) * 146 + 69}" y="{4 + (i // 5) * 58 + 21}" text-anchor="middle" font-weight="bold">{n}</text>'
    f'<text x="{4 + (i % 5) * 146 + 69}" y="{4 + (i // 5) * 58 + 38}" text-anchor="middle" font-size="9">{t}</text>'
    for i, (n, t) in enumerate([("Identity (4)", "roles, profiles, students"), ("Academic (6)", "terms, programs, subjects"), ("Enrollment (4)", "enrollments, items, grades"), ("Admissions (1)", "applications"), ("Finance (3)", "charges, payments"),
                                ("Documents (2)", "requests, types"), ("Clearance (3)", "clearances, items, holds"), ("Queue (3)", "services, tickets, counters"), ("Notifications (1)", "notifications"), ("Security (2)", "audit_logs, login_attempts")])
) + "</svg>"

PAPER = f"""
<div class="title">Centralized Student Portal and Automated Clearance System for Pamantasan ng Cabuyao</div>
<div class="authors">
<span>Justinbril Abarquez<br><i>Project Manager</i></span>
<span>Aaron Cruzante<br><i>Back-End Developer</i></span>
<span>Ron Canayong<br><i>Back-End Developer</i></span>
<span>Justine Esgana<br><i>Front-End Developer</i></span>
<span>Arvien Espedilon<br><i>Front-End Developer</i></span>
<span>Byrone Dominado<br><i>Front-End Developer</i></span>
</div>
<div class="affil">Bachelor of Science in Computer Science, Pamantasan ng Cabuyao (Cabuyao University), Cabuyao, Laguna, Philippines</div>

<div class="cols">
<p class="abs"><b><i>Abstract</i>&mdash;</b>Students at Pamantasan ng Cabuyao queue in person to enroll, collect clearance signatures from several offices, and request records. This paper presents a web-based Centralized Student Portal and Automated Clearance System that moves these processes online for five roles: Student, Registrar, Cashier, Department head and Admin, plus a public application site for new students. The system uses a Backend-as-a-Service architecture (Next.js on Vercel and Supabase PostgreSQL with Authentication) and a database normalized to the Third Normal Form with 29 tables. Business rules, such as a department cannot clear a student with an active hold and the Registrar can only approve a clearance when every office has cleared, are enforced by database triggers and Row Level Security instead of application code. Further features are a virtual queue with a rotating QR pass, in-app notifications, and an append-only audit log. The project followed Agile sprints, was modeled with Use Case, Activity, Data Flow and Class diagrams, and was verified with 128 unit tests, about 250 database test cases, browser end-to-end checks, performance measurements and security tests. All main pages load in under 2.5 s and database queries run in under 2 ms on the test data. We also analyze the ethical and legal duties of handling student records under the Data Privacy Act of 2012.</p>
<p class="kw"><b><i>Keywords</i>&mdash;</b>student portal, clearance automation, row level security, Supabase, database triggers, role-based access control, Agile, data privacy</p>

<h2>I. Introduction</h2>
<p>Enrollment, clearance and document requests are routine services of a university, but in many schools they still depend on paper forms and physical lines. A student who needs clearance must visit the Cashier, each academic department and the Registrar, and every office keeps its own record. This causes long waiting times, lost or inconsistent records, and no single place where a student can see what is holding a clearance back.</p>
<p>The goal of this project is a single portal that (1) removes physical queuing for enrollment and document claiming, (2) automates the clearance chain across academic and financial offices, (3) gives students real-time access to their grades and status, and (4) gives staff tools that enforce the school's rules the same way every time. The contributions of this paper are the system design, the decision to enforce rules inside the database, and the evidence from testing that the system meets its functional, security and performance requirements.</p>

<h2>II. Background and Related Work</h2>
<p><b>Student information systems.</b> Student portals usually combine records, enrollment and payments in one application. We scoped ours to six modules (Student, Registrar, Cashier, Department, Admin, Document Requests) and later added admissions, a virtual queue and notifications, because these were the main pain points reported for the Registrar window.</p>
<p><b>Backend-as-a-Service.</b> To deliver in 12 days without losing architectural quality, we used Supabase, which provides PostgreSQL, authentication and an API [3]. Access control uses PostgreSQL Row Level Security (RLS) policies [4], so the database, not the web server, decides which rows a user may read or write.</p>
<p><b>Normalization.</b> The schema follows the relational model [5] and is normalized to the Third Normal Form (3NF) to avoid duplicated and inconsistent data.</p>
<p><b>Process and requirements.</b> We followed an Agile, Scrum-style process [6] and wrote requirements in the style of ISO/IEC/IEEE 29148 [7] with traceable IDs (REQ, SEC, PER, ETH).</p>

<h2>III. Methodology</h2>
<p><b>A. Process.</b> The team worked in four short sprints: modeling and database design; authentication and role routing; the clearance chain on live data; and enrollment, grades, documents, queue, notifications, admissions, hardening and release. Work was done on feature branches, merged by pull request into a <i>dev</i> branch, and released to <i>main</i> by the Project Manager, which Vercel deploys automatically.</p>
<p><b>B. Requirements.</b> Requirements were grouped by module: Student (6), Registrar (4), Cashier (3), Department (3), Admin (4), Document requests (2), Admissions (3), Virtual queue (4), Notifications (1), plus security (8) and performance (3) requirements.</p>
<p><b>C. Modeling.</b> The system was modeled with a Use Case diagram (6 actors), an Activity diagram of the term clearance (5 swimlanes), a level-1 Data Flow diagram (13 processes, 14 data stores), a Class diagram (28 classes), and an Entity Relationship diagram (29 tables). The diagrams are available at https://www.figma.com/design/caIH5zcYI3ursQ9c2iYFJg and the wireframes of 30 screens at https://www.figma.com/design/ZtlUFDtPCuTFA1V2SCIlrb.</p>

<table><caption>TABLE I. SYSTEM REQUIREMENTS BY MODULE</caption>
<tr><th>Module</th><th>Main requirements</th></tr>
<tr><td>Student</td><td>Sign in with student ID; see enrollment status, grades and clearance; submit enrollment; request documents and clearance</td></tr>
<tr><td>Registrar</td><td>Encode grades; process documents; approve or reject enrollments; final clearance only when every item is cleared</td></tr>
<tr><td>Cashier</td><td>View balances; log payments; tag charges; Finance clearance updates automatically</td></tr>
<tr><td>Department</td><td>See only own students; place and lift holds; approve departmental clearance</td></tr>
<tr><td>Admin</td><td>Manage accounts and roles; maintain the academic catalog; read the audit log</td></tr>
<tr><td>Admissions</td><td>Public application form; accept or reject; account and first-year enrollment created automatically</td></tr>
<tr><td>Queue, notifications</td><td>Rotating QR pass, ticket, hold and cancel; in-app inbox for every role</td></tr>
<tr><td>Security, performance</td><td>Authentication, RLS, lockout, rate limiting, injection protection, secret handling, password rules, headers; pages under 2.5 s; queries under 500 ms</td></tr>
</table>
<p><b>D. What the diagrams show.</b> The Use Case diagram has six actors (Applicant, Student, Registrar, Cashier, Department head, Admin); all signed-in actors sign in first, and some use cases include or extend others (for example, issuing the final clearance includes verifying that every office has cleared). The Activity diagram follows one term clearance across five swimlanes (Student, Department, Cashier, Registrar, System) and marks the steps that the database performs by itself. The Data Flow diagram is split into ten sections (authentication, admissions, enrollment, grades, payments, clearance, document requests, queue, notifications, administration and audit); each section shows the entities, one or more processes and the data stores they touch, and dashed flows mark changes made by triggers. The Class diagram shows an abstract <i>User</i> specialized by the five role classes, each with its operations, and the domain classes (for example <i>Enrollment</i>, <i>Clearance</i>, <i>QueueTicket</i>) with their multiplicities.</p>

<h2>IV. System Design</h2>
<p><b>A. Architecture.</b> Fig. 1 shows the architecture. The browser talks to a Next.js 16 application on Vercel. A proxy refreshes the session and routes each role to its own module. Server Components and Server Actions query Supabase with the signed-in user's own session, so RLS applies to every request. A privileged server-side key is used only in server code for a few tasks, such as creating a student account when an application is accepted.</p>
<div class="fig">{FIG_ARCH}<div class="cap">Fig. 1. System architecture.</div></div>
<p><b>B. Database design.</b> The database has 29 tables in ten groups (identity, academic structure, enrollment and grades, admissions, finance, document requests, clearance, queue, notifications, security and audit), 47 foreign keys and four views. Design decisions that keep it in 3NF include: credentials stay in the authentication service and portal tables reference the same identifier; a grade stores only its code, with the numeric value and pass flag in a scale table; a balance is computed from charges and payments instead of stored; and the status of a clearance, an item or a hold is derived from timestamps in views. Foreign keys use <i>ON DELETE RESTRICT</i>, so accounts are deactivated, never deleted.</p>
<div class="figw">{FIG_DB}<div class="cap">Fig. 2. The 29 tables grouped in ten modules (number of tables in brackets).</div></div>
<p><b>C. Rules in the database.</b> Rules that must hold for every role are triggers: a department cannot clear its item while the student has an active hold of that department; the Finance item clears automatically when every charge of the student for the term is Cleared or Waived; a clearance can be approved only when all its items are cleared; grades can be posted only for an Approved enrollment; and document requests and queue tickets move only along fixed status flows. Fig. 3 shows the clearance flow that these rules control.</p>
<div class="figw">{FIG_FLOW}<div class="cap">Fig. 3. Term clearance flow. Dashed boxes are automatic (database).</div></div>
<p><b>D. Security design.</b> Passwords are hashed by the authentication service. RLS is enabled on all 29 tables and each role receives only the column-level privileges its screens need. The audit log is written by triggers and is append-only for every role, including the Admin. Sign-in has a lockout with exponential backoff, a rate limit of 20 POST requests per minute per IP, password rules (8 to 72 characters with lowercase, capital, digit and symbol), and HTTP security headers.</p>
<p><b>E. UI/UX.</b> All signed-in roles share one layout (sidebar, top bar, content cards and tables) built from the same components and design tokens, with light and dark themes. Status is shown in words, disabled buttons explain why, and every page works at phone width.</p>

<h2>V. Implementation</h2>
<p>The prototype is deployed at https://cabuyaouni.vercel.app. <b>Student:</b> dashboard with live grades, GWA per term and clearance chain; enrollment; grades; clearance; document requests (one to five documents per request, each with its own ticket); queue. <b>Registrar:</b> applications, enrollments, grade encoding, document processing, final clearance and the queue desk. <b>Cashier:</b> charges, payments and Finance clearance. <b>Department:</b> clearance items and academic holds. <b>Admin:</b> user accounts, academic setup (terms, programs, departments, subjects, sections) and the audit log.</p>
<p><b>Admissions.</b> An applicant fills a public form. When the Registrar accepts it, the system creates the account with the next student number, e-mails the student ID and a link to set a password, and, for a new student, creates a Pending first-year enrollment from the program curriculum.</p>
<p><b>Virtual queue.</b> A student's queue pass is a QR code carrying a signed token (HMAC-SHA256 with a server secret) that changes every 15 seconds, so a screenshot is useless after at most 30 seconds. The Registrar scans it, which issues a ticket with a random 7-digit code; the line order is kept separately so the line cannot be guessed. A student can see the place in line, hold the place for 30 minutes, or cancel. Expired holds are closed by the database.</p>
<p><b>Notifications.</b> Database triggers write in-app notifications for queue, enrollment, document, clearance, hold, grade and application events. A failing notification can never block the original action.</p>

<h2>VI. Testing and Results</h2>
<p>Testing used six levels (Table II). Each database change was first rehearsed in a rolled-back transaction, then run live, then the regression script was re-run.</p>
<table><caption>TABLE II. TEST LEVELS AND EVIDENCE</caption>
<tr><th>Level</th><th>Method</th><th>Evidence</th></tr>
<tr><td>Unit</td><td>Vitest on pure functions</td><td>128 tests pass</td></tr>
<tr><td>Integration</td><td>SQL suites on the live database</td><td>TC-01 to TC-259</td></tr>
<tr><td>System</td><td>Browser walks per role, phone width, dark mode</td><td>E2E-01 to E2E-13, S-01 to S-12</td></tr>
<tr><td>Acceptance</td><td>One check per requirement</td><td>ACC-01 to ACC-10</td></tr>
<tr><td>Performance</td><td>Timed queries and page loads</td><td>Table III</td></tr>
<tr><td>Security</td><td>Isolation, injection, lockout, flooding</td><td>Table IV</td></tr>
</table>
<p><b>Performance.</b> Queries for grades and clearance ran 30 times as a student with RLS on. Main pages of all five roles were timed on the live site (Table III).</p>
<table><caption>TABLE III. PERFORMANCE RESULTS</caption>
<tr><th>Requirement</th><th>Result</th><th>Limit</th></tr>
<tr><td>PER-02 query time</td><td>0.09 to 1.46 ms</td><td>500 ms</td></tr>
<tr><td>PER-01 full page load</td><td>0.93 to 2.18 s</td><td>2.5 s</td></tr>
</table>
<p><b>Security.</b> Seven vulnerabilities were addressed with a solution and a test (Table IV). In addition, 24 of 24 local repository checks passed, production dependencies had no known vulnerabilities, the seven expected security headers were present on the live site, the anonymous API was refused on 17 of 17 probes, and reads between two student accounts were refused on 9 of 9 probes.</p>
<table><caption>TABLE IV. VULNERABILITIES AND SOLUTIONS</caption>
<tr><th>Vulnerability</th><th>Solution</th></tr>
<tr><td>Helper function callable by anonymous role</td><td>EXECUTE revoked; test TC-81</td></tr>
<tr><td>Brute-force sign-in</td><td>Lockout with exponential backoff</td></tr>
<tr><td>Request flooding</td><td>Rate limit, HTTP 429 (20 of 40 blocked)</td></tr>
<tr><td>Document rule conflict</td><td>Database sets the fields; 14 cases</td></tr>
<tr><td>SQL injection</td><td>Parameterized calls; payloads stored as text</td></tr>
<tr><td>QR forgery and replay</td><td>Signed token, 15 s window</td></tr>
<tr><td>Proxy queuing</td><td>Random codes; ID checked at the window</td></tr>
</table>

<h2>VII. Ethical and Legal Considerations</h2>
<p>The system holds grades, balances, holds and requests of real students, so a leak or a wrong record can cause harm. We applied the ACM and IEEE codes of ethics [1], [2] by theme: avoid harm, protect privacy, be honest, and be accountable. Under the Data Privacy Act of 2012 [8], the system limits data to enrollment, grades, documents and clearance (legitimate purpose, proportionality), lets each user read only their own rows and each department only its own items (confidentiality), enforces rules for every role (integrity), and records every critical change in an append-only log (accountability). All test data are fictional.</p>
<p>Proposed safeguards for real use are a privacy notice for students, a written incident procedure that names who notifies the National Privacy Commission, read logging for sensitive tables, a second approver for amount changes by the Cashier, automatic retention of old logs, and a review by the university's data protection contact before real data is loaded. An AI coding assistant helped draft code and documents; the team reviewed and tested every output and approved every change to the live database.</p>

<h2>VIII. Conclusion and Future Work</h2>
<p>The Centralized Student Portal replaces physical queues and paper clearance with one role-based web system whose critical rules are enforced by the database. Evidence from unit, integration, system, performance and security tests shows that the main requirements are met. Future work includes a Realtime queue display, a student photo on the queue card, larger-scale load tests on a phone and slower networks, payment gateway integration, and the safeguards above.</p>

<h2 class="noindent">References</h2>
<ol class="refs">
<li>ACM, &ldquo;ACM Code of Ethics and Professional Conduct,&rdquo; Association for Computing Machinery, 2018.</li>
<li>IEEE, &ldquo;IEEE Code of Ethics,&rdquo; IEEE Policies, Section 7.8.</li>
<li>Supabase Inc., &ldquo;Supabase Documentation: Database and Auth,&rdquo; 2026. [Online]. Available: https://supabase.com/docs</li>
<li>PostgreSQL Global Development Group, &ldquo;PostgreSQL Documentation: Row Security Policies,&rdquo; 2026. [Online]. Available: https://www.postgresql.org/docs/</li>
<li>E. F. Codd, &ldquo;A relational model of data for large shared data banks,&rdquo; <i>Commun. ACM</i>, vol. 13, no. 6, pp. 377&ndash;387, Jun. 1970.</li>
<li>K. Schwaber and J. Sutherland, &ldquo;The Scrum Guide,&rdquo; Nov. 2020.</li>
<li>ISO/IEC/IEEE, &ldquo;Systems and software engineering: Life cycle processes: Requirements engineering,&rdquo; ISO/IEC/IEEE 29148:2018, 2018.</li>
<li>Republic of the Philippines, &ldquo;Data Privacy Act of 2012,&rdquo; Republic Act No. 10173, Aug. 2012.</li>
<li>Vercel Inc., &ldquo;Next.js Documentation,&rdquo; 2026. [Online]. Available: https://nextjs.org/docs</li>
</ol>
</div>
"""

CSS = """
@page { size: A4; margin: 18mm 15mm 20mm 15mm; @bottom-center { content: counter(page); font: 9pt 'Times New Roman', serif; } }
body { font-family: 'Times New Roman', Times, serif; font-size: 10pt; line-height: 1.25; color: #000; }
.title { font-size: 21pt; text-align: center; line-height: 1.15; margin: 0 0 8pt; }
.authors { display: grid; grid-template-columns: repeat(3, 1fr); gap: 6pt 10pt; text-align: center; font-size: 9.5pt; margin: 4pt 0; }
.authors i { font-size: 8.8pt; }
.affil { text-align: center; font-size: 9pt; font-style: italic; margin: 2pt 0 8pt; }
.cols { column-count: 2; column-gap: 7mm; text-align: justify; hyphens: auto; }
p { margin: 0 0 4.5pt; text-indent: 0; }
p.abs { font-weight: bold; font-size: 9.2pt; }
p.abs b { font-weight: bold; }
p.kw { font-weight: bold; font-size: 9.2pt; }
h2 { font-size: 10pt; font-weight: normal; text-transform: uppercase; text-align: center; margin: 9pt 0 4pt; letter-spacing: 0.3pt; break-after: avoid; }
table { border-collapse: collapse; width: 100%; margin: 3pt 0 7pt; font-size: 8.4pt; break-inside: avoid; }
caption { font-size: 8pt; text-transform: uppercase; margin-bottom: 2pt; text-align: center; caption-side: top; }
th, td { border: 0.6pt solid #000; padding: 1.5pt 3pt; text-align: left; vertical-align: top; }
th { font-weight: bold; }
.fig { break-inside: avoid; margin: 5pt 0; text-align: center; }
.fig svg { width: 100%; height: auto; }
.figw { column-span: all; margin: 6pt 0; text-align: center; }
.figw svg { width: 92%; height: auto; }
.cap { font-size: 8pt; text-align: center; margin-top: 2pt; }
ol.refs { padding-left: 16pt; font-size: 8.4pt; margin: 0; text-align: left; } ol.refs li { margin-bottom: 2pt; }
a { color: #000; text-decoration: none; }
"""
html = f'<!doctype html><html><head><meta charset="utf-8"><title>Centralized Student Portal and Automated Clearance System</title><style>{CSS}</style></head><body>{PAPER}</body></html>'
hp = TMP / 'IEEE-Paper.html'
hp.write_text(html, encoding='utf-8')
subprocess.run([EDGE, '--headless=new', '--disable-gpu', '--no-pdf-header-footer', f'--print-to-pdf={OUT_PDF}', hp.as_uri()], check=True, timeout=180)
print('wrote', OUT_PDF, OUT_PDF.stat().st_size, 'bytes')
