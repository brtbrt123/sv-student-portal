# Ethical Analysis

**System:** Centralized Student Portal and Automated Clearance System (Cabuyao University portal, Pamantasan ng Cabuyao, BS Computer Science project)
**Requirements covered:** ETH-01 and ETH-02 (`docs/documentation.md`, section 4.3), and the security requirements SEC-01 to SEC-06 where they protect people.
**GitHub issue:** #111 (professor's Task 5).
**Status:** draft by the Project Manager with Claude Code. Teammate review is still pending (see section 11). The list of frameworks must still be confirmed against what the professor discussed in class.

This document says what the system does about ethics, shows where in the system you can check it, and lists the gaps openly. It does not claim the system is perfect. It is a student prototype with fictional data.

## 1. Scope and method

The system handles student records: grades, enrollment, balances, holds, document requests and clearance. These records are personal and can affect a student's progress. A wrong or leaked record can hurt a real person.

For each theme we answer three questions: what the principle asks, what the system does (with a file or rule you can open), and what is still wrong or risky. Sections 3 to 9 follow the themes in the issue. Section 10 is a compliance checklist.

Sources used for the principles: the ACM Code of Ethics and Professional Conduct (2018), the IEEE Code of Ethics, the IEEE-CS/ACM Software Engineering Code of Ethics and Professional Practice, and Republic Act No. 10173, the Data Privacy Act of 2012. We paraphrase them. We cite the principle by its theme or name only. Exact clause numbers should be checked against the official texts before the paper is submitted.

## 2. Stakeholders and who could be harmed

| Stakeholder | What they need | How they could be harmed |
| --- | --- | --- |
| Students | Correct, private records; a fair clearance; clear reasons for holds | Another student or an outsider reads their grades or balance; a wrong hold or a wrong grade delays clearance or graduation; a locked account at a bad moment |
| Registrar staff | Tools to encode grades and approve enrollment and clearance | Blamed for changes they did not make if the log is weak; wrongly given power over data outside their job |
| Cashier staff | Record payments and charges | Blamed for a wrong amount; temptation to edit amounts (see section 8) |
| Department heads | Place and lift holds, approve their own department | Acting on students outside their department |
| Admin | Read the audit log, manage the catalog and accounts | Holds too much power; their own actions must also be visible |
| The university | Trustworthy records, legal compliance | Data breach, loss of trust, fines or complaints under the Data Privacy Act |
| The student team | A working, honest project | Claiming more than was built |
| Parents or guardians, other offices | Not users | Indirectly affected if a record is wrong. Not in scope. |

The students are the most exposed group. They have the least power in the system and the most to lose.

## 3. The codes of ethics and what they ask

We read the codes through the themes that matter for this system.

| Code | Ideas we apply | Where in this document |
| --- | --- | --- |
| ACM Code of Ethics and Professional Conduct | Avoid harm; be honest and trustworthy; be fair and do not discriminate; respect privacy; honor confidentiality; give thorough evaluations of systems and their risks; design and implement systems that are robust and secure; accept responsibility and give credit | sections 4 to 9, 11 |
| IEEE Code of Ethics | Hold public safety, health and welfare paramount; avoid conflicts of interest; be honest in claims and estimates; reject bribery; improve understanding of technology and its consequences; accept honest criticism and correct errors; treat people fairly; do not injure others | sections 4 to 9 |
| IEEE-CS/ACM Software Engineering Code of Ethics and Professional Practice | Act in the public interest; act in the interest of the client and employer within that; deliver products that meet the highest professional standards; keep independent judgment; manage honestly; support colleagues | sections 8, 9, 11 |

Plain reading of the three codes together: build software that does not hurt people, tell the truth about what it does and does not do, protect the data you hold, and take responsibility for the result.

## 4. Privacy and data minimisation

**What the principle asks.** ACM asks us to respect privacy and keep confidential what we are trusted with. The Data Privacy Act asks that personal information is collected for a clear purpose, kept to what is needed, and protected.

**What the system does.**

