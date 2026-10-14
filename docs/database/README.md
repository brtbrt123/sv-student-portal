# Database SQL (Supabase / PostgreSQL)

SQL scripts needed to recreate the Centralized Student Portal database and to
review its Row Level Security (RLS) policies locally. Owned by the **Backend
team** (see Project Charter, section 5: "ERD and 3NF Tables").

| File                   | Contents                                                                 |
| ---------------------- | ------------------------------------------------------------------------ |
| `schema.sql`           | 23 tables (3NF) in dependency order, plus `document_ticket_seq`          |
| `views.sql`            | The 4 views (`security_invoker = true`), as live after `views_extend.sql`|
| `seed.sql`             | Fictional test data: 7 accounts' profiles, 3 students, one full term     |
| `private_functions.sql`| The 6 functions in schema `private`, exported from live                  |
| `rls.sql`              | `ENABLE ROW LEVEL SECURITY` on all 23 tables and all 49 live policies    |
| `hardening.sql`        | Issue #50 fixes: 3 policies, `my_department_id()`, immutable-column triggers; rollback and grant/trigger diagnostics as comments |
| `hardening2.sql`       | Issue #50, part 2, three sections run separately: A `holds_dept_place` checks the student's program department; B audit-log triggers (REQ-ADM-03) and append-only `audit_logs`; C grants cleanup. A rollback block per section |
| `triggers.sql`         | Record (not a script) of the app's table triggers after `hardening.sql`, `hardening2.sql`, `trigger_dept_approval.sql`, `trigger_finance_autoclear.sql` and `trigger_final_clearance.sql`, with the firing order per table |
| `views_extend.sql`     | Issue #49: extends `v_grades`, `v_clearance_items`, `v_clearances` to the columns of `types/database.types.ts` (`CREATE OR REPLACE`, still `security_invoker = true`); safety checks, rollback and diagnostics as comments |
| `grants_clearance.sql` | Issue #60: exposes the clearance slice to `authenticated` only (SELECT on 3 views, `charges`, `payments`, `audit_logs`; column-level writes on `clearances`, `clearance_items`, `academic_holds`, `payments`, `charges`), then repeats the anon part of `hardening2.sql` section C; checks before and after, rollback and diagnostics as comments. **Run live 2026-10-11** |
| `grants_clearance_test.sql` | Tests TC-34 to TC-39 for `grants_clearance.sql` (each block ends in `ROLLBACK`), plus how to rehearse the whole change in a rolled-back transaction (TC-34R). The setup of TC-37 and TC-39 changed for issue 24 (items cleared first); not re-run yet |
| `regression_after_grants.sql` | Issue 21 (#60): TC-12 to TC-33 as one rolled-back script with one result row (run live 2026-10-11, all pass). TC-18 / TC-19 changed for issue 24 (they approve a throwaway clearance whose items are all cleared); not re-run yet |
| `e2e_negative_tests.sql` | Issue 30 (#69), TC-71: a department cannot read or approve another department's item (rolled back; run 2026-10-11, passes) |
| `trigger_dept_approval.sql` | Issue 22 (#61), REQ-DPT-03: BEFORE UPDATE trigger `require_no_active_hold` on `clearance_items` (function `private.require_no_active_hold()`, SECURITY DEFINER) rejects clearing an item while the student has an active hold of the same department; safety checks before and after, rollback and diagnostics as comments. **Run live 2026-10-11** |
| `trigger_dept_approval_test.sql` | Tests TC-41 to TC-48 for `trigger_dept_approval.sql` (each block creates its own data and ends in `ROLLBACK`) |
| `trigger_dept_approval_rehearsal.sql` | `trigger_dept_approval.sql` plus TC-41 to TC-48 in ONE rolled-back transaction with one result row (paste once, nothing committed) |
| `trigger_finance_autoclear.sql` | Issue 23 (#62), REQ-CSH-03: function `private.finance_autoclear()` (SECURITY DEFINER) with two triggers, `finance_autoclear` on `charges` and `finance_autoclear_on_create` on `clearance_items`, clears the Financial item automatically when every charge of the student for that term is Cleared or Waived (`cleared_by` = the Cashier who tagged the last charge); skips on an active Financial hold, never overwrites, never un-clears; design decisions in the header; safety checks before and after, rollback and diagnostics as comments. **Run live 2026-10-11** |
| `trigger_finance_autoclear_test.sql` | Tests TC-49 to TC-61 for `trigger_finance_autoclear.sql` (each block creates its own data and ends in `ROLLBACK`; TC-50 uses the seed rows) |
| `trigger_finance_autoclear_rehearsal.sql` | `trigger_finance_autoclear.sql` plus TC-49 to TC-61 in ONE rolled-back transaction with one result row; its test part (from the `TESTS START HERE` line) also runs on its own once the change is live |
| `trigger_final_clearance.sql` | Issue 24 (#63), REQ-REG-03: BEFORE UPDATE trigger `require_all_items_cleared` on `clearances` (function `private.require_all_items_cleared()`, SECURITY DEFINER) rejects approving a clearance (`approved_at` or `approved_by` NULL -> value) while any of its items is pending (the Financial item included) or when it has no items; SQLSTATE P0001, message `pending items: ...`; applies to every role; who may approve is unchanged (Registrar only, by policy); design decisions in the header; safety checks before and after, rollback and diagnostics as comments. **NOT RUN YET** (untested, no local PostgreSQL) |
| `trigger_final_clearance_test.sql` | Tests TC-62 to TC-70 for `trigger_final_clearance.sql` (each block creates its own data and ends in `ROLLBACK`) |
| `trigger_final_clearance_rehearsal.sql` | `trigger_final_clearance.sql` plus TC-62 to TC-70 in ONE rolled-back transaction with one result row (TC-62R); its test part (from the `TESTS START HERE` line) also runs on its own once the change is live |
| `login_lockout.sql` | Issue #90 (Sprint 4 issue 34), SEC-03: login lockout with exponential backoff. `public.check_login_lockout(p_email)` (returns only `locked`, `seconds_remaining`) and `public.record_login_attempt(p_email, p_success, p_ip)`, both SECURITY DEFINER with EXECUTE for anon and authenticated only; helpers `private.login_lockout_settings()` (the policy constants: 5 failures, 60 s doubling, cap 900 s, 24 h window, 254 characters), `private.login_lockout_email()`, `private.login_lockout_state()`; index on `login_attempts (lower(email), attempted_at DESC)`; anon loses every privilege on `login_attempts`, authenticated loses writes. A success is accepted only from the signed-in owner of the email; failures while locked are ignored. Design decisions and residual risks (DoS lockout, direct calls to Supabase Auth, check/sign-in race) in the header; safety checks before and after, rollback, diagnostics and maintenance (retention) as comments. **Run live 2026-10-12** (rehearsed first; TC-72 to TC-82 pass live) |
| `login_lockout_test.sql` | Tests TC-72 to TC-82 for `login_lockout.sql`, ONE rolled-back transaction with one result row (own throwaway data under `@lockout.test`, anon simulated with `SET LOCAL ROLE anon`) |
| `login_lockout_rehearsal.sql` | `login_lockout.sql` plus TC-72 to TC-82 in ONE rolled-back transaction with one result row (TC-72R); its test part (from the `TESTS START HERE` line) is the same as `login_lockout_test.sql` |
| `grades_rules.sql` | Issue 36 (#92), REQ-REG-01: grades path. Grants on `grades` (SELECT; INSERT `enrollment_item_id, grade_code, encoded_by`; UPDATE `grade_code, encoded_by`; no DELETE) and `v_grades` (SELECT) to `authenticated` only, nothing for anon; BEFORE triggers `require_approved_enrollment` (a grade only for an item of an Approved enrollment; SQLSTATE P0001, message `not approved: ...`) and `stamp_encoded_at` (`encoded_at` = now() on every write, not granted to clients); policies unchanged (Registrar only, `encoded_by` = own id); `grade_code` checked by the existing foreign key to `grade_scale`; safety checks before and after, rollback and diagnostics as comments. **Run live 2026-10-12** (rehearsed first, passed) |
| `grades_rules_test.sql` | Tests TC-83 to TC-93 for `grades_rules.sql` in ONE rolled-back script with one result row (creates its own throwaway term, enrollments and grades) |
| `grades_rules_rehearsal.sql` | `grades_rules.sql` plus TC-83 to TC-93 in ONE rolled-back transaction with one result row; its test part (from the `TESTS START HERE` line) also runs on its own once the change is live |
| `documents_rules.sql` | Issue 37 (#93), REQ-DOC-01 / REQ-DOC-02: grants on `document_requests` (SELECT; INSERT `student_id, document_type_id, purpose, copies`; UPDATE `status, remarks`; no DELETE), SELECT on `document_types`, USAGE only on `document_ticket_seq` (the ticket DEFAULT needs it; first time sequence grants are written down), nothing for anon; BEFORE UPDATE trigger `require_document_status_flow` (function `private.require_document_status_flow()`, SECURITY INVOKER) allows only Pending -> Processing -> Ready -> Released and Pending / Processing -> Rejected (final states locked, every role; SQLSTATE P0001, message `bad status change: ...`) and sets `processed_by` / `processed_at` itself; design decisions in the header; safety checks before and after, rollback and diagnostics as comments. **Run live 2026-10-12** (rehearsed first, passed) |
| `documents_rules_test.sql` | Tests TC-95 to TC-108 for `documents_rules.sql` as one rolled-back script with one result row (`all_ok` plus one cell per case) |
| `documents_rules_rehearsal.sql` | `documents_rules.sql` plus TC-95 to TC-108 in ONE rolled-back transaction with one result row (TC-95R); its test part (from the `TESTS START HERE` line) is the same as `documents_rules_test.sql` |
| `enrollment_rules.sql` | Issue 38 (#94), REQ-STU-05 / REQ-REG-04: unique keys `(student_id, term_id)` on enrollments and `(enrollment_id, section_id)` on enrollment_items (only if missing); BEFORE trigger `require_enrollment_rules` on enrollments (new enrollment Pending, one per student per term, Pending -> Approved / Rejected with both final, `reviewed_by` / `reviewed_at` set by the database, approval needs at least one section, all of the term, and a free seat in each: Approved only, section rows locked) and BEFORE trigger `require_enrollment_item_rules` on enrollment_items (only while Pending, same term, no section twice); SQLSTATE P0001 with the prefixes `enrollment exists:`, `invalid status:`, `enrollment locked:`, `reviewer required:`, `wrong term:`, `duplicate section:`, `no items:`, `section full:`; column grants for authenticated (enrollments INSERT student_id, term_id, year_level and UPDATE status, reviewed_by, reviewed_at, remarks; enrollment_items INSERT enrollment_id, section_id and DELETE), anon nothing, no DELETE on enrollments; policies unchanged; design decisions in the header; safety checks before and after, rollback and diagnostics as comments. **Run live 2026-10-12** (rehearsed first; TC-109 to TC-122 pass live) |
| `enrollment_rules_test.sql` | Tests TC-109 to TC-122 for `enrollment_rules.sql`, ONE rolled-back transaction with one result row (own throwaway terms, sections and enrollments; TC-109 also lists the live CHECK / UNIQUE constraints) |
| `enrollment_rules_rehearsal.sql` | `enrollment_rules.sql` plus TC-109 to TC-122 in ONE rolled-back transaction with one result row (TC-109R); its test part (from the `TESTS START HERE` line) is the same as `enrollment_rules_test.sql` |
| `applications_rules.sql` | Enrollment site for new applicants: table `applications` (RLS; Registrar-only SELECT / UPDATE policies; authenticated SELECT + UPDATE (status, remarks), anon nothing; CHECKs, partial unique "one open application per email", audited); `list_programs()` and `submit_application(...)` (SECURITY DEFINER, anon + authenticated; validation SQLSTATE 22023 `invalid application:`; silent success on duplicate / existing account / cap of 3 per email per year, no enumeration; hourly flood valve P0001 `try later:`); `next_student_number()` (`YYYY-NNNN`, Manila year, new `student_number_seq` placed after the highest existing number; not executable by anon / authenticated); BEFORE trigger `require_application_rules` (Pending -> Accepted / Rejected, both final, reviewer and time set by the database, P0001 `remarks required:` / `bad decision:`, one-time `student_id` link of an Accepted application to a matching Student with `provisioned_at` set by the database); retention proposal (12 months) and maintenance queries in the header; safety checks (including live CHECK constraints tested with sample values) before and after, rollback and diagnostics as comments. **Run live 2026-10-12** |
| `applications_rules_test.sql` | Tests TC-123 to TC-135 for `applications_rules.sql`, ONE rolled-back transaction with one result row (own applications under @applicant.test; provisioning links seed students; TC-123 also lists the live CHECK / UNIQUE constraints; TC-133 restores the sequence) |
| `applications_rules_rehearsal.sql` | `applications_rules.sql` plus TC-123 to TC-135 in ONE rolled-back transaction with one result row (TC-123R); its test part (from the `TESTS START HERE` line) is the same as `applications_rules_test.sql` |
| `applications_server_grants.sql` | Table privileges for the app's server-side admin client (account setup after "Accept application"): SELECT on `roles`, SELECT / INSERT / DELETE on `profiles` and `students`, SELECT and UPDATE (student_id, provisioned_at) on `applications`. Added because hardening2.sql section C left the server role without access to tables not exposed in the Data API (first live run stopped at "permission denied for table roles"). Only adds privileges; finds the role by property (not by name; the scrub forbids that); also touches Supabase's internal bypass-RLS roles (3 roles at the time). **Run live 2026-10-12** |
| `applications_server_grants_rehearsal.sql` | The same body ending in ROLLBACK, with one result row (all cells true) |
| `student_id_login.sql` | **Run live 2026-10-12.** Sign in with a student ID: `public.login_email_for_student_id(text)` (SECURITY DEFINER, EXECUTE for anon and authenticated) returns the email an ID signs in with (the account's email, the internal `<id>@students.pnc.test` for an ID nobody has, NULL for input that is not an ID; accepts `2026-0001` and `20260001`); never returns a password or a contact email; residual note in the header. |
| `student_id_login_test.sql` | Tests TC-136 to TC-138 for `student_id_login.sql`, ONE rolled-back transaction with one result row |
| `student_id_login_rehearsal.sql` | `student_id_login.sql` plus TC-136 to TC-138 in ONE rolled-back transaction with one result row |
| `catalog_grants.sql` | Issue 39 (REQ-ADM-04): Admin academic catalog. Grants on `departments`, `programs`, `terms`, `subjects`, `sections` to `authenticated` only (SELECT; column-level INSERT / UPDATE, link columns and `department_type` insert-only; no DELETE; `REVOKE ALL` from anon, which still held INSERT / UPDATE / DELETE); partial unique index `uq_terms_one_current_term`, CHECK `terms_dates_order` (and `sections.capacity > 0`, already live); `audit_log` triggers on the 5 tables; policies unchanged (Admin only, by policy). The rehearsal and tests TC-218 to TC-225 are the rolled-back block at the bottom of the file. Design decisions and limits in the header; safety checks before and after, rollback and diagnostics as comments. **Run live 2026-10-14** (rehearsal TC-218 to TC-225 passed on the live project; `regression_after_grants.sql` unchanged afterwards) |
| `catalog_grants_rehearsal.sql` | `catalog_grants.sql` plus TC-218 to TC-225 in ONE rolled-back transaction with one result row (generated from it; run it before the live change) |
| `admin_users.sql` | Issue 40 (REQ-ADM-01): Admin user accounts. BEFORE UPDATE OF role_id, is_active trigger `prevent_last_admin_deactivation` on `profiles` (function `private.trg_prevent_last_admin_deactivation()`, SECURITY DEFINER, advisory lock; SQLSTATE P0001, message `last admin: ...`; applies to every role); grants to `authenticated` only: `profiles` SELECT + UPDATE (`role_id`, `is_active`, `first_name`, `last_name`), no INSERT / DELETE (accounts are created and removed by the server-side admin client only); `department_staff` SELECT, INSERT (`profile_id`, `department_id`), UPDATE (`department_id`), DELETE; policies unchanged (Admin only, by policy). `profiles` has no `department_id`: the department is the `department_staff` row. The rehearsal and tests TC-226 to TC-233 are the rolled-back block at the bottom of the file. Decision record: `docs/decisions/sprint4-admin-users.md`. **Run live 2026-10-14** (rehearsal TC-226 to TC-233 passed on the live project; `regression_after_grants.sql` unchanged afterwards) |
| `admin_users_rehearsal.sql` | `admin_users.sql` plus TC-226 to TC-233 in ONE rolled-back transaction with one result row (generated from it; run it before the live change) |
| `queue_rules.sql` | Virtual queue (ticket numbers) for the Registrar window: 3 new tables, RLS on all three: `queue_services` (seeded Enrollment `E`, Documents `D`; SELECT policy for every signed-in user), `queue_tickets` (status Waiting / Serving / Done / No-show / Cancelled, one active ticket per student per service per Manila day; internal `ticket_number` (sequential, decides the order) and a random 7-digit `ticket_code` from `gen_random_uuid()` (never `random()`), both unique per service per day; labels shown to people are `#` + code, e.g. `#8124231`; `ticket_prefix` no longer used in labels; reserved `checkin_photo_path`; SELECT policy: own rows or Registrar; audited), `queue_counters` (per-service, per-day counter, no policy); authenticated SELECT only on the three (TC-27 needs it), no writes for anyone, anon nothing; 7 SECURITY DEFINER functions, EXECUTE for authenticated only: `issue_queue_ticket(uuid, text)`, `queue_call_next(text, text)`, `queue_finish(bigint, text)`, `queue_cancel_my_ticket(text)`, `queue_my_status(text)` (with the window of the student's own Serving ticket), `queue_staff_list(text)`, `queue_student_card(uuid)` (Registrar's scan-screen card; a photo path will be added there later) (role checked inside; 42501 `not allowed:`, 22023 `invalid ticket request:`, P0001 `queue closed:` / `already queued:` / `finish first:` / `queue busy:` / `bad ticket change:`); BEFORE UPDATE trigger `require_queue_ticket_rules` (status flow, immutable columns including `ticket_code`, `called_at` / `finished_at` by the database, every role); design decisions, residual risks and retention proposal in the header; safety checks (including live CHECK constraints on `audit_logs` tested with sample values) before and after, rollback, diagnostics and maintenance as comments. **NOT RUN YET** |
| `queue_rules_test.sql` | Tests TC-139 to TC-166 for `queue_rules.sql`, ONE rolled-back transaction with one result row (own throwaway services TCQ-A / TCQ-B / TCQ-C; TC-165 may add one ticket of a seed student to the real Enrollment service, rolled back; seed students as ticket holders, no account created; TC-162 also lists the live CHECK / UNIQUE constraints) |
| `queue_rules_rehearsal.sql` | `queue_rules.sql` plus TC-139 to TC-166 in ONE rolled-back transaction with one result row (TC-139R); its test part (from the `TESTS START HERE` line) is the same as `queue_rules_test.sql` |
| `notifications_rules.sql` | In-app notifications for every role: table `notifications` (RLS; SELECT policy `notifications_own_read`, own rows only; authenticated SELECT only (TC-27 needs it), no writes for anyone, anon nothing; CHECKs on `kind` (a short code), `title` (1..120), `body` (<= 400) and `link` (an in-app path, <= 200); `recipient_id` FK to profiles ON DELETE CASCADE; not audited); BEFORE UPDATE trigger `require_notification_rules` (only `read_at`, NULL -> now() by the database, never back, every role); 3 SECURITY DEFINER functions, EXECUTE for authenticated only, any active account: `list_my_notifications(integer, boolean)` (newest first, limit clamped to 1..100), `notification_unread_count()`, `mark_notifications_read(bigint[])` (own rows only; 42501 `not allowed:`); helpers `private.notify` (never raises, trims, drops a bad link, active recipients only), `private.notify_role`, `private.notify_office` (department heads through `department_staff` with role Department, plus the Cashiers for the Financial department), `private.person_name`; 8 AFTER ROW triggers `trg_notify_<table>` on queue_tickets, enrollments, document_requests, clearance_items, clearances, academic_holds, grades, applications (each the last AFTER trigger of its table, SECURITY DEFINER, wrapped so it can never fail the original statement) creating 17 kinds for students, Registrars, department heads and Cashiers (none for Admin yet); design decisions, residual risks (including the older trigger-list checks it changes) and a retention proposal in the header; safety checks before and after, rollback, diagnostics and maintenance as comments. **NOT RUN YET** |
| `notifications_rules_test.sql` | Tests TC-167 to TC-198 for `notifications_rules.sql`, ONE rolled-back transaction with one result row (throwaway term 2091-2092, clearance, holds, requests, grades, two @notify.test applications and a throwaway queue service TCN-A; TC-173 adds one ticket to each real queue service, rolled back; TC-196 / TC-197 make the notification writes fail on purpose and show the original changes still succeed; TC-170 also lists the live CHECK constraints) |
| `notifications_rules_rehearsal.sql` | `notifications_rules.sql` plus TC-167 to TC-198 in ONE rolled-back transaction with one result row (TC-167R); its test part (from the `TESTS START HERE` line) is the same as `notifications_rules_test.sql` |
| `queue_hold.sql` | Queue hold (2026-10-14): a student can put their own Waiting ticket on hold and take it off again. New status `Held` and column `held_at` on `queue_tickets` (CHECKs `ck_queue_tickets_status`, `ck_queue_tickets_state`, new `ck_queue_tickets_held`; the one-active-ticket unique index now includes Held); helper `private.queue_hold_limit()` (15 minutes); new functions `queue_hold_my_ticket(text)` and `queue_unhold_my_ticket(text)`; `queue_my_status` gains `held_until`, `queue_staff_list` gains `held_at` (dropped and created again); `issue_queue_ticket`, `queue_finish` (a Held ticket can be marked No-show), `queue_cancel_my_ticket`, `queue_student_card` and the trigger function `private.require_queue_ticket_rules` replaced (new steps Waiting to Held, Held to Waiting, Cancelled or No-show). `queue_call_next` is unchanged: it only calls Waiting tickets, so held ones are skipped. Hold and unhold send no notifications. **Run live 2026-10-14** (rehearsal TC-199 to TC-217 passed 19 of 19). Do not re-run `queue_rules.sql` as it stands: its checks reject the new `held_at` column |
| `queue_hold_test.sql` | Tests TC-199 to TC-217 for `queue_hold.sql`, ONE rolled-back transaction with one result row (TC-207 switches off the ticket trigger as owner for two UPDATEs, so run it at a quiet time) |
| `queue_hold_rehearsal.sql` | `queue_hold.sql` plus TC-199 to TC-217 in ONE rolled-back transaction with one result row |
| `first_year_curriculum.sql` | Auto first-year enrollment (feature/auto-first-year): table `program_curriculum` (program, year 1..6, semester, subject; RLS, SELECT for authenticated only, owner writes only) with SAMPLE year-1 / 1st-semester subjects for BSCS, BSIT, BSBA (5 each, one section 'A' per new subject in the current term); `applications.applicant_type` ('New' / 'Transferee', default 'New'); `submit_application` gains an optional 6th parameter `p_applicant_type` (old 5-argument signature dropped, same EXECUTE grantees); new `create_first_year_enrollment(uuid) RETURNS bigint` (SECURITY DEFINER, server role only; idempotent; P0001 `unknown student:` / `no current term:` / `no curriculum:` / `no section:`). The app calls it only for a NEW applicant. Older tests that name `submit_application(text, text, text, text, bigint)` need the new signature. **NOT RUN YET** |
| `first_year_curriculum_test.sql` | Tests TC-234 to TC-247 for `first_year_curriculum.sql`, ONE rolled-back transaction with one result row (throwaway current term 2088-2089, applications under @firstyear.test) |
| `first_year_curriculum_rehearsal.sql` | `first_year_curriculum.sql` plus TC-234 to TC-247 in ONE rolled-back transaction with one result row (generated from the two files; run it before the live change) |
| `queue_hold_v2.sql` | Queue hold v2 and the Registrar's own subject drop (feature/hold-and-documents): `private.queue_hold_limit()` now 30 minutes; `ck_queue_tickets_state` lets a never-called No-show have no handler (an automatic close); trigger `private.require_queue_ticket_rules` (Held -> No-show only after the hold ran out for a signed-in caller, `handled_by` taken from the statement, NULL only for an expired hold); `queue_finish` refuses a held ticket's No-show while the hold runs (P0001 `hold active:`); new `queue_expire_holds() RETURNS integer` (SECURITY DEFINER, EXECUTE authenticated and the server role; closes every expired hold as No-show, SKIP LOCKED, idempotent; the app calls it, pg_cron optional); `private.notify_on_queue_tickets` adds kind `queue_hold_expired` ("Your hold ran out"); new policy `enrollment_items_registrar_delete` (DELETE for an active Registrar; the item trigger still requires Pending; audited with the Registrar as actor). Older files that now disagree are listed in its header (R1 to R5). **NOT RUN YET** |
| `queue_hold_v2_test.sql` | Tests TC-248 to TC-259 for `queue_hold_v2.sql`, ONE rolled-back transaction with one result row (throwaway services TCV-A .. TCV-E, throwaway term 2087-2088; switches the ticket trigger off as owner for single UPDATEs, so run it at a quiet time) |
| `queue_hold_v2_rehearsal.sql` | `queue_hold_v2.sql` plus TC-248 to TC-259 in ONE rolled-back transaction with one result row (generated from the two files; run it before the live change) |

`private_functions.sql` and the policies in `rls.sql` were exported from the live Supabase
project on 2026-10-10 (`pg_get_functiondef`, `pg_policies`); their SQL text is verbatim from the
export. `views.sql` is the state of the views after `views_extend.sql` ran on 2026-10-10:
`v_active_holds` is the original export, the other three are the extended definitions (same SQL,
not a fresh `pg_views` export, so the layout may differ slightly).

## Execution order

Run in the Supabase **SQL Editor** (or `psql`), in exactly this order:

1. **`schema.sql`**
2. **`views.sql`**
3. Create the 7 test accounts in Supabase Auth (see below)
4. **`seed.sql`**
5. **`private_functions.sql`**
6. **`rls.sql`**
7. **`hardening.sql`** (issue #50; run as a whole, then the tests in
   `docs/issue-12-testing-guide.md` Part C and Part F. Undo with its ROLLBACK section.)
8. **`hardening2.sql`**, one section at a time, in this order: **section A**, then
   **section B**, then **section C** (C needs B; save diagnostic (a) before C). Then the
   tests in Part G of `docs/issue-12-testing-guide.md` (TC-24 to TC-28) and Parts C and F
   again. Undo with each section's ROLLBACK block, in reverse order (C, B, A).
9. **`views_extend.sql`** (issue #49; after `hardening2.sql` section C, because its
   checks expect authenticated SELECT and no anon access on the views). Run as a whole;
   save its diagnostics (a) to (c) first. Then the tests in Part H of
   `docs/issue-12-testing-guide.md` (TC-29 to TC-33) and TC-15, TC-16, TC-28 again. Undo
   with its ROLLBACK block (DROP + CREATE, then the grants again).
10. **`grants_clearance.sql`** (issue #60; after `views_extend.sql`). **Run live on 2026-10-11** (rehearsed first, TC-34R to TC-39; live TC-34 passed). First
   rehearse it in a rolled-back transaction (TC-34R, see the top of
   `grants_clearance_test.sql`) and save its diagnostic (a). Then run it as a whole, WITHOUT
   toggling the tables in the dashboard's Data API settings (the file header explains why
   the GRANTs are enough). Then Part I of `docs/issue-12-testing-guide.md` (TC-34 to TC-40)
   and TC-12 to TC-33 again. Undo with its ROLLBACK block.
11. **`trigger_dept_approval.sql`** (issue #61, REQ-DPT-03; after `grants_clearance.sql`). **Run live on 2026-10-11** (rehearsed first; TC-41 to TC-48 pass live).
   First run `trigger_dept_approval_rehearsal.sql` (the change and TC-41 to TC-48 in one rolled-back
   transaction; every cell must end in `-> OK`, `all_ok` true) and save diagnostics (a) and (c) of
   `trigger_dept_approval.sql`. Then run the file as a whole, then Part J of
   `docs/issue-12-testing-guide.md` (TC-41 to TC-48, SQL in `trigger_dept_approval_test.sql`), TC-37 and
   `regression_after_grants.sql` again. Undo with its ROLLBACK block (drop trigger, drop function).
12. **`trigger_finance_autoclear.sql`** (issue #62, REQ-CSH-03; after `trigger_dept_approval.sql`). **Run live on 2026-10-11** (rehearsed first; TC-49 to TC-61 pass live).
   First run `trigger_finance_autoclear_rehearsal.sql` (the change and TC-49 to TC-61 in one rolled-back
   transaction; every cell must end in `-> OK`, `all_ok` true) and save diagnostics (a), (c) and (d) of
   `trigger_finance_autoclear.sql`. Then run the file as a whole, then Part K of
   `docs/issue-12-testing-guide.md` (TC-49 to TC-61: the blocks of `trigger_finance_autoclear_test.sql`, or the
   test part of the rehearsal file on its own), TC-37, Part J and `regression_after_grants.sql` again. Undo with its
   ROLLBACK block (drop both triggers, drop the function).
13. **`trigger_final_clearance.sql`** (issue #63, REQ-REG-03; after `trigger_finance_autoclear.sql`). **Run live on 2026-10-11** (rehearsed first; TC-62 to TC-70 pass live)
   (written without a local PostgreSQL, untested). First run `trigger_final_clearance_rehearsal.sql` (the change and
   TC-62 to TC-70 in one rolled-back transaction, TC-62R; every cell must end in `-> OK`, `all_ok` true) and save
   diagnostics (a), (c), (d) and (e) of `trigger_final_clearance.sql`. Then run the file as a whole, then Part L of
   `docs/issue-12-testing-guide.md` (TC-62 to TC-70: the blocks of `trigger_final_clearance_test.sql`, or the test part
   of the rehearsal file on its own), then TC-37 and TC-39 (`grants_clearance_test.sql`), Parts J and K and
   `regression_after_grants.sql` again (TC-18, TC-19, TC-37 and TC-39 were adjusted for the new rule; Part L explains
   how). Undo with its ROLLBACK block (drop the trigger, drop the function).
14. **`login_lockout.sql`** (issue #90, SEC-03; after `hardening2.sql` section C; independent of steps 9 to 13).
   **Run live 2026-10-12** (rehearsed first; TC-72 to TC-82 pass live). First run `login_lockout_rehearsal.sql` (the change and
   TC-72 to TC-82 in one rolled-back transaction, TC-72R; every cell must end in `-> OK`, `all_ok` true) and save
   diagnostics (a), (b) and (e) of `login_lockout.sql`. Then run the file as a whole, then
   `login_lockout_test.sql` (TC-72 to TC-82) and `regression_after_grants.sql` again. Deploy the app change that
   calls the two functions only AFTER the file is live. Undo with its ROLLBACK block (remove the app calls first;
   drops the five functions and the index; the revoked table privileges stay revoked).
15. **`grades_rules.sql`** (issue #92, REQ-REG-01; after `trigger_final_clearance.sql`). **Run live 2026-10-12** (rehearsed first; all tests pass live). First run
   `grades_rules_rehearsal.sql` (the change and TC-83 to TC-93 in one rolled-back transaction; every cell must
   end in `-> OK`, `all_ok` true) and save diagnostics (a), (b) and (d) of `grades_rules.sql` ((d) must return no
   rows). Then run the file as a whole, then `grades_rules_test.sql` (TC-83 to TC-93) and
   `regression_after_grants.sql` again (same results expected). Undo with its ROLLBACK block (drop both
   triggers and functions, back to `authenticated` SELECT only on `grades` and `v_grades`).
16. **`documents_rules.sql`** (issue #93, REQ-DOC-01 / REQ-DOC-02; after `trigger_final_clearance.sql`). **Run live 2026-10-12** (rehearsed first; all tests pass live).
   First run `documents_rules_rehearsal.sql` (the change and TC-95 to TC-108 in one rolled-back transaction, TC-95R;
   `all_ok` must be true, every cell ending in `-> OK`) and save diagnostics (a), (b) and (c) of `documents_rules.sql`
   (diagnostic (a) holds the sequence grants the ROLLBACK needs). Then run the file as a whole, then
   `documents_rules_test.sql` (TC-95 to TC-108) and `regression_after_grants.sql` again. Do not toggle
   `document_requests` in the dashboard's Data API settings; if anyone does, run the file again. Undo with its
   ROLLBACK block (drop the trigger and the function, `document_requests` back to authenticated SELECT only,
   sequence grants as in the saved diagnostic (a)).
17. **`enrollment_rules.sql`** (issue #94, REQ-STU-05 / REQ-REG-04; after `hardening2.sql` section C and `grants_clearance.sql`). **Run live 2026-10-12** (rehearsed first; all tests pass live, regression unchanged).
   First run `enrollment_rules_rehearsal.sql` (the change and TC-109 to TC-122 in one rolled-back transaction, TC-109R; every cell must end in `-> OK`, `all_ok` true; read the constraint list in the TC-109 cell) and save diagnostics (a), (b), (c), (d) and (e) of `enrollment_rules.sql`. Then run the file as a whole, then `enrollment_rules_test.sql` (TC-109 to TC-122) and `regression_after_grants.sql` (TC-12 to TC-33) again. Deploy the student and registrar enrollment screens (#101, #102) only AFTER the file is live. Undo with its ROLLBACK block (drops both triggers and functions, returns the two tables to authenticated SELECT only; drop the unique keys only if diagnostic (b) showed they did not exist before).
18. **`applications_rules.sql`** (enrollment site for new applicants; after `hardening2.sql` section C, `login_lockout.sql` and `enrollment_rules.sql`). **Run live 2026-10-12** (rehearsed first; TC-123 to TC-135 pass live).
   First run `applications_rules_rehearsal.sql` (the change and TC-123 to TC-135 in one rolled-back transaction, TC-123R; every cell must end in `-> OK`, `all_ok` true; read the constraint list in the TC-123 cell) and save diagnostics (a), (b), (c) and (e) of `applications_rules.sql`. Then run the file as a whole, then `applications_rules_test.sql` (TC-123 to TC-135; run it while nobody is provisioning, TC-133 moves and restores `student_number_seq`), `regression_after_grants.sql` and `login_lockout_test.sql` again (TC-81's expected anon function list now also contains `list_programs()` and `submit_application(text, text, text, text, bigint)`). Check diagnostic (f): the server role must be able to execute `next_student_number()`, update `applications.student_id` and insert into `profiles` / `students`. Deploy the public enrollment site, the Registrar applications screen and the server-side provisioning only AFTER the file is live. Undo with its ROLLBACK block (drops the table and every application, the functions and the sequence; remove the app calls first).
18b. **`applications_server_grants.sql`** (right after `applications_rules.sql`; needed before the Registrar can accept an application). **Run live 2026-10-12** (rehearsed first). Check: the result row has `roles_select`, `profiles_insert_delete`, `students_insert_delete` and `applications_link` all true. Undo: the ROLLBACK block in the file.
19. **`student_id_login.sql`** (after `applications_rules.sql`). **Run live 2026-10-12** (rehearsed first; TC-136 to TC-138 pass live). First `student_id_login_rehearsal.sql` (the change and TC-136 to TC-138, `all_ok` true), then the file, then `student_id_login_test.sql`, then `login_lockout_test.sql` and `applications_rules_test.sql` again (their expected anon function list now also contains `login_email_for_student_id(text)`). Deploy the login change only after the file is live (until then the login falls back to `<id>@students.pnc.test`, so seed students cannot use their ID). Undo: drop the function.
20. **`queue_rules.sql`** (virtual queue for the Registrar window; after `hardening2.sql` section C, `applications_rules.sql` and `student_id_login.sql`). **NOT RUN YET** (written without a local PostgreSQL).
   First run `queue_rules_rehearsal.sql` (the change and TC-139 to TC-166 in one rolled-back transaction, TC-139R; every cell must end in `-> OK`, `all_ok` true; read the constraint list in the TC-162 cell) and save diagnostics (a), (b) and (c) of `queue_rules.sql`. Then run the file as a whole, then `queue_rules_test.sql` (TC-139 to TC-166) and `regression_after_grants.sql` again (unchanged results expected; TC-27 still sees authenticated SELECT on every table). Deploy the QR / scanning page, the Registrar queue screen and the student queue page only AFTER the file is live. Undo with its ROLLBACK block (drops the three tables with every ticket, the seven functions and the helpers; remove the app calls first).
21. **`notifications_rules.sql`** (in-app notifications for every role; after `queue_rules.sql`, because it puts a trigger on `queue_tickets`, and after every earlier step). **NOT RUN YET** (written without a local PostgreSQL).
   First run `notifications_rules_rehearsal.sql` (the change and TC-167 to TC-198 in one rolled-back transaction, TC-167R; every cell must end in `-> OK`, `all_ok` true; read the constraint list in the TC-170 cell) and save diagnostics (a), (b) and (c) of `notifications_rules.sql`. Run it at a quiet time (TC-196 briefly locks `notifications`). Then run the file as a whole, then `notifications_rules_test.sql` (TC-167 to TC-198) and `regression_after_grants.sql` again (unchanged results expected). The new triggers change the full trigger lists that some older tests compare (`grades_rules_test.sql` TC-83, `documents_rules_test.sql` TC-95, `trigger_dept_approval_test.sql`, `trigger_finance_autoclear_test.sql`, `trigger_final_clearance_test.sql`; residual risk R7 in the header): update their expected lists before running them again, and do not re-run `queue_rules.sql` as it stands (its checks expect exactly two triggers on `queue_tickets`). Deploy the bell, the inbox page and the RPC calls only AFTER the file is live. Undo with its ROLLBACK block (drops the eight triggers, the table with every notification, the three functions and the helpers; remove the app calls first).

22. **`catalog_grants.sql`** (issue 39, REQ-ADM-04; after `hardening2.sql` section C and `enrollment_rules.sql`; independent of the other steps from 9 on). **RUN LIVE 2026-10-14.**
   First save diagnostics (a), (b) and (c) of the file ((c) must return no rows), then run `catalog_grants_rehearsal.sql` (the change and TC-218 to TC-225 in one rolled-back transaction; `all_ok` must be true). Then run the file from `BEGIN;` to `COMMIT;` as a whole, then its bottom block (TC-218 to TC-225, also rolled back) and `regression_after_grants.sql` again. Do not toggle the five tables in the dashboard's Data API settings; if anyone does, run the file again. Undo with its ROLLBACK block (anon's old INSERT / UPDATE / DELETE only if diagnostic (a) showed them).
23. **`admin_users.sql`** (issue 40, REQ-ADM-01; after `hardening2.sql` section C and `applications_server_grants.sql`; independent of `catalog_grants.sql`, either order). **RUN LIVE 2026-10-14.**
   First save diagnostics (a) and (b) of the file ((b) should list at least one active Admin; two is safer), then run `admin_users_rehearsal.sql` (the change and TC-226 to TC-233 in one rolled-back transaction; `all_ok` must be true). Then run the file from `BEGIN;` to `COMMIT;` as a whole, then its bottom block (TC-226 to TC-233, also rolled back) and `regression_after_grants.sql` again. Deploy the app's account actions (`lib/data/admin-users-actions.ts`) only AFTER the file is live. Undo with its ROLLBACK block (remove the app calls first).
24. **`queue_hold.sql`** (queue hold and unhold; after `queue_rules.sql` and `notifications_rules.sql`). **RUN LIVE 2026-10-14.**
   First run `queue_hold_rehearsal.sql` (the change and TC-199 to TC-217 in one rolled-back transaction; `all_ok` must be true), then the file from `BEGIN;` to `COMMIT;` as a whole. Undo with its ROLLBACK block (held tickets are set back to Waiting).
25. **`first_year_curriculum.sql`** (auto first-year enrollment; after `enrollment_rules.sql`, `applications_rules.sql`, `applications_server_grants.sql` and `catalog_grants.sql`). **NOT RUN YET.**
   First save diagnostics (a), (b) and (c) from the file's header, then run `first_year_curriculum_rehearsal.sql` (the change and TC-234 to TC-247 in one rolled-back transaction; `all_ok` must be true), then the file from `BEGIN;` to `COMMIT;` as a whole, then `first_year_curriculum_test.sql` and `regression_after_grants.sql`. Deploy the app change (applicant type on the form, the RPC call after provisioning) only AFTER the file is live. Undo with the ROLLBACK block in the file's header (remove the app calls first).
26. **`queue_hold_v2.sql`** (30-minute hold, automatic No-show of expired holds, its notification, the Registrar's own DELETE on `enrollment_items`; after `queue_hold.sql`, `notifications_rules.sql` and `enrollment_rules.sql`; independent of `first_year_curriculum.sql`). **NOT RUN YET.**
   First save diagnostics (a) to (d) from the file's header, then run `queue_hold_v2_rehearsal.sql` at a quiet time (the change and TC-248 to TC-259 in one rolled-back transaction; `all_ok` must be true), then the file from `BEGIN;` to `COMMIT;` as a whole, then `queue_hold_v2_test.sql` and `regression_after_grants.sql`. Do not run `queue_hold.sql`, `queue_hold_rehearsal.sql`, `notifications_rules.sql` or `enrollment_rules.sql` again as they stand afterwards (header R1 to R5; `queue_hold_test.sql` and `enrollment_rules_test.sql` TC-119 now report expected differences). Deploy the app change (`queue_expire_holds` calls, the `hold active:` message, 30-minute texts, the Registrar's drop with the user session) only AFTER the file is live. Undo with the ROLLBACK block in the file's header (remove the app calls first).

`triggers.sql` is a record of the triggers, **not** a step: do not run it (it stops itself
and rolls back if run by mistake).

`hardening2.sql` sections A, B and C were run on the live database on 2026-10-10, one at a time, and tested
(TC-24 to TC-28 and the regression TC-12 to TC-23 in `docs/issue-12-testing-guide.md`). The grants before
section C are saved in `grants_snapshot_2026-10-10.txt`. Tables exposed later in the Supabase Data API get
full default rights again, so repeat the anon part of section C afterwards.

`hardening.sql` was run on the live database on 2026-10-10 and tested (TC-18 to TC-23 and the
regression TC-12 to TC-17 in `docs/issue-12-testing-guide.md`). It is a change on top of the live
export: `rls.sql` and `private_functions.sql` still show the policies and function as exported
BEFORE it, so the live versions of `clearance_items_dept_update`, `holds_dept_lift`,
`clearances_registrar_approve` and `private.my_department_id()` are the ones in `hardening.sql`.

## Views (issue #49)

`types/database.types.ts` and `lib/mock-data.ts` expect more view columns than the live
views have. `views_extend.sql` adds them (option A: change the views, not the app):
`v_grades` gets the enrollment, term, section and subject columns; `v_clearance_items`
gets `student_id`, `term_id`, `department_name`, `department_type`; `v_clearances` gets
`total_items` and `cleared_items`. `v_active_holds` already matches. All new joins are
LEFT JOINs, so with `security_invoker` every role keeps exactly the rows it saw before.
For Cashier and Department, `total_items` / `cleared_items` count only their own
department's items (RLS on `clearance_items`).

`views_extend.sql` was run on the live database on 2026-10-10 and Part H (TC-29 to TC-33) passed.
`views.sql` now holds the extended definitions. To recreate the database from scratch, run
`schema.sql`, then `views.sql` (not `views_extend.sql`, which is the change script for a database that
still has the old thin views).

These files were run end to end against an in-memory PostgreSQL (with a stand-in for
`auth.users`/`auth.uid()`): the seed gives 3 students, charges of 45,000 with 20,000
collected, and 3/4, 2/4 and 3/4 offices cleared; with RLS on, each role sees only its
own rows (student: own rows only, Cashier and Department: their own office, Registrar and
Admin: everything).

## Known gaps (Backend team)

Views, `private` functions and policies now match the live database (export of
2026-10-10). These are still **not exported** and are therefore not in this folder:

- **Triggers.** `triggers.sql` records all of them, including `trg_clearances_create_items` on
  `clearances` (calls `private.create_clearance_items()`; its live definition is in section 1 of
  that file). To re-check the live state, list them with:
  `select event_object_table, trigger_name, action_timing, event_manipulation, action_statement from information_schema.triggers where trigger_schema = 'public';`
- **Grants.** No `GRANT` / `REVOKE` statements were exported (schema `private`, functions,
  tables, views). `private_functions.sql` keeps the old draft grants as a comment only;
  verify them against the live database. The grant state before `hardening2.sql` section C
  is in `grants_snapshot_2026-10-10.txt`; `hardening2.sql` section C and (once run)
  `grants_clearance.sql` are the written-down changes since. Grants on sequences other than
  `document_ticket_seq` (written down in `documents_rules.sql`) and the server role's grants are still
  not written down.
- **Tables created by later change files** are not in `schema.sql` / `rls.sql` (which still list the
  original 23): `applications` (in `applications_rules.sql`) and `queue_services`, `queue_tickets`,
  `queue_counters` (in `queue_rules.sql`, once run). Their columns, constraints, RLS and policies are
  defined in those files.
- **Audit triggers.** `hardening2.sql` section B (REQ-ADM-03) is live; `audit_logs` only holds
  changes made after 2026-10-10 (no back-fill).
- **Views vs types (issue #49): fixed** on 2026-10-10 with `views_extend.sql`; the live views have every
  column of `types/database.types.ts`. Open: `v_clearances.status` has no `Ready` value (the mock data does).

## Read before running

- **Create the 7 test accounts in Supabase Auth first.** `seed.sql` links its
  `profiles` rows to existing `auth.users` ids (`profiles.profile_id` ->
  `auth.users.id`). Create the users in the Supabase Dashboard
  (Authentication -> Users) *before* step 4, otherwise the seed will fail.
  Accounts are provisioned by the Admin through Supabase Auth, as stated in the
  SRS, section 2.2. Share test credentials with teammates privately, never in
  this repo.
- **`seed.sql` finds the accounts by e-mail**, so no UUIDs have to be edited. Names and
  student numbers match the Figma screens (`lib/mock-data.ts` is a separate UI-only dataset).
- **Do NOT run `seed.sql` again after `rls.sql`.** Once RLS is enabled the
  database is in its protected state; re-seeding can conflict with existing
  rows and policies. To reset, recreate the schema from step 1.
- **RLS must stay enabled on every table** (SRS SEC-02). Any new table added to
  `schema.sql` needs matching policies in `rls.sql`
  (Developer Onboarding: "Backend developers must enable RLS on each new table").

## Security rules for these files

These come from SRS SEC-05 / SEC-06 and the Developer Onboarding guide:

- No passwords, password hashes, JWTs, API keys, or connection strings.
- The Supabase `service_role` key must never appear in the repo. Only the anon
  key is used client-side, and `.env.local` is never committed.
- No real student data; the Data Privacy Act of 2012 applies (SRS ETH-01), so
  seed data must be fictional.
- Schema changes follow the normal Git flow: branch off `dev`, open a PR, and
  have a teammate review. Only the Project Manager merges `dev` into `main`.

### Pre-commit scrub

Run from the repo root before committing any `.sql` file; it must print nothing:

```bash
grep -rniE "service_role|eyJ[A-Za-z0-9_-]{10,}|sb_secret|postgres(ql)?://|password\s*(=|:)|encrypted_password" docs/database/ --include='*.sql'
```
