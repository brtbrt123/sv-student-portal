-- ==========================================
-- IN-APP NOTIFICATIONS FOR EVERY ROLE: DATABASE SIDE (feature/notifications)
-- ==========================================
-- Every signed-in person (Student, Registrar, Cashier, Department, Admin) gets an inbox: a
-- bell with an unread count in the top bar and a page that lists the notifications (app
-- code, written separately against the three functions below). Notifications are created
-- by the DATABASE, by AFTER triggers on the tables where things happen, so nothing in the
-- app has to remember to send one. In-app only: no email, no push, no Realtime.
-- Runs AFTER queue_rules.sql (it needs queue_tickets / queue_services), applications_rules.sql,
-- enrollment_rules.sql, documents_rules.sql, grades_rules.sql and the clearance trigger files
-- (keep README order).
--
-- WHAT IT DOES
--   1. Table public.notifications (RLS ON, NOT audited, decision 9):
--        notification_id bigint identity PK
--        recipient_id    uuid NOT NULL  FK profiles(profile_id) ON DELETE CASCADE (decision 10)
--        kind            text NOT NULL  CHECK '^[a-z][a-z_]{2,39}$' (a short code, not an enum:
--                                       a new kind needs no migration)
--        title           text NOT NULL  CHECK not blank after btrim, at most 120 characters
--        body            text NOT NULL DEFAULT ''  CHECK at most 400 characters
--        link            text NULL      CHECK NULL or an in-app path '^/[A-Za-z0-9/_?=&.#%-]*$'
--                                       of at most 200 characters
--        created_at      timestamptz NOT NULL DEFAULT now()
--        read_at         timestamptz NULL
--      Indexes: (recipient_id, created_at DESC) "my newest first", and (recipient_id)
--      WHERE read_at IS NULL "my unread".
--      Policy notifications_own_read: SELECT TO authenticated USING (recipient_id = (SELECT
--      private.active_uid())). Grants: authenticated SELECT only (regression TC-27 needs
--      table-level SELECT on every public table); no INSERT / UPDATE / DELETE / TRUNCATE /
--      REFERENCES / TRIGGER / MAINTAIN for anon or authenticated; anon nothing; the identity
--      sequence: nothing for anyone through the API. All writes happen in SECURITY DEFINER code.
--   2. BEFORE UPDATE trigger require_notification_rules on notifications (function
--      private.require_notification_rules(), SECURITY INVOKER, EVERY role, the owner too):
--      only read_at may change, only NULL -> a time, and the time is the database's now()
--      (any value the statement sends is replaced); a read notification is never made unread
--      (P0001); setting another time on an already read row keeps the first read time (no
--      error, so "mark read" twice is harmless); every other column is immutable (P0001
--      "bad notification change: ..."). No DELETE path for API users (no privilege); the owner
--      deletes in maintenance (m1), no DELETE trigger needed.
--   3. Three callable functions in schema public (SECURITY DEFINER, owner postgres,
--      search_path '', every name schema-qualified; EXECUTE for authenticated only, not
--      PUBLIC, not anon; each requires a signed-in ACTIVE account of ANY role through
--      private.active_uid(), else 42501 "not allowed: ..."):
--        list_my_notifications(p_limit integer DEFAULT 30, p_unread_only boolean DEFAULT false)
--          RETURNS TABLE(notification_id bigint, kind text, title text, body text, link text,
--                        created_at timestamptz, read_at timestamptz)
--          the caller's own rows, newest first (created_at DESC, notification_id DESC);
--          p_limit clamped to 1..100, NULL means 30; p_unread_only NULL means false.
--        notification_unread_count() RETURNS integer
--        mark_notifications_read(p_ids bigint[] DEFAULT NULL) RETURNS integer
--          marks the CALLER's own unread rows read (only the given ids, or all when p_ids is
--          NULL; an empty array marks nothing); returns how many changed; ids of other people
--          and ids already read are silently ignored (so a second call returns 0).
--   4. Internal helpers in schema private (SECURITY INVOKER: they run as the owner because
--      only the SECURITY DEFINER trigger functions call them; no EXECUTE for PUBLIC, anon,
--      authenticated):
--        private.notify(p_recipient uuid, p_kind text, p_title text, p_body text, p_link text)
--          RETURNS void: one row when the recipient is an ACTIVE profile. Control characters
--          become spaces; title trimmed and cut to 120, body trimmed and cut to 400; a link
--          that is not an in-app path (or longer than 200) is dropped (row written without a
--          link); an unknown kind format, a blank title, a NULL / unknown / inactive recipient
--          write nothing. NEVER raises: any error becomes RAISE WARNING, so a notification
--          problem can never block or roll back the action that caused it.
--        private.notify_role(p_role_name text, p_kind text, p_title text, p_body text,
--          p_link text) RETURNS void: private.notify for every ACTIVE profile of that role.
--        private.notify_office(p_department_id bigint, p_kind text, p_title text, p_body text,
--          p_head_link text, p_cashier_link text) RETURNS void: the department heads of that
--          department, plus the Cashiers when it is the Cashier's office (decision 3).
--        private.person_name(p_profile_id uuid) RETURNS text: 'Last, First' exactly as the
--          queue functions build it (NULL when there is no such profile).
--   5. Eight AFTER ROW triggers, one per table, each calling its own SECURITY DEFINER trigger
--      function private.notify_on_<table>() (search_path '', fully qualified). Each body is
--      wrapped in BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING ... END and returns NULL,
--      so it can NEVER fail or change the statement that fired it; each does nothing unless
--      the change is the relevant one (decision 5):
--        trg_notify_queue_tickets      AFTER INSERT OR UPDATE ON queue_tickets
--        trg_notify_enrollments        AFTER INSERT OR UPDATE ON enrollments
--        trg_notify_document_requests  AFTER INSERT OR UPDATE ON document_requests
--        trg_notify_clearance_items    AFTER INSERT OR UPDATE ON clearance_items
--        trg_notify_clearances         AFTER UPDATE ON clearances
--        trg_notify_academic_holds     AFTER INSERT OR UPDATE ON academic_holds
--        trg_notify_grades             AFTER INSERT OR UPDATE ON grades
--        trg_notify_applications       AFTER INSERT ON applications
--      Trigger functions: REVOKE EXECUTE FROM PUBLIC, anon; GRANT EXECUTE TO authenticated
--      (same grant style as every other trigger function, hardening2.sql section C).
--
-- THE NOTIFICATIONS (kind: recipient, title, body, link)
--   STUDENT
--   queue_ticket        the ticket holder, on a new Waiting ticket: "You are in line",
--                       "Your ticket is #1234567. N people are ahead of you." (N = Waiting
--                       tickets of that service and day with a lower ticket_number; 0 -> "No
--                       one is ahead of you.", 1 -> "1 person is ahead of you."),
--                       link /student/enrollment (service Enrollment) or /student/documents
--                       (service Documents), NULL for any other service (decision 6)
--   queue_turn          Waiting -> Serving: "It is your turn", "Go to <window_label, or 'the
--                       Registrar window' when empty> now. Bring your valid ID.", same link
--   queue_skipped       Serving -> No-show: "You were skipped", "Your number was called and
--                       you were not at the window. Show your code again to get a new
--                       number.", same link
--   enrollment_decided  Pending -> Approved / Rejected: "Your enrollment was approved" / "...
--                       was rejected"; body = the remarks when present, else "Open the
--                       enrollment page to see your subjects." (Approved) / "Open the
--                       enrollment page or ask the Registrar for the reason." (Rejected);
--                       link /student/enrollment
--   document_status     any status change: "Document request <ticket number>: <new status>";
--                       Processing "The Registrar started working on it.", Ready "It is
--                       ready. Claim it at the Registrar.", Released "It was released to
--                       you.", Rejected = the remarks, else "The Registrar could not process
--                       it."; link /student/documents
--   clearance_cleared   clearance_items.cleared_at NULL -> a time: "<office name> cleared you",
--                       body = the item's remarks or ''; link /student/clearance
--   clearance_note      remarks change to a non-blank value while the item is NOT cleared:
--                       "<office name> left a note", body = the remarks; /student/clearance
--   clearance_approved  clearances.approved_at NULL -> a time: "Your clearance is approved",
--                       "Every office cleared you and the Registrar gave the final
--                       approval."; /student/clearance
--   hold_placed         new hold (lifted_at NULL): "A hold was placed on your account",
--                       "<department name>: <reason>"; /student/clearance
--   hold_lifted         lifted_at NULL -> a time: "A hold was lifted", "<department name>:
--                       <reason>"; /student/clearance
--   grade_posted        new grade: "A new grade was posted", "<subject code>: <grade code>";
--                       /student/grades
--   grade_changed       grade_code changed: "A grade was updated", same body; /student/grades
--   REGISTRAR (every ACTIVE Registrar, private.notify_role)
--   application_submitted  new Pending application: "New application", "<First Last> applied
--                       for <program code>."; /registrar/applications
--   enrollment_submitted   new Pending enrollment: "New enrollment to review", "<Last, First>
--                       submitted an enrollment."; /registrar/enrollments
--   document_requested     new Pending request: "New document request", "<Last, First>
--                       requested <document type name>."; /registrar/documents
--   clearance_ready        an item becomes cleared, no item of that clearance is pending and
--                       the clearance is not approved: "A clearance is ready for final
--                       approval", "<Last, First>"; /registrar/clearance (once per clearance
--                       per transaction, decision 7)
--   DEPARTMENT / CASHIER (private.notify_office on the item's department)
--   clearance_waiting      new clearance item that is still pending after the INSERT
--                       triggers ran: "Clearance item waiting", "<Last, First> is waiting for
--                       your office."; /department/clearance for department heads,
--                       /cashier/clearance for Cashiers
--   ADMIN: no events yet. The table, the policy and the three functions already work for the
--   Admin (an empty inbox until a later change adds Admin events).
--   NOT INCLUDED ON PURPOSE (later): charges and payments, login events, any email / push.
--
-- HOW THE APP USES IT (the contract)
--   Top bar:   rpc('notification_unread_count')                         -> integer
--   Inbox:     rpc('list_my_notifications', { p_limit: 30, p_unread_only: false })
--   Read:      rpc('mark_notifications_read', { p_ids: [12, 13] })      -> how many changed
--              rpc('mark_notifications_read')  (all of mine)            -> how many changed
--   (from('notifications').select(...) also works: the policy shows only the caller's rows.)
--   Errors:    42501 "not allowed: ..."       not signed in, unknown or inactive account
--              42501 "permission denied ..."  anon (no EXECUTE), or any direct table write
--
-- DESIGN DECISIONS
--   1. Created by the database. AFTER ROW triggers on the source tables call private.notify;
--      the app only reads and marks read. A failed notification must never cost the user
--      their action: every trigger body and every helper catches everything and turns it
--      into RAISE WARNING (decision 5). The price: a broken notification is silent (R3).
--   2. Recipients are looked up when the event happens. Only ACTIVE profiles get rows (an
--      inactive account would never see them; re-activation does not back-fill).
--   3. Department heads and the Cashier (from schema.sql, seed.sql, hardening.sql):
--      profiles has NO department_id column (the brief assumed one). A department head is
--      an ACTIVE profile with role 'Department' that has a public.department_staff row for
--      the item's department (department_staff.profile_id is the primary key, so one
--      department each; the same lookup private.my_department_id() uses). The Cashier's
--      office is the department of type 'Financial' (seed: CSH "Cashier's Office"), and a
--      Cashier works on exactly the Financial department that private.my_department_id()
--      returns: the LOWEST department_id of type 'Financial' (hardening.sql 4). So
--      notify_office(d) also notifies every ACTIVE profile with role 'Cashier' when d is that
--      department. The seed also puts cashier@ in department_staff (CSH); department heads are
--      filtered to role 'Department', so a Cashier is never notified twice and gets the
--      /cashier/ link only. A second Financial department (none exists) would reach its
--      Department-role staff only, never the Cashiers (they cannot see its items either).
--   4. RLS and grants: the policy is the only way to read rows directly; the three functions
--      run as the owner and filter on the caller's own id. No write privilege for anyone
--      through the API (direct INSERT / UPDATE / DELETE fail with 42501 "permission denied").
--      Regression TC-27 still sees authenticated SELECT on every table.
--   5. Trigger shape. One trigger per table, named trg_notify_<table>, AFTER ... FOR EACH ROW,
--      RETURN NULL (AFTER: the row is already written, nothing can be changed). No column
--      list on UPDATE: earlier BEFORE triggers set columns themselves (processed_at,
--      reviewed_at, called_at ...), so the body compares OLD and NEW. Each body starts with
--      the cheap "is this the relevant change" test and returns at once otherwise. The trigger
--      functions only INSERT into notifications (through private.notify); notifications has no
--      INSERT trigger, so nothing can loop.
--      Firing order (AFTER triggers of the same event fire in name order, "C" collation;
--      safety check (e) stops if an existing AFTER trigger would sort after ours):
--        queue_tickets:     require_queue_ticket_rules (BEFORE) -> write -> audit_log
--                           -> trg_notify_queue_tickets
--        enrollments:       guard_immutable_columns, require_enrollment_rules (BEFORE) -> write
--                           -> audit_log -> trg_notify_enrollments
--        document_requests: guard_immutable_columns, require_document_status_flow (BEFORE)
--                           -> write -> audit_log -> trg_notify_document_requests
--        clearance_items:   UPDATE: guard_immutable_columns, require_no_active_hold (BEFORE)
--                           -> write -> audit_log -> trg_notify_clearance_items
--                           INSERT: write -> audit_log -> finance_autoclear_on_create (may
--                           clear the Financial item at once with a nested UPDATE, which fires
--                           trg_notify_clearance_items as an UPDATE: the student is told the
--                           Cashier's Office cleared them) -> trg_notify_clearance_items (re-reads
--                           the item and sends clearance_waiting only if it is still pending)
--        clearances:        UPDATE: guard_immutable_columns, require_all_items_cleared (BEFORE)
--                           -> write -> audit_log -> trg_notify_clearances
--        academic_holds:    guard_immutable_columns (BEFORE, UPDATE) -> write -> audit_log
--                           -> trg_notify_academic_holds
--        grades:            guard_immutable_columns, require_approved_enrollment,
--                           stamp_encoded_at (BEFORE) -> write -> audit_log -> trg_notify_grades
--        applications:      require_application_rules (BEFORE) -> write -> audit_log
--                           -> trg_notify_applications
--   6. Queue links: service_code 'Enrollment' -> /student/enrollment, 'Documents' ->
--      /student/documents, any other service (for example the tests' throwaway services) ->
--      no link. The label is '#' || ticket_code, the same as private.queue_label().
--   7. clearance_ready once: one UPDATE that clears several items of a clearance fires the
--      trigger once per item, and AFTER ROW triggers run when the whole statement is done, so
--      every call sees "nothing pending". The trigger therefore skips when the first active
--      Registrar (lowest profile_id) already has a clearance_ready row with the same body
--      ('Last, First') created in this transaction (created_at = now()); it uses the
--      (recipient_id, created_at) index.
--   8. INSERT events only for the normal start state: a new enrollment / document request /
--      application must be Pending, a new queue ticket Waiting, a new hold not lifted, a new
--      clearance item not cleared. Owner inserts of history rows (seeds) stay silent.
--   9. Not audited: notifications are derived, high-volume data; the source tables are
--      audited already. Do NOT attach private.audit_log to notifications.
--  10. recipient_id ... ON DELETE CASCADE (an addition to the brief): deleting a profile (the
--      server-side provisioning clean-up deletes a just-created profile on failure) would
--      otherwise fail on this FK. An inbox is derived data and goes with the profile.
--  11. Text is plain English for students and staff, no codes or database words. Names come
--      from profiles (students: 'Last, First'); applicants (no profile yet): 'First Last'.
--
-- RESIDUAL RISKS (not solved here)
--   R1 A missed notification is silent: errors only become server WARNINGs (decision 1).
--      Diagnostic (d) shows the latest rows per kind; compare with the source tables.
--   R2 Personal data: titles / bodies contain names, reasons and remarks. Readable only by
--      the recipient (policy) and the owner. See RETENTION.
--   R3 A Registrar-wide event writes one row per active Registrar; 200 junk applications per
--      hour (applications_rules.sql R1) write 200 x (number of Registrars) rows.
--   R4 Timing (applications_rules.sql R2): a real application now also writes the
--      Registrars' rows, so a real insert is a little slower than a skipped duplicate.
--   R5 Decision 7 merges two clearances of the SAME student that become ready in the SAME
--      transaction into one clearance_ready row (both show the same name anyway).
--   R6 The server role (server-side key) keeps Supabase's default rights on the new table and
--      bypasses RLS; the BEFORE UPDATE trigger still fires for it.
--   R7 OLDER FILES' CHECKS: the new trg_notify_* triggers change the trigger lists of eight
--      tables. Checks of earlier files that compare the FULL trigger list of such a table
--      will report a difference once this file is live: grades_rules_test.sql TC-83 (grades),
--      documents_rules_test.sql TC-95 (document_requests), trigger_dept_approval_test.sql
--      (clearance_items), trigger_finance_autoclear_test.sql (its clearance_items order
--      cell), trigger_final_clearance_test.sql (clearances), and queue_rules.sql itself if
--      it is ever run again (its safety check (c) refuses unknown triggers on queue_tickets
--      and its post-check (d) expects exactly 2). Their expected values need the new trigger
--      added before they are re-run. Not affected (they filter by function or look at
--      BEFORE triggers only): queue_rules_test.sql, applications_rules_test.sql,
--      enrollment_rules_test.sql, regression_after_grants.sql.
--   R8 window_label (staff-typed) is shown to the student in queue_turn (40 characters max,
--      no control characters, queue_rules.sql).
--
-- RETENTION (Data Privacy Act of 2012: keep only as long as needed)
--   Proposed (PM to confirm): delete read notifications 90 days after they were read and any
--   notification older than 12 months (maintenance m1). Nothing deletes automatically.
--
-- How to run: Supabase SQL editor, as postgres (the owner of the tables). Copy from "BEGIN;"
-- to "COMMIT;" inclusive into a new tab and run that tab as a whole (never a partial
-- selection). One transaction: any error, including a failed check, rolls back everything.
-- Re-runnable (IF NOT EXISTS, CREATE OR REPLACE, DROP ... IF EXISTS, grants rebuilt from
-- REVOKE ALL; a "WARNING: no privileges could be revoked" is harmless). Do not toggle the
-- new table in the dashboard's Data API settings; if anyone does, run this file again.
--   - Before running: run diagnostics (a), (b) and (c) at the bottom and SAVE the output;
--     READ (a): the live CHECK constraints on the tables the triggers read (the live
--     database has constraints that are not in schema.sql; safety check (g) also prints
--     them as NOTICEs).
--   - Rehearse first: docs/database/notifications_rules_rehearsal.sql runs this change and all
--     tests (TC-167 to TC-198) in ONE rolled-back transaction with one result row (TC-167R).
-- Test afterwards: docs/database/notifications_rules_test.sql (TC-167 to TC-198, the same as
-- the test part of the rehearsal), then docs/database/regression_after_grants.sql (unchanged
-- results expected; TC-27 still sees authenticated SELECT on every table). Then update the
-- trigger-list expectations named in R7 before those older tests are run again.
-- Deploy the bell, the inbox page and the RPC calls only AFTER the file is live.
-- Undo: the ROLLBACK block after COMMIT.
--
-- Status: NOT RUN YET (written 2026-10-13 without a local PostgreSQL; rehearse first).


BEGIN;

-- ------------------------------------------
-- 1. Safety checks (stop before changing anything)
-- ------------------------------------------
DO $$
DECLARE
  v_bad  text;
  v_list text;
  v_fin  bigint;
  v_n    bigint;
  r      record;
BEGIN
  IF current_setting('server_version_num')::int < 170000 THEN
    RAISE EXCEPTION 'notifications_rules: PostgreSQL 17+ expected (REVOKE ALL includes MAINTAIN); found %', current_setting('server_version');
  END IF;

  -- a) Tables, schema private, the helpers this file calls, auth.uid(), the five roles.
  SELECT string_agg(e.t, ', ') INTO v_bad
  FROM (VALUES ('profiles'), ('roles'), ('students'), ('programs'), ('departments'),
               ('department_staff'), ('subjects'), ('sections'), ('enrollments'),
               ('enrollment_items'), ('grades'), ('document_types'), ('document_requests'),
               ('clearances'), ('clearance_items'), ('academic_holds'), ('applications'),
               ('queue_services'), ('queue_tickets')) AS e(t)
  WHERE pg_catalog.to_regclass('public.' || e.t) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: missing table(s) public.%; run the earlier files first (README order); stop', v_bad;
  END IF;
  IF pg_catalog.to_regnamespace('private') IS NULL
     OR pg_catalog.to_regprocedure('private.active_uid()') IS NULL
     OR pg_catalog.to_regprocedure('private.current_role_name()') IS NULL
     OR pg_catalog.to_regprocedure('auth.uid()') IS NULL THEN
    RAISE EXCEPTION 'notifications_rules: schema private, private.active_uid(), private.current_role_name() or auth.uid() is missing; stop';
  END IF;
  SELECT string_agg(e.rn, ', ') INTO v_bad
  FROM (VALUES ('Student'), ('Registrar'), ('Cashier'), ('Department'), ('Admin')) AS e(rn)
  WHERE NOT EXISTS (SELECT 1 FROM public.roles r2 WHERE r2.role_name::text = e.rn);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: role(s) missing in public.roles: %; stop', v_bad;
  END IF;

  -- b) Columns used, with the expected types (format_type with a NULL typmod).
  SELECT string_agg(e.t || '.' || e.col || ' ' || e.typ, ', ') INTO v_bad
  FROM (VALUES
    ('profiles', 'profile_id', 'uuid'), ('profiles', 'role_id', 'smallint'),
    ('profiles', 'first_name', 'character varying'), ('profiles', 'last_name', 'character varying'),
    ('profiles', 'is_active', 'boolean'),
    ('roles', 'role_id', 'smallint'), ('roles', 'role_name', 'character varying'),
    ('department_staff', 'profile_id', 'uuid'), ('department_staff', 'department_id', 'bigint'),
    ('departments', 'department_id', 'bigint'), ('departments', 'name', 'character varying'),
    ('departments', 'department_type', 'character varying'),
    ('programs', 'program_id', 'bigint'), ('programs', 'code', 'character varying'),
    ('subjects', 'subject_id', 'bigint'), ('subjects', 'code', 'character varying'),
    ('sections', 'section_id', 'bigint'), ('sections', 'subject_id', 'bigint'),
    ('enrollments', 'enrollment_id', 'bigint'), ('enrollments', 'student_id', 'uuid'),
    ('enrollments', 'status', 'character varying'), ('enrollments', 'remarks', 'character varying'),
    ('enrollment_items', 'enrollment_item_id', 'bigint'), ('enrollment_items', 'enrollment_id', 'bigint'),
    ('enrollment_items', 'section_id', 'bigint'),
    ('grades', 'enrollment_item_id', 'bigint'), ('grades', 'grade_code', 'character varying'),
    ('document_types', 'document_type_id', 'bigint'), ('document_types', 'name', 'character varying'),
    ('document_requests', 'ticket_number', 'character varying'), ('document_requests', 'student_id', 'uuid'),
    ('document_requests', 'document_type_id', 'bigint'), ('document_requests', 'status', 'character varying'),
    ('document_requests', 'remarks', 'character varying'),
    ('clearances', 'clearance_id', 'bigint'), ('clearances', 'student_id', 'uuid'),
    ('clearances', 'approved_at', 'timestamp with time zone'),
    ('clearance_items', 'clearance_item_id', 'bigint'), ('clearance_items', 'clearance_id', 'bigint'),
    ('clearance_items', 'department_id', 'bigint'), ('clearance_items', 'cleared_at', 'timestamp with time zone'),
    ('clearance_items', 'remarks', 'character varying'),
    ('academic_holds', 'student_id', 'uuid'), ('academic_holds', 'department_id', 'bigint'),
    ('academic_holds', 'reason', 'character varying'), ('academic_holds', 'lifted_at', 'timestamp with time zone'),
    ('applications', 'first_name', 'character varying'), ('applications', 'last_name', 'character varying'),
    ('applications', 'program_id', 'bigint'), ('applications', 'status', 'character varying'),
    ('queue_services', 'service_id', 'bigint'), ('queue_services', 'service_code', 'text'),
    ('queue_tickets', 'service_id', 'bigint'), ('queue_tickets', 'student_id', 'uuid'),
    ('queue_tickets', 'queue_date', 'date'), ('queue_tickets', 'ticket_number', 'integer'),
    ('queue_tickets', 'ticket_code', 'integer'), ('queue_tickets', 'status', 'text'),
    ('queue_tickets', 'window_label', 'text')) AS e(t, col, typ)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = pg_catalog.to_regclass('public.' || e.t)
      AND a.attname = e.col AND a.attnum > 0 AND NOT a.attisdropped
      AND pg_catalog.format_type(a.atttypid, NULL) = e.typ);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: missing column or other type: %; stop', v_bad;
  END IF;

  -- c) Re-run: an existing notifications table must have exactly the contract's columns,
  --    no trigger but require_notification_rules, no policy but notifications_own_read.
  WITH expected(col, typ) AS (VALUES
    ('notification_id', 'bigint'), ('recipient_id', 'uuid'), ('kind', 'text'), ('title', 'text'),
    ('body', 'text'), ('link', 'text'), ('created_at', 'timestamp with time zone'),
    ('read_at', 'timestamp with time zone')),
  live AS (
    SELECT a.attname::text AS col, pg_catalog.format_type(a.atttypid, NULL) AS typ
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = pg_catalog.to_regclass('public.notifications')
      AND a.attnum > 0 AND NOT a.attisdropped),
  diff AS (
    (SELECT 'missing ' || e.col || ' ' || e.typ AS d
     FROM (SELECT * FROM expected EXCEPT SELECT * FROM live) e
     WHERE pg_catalog.to_regclass('public.notifications') IS NOT NULL)
    UNION ALL
    (SELECT 'unexpected ' || x.col || ' ' || x.typ FROM (SELECT * FROM live EXCEPT SELECT * FROM expected) x))
  SELECT string_agg(d, '; ') INTO v_bad FROM diff;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: public.notifications exists with other columns: %; stop and review', v_bad;
  END IF;
  SELECT string_agg(t.tgname::text, ', ') INTO v_bad
  FROM pg_catalog.pg_trigger t
  WHERE t.tgrelid = pg_catalog.to_regclass('public.notifications') AND NOT t.tgisinternal
    AND t.tgname <> 'require_notification_rules';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: unexpected trigger(s) on public.notifications: % (it must not be audited, decision 9); stop and review', v_bad;
  END IF;
  SELECT string_agg(p.policyname::text, ', ') INTO v_bad
  FROM pg_catalog.pg_policies p
  WHERE p.schemaname = 'public' AND p.tablename = 'notifications' AND p.policyname <> 'notifications_own_read';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: unexpected policy(ies) on public.notifications: %; stop and review', v_bad;
  END IF;

  -- d) No function with these names and another signature (an overload would make the
  --    PostgREST call ambiguous); triggers with this file's names call this file's functions.
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE ((p.pronamespace = 'public'::pg_catalog.regnamespace
          AND p.proname IN ('list_my_notifications', 'notification_unread_count', 'mark_notifications_read'))
      OR (p.pronamespace = 'private'::pg_catalog.regnamespace
          AND p.proname IN ('notify', 'notify_role', 'notify_office', 'person_name',
                            'require_notification_rules', 'notify_on_queue_tickets',
                            'notify_on_enrollments', 'notify_on_document_requests',
                            'notify_on_clearance_items', 'notify_on_clearances',
                            'notify_on_academic_holds', 'notify_on_grades', 'notify_on_applications')))
    AND p.oid NOT IN (SELECT s.o::oid FROM (VALUES
          (pg_catalog.to_regprocedure('public.list_my_notifications(integer, boolean)')),
          (pg_catalog.to_regprocedure('public.notification_unread_count()')),
          (pg_catalog.to_regprocedure('public.mark_notifications_read(bigint[])')),
          (pg_catalog.to_regprocedure('private.notify(uuid, text, text, text, text)')),
          (pg_catalog.to_regprocedure('private.notify_role(text, text, text, text, text)')),
          (pg_catalog.to_regprocedure('private.notify_office(bigint, text, text, text, text, text)')),
          (pg_catalog.to_regprocedure('private.person_name(uuid)')),
          (pg_catalog.to_regprocedure('private.require_notification_rules()')),
          (pg_catalog.to_regprocedure('private.notify_on_queue_tickets()')),
          (pg_catalog.to_regprocedure('private.notify_on_enrollments()')),
          (pg_catalog.to_regprocedure('private.notify_on_document_requests()')),
          (pg_catalog.to_regprocedure('private.notify_on_clearance_items()')),
          (pg_catalog.to_regprocedure('private.notify_on_clearances()')),
          (pg_catalog.to_regprocedure('private.notify_on_academic_holds()')),
          (pg_catalog.to_regprocedure('private.notify_on_grades()')),
          (pg_catalog.to_regprocedure('private.notify_on_applications()'))) AS s(o)
        WHERE o IS NOT NULL);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: function(s) with another signature already exist: %; stop and review', v_bad;
  END IF;
  SELECT string_agg(c.relname || '.' || t.tgname, ', ') INTO v_bad
  FROM pg_catalog.pg_trigger t
  JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
  WHERE NOT t.tgisinternal
    AND (t.tgname LIKE 'trg\_notify\_%' OR t.tgname = 'require_notification_rules')
    AND NOT EXISTS (
      SELECT 1 FROM (VALUES
        ('queue_tickets', 'trg_notify_queue_tickets', 'private.notify_on_queue_tickets()'),
        ('enrollments', 'trg_notify_enrollments', 'private.notify_on_enrollments()'),
        ('document_requests', 'trg_notify_document_requests', 'private.notify_on_document_requests()'),
        ('clearance_items', 'trg_notify_clearance_items', 'private.notify_on_clearance_items()'),
        ('clearances', 'trg_notify_clearances', 'private.notify_on_clearances()'),
        ('academic_holds', 'trg_notify_academic_holds', 'private.notify_on_academic_holds()'),
        ('grades', 'trg_notify_grades', 'private.notify_on_grades()'),
        ('applications', 'trg_notify_applications', 'private.notify_on_applications()'),
        ('notifications', 'require_notification_rules', 'private.require_notification_rules()')) AS e(tbl, tg, fn)
      WHERE c.relnamespace = 'public'::pg_catalog.regnamespace AND c.relname = e.tbl
        AND t.tgname = e.tg AND t.tgfoid = pg_catalog.to_regprocedure(e.fn));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: trigger(s) with this file''s names but another table or function: %; stop and review', v_bad;
  END IF;

  -- e) Firing order: on each of the eight tables, every other AFTER trigger must sort BEFORE
  --    trg_notify_<table> (same timing fires in name order, byte order), so the notification
  --    is the last thing that happens.
  SELECT string_agg(c.relname || '.' || t.tgname, ', ') INTO v_bad
  FROM pg_catalog.pg_trigger t
  JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
  WHERE c.relnamespace = 'public'::pg_catalog.regnamespace
    AND c.relname IN ('queue_tickets', 'enrollments', 'document_requests', 'clearance_items',
                      'clearances', 'academic_holds', 'grades', 'applications')
    AND NOT t.tgisinternal
    AND (t.tgtype::integer & 2) = 0
    AND t.tgname::text <> ('trg_notify_' || c.relname::text)
    AND (t.tgname::text COLLATE "C") > (('trg_notify_' || c.relname::text) COLLATE "C");
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: AFTER trigger(s) % would fire after the notification trigger; stop and review the names', v_bad;
  END IF;

  -- f) SECURITY DEFINER only sees every row if its owner (the role running this file)
  --    bypasses RLS on the tables it reads: owner without FORCE RLS, or BYPASSRLS.
  SELECT string_agg(c.relname, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  WHERE c.relnamespace = 'public'::pg_catalog.regnamespace
    AND c.relname IN ('profiles', 'roles', 'students', 'programs', 'departments', 'department_staff',
                      'subjects', 'sections', 'enrollments', 'enrollment_items', 'grades',
                      'document_types', 'document_requests', 'clearances', 'clearance_items',
                      'academic_holds', 'applications', 'queue_services', 'queue_tickets', 'notifications')
    AND c.relkind = 'r'
    AND NOT (SELECT r2.rolbypassrls FROM pg_catalog.pg_roles r2 WHERE r2.rolname = current_user)
    AND NOT (c.relowner = (SELECT r2.oid FROM pg_catalog.pg_roles r2 WHERE r2.rolname = current_user)
             AND NOT c.relforcerowsecurity);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: % would not bypass RLS on %; run as the table owner (postgres); stop', current_user, v_bad;
  END IF;

  -- g) The live database has CHECK constraints that are not in schema.sql. This file only
  --    READS the source tables (it writes only to notifications, whose CHECKs it defines),
  --    so they cannot reject a notification; they are printed here for the record (and in
  --    diagnostic (a) and TC-170). Read them: the tests write throwaway rows to these tables.
  v_list := '';
  FOR r IN
    SELECT c.conrelid::pg_catalog.regclass::text AS tbl, c.conname::text AS conname,
           pg_catalog.pg_get_constraintdef(c.oid) AS def
    FROM pg_catalog.pg_constraint c
    WHERE c.contype = 'c'
      AND c.conrelid IN (SELECT c2.oid FROM pg_catalog.pg_class c2
                         WHERE c2.relnamespace = 'public'::pg_catalog.regnamespace
                           AND c2.relname IN ('profiles', 'enrollments', 'document_requests', 'clearances',
                                              'clearance_items', 'academic_holds', 'grades', 'applications',
                                              'queue_tickets', 'notifications'))
    ORDER BY 1, 2
  LOOP
    v_list := v_list || r.tbl || '.' || r.conname || ' ' || r.def || '; ';
  END LOOP;
  RAISE NOTICE 'notifications_rules: live CHECK constraints on the tables involved: %', v_list;

  -- h) The Cashier's office and the department heads (decision 3), informational.
  SELECT d.department_id INTO v_fin FROM public.departments d
  WHERE d.department_type::text = 'Financial' ORDER BY d.department_id LIMIT 1;
  IF v_fin IS NULL THEN
    RAISE NOTICE 'notifications_rules: no department of type Financial; Cashiers will get no clearance_waiting rows';
  END IF;
  SELECT pg_catalog.count(*) INTO v_n
  FROM public.department_staff ds
  JOIN public.profiles p ON p.profile_id = ds.profile_id
  JOIN public.roles r2 ON r2.role_id = p.role_id
  WHERE r2.role_name::text = 'Department' AND p.is_active;
  RAISE NOTICE 'notifications_rules: Financial department id [%], active department heads [%]', v_fin, v_n;
