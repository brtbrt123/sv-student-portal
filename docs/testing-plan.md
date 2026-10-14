# Software Testing Plan

Organised in the six test levels the professor asks for: **unit, integration, system, acceptance, performance, security**.
Started in Sprint 3 for the clearance slice (GitHub issue #69, SDLC section 7.7). Reorganised in Sprint 4 (GitHub issue #110)
and extended with the grades, documents, enrollment and login lockout work of 2026-10-12.

Honesty rule: every result below was recorded when the test ran. Nothing is copied from the expected column.
Failures and findings stay in this file. Anything not done says "Not done" with the plan for it.

Last updated: 2026-10-12 (Sprint 4, day 1). This file is still being filled in (see section 14).

## 1. Scope and objectives

In scope: the Cabuyao University portal on the live Supabase project. The clearance path (student request to the Registrar's
final clearance, with the audit trail) plus, since 2026-10-12, grades, document requests, enrollment and the login lockout.

| Area | Requirements |
| --- | --- |
| Student requests clearance, sees every office | REQ-STU-03, REQ-STU-06 |
| Department lifts holds and approves | REQ-DPT-01, REQ-DPT-02, REQ-DPT-03 |
| Cashier logs payments and tags charges; Finance clears automatically | REQ-CSH-01, REQ-CSH-02, REQ-CSH-03 |
| Registrar issues final clearance only when every office has cleared | REQ-REG-03 |
| Admin reads the audit log, read-only | REQ-ADM-03 |
| Student sees grades; Registrar encodes grades | REQ-STU-02, REQ-REG-01 |
| Student requests documents; Registrar processes them; ticket and status | REQ-STU-04, REQ-REG-02, REQ-DOC-01, REQ-DOC-02 |
| Student enrolls; Registrar approves or rejects | REQ-STU-05, REQ-REG-04 |
| Brute-force protection (login lockout) | SEC-03 |
| Isolation between students, roles and anonymous users | ETH-01, SEC-02 |

Not covered yet (see section 12): Admin user accounts and academic catalog screens (REQ-ADM-01, REQ-ADM-04), rate limiting
(SEC-04, tested on the sign-in route only), unit tests, performance, acceptance sign-off, phone-width and dark-mode scans for every role, CSV export
in the browser.

## 2. Accounts

Test accounts live in Supabase Auth (created by the Project Manager; passwords are never in the repo or in chat).

| Role | Account | Person in the data |
| --- | --- | --- |
| Admin | admin@pnc.test | |
| Registrar | registrar@pnc.test | Cruz, Rey |
| Cashier | cashier@pnc.test | Diaz, Cora |
| Department (College of Computer Studies) | dept@pnc.test | Tan, Hal |
| Student 1 | student1@pnc.test | Reyes, Ana (2026-0001, BSCS) |
| Student 2 | student2@pnc.test | Santos, Ben (2026-0002, BSIT) |
| Student 3 | student3@pnc.test | Mendoza, Carla (2026-0003, BSBA) |

The College of Business Administration and the College of Arts and Sciences have no staff accounts in the seed, so their
clearance items can only be cleared by SQL as the database owner (recorded as test setup where it was used).

## 3. Environment and how results are recorded

- Database: the Supabase project `sv-student-portal` (labelled production), Data API with column-level grants, the triggers
  and rules of issues 22 to 24 and of the Sprint 4 files live.
- Application: Next.js 16 dev server on `http://localhost:3000`, the Claude desktop app's browser pane, against the live data.
  The live site is `https://sv-student-portal-beta.vercel.app`.
- Who runs what: the Project Manager signs in to each account in the browser pane and pastes and runs SQL in the Supabase SQL
  editor; Claude drives the pages, reads the result row or the page text, and records it here.
- Each SQL change was first rehearsed in a rolled-back transaction, then run live, then its test file was run live.
- Each case lists: the steps, the expected result, the actual result with the date, and Pass or Fail (or "Not done").
  A failure is filed as a GitHub issue and stays in this file.
- SQL cases end with `rollback;` or use throwaway data. The browser walks changed the seed data (section 11, D-1 and D-3).
- Rolled-back tests still use up sequence values, so ticket numbers jump (for example DR-2026-000054).

## 4. The six levels at a glance

| Level | Evidence we have | Result so far | Main gaps |
| --- | --- | --- | --- |
| 1. Unit | None. The project has no unit test framework yet | Not done | All of it. Planned in issue #107 (owner and date not set) |
| 2. Integration | SQL suites TC-01 to TC-71 (clearance slice, hardening) and TC-72 to TC-122 (lockout, grades, documents, enrollment), all run on the live database | Pass (some rehearsal failures found real defects, section 6) | App-to-database calls are only covered through the browser checks of level 3. TC-94 has no recorded file |
| 3. System | Browser walk E2E-01 to E2E-13 (clearance, 2026-10-11) and browser checks S-01 to S-12 (2026-10-12, grades, documents, enrollment, lockout in the app) | Pass, with the gaps on the right | Student enrollment submit/add/remove forms, Reject button, friendly error messages, audit rows of the new writes, phone width, dark mode, every role on the deployed site |
| 4. Acceptance | None run | Not done | A script per SRS requirement with a sign-off by team members (section 9). Nobody is assigned yet |
| 5. Performance | None measured | Not done | PER-01 (2.5 s) and PER-02 (500 ms) never measured (issue #109) |
| 6. Security | Isolation, grants, audit and lockout tests (SQL and browser); vulnerabilities table in section 10 | Partly done: 3 of the candidate vulnerabilities have a fix and a recorded test (rls_auto_enable, brute force, rate limiting) | SQL injection has no direct test; rate limiting tested on the sign-in route only; lockout residual risks not tested; at least 3 vulnerabilities with solutions needed |

## 5. Level 1: Unit testing

Goal: test single functions (validation, formatting, status rules) without the database or the browser.

| ID | What | Status | Planned |
| --- | --- | --- | --- |
| UNIT-* | No unit test exists. No test framework is installed in the project | Not done | Issue #107. Owner: not assigned. Date: not set |

Nothing here has been run. The database triggers are unit-like checks of single rules, but they are recorded as integration
tests in section 6 because they run against the live database.

## 6. Level 2: Integration testing (database suites)

Each case is a SQL script run by the Project Manager in the Supabase SQL editor, result rows read by Claude. Details of
TC-01 to TC-70: `docs/issue-12-testing-guide.md`. Files: `docs/database/` (table in `docs/database/README.md`).

| Suite | Cases | Evidence file | Date run live and who | Result |
| --- | --- | --- | --- | --- |
| Routing (browser) | TC-01 to TC-11 | `docs/issue-12-testing-guide.md` | 2026-10-10, Claude on localhost (TC-11 by the PM) | Pass |
| Isolation, hardening, views, regression | TC-12 to TC-33 | `docs/database/regression_after_grants.sql` | 2026-10-11 after every change; 22 results identical each time | Pass |
| Grants for the clearance slice | TC-34 to TC-40 | `docs/database/grants_clearance_test.sql` | 2026-10-11 (live; TC-40 through the app) | Pass |
| Trigger: no approval with an active hold | TC-41 to TC-48 | `docs/database/trigger_dept_approval_test.sql` | 2026-10-11 | Pass |
| Trigger: Finance clears automatically | TC-49 to TC-61 | `docs/database/trigger_finance_autoclear_test.sql` | 2026-10-11 | Pass |
| Trigger: final clearance needs every item | TC-62 to TC-70 | `docs/database/trigger_final_clearance_test.sql` | 2026-10-11 | Pass |
| Negative case: another department's item | TC-71 | `docs/database/e2e_negative_tests.sql` | 2026-10-11 | Pass |
| Login lockout (SEC-03) | TC-72 to TC-82 (11 cases) | `docs/database/login_lockout_test.sql` | 2026-10-12, PM ran, Claude read | 11 of 11 Pass live. The rehearsal first found a FAIL on TC-81 (finding F-5) |
| Grades rules (REQ-REG-01) | TC-83 to TC-93 (11 cases) | `docs/database/grades_rules_test.sql` | 2026-10-12, PM ran, Claude read | Pass live |
| Document request rules (REQ-DOC-01, REQ-DOC-02) | TC-95 to TC-108 (14 cases) | `docs/database/documents_rules_test.sql` | 2026-10-12, PM ran, Claude read | 14 of 14 Pass live. The rehearsal first found 2 failures (finding F-6) |
| Enrollment rules (REQ-STU-05, REQ-REG-04) | TC-109 to TC-122 (14 cases) | `docs/database/enrollment_rules_test.sql` | 2026-10-12, PM ran, Claude read | Pass live, first time |
| Regression after each Sprint 4 change | TC-12 to TC-33 | `docs/database/regression_after_grants.sql` | 2026-10-12, re-run after the lockout, after grades and documents, and after enrollment | Unchanged each time: 15 cells OK plus one known CHECK cell on TC-24 (the seed data was changed by the 2026-10-11 browser walk, D-1) |

Notes:
- TC-94 does not appear in any test file. It is not recorded as a case. Not run, not claimed.
- The Sprint 4 files of this table (TC-72 to TC-122) are in the pull requests of Sprint 4 (PR #119 for grades, documents and
  enrollment). Until a PR is merged, its file may not be on every branch. The `docs/database/README.md` rows are the index.
- Each Sprint 4 SQL change was rehearsed first (`*_rehearsal.sql`, one rolled-back transaction). Rehearsal failures are
  recorded here as findings, not edited out.

Mapping of TC ranges to areas:

| Area | TC range |
| --- | --- |
| Routing and role redirects | TC-01 to TC-11 |
| Data isolation, anon denied, audit log, views | TC-12 to TC-33 |
| Least-privilege grants | TC-34 to TC-40 |
| Clearance rules (hold, Finance, final) | TC-41 to TC-71 |
| Login lockout | TC-72 to TC-82 |
| Grades | TC-83 to TC-93 |
| Documents | TC-95 to TC-108 |
| Enrollment | TC-109 to TC-122 |

## 7. Level 3: System testing (browser, end to end)

### 7.1 The clearance chain (browser, 2026-10-11)

Run by: Project Manager (signed in) and Claude (drove the pages, read the page text), localhost, live data.

Subject: Santos, Ben (student2). Start state: clearance 2 for 1st 2026-2027 with 0 of 4 offices cleared, an active
CCS hold ("Missing lab equipment"), one unpaid charge of 15,000.

| ID | Role and steps | Expected | Actual (2026-10-11) | Result |
| --- | --- | --- | --- | --- |
| E2E-01 | Student requests clearance. With a throwaway current term (2098-2099, removed afterwards) student2 and student1 each clicked "Request clearance" | A clearance with one item per office is created; a notice confirms it | Clearance created with 4 pending items each; notice "Clearance requested. Each office will now review it." The trigger created the items. | Pass |
| E2E-02 | Student requests a second time (stale second tab) | One clearance per student per term; a clear message; no second row | Notice "You already requested clearance for this term..." and the existing clearance; no second clearance (first attempt showed no message: defect fixed in the same pull request, see section 11) | Pass |
| E2E-03 | Department: open Clearance Items with Ben's hold active | Ben's Approve is blocked with a reason | Approve disabled; text "Approval is blocked. Lift the active hold first." | Pass |
| E2E-04 | Department: lift Ben's hold | Hold shows lifted, by whom and when; active holds 0 | "Hold lifted for Santos, Ben. You can approve the item now."; lifted Oct 11, 2026 by Tan, Hal (you); active holds 0 | Pass |
| E2E-05 | Department: approve Ben's CCS item | Item cleared with the server date | "Approved for Santos, Ben."; Ben moved to Decided, cleared Oct 11, 2026; department cleared count 1 to 2 | Pass |
| E2E-06 | Cashier: log a payment with an existing receipt number (OR-0001) | Refused with a clear message; nothing written | "This receipt number is already used. Use a new one."; payments still 2, collected 20,000 | Pass |
| E2E-07 | Cashier: log Ben's 15,000 under OR-0003 | Payment recorded with the server date; balance 0 | "Logged 15,000 as receipt OR-0003."; payments 3, collected 35,000, date Oct 11, 2026 | Pass |
| E2E-08 | Cashier: tag Ben's charge Cleared | Charge Cleared; Finance item clears by itself | "Charge marked Cleared..."; on Finance Clearance Ben's item Cleared with no manual step, finance items cleared 1 to 2, outstanding 25,000 to 10,000 | Pass |
| E2E-09 | Setup (SQL, owner): clear Ben's College of Business Administration and Arts and Sciences items (no staff accounts exist for those offices) | 2 rows updated | 2 rows (items 7 and 8 of clearance 2) | Setup |
| E2E-10 | Registrar: select Carla's request (0 of 4) | Final clearance button disabled with a visible reason | Disabled; "...offices have not cleared yet: Cashier's Office, College of Computer Studies, College of Business Administration, College of Arts and Sciences." | Pass |
| E2E-11 | Registrar: select Ben's request (4 of 4) and issue final clearance | Button enabled; clearance approved with the approver and date | "Santos, Ben has cleared every office. Final clearance can be issued." then "Final clearance issued."; 4 of 4, Approved, "approved by Cruz, Rey on Oct 11, 2026"; Issued count 1 | Pass |
| E2E-12 | Student 2: open the clearance page and dashboard | Everything cleared and approved | 4 of 4 cleared, "Registrar final approval: Approved", "Your clearance is complete."; dashboard agrees but still shows the old hint line (finding F-1) | Pass, with finding F-1 |
| E2E-13 | Admin: open the audit log | Every step above is present with the actor | Hold lifted and CCS item cleared (Hal Tan, 22:45), payment OR-0003 and charge Cleared and Finance item cleared (Cora Diaz, 22:47), items 7 and 8 (System, the setup SQL), clearance approved (Rey Cruz, 22:49); the refused duplicate receipt left no row; 31 entries | Pass |

### 7.2 Grades, documents, enrollment and lockout in the app (browser, 2026-10-12)

Run by: Claude drove the browser on localhost against the live data; the Project Manager signed in. Each page was opened after
the matching SQL file went live. These checks used the live seed data.

| ID | Role and steps | Expected | Actual (2026-10-12) | Result |
| --- | --- | --- | --- | --- |
| S-01 | Login lockout: with a made-up email, 5 wrong passwords, then a 6th try | 5 times the generic message; the 6th is refused as locked, without checking the password | 5 wrong passwords gave the generic message. The 6th gave "Too many failed sign-in attempts. Try again in 1 minute." | Pass |
| S-02 | Login still works for a real account (student1) after the lockout test | Sign-in succeeds | Signed in as student1 | Pass |
| S-03 | Student (Ana): open the grades page | Own grades only, from the database | 3 grades, GWA 1.75 | Pass |
| S-04 | Student (Ana): submit a new document request | Request created; the database makes the ticket number | New request got ticket DR-2026-000054 from the database | Pass |
| S-05 | Registrar: open the documents screen and move that request Pending, Processing, Ready | Only legal buttons are offered; each step saves | Moved Pending to Processing to Ready; only legal buttons offered | Pass |
| S-06 | Registrar: open the grades screen | Encoded grades show; a grade can be saved again | 6 of 6 encoded; re-saved one grade, message "Saved 1.75" | Pass |
| S-07 | Registrar: open the enrollments screen and approve Ben's pending enrollment | Approved, with the reviewer named, final; seats counted | "Approved ... by Cruz, Rey. This decision is final."; seats 2/40 in each section | Pass |
| S-08 | Student (Ben): open the enrollment screen after approval | Status Approved with the sections | Approved, 3 subjects, 9 units | Pass |

Not verified in the browser (stays "Not done", section 12):
- the student enrollment forms (submit, add a section, remove a section): all seed students already have an enrollment;
- the Reject button on the Registrar enrollments screen;
- the friendly error messages of the new screens;
- the audit rows written by the browser tests of 2026-10-12;
- the same checks on the deployed Vercel site.

## 8. Negative and isolation cases (support levels 2, 3 and 6)

| ID | Case | Expected | Actual | Result |
| --- | --- | --- | --- | --- |
| N-01 | Student A cannot see student B (browser) | Each student sees only their own clearance | Student 1: 2 of 4, no hold. Student 2: 0 of 4 with the CCS hold. None of the other's items appeared (2026-10-11) | Pass |
| N-02 | Student 1 reads student 2's data (SQL, TC-12 to TC-14, TC-30) | 0 rows | All 0; views show own rows only (2026-10-10, again 2026-10-11 after the grants and each trigger, again 2026-10-12 after the Sprint 4 changes) | Pass |
| N-03 | A department cannot read or approve another department's item (SQL, TC-71, `docs/database/e2e_negative_tests.sql`) | 0 other items visible; approve changes 0 rows; item stays pending | other_items_visible 0; dept_approves_other_office "rows 0"; still_pending true; "-> OK" (2026-10-11) | Pass |
| N-04 | Approval with an active hold fails (SQL, TC-42, TC-45, TC-47) | Error "active hold: ..."; no audit row | Blocked for the Department user and for postgres; the Cashier's Financial item ignores a Department hold and is blocked by a Financial hold (2026-10-11, live) | Pass |
| N-05 | Final clearance with a pending item fails (SQL, TC-63, TC-64, TC-67; UI E2E-10) | Error "pending items: ..."; the Financial item alone also blocks | Blocked for the Registrar and postgres; a clearance with no items is also refused (2026-10-11, live) | Pass |
| N-06 | Non-Registrar roles cannot approve a clearance (SQL, TC-66, TC-39) | 0 rows | Student, Cashier and Department: rows 0 | Pass |
| N-07 | Anonymous has no access to any exposed object (SQL, TC-35, TC-33, TC-16) | Permission denied | 19 of 19 anon statements and all 4 views denied (2026-10-11, live) | Pass |
| N-08 | The audit log cannot be changed (SQL, TC-25) | UPDATE, DELETE and TRUNCATE blocked, even as postgres | All three blocked (2026-10-11 regression) | Pass |
| N-09 | Routing: a role cannot open another role's module (TC-03 to TC-10) | Redirect to the role's home | All redirect (2026-10-10, localhost) | Pass |
| N-10 | Anon and students cannot read or write `login_attempts`; anon cannot call the private lockout helpers (TC-80, TC-81) | Permission denied | Pass live 2026-10-12, after the fix of finding F-5 (TC-81 first FAILED in the rehearsal) | Pass |
| N-11 | A student cannot write grades, change another student's document request, or decide an enrollment (TC-85, TC-97 to TC-99, TC-119) | Denied or 0 rows | Pass live 2026-10-12 (PM ran, Claude read) | Pass |

## 9. Level 4: Acceptance testing

Goal: a script of the SRS requirements, each with an acceptance check, run by team members, with the date and a sign-off.

Status: **Not done.** Nobody is assigned yet. Planned: before the freeze on 2026-10-15 (issue #110, #115). Owner: to be
named by the Project Manager. The Project Manager and Claude ran the system checks of section 7, which are not a team
sign-off and do not count as acceptance.

Planned acceptance script (checks to run on the live site; each needs a name and a date when run):

| ID | Requirement | Acceptance check | Run by | Date | Result |
| --- | --- | --- | --- | --- | --- |
| ACC-01 | REQ-STU-01 | A student signs in with university credentials and lands on the student home | not assigned | | Not done |
| ACC-02 | REQ-STU-02, REQ-REG-01 | A student sees their own grades and enrollment status; the Registrar encodes a grade | not assigned | | Not done |
| ACC-03 | REQ-STU-03, REQ-STU-06 | A student requests clearance and sees every office | not assigned | | Not done |
| ACC-04 | REQ-STU-04, REQ-REG-02, REQ-DOC-01, REQ-DOC-02 | A student requests a document, gets a ticket, the Registrar moves it to Released | not assigned | | Not done |
| ACC-05 | REQ-STU-05, REQ-REG-04 | A student submits an enrollment; the Registrar approves or rejects it | not assigned | | Not done |
| ACC-06 | REQ-DPT-01 to REQ-DPT-03 | A department lifts a hold and approves only its own students | not assigned | | Not done |
| ACC-07 | REQ-CSH-01 to REQ-CSH-03 | The Cashier logs a payment and tags a charge; Finance clears by itself | not assigned | | Not done |
| ACC-08 | REQ-REG-03 | The Registrar issues the final clearance only when every office cleared | not assigned | | Not done |
| ACC-09 | REQ-ADM-02, REQ-ADM-03 | A role cannot open another role's module; the Admin reads the audit log | not assigned | | Not done |
| ACC-10 | PER-03 | A change merged to main appears on the live site | not assigned | | Not done |

## 10. Level 5 and level 6

### 10.1 Level 5: Performance testing

Status: **Not done.** Nothing was measured. PER-01 (UI loads in under 2.5 s) and PER-02 (grade and clearance queries under
500 ms) have no result. Planned: issue #109. Owner and date: not set.

| ID | Requirement | What to measure | Status |
| --- | --- | --- | --- |
| PERF-01 | PER-01 | Page load time of the main pages on the live site | Not done |
| PERF-02 | PER-02 | Query time for grades and clearance status (for example `EXPLAIN ANALYZE` on the views) | Not done |

### 10.2 Level 6: Security testing

Professor's rule: address at least 3 specific vulnerabilities, each with a solution (examples: SQL injection, brute-force,
rate limiting).

**Vulnerabilities table**

| ID | Vulnerability | Solution | Test evidence | Status |
| --- | --- | --- | --- | --- |
| V-1 | `public.rls_auto_enable()` (a Supabase helper function) was executable by `anon`. Found by TC-81 in the rehearsal of the lockout file, 2026-10-12 | Revoke EXECUTE from anon (in `docs/database/login_lockout.sql`) | TC-81 failed in the rehearsal, passed live after the fix (2026-10-12) | Fixed |
| V-2 | Brute-force on the login (SEC-03) | Login lockout with exponential backoff: 5 failures, 60 s doubling, cap 900 s, 24 h window; checked before the password (`docs/database/login_lockout.sql`) | TC-72 to TC-82 (11 of 11 pass live, 2026-10-12); in the app, 5 wrong passwords then "Too many failed sign-in attempts. Try again in 1 minute." with no password check (S-01) | Fixed, with residual risks below |
| V-3 | Request flooding / denial of service (SEC-04, rate limiting) | Vercel firewall rule "Limit POST requests per IP" (POST, fixed window 60 s, 20 requests per IP, answer 429) | `docs/rate-limiting.md` | **Fixed and tested 2026-10-12**: 60 quick POSTs to `/login` got 429 after about 24 (approximate count; see the file for all runs, including two earlier runs that found nothing because the rule was not yet enforcing) |
| V-4 | A document request could not take remarks while Pending (a rule conflict: the table check forbids `processed_by` on Pending, the policy demands it). Found by the documents rehearsal, 2026-10-12 | Trigger and tests changed so the database sets the fields itself | All 14 cases pass live (TC-95 to TC-108), including the "remarks while Pending" case (2026-10-12) | Fixed |
| V-5 | SQL injection (SEC-05) | All database access goes through the Supabase client with parameters; the test SQL files and the app build no SQL from user input | No direct test. The grants, RLS and trigger tests show that raw columns cannot be written by a client, which limits the damage, but this is not an injection test | **Not done**: a direct test (hostile strings in the forms) is planned in issue #108. Owner and date not set |

Residual risks of the login lockout (V-2), written in the header of `login_lockout.sql`, **not tested**:
- An attacker can lock a real user out by sending wrong passwords for that email (denial of service on one account).
- Direct calls to the Supabase Auth endpoint skip the lockout, because the lockout runs in the app's login action.
- A race between the check and the sign-in can let a few extra tries through.

**Security test cases**

| Check | Cases | Date | Result |
| --- | --- | --- | --- |
| Row Level Security isolation between students and roles | N-01 to N-09, TC-12 to TC-33 | 2026-10-10 to 2026-10-12 | Pass |
| Anon has no access to exposed objects | N-07, TC-35, TC-88, TC-122 | 2026-10-11 and 2026-10-12 | Pass |
| Append-only audit log | N-08, TC-25, TC-93 | 2026-10-11 and 2026-10-12 | Pass |
| Least-privilege column grants (client cannot set ticket, dates, reviewer, `encoded_at`) | TC-34 to TC-40, TC-92, TC-97, TC-120 | 2026-10-11 and 2026-10-12 | Pass |
| Brute-force lockout (database) | TC-72 to TC-82 | 2026-10-12 | Pass |
| Brute-force lockout (app) | S-01, S-02 | 2026-10-12 | Pass |
| No account enumeration (a made-up email behaves like a real one) | TC-78 | 2026-10-12 | Pass |
| Rate limiting | `docs/rate-limiting.md` | 2026-10-12 | Pass (approximate count; sign-in route only) |
| SQL injection test | none | | Not done |
| Secret handling (no `service_role` key in the repo or browser) | `docs/database/README.md` gives a pre-commit scrub command. No recorded run as a test case | | Not done as a recorded test |

### 10.2.1 Issue #108: security tests and vulnerability patching (record of 2026-10-14)

**Read this first.** This record was written from a source-only copy of the repository (a ZIP: no `.git`, no `node_modules`,
no network, no Supabase credentials, no test accounts). So: static review and the dependency-free local checks were done;
everything that needs the database, the Vercel deployment, `npm` or a browser was **not run**. Nothing below marks an unrun test
as Pass. Where a status says "Pass (local check)", it means the check of `scripts/security/local-checks.mjs` passed against the source
files, which is not the same as observing the live behavior. Run by (name of the person for the live runs): ____________ . Static
review and local checks: Claude, 2026-10-14.

**Status key:** Pass = observed and as expected. Fail = observed and not as expected. Blocked = could not run here. Not Run = written but not executed.

| Item | Result |
| --- | --- |
| Local checks (`node scripts/security/local-checks.mjs`) | 24 of 24 pass, 2026-10-14. The script was also shown to fail when two headers were removed (22 of 24), so it can detect a regression |
| `npx tsc --noEmit`, `npx eslint app components lib types`, `npm run build`, `npm test` | **Not Run** (no `node_modules`, no network). The changes of this issue are therefore not type-checked or linted |
| `npm audit` | **Blocked** (no network) |
| Live tests (`node scripts/security/live-tests.mjs all`) | **Blocked** (no `BASE_URL`, Supabase URL, anon key or accounts); the script ran with no input and reported 6 groups blocked, 0 pass, 0 fail |

**Changes made for this issue**

| File | Change |
| --- | --- |
| `next.config.ts` | Adds response headers on every path: `X-Frame-Options: DENY`, `Content-Security-Policy: frame-ancestors 'none'`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Content-Type-Options: nosniff`, `Permissions-Policy` (camera for the same origin only, because the Registrar scan desk needs it; microphone, location, payment off), `Strict-Transport-Security: max-age=31536000`; switches off `X-Powered-By` |
| `lib/auth/login-input.ts` (new) | Pure shape check for the sign-in form: name 1 to 254 characters, no control characters, password 1 to 1024 characters |
| `app/(auth)/login/actions.ts` | Calls the shape check before any database call and answers bad input with the generic "Invalid email or password." Before: such input reached `check_login_lockout`, the database raised 22023, and the user saw "Sign-in is temporarily unavailable" (safe, but misleading, and one wasted call) |
| `tests/unit/login-input.test.ts` (new) | UT-79 to UT-84 |
| `scripts/security/local-checks.mjs`, `scripts/security/live-tests.mjs` (new) | The two test scripts described above |

No SQL file was changed, so there is nothing for the Project Manager to run live and no rehearsal file was needed.

**ST-HDR: missing security headers (clickjacking, referrer leakage, MIME sniffing)**

| Field | Value |
| --- | --- |
| Vulnerability | Pages could be framed by another site (clickjacking); the full URL of a portal page could go to other sites in `Referer`; the browser could sniff content types |
| Affected component | Response headers of the Next.js app (`next.config.ts`; `proxy.ts` sets none) |
| Test case | ST-HDR-1: `GET /login` and an anonymous `GET /student` (redirect). Expected: `Content-Type: text/html; charset=utf-8`; `X-Frame-Options` or CSP `frame-ancestors`; `Referrer-Policy`; `nosniff`; no `X-Powered-By`; the same headers on the redirect |
| Actual result | By reading the source before the patch: `next.config.ts` had no `headers()`, and nothing else in `app`, `lib` or `proxy.ts` sets them. This is a source finding; the live response was not captured |
| Status | **Fail (by source inspection); live response Not Run** |
| Solution | Headers added in `next.config.ts` (table above). `Content-Type` is set by Next.js and was not duplicated. A full CSP was not added (see F-3) |
| Verification | Local checks H-1 to H-8: Pass (the configuration declares each header once, camera stays allowed, no duplicates). **Live verification Not Run**: `node scripts/security/live-tests.mjs headers` with `BASE_URL` set, or `curl -sI <url>/login` |
| Execution record | Local checks 2026-10-14, Claude. Live run: date ______ name ______ |

**ST-SQL: SQL injection (SEC-05)** (payloads `' OR 1=1 --`, `'; DROP TABLE x; --`)

| Field | Value |
| --- | --- |
| Vulnerability | User text reaching a SQL statement unescaped |
| Affected component | Login (`app/(auth)/login/actions.ts`, RPC `check_login_lockout`, `record_login_attempt`, `login_email_for_student_id`); hold reason (`lib/data/department-actions.ts`, 300 characters); remarks (`documents-actions.ts`, `applications-actions.ts`, `enrollments-review-actions.ts`, `department-actions.ts`); receipt number (`cashier-actions.ts`, 40 characters); document purpose (`documents-actions.ts`, `MAX_PURPOSE`) |
| Test case | ST-SQL-1 (script, as student A through the Data API): insert a document request with each payload as `purpose`; expected: stored as the same literal text, or refused without query details; `document_types` and `profiles` row counts unchanged. ST-SQL-2 (by hand in the browser, because these are Server Actions): put each payload in the login name, the hold reason, a remark, the receipt number and the purpose; expected: the same |
| Actual result | **Source inspection only.** No SQL driver, `.raw()` or `sql` template in `app`, `components` or `lib`; no table or function name built from a variable; every data call uses supabase-js (`.from()`, `.rpc()` with an argument object). No stored function body in `docs/database` builds SQL with `EXECUTE` (the `EXECUTE` lines are in one-off DO blocks and diagnostics). Local checks Q-1, Q-2, Q-5: Pass. No payload was sent anywhere |
| Status | **Not Run** (static review: no confirmed vulnerability) |
| Solution | No patch needed for SQL construction. Added the login shape check (above) as input hygiene, not as the injection defence |
| Verification | UT-84 documents that the payloads are not filtered. **Live ST-SQL-1 and ST-SQL-2 Not Run**; commands in "How to finish" below |
| Execution record | Static review 2026-10-14, Claude. Live run: date ______ name ______ |

**ST-LOCK: brute-force protection (SEC-03)**

| Field | Value |
| --- | --- |
| Vulnerability | Unlimited password guessing |
| Affected component | Login action, then `check_login_lockout` and `record_login_attempt` (`docs/database/login_lockout.sql`): 5 failures, 60 s doubling, 900 s cap, 24 h window (read from the SQL file; not observed live) |
| Test case | ST-LOCK-1 (browser): 5 wrong passwords for a test account, then the right password; expected: "Too many failed sign-in attempts. Try again in 1 minute." and no password check; after the wait the right password works. ST-LOCK-2 (script): 8 wrong passwords straight to the Supabase Auth endpoint, then the right one; expected by the SRS: refused. ST-LOCK-3: a student ID and the matching email share one lock |
| Actual result | Source: the lockout runs only inside the login Server Action, before `signInWithPassword` (local check A-4: Pass). The anon key is public by design, so the Auth endpoint can be called without the app. The header of `login_lockout.sql` already lists this as a residual risk. **Not observed**: nothing was run |
| Status | ST-LOCK-1 and ST-LOCK-3: **Not Run**. ST-LOCK-2: **Not Run**; expected to **Fail** (open finding F-1) |
| Solution | No code patch. A correct fix is outside the app code: Supabase Auth rate limits and CAPTCHA in the dashboard, or a password-verification hook that applies the same lock inside the database. Both need a test project; see F-1. The existing app lockout was not changed |
| Verification | Not Run. `node scripts/security/live-tests.mjs lockout` with a dedicated test account |
| Execution record | Static review 2026-10-14, Claude. Live run: date ______ name ______ |

**ST-RATE: rate limiting (SEC-04)**

| Field | Value |
| --- | --- |
| Vulnerability | Request flooding |
| Affected component | Vercel Firewall rule "Limit POST requests per IP" (20 per 60 s, 429); not in the repository |
| Test case | ST-RATE-1: below the limit, all requests pass; ST-RATE-2: above the limit, 429; ST-RATE-3: other POST paths (Server Actions of each module); ST-RATE-4: a direct call to the Supabase Auth endpoint. Run only against localhost or an approved preview deployment |
| Actual result | The 2026-10-12 run in `docs/rate-limiting.md` (60 POSTs to `/login`, 429 from about the 25th) is the only observed result and is unchanged. In this session nothing was flooded. Note for testers: the rule is a Vercel setting, so a flood against `localhost` cannot show a 429 |
| Status | Re-run **Not Run**. The earlier result stands for `/login` only; ST-RATE-3 and ST-RATE-4 **Not Run** |
| Solution | No code patch. The control is a dashboard rule (no code, no secret). Follow-ups in F-2 |
| Verification | `FLOOD_COUNT=40 BASE_URL=<preview> ALLOW_REMOTE_FLOOD=1 node scripts/security/live-tests.mjs rate` |
| Execution record | Earlier run: 2026-10-12 (see `docs/rate-limiting.md`). This issue: Not Run |

**ST-IDOR: broken access control and IDOR (SEC-02, ETH-01; TC-12 to TC-39, TC-71)**

| Field | Value |
| --- | --- |
| Vulnerability | A user reads or changes another user's record by changing an id in a request or URL; a role does something outside its scope; anonymous access |
| Affected component | RLS policies (`docs/database/rls.sql`, `hardening*.sql`), grants (`grants_clearance.sql`), the proxy (`lib/supabase/proxy.ts`), `getAdminClientFor` (`lib/supabase/admin.ts`) |
| Test case | ST-IDOR-1 (script): student A asks for student B's rows in `students`, `enrollments`, `document_requests`, `academic_holds`, `clearances`, `v_grades`; expected 0 rows; A updates and deletes B's document request by id: 0 rows changed; a student cannot read `audit_logs`. ST-IDOR-2: anonymous read of 17 tables and views: no rows. ST-IDOR-3 (browser): signed in as a student, open `/registrar`, `/cashier`, `/department`, `/admin` and another role's sub-pages directly: redirected to `/student`. ST-IDOR-4: the SQL suites TC-12 to TC-39 and TC-71 |
| Actual result | Source: every `getAdminClientFor` call passes the matching role (`Admin` in `admin-users-actions.ts`, `Registrar` in `applications-actions.ts`; local check A-1: Pass); the proxy validates with `getUser()` (A-3: Pass); public paths are only `/apply` and `/auth/confirm` (A-2: Pass); other actions run with the caller's own session so RLS decides. The proxy only guides navigation; the database is the gatekeeper. **No request was sent** and the SQL suites were not re-run. Their last recorded live results are in section 6 (2026-10-11 to 2026-10-13: Pass) |
| Status | **Not Run** in this session. No defect found by source review |
| Solution | No patch needed on the evidence available |
| Verification | `node scripts/security/live-tests.mjs anon`, then `idor`; re-run `regression_after_grants.sql` and `e2e_negative_tests.sql` (no database change was made, so this is confirmation, not a required regression) |
| Execution record | Static review 2026-10-14, Claude. Live run: date ______ name ______ |

**ST-XSS: cross-site scripting**

| Field | Value |
| --- | --- |
| Vulnerability | Stored text executing as script when shown |
| Affected component | Every screen that shows free text (hold reasons, remarks, purposes, receipt numbers, names) |
| Test case | ST-XSS-1: enter `<script>alert('XSS')</script>` in each free-text field, open the screens that show it as the student and as the staff role; expected: the text is shown as text, no alert, no tag in the DOM. The `live-tests.mjs sqli` group also stores this string as a document purpose to display |
| Actual result | Source: one `dangerouslySetInnerHTML` in the whole app (`app/layout.tsx`); it injects a constant string with no interpolation (local checks Q-3 and Q-4: Pass). Everything else is rendered by React, which escapes text. No screen was opened |
| Status | **Not Run** (no defect found by source review) |
| Solution | No patch needed. A full CSP would add a second layer (F-3) |
| Verification | Not Run. Browser steps above |
| Execution record | Static review 2026-10-14, Claude. Live run: date ______ name ______ |

**ST-DEP and ST-SEC: dependency audit and secret handling (SEC-06)**

| Field | Value |
| --- | --- |
| Vulnerability | A known-vulnerable dependency; a secret in the repository, the browser bundle or a `NEXT_PUBLIC_` name |
| Affected component | `package.json` and `package-lock.json`; `lib/supabase/admin.ts`; `.gitignore`; environment variable names |
| Test case | ST-DEP-1: `npm audit` and `npm audit --omit=dev`; expected: no high or critical finding that applies. ST-SEC-1: only the Supabase URL and anon key are public; the admin key is read in one server-only file; no secret in files or history |
| Actual result | ST-DEP-1: not run, no network. ST-SEC-1 on the files of the ZIP: the only `NEXT_PUBLIC_` names are `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` (S-1: Pass); `SUPABASE_ADMIN_KEY` appears only in `lib/supabase/admin.ts`, which imports `server-only` (S-2, S-3: Pass); no Client Component imports it or `QUEUE_QR_SECRET` (S-4: Pass); `.env*` is ignored (S-5: Pass); no JWT, `sb_secret_`, private-key or AWS-key pattern in source, docs or tests (S-6: Pass). **Git history was not checked** (no `.git`) |
| Status | ST-DEP-1: **Blocked**. ST-SEC-1 working tree: **Pass (local check)**; history: **Blocked** |
| Solution | None needed for the working tree. Any `npm audit` fix is to be chosen after the report is read (no `npm audit fix --force`) |
| Verification | ST-DEP-1 Not Run. For history: `git log --all -p -S"SUPABASE_ADMIN_KEY" -- . ':!docs'` and `git log --all --full-history -- '.env*'`; do not paste any value into a report |
| Execution record | Local checks 2026-10-14, Claude. Live run: date ______ name ______ |

**Open findings (to be filed as issues; none is hidden)**

| ID | Finding | Status |
| --- | --- | --- |
| F-1 | The login lockout does not cover direct calls to the Supabase Auth endpoint (known residual risk of V-2; expected to be confirmed by ST-LOCK-2). Options to decide with the Project Manager: Supabase Auth rate limits and CAPTCHA, or a database-side password-verification hook. Any SQL goes in one file in `docs/database/` with a rollback block, rehearsed in a rolled-back transaction, run live by the Project Manager | Open, not patched |
| F-2 | Rate limiting is a dashboard rule outside the repository and was observed only for `/login`; no stricter rule for sign-in; Server Actions and the Auth endpoint not tested | Open |
| F-3 | No full Content-Security-Policy. The inline theme script in `app/layout.tsx` means a strict `script-src` needs per-request nonces; test it in a browser before shipping | Open, recommendation |
| F-4 | The set-password link falls back to the request host when `SITE_URL` is not set (`siteUrl()` in `admin-users-actions.ts` and `applications-actions.ts`). Only an Admin or Registrar can trigger it and the host is pattern-checked, so the risk is low. Recommendation: make sure `SITE_URL` is set in Vercel production | Open, recommendation, not tested |
| F-5 | `npx tsc --noEmit`, `npx eslint app components lib types`, `npm run build`, `npm test` and `npm audit` have not been run on the changes of this issue | Open, must be done before the pull request |

**How to finish (in the development environment)**

1. `npm ci`, then `npx tsc --noEmit`, `npx eslint app components lib types`, `npm test`, `npm run build`, `npm audit`, `npm audit --omit=dev`.
2. `node scripts/security/local-checks.mjs` (expect 24 of 24).
3. Start the app with `npm run dev` against a TEST Supabase project, then run `live-tests.mjs` with the variables listed at the top of that file: `headers`, `anon`, `idor`, `sqli`, then `lockout` (dedicated test account) and `rate` (localhost shows no 429; use an approved preview deployment with `ALLOW_REMOTE_FLOOD=1`).
4. By hand, in the browser: ST-SQL-2, ST-LOCK-1, ST-LOCK-3, ST-IDOR-3, ST-XSS-1.
5. Fill the date and the name in each Execution record, change each Status to what was observed, and file F-1 to F-5 as issues if they are still open.
6. On a clone with history: create `chore/security-tests` from the latest `dev`, commit, open the pull request to `dev`, request a review. Do not merge to `main` (the Project Manager does that).

## 11. Findings and deviations

| ID | Finding | Status |
| --- | --- | --- |
| F-1 | The student dashboard clearance card still shows "After all 4 offices clear you, the Registrar gives the final approval." after the clearance is approved (found in E2E-12) | Fixed (GitHub issue #83): the hint now shows only while an office is still pending. Retested 2026-10-11 in the browser: student2 (approved) no longer shows it, student1 (2 of 4) still does |
| F-2 | The duplicate-request message was lost on first test because the page re-rendered to the clearance view | Fixed before merge (notice after redirect), retested E2E-02 |
| F-3 | TC-68 and TC-69 expectations assumed a lone `approved_at` or `approved_by` could be saved; table check `ck_clearances_approval` requires both together | Test expectations corrected; the trigger behaved as designed |
| F-4 | First rehearsal of issue 23 stopped at its own safety check (a varchar type comparison) | Check fixed; rehearsal then passed |
| F-5 | Login lockout rehearsal, 2026-10-12: TC-81 FAILED. Supabase's helper `public.rls_auto_enable()` was executable by anon. A real security finding (vulnerability V-1) | Fixed by revoking EXECUTE; rehearsal and live run then passed. Failure kept visible here |
| F-6 | Documents rehearsal, 2026-10-12: 2 failures. (1) The test data violated the live check constraint `ck_document_requests_processed` (a test defect). (2) A real rule conflict (V-4): remarks could not be edited while a request is Pending, because the table check forbids `processed_by` on Pending while the policy demands it | Trigger and tests fixed; then all 14 cases pass live. Failures kept visible here |
| F-7 | Ticket numbers jump (for example DR-2026-000054) because rolled-back tests consume sequence values | Recorded so nobody reads a gap in the numbers as lost requests |
| D-1 | The browser walk changed the seed data on 2026-10-11: Ben's hold is lifted, his charge is Cleared, a 15,000 payment OR-0003 exists, all four of his items are cleared and his clearance is approved. The audit rows stay (append-only). Resetting needs SQL by the owner. This is why TC-24 shows one known CHECK cell in the regression | Recorded; reset only if a fresh demo is needed |
| D-2 | Two of the four offices have no staff account, so E2E-09 used SQL | Recorded as setup |
| D-3 | The browser checks of 2026-10-12 also changed live data: one new document request (DR-2026-000054) moved to Ready, one grade re-saved, Ben's pending enrollment approved (final). The audit rows stay | Recorded |

## 12. Gaps and work not done (nothing is hidden)

| Item | Level | Status | Plan |
| --- | --- | --- | --- |
| Unit tests (no framework) | 1 | Not done | Issue #107. Owner and date not set |
| Acceptance script run and signed off by team members | 4 | Not done | Section 9. Before the freeze on 2026-10-15. Owner: to be named by the PM |
| Performance: PER-01 and PER-02 | 5 | Not done | Issue #109. Owner and date not set |
| Rate limiting (SEC-04) | 6 | Done (sign-in route) | Vercel firewall rule "Limit POST requests per IP" (POST, 60 s fixed window, 20 requests per IP, 429) tested 2026-10-12: 429 after about 24 POSTs in a minute from one IP; see `docs/rate-limiting.md` |
| SQL injection direct test | 6 | Not done | Issue #108. Owner and date not set |
| Lockout residual risks (DoS lockout, direct Auth endpoint, race) | 6 | Not tested | Documented as accepted risks; test or mitigate if time allows |
| Student enrollment submit, add and remove forms | 3 | Not done | No seed student without an enrollment; needs a new test student or a throwaway term |
| Reject button on the Registrar enrollments screen | 3 | Not done | Needs a second Pending enrollment |
| Friendly error messages of the new screens | 3 | Not done | Trigger each message in the browser |
| Audit rows of the 2026-10-12 browser writes | 3, 6 | Not done | Admin audit log screen |
| Admin user accounts and academic catalog (REQ-ADM-01, REQ-ADM-04) | 3 | Not done | Admin users is a stretch item; no test recorded for either |
| Same checks on the deployed Vercel site, all roles | 3 | Not done | Issue #116 |
| Phone-width and dark-mode scans, CSV export | 3 | Not done | Issue #106 |
| TC-94 | 2 | No case exists | Not claimed |

## 13. Coverage: SRS requirement to test cases

"Partly" means some of the requirement has evidence and the gap is named.

| Requirement | Covered by | Status |
| --- | --- | --- |
| REQ-STU-01 login | TC-01 to TC-11; S-02 (real sign-in) | Pass |
| REQ-STU-02 own grades and enrollment status | TC-84; TC-110; S-03, S-08 | Pass |
| REQ-STU-03 clearance dashboard | E2E-12, N-01 | Pass |
| REQ-STU-04 document requests | TC-96 to TC-100; S-04 | Pass |
| REQ-STU-05 online enrollment | TC-110 to TC-113, TC-119 to TC-121 (database) | Partly: the student forms are not tested in the browser |
| REQ-STU-06 request clearance | E2E-01, E2E-02 | Pass |
| REQ-REG-01 encode grades | TC-86, TC-87, TC-90 to TC-93; S-06 | Pass |
| REQ-REG-02 process document requests | TC-101; S-05 | Pass |
| REQ-REG-03 final clearance | TC-62 to TC-70; E2E-10, E2E-11, N-05 | Pass |
| REQ-REG-04 review enrollments | TC-114 to TC-118; S-07 | Partly: approve tested; Reject button not tested in the browser |
| REQ-CSH-01 to REQ-CSH-03 | TC-49 to TC-61; E2E-06 to E2E-08 | Pass |
| REQ-DPT-01 to REQ-DPT-03 | TC-41 to TC-48, TC-71; E2E-03 to E2E-05, N-03, N-04 | Pass |
| REQ-ADM-01 user accounts | none | Not tested: no live Admin users screen (stretch) |
| REQ-ADM-02 role-based access | TC-03 to TC-10, N-09 | Pass |
| REQ-ADM-03 audit log | TC-24 to TC-28, TC-93; E2E-13; N-08 | Pass |
| REQ-ADM-04 academic catalog | none | Not tested: no live catalog screen recorded |
| REQ-DOC-01 ticket | TC-96, TC-97; S-04 | Pass |
| REQ-DOC-02 status flow | TC-101; S-05 | Pass |
| SEC-01 passwords | Supabase Auth bcrypt; no own test | Not tested |
| SEC-02 RLS | N-01 to N-07, TC-12 to TC-33 | Pass |
| SEC-03 brute-force | TC-72 to TC-82; S-01, S-02 | Pass; residual risks not tested |
| SEC-04 rate limiting | `docs/rate-limiting.md` | Pass (sign-in route; server actions not tested one by one) |
| SEC-05 SQL injection | none direct | Not done |
| SEC-06 secret handling | pre-commit scrub command only | Not done as a recorded test |
| PER-01, PER-02 | none | Not done |
| PER-03 deploy on merge to main | Vercel deployment of main verified 2026-10-11 (signed in as student1; see HANDOFF.md) | Partly: not a written test case |
| ETH-01 privacy between students | N-01, N-02, TC-12 to TC-14 | Pass |
| ETH-02 data minimization | none | Not tested: a review item for the ethical analysis (issue #111) |

## 14. How to re-run, and what is still to fill in

1. Database cases: paste the file named in section 6 into the Supabase SQL editor, as postgres, one tab per file, and run the
   whole tab (each ends in a rollback). The regression is one paste: `docs/database/regression_after_grants.sql`.
2. Browser walk: sign in to each account in the browser pane in the order of section 7.1; use the throwaway-term steps of
   E2E-01 if no student without a clearance exists.
3. Before a pull request: `npx tsc --noEmit`, `npx eslint app components lib types`, `npm run build`.

Still to fill in before the freeze (2026-10-15): level 1 (unit), level 4 (acceptance sign-off), level 5 (performance), the
rate limiting test of the write actions, the SQL injection test, and the gaps of section 12.
