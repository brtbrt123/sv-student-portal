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
| 1. Unit | Vitest, 78 cases UT-01 to UT-78 on the pure functions (section 5), run 2026-10-13 | Pass (78 of 78) | Only functions without a database; React components and the Server Actions themselves are covered at levels 2 and 3 |
| 2. Integration | SQL suites TC-01 to TC-71 (clearance slice, hardening) and TC-72 to TC-122 (lockout, grades, documents, enrollment), all run on the live database | Pass (some rehearsal failures found real defects, section 6) | App-to-database calls are only covered through the browser checks of level 3. TC-94 has no recorded file |
| 3. System | Browser walk E2E-01 to E2E-13 (clearance, 2026-10-11) and browser checks S-01 to S-12 (2026-10-12, grades, documents, enrollment, lockout in the app) | Pass, with the gaps on the right | Student enrollment submit/add/remove forms, Reject button, friendly error messages, audit rows of the new writes, phone width, dark mode, every role on the deployed site |
| 4. Acceptance | None run | Not done | A script per SRS requirement with a sign-off by team members (section 9). Nobody is assigned yet |
| 5. Performance | PER-02 (0.1 to 1.5 ms per query) and PER-01 (all five roles load in 0.93 to 2.18 s) measured 2026-10-14 | Done | Phone, throttled network and larger data not tested (issue #109) |
| 6. Security | Isolation, grants, audit and lockout tests (SQL and browser); vulnerabilities table in section 10 | Partly done: 3 of the candidate vulnerabilities have a fix and a recorded test (rls_auto_enable, brute force, rate limiting) | SQL injection has no direct test; rate limiting tested on the sign-in route only; lockout residual risks not tested; at least 3 vulnerabilities with solutions needed |

## 5. Level 1: Unit testing

Goal: test single functions (validation, formatting, error messages, routing) without the database or the browser. They need
no secret and no network.

**Runner:** Vitest 3.2.7 (`npm test`, config `vitest.config.ts`, files in `tests/unit/`). **Run on:** 2026-10-13, Windows,
Node 24, by Claude Code in the Project Manager's session on the PM's computer. A teammate has not re-run it yet.
**Result: 78 of 78 passed.** The expected values were written from the documented behaviour of each function before the first
run. To check that the tests can fail, the `@` was removed from the formula guard of the CSV export: UT-13 failed as it should,
and the guard was put back.

To make the database-error messages testable they were moved out of the `'use server'` files (which can only export async
functions) into one pure module, `lib/data/db-errors.ts`; the CSV cell guard moved from the audit log screen to `lib/csv.ts`.
The wording and the behaviour were not changed.

| ID | Function (file) | Expected result | Result 2026-10-13 |
| --- | --- | --- | --- |
| UT-01 | `formatPeso(1500)` (`components/cashier/format.ts`) | `₱1,500`, no decimals for whole pesos | Pass |
| UT-02 | `formatPeso(1500.5)` | `₱1,500.50` | Pass |
| UT-03 | `formatPeso(0)` | `₱0` | Pass |
| UT-04 | `formatPeso(1234567.89)` | `₱1,234,567.89` | Pass |
| UT-05 | `formatTimestamp('2026-09-20T16:00:00Z')`, Asia/Manila | `Sep 21, 2026` (already the next day in Manila) | Pass |
| UT-06 | `formatTimestamp('2026-09-20T15:59:59Z')` | `Sep 20, 2026` | Pass |
| UT-07 | `formatTimestamp('not a date')` | `-` | Pass |
| UT-08 | `formatDateOnly('2026-09-20')` | `Sep 20, 2026` | Pass |
| UT-09 | `formatDateOnly('2026-09-20T23:30:00+00:00')` | `Sep 20, 2026` (the day never shifts) | Pass |
| UT-10 | `formatDateOnly('garbage')` | `-` | Pass |
| UT-11 | `plural(1, 'item')`, `plural(2, 'item')`, `plural(0, 'class', 'classes')` | `1 item`, `2 items`, `0 classes` | Pass |
| UT-12 | `csvCell('=SUM(A1:A9)')` (`lib/csv.ts`) | `"'=SUM(A1:A9)"` (no formula runs) | Pass |
| UT-13 | `csvCell` of `+1`, `-2`, `@cmd` | each gets a leading apostrophe | Pass |
| UT-14 | `csvCell` of a leading tab or carriage return | leading apostrophe | Pass |
| UT-15 | `csvCell('Insert')` | `"Insert"` | Pass |
| UT-16 | `csvCell('say "hi"')` | `"say ""hi"""` | Pass |
| UT-17 | `isRoleName` (`lib/auth/roles.ts`) | true for the five roles, false for `admin`, `Teacher`, `5`, `null` | Pass |
| UT-18 | `ROLE_HOME` | Student `/student`, Registrar `/registrar`, Cashier `/cashier`, Department `/department`, Admin `/admin` | Pass |
| UT-19 | `roleForPath` of `/student`, `/cashier/payments`, `/admin/audit-log` | Student, Cashier, Admin | Pass |
| UT-20 | `roleForPath` of `/studentx`, `/login`, `/` | `null` | Pass |
| UT-21 | `isPublicPath` of `/apply`, `/apply/enroll`, `/auth/confirm` | true | Pass |
| UT-22 | `isPublicPath` of `/student`, `/applyx`, `/registrar/applications` | false | Pass |
| UT-23 | `normalizeStudentId('20260004')` (`lib/auth/student-id.ts`) | `2026-0004` | Pass |
| UT-24 | `normalizeStudentId('2026-0004')` and with spaces around it | `2026-0004` | Pass |
| UT-25 | `looksLikeStudentId` | true for `2026-0004`, `20260004`, `2026-000004`; false for `abc`, `2026-00` and an SQL injection string | Pass |
| UT-26 | `studentIdToEmail('20260004')` and `('2026-0004')` | `2026-0004@students.pnc.test` for both | Pass |
| UT-27 | `gradeErrorMessage` P0001 `not approved:` (`lib/data/db-errors.ts`) | tells the Registrar to approve the enrollment first | Pass |
| UT-28 | `gradeErrorMessage` 23503 and an unknown error | grade-scale message; generic message with no raw database text | Pass |
| UT-29 | `documentStatusErrorMessage` P0001 `bad status change:` | explains "one step at a time" | Pass |
| UT-30 | `documentStatusErrorMessage` 42501 and unknown | "not allowed" message; generic update message | Pass |
| UT-31 | `enrollmentErrorMessage` P0001 `enrollment exists:`, `enrollment locked:`, `wrong term:`, `duplicate section:` | one distinct message each | Pass |
| UT-32 | `enrollmentErrorMessage` 42501 | "not allowed" message | Pass |
| UT-33 | `enrollmentErrorMessage` unknown error | returns the generic text passed in by the action | Pass |
| UT-34 | `enrollmentDecisionErrorMessage` `section full:` with details | names the full sections | Pass |
| UT-35 | `enrollmentDecisionErrorMessage` `section full:` without details | short "no seat left" message | Pass |
| UT-36 | `enrollmentDecisionErrorMessage` `no items:`, `enrollment locked:`, 42501, unknown | four distinct messages | Pass |
| UT-37 | `applicationDecisionErrorMessage` `remarks required:`, `bad decision:`, 42501, unknown | four distinct messages | Pass |
| UT-38 | `departmentApproveErrorMessage` `active hold:` | names the student and says to lift the hold | Pass |
| UT-39 | `departmentHoldErrorMessage` 42501, 23503, 23514, unknown | four distinct messages | Pass |
| UT-40 | `cn('p-2', 'p-4')` (`lib/utils.ts`) | `p-4` | Pass |
| UT-41 | `cn` with falsy values and the custom shadow sizes | `a c`; `shadow-xl` wins over `shadow-elev-sm` | Pass |
| UT-42 | `paymentErrorMessage` 23505, 23503, 23514, 42501 (cashier, `lib/data/db-errors.ts`) | each rule names its form field (receipt, charge, amount) or the permission message | Pass |
| UT-43 | `paymentErrorMessage` unknown error; `chargeTagErrorMessage` | generic text with no field; 42501 maps, anything else is generic | Pass |
| UT-44 | `documentRequestErrorMessage` (new document request) | permission, unknown type with its field, bad purpose or copies, unknown error | Pass |
| UT-45 | `applicationFormErrorMessage` (public application form) | invalid details, the flood valve ("try later"), unknown error | Pass |
| UT-46 | `finalClearanceErrorMessage` (Registrar) | `pending items:` is explained; any other error gives `null` | Pass |
| UT-47 | `enrollmentSubmitErrorMessage` | already enrolled, bad year level with its field (1 to 6), a trigger rule, unknown error | Pass |
| UT-48 | `enrollmentAddSectionErrorMessage` | duplicate section, unknown section, a trigger rule, unknown error | Pass |
| UT-49 | `departmentReviewErrorMessage`, `departmentLiftHoldErrorMessage` | permission error named, anything else generic with no database text | Pass |
| UT-50 | `createQueueToken` then `verifyQueueToken` (`lib/queue/qr-token.ts`) | a fresh queue code verifies and returns the same student | Pass |
| UT-51 | `createQueueToken` | the code has the shape `CUQ1.<student id>.<window>.<signature>` | Pass |
| UT-52 | `createQueueToken` at +14 s and +15 s | same code inside a 15-second window, a different code in the next | Pass |
| UT-53 | `refreshInSeconds` | 15, 5 and 1 at 0 s, 10 s and 14.2 s into a window | Pass |
| UT-54 | `verifyQueueToken` in the next window | still accepted (grace for a scan at the edge of a window) | Pass |
| UT-55 | `verifyQueueToken` two windows later and 5 minutes later | rejected as expired, so a screenshot stops working | Pass |
| UT-56 | `verifyQueueToken` with a code from a far-future window | rejected as expired | Pass |
| UT-57 | `verifyQueueToken` with a code signed by another secret | rejected as bad signature | Pass |
| UT-58 | `verifyQueueToken` after changing the student id or the window in the code | rejected as bad signature (no forging a code for another student) | Pass |
| UT-59 | `verifyQueueToken` with empty, short, wrong-prefix, oversize and wrong-shape input | rejected as malformed, never throws | Pass |
| UT-60 | `createQueueToken` with a bad id or a short secret; `verifyQueueToken` with a short secret | throws; rejected | Pass |
| UT-61 | `queueErrorMessage` P0001 `already queued: #8124231` (`lib/data/db-errors.ts`) | names the ticket | Pass |
| UT-62 | `queueErrorMessage` with a label that is not a ticket label | the text is not echoed (no markup in the message) | Pass |
| UT-63 | `queueErrorMessage` `finish first:`, `queue closed:`, `queue busy:`, `bad ticket change:` | one distinct message each | Pass |
| UT-64 | `queueErrorMessage` 22023, 42501 and an unknown error | not-an-active-student message, permission message, generic message with no database text | Pass |
| UT-65 | `ordinal` (`lib/queue/ordinal.ts`) | 1st, 2nd, 3rd, 4th, 10th, 21st, 22nd, 23rd, 25th, 101st to 103rd | Pass |
| UT-66 | `ordinal` of 11, 12, 13, 111, 112, 113 | always `th` | Pass |
| UT-67 | `estimateWait` (`lib/queue/line.ts`) | 3 to 5 minutes per person ahead (4 ahead: 12 to 20 min); nothing when nobody is ahead | Pass |
| UT-68 | `formatWait` | `12–20 min` with an en dash; `5 min` when both ends are equal | Pass |
| UT-69 | `lineSlots` for a short line | everybody shown: the people ahead, one "you", the people behind | Pass |
| UT-70 | `lineSlots(2, 20)` | the first 6 positions and a gap | Pass |
| UT-71 | `lineSlots(15, 20)` | the first three, a gap, then you (15) | Pass |
| UT-72 | `lineSlots` with disagreeing counts | always exactly one "you" | Pass |
| UT-73 | `formatWhen` (`lib/notifications/time.ts`) | under a minute and a time slightly in the future read "Just now" | Pass |
| UT-74 | `formatWhen` | "5 min ago", "59 min ago", "2 h ago" (up to six hours) | Pass |
| UT-75 | `formatWhen` | earlier the same Manila day "Today, 8:05 AM"; the day before "Yesterday, 3:30 PM" | Pass |
| UT-76 | `formatWhen` | older dates "Oct 1, 10:00 AM", the year only for another year; a bad date gives empty text | Pass |
| UT-77 | `unreadLabel` | nothing for 0, the number up to 99, "99+" from 100 | Pass |
| UT-78 | `kindIcon` (`lib/notifications/kind.ts`) | each kind code prefix maps to its icon; an unknown kind to the plain bell | Pass |

The database triggers are unit-like checks of single rules, but they are recorded as integration tests in section 6 because
they run against the live database.

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
| Virtual queue for the Registrar window (physical queuing for enrollment) | TC-139 to TC-166 (28 cases) | `docs/database/queue_rules_test.sql` | 2026-10-13, PM ran, Claude read. Rehearsed first (`queue_rules_rehearsal.sql`): 28 of 28 OK, rolled back. Then the live change, then this file again against the live tables | 28 of 28 Pass live, first time |
| Regression after the queue change | TC-12 to TC-33 | `docs/database/regression_after_grants.sql` | 2026-10-13, re-run after the queue went live | Unchanged: 15 cells OK plus the one known data-dependent CHECK cell (TC-23, Ben's lifted hold); every TC-27 permission flag as expected |
| Notifications (in-app inbox for every role) | TC-167 to TC-198 (32 cases) | `docs/database/notifications_rules_test.sql` | 2026-10-13, PM ran, Claude read. Rehearsed first (`notifications_rules_rehearsal.sql`): 32 of 32 OK, rolled back. Then the live change, then this file again against the live tables | 32 of 32 Pass live, first time |
| Regression after each Sprint 4 change | TC-12 to TC-33 | `docs/database/regression_after_grants.sql` | 2026-10-12, re-run after the lockout, after grades and documents, and after enrollment | Unchanged each time: 15 cells OK plus one known CHECK cell on TC-24 (the seed data was changed by the 2026-10-11 browser walk, D-1) |
| Regression after the notifications change | TC-12 to TC-33 | `docs/database/regression_after_grants.sql` | 2026-10-13, re-run after the notifications went live | Unchanged: 15 cells OK plus the one known data-dependent CHECK cell (TC-23); every TC-27 permission flag as expected |
| Auto first-year enrollment (curriculum table, applicant type, enrollment function) | TC-234 to TC-247 (14 cases) | `docs/database/first_year_curriculum_test.sql` | 2026-10-14, PM ran, Claude read. Rehearsed first (`first_year_curriculum_rehearsal.sql`): `all_ok` true, 14 of 14 OK, rolled back. Then the live change (`first_year_curriculum.sql`, its own checks all OK), then this file again against the live tables. Not written with a local PostgreSQL: the rehearsal was its first run | 14 of 14 Pass live |
| Regression after the first-year change | TC-12 to TC-33 | `docs/database/regression_after_grants.sql` | 2026-10-14, re-run after the change went live | Unchanged: the same cells OK plus the one known data-dependent CHECK cell (TC-23) |
| Hold v2: 30-minute hold, No-show only after it, automatic expiry, notification, Registrar drop policy | TC-248 to TC-259 (12 cases) | `docs/database/queue_hold_v2_test.sql` | 2026-10-14, PM ran, Claude read. Rehearsed first (`queue_hold_v2_rehearsal.sql`): `all_ok` true, 12 of 12 OK, rolled back. Then the live change (`queue_hold_v2.sql`, its five checks true), then this file again against the live tables | 12 of 12 Pass live |
| Regression after the hold v2 change | TC-12 to TC-33 | `docs/database/regression_after_grants.sql` | 2026-10-14, re-run after the change went live | Unchanged: the same cells OK plus the one known data-dependent CHECK cell (TC-23) |

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
| Virtual queue (tickets) | TC-139 to TC-166 |
| Notifications | TC-167 to TC-198 |

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

### 7.3 The virtual queue in the app (browser, 2026-10-13)

Run by: Claude drove the browser on localhost against the live data after `queue_rules.sql` went live; the Project Manager signed
in. Two pane tabs with separate sign-ins: `localhost:3000` as student 2026-0004 (Test Applicant, no enrollment) and
`127.0.0.1:3000` as the Registrar (Cruz, Rey). **The camera was not used:** the code was read from the QR component of the
student page and typed into the scan field of the Registrar page, within the 30 seconds a code lives.

| ID | Role and steps | Expected | Actual (2026-10-13) | Result |
| --- | --- | --- | --- | --- |
| Q-01 | Student: open Enrollment | The "Physical enrollment at the Registrar" card with a QR that changes every 15 s | Card shown; the QR pattern changed within 15 to 20 s | Pass |
| Q-02 | Registrar: open Queue | The page loads from the live database with an empty queue | "Waiting (0)", no error | Pass |
| Q-03 | Registrar: scan the student's code | The student's card (name, number, program); no ticket yet | "Applicant, Test, 2026-0004, BSCS"; Waiting stayed 0 | Pass |
| Q-04 | Registrar: Approve and issue ticket | A random 7-digit ticket; the student's page switches to the ticket by itself | Ticket #8503599; student saw "Your ticket #8503599, You are next" within 6 s | Pass |
| Q-05 | Registrar: Call next with window "Window 1" | The Registrar sees who is being served; the student sees a green "your turn" with the window | "Now serving #8503599 ... Window 1"; student: "It is your turn. Go to Window 1 now." | Pass |
| Q-06 | Registrar: Done | The line is empty, totals update; the student sees they were served | "Today: 1 done"; student: "You were served today (#8503599)" | Pass |
| Q-07 | Registrar: scan an expired code (the one used in Q-03) | Rejected as expired, nothing issued | "This code has expired. Ask the student to hold the phone up again; the code refreshes every 15 seconds." | Pass |
| Q-08 | Registrar: scan a forged code (valid shape, wrong signature) | Rejected | "This is not a valid portal queue code." | Pass |
| Q-09 | Registrar: scan junk text | Rejected | "This is not a portal queue code." | Pass |

Not verified in the browser (stays "Not done", section 12): the camera scan and a USB barcode scanner (hardware not tried),
the QR on a real phone, "Leave the queue", the No-show button, several students in one line (order and "You are 25th"
numbers), the audit rows of the ticket changes on the Admin screen, phone widths and light mode, and the deployed Vercel site.

### 7.4 Enrollment submit, Reject and Approve in the app (browser, 2026-10-14)

Run by: the Project Manager signed in and clicked (student 2026-0008 Justinbril Abarquez; Registrar Cruz, Rey) on localhost against the
live database. Claude read the pages and checked every result with read-only SELECTs on the live project. For issues #101 and #102.
One test enrollment (id 58) was used. A Rejected enrollment is final in the database, so after the Reject the owner ran a one-off
script that put that single row back to Pending (the trigger `require_enrollment_rules` was switched off for that one change and
switched on again, checked); the reset is itself in the audit log. Then the enrollment was approved.

| ID | Role and steps | Expected | Actual (2026-10-14) | Result |
| --- | --- | --- | --- | --- |
| E-01 | Student (2026-0008, no enrollment yet): Enrollment page, choose Year 3, submit | One enrollment, status Pending, year level 3 | Page: Pending, Year 3, submitted Oct 14, 2026. Database: enrollment 58, Pending, year_level 3, not reviewed | Pass |
| E-02 | Student: add two sections (CS101 A, GE101 A) | Both listed with units and schedule; items saved | Page: 2 subjects, 6 units. Database: 2 items (A/CS101, A/GE101) | Pass |
| E-03 | Student: the "Add a section" picker after two sections were added | Only sections not yet chosen are offered (a duplicate cannot be picked) | Picker listed only CS102 (the one section left). The duplicate-section message itself is covered by UT-48 and TC-109 to TC-122, not by a click | Pass (by design) |
| E-04 | Student: the page text while Pending | Items can be added or removed only while Pending | "Sections can be added or removed only while the enrollment is Pending. The Registrar checks for a free seat when approving." | Pass |
| E-05 | Registrar: Enrollments page shows the pending enrollment | Student, program, year level, subjects and sections, free seats | The Registrar found the enrollment on this page and rejected and approved it from there (E-06, E-08); what the list showed (columns, seat figures) was not written down | Partly recorded |
| E-06 | Registrar: Reject with remarks "Test: missing requirements" | Status Rejected, `reviewed_by` the Registrar, `reviewed_at` set, student notified | Database: Rejected, remarks saved, reviewer Cruz, Rey, reviewed_at set, 2 audit rows, student notification "Your enrollment was rejected" | Pass |
| E-07 | Owner: reset enrollment 58 to Pending (one-off script) | Exactly one row changed, trigger enabled again | Pending, review fields cleared, trigger state enabled (`O`), 2 items kept | Pass |
| E-08 | Registrar: Approve | Status Approved, reviewer named, `reviewed_at` set, audit rows, student notified | Database: Approved, reviewer Cruz, Rey, reviewed_at set, 4 audit rows (submit, reject, reset, approve), notifications "rejected" and "approved", 2 items | Pass |
| E-09 | Registrar: Encode Grades lists the approved enrollment's subjects | CS101 and GE101 of 2026-0008 appear | PM confirmed both rows are there | Pass (reported by the PM) |
| E-10 | Isolation: one student cannot see another student's enrollment | 0 rows of another student | Regression TC-14 on the live project, 2026-10-14, before and after the catalog and admin grants: "s2 ... enrollments 0 -> OK" (SQL level; not repeated by clicking as a second student) | Pass |

Not verified in this run (stays in section 12): Reject pressed with EMPTY remarks (the refusal text was not reported); the student
page after the Reject (the "not approved" box and the remarks were not looked at); the Remove button; a second enrollment for the
same term from the screen; the Registrar list's free-seat figures; the same checks on the deployed Vercel site and on a phone.
Gap against issue #101: the section picker shows "capacity 40", not the free places left.

### 7.5 QA pass: phone width, dark mode, accessibility (browser, 2026-10-14)

Run by: Claude in the browser pane at a phone size (375 x 812, device pixel ratio 2, mobile emulation) on `localhost:3000` against the live
data; the Project Manager signed in as each role. For issue #106. An audit script was run on every screen after the page loaded. It measured:
page-level horizontal scroll; elements wider than the screen outside a scroll container; tap targets under 44 px (links, buttons, fields,
tabs; a checkbox or radio is measured by the label around it, which is the real tap area); text contrast from the computed text colour and
the effective background (text over a photo or an image is skipped: unknown background); controls without an accessible name; fields without a
label; images without `alt`; heading order and the number of `h1`; page language, title and the `main` landmark. Keyboard focus was checked by
pressing Tab on a page and reading the focused element.

| Area | Screens checked | Themes | Result |
| --- | --- | --- | --- |
| Public | `/apply`, `/apply/enroll`, login (student view and staff view) | light and dark (`/apply/enroll`: light only) | See findings F-2, F-3, F-5 |
| Student | `/student`, clearance, documents, enrollment, grades, notifications, queue (7) | light and dark | One finding, F-1 (fixed) |
| Registrar | dashboard, applications, clearance, documents, enrollments, grades, notifications, queue (Enrollment line and Documents line) (9) | light and dark | No findings |
| Cashier | dashboard, charges, clearance, payments, notifications (5) | light and dark | No findings |
| Department | dashboard, clearance, holds, notifications (4) | light and dark | No findings |
| Admin | dashboard, users, academic setup, audit log, notifications (5) | light and dark | No findings |

Across all of them: no page-level horizontal scroll on any screen (wide tables scroll sideways inside their own box); no control without a
name and no field without a label; no image without `alt`; headings in order with one `h1`; the page language, title and `main` landmark are
present; no contrast failure among the text the script could measure; the status badges carry the status word (`StatusBadge` prints the
text), so status is not colour only. Keyboard focus (7 Tab stops in dark mode and 1 in light mode, on the Admin users page): every control tried showed a 2 px solid outline (gold on fields and the skip link, light
grey on the header buttons in dark mode; charcoal at 16.4 to 1 against the page in light mode).

| ID | Screen | Problem | Severity | Resolution |
| --- | --- | --- | --- | --- |
| F-1 | Student: documents and enrollment pages, the "Open the Queue page" button of the queue banner | 40 px tall, 4 px under the 44 px minimum tap target | Low | **Fixed** (`h-11`, 44 px) on branch `chore/qa-pass` |
| F-2 | Public: `/apply` and `/apply/enroll`, light mode, the gold "Cabuyao" word in the header | The script measured 1.27 to 1 for the gold text on the pale header. It is the school's logotype with a dark outline and the word "University" under it is dark; logotypes are exempt from the contrast rule | Accepted | Accepted, no change. Looked at in a screenshot: legible |
| F-3 | Public: `/apply/enroll`, the `website` field (154 x 20 px) | It is the hidden spam-trap field (a honeypot) meant to be invisible to people, so its size does not matter for tapping | Not an issue | None |
| F-4 | Every signed-in screen, the "Skip to main content" link (32 x 16 px) | It is only shown to keyboard users when focused | Not an issue | None |
| F-5 | Public: `/apply/enroll`, the white "Start your enrollment" text over the campus photo | The script cannot measure text over an image (it read the page background, 1.08 to 1). The text sits on a black 60 % gradient at the bottom of the photo. By calculation the large title passes even over a bright photo (about 3.9 to 1 against the 3 to 1 needed for large text); the small line under it is estimated at 5 to 1 or better over the grass; not measured | Low | Accepted as judged by eye and by calculation, **not measured**. To be re-checked if the photo changes |
| F-6 | Every page, the theme button | The label comes from a client-side value, so the server's HTML says "Switch to dark mode" for a moment even in dark mode, then corrects itself after loading. A screen reader could read the wrong label in that moment | Low | Recorded, not fixed (a neutral label such as "Dark mode" with `aria-pressed` would remove it) |

Not tested in this pass: a real phone (a phone emulation is not a phone), text enlarged by the user or browser zoom, a screen reader, the
screens in their empty and error states and with many rows (the data set is small), the `/set-password` page (it needs a recovery link and
redirects to the login without one), and `/apply/enroll` in dark mode. The live site was not re-checked after the fix (the fix is not
deployed). Findings are fixed or listed here; none was filed as a separate GitHub issue.

### 7.6 Live check on the deployed site after the release (browser and phone, 2026-10-14)

Run by: the Project Manager on `https://cabuyaouni.vercel.app` (PC as student 2026-0008, phone as the Registrar); Claude read the student pages
in the browser pane. For issue #116. The release was PR #146 (`dev` into `main`, commit `8d17b98`; the production deployment for that commit
had status success and the function ran in Sydney, `syd1`). It carries PRs #143, #144 and #145.

| ID | Steps | Expected | Actual (2026-10-14) | Result |
| --- | --- | --- | --- | --- |
| L-01 | Student shows the Enrollment QR; Registrar scans it | One scan issues the ticket, no Approve button | Ticket #1821941 appeared right away | Pass |
| L-02 | Scan the same student again | Refused, no second ticket | "Already have a ticket" (the QR was still on screen before the page refreshed). The student page then showed the ticket and no QR | Pass |
| L-03 | Student holds the ticket; Registrar marks it No-show | Held ticket listed under On hold; No-show closes it | The ticket disappeared from the student page after No-show. The student got **no notification** (see below) | Pass, with a gap |
| L-04 | Documents line: scan, then the student taps the red Cancel ticket | Confirm step, ticket closed, QR offered again | Ticket #8017077 closed; the page said "Your last ticket (#8017077) was closed. Show the code again" and showed the QR. Whether the confirm step was shown and the button was red was not reported | Pass |
| L-05 | Documents line: new ticket, Call next, Done | Student told they were served; QR offered again | Ticket #5467942 called at Window 2 and finished; the page said "You were served today (#5467942)" and showed the QR | Pass |
| L-06 | The student's notification bell | One entry per ticket event | "You are in line" for #1821941, #8017077 and #5467942, and "It is your turn, go to Window 2" for the called ticket. Nothing for the held-then-No-show ticket or the cancelled ticket | Pass, with a gap |
| L-07 | `/apply/enroll`: press Submit with every field empty | Per-field messages, nothing saved | "Enter your first name.", "Enter your last name.", "Enter your email address.", "Choose the program you are applying for." and "Please fix the highlighted fields." Nothing was saved | Pass |
| L-08 | Student dashboard at 375 px: every link and button at least 44 px | No tap target under 44 px | Everything measured 44 px or more except the hidden "Skip to main content" link. The queue banner itself was not on screen (no active ticket), so the F-1 fix was not seen live | Partly recorded |
| L-09 | Reset the PM's Gmail, apply on the live form, the Registrar accepts, check the inbox | Branded acceptance email, 8-digit student ID, link to `cabuyaouni.vercel.app`, password set, sign-in | Reported "all pass" by the PM. The details (look, ID, link host) were not written down in this record | Pass (reported by the PM) |

Findings from this run (not fixed; each is a candidate for a later issue, none was filed):
- A held ticket marked No-show by the Registrar sends no notification, and a cancelled ticket sends none either (the trigger reacts only to
  a new ticket, a call and a called ticket marked No-show; `queue_hold.sql` H8 recorded this as a known gap).
- The Registrar can mark a held ticket No-show at any time, including seconds after the hold started, and a hold that runs out does not close
  itself. The PM asked for: hold limit 30 minutes, No-show allowed only after it runs out, automatic No-show after it, and a notification.
- The Documents QR is offered while any request is Pending, Processing or Ready, so a student who was just served can get the QR back for a
  request already handled.
- A document request files one document type; the student cannot pick several documents in one request (one ticket already serves them all).

Not verified in this run: Reject on the live site and the rejection email; the queue banner button at 44 px with an active ticket; the
Registrar's Documents line on a phone beyond the scan; dark mode and phone width on the deployed site; PER-01 was not re-measured.

### 7.7 Automatic first-year enrollment on localhost against the live database (2026-10-14)

Run by: the Project Manager (Registrar and student screens) and Claude (read-only SELECTs of the live tables), on a production build of the new code served on `localhost:3000`, against the live project. For the change in branch `feature/auto-first-year`. Not yet deployed to `cabuyaouni.vercel.app` at the time of this run. The curriculum is SAMPLE data (BSCS: CS111, CS112, MATH101, CS113, CS114; BSIT: IT101 to IT104 and GE101; BSBA: BA101 to BA104 and GE101).

| ID | Steps | Expected | Actual (2026-10-14) | Result |
| --- | --- | --- | --- | --- |
| A-01 | Apply with the PM's Gmail as a New student (BSBA), the Registrar accepts | Student account created, a Pending Year 1 enrollment with the program's five subjects, no picking | Application 227 (New) Accepted, student 2026-0010; enrollment 66, Year 1, Pending, items BA101, BA102, BA103, BA104, GE101 | Pass |
| A-02 | The new student opens Enrollment | The five subjects, no section picker, no Remove buttons, a note to ask the Registrar to drop a subject | Reported by the PM: the fixed subjects are shown; the picker and Remove were not described | Pass (reported by the PM) |
| A-03 | The Registrar drops one subject of the Pending enrollment | The subject is removed from that enrollment | First recorded as "Pass (reported by the PM)", but when the PM pressed Drop again nothing happened: the Drop buttons sat INSIDE the Approve/Reject form (nested forms, React error "A React form was unexpectedly submitted"). Fixed (commit e2ea176) and tried again by Claude on a production build: the subject BA104 was removed from enrollment 66 (database: BA101, BA102, BA103, GE101 left) | Fail, then fixed and Pass (see B-04) |
| A-04 | The acceptance email | Branded email with the student ID and a set-password link | Reported by the PM: working. The details were not written down | Pass (reported by the PM) |
| A-05 | Another application (203, Arvien Espedillon) in the live table | Stays Pending, untouched | Still Pending, no student | Pass |

Known limits of this change (recorded, not fixed): the Registrar's drop is not audited with the Registrar as actor; a student can still remove or add their own Pending items by calling the database API directly (the screen hides it; the database policies are unchanged); the function always uses year 1 and the 1st semester; a section has capacity 40 and the Registrar's approval fails with "section full" beyond that; the older test files that call the old five-argument `submit_application` (`applications_rules_test.sql` setup and TC-123, `login_lockout_test.sql` TC-81, the anon function lists in other tests) are not updated; the sample subjects, schedules and capacities are invented; a transferee is not auto-enrolled and picks sections as before (not exercised in A-01 to A-05).

Not verified in this run: the same flow on the deployed site, a transferee end to end, BSCS and BSIT through the screens (covered at database level by TC-240), the Registrar drop on a phone, and PER-01 after the change.

### 7.8 Hold v2, several documents, the QR rule and the Registrar drop on localhost against the live database (2026-10-14)

Run by: the Project Manager (student 20260008 on `127.0.0.1:3000`) and Claude (Registrar tab, read-only SELECTs), on a production build of the new code. Not yet deployed to `cabuyaouni.vercel.app` at the time of this run. A real 30-minute hold could not be waited out, so the expiry itself is proven by the database tests TC-249 to TC-253 (a held time moved back inside a rolled-back transaction), not by clicking.

| ID | Steps | Expected | Actual (2026-10-14) | Result |
| --- | --- | --- | --- | --- |
| B-01 | Student 20260008, served today in the Documents line, opens the queue page | No Documents code, a "You were served" note | Reported by the PM: passes (UT-80 and UT-81 cover the rule) | Pass (reported by the PM) |
| B-02 | The student checks two documents on the request form and submits | Two requests listed as Pending, one submit | Reported by the PM: passes | Pass (reported by the PM) |
| B-03 | The student opens the queue page after the new requests | The Documents code is back (the requests are newer than the last Done ticket) | Reported by the PM: passes | Pass (reported by the PM) |
| B-04 | The Registrar drops BA104 from the Pending enrollment 66 of student 2026-0010 (after the nested-form fix) | The subject is removed and the audit row names the Registrar | Database: BA101, BA102, BA103, GE101 left; the audit row for the delete has the Registrar Rey Cruz as actor. The screen showed the change a moment late while the tab was in the background | Pass |
| B-05 | The Registrar's No-show on a held ticket before the hold runs out (button disabled, "No-show allowed after ...") and the automatic expiry | Disabled until 30 minutes pass; the database refuses an early No-show; an expired hold becomes a No-show and the student is told | Not clicked: no ticket could be made on localhost (the QR scan needs a phone camera, which needs https). Covered at database level by TC-249 to TC-253 (hold active, expiry, notification) | Not tested on screen |

Known limits of this change (recorded, not fixed): expiry is run when the Registrar's or the student's queue page loads or refreshes, not by a scheduler, so an expired hold stays Held until one of those pages is open (an optional `pg_cron` block is in the file header); the older `queue_hold_test.sql` (and its rehearsal) now fail where they expect 15 minutes or an immediate No-show, and `enrollment_rules_test.sql` TC-119 (Registrar cannot delete) and `first_year_curriculum_test.sql` TC-247's information line show the new Registrar delete; none of them is updated; do not re-run `queue_hold.sql`, `enrollment_rules.sql` or `notifications_rules.sql` as they stand; a Registrar's drop screen shows the change only after the page refreshes.

Not verified in this run: B-05 on screen, the several-documents form and the queue rule on the deployed site and on a phone, a transferee end to end, and PER-01 after these changes.

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

Status: **PER-02 measured and passed; PER-01 measured on the live site after the fixes and passed for all five roles (both
2026-10-14).** Limits are listed under the tables. Issue #109.

**PERF-02 (PER-02: grade and clearance queries under 500 ms): Pass.** Run by Claude with a read-only, rolled-back script in the
Supabase SQL editor on the live project (as a student with row-level security on: role `authenticated` and the JWT claim of
student1). Each query was run 30 times; the figures are the average per call, in milliseconds.

| Query | ms per call | Limit |
| --- | --- | --- |
| `v_grades` | 1.46 | 500 |
| `v_clearance_items` | 0.89 | 500 |
| `v_clearances` | 0.45 | 500 |
| profile and role lookup | 0.14 | 500 |
| `enrollments` | 0.28 | 500 |
| `list_my_notifications(20, false)` | 0.09 | 500 |
| `queue_my_status('Enrollment')` | 0.80 | 500 |

Rows used (counted the same way, 2026-10-14): as student1 the views returned 3 rows (`v_grades`), 4 rows (`v_clearance_items`) and
1 row (`v_clearances`); the tables hold 6 grades, 12 clearance items, 3 clearances, 4 enrollments, 7 notifications and 1 queue ticket.
These are database times on a very small data set (demo data); they say the queries are cheap here, not how they would scale. They do not
include the network between the app and the database.

**PERF-01 (PER-01: UI loads in under 2.5 s): Pass for the main pages of all five roles, measured after the fixes were deployed.** Before the fixes,
measured from the Project Manager's machine on the deployed site with `curl` on 2026-10-14: a static file from the edge takes 0.18 s to the first byte; `/login` (no database call) takes 0.43 to
0.46 s warm and 1.8 s on a cold start; `/apply` 0.47 s. Signed-in pages were not timed on the live site (a login is needed). Findings:
- The Supabase project is in Sydney (`ap-southeast-2`) but Vercel runs the app's functions in Washington DC (`iad1`, the default;
  response header `X-Vercel-Id: sin1::iad1`). Every database call from a page crosses that distance (about 230 ms each).