END
$$;

-- ------------------------------------------
-- 2. The table, its constraints and indexes
-- ------------------------------------------
CREATE TABLE IF NOT EXISTS public.notifications (
  notification_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  recipient_id uuid NOT NULL,
  kind text NOT NULL,
  title text NOT NULL,
  body text NOT NULL DEFAULT ''::text,
  link text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  read_at timestamp with time zone,
  CONSTRAINT notifications_pkey PRIMARY KEY (notification_id),
  CONSTRAINT fk_notifications_recipient_id FOREIGN KEY (recipient_id) REFERENCES public.profiles(profile_id) ON DELETE CASCADE,
  CONSTRAINT ck_notifications_kind CHECK (kind ~ '^[a-z][a-z_]{2,39}$'),
  CONSTRAINT ck_notifications_title CHECK (btrim(title) <> '' AND length(title) <= 120),
  CONSTRAINT ck_notifications_body CHECK (length(body) <= 400),
  CONSTRAINT ck_notifications_link CHECK (link IS NULL OR (link ~ '^/[A-Za-z0-9/_?=&.#%-]*$' AND length(link) <= 200))
);

CREATE INDEX IF NOT EXISTS notifications_recipient_created_idx
  ON public.notifications (recipient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_unread_idx
  ON public.notifications (recipient_id) WHERE read_at IS NULL;

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------
-- 3. Internal helpers (schema private, SECURITY INVOKER, not callable by API users; the
--    SECURITY DEFINER trigger functions below call them as their owner)
-- ------------------------------------------

-- 'Last, First', built like the queue functions do.
CREATE OR REPLACE FUNCTION private.person_name(p_profile_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  SELECT p.last_name::text || ', ' || p.first_name::text
  FROM public.profiles p
  WHERE p.profile_id = p_profile_id
$function$;

-- One notification for one ACTIVE profile. Never raises (decision 1).
CREATE OR REPLACE FUNCTION private.notify(p_recipient uuid, p_kind text, p_title text, p_body text, p_link text)
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE
 SET search_path TO ''
AS $function$
DECLARE
  v_title text;
  v_body  text;
  v_link  text;
BEGIN
  IF p_recipient IS NULL THEN
    RETURN;
  END IF;
  IF p_kind IS NULL OR p_kind !~ '^[a-z][a-z_]{2,39}$' THEN
    RAISE WARNING 'private.notify: kind [%] is not a valid code; nothing written', pg_catalog.left(COALESCE(p_kind, 'NULL'), 40);
    RETURN;
  END IF;

  -- Control characters become spaces; trimmed; cut to the column limits (decision 11).
  v_title := pg_catalog.btrim(pg_catalog.left(pg_catalog.btrim(
               pg_catalog.regexp_replace(COALESCE(p_title, ''), '[[:cntrl:]]+', ' ', 'g')), 120));
  IF v_title = '' THEN
    RAISE WARNING 'private.notify: empty title for kind %; nothing written', p_kind;
    RETURN;
  END IF;
  v_body := pg_catalog.btrim(pg_catalog.left(pg_catalog.btrim(
              pg_catalog.regexp_replace(COALESCE(p_body, ''), '[[:cntrl:]]+', ' ', 'g')), 400));
  v_link := NULLIF(pg_catalog.btrim(COALESCE(p_link, '')), '');
  IF v_link IS NOT NULL
     AND (pg_catalog.length(v_link) > 200 OR v_link !~ '^/[A-Za-z0-9/_?=&.#%-]*$') THEN
    RAISE WARNING 'private.notify: link for kind % is not an in-app path; written without a link', p_kind;
    v_link := NULL;
  END IF;

  -- Only an existing, ACTIVE profile gets the row.
  INSERT INTO public.notifications (recipient_id, kind, title, body, link)
  SELECT p.profile_id, p_kind, v_title, v_body, v_link
  FROM public.profiles p
  WHERE p.profile_id = p_recipient AND p.is_active;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'private.notify: notification skipped (% %)', SQLSTATE, SQLERRM;
END
$function$;

-- private.notify for every ACTIVE profile of a role.
CREATE OR REPLACE FUNCTION private.notify_role(p_role_name text, p_kind text, p_title text, p_body text, p_link text)
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE
 SET search_path TO ''
AS $function$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.profile_id
    FROM public.profiles p
    JOIN public.roles ro ON ro.role_id = p.role_id
    WHERE ro.role_name::text = p_role_name AND p.is_active
    ORDER BY p.profile_id
  LOOP
    PERFORM private.notify(r.profile_id, p_kind, p_title, p_body, p_link);
  END LOOP;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'private.notify_role: notification skipped (% %)', SQLSTATE, SQLERRM;
END
$function$;

-- The office of a department (decision 3): its ACTIVE department heads (role Department,
-- department_staff row), plus every ACTIVE Cashier when it is the Cashier's office (the
-- lowest department_id of type Financial, as private.my_department_id()).
CREATE OR REPLACE FUNCTION private.notify_office(p_department_id bigint, p_kind text, p_title text, p_body text, p_head_link text, p_cashier_link text)
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE
 SET search_path TO ''
AS $function$
DECLARE
  r     record;
  v_fin bigint;
BEGIN
  IF p_department_id IS NULL THEN
    RETURN;
  END IF;

  FOR r IN
    SELECT DISTINCT p.profile_id
    FROM public.department_staff ds
    JOIN public.profiles p ON p.profile_id = ds.profile_id
    JOIN public.roles ro ON ro.role_id = p.role_id
    WHERE ds.department_id = p_department_id AND ro.role_name::text = 'Department' AND p.is_active
    ORDER BY p.profile_id
  LOOP
    PERFORM private.notify(r.profile_id, p_kind, p_title, p_body, p_head_link);
  END LOOP;

  SELECT d.department_id INTO v_fin
  FROM public.departments d
  WHERE d.department_type::text = 'Financial'
  ORDER BY d.department_id
  LIMIT 1;
  IF v_fin = p_department_id THEN
    PERFORM private.notify_role('Cashier', p_kind, p_title, p_body, p_cashier_link);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'private.notify_office: notification skipped (% %)', SQLSTATE, SQLERRM;
END
$function$;

REVOKE ALL ON FUNCTION private.person_name(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.notify(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.notify_role(text, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.notify_office(bigint, text, text, text, text, text) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------
-- 4. BEFORE UPDATE trigger on notifications (WHAT IT DOES 2)
-- ------------------------------------------
CREATE OR REPLACE FUNCTION private.require_notification_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $function$
BEGIN
  IF TG_OP <> 'UPDATE' OR TG_WHEN <> 'BEFORE' OR TG_LEVEL <> 'ROW'
     OR TG_TABLE_SCHEMA <> 'public' OR TG_TABLE_NAME <> 'notifications' THEN
    RAISE EXCEPTION 'private.require_notification_rules must be a BEFORE UPDATE FOR EACH ROW trigger on public.notifications';
  END IF;

  IF NEW.notification_id IS DISTINCT FROM OLD.notification_id
     OR NEW.recipient_id IS DISTINCT FROM OLD.recipient_id
     OR NEW.kind IS DISTINCT FROM OLD.kind
     OR NEW.title IS DISTINCT FROM OLD.title
     OR NEW.body IS DISTINCT FROM OLD.body
     OR NEW.link IS DISTINCT FROM OLD.link
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'bad notification change: only read_at of notification % can change', OLD.notification_id
      USING ERRCODE = 'P0001';
  END IF;

  IF OLD.read_at IS NOT NULL THEN
    IF NEW.read_at IS NULL THEN
      RAISE EXCEPTION 'bad notification change: notification % is read and cannot be marked unread', OLD.notification_id
        USING ERRCODE = 'P0001';
    END IF;
    NEW.read_at := OLD.read_at;           -- the first read time stays
  ELSIF NEW.read_at IS NOT NULL THEN
    NEW.read_at := pg_catalog.now();      -- the database's time, never the statement's
  END IF;

  RETURN NEW;
END
$function$;

-- Same grant style as the other trigger functions (hardening2.sql section C).
REVOKE EXECUTE ON FUNCTION private.require_notification_rules() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.require_notification_rules() TO authenticated;

DROP TRIGGER IF EXISTS require_notification_rules ON public.notifications;
CREATE TRIGGER require_notification_rules BEFORE UPDATE ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION private.require_notification_rules();

-- ------------------------------------------
-- 5. The event trigger functions (SECURITY DEFINER; never fail; decision 5)
-- ------------------------------------------

-- queue_tickets: queue_ticket, queue_turn, queue_skipped (decision 6).
CREATE OR REPLACE FUNCTION private.notify_on_queue_tickets()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_service text;
  v_link    text;
  v_label   text;
  v_ahead   integer;
  v_where   text;
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' THEN
      IF NEW.status IS DISTINCT FROM 'Waiting' THEN
        RETURN NULL;
      END IF;
    ELSIF TG_OP = 'UPDATE' THEN
      IF NOT ((OLD.status = 'Waiting' AND NEW.status = 'Serving')
              OR (OLD.status = 'Serving' AND NEW.status = 'No-show')) THEN
        RETURN NULL;
      END IF;
    ELSE
      RETURN NULL;
    END IF;

    SELECT s.service_code INTO v_service
    FROM public.queue_services s
    WHERE s.service_id = NEW.service_id;
    v_link := CASE v_service
                WHEN 'Enrollment' THEN '/student/enrollment'
                WHEN 'Documents' THEN '/student/documents'
              END;
    v_label := '#' || NEW.ticket_code::text;

    IF TG_OP = 'INSERT' THEN
      SELECT pg_catalog.count(*)::integer INTO v_ahead
      FROM public.queue_tickets w
      WHERE w.service_id = NEW.service_id AND w.queue_date = NEW.queue_date
        AND w.status = 'Waiting' AND w.ticket_number < NEW.ticket_number;
      PERFORM private.notify(NEW.student_id, 'queue_ticket', 'You are in line',
        'Your ticket is ' || v_label || '. '
          || CASE WHEN v_ahead = 0 THEN 'No one is ahead of you.'
                  WHEN v_ahead = 1 THEN '1 person is ahead of you.'
                  ELSE v_ahead::text || ' people are ahead of you.' END,
        v_link);
    ELSIF NEW.status = 'Serving' THEN
      v_where := COALESCE(NULLIF(pg_catalog.btrim(NEW.window_label), ''), 'the Registrar window');
      PERFORM private.notify(NEW.student_id, 'queue_turn', 'It is your turn',
        'Go to ' || v_where || ' now. Bring your valid ID.', v_link);
    ELSE
      PERFORM private.notify(NEW.student_id, 'queue_skipped', 'You were skipped',
        'Your number was called and you were not at the window. Show your code again to get a new number.',
        v_link);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_on_queue_tickets: notification skipped (% %)', SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END
$function$;

-- enrollments: enrollment_submitted (Registrars), enrollment_decided (the student).
CREATE OR REPLACE FUNCTION private.notify_on_enrollments()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_remarks text;
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' THEN
      IF NEW.status::text = 'Pending' THEN
        PERFORM private.notify_role('Registrar', 'enrollment_submitted', 'New enrollment to review',
          COALESCE(private.person_name(NEW.student_id), 'A student') || ' submitted an enrollment.',
          '/registrar/enrollments');
      END IF;
    ELSIF TG_OP = 'UPDATE' THEN
      IF OLD.status::text = 'Pending' AND NEW.status::text IN ('Approved', 'Rejected') THEN
        v_remarks := NULLIF(pg_catalog.btrim(COALESCE(NEW.remarks::text, '')), '');
        PERFORM private.notify(NEW.student_id, 'enrollment_decided',
          CASE NEW.status::text WHEN 'Approved' THEN 'Your enrollment was approved'
                                ELSE 'Your enrollment was rejected' END,
          COALESCE(v_remarks,
                   CASE NEW.status::text WHEN 'Approved' THEN 'Open the enrollment page to see your subjects.'
                                         ELSE 'Open the enrollment page or ask the Registrar for the reason.' END),
          '/student/enrollment');
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_on_enrollments: notification skipped (% %)', SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END
$function$;

-- document_requests: document_requested (Registrars), document_status (the student).
CREATE OR REPLACE FUNCTION private.notify_on_document_requests()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_type text;
  v_body text;
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' THEN
      IF NEW.status::text = 'Pending' THEN
        SELECT dt.name::text INTO v_type
        FROM public.document_types dt
        WHERE dt.document_type_id = NEW.document_type_id;
        PERFORM private.notify_role('Registrar', 'document_requested', 'New document request',
          COALESCE(private.person_name(NEW.student_id), 'A student') || ' requested '
            || COALESCE(v_type, 'a document') || '.',
          '/registrar/documents');
      END IF;
    ELSIF TG_OP = 'UPDATE' THEN
      IF NEW.status::text IS DISTINCT FROM OLD.status::text THEN
        v_body := CASE NEW.status::text
                    WHEN 'Processing' THEN 'The Registrar started working on it.'
                    WHEN 'Ready' THEN 'It is ready. Claim it at the Registrar.'
                    WHEN 'Released' THEN 'It was released to you.'
                    WHEN 'Rejected' THEN COALESCE(NULLIF(pg_catalog.btrim(COALESCE(NEW.remarks::text, '')), ''),
                                                  'The Registrar could not process it.')
                    ELSE ''
                  END;
        PERFORM private.notify(NEW.student_id, 'document_status',
          'Document request ' || NEW.ticket_number::text || ': ' || COALESCE(NEW.status::text, ''),
          v_body, '/student/documents');
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_on_document_requests: notification skipped (% %)', SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END
$function$;

-- clearance_items: clearance_waiting (office), clearance_cleared / clearance_note (the
-- student), clearance_ready (Registrars, once; decision 7).
CREATE OR REPLACE FUNCTION private.notify_on_clearance_items()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_student  uuid;
  v_office   text;
  v_name     text;
  v_cleared  timestamp with time zone;
  v_approved timestamp with time zone;
  v_reg      uuid;
  v_remarks  text;
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' THEN
      IF NEW.cleared_at IS NOT NULL THEN
        RETURN NULL;
      END IF;
      -- An earlier AFTER INSERT trigger (finance_autoclear_on_create) may have cleared it.
      SELECT i.cleared_at INTO v_cleared
      FROM public.clearance_items i
      WHERE i.clearance_item_id = NEW.clearance_item_id;
      IF v_cleared IS NOT NULL THEN
        RETURN NULL;
      END IF;
      SELECT c.student_id INTO v_student
      FROM public.clearances c
      WHERE c.clearance_id = NEW.clearance_id;
      PERFORM private.notify_office(NEW.department_id, 'clearance_waiting', 'Clearance item waiting',
        COALESCE(private.person_name(v_student), 'A student') || ' is waiting for your office.',
        '/department/clearance', '/cashier/clearance');
      RETURN NULL;
    END IF;

    IF TG_OP <> 'UPDATE' THEN
      RETURN NULL;
    END IF;

    v_remarks := NULLIF(pg_catalog.btrim(COALESCE(NEW.remarks::text, '')), '');

    IF OLD.cleared_at IS NULL AND NEW.cleared_at IS NOT NULL THEN
      SELECT c.student_id, c.approved_at INTO v_student, v_approved
      FROM public.clearances c
      WHERE c.clearance_id = NEW.clearance_id;
      SELECT d.name::text INTO v_office
      FROM public.departments d
      WHERE d.department_id = NEW.department_id;
      PERFORM private.notify(v_student, 'clearance_cleared',
        COALESCE(v_office, 'An office') || ' cleared you', COALESCE(v_remarks, ''), '/student/clearance');

      IF v_approved IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.clearance_items i
                         WHERE i.clearance_id = NEW.clearance_id AND i.cleared_at IS NULL) THEN
        v_name := pg_catalog.btrim(COALESCE(private.person_name(v_student), 'A student'));
        SELECT p.profile_id INTO v_reg
        FROM public.profiles p
        JOIN public.roles ro ON ro.role_id = p.role_id
        WHERE ro.role_name::text = 'Registrar' AND p.is_active
        ORDER BY p.profile_id
        LIMIT 1;
        IF v_reg IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM public.notifications n
                           WHERE n.recipient_id = v_reg AND n.created_at = pg_catalog.now()
                             AND n.kind = 'clearance_ready' AND n.body = v_name) THEN
          PERFORM private.notify_role('Registrar', 'clearance_ready',
            'A clearance is ready for final approval', v_name, '/registrar/clearance');
        END IF;
      END IF;
    ELSIF NEW.cleared_at IS NULL
          AND v_remarks IS NOT NULL
          AND NEW.remarks::text IS DISTINCT FROM OLD.remarks::text THEN
      SELECT c.student_id INTO v_student
      FROM public.clearances c
      WHERE c.clearance_id = NEW.clearance_id;
      SELECT d.name::text INTO v_office
      FROM public.departments d
      WHERE d.department_id = NEW.department_id;
      PERFORM private.notify(v_student, 'clearance_note',
        COALESCE(v_office, 'An office') || ' left a note', v_remarks, '/student/clearance');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_on_clearance_items: notification skipped (% %)', SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END
$function$;

-- clearances: clearance_approved (the student).
CREATE OR REPLACE FUNCTION private.notify_on_clearances()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  BEGIN
    IF TG_OP = 'UPDATE' AND OLD.approved_at IS NULL AND NEW.approved_at IS NOT NULL THEN
      PERFORM private.notify(NEW.student_id, 'clearance_approved', 'Your clearance is approved',
        'Every office cleared you and the Registrar gave the final approval.', '/student/clearance');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_on_clearances: notification skipped (% %)', SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END
$function$;

-- academic_holds: hold_placed, hold_lifted (the student).
CREATE OR REPLACE FUNCTION private.notify_on_academic_holds()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_dept text;
BEGIN
  BEGIN
    IF NOT ((TG_OP = 'INSERT' AND NEW.lifted_at IS NULL)
            OR (TG_OP = 'UPDATE' AND OLD.lifted_at IS NULL AND NEW.lifted_at IS NOT NULL)) THEN
      RETURN NULL;
    END IF;
    SELECT d.name::text INTO v_dept
    FROM public.departments d
    WHERE d.department_id = NEW.department_id;
    IF TG_OP = 'INSERT' THEN
      PERFORM private.notify(NEW.student_id, 'hold_placed', 'A hold was placed on your account',
        COALESCE(v_dept, 'An office') || ': ' || COALESCE(NEW.reason::text, ''), '/student/clearance');
    ELSE
      PERFORM private.notify(NEW.student_id, 'hold_lifted', 'A hold was lifted',
        COALESCE(v_dept, 'An office') || ': ' || COALESCE(NEW.reason::text, ''), '/student/clearance');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_on_academic_holds: notification skipped (% %)', SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END
$function$;

-- grades: grade_posted, grade_changed (the student).
CREATE OR REPLACE FUNCTION private.notify_on_grades()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_student uuid;
  v_subject text;
BEGIN
  BEGIN
    IF NOT (TG_OP = 'INSERT'
            OR (TG_OP = 'UPDATE' AND NEW.grade_code::text IS DISTINCT FROM OLD.grade_code::text)) THEN
      RETURN NULL;
    END IF;
    SELECT e.student_id, s.code::text INTO v_student, v_subject
    FROM public.enrollment_items ei
    JOIN public.enrollments e ON e.enrollment_id = ei.enrollment_id
    JOIN public.sections sec ON sec.section_id = ei.section_id
    JOIN public.subjects s ON s.subject_id = sec.subject_id
    WHERE ei.enrollment_item_id = NEW.enrollment_item_id;
    IF TG_OP = 'INSERT' THEN
      PERFORM private.notify(v_student, 'grade_posted', 'A new grade was posted',
        COALESCE(v_subject, 'A subject') || ': ' || COALESCE(NEW.grade_code::text, ''), '/student/grades');
    ELSE
      PERFORM private.notify(v_student, 'grade_changed', 'A grade was updated',
        COALESCE(v_subject, 'A subject') || ': ' || COALESCE(NEW.grade_code::text, ''), '/student/grades');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_on_grades: notification skipped (% %)', SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END
$function$;

-- applications: application_submitted (Registrars).
CREATE OR REPLACE FUNCTION private.notify_on_applications()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_program text;
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' AND NEW.status::text = 'Pending' THEN
      SELECT pr.code::text INTO v_program
      FROM public.programs pr
      WHERE pr.program_id = NEW.program_id;
      PERFORM private.notify_role('Registrar', 'application_submitted', 'New application',
        pg_catalog.btrim(COALESCE(NEW.first_name::text, '')) || ' ' || pg_catalog.btrim(COALESCE(NEW.last_name::text, ''))
          || ' applied for ' || COALESCE(v_program, 'a program') || '.',
        '/registrar/applications');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_on_applications: notification skipped (% %)', SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END
$function$;

-- Same grant style as the other trigger functions (hardening2.sql section C).
REVOKE EXECUTE ON FUNCTION private.notify_on_queue_tickets() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION private.notify_on_enrollments() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION private.notify_on_document_requests() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION private.notify_on_clearance_items() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION private.notify_on_clearances() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION private.notify_on_academic_holds() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION private.notify_on_grades() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION private.notify_on_applications() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.notify_on_queue_tickets() TO authenticated;
GRANT EXECUTE ON FUNCTION private.notify_on_enrollments() TO authenticated;
GRANT EXECUTE ON FUNCTION private.notify_on_document_requests() TO authenticated;
GRANT EXECUTE ON FUNCTION private.notify_on_clearance_items() TO authenticated;
GRANT EXECUTE ON FUNCTION private.notify_on_clearances() TO authenticated;
GRANT EXECUTE ON FUNCTION private.notify_on_academic_holds() TO authenticated;
GRANT EXECUTE ON FUNCTION private.notify_on_grades() TO authenticated;
GRANT EXECUTE ON FUNCTION private.notify_on_applications() TO authenticated;

-- ------------------------------------------
-- 6. The triggers (AFTER ROW, named to fire after every existing AFTER trigger)
-- ------------------------------------------
DROP TRIGGER IF EXISTS trg_notify_queue_tickets ON public.queue_tickets;
CREATE TRIGGER trg_notify_queue_tickets AFTER INSERT OR UPDATE ON public.queue_tickets
  FOR EACH ROW EXECUTE FUNCTION private.notify_on_queue_tickets();

DROP TRIGGER IF EXISTS trg_notify_enrollments ON public.enrollments;
CREATE TRIGGER trg_notify_enrollments AFTER INSERT OR UPDATE ON public.enrollments
  FOR EACH ROW EXECUTE FUNCTION private.notify_on_enrollments();

DROP TRIGGER IF EXISTS trg_notify_document_requests ON public.document_requests;
CREATE TRIGGER trg_notify_document_requests AFTER INSERT OR UPDATE ON public.document_requests
  FOR EACH ROW EXECUTE FUNCTION private.notify_on_document_requests();

DROP TRIGGER IF EXISTS trg_notify_clearance_items ON public.clearance_items;
CREATE TRIGGER trg_notify_clearance_items AFTER INSERT OR UPDATE ON public.clearance_items
  FOR EACH ROW EXECUTE FUNCTION private.notify_on_clearance_items();

DROP TRIGGER IF EXISTS trg_notify_clearances ON public.clearances;
CREATE TRIGGER trg_notify_clearances AFTER UPDATE ON public.clearances
  FOR EACH ROW EXECUTE FUNCTION private.notify_on_clearances();

DROP TRIGGER IF EXISTS trg_notify_academic_holds ON public.academic_holds;
CREATE TRIGGER trg_notify_academic_holds AFTER INSERT OR UPDATE ON public.academic_holds
  FOR EACH ROW EXECUTE FUNCTION private.notify_on_academic_holds();

DROP TRIGGER IF EXISTS trg_notify_grades ON public.grades;
CREATE TRIGGER trg_notify_grades AFTER INSERT OR UPDATE ON public.grades
  FOR EACH ROW EXECUTE FUNCTION private.notify_on_grades();

DROP TRIGGER IF EXISTS trg_notify_applications ON public.applications;
CREATE TRIGGER trg_notify_applications AFTER INSERT ON public.applications
  FOR EACH ROW EXECUTE FUNCTION private.notify_on_applications();

-- ------------------------------------------
-- 7. The callable functions (schema public, SECURITY DEFINER)
-- ------------------------------------------

-- The caller's own notifications, newest first. DROP first so a re-run can never keep an
-- older result shape (CREATE OR REPLACE cannot change it; the grants are given again below).
DROP FUNCTION IF EXISTS public.list_my_notifications(integer, boolean);
CREATE OR REPLACE FUNCTION public.list_my_notifications(p_limit integer DEFAULT 30, p_unread_only boolean DEFAULT false)
 RETURNS TABLE(notification_id bigint, kind text, title text, body text, link text, created_at timestamp with time zone, read_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
DECLARE
  v_uid   uuid;
  v_limit integer;
BEGIN
  v_uid := private.active_uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not allowed: only a signed-in, active account can read notifications'
      USING ERRCODE = '42501';
  END IF;
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100);

  RETURN QUERY
  SELECT n.notification_id, n.kind, n.title, n.body, n.link, n.created_at, n.read_at
  FROM public.notifications n
  WHERE n.recipient_id = v_uid
    AND (NOT COALESCE(p_unread_only, false) OR n.read_at IS NULL)
  ORDER BY n.created_at DESC, n.notification_id DESC
  LIMIT v_limit;
END
$function$;

-- The caller's unread count.
CREATE OR REPLACE FUNCTION public.notification_unread_count()
 RETURNS integer
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid;
  v_n   integer;
BEGIN
  v_uid := private.active_uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not allowed: only a signed-in, active account can read notifications'
      USING ERRCODE = '42501';
  END IF;

  SELECT pg_catalog.count(*)::integer INTO v_n
  FROM public.notifications n
  WHERE n.recipient_id = v_uid AND n.read_at IS NULL;
  RETURN v_n;
END
$function$;

-- Mark the caller's own unread notifications read (the given ids, or all when NULL).
CREATE OR REPLACE FUNCTION public.mark_notifications_read(p_ids bigint[] DEFAULT NULL)
 RETURNS integer
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid;
  v_n   integer;
BEGIN
  v_uid := private.active_uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not allowed: only a signed-in, active account can mark notifications'
      USING ERRCODE = '42501';
  END IF;

  -- read_at becomes now() (the BEFORE UPDATE trigger sets it).
  UPDATE public.notifications AS n
  SET read_at = pg_catalog.now()
  WHERE n.recipient_id = v_uid
    AND n.read_at IS NULL
    AND (p_ids IS NULL OR n.notification_id = ANY (p_ids));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$function$;

REVOKE ALL ON FUNCTION public.list_my_notifications(integer, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.notification_unread_count() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_notifications_read(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_notifications(integer, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.notification_unread_count() TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_notifications_read(bigint[]) TO authenticated;

-- ------------------------------------------
-- 8. Policy and grants (rebuilt from nothing; decision 4)
-- ------------------------------------------
DROP POLICY IF EXISTS notifications_own_read ON public.notifications;
CREATE POLICY notifications_own_read ON public.notifications
  FOR SELECT TO authenticated
  USING ((recipient_id = ( SELECT private.active_uid() AS active_uid)));

REVOKE ALL ON public.notifications FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.notifications TO authenticated;

DO $$
BEGIN
  EXECUTE pg_catalog.format('REVOKE ALL ON SEQUENCE %s FROM PUBLIC, anon, authenticated',
                            pg_catalog.pg_get_serial_sequence('public.notifications', 'notification_id'));
END
$$;

-- ------------------------------------------
-- 9. Checks after the change (any failure rolls back the whole file)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
BEGIN
  -- a) All functions exist.
  SELECT string_agg(e.sig, ', ') INTO v_bad
  FROM (VALUES ('public.list_my_notifications(integer, boolean)'), ('public.notification_unread_count()'),
               ('public.mark_notifications_read(bigint[])'),
               ('private.notify(uuid, text, text, text, text)'), ('private.notify_role(text, text, text, text, text)'),
               ('private.notify_office(bigint, text, text, text, text, text)'), ('private.person_name(uuid)'),
               ('private.require_notification_rules()'), ('private.notify_on_queue_tickets()'),
               ('private.notify_on_enrollments()'), ('private.notify_on_document_requests()'),
               ('private.notify_on_clearance_items()'), ('private.notify_on_clearances()'),
               ('private.notify_on_academic_holds()'), ('private.notify_on_grades()'),
               ('private.notify_on_applications()')) AS e(sig)
  WHERE pg_catalog.to_regprocedure(e.sig) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: function(s) not created: %; rolled back', v_bad;
  END IF;

  -- b) Public functions: SECURITY DEFINER, empty search_path, owned by the running role, no
  --    PUBLIC, anon cannot execute, authenticated can.
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE p.oid IN (pg_catalog.to_regprocedure('public.list_my_notifications(integer, boolean)'),
                  pg_catalog.to_regprocedure('public.notification_unread_count()'),
                  pg_catalog.to_regprocedure('public.mark_notifications_read(bigint[])'))
    AND NOT (p.prosecdef
             AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
             AND p.proowner = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
             AND p.proacl IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)
             AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
             AND pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: public function(s) not SECURITY DEFINER / empty search_path / owner / grants as intended: %; rolled back', v_bad;
  END IF;

  -- c) Helpers: SECURITY INVOKER, empty search_path, nobody but the owner can execute.
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE p.oid IN (pg_catalog.to_regprocedure('private.notify(uuid, text, text, text, text)'),
                  pg_catalog.to_regprocedure('private.notify_role(text, text, text, text, text)'),
                  pg_catalog.to_regprocedure('private.notify_office(bigint, text, text, text, text, text)'),
                  pg_catalog.to_regprocedure('private.person_name(uuid)'))
    AND NOT (NOT p.prosecdef
             AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
             AND p.proacl IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)
             AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
             AND NOT pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: helper(s) not locked down: %; rolled back', v_bad;
  END IF;

  -- d) Trigger functions: the eight event functions SECURITY DEFINER, require_notification_rules
  --    SECURITY INVOKER; empty search_path; no PUBLIC, no anon; authenticated can (house style).
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE p.oid IN (pg_catalog.to_regprocedure('private.require_notification_rules()'),
                  pg_catalog.to_regprocedure('private.notify_on_queue_tickets()'),
                  pg_catalog.to_regprocedure('private.notify_on_enrollments()'),
                  pg_catalog.to_regprocedure('private.notify_on_document_requests()'),
                  pg_catalog.to_regprocedure('private.notify_on_clearance_items()'),
                  pg_catalog.to_regprocedure('private.notify_on_clearances()'),
                  pg_catalog.to_regprocedure('private.notify_on_academic_holds()'),
                  pg_catalog.to_regprocedure('private.notify_on_grades()'),
                  pg_catalog.to_regprocedure('private.notify_on_applications()'))
    AND NOT ((p.prosecdef = (p.proname <> 'require_notification_rules'))
             AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
             AND p.proowner = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
             AND p.proacl IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)
             AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
             AND pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: trigger function(s) not as intended: %; rolled back', v_bad;
  END IF;

  -- e) Triggers: exactly these nine (tgtype: ROW 1, BEFORE 2, INSERT 4, UPDATE 16), enabled,
  --    calling this file's functions; on notifications nothing else.
  SELECT string_agg(e.tbl || '.' || e.tg, ', ') INTO v_bad
  FROM (VALUES
    ('queue_tickets', 'trg_notify_queue_tickets', 'private.notify_on_queue_tickets()', 21),
    ('enrollments', 'trg_notify_enrollments', 'private.notify_on_enrollments()', 21),
    ('document_requests', 'trg_notify_document_requests', 'private.notify_on_document_requests()', 21),
    ('clearance_items', 'trg_notify_clearance_items', 'private.notify_on_clearance_items()', 21),
    ('clearances', 'trg_notify_clearances', 'private.notify_on_clearances()', 17),
    ('academic_holds', 'trg_notify_academic_holds', 'private.notify_on_academic_holds()', 21),
    ('grades', 'trg_notify_grades', 'private.notify_on_grades()', 21),
    ('applications', 'trg_notify_applications', 'private.notify_on_applications()', 5),
    ('notifications', 'require_notification_rules', 'private.require_notification_rules()', 19)) AS e(tbl, tg, fn, typ)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger t
    WHERE t.tgrelid = pg_catalog.to_regclass('public.' || e.tbl) AND t.tgname = e.tg AND NOT t.tgisinternal
      AND t.tgfoid = pg_catalog.to_regprocedure(e.fn) AND t.tgtype::integer = e.typ AND t.tgenabled = 'O');
  IF v_bad IS NOT NULL
     OR (SELECT pg_catalog.count(*) FROM pg_catalog.pg_trigger t
          WHERE t.tgrelid = 'public.notifications'::pg_catalog.regclass AND NOT t.tgisinternal) <> 1 THEN
    RAISE EXCEPTION 'notifications_rules: triggers not as intended (missing or different: [%]); rolled back', v_bad;
  END IF;

  -- f) Still the last AFTER trigger on each table (safety check (e) again).
  SELECT string_agg(c.relname || '.' || t.tgname, ', ') INTO v_bad
  FROM pg_catalog.pg_trigger t
  JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
  WHERE c.relnamespace = 'public'::pg_catalog.regnamespace
    AND c.relname IN ('queue_tickets', 'enrollments', 'document_requests', 'clearance_items',
                      'clearances', 'academic_holds', 'grades', 'applications')
    AND NOT t.tgisinternal
    AND (t.tgtype::integer & 2) = 0
    AND (t.tgname::text COLLATE "C") > (('trg_notify_' || c.relname::text) COLLATE "C");
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'notifications_rules: AFTER trigger(s) % fire after the notification trigger; rolled back', v_bad;
  END IF;

  -- g) RLS on; exactly the one SELECT policy, for authenticated.
  SELECT string_agg(p.policyname || ' (' || p.cmd || ' ' || pg_catalog.array_to_string(p.roles, ',') || ')', ', ') INTO v_bad
  FROM pg_catalog.pg_policies p
  WHERE p.schemaname = 'public' AND p.tablename = 'notifications';
  IF v_bad IS DISTINCT FROM 'notifications_own_read (SELECT authenticated)'
     OR NOT (SELECT c.relrowsecurity FROM pg_catalog.pg_class c WHERE c.oid = 'public.notifications'::pg_catalog.regclass) THEN
    RAISE EXCEPTION 'notifications_rules: RLS or policies on public.notifications not as intended ([%]); rolled back', v_bad;
  END IF;

  -- h) Table privileges: anon nothing; authenticated SELECT only, no column grants; the
  --    identity sequence: nothing for anon / authenticated.
  IF pg_catalog.has_table_privilege('anon', 'public.notifications', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR pg_catalog.has_any_column_privilege('anon', 'public.notifications', 'SELECT, INSERT, UPDATE, REFERENCES')
     OR NOT pg_catalog.has_table_privilege('authenticated', 'public.notifications', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.notifications', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR pg_catalog.has_any_column_privilege('authenticated', 'public.notifications', 'INSERT, UPDATE, REFERENCES')
     OR EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = 'public.notifications'::pg_catalog.regclass
                   AND a.attnum > 0 AND NOT a.attisdropped AND a.attacl IS NOT NULL)
     OR pg_catalog.has_sequence_privilege('anon', pg_catalog.pg_get_serial_sequence('public.notifications', 'notification_id'), 'USAGE, SELECT, UPDATE')
     OR pg_catalog.has_sequence_privilege('authenticated', pg_catalog.pg_get_serial_sequence('public.notifications', 'notification_id'), 'USAGE, SELECT, UPDATE') THEN
    RAISE EXCEPTION 'notifications_rules: privileges on public.notifications or its sequence not as intended; rolled back';
  END IF;

  -- i) Constraints and indexes.
  IF (SELECT pg_catalog.count(*) FROM pg_catalog.pg_constraint k
       WHERE k.conrelid = 'public.notifications'::pg_catalog.regclass
         AND k.conname IN ('ck_notifications_kind', 'ck_notifications_title', 'ck_notifications_body',
                           'ck_notifications_link', 'fk_notifications_recipient_id', 'notifications_pkey')) <> 6
     OR pg_catalog.to_regclass('public.notifications_recipient_created_idx') IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                    WHERE i.indexrelid = pg_catalog.to_regclass('public.notifications_unread_idx')
                      AND i.indrelid = 'public.notifications'::pg_catalog.regclass AND i.indpred IS NOT NULL) THEN
    RAISE EXCEPTION 'notifications_rules: constraints or indexes of public.notifications not as intended; rolled back';
  END IF;