- **Each student sees only their own rows.** Row Level Security (RLS) is enabled on all 29 tables (`docs/database/rls.sql` holds the 49 policies of Oct 10; the newer tables add their own, SEC-02). A student cannot read another student's grades, charges or clearance. Tests: TC-12 to TC-14 and TC-30 return 0 rows; the browser check N-01 and the SQL check N-02 are in `docs/testing-plan.md`, section 6.
- **Staff see only their scope.** A Department user reads only their own department's items (TC-71, `docs/database/e2e_negative_tests.sql`). Holds can be placed only on students of the department's own programs (`docs/database/hardening2.sql`, section A).
- **Column-level grants and no anonymous access.** Signed-in users get only the columns and operations the screens need (`docs/database/grants_clearance.sql`, `grades_rules.sql`, `documents_rules.sql`, `enrollment_rules.sql`). The anonymous role has no access to any table or view (N-07: 19 of 19 anonymous statements and all 4 views denied on 2026-10-11).
- **Views use the caller's rights.** The four views are `security_invoker`, so a view never shows more than the table policies allow (`docs/database/views.sql`).
- **No passwords in our tables.** Credentials stay in Supabase Auth; `profiles.profile_id` equals `auth.users.id` (SEC-01, `docs/documentation.md` Part 3).
- **Fictional data only.** The seed has three made-up students and `@pnc.test` accounts (`docs/database/seed.sql`). No real student data is in the repository. The pre-commit scrub in `docs/database/README.md` looks for keys, tokens and connection strings before any SQL file is committed.
- **Minimisation (ETH-02).** The schema stores what enrollment, grades, charges, documents and clearance need. There is no storage of addresses, family data, health data or photos of students. The login log stores an email and an optional IP address for the Admin only.
- **No hard deletes of records.** Foreign keys use `ON DELETE RESTRICT`; users are deactivated with `profiles.is_active`, not deleted.

**Gaps and risks.**

- The IP address in `login_attempts` is personal data. It is kept for review, and nothing deletes old rows automatically. The file recommends 30 days of retention, but the cleanup is manual (`docs/database/login_lockout.sql`, "RETENTION").
- There is no written privacy notice or consent text for students in the app yet. The Data Privacy Act expects people to be informed about how their data is used. We list this as a gap in section 10.
- The Admin can read the whole audit log and can see all records by role. This is needed for the job but is a lot of power (section 7).
- The live Supabase project is labelled production and holds only fictional data. If real records were ever loaded, the legal duties in section 5 would apply in full and a separate review would be needed.

## 5. The Data Privacy Act of 2012 (Republic Act No. 10173)

The Act protects personal information in information and communications systems in the Philippines. It is overseen by the National Privacy Commission (NPC). A university that keeps student records is a personal information controller, so it has duties. This section applies the main ideas to our system. We do not cite section numbers because we have not checked them against the official text.

| Idea in the Act | Plain meaning | In this system |
| --- | --- | --- |
| Transparency | People know what is collected and why | Students see their own status and the reason for a hold in the portal. A written privacy notice is missing (gap). |
| Legitimate purpose | Data is used only for a declared, lawful purpose | The only purposes are enrollment, grades, documents and clearance (ETH-02, `docs/documentation.md`). No marketing, no sharing, no analytics tools. |
| Proportionality | Collect and keep only what is needed | Minimal schema, column-level grants, no hard deletes. Retention rules for the login log are manual. |
| Data subject rights | Access to your data, correction, objection, and in some cases erasure or blocking | Access: a student reads their own records. Correction: only through staff (Registrar, Cashier, Department). There is no self-service request form for correction or erasure; deactivation, not deletion, is the design. Gap. |
| Security measures | Organisational, physical and technical protection | See section 8. Technical: RLS, least privilege, lockout, audit log. Organisational: roles, branch rules. Physical: provided by Supabase and Vercel, not by us. |
| Breach notification | The controller must notify the NPC and affected people when a serious breach happens | The system has no breach procedure written down. The audit log can help find who changed what, but it does not record who only read data. Gap. |
| Data protection officer and registration | Controllers appoint a responsible person | Outside the scope of a student project. The university would do this. |

The ETH-01 requirement says student records are strictly confidential and inaccessible to peer student accounts. The evidence is the RLS tests above. The SQL suites TC-01 to TC-122 and the browser walks are listed in `docs/testing-plan.md` and `docs/issue-12-testing-guide.md`.

One important limit: the Act has specific rules for the handling of personal information of students and for sensitive information. We are not lawyers. This section is a good-faith mapping by students, not legal advice, and the university's own data protection office would have to review the system before real use.

## 6. Fairness and accessibility

**What the principle asks.** ACM and IEEE ask us to be fair and not to discriminate, and to treat everyone equally. In a clearance system, fairness means the same rule for every student and no hidden favours.

**What the system does.**