- A signed-in page made about 7 to 9 database calls in a row: the proxy (`getUser` and a profile query), the page's `requireRole`
  (the same two again), the page data, then the sidebar's unread count. That is an estimate of 1.6 to 2.1 s plus the 0.27 s region
  penalty; it was not measured on the live site.
- The unread-count poll was a separate request that also repeated the profile check.
Fixes (branch `feature/performance-fixes`): Vercel functions to Sydney (`vercel.json`, `syd1`); `getCurrentProfile` and
`getUnreadCount` cached per request and the unread count started early so it runs while the page loads; the poll no longer repeats
the profile check; queue auto-refresh 5 s to 10 s. Not done: the proxy still asks Supabase Auth and the profile table on every request.

**After the fixes (live site `cabuyaouni.vercel.app`, `main` at e8fb5c4, 2026-10-14, signed in as student 2026-0008 in the Claude
browser pane on the Project Manager's machine; the response header now reads `X-Vercel-Id: sin1::syd1`, so the functions run in
Sydney).** No signed-in "before" figure was taken on the live site, so the size of the improvement is not measured; the figures below
are what the requirement is checked against.

Server response of the signed-in page (`fetch` with caching off, 3 runs per page; milliseconds; first byte / whole HTML):

| Page | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| /student | 788 / 977 | 1406 / 1582 | 847 / 1024 |
| /student/enrollment | 827 / 1018 | 878 / 1067 | 856 / 1004 |
| /student/grades | 811 / 917 | 870 / 945 | 797 / 867 |
| /student/clearance | 1503 / 1634 | 921 / 1025 | 862 / 985 |
| /student/documents | 860 / 955 | 829 / 909 | 767 / 865 |
| /student/queue | 738 / 954 | 682 / 834 | 806 / 957 |
| /student/notifications | 1446 / 1516 | 979 / 1080 | 843 / 1019 |