END
$$;

-- Ask PostgREST to reload its schema cache (sent when the transaction commits).
NOTIFY pgrst, 'reload schema';

COMMIT;


-- ------------------------------------------
-- ROLLBACK (back to the state before this file)
-- ------------------------------------------
-- DESTROYS every notification. Remove the bell, the inbox page and the RPC calls from the
-- app FIRST. Nothing else was changed by this file (no existing grant, policy, function or
-- trigger was touched; the eight triggers are new).
--
-- BEGIN;
--
-- DROP TRIGGER IF EXISTS trg_notify_queue_tickets ON public.queue_tickets;
-- DROP TRIGGER IF EXISTS trg_notify_enrollments ON public.enrollments;
-- DROP TRIGGER IF EXISTS trg_notify_document_requests ON public.document_requests;
-- DROP TRIGGER IF EXISTS trg_notify_clearance_items ON public.clearance_items;
-- DROP TRIGGER IF EXISTS trg_notify_clearances ON public.clearances;
-- DROP TRIGGER IF EXISTS trg_notify_academic_holds ON public.academic_holds;
-- DROP TRIGGER IF EXISTS trg_notify_grades ON public.grades;
-- DROP TRIGGER IF EXISTS trg_notify_applications ON public.applications;
-- DROP FUNCTION IF EXISTS public.list_my_notifications(integer, boolean);
-- DROP FUNCTION IF EXISTS public.notification_unread_count();
-- DROP FUNCTION IF EXISTS public.mark_notifications_read(bigint[]);
-- DROP TABLE IF EXISTS public.notifications;    -- drops its trigger, policy and indexes
-- DROP FUNCTION IF EXISTS private.notify_on_queue_tickets();
-- DROP FUNCTION IF EXISTS private.notify_on_enrollments();
-- DROP FUNCTION IF EXISTS private.notify_on_document_requests();
-- DROP FUNCTION IF EXISTS private.notify_on_clearance_items();
-- DROP FUNCTION IF EXISTS private.notify_on_clearances();
-- DROP FUNCTION IF EXISTS private.notify_on_academic_holds();
-- DROP FUNCTION IF EXISTS private.notify_on_grades();
-- DROP FUNCTION IF EXISTS private.notify_on_applications();
-- DROP FUNCTION IF EXISTS private.require_notification_rules();
-- DROP FUNCTION IF EXISTS private.notify_office(bigint, text, text, text, text, text);
-- DROP FUNCTION IF EXISTS private.notify_role(text, text, text, text, text);
-- DROP FUNCTION IF EXISTS private.notify(uuid, text, text, text, text);
-- DROP FUNCTION IF EXISTS private.person_name(uuid);
-- NOTIFY pgrst, 'reload schema';
--
-- COMMIT;