- **The database enforces the rules, not a person.** A department cannot approve a student who has an active hold of that department (`docs/database/trigger_dept_approval.sql`). The Cashier's Office item clears automatically when every charge is Cleared or Waived (`trigger_finance_autoclear.sql`). The Registrar cannot give final clearance while any item is pending (`trigger_final_clearance.sql`). These rules apply to every role, including the database owner (tests N-04 and N-05). A staff member cannot bend them for a friend.
- **Grades.** A grade can be saved only for an item of an Approved enrollment, and the time is stamped by the database (`grades_rules.sql`). Only the Registrar can encode.
- **Documents.** A request follows one status path: Pending, Processing, Ready, Released, or Rejected. Final states are locked. The processor and time are set by the database (`documents_rules.sql`).
- **Enrollment.** One enrollment per student per term. Approval needs at least one section, all of the same term, with a free seat. The reviewer and time are set by the database (`enrollment_rules.sql`). Seats are given by the rule, not by queue position or by knowing someone, which removes the physical queuing that was the original pain point.
- **Role limits.** Only the Registrar can approve clearance, grades and enrollment. Only the Cashier tags charges. Only a department places its own holds.
- **Accessibility.** The team's standard is WCAG AA: visible labels, 3:1 field borders, keyboard focus, checked contrast in light and dark mode, and phone and desktop equal (`PRODUCT.md`). A phone-width and dark-mode scan for every role is not complete yet (`docs/testing-plan.md`, section 1).

**Gaps and risks.**

- A rule can be fair and still produce a wrong result if the data is wrong. A mistaken hold blocks a student until staff lifts it. The student can see the hold but there is no in-app appeal button.
- Two of the four offices in the seed (College of Business Administration and College of Arts and Sciences) have no staff account, so their items were cleared by SQL in the test (D-2, `docs/testing-plan.md`). In real use, an office without a staff account would block students. That is a process risk.
- No formal accessibility audit with assistive technology has been run. We have not tested with a screen reader.
- The system is in English only.
- The interface assumes internet access and a modern browser (SRS 2.2). Students without a device still need the office. The system does not fully remove that inequality.

## 7. Accountability and the audit log

**What the principle asks.** ACM asks us to accept responsibility for our work. A system that changes records needs to show who did what, so that errors can be traced and nobody is blamed without proof.

**What the system does.**

- **Append-only audit log.** `public.audit_logs` is written by triggers on 12 tables (`docs/database/hardening2.sql`, section B, REQ-ADM-03). UPDATE, DELETE and TRUNCATE are blocked for every role, including the database owner (N-08, TC-25). The Admin can read the log but cannot change it.
- **The actor comes from the database.** The log stores the acting user. Fields like `reviewed_by`, `processed_by`, `cleared_by`, `approved_by` and `encoded_by` are checked against, or set from, the signed-in user, so a client cannot claim to be someone else (the policies in `rls.sql`, the rules files above, `docs/documentation.md` Figure 1 notes the "who did it" links to `profiles`).
- **Time comes from the database.** `encoded_at`, `processed_at`, `reviewed_at` and the payment date are stamped by the server, not typed by a user.
- **Who can do what** is visible in the policies (49) and the role list in `docs/documentation.md`, section 2.1.
- **Evidence in practice.** In the browser walk E2E-13, the Admin saw every step with its actor; a refused duplicate receipt left no row.
- **Our own process.** Branch rules and pull requests: nobody commits to `main` or `dev`; only the Project Manager merges `dev` into `main` (`docs/documentation.md`, section 7.6).

**Trade-offs.**

- *Audit versus privacy of staff.* A detailed log protects students and also records what staff do. We think this is proportionate: it logs actions on records, not browsing, and only the Admin reads it. Staff should know the log exists. A written policy for this is missing.
- *The Admin sees everything.* This is needed for the job. The Admin cannot edit the log, but the Admin role is powerful and there is no second approver. Real use would need a rule such as two named admins and a periodic review.
- *Reads are not logged.* The log shows changes, not who looked at a record. If staff peek at a record out of curiosity, we would not see it.
- *No back-fill.* The log only holds changes after 2026-10-10 (`docs/database/README.md`).

## 8. Security

**What the principle asks.** ACM asks for robust and secure systems and for us to avoid harm. A privacy promise is empty without technical protection.

**What the system does.** The professor's examples (SQL injection, brute force, rate limiting) are mapped to concrete controls.