Typical whole-HTML time 0.83 to 1.08 s; the slowest was 1.63 s (the first request to a page, probably a cold function).

Full page load in the browser (Navigation Timing and largest contentful paint, one run per page, milliseconds):

| Page | DOM interactive | Load event | Largest contentful paint |
| --- | --- | --- | --- |
| /student | 1234 | 1277 | 1448 |
| /student/enrollment | 1016 | 1173 | 1228 |
| /student/grades | 880 | 926 | 1192 |

Staff roles, same method (signed in as `registrar@pnc.test`, `cashier@pnc.test`, `dept@pnc.test`, `admin@pnc.test`; whole-HTML time in
milliseconds, 3 runs per page; the first number is the first run):

| Page | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| /registrar | 1146 | 1073 | 884 |
| /registrar/enrollments | 1227 | 978 | 1062 |
| /registrar/queue | 989 | 939 | 926 |
| /registrar/documents | 929 | 946 | 945 |
| /registrar/grades | 1048 | 1167 | 1293 |
| /registrar/applications | 923 | 878 | 958 |
| /cashier | 1054 | 1030 | 992 |
| /cashier/charges | 960 | 1677 | 949 |
| /cashier/payments | 962 | 995 | 925 |
| /cashier/clearance | 1135 | 973 | 1150 |
| /department | 1003 | 1679 | 968 |
| /department/clearance | 1136 | 1047 | 1110 |
| /department/holds | 949 | 913 | 1672 |
| /admin | 1860 | 874 | 1107 |
| /admin/users | 1401 | 891 | 802 |
| /admin/academic-setup | 1004 | 858 | 1090 |
| /admin/audit-log | 1087 | 1231 | 903 |