-- ==========================================
-- DIAGNOSTICS (read-only; run one at a time and send the output back)
-- ==========================================
-- Nothing here changes the database.
--
-- a) BEFORE and AFTER: every CHECK, UNIQUE, PRIMARY KEY and FOREIGN KEY constraint on the
--    tables this feature reads, plus notifications. READ IT: the live database has CHECK
--    constraints that are not in schema.sql.
-- select c.conrelid::regclass as table_name, c.conname, c.contype, pg_get_constraintdef(c.oid) as definition
-- from pg_constraint c
-- where c.conrelid in ('public.profiles'::regclass, 'public.enrollments'::regclass,
--                      'public.document_requests'::regclass, 'public.clearances'::regclass,
--                      'public.clearance_items'::regclass, 'public.academic_holds'::regclass,
--                      'public.grades'::regclass, 'public.applications'::regclass,
--                      'public.queue_tickets'::regclass)
--    or c.conrelid = to_regclass('public.notifications')
-- order by 1, 3, 2;
--
-- b) BEFORE and AFTER: functions with these names, their properties and grants.
-- select p.oid::regprocedure as function, pg_get_userbyid(p.proowner) as owner,
--        p.prosecdef as security_definer, p.proconfig, p.proacl::text as acl,
--        has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute
-- from pg_proc p
-- where p.proname in ('list_my_notifications', 'notification_unread_count', 'mark_notifications_read',
--                     'notify', 'notify_role', 'notify_office', 'person_name', 'require_notification_rules')
--    or p.proname like 'notify\_on\_%'
-- order by 1;
--
-- c) BEFORE and AFTER: every trigger on the eight source tables and on notifications, in
--    firing order (BEFORE first, then by name).
-- select t.tgrelid::regclass as table_name, t.tgname,
--        case when (t.tgtype::int & 2) = 2 then 'BEFORE' else 'AFTER' end as timing,
--        t.tgtype, t.tgenabled, t.tgfoid::regprocedure as function
-- from pg_trigger t
-- where t.tgrelid in ('public.queue_tickets'::regclass, 'public.enrollments'::regclass,
--                     'public.document_requests'::regclass, 'public.clearance_items'::regclass,
--                     'public.clearances'::regclass, 'public.academic_holds'::regclass,
--                     'public.grades'::regclass, 'public.applications'::regclass)
--    or t.tgrelid = to_regclass('public.notifications')
--   and not t.tgisinternal
-- order by 1, case when (t.tgtype::int & 2) = 2 then 0 else 1 end, t.tgname collate "C";
-- select c.relname, c.relacl::text as acl, c.relrowsecurity, c.relforcerowsecurity, pg_get_userbyid(c.relowner) as owner
-- from pg_class c where c.oid = to_regclass('public.notifications');
-- select tablename, policyname, cmd, roles, qual, with_check from pg_policies
-- where schemaname = 'public' and tablename = 'notifications';
--
-- d) AFTER: notifications per kind in the last 7 days (counts only, no personal data).
-- select n.kind, count(*) as total, count(*) filter (where n.read_at is null) as unread,
--        max(n.created_at) as latest
-- from public.notifications n
-- where n.created_at > now() - interval '7 days'
-- group by n.kind order by n.kind;
--
-- e) AFTER: table size and the oldest row (for the retention decision).
-- select count(*) as total, count(*) filter (where read_at is null) as unread,
--        min(created_at) as oldest, pg_size_pretty(pg_total_relation_size('public.notifications')) as size
-- from public.notifications;


-- ==========================================
-- MAINTENANCE (these WRITE; run only on purpose, as postgres)
-- ==========================================
-- m1) Retention (PM to confirm 90 days after reading / 12 months for everything). Not
--     audited (decision 9), so nothing else has to be cleaned.
-- DELETE FROM public.notifications
-- WHERE (read_at IS NOT NULL AND read_at < now() - interval '90 days')
--    OR created_at < now() - interval '12 months';
--
-- m2) Switch the notifications of one table off for a while (for example during a bulk
--     import), and back on. Every user's action keeps working either way.
-- ALTER TABLE public.grades DISABLE TRIGGER trg_notify_grades;
-- ALTER TABLE public.grades ENABLE TRIGGER trg_notify_grades;