| Threat | Control | Evidence |
| --- | --- | --- |
| Reading other people's data | RLS on every table, `SECURITY DEFINER` helper functions to avoid recursive policies (SEC-02) | `rls.sql`, TC-12 to TC-33, TC-71 |
| Too much access | Least-privilege, column-level grants for `authenticated`; anonymous has nothing; no DELETE on records | `grants_clearance.sql`, `hardening2.sql` section C, `docs/database/grants_snapshot_2026-10-10.txt` and `2026-10-11.txt` |
| Brute-force guessing | Lockout with exponential backoff: 5 failed attempts, then 1 minute, doubling, capped at 15 minutes. The check runs before the password is verified. The message is generic. Fails closed if the check cannot run. | `login_lockout.sql`, `app/(auth)/login/actions.ts`, TC-72 to TC-82 (live 2026-10-12) |
| User enumeration | A made-up email locks and unlocks exactly like a real one; the same error message for every failure | `login_lockout.sql` decision 3 (TC-78) |
| Forged login success | A success is accepted only from the signed-in owner of that email | `login_lockout.sql` decision 5 (TC-79) |
| SQL injection | Parameterized access through the Supabase client; server-side validation; the SQL functions use an empty `search_path` and schema-qualified names; email input is validated for length and control characters | SEC-05, `login_lockout.sql` decision 4. No dedicated injection test exists yet (see `docs/testing-plan.md`). |
| Denial of service by flooding | Rate limiting at the Vercel firewall or a shared store (SEC-04) | Issue #91. Live since 2026-10-12 as a Vercel firewall rule (20 POST requests per minute per IP, HTTP 429), tested on the sign-in route (`docs/rate-limiting.md`). It does not cover direct calls to the Supabase Auth endpoint. |
| Leaked privileged key | The server-side admin key (`SUPABASE_ADMIN_KEY`) is read only in `lib/supabase/admin.ts` and used only in server code: creating a student account when an application is accepted, the Admin staff-account actions, and one read of the applicant type (finding SF-6). Every other read and write uses the signed-in user's session. `.env.local` is git-ignored. A pre-commit scrub searches the SQL files. | SEC-06, `docs/database/README.md` "Security rules", `HANDOFF.md` |
| Hidden exposure in the platform | While rehearsing the lockout (TC-81), we found that Supabase's own helper `rls_auto_enable()` could be executed by the anonymous role. It returns an event trigger, so the API could not call it, but nobody except the owner needs it. We revoked the access in the same change. | `login_lockout.sql`, near line 418 |
| Tampering with history | Audit log is append-only; guard triggers protect immutable columns | `hardening.sql`, `hardening2.sql` |

Process security: every database change is rehearsed in a rolled-back transaction before it runs live, has a rollback block, and is followed by the regression suite (`docs/database/README.md`, execution order).

**Residual risks (stated in the SQL header and repeated here).**