Full page load of each role's main page, plus the Registrar's queue page (one run each, milliseconds):

| Page | DOM interactive | Load event | Largest contentful paint |
| --- | --- | --- | --- |
| /registrar | 1534 | 1584 | 1568 |
| /registrar/queue | 1724 | 2184 | 1752 |
| /cashier | 983 | 1034 | 1020 |
| /department | 1044 | 1138 | 1068 |
| /admin | 914 | 991 | 944 |

Summary over all five roles: whole HTML typically 0.8 to 1.3 s, slowest single response 1.86 s (the first request to /admin); full load
0.93 to 2.18 s, the slowest being the Registrar's queue page (2.18 s, a single run, which loads the QR scanner library); largest
contentful paint 0.94 to 1.75 s. All measured values are under 2.5 s, but the queue page is the closest to the limit.

Limits of this test: one account per role, one network (the Project Manager's, Philippines to Singapore to Sydney), one run per page for
the full load, no phone, no throttling, cold start not isolated, a very small data set (see PERF-02 row counts), and no "before" figure for
signed-in pages, so the size of the improvement is not measured. The test used the live site with the Claude browser pane
(Project Manager signed in each role); Claude read the numbers.

| ID | Requirement | What to measure | Status |
| --- | --- | --- | --- |
| PERF-01 | PER-01 | Page load time of the main page of each role on the live site, after the fixes (full load 0.93 to 1.58 s, Registrar queue page 2.18 s; largest contentful paint 0.94 to 1.75 s) | Pass, 2026-10-14 |
| PERF-02 | PER-02 | Query time for grades and clearance status (`v_grades`, `v_clearance_items`, `v_clearances` and others, as a student, 30 runs) | Pass, 2026-10-14 |

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
| V-6 | Queue QR forgery, replay and sharing (physical queuing). A static or guessable code would let anyone take a ticket for another student, or let a screenshot be passed around | The code is a signed token that changes every 15 seconds: HMAC-SHA256 over the student and the time window with a server-only secret (`QUEUE_QR_SECRET`, at least 32 characters), valid for its own window and the next (30 s at most); the signature is checked first and compared in constant time (`lib/queue/qr-token.ts`); only the server makes and checks it | UT-50 to UT-60 (forged, tampered, other-secret, expired, future and malformed codes); Q-07 to Q-09 in the browser | Pass. Residual: proxy queuing, see V-7 |
| V-7 | Proxy queuing and ticket trading: someone else takes the place of a student who is not on campus | Tickets are issued only by a Registrar after comparing the student's card on screen with the person and the ID (Approve step); the ticket number shown to people is random and 7 digits, the line order is kept separately and hidden (`ticket_code` vs `ticket_number`); the owner's name is shown again at the window | TC-139 to TC-166 (random codes, order follows issue order, student privacy); Q-03 to Q-06 | Partly. A person holding a student's phone and ID who looks similar can still pass. The student photo (not built, a placeholder is in the SQL and the screen) would reduce this. Accepted residual risk |

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
| Queue QR codes cannot be forged, replayed after 30 s or malformed | UT-50 to UT-60, Q-07 to Q-09 | 2026-10-13 | Pass |
| Queue: only a Registrar issues, calls and finishes tickets; students see only their own ticket and aggregate numbers; no direct writes | TC-139 to TC-166 | 2026-10-13 | Pass |
| SQL injection test | ST-SQL-1, ST-SQL-2 (10.2.1) | 2026-10-14 | Source review only (no concatenated SQL found); the typed-payload tests are **Not Run** |
| Secret handling (no server key in the repo or browser) | ST-SEC-1, local checks S-1 to S-6, Git history scan (10.2.1) | 2026-10-14 | Pass (269 commits, 0 matches) |
| Security response headers (clickjacking, referrer, sniffing) | ST-HDR-1, LH-1 to LH-7 (10.2.1) | 2026-10-14 | Pass on a local production build; deployed site Not Run |

### 10.2.1 Issue #108: security tests and vulnerability patching (2026-10-14)

**Read this first.** The first version of this record (a teammate's pull request, #148) was written from a source-only copy of the
repository, so almost nothing could be run. This version is rebuilt on the current `dev` and keeps their code and write-up. It was
then run by Claude on 2026-10-14 in the development checkout (local production build, no test project); what needs credentials or a
test project is listed as Not Run. **Status key:** Pass = observed and as expected. Fail = observed and not as expected. Blocked = could
not run. Not Run = written but not executed. Nothing below marks an unrun test as Pass.

| Item | Result (2026-10-14) |
| --- | --- |
| Local checks (`node scripts/security/local-checks.mjs`) | 24 of 24 pass. On the first run on current `dev` check A-1 failed on a new admin-client use (`lib/data/applicant-type.ts`, Student): reviewed, added to the explicit allowed list and recorded as SF-6 |
| `npm test`, `npx tsc --noEmit`, `npx eslint`, `npm run build` | Pass: 87 of 87 unit tests (6 new: UT-82 to UT-87), no type errors, no lint findings, build finished |
| `npm audit --omit=dev` and `npm audit` | Production packages: **0 vulnerabilities**. All packages: 8 (1 moderate, 5 high, 2 critical), all in development tools (lint chain, vitest); the only fix offered is `npm audit fix --force`, a breaking change, so it was **not** applied. Recorded as SF-7 |
| Response headers on a real server (`live-tests.mjs headers` against `http://localhost:3000`, a production build) | 7 of 7 pass (LH-1 to LH-7); `curl -I` shows the same headers. The deployed site was **not** re-checked yet |
| Anonymous access to the 10 protected pages | 10 of 10 answer 307 to `/login` without a session (`/student`, `/registrar`, `/cashier`, `/department`, `/admin` and five sub-pages), on the local build |
| Anonymous access to the Data API (`live-tests.mjs anon`, 17 tables and views) | **Not Run in this record** (needs the project's anon key). A manual run earlier on 2026-10-14 found the tables refused, but it was not recorded as a case |
| Secrets in the Git history | Pass: 269 commits scanned, 0 lines adding a JWT or `sb_secret_` pattern, 0 `.env` files committed, 0 values assigned to `SUPABASE_ADMIN_KEY` (counts only; no value was printed) |
| Live tests that need test accounts (`idor`, `sqli`, `lockout`, `rate`) | **Not Run**. They need a TEST project; the script says it must not be pointed at production data |

**Changes made for this issue**

| File | Change |
| --- | --- |
| `next.config.ts` | Adds response headers on every path: `X-Frame-Options: DENY`, `Content-Security-Policy: frame-ancestors 'none'`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Content-Type-Options: nosniff`, `Permissions-Policy` (camera for the same origin only, because the Registrar scan desk needs it; microphone, location, payment off), switches off `X-Powered-By`. `Strict-Transport-Security` is **not** set by the app (Vercel already sends it, and a second copy could conflict) |
| `lib/auth/login-input.ts` (new) | Pure shape check for the sign-in form: name 1 to 254 characters, no control characters, password 1 to 1024 characters |
| `app/(auth)/login/actions.ts` | Calls the shape check before any database call and answers bad input with the generic "Invalid email or password." Before: such input reached `check_login_lockout`, the database raised 22023, and the user saw "Sign-in is temporarily unavailable" (safe, but misleading, and one wasted call) |
| `tests/unit/login-input.test.ts` (new) | UT-82 to UT-87 |
| `scripts/security/local-checks.mjs`, `scripts/security/live-tests.mjs` (new) | The two test scripts described above |

No SQL file was changed, so there is nothing for the Project Manager to run live and no rehearsal file was needed.

**ST-HDR: missing security headers (clickjacking, referrer leakage, MIME sniffing)**

| Field | Value |
| --- | --- |
| Vulnerability | Pages could be framed by another site (clickjacking); the full URL of a portal page could go to other sites in `Referer`; the browser could sniff content types |
| Affected component | Response headers of the Next.js app (`next.config.ts`; `proxy.ts` sets none) |
| Test case | ST-HDR-1: `GET /login` and an anonymous `GET /student` (redirect). Expected: `Content-Type: text/html; charset=utf-8`; `X-Frame-Options` or CSP `frame-ancestors`; `Referrer-Policy`; `nosniff`; no `X-Powered-By`; the same headers on the redirect |
| Actual result | By reading the source before the patch: `next.config.ts` had no `headers()`, and nothing else in `app`, `lib` or `proxy.ts` sets them. This is a source finding; the live response was not captured |
| Status | Before the patch: **Fail (by source inspection)**. After: **Pass on a local production build** (7 of 7); **deployed site Not Run** |
| Solution | Headers added in `next.config.ts` (table above). `Content-Type` is set by Next.js and was not duplicated. A full CSP was not added (see SF-3) |
| Verification | Local checks H-1 to H-8: Pass. `live-tests.mjs headers` against `http://localhost:3000` (production build): LH-1 to LH-7 Pass; `curl -I` shows `X-Frame-Options: DENY`, `Content-Security-Policy: frame-ancestors 'none'`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Content-Type-Options: nosniff`, `Permissions-Policy: camera=(self), microphone=(), geolocation=(), payment=()`, no `X-Powered-By`. **Not Run:** the same on `cabuyaouni.vercel.app` after the release, and the Registrar scan desk still opening the camera under `camera=(self)` (a phone is needed) |
| Execution record | 2026-10-14, Claude (local production build). Deployed site: date ______ name ______ |

**ST-SQL: SQL injection (SEC-05)** (payloads `' OR 1=1 --`, `'; DROP TABLE x; --`)

| Field | Value |
| --- | --- |
| Vulnerability | User text reaching a SQL statement unescaped |
| Affected component | Login (`app/(auth)/login/actions.ts`, RPC `check_login_lockout`, `record_login_attempt`, `login_email_for_student_id`); hold reason (`lib/data/department-actions.ts`, 300 characters); remarks (`documents-actions.ts`, `applications-actions.ts`, `enrollments-review-actions.ts`, `department-actions.ts`); receipt number (`cashier-actions.ts`, 40 characters); document purpose (`documents-actions.ts`, `MAX_PURPOSE`) |
| Test case | ST-SQL-1 (script, as student A through the Data API): insert a document request with each payload as `purpose`; expected: stored as the same literal text, or refused without query details; `document_types` and `profiles` row counts unchanged. ST-SQL-2 (by hand in the browser, because these are Server Actions): put each payload in the login name, the hold reason, a remark, the receipt number and the purpose; expected: the same |
| Actual result | **Source inspection only.** No SQL driver, `.raw()` or `sql` template in `app`, `components` or `lib`; no table or function name built from a variable; every data call uses supabase-js (`.from()`, `.rpc()` with an argument object). No stored function body in `docs/database` builds SQL with `EXECUTE` (the `EXECUTE` lines are in one-off DO blocks and diagnostics). Local checks Q-1, Q-2, Q-5: Pass. No payload was sent anywhere |
| Status | **Not Run** (static review: no confirmed vulnerability) |
| Solution | No patch needed for SQL construction. Added the login shape check (above) as input hygiene, not as the injection defence |
| Verification | UT-87 documents that the payloads are not filtered. **Live ST-SQL-1 and ST-SQL-2 Not Run**; commands in "How to finish" below |
| Execution record | Static review 2026-10-14, Claude. Live run: date ______ name ______ |

**ST-LOCK: brute-force protection (SEC-03)**

| Field | Value |
| --- | --- |
| Vulnerability | Unlimited password guessing |
| Affected component | Login action, then `check_login_lockout` and `record_login_attempt` (`docs/database/login_lockout.sql`): 5 failures, 60 s doubling, 900 s cap, 24 h window (read from the SQL file; not observed live) |
| Test case | ST-LOCK-1 (browser): 5 wrong passwords for a test account, then the right password; expected: "Too many failed sign-in attempts. Try again in 1 minute." and no password check; after the wait the right password works. ST-LOCK-2 (script): 8 wrong passwords straight to the Supabase Auth endpoint, then the right one; expected by the SRS: refused. ST-LOCK-3: a student ID and the matching email share one lock |
| Actual result | Source: the lockout runs only inside the login Server Action, before `signInWithPassword` (local check A-4: Pass). The anon key is public by design, so the Auth endpoint can be called without the app. The header of `login_lockout.sql` already lists this as a residual risk. **Not observed**: nothing was run |
| Status | ST-LOCK-1 and ST-LOCK-3: **Not Run**. ST-LOCK-2: **Not Run**; expected to **Fail** (open finding SF-1) |
| Solution | No code patch. A correct fix is outside the app code: Supabase Auth rate limits and CAPTCHA in the dashboard, or a password-verification hook that applies the same lock inside the database. Both need a test project; see SF-1. The existing app lockout was not changed |
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
| Solution | No code patch. The control is a dashboard rule (no code, no secret). Follow-ups in SF-2 |
| Verification | `FLOOD_COUNT=40 BASE_URL=<preview> ALLOW_REMOTE_FLOOD=1 node scripts/security/live-tests.mjs rate` |
| Execution record | Earlier run: 2026-10-12 (see `docs/rate-limiting.md`). This issue: Not Run |

**ST-IDOR: broken access control and IDOR (SEC-02, ETH-01; TC-12 to TC-39, TC-71)**

| Field | Value |
| --- | --- |
| Vulnerability | A user reads or changes another user's record by changing an id in a request or URL; a role does something outside its scope; anonymous access |
| Affected component | RLS policies (`docs/database/rls.sql`, `hardening*.sql`), grants (`grants_clearance.sql`), the proxy (`lib/supabase/proxy.ts`), `getAdminClientFor` (`lib/supabase/admin.ts`) |
| Test case | ST-IDOR-1 (script): student A asks for student B's rows in `students`, `enrollments`, `document_requests`, `academic_holds`, `clearances`, `v_grades`; expected 0 rows; A updates and deletes B's document request by id: 0 rows changed; a student cannot read `audit_logs`. ST-IDOR-2: anonymous read of 17 tables and views: no rows. ST-IDOR-3 (browser): signed in as a student, open `/registrar`, `/cashier`, `/department`, `/admin` and another role's sub-pages directly: redirected to `/student`. ST-IDOR-4: the SQL suites TC-12 to TC-39 and TC-71 |
| Actual result | Source: every `getAdminClientFor` call passes the matching role (`Admin` in `admin-users-actions.ts`, `Registrar` in `applications-actions.ts`; local check A-1: Pass); the proxy validates with `getUser()` (A-3: Pass); public paths are only `/apply` and `/auth/confirm` (A-2: Pass); other actions run with the caller's own session so RLS decides. The proxy only guides navigation; the database is the gatekeeper. On the local production build the 10 protected pages all answer 307 to `/login` without a session (observed, 2026-10-14). **No Data API request was sent** and the SQL suites were not re-run. Their last recorded live results are in section 6 (2026-10-11 to 2026-10-13: Pass) |
| Status | Anonymous page access: **Pass** (10 of 10, local build). ST-IDOR-1, ST-IDOR-2 (`anon`, `idor`) and ST-IDOR-3 (signed in as the wrong role): **Not Run**. No defect found by source review |
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
| Solution | No patch needed. A full CSP would add a second layer (SF-3) |
| Verification | Not Run. Browser steps above |
| Execution record | Static review 2026-10-14, Claude. Live run: date ______ name ______ |

**ST-DEP and ST-SEC: dependency audit and secret handling (SEC-06)**

| Field | Value |
| --- | --- |
| Vulnerability | A known-vulnerable dependency; a secret in the repository, the browser bundle or a `NEXT_PUBLIC_` name |
| Affected component | `package.json` and `package-lock.json`; `lib/supabase/admin.ts`; `.gitignore`; environment variable names |
| Test case | ST-DEP-1: `npm audit` and `npm audit --omit=dev`; expected: no high or critical finding that applies. ST-SEC-1: only the Supabase URL and anon key are public; the admin key is read in one server-only file; no secret in files or history |
| Actual result | ST-DEP-1 (2026-10-14): `npm audit --omit=dev` found 0 vulnerabilities; `npm audit` found 8 (1 moderate, 5 high, 2 critical), all in development-only packages (the lint chain and vitest), not shipped to users; the only fix offered is `npm audit fix --force` (breaking), so it was not applied (SF-7). ST-SEC-1 on the working tree: the only `NEXT_PUBLIC_` names are `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` (S-1: Pass); `SUPABASE_ADMIN_KEY` appears only in `lib/supabase/admin.ts`, which imports `server-only` (S-2, S-3: Pass); no Client Component imports it or `QUEUE_QR_SECRET` (S-4: Pass); `.env*` is ignored (S-5: Pass); no JWT, `sb_secret_`, private-key or AWS-key pattern in source, docs or tests (S-6: Pass). **Git history checked** (269 commits): no JWT or `sb_secret_` pattern added, no `.env` file ever committed, no value assigned to `SUPABASE_ADMIN_KEY` (counts only) |
| Status | ST-DEP-1: **Pass for production packages (0)**; development-only findings recorded (SF-7). ST-SEC-1: working tree **Pass**; history **Pass** |
| Solution | None needed for the working tree. Any `npm audit` fix is to be chosen after the report is read (no `npm audit fix --force`) |
| Verification | ST-DEP-1 Not Run. For history: `git log --all -p -S"SUPABASE_ADMIN_KEY" -- . ':!docs'` and `git log --all --full-history -- '.env*'`; do not paste any value into a report |
| Execution record | 2026-10-14, Claude |

**Open findings (to be filed as issues; none is hidden)**

| ID | Finding | Status |
| --- | --- | --- |
| SF-1 | The login lockout does not cover direct calls to the Supabase Auth endpoint (known residual risk of V-2; expected to be confirmed by ST-LOCK-2). Options to decide with the Project Manager: Supabase Auth rate limits and CAPTCHA, or a database-side password-verification hook. Any SQL goes in one file in `docs/database/` with a rollback block, rehearsed in a rolled-back transaction, run live by the Project Manager | Open, not patched |
| SF-2 | Rate limiting is a dashboard rule outside the repository and was observed only for `/login`; no stricter rule for sign-in; Server Actions and the Auth endpoint not tested | Open |
| SF-3 | No full Content-Security-Policy. The inline theme script in `app/layout.tsx` means a strict `script-src` needs per-request nonces; test it in a browser before shipping | Open, recommendation |
| SF-4 | The set-password link falls back to the request host when `SITE_URL` is not set (`siteUrl()` in `admin-users-actions.ts` and `applications-actions.ts`). Only an Admin or Registrar can trigger it and the host is pattern-checked, so the risk is low. Recommendation: make sure `SITE_URL` is set in Vercel production | Open, recommendation, not tested |
| SF-5 | `npx tsc --noEmit`, `npx eslint`, `npm run build`, `npm test` and `npm audit` on the changes of this issue | **Closed**: all run on 2026-10-14 (see the table at the top) |
| SF-6 | `lib/data/applicant-type.ts` reads ONE row, the signed-in student's own application, with the admin client, because the applications table is private (only the Registrar can read it). The role is proven first (`getAdminClientFor('Student')`) and the query is filtered by the student's own id. Cleaner: a database policy that lets a student read only their own `applicant_type`, so no admin key is used on a student page | Open, accepted for now; the local check lists this call explicitly |
| SF-7 | `npm audit` reports 8 findings (1 moderate, 5 high, 2 critical) in development-only packages; none is in the production dependencies (`npm audit --omit=dev`: 0). The only fix offered, `npm audit fix --force`, is a breaking change | Open, accepted and recorded (not shipped to users) |

**How to finish (what is still Not Run)**

1. **Anonymous Data API** (read-only, safe on the live project; needs only the public anon key from the Supabase dashboard, Project Settings, API): in PowerShell, from the repository root, set `$env:SUPABASE_URL` and `$env:SUPABASE_ANON_KEY`, then `node scripts/security/live-tests.mjs anon`. Expect PASS for all 17.
2. **Deployed site headers:** after the release, `$env:BASE_URL='https://cabuyaouni.vercel.app'; node scripts/security/live-tests.mjs headers` (7 checks), and open the Registrar queue on a phone to confirm the scan camera still starts.
3. **Needs a TEST Supabase project and test accounts** (the script is not meant for production data): `live-tests.mjs idor`, `sqli`, `lockout`, `rate` with the variables listed at the top of that file.
4. **By hand in the browser** (hostile text typed into forms; it writes rows, so use test data): ST-SQL-2, ST-LOCK-1, ST-LOCK-3, ST-IDOR-3, ST-XSS-1.
5. Fill the date and the name in each Execution record and change each Status to what was observed; file SF-1, SF-2, SF-3, SF-4, SF-6 and SF-7 as issues if they stay open.
6. Review by a teammate (issue #108 requires it) before the merge into `dev`; the Project Manager merges `dev` into `main`.

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
| F-8 | The queue rehearsal (`queue_rules_rehearsal.sql`), 2026-10-13, passed with no failure on its first run, both the first design and the revised one (random ticket codes, window in the student status, student card). Earlier rehearsals found defects (F-4 to F-6); this one found none | Recorded so a clean result is not read as an unchecked one: the live run and the live test file were run as well |
| D-4 | The browser checks of 2026-10-13 changed live data: one queue ticket (#8503599) for student 2026-0004 went Waiting, Serving, Done, with its audit rows. The audit rows and the ticket stay (append-only) | Recorded; daily numbering restarts each Manila day |

## 12. Gaps and work not done (nothing is hidden)

| Item | Level | Status | Plan |
| --- | --- | --- | --- |
| Unit tests | 1 | Done (78 of 78 pass) | Section 5. Not covered: React components and the Server Actions as a whole (levels 2 and 3) |
| Acceptance script run and signed off by team members | 4 | Not done | Section 9. Before the freeze on 2026-10-15. Owner: to be named by the PM |
| Performance: PER-01 on a phone and on a throttled network; PER-02 on a larger data set | 5 | Not done | All five roles were measured on the live site on 2026-10-14 (pass); demo-size data and one network only (issue #109) |
| Rate limiting (SEC-04) | 6 | Done (sign-in route) | Vercel firewall rule "Limit POST requests per IP" (POST, 60 s fixed window, 20 requests per IP, 429) tested 2026-10-12: 429 after about 24 POSTs in a minute from one IP; see `docs/rate-limiting.md` |
| SQL injection direct test | 6 | Not done | Issue #108. Owner and date not set |
| Lockout residual risks (DoS lockout, direct Auth endpoint, race) | 6 | Not tested | Documented as accepted risks; test or mitigate if time allows |
| Student enrollment submit, add and remove forms | 3 | Partly done | Submit and add done 2026-10-14 (E-01 to E-04); Remove button and a second enrollment from the screen not clicked |
| Reject button on the Registrar enrollments screen | 3 | Done with gaps | Reject with remarks done 2026-10-14 (E-06); Reject with EMPTY remarks and the student's view of the rejection not recorded |
| Friendly error messages of the new screens | 3 | Not done | Trigger each message in the browser |
| Audit rows of the 2026-10-12 browser writes | 3, 6 | Not done | Admin audit log screen |
| Admin user accounts and academic catalog (REQ-ADM-01, REQ-ADM-04) | 3 | Not done | Admin users is a stretch item; no test recorded for either |
| Same checks on the deployed Vercel site, all roles | 3 | Not done | Issue #116 |
| Phone-width and dark-mode scans, CSV export | 3 | Not done | Issue #106 |
| TC-94 | 2 | No case exists | Not claimed |
| Queue: camera scan and USB barcode scanner | 3 | Not done | Needs the hardware. A USB scanner must be a 2D imager that can read a phone screen |
| Queue: student photo on the card, visit day in the acceptance email, Realtime | 3 | Not built | A photo placeholder is in the SQL and on the screen. Polling every 5 to 10 s is used instead of Realtime (a student cannot see other tickets under the privacy rules, so Realtime would only signal that something changed) |
| Queue: Leave the queue, No-show, several students and the 25th-in-line text, audit rows on screen, the Documents queue for students | 3 | Not done | The database supports Documents; only the Enrollment queue is wired to students |
| Queue: `QUEUE_QR_SECRET` on Vercel | 6 | Not done | The variable must be added to the Vercel project before dev is merged to main, or the QR is "not set up" on the live site |
| Notifications: older test files after the change | 2 | Not done | `notifications_rules.sql` is live (2026-10-13) and its 32 tests pass. Older test files that compare a table's full trigger list (grades_rules_test.sql TC-83, documents_rules_test.sql TC-95, trigger_dept_approval_test.sql, trigger_finance_autoclear_test.sql, trigger_final_clearance_test.sql) need their expected lists updated; `queue_rules.sql` must not be run again as it stands (its own check expects two triggers on `queue_tickets`) |
| Notifications: the screens in the browser with real events, the badge, the bell on a phone | 3 | Not done | The database part is live. Only the layout was seen, with fake data at phone width |
| Notifications: retention and Admin events | 2 | Not decided | Proposed: delete read notifications after 90 days and everything after 12 months (maintenance queries in the SQL header); the Admin receives no event yet |
| Queue: stale tickets and retention | 2 | Not done | Maintenance m1 (close tickets left open from an earlier day) and the 12-month retention proposal are in the header of `queue_rules.sql`; nothing runs automatically |

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
| PER-01 | PERF-01 | Pass (all five roles) |
| PER-02 | PERF-02 | Pass |
| PER-03 deploy on merge to main | Vercel deployment of main verified 2026-10-11 (signed in as student1; see HANDOFF.md) | Partly: not a written test case |
| ETH-01 privacy between students | N-01, N-02, TC-12 to TC-14 | Pass |
| ETH-02 data minimization | none | Not tested: a review item for the ethical analysis (issue #111) |
| Physical queuing for enrollment (professor's pain point) | UT-50 to UT-60 (QR), UT-61 to UT-66, TC-139 to TC-166, Q-01 to Q-09 | Partly: the core flow passes in the browser with a typed code; the camera, a USB scanner, a phone and the photo are not tested; proxy queuing is a documented residual risk (V-7) |
| Notifications (all roles) | UT-73 to UT-78; TC-167 to TC-198 | Partly: the database part passes live; the screens are not yet tested with real events in the browser |

## 14. How to re-run, and what is still to fill in

1. Database cases: paste the file named in section 6 into the Supabase SQL editor, as postgres, one tab per file, and run the
   whole tab (each ends in a rollback). The regression is one paste: `docs/database/regression_after_grants.sql`.
2. Browser walk: sign in to each account in the browser pane in the order of section 7.1; use the throwaway-term steps of
   E2E-01 if no student without a clearance exists.
3. Unit tests: `npm test` (no secret and no database needed). Queue database tests: `docs/database/queue_rules_test.sql` (one rolled-back transaction; run it when nobody is using the queue, TC-165 briefly touches today's Enrollment queue). The queue pages need `QUEUE_QR_SECRET` in `.env.local`.
4. Before a pull request: `npm test`, `npx tsc --noEmit`, `npx eslint app components lib types`, `npm run build`.

Still to fill in before the freeze (2026-10-15): level 4 (acceptance sign-off), level 5 (performance), the
rate limiting test of the write actions, the SQL injection test, and the gaps of section 12.