- **R1: lockout can be abused.** Anyone who knows a student's email can keep that account locked by failing on purpose each time the lock expires. The lock is capped at 15 minutes, but the real student cannot sign in meanwhile. This is the classic trade-off: protection against guessing creates a way to deny service to one person. We chose a cap and ignored extra failures while locked so the abuse cannot grow faster than real time. The Admin can delete the rows for an email. The per-IP rate limit (issue #91) is the intended second layer.
- **R2: direct calls to Supabase Auth skip the lockout.** The anon key is public, so an attacker can call the Supabase Auth password endpoint directly. Supabase Auth has its own per-IP limits, and a CAPTCHA option exists, but closing this fully needs an auth hook that is a paid feature. So the lockout is real protection for people using our login page, not a full guarantee.
- **R3: a race.** A burst of parallel attempts can exceed five guesses before the first lock is recorded.
- **R4: the lock state of any email is visible** (locked or not, and seconds), but not whether the account exists.
- **Cashier can edit charge amounts.** The Cashier role can change `charges.amount`. We kept it on purpose because the Cashier encodes charges by hand and there is no payment gateway. Every change is audited. It is still a fraud risk and a fairness risk for students (`docs/sprint-3-plan.md`, known gaps). Next step: restrict amount edits to creation, or require a second role for changes.
- **No teammate has reviewed any pull request yet** (0 reviews on #58 to #88 at the last count in `HANDOFF.md`). The rule exists on paper (`docs/documentation.md`, section 7.6) but was not followed. This weakens every claim above, because one person's mistake could pass unseen. It is a team task (issue #115).
- **Production label.** The Supabase project is labelled production while it only holds test data. Test data was changed by the browser walk (D-1) and cannot be un-logged.
- **Performance and availability** (PER-01, PER-02) have not been measured. Slow or unavailable services also harm students at deadline time.

## 9. Transparency and honesty

**What the principle asks.** ACM and IEEE ask us to be honest about what our systems do and do not do, and to give honest estimates and claims.

**What the system does.**

- **Students see their own status.** The clearance page and dashboard show every office, who is holding it up, the reason for a hold, and what is next (`PRODUCT.md`, principle 2). The Registrar's button is disabled with a visible reason (E2E-10).
- **Friendly, specific error messages.** For example: "This receipt number is already used. Use a new one." (E2E-06); "Approval is blocked. Lift the active hold first." (E2E-03); a clear message for a duplicate clearance request (E2E-02). Database rules return a stable error prefix (`active hold:`, `pending items:`, `bad status change:`, `section full:`) that the app turns into plain language.
- **No screen shows made-up data.** The "Sample data" label and the mock data files were removed on Oct 14, 2026, when the last screen (the Student dashboard, PR #154) was connected to the database. The first-year curriculum, section schedules and capacities in the database are still SAMPLE rows until the Registrar and Admin enter real ones. Re-check on the day of submission.
- **Known gaps are written down, not hidden.** `docs/sprint-3-plan.md`, `docs/testing-plan.md` (findings F-1 to F-4, D-1, D-2) and the SQL headers list failures and risks. Failures stay in the record instead of being edited out.
- **Dates and status.** The SQL README marks each file with whether and when it was run live. The login lockout header said "NOT RUN YET" while it was untested, and was updated after the live run.

**Gaps we state openly.**

- No teammate review of pull requests yet.
- The lockout can be abused (R1) and can be bypassed by calling Supabase Auth directly (R2).
- The Cashier can edit charge amounts (audited).
- `types/database.types.ts` is written by hand, not generated, so it can drift from the database.
- `Database_Design_ERD_3NF.docx`, which `docs/documentation.md` cites for the normalization proof and rules R1 to R12, is not in the repository. The documentation should be reworded or the file added (issue #112).
- Some documents still say the deadline is Oct 12; the real final deadline is Oct 15 (issue #114).
- Performance requirements are not measured; unit and acceptance tests are not yet complete (issue #110).
- The public name is "Cabuyao University" in the app and "Pamantasan ng Cabuyao" in the documents (`PRODUCT.md`). Photos in `public/photos` have an unknown license, and one is of a different campus; none should be presented as Cabuyao.

## 10. Compliance checklist against the Data Privacy Act principles

"Met" means we have evidence in the repository. "Partly" and "Gap" mean what they say. This is a self-assessment, not a certification.

| Principle | What the Act asks | Status | Evidence | What is missing |
| --- | --- | --- | --- | --- |
| Transparency | Tell people what is collected, why, and how it is handled | Partly | Students see their own records, status and hold reasons; `PRODUCT.md` principles; ETH-02 | A written privacy notice in the app; a policy for staff on the audit log |
| Legitimate purpose | Collect for a declared, lawful purpose only | Met for the prototype | Purposes limited to enrollment, grades, documents, clearance (`docs/documentation.md` Charter and SRS); no third-party sharing or analytics in the code | A formal statement of purpose approved by the university |
| Proportionality | Collect and keep only what is needed, in a way that fits the purpose | Mostly met | Minimal schema (29 tables); column-level grants; no hard deletes; fictional seed (`seed.sql`) | Retention rule for `login_attempts` is manual; no retention plan for audit and academic rows |
| Confidentiality (security measure) | Only authorised people can read the data | Met in tests | RLS on all 29 tables; TC-12 to TC-33, TC-71; N-01, N-02, N-07 | An independent security review; no read logging |
| Integrity (security measure) | Data is not changed in unauthorised ways | Met in tests | Triggers for holds, finance, final clearance, grades, documents, enrollment; append-only audit log (TC-25) | Cashier can edit amounts (audited) |
| Availability (security measure) | Data is accessible when needed | Partly | Hosted on Vercel and Supabase | PER-01 and PER-02 not measured; rate limiting must be confirmed (issue #91) |
| Access control and authentication | Strong sign-in and protection against guessing | Partly | Supabase Auth, lockout (SEC-03), generic errors | R1 to R3; direct calls to Supabase Auth skip the lockout |
| Data subject rights | Access, correction, objection, erasure or blocking where allowed | Partly | Students read their own records | No self-service correction or erasure request; correction goes through staff |
| Breach management | Detect, contain and notify | Gap | Audit log helps find changes | No written incident procedure; no read log; nobody named to notify the NPC |
| Accountability | Be able to show compliance | Partly | This document; testing plan; SQL headers | Teammate review pending; no university data protection officer involved |

## 11. AI assistance in building the system

The team used Claude Code (an AI coding assistant) during the project, for example to draft SQL, application code, tests and documents. The assistant ran commands in the working folder, and the Project Manager approved pushes, pull requests and every change to the live database.

What this means ethically, in line with the ACM principle of accepting responsibility and the IEEE principle of honesty:

- **The team is responsible for the result.** AI output is a draft. The team must read, run, test and understand it. The professor's Q&A checks that.
- **Verification matters.** AI-generated results were checked with `npx tsc --noEmit`, `npx eslint`, `npm run build`, rehearsals in rolled-back transactions and the SQL and browser test suites. Delegated results were checked by the lead, and in at least one case an assistant report of a gap was false and was corrected on spot-check (`HANDOFF.md`).
- **Secrets.** The assistant was told never to read or print `.env.local`, passwords or the server-only key, and a repository hook blocks commands that name that key.
- **Authorship and credit.** Commits made with the assistant carry a co-author line.
- **Verification reports.** The professor asked for plagiarism-checker and AI-detector reports. These are team tasks tracked in issue #115. **They are pending. No results exist yet, and none are reported here.**
- **Limits of detectors.** Detector tools are not proof either way. We will report the numbers we get and explain how the work was produced.

## 12. Ethical risks and trade-offs in short

| Trade-off | Choice we made | Cost |
| --- | --- | --- |
| Lockout versus denial of service | Lockout with a 15-minute cap and ignoring failures while locked | A victim can still be kept out (R1) |
| Audit versus staff privacy | Log changes only, Admin read-only | Reads are not logged; no staff policy yet |
| Admin sees everything | Needed to run the system; the log is append-only for Admin too | One powerful role, no second approver |
| Rules in the database versus flexibility | Rules enforced for every role | Staff cannot make a one-off exception; a wrong hold needs a staff fix |
| Cashier editing amounts | Kept, audited | Fraud risk |
| Speed of delivery versus review | Short sprints, tests, rehearsals | No teammate review yet |
| Realistic demo versus privacy | Fictional data in a production-labelled project | The label may confuse; real data must never be loaded without a new review |

## 13. What we would do next

1. Add a stricter per-IP limit for the sign-in route and test the write actions one by one (the first rule covers all POST requests).
2. Get a teammate to review every open pull request, and record it (issue #115).
3. Write a short privacy notice for students and a staff notice about the audit log.
4. Add a breach and incident procedure and name who notifies the NPC.
5. Restrict Cashier edits of charge amounts, or add a second approver for changes.
6. Add read logging for sensitive tables, or at least for the Admin.
7. Automate retention for `login_attempts` (30 days is recommended in `login_lockout.sql`).
8. Generate `types/database.types.ts` from the database, and add the 3NF document to the repository.
9. Run an accessibility check with a screen reader and phone and dark-mode scans for every role.
10. Add a student appeal or correction request flow for holds and grades.
11. Test the Supabase Auth endpoint directly and consider an auth hook or CAPTCHA.
12. Have the university's data protection contact review the system before any real data is used.

## 14. Traceability

| Requirement | Evidence in this document |
| --- | --- |
| ETH-01 (comply with data privacy principles; records inaccessible to peers) | sections 4, 5 and 10; tests N-01, N-02, N-07, TC-12 to TC-33, TC-71 |
| ETH-02 (data minimisation) | sections 4 and 10; `schema.sql`, `grants_*.sql`, `seed.sql` |
| SEC-01 to SEC-06 | section 8 |
| REQ-ADM-03 (audit log) | section 7 |

## 15. References for the paper (to be put in IEEE style by the PM)

- ACM, "ACM Code of Ethics and Professional Conduct," 2018.
- IEEE, "IEEE Code of Ethics."
- ACM and IEEE Computer Society, "Software Engineering Code of Ethics and Professional Practice."
- Republic of the Philippines, Republic Act No. 10173, "Data Privacy Act of 2012." National Privacy Commission.

Authors, dates, URLs and access dates must be taken from the official sources by the PM. They are not filled in here to avoid errors.
