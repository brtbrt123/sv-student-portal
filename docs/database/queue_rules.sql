-- ==========================================
-- VIRTUAL QUEUE (TICKET NUMBERS) FOR THE REGISTRAR WINDOW: DATABASE SIDE (feature/queue-system)
-- ==========================================
-- After an applicant is accepted they go to the Registrar in person; many arrive at once.
-- The student shows a rotating QR code in the portal, a Registrar staff member scans it, sees
-- the student's card (queue_student_card) and the database issues a ticket. The student sees
-- their ticket code (#8124231), how many people are ahead and which ticket is being served;
-- the Registrar presses "Call next", then "Done" or "No-show". Built around queue_services so
-- the same queue serves document claims later.
-- This file is the DATABASE side only (the QR / scanning page is app code). Runs AFTER
-- hardening2.sql (A, B, C), applications_rules.sql and student_id_login.sql (independent of
-- them; keep README order).
--
-- WHAT IT DOES
--   1. Three new tables in schema public, RLS ON for all three:
--        queue_services (service_id identity PK, service_code text UNIQUE, service_name text,
--                        ticket_prefix text UNIQUE (one capital letter), is_open boolean)
--          seeded with ('Enrollment', 'Enrollment', 'E') and ('Documents', 'Document claim', 'D').
--          ticket_prefix is kept (unique, checked) but is NO LONGER used in labels (decision 2).
--        queue_tickets  (ticket_id identity PK, service_id FK, student_id FK students,
--                        queue_date date (Manila day),
--                        ticket_number integer > 0   INTERNAL order key, sequential per
--                                                    service per day; decides who is called next
--                        ticket_code integer         RANDOM 7-digit display code
--                                                    (1000000..9999999), shown as #8124231
--                        status Waiting | Serving | Done | No-show | Cancelled,
--                        window_label text NULL (trimmed, 1..40), handled_by FK profiles NULL,
--                        created_at, called_at, finished_at, checkin_photo_path text NULL)
--          UNIQUE (service_id, queue_date, ticket_number); UNIQUE (service_id, queue_date,
--          ticket_code); partial UNIQUE uq_queue_tickets_active_student (student_id,
--          service_id, queue_date) WHERE status IN ('Waiting', 'Serving') = one active ticket
--          per student per service per day. Audited (private.audit_log('ticket_id'),
--          hardening2.sql B).
--        queue_counters (service_id, queue_date) PK, last_number: the per-service, per-day
--          counter; no policy (nobody reads a row through the API), not audited.
--   2. Seven callable functions in schema public (SECURITY DEFINER, owner postgres,
--      search_path '', every name schema-qualified; EXECUTE for authenticated only, not
--      PUBLIC, not anon; each checks the caller's role itself, the caller must be ACTIVE):
--        issue_queue_ticket(p_student_id uuid, p_service text)
--          RETURNS TABLE(ticket_id bigint, ticket_label text, status text, queue_date date,
--                        people_ahead integer)                                     Registrar
--        queue_call_next(p_service text, p_window text DEFAULT NULL)
--          RETURNS TABLE(ticket_id bigint, ticket_label text, student_id uuid,
--                        student_number text, student_name text, window_label text,
--                        called_at timestamptz)                                     Registrar
--        queue_finish(p_ticket_id bigint, p_outcome text) RETURNS void            Registrar
--        queue_cancel_my_ticket(p_service text) RETURNS void                      Student
--        queue_my_status(p_service text)
--          RETURNS TABLE(is_open boolean, has_ticket boolean, ticket_label text,
--                        ticket_status text, people_ahead integer, now_serving text,
--                        waiting_total integer, avg_service_seconds integer,
--                        window_label text)                                         Student
--        queue_staff_list(p_service text)
--          RETURNS TABLE(ticket_id bigint, ticket_label text, ticket_number integer,
--                        status text, student_id uuid, student_number text,
--                        student_name text, window_label text, created_at timestamptz,
--                        called_at timestamptz, finished_at timestamptz)          Registrar
--        queue_student_card(p_student_id uuid)
--          RETURNS TABLE(student_id uuid, student_number text, student_name text,
--                        program_code text, program_name text,
--                        already_queued_label text)                                Registrar
--          >>> PHOTO PLACEHOLDER: a later anti-proxy feature will add the student's photo
--          >>> path to THIS function's result (and use queue_tickets.checkin_photo_path).
--          >>> No photo column or value exists or is returned now.
--   3. Internal helpers in schema private (SECURITY INVOKER, no EXECUTE for PUBLIC, anon,
--      authenticated): private.queue_today() (the Manila date), private.queue_label(integer)
--      ('#' || code), private.queue_random_code() (random 7-digit code, decision 1a),
--      private.queue_require_role(text) (42501 unless the caller is an active account of
--      that role; returns the caller's id), private.queue_service_row(text) (the service
--      row or 22023).
--   4. BEFORE UPDATE trigger require_queue_ticket_rules on queue_tickets (function
--      private.require_queue_ticket_rules(), SECURITY INVOKER): status flow, immutable
--      columns (ticket_code included), called_at / finished_at set by the database. Applies
--      to EVERY role.
--   5. Grants: anon nothing on the three tables, their identity sequences and the seven
--      functions. authenticated: SELECT on the three tables (rows limited by RLS; see
--      decision 9), no INSERT / UPDATE / DELETE / TRUNCATE / REFERENCES / TRIGGER / MAINTAIN
--      anywhere. All writes go through the functions.
--
-- HOW THE APP USES IT (the contract; p_service is the service_code, exact match:
-- 'Enrollment' or 'Documents')
--   Registrar scanning page:  rpc('queue_student_card', { p_student_id })  -> exactly 1 row:
--                               number, 'Last, First', program code / name, and
--                               already_queued_label (the active Enrollment ticket of today,
--                               else null); the Registrar checks the person, then
--                             rpc('issue_queue_ticket', { p_student_id, p_service })
--                             -> one row; show ticket_label (#8124231) and people_ahead.
--   Registrar queue screen:   rpc('queue_staff_list', { p_service })  today's tickets ordered
--                               by ticket_number (the internal order; also returned)
--                             rpc('queue_call_next', { p_service, p_window })  -> 0 or 1 row
--                               (0 rows = nobody waiting; not an error)
--                             rpc('queue_finish', { p_ticket_id, p_outcome: 'Done' | 'No-show' })
--   Student page:             rpc('queue_my_status', { p_service })  -> always exactly 1 row
--                             rpc('queue_cancel_my_ticket', { p_service })
--   queue_my_status details: has_ticket = the student has a ticket today in that service
--     (if several, the active one (Waiting / Serving) is preferred, else the latest);
--     people_ahead = Waiting tickets of the service today with a lower internal number when
--     the student's ticket is Waiting, 0 when it is Serving, NULL otherwise (no ticket, Done,
--     No-show, Cancelled); now_serving = the label being served (lowest internal number if
--     several windows), else the label called last today (ties: higher internal number),
--     else NULL; waiting_total = Waiting tickets today; avg_service_seconds = rounded average
--     of (finished_at - called_at) over the last 20 Done tickets today, NULL if none;
--     window_label = the window of the student's OWN ticket when it is Serving, else NULL.
--   Labels are '#' || ticket_code, e.g. #8124231 (always '#' + 7 digits).
--   Errors (PostgREST: code = SQLSTATE, message = text; the app recognises the prefix):
--     42501  "not allowed: ..."            wrong role, not signed in, or inactive account
--     42501  "permission denied ..."       anon (no EXECUTE), or a direct table write
--     22023  "invalid ticket request: ..." unknown service, target not an active Student
--                                          ("invalid ticket request: the person is not an
--                                          active student"), bad outcome, window too long
--     P0001  "queue closed: ..."           the service is not taking new tickets
--     P0001  "already queued: #8124231"    the student already has an active ticket today;
--                                          the label after the prefix is the existing one
--     P0001  "finish first: #8124231"      the caller is still serving that ticket
--     P0001  "queue busy: try again"       no free random code after 20 tries (practically
--                                          never: needs thousands of tickets in one day)
--     P0001  "bad ticket change: ..."      unknown ticket, wrong state, no waiting ticket,
--                                          any refused direct change (trigger)
--
-- DESIGN DECISIONS
--   1. Numbering per service per Manila day. queue_date = (now() AT TIME ZONE 'Asia/Manila')
--      ::date, computed in ONE place (private.queue_today(); the column DEFAULT repeats the
--      expression for owner inserts). The INTERNAL ticket_number comes from queue_counters
--      with one atomic INSERT ... ON CONFLICT ON CONSTRAINT queue_counters_pkey DO UPDATE
--      SET last_number = last_number + 1 RETURNING: the counter row is locked until the
--      transaction ends, so two scans at once never get the same number (the second waits
--      for the first). A new Manila day has no counter row yet, so it starts at 1. The
--      counter is transactional: a failed issue does not burn a number. The constraint name
--      (not the column list) is used in ON CONFLICT because the function's output column
--      queue_date would make the column list ambiguous in PL/pgSQL. ticket_number is never
--      shown to students (only queue_staff_list returns it, for ordering).
--  1a. Random display code (students must not guess the line sequence or trade tickets by
--      number): ticket_code = 1000000 + (n mod 9000000), n = the first 32 bits of
--      gen_random_uuid() (core PostgreSQL 13+, in pg_catalog, no extension; a version-4
--      UUID whose first 32 bits come from the server's strong random source,
--      pg_strong_random). random() is never used. The modulo bias is below 0.03 % and
--      irrelevant here. On a unique violation of uq_queue_tickets_code (same service, same
--      day) a new code is drawn, up to 20 tries, then P0001 "queue busy: try again" (the
--      whole issue rolls back, the counter included). Any other unique violation is raised
--      as is. The order of service never depends on the code.
--   2. Label = '#' || ticket_code (#8124231), built in the functions (private.queue_label),
--      not stored. ticket_prefix stays in queue_services (seeds E and D unchanged) for a
--      later display use, but labels no longer contain it.
--   3. One active ticket per student per service per day: partial unique index (decision
--      in the brief) plus a per-student, per-service transaction advisory lock in
--      issue_queue_ticket, so two Registrars scanning the same student at once get
--      "already queued:" instead of a unique-violation. A Waiting ticket left over from an
--      earlier day does not block a new one today (the index includes queue_date).
--   4. issue_queue_ticket checks in this order: caller (42501), service exists (22023),
--      target is an existing student whose profile is active with role Student (22023),
--      service open (P0001 "queue closed:"), already queued (P0001). A closed service only
--      stops NEW tickets; queue_call_next, queue_finish and cancelling still work so the
--      people already waiting are served. Opening / closing a service is an owner change
--      for now (maintenance m2); a Registrar toggle is a later decision.
--   5. queue_call_next: window label trimmed, empty -> NULL, more than 40 characters or a
--      control character -> 22023. A per-caller, per-service advisory lock stops a double
--      click from calling two people; if the caller already has a Serving ticket TODAY in
--      that service -> "finish first: <label>". The Waiting ticket of today with the lowest
--      INTERNAL ticket_number (= the earliest issued; never the lowest code) is taken with FOR UPDATE SKIP LOCKED, so two Registrar staff never take the same
--      ticket (the second takes the next one). Waiting tickets of earlier days are never
--      called (maintenance m1 closes them).
--   6. queue_finish: any active Registrar may finish any Serving ticket (a colleague can
--      cover a window); handled_by stays the Registrar who called it. Outcome must be
--      'Done' or 'No-show' (22023); unknown ticket or not Serving -> "bad ticket change:".
--   7. Status flow (trigger, EVERY role, also the owner and the server role):
--        Waiting -> Serving | Cancelled;  Serving -> Done | No-show
--      Done, No-show and Cancelled are final: no column of such a row changes any more.
--      ticket_id, student_id, service_id, queue_date, ticket_number, ticket_code and
--      created_at never change. called_at = now() when a ticket becomes Serving; finished_at = now() when it
--      becomes Done, No-show or Cancelled; any value the statement sends for them is
--      replaced. handled_by and window_label change only in the step Waiting -> Serving
--      (handled_by = auth.uid() when there is a user JWT; the owner without a JWT must give
--      it, the table CHECK requires it). INSERT is not checked by the trigger: only the
--      SECURITY DEFINER function and the owner can insert, and the CHECK
--      ck_queue_tickets_state keeps every row consistent (Waiting has no call / finish /
--      handler, Serving has called_at and handled_by, ...). Refused change: P0001
--      "bad ticket change: ...".
--   8. Privacy: the student functions never return another student's id, name or number.
--      queue_my_status returns only labels and counts (now_serving is a random code label
--      like #8124231, which identifies nobody) plus the window of the caller's OWN Serving
--      ticket. queue_student_card (Registrar only) returns one student's card; its
--      already_queued_label looks at the Enrollment service only (the scan screen's use).
--      The SELECT policy on queue_tickets shows a Student only their own rows (they see
--      handled_by, a staff id, and window_label of their own ticket); an active Registrar
--      sees all rows; Cashier, Department and Admin see none (decision 10).
--   9. Grants vs the regression: regression_after_grants.sql TC-27 (must keep passing
--      unchanged) expects authenticated to have table-level SELECT on EVERY table in schema
--      public. So authenticated gets SELECT on all three tables, also on queue_counters (no
--      policy there, so it reads 0 rows) and on the whole of queue_tickets including the
--      reserved checkin_photo_path column (rows still limited by queue_tickets_read). No
--      write privilege of any kind on any queue table, sequence or column for anyone but the
--      owner (and the server role's Supabase defaults; residual risk R4).
--  10. Admin: no read access to queue_tickets. The comparable Registrar-operated tables
--      (document_requests: docreq_read, applications: applications_registrar_read) do not
--      give Admin read either; add Admin to queue_tickets_read in a separate change if an
--      Admin dashboard needs it. queue_services is readable by every signed-in user.
--  11. checkin_photo_path is RESERVED for a later anti-proxy photo feature (the Registrar
--      compares a check-in photo with the student; the photo path will be returned by
--      queue_student_card, see the PHOTO PLACEHOLDER above). Nothing writes it now; no
--      function returns it; nobody has an INSERT / UPDATE privilege on it (decision 9 explains the
--      SELECT). The feature that uses it must add its own rules (who writes it, storage
--      bucket policy, retention of the photo).
--  12. Audit: AFTER INSERT OR UPDATE OR DELETE trigger audit_log on queue_tickets
--      (private.audit_log('ticket_id'), exactly as hardening2.sql section B attaches it).
--      Firing order on UPDATE: require_queue_ticket_rules (BEFORE) -> (RLS: the functions
--      run as the owner and bypass it; direct API writes have no privilege) -> CHECK /
--      unique -> write -> audit_log (AFTER). A refused change writes no audit row (the
--      BEFORE trigger or the constraint stops the statement first); the audit row shows the
--      database's called_at / finished_at. actor_id = the Registrar (issue, call, finish),
--      the student (cancel), NULL for the owner. queue_counters and queue_services are not
--      audited (a counter and a catalog, like login_attempts and the other catalogs).
--
-- RESIDUAL RISKS (not solved here)
--   R1 Proxy queuing: someone may show another student's QR code (screenshot or shared
--      phone). The QR rotates (app side) and the Registrar sees the name on
--      queue_staff_list; the reserved photo column is the planned fix.
--   R2 Stale tickets: tickets left Waiting / Serving at the end of a day stay so (they do
--      not block the next day, decision 3). Close them with maintenance m1 (daily, by hand
--      or later with pg_cron; a separate decision).
--   R3 Midnight: queue_date is the Manila date of the transaction start; a ticket issued at
--      23:59:59.9 belongs to that day. Not a problem during office hours.
--   R4 The server role (server-side key) keeps Supabase's default table rights on the new
--      tables and bypasses RLS; the status-flow trigger still fires for it, the role checks
--      in the functions refuse it (no user JWT -> "not allowed:").
--   R5 Issuance per service is serialised on the counter row (decision 1): at this school's
--      scale (a few scans per minute) the wait is milliseconds.
--   R6 Audit rows keep student ids and handled_by (append-only); follow the retention below.
--
-- RETENTION (Data Privacy Act of 2012: keep only as long as needed)
--   Proposed (PM to confirm): tickets are operational data; keep them 12 months (one school
--   year of statistics), then delete the tickets, their counters and their audit rows with
--   maintenance m3. Nothing deletes automatically.
--
-- How to run: Supabase SQL editor, as postgres (the owner of the tables). Copy from "BEGIN;"
-- to "COMMIT;" inclusive into a new tab and run that tab as a whole (never a partial
-- selection). One transaction: any error, including a failed check, rolls back everything.
-- Re-runnable (IF NOT EXISTS, CREATE OR REPLACE, DROP ... IF EXISTS, grants rebuilt from
-- REVOKE ALL; a "WARNING: no privileges could be revoked" is harmless). Do not toggle the
-- new tables in the dashboard's Data API settings (that would give anon and authenticated
-- full default rights again); if anyone does, run this file again.
--   - Before running: run diagnostics (a), (b) and (c) at the bottom and SAVE the output;
--     READ (a): the live CHECK constraints on audit_logs, profiles and students (the live
--     database has constraints that are not in schema.sql; safety check (g) tests the ones
--     on the audit_logs columns this feature writes with sample values).
--   - Rehearse first: docs/database/queue_rules_rehearsal.sql runs this change and all
--     tests (TC-139 to TC-166) in ONE rolled-back transaction with one result row (TC-139R).
-- Test afterwards: docs/database/queue_rules_test.sql (TC-139 to TC-166, the same as the test
-- part of the rehearsal), then docs/database/regression_after_grants.sql (unchanged results
-- expected; TC-27 still sees authenticated SELECT on every table, decision 9).
-- Deploy the QR / scanning page, the Registrar queue screen and the student queue page only
-- AFTER the file is live.
-- Undo: the ROLLBACK block after COMMIT.
--
-- Status: NOT RUN YET (written 2026-10-13 without a local PostgreSQL; rehearse first).


BEGIN;

-- ------------------------------------------
-- 1. Safety checks (stop before changing anything)
-- ------------------------------------------
DO $$
DECLARE
  v_bad    text;
  v_ok     boolean;
  v_expr   text;
  v_sample text;
  r        record;
  v_fn     regprocedure := pg_catalog.to_regprocedure('private.require_queue_ticket_rules()');
BEGIN
  IF current_setting('server_version_num')::int < 170000 THEN
    RAISE EXCEPTION 'queue_rules: PostgreSQL 17+ expected (REVOKE ALL includes MAINTAIN); found %', current_setting('server_version');
  END IF;

  -- a) Tables, schema private, the helpers this file calls, auth.uid(), the roles.
  SELECT string_agg(e.t, ', ') INTO v_bad
  FROM (VALUES ('profiles'), ('students'), ('roles'), ('audit_logs')) AS e(t)
  WHERE pg_catalog.to_regclass('public.' || e.t) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: missing table(s) public.%; stop', v_bad;
  END IF;
  IF pg_catalog.to_regnamespace('private') IS NULL
     OR pg_catalog.to_regprocedure('private.audit_log()') IS NULL
     OR pg_catalog.to_regprocedure('private.current_role_name()') IS NULL
     OR pg_catalog.to_regprocedure('private.active_uid()') IS NULL
     OR pg_catalog.to_regprocedure('auth.uid()') IS NULL THEN
    RAISE EXCEPTION 'queue_rules: schema private, private.audit_log(), private.current_role_name(), private.active_uid() or auth.uid() is missing; stop';
  END IF;
  -- The random code source (decision 1a): core gen_random_uuid(), no extension needed.
  IF pg_catalog.to_regprocedure('pg_catalog.gen_random_uuid()') IS NULL THEN
    RAISE EXCEPTION 'queue_rules: pg_catalog.gen_random_uuid() not found (PostgreSQL 13+ core function); stop';
  END IF;
  IF pg_catalog.to_regclass('public.programs') IS NULL THEN
    RAISE EXCEPTION 'queue_rules: missing table public.programs; stop';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.roles r2 WHERE r2.role_name = 'Registrar')
     OR NOT EXISTS (SELECT 1 FROM public.roles r2 WHERE r2.role_name = 'Student') THEN
    RAISE EXCEPTION 'queue_rules: roles Registrar / Student missing in public.roles; stop';
  END IF;

  -- b) Columns used, with the expected types (format_type with a NULL typmod).
  SELECT string_agg(e.t || '.' || e.col || ' ' || e.typ, ', ') INTO v_bad
  FROM (VALUES
    ('profiles', 'profile_id', 'uuid'),
    ('profiles', 'role_id', 'smallint'),
    ('profiles', 'first_name', 'character varying'),
    ('profiles', 'last_name', 'character varying'),
    ('profiles', 'is_active', 'boolean'),
    ('roles', 'role_id', 'smallint'),
    ('roles', 'role_name', 'character varying'),
    ('students', 'student_id', 'uuid'),
    ('students', 'student_number', 'character varying'),
    ('students', 'program_id', 'bigint'),
    ('programs', 'program_id', 'bigint'),
    ('programs', 'code', 'character varying'),
    ('programs', 'name', 'character varying'),
    ('audit_logs', 'table_name', 'character varying'),
    ('audit_logs', 'record_id', 'character varying'),
    ('audit_logs', 'action', 'character varying')) AS e(t, col, typ)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = pg_catalog.to_regclass('public.' || e.t)
      AND a.attname = e.col AND a.attnum > 0 AND NOT a.attisdropped
      AND pg_catalog.format_type(a.atttypid, NULL) = e.typ);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: missing column or other type: %; stop', v_bad;
  END IF;

  -- c) Re-run: tables that already exist must have exactly the contract's columns and types,
  --    and no trigger or policy other than this file's.
  WITH expected(t, col, typ) AS (VALUES
    ('queue_services', 'service_id', 'bigint'), ('queue_services', 'service_code', 'text'),
    ('queue_services', 'service_name', 'text'), ('queue_services', 'ticket_prefix', 'text'),
    ('queue_services', 'is_open', 'boolean'),
    ('queue_tickets', 'ticket_id', 'bigint'), ('queue_tickets', 'service_id', 'bigint'),
    ('queue_tickets', 'student_id', 'uuid'), ('queue_tickets', 'queue_date', 'date'),
    ('queue_tickets', 'ticket_number', 'integer'), ('queue_tickets', 'ticket_code', 'integer'),
    ('queue_tickets', 'status', 'text'),
    ('queue_tickets', 'window_label', 'text'), ('queue_tickets', 'handled_by', 'uuid'),
    ('queue_tickets', 'created_at', 'timestamp with time zone'),
    ('queue_tickets', 'called_at', 'timestamp with time zone'),
    ('queue_tickets', 'finished_at', 'timestamp with time zone'),
    ('queue_tickets', 'checkin_photo_path', 'text'),
    ('queue_counters', 'service_id', 'bigint'), ('queue_counters', 'queue_date', 'date'),
    ('queue_counters', 'last_number', 'integer')),
  live AS (
    SELECT c.relname::text AS t, a.attname::text AS col, pg_catalog.format_type(a.atttypid, NULL) AS typ
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
    WHERE c.relnamespace = 'public'::pg_catalog.regnamespace
      AND c.relname IN ('queue_services', 'queue_tickets', 'queue_counters')
      AND a.attnum > 0 AND NOT a.attisdropped),
  diff AS (
    (SELECT 'missing ' || e.t || '.' || e.col || ' ' || e.typ AS d
     FROM (SELECT * FROM expected EXCEPT SELECT * FROM live) e
     WHERE pg_catalog.to_regclass('public.' || e.t) IS NOT NULL)
    UNION ALL
    (SELECT 'unexpected ' || x.t || '.' || x.col || ' ' || x.typ FROM (SELECT * FROM live EXCEPT SELECT * FROM expected) x))
  SELECT string_agg(d, '; ') INTO v_bad FROM diff;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: queue table(s) exist with other columns: %; stop and review', v_bad;
  END IF;
  SELECT string_agg(c.relname || '.' || t.tgname, ', ') INTO v_bad
  FROM pg_catalog.pg_trigger t
  JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
  WHERE c.relnamespace = 'public'::pg_catalog.regnamespace
    AND c.relname IN ('queue_services', 'queue_tickets', 'queue_counters') AND NOT t.tgisinternal
    AND NOT (c.relname = 'queue_tickets' AND t.tgname IN ('require_queue_ticket_rules', 'audit_log'));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: unexpected trigger(s) on the queue tables: %; stop and review', v_bad;
  END IF;
  SELECT string_agg(p.tablename || '.' || p.policyname, ', ') INTO v_bad
  FROM pg_catalog.pg_policies p
  WHERE p.schemaname = 'public' AND p.tablename IN ('queue_services', 'queue_tickets', 'queue_counters')
    AND NOT ((p.tablename = 'queue_services' AND p.policyname = 'queue_services_read')
          OR (p.tablename = 'queue_tickets' AND p.policyname = 'queue_tickets_read'));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: unexpected policy(ies) on the queue tables: %; stop and review', v_bad;
  END IF;

  -- d) No function with these names and another signature (an overload would make the
  --    PostgREST call ambiguous); triggers with this file's names call this file's functions.
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE ((p.pronamespace = 'public'::pg_catalog.regnamespace
          AND p.proname IN ('issue_queue_ticket', 'queue_call_next', 'queue_finish',
                            'queue_cancel_my_ticket', 'queue_my_status', 'queue_staff_list',
                            'queue_student_card'))
      OR (p.pronamespace = 'private'::pg_catalog.regnamespace
          AND p.proname IN ('queue_today', 'queue_label', 'queue_random_code', 'queue_require_role',
                            'queue_service_row', 'require_queue_ticket_rules')))
    AND p.oid NOT IN (SELECT s.o::oid FROM (VALUES
          (pg_catalog.to_regprocedure('public.issue_queue_ticket(uuid, text)')),
          (pg_catalog.to_regprocedure('public.queue_call_next(text, text)')),
          (pg_catalog.to_regprocedure('public.queue_finish(bigint, text)')),
          (pg_catalog.to_regprocedure('public.queue_cancel_my_ticket(text)')),
          (pg_catalog.to_regprocedure('public.queue_my_status(text)')),
          (pg_catalog.to_regprocedure('public.queue_staff_list(text)')),
          (pg_catalog.to_regprocedure('public.queue_student_card(uuid)')),
          (pg_catalog.to_regprocedure('private.queue_today()')),
          (pg_catalog.to_regprocedure('private.queue_label(integer)')),
          (pg_catalog.to_regprocedure('private.queue_random_code()')),
          (pg_catalog.to_regprocedure('private.queue_require_role(text)')),
          (pg_catalog.to_regprocedure('private.queue_service_row(text)')),
          (pg_catalog.to_regprocedure('private.require_queue_ticket_rules()'))) AS s(o)
        WHERE o IS NOT NULL);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: function(s) with another signature already exist: %; stop and review', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
             WHERE t.tgname = 'require_queue_ticket_rules' AND NOT t.tgisinternal
               AND (v_fn IS NULL OR t.tgfoid <> v_fn)) THEN
    RAISE EXCEPTION 'queue_rules: a different trigger named require_queue_ticket_rules already exists; stop and review';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
             WHERE t.tgname = 'audit_log' AND NOT t.tgisinternal
               AND t.tgfoid <> 'private.audit_log()'::pg_catalog.regprocedure) THEN
    RAISE EXCEPTION 'queue_rules: a different trigger named audit_log already exists; stop and review';
  END IF;

  -- e) SECURITY DEFINER only sees every row if its owner (the role running this file)
  --    bypasses RLS on the tables it reads: owner without FORCE RLS, or BYPASSRLS.
  SELECT string_agg(c.relname, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  WHERE c.oid IN ('public.profiles'::pg_catalog.regclass, 'public.students'::pg_catalog.regclass,
                  'public.roles'::pg_catalog.regclass, 'public.programs'::pg_catalog.regclass)
    AND NOT (SELECT r2.rolbypassrls FROM pg_catalog.pg_roles r2 WHERE r2.rolname = current_user)
    AND NOT (c.relowner = (SELECT r2.oid FROM pg_catalog.pg_roles r2 WHERE r2.rolname = current_user)
             AND NOT c.relforcerowsecurity);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: % would not bypass RLS on %; run as the table owner (postgres); stop', current_user, v_bad;
  END IF;

  -- f) audit_logs without FORCE RLS (private.audit_log() inserts as its owner; hardening2.sql B).
  IF (SELECT c.relforcerowsecurity FROM pg_catalog.pg_class c
      WHERE c.oid = 'public.audit_logs'::pg_catalog.regclass) THEN
    RAISE EXCEPTION 'queue_rules: public.audit_logs has FORCE ROW LEVEL SECURITY; the audit trigger would fail; stop and review';
  END IF;

  -- g) The live database has CHECK constraints that are not in schema.sql. Every
  --    single-column CHECK on the audit_logs columns this feature writes (through the audit
  --    trigger) must accept what it will write there. Each one is evaluated against samples.
  FOR r IN
    SELECT c.conrelid::pg_catalog.regclass::text AS tbl, c.conname::text AS conname,
           pg_catalog.pg_get_constraintdef(c.oid) AS def, a.attname::text AS col
    FROM pg_catalog.pg_constraint c
    JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
    WHERE c.contype = 'c' AND pg_catalog.array_length(c.conkey, 1) = 1
      AND c.conrelid = 'public.audit_logs'::pg_catalog.regclass
      AND a.attname IN ('action', 'table_name', 'record_id')
  LOOP
    v_expr := pg_catalog.regexp_replace(r.def, '^CHECK \((.*)\)( NOT VALID)?$', '\1');
    FOREACH v_sample IN ARRAY CASE r.col
        WHEN 'action' THEN ARRAY['INSERT', 'UPDATE', 'DELETE']
        WHEN 'table_name' THEN ARRAY['queue_tickets']
        ELSE ARRAY['1', '123456789012']
      END
    LOOP
      EXECUTE pg_catalog.format('SELECT (%s) FROM (SELECT %L::character varying AS %I) AS x', v_expr, v_sample, r.col)
        INTO v_ok;
      IF v_ok IS FALSE THEN
        RAISE EXCEPTION 'queue_rules: live constraint %.% (%) rejects the sample value [%] that the audit trigger will write; stop and review (diagnostic (a))',
          r.tbl, r.conname, r.def, v_sample;
      END IF;
    END LOOP;
  END LOOP;
END
$$;

-- ------------------------------------------
-- 2. The tables, their constraints and indexes; the two services
-- ------------------------------------------
CREATE TABLE IF NOT EXISTS public.queue_services (
  service_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  service_code text NOT NULL,
  service_name text NOT NULL,
  ticket_prefix text NOT NULL,
  is_open boolean NOT NULL DEFAULT true,
  CONSTRAINT queue_services_pkey PRIMARY KEY (service_id),
  CONSTRAINT uq_queue_services_code UNIQUE (service_code),
  CONSTRAINT uq_queue_services_prefix UNIQUE (ticket_prefix),
  CONSTRAINT ck_queue_services_code CHECK (service_code ~ '^[A-Za-z][A-Za-z0-9_-]{0,39}$'),
  CONSTRAINT ck_queue_services_name CHECK (btrim(service_name) <> '' AND length(service_name) <= 100),
  CONSTRAINT ck_queue_services_prefix CHECK (ticket_prefix ~ '^[A-Z]$')
);

CREATE TABLE IF NOT EXISTS public.queue_tickets (
  ticket_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  service_id bigint NOT NULL,
  student_id uuid NOT NULL,
  queue_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Manila'::text))::date,
  ticket_number integer NOT NULL,
  ticket_code integer NOT NULL,
  status text NOT NULL DEFAULT 'Waiting'::text,
  window_label text,
  handled_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  called_at timestamp with time zone,
  finished_at timestamp with time zone,
  checkin_photo_path text,
  CONSTRAINT queue_tickets_pkey PRIMARY KEY (ticket_id),
  CONSTRAINT fk_queue_tickets_service_id FOREIGN KEY (service_id) REFERENCES public.queue_services(service_id),
  CONSTRAINT fk_queue_tickets_student_id FOREIGN KEY (student_id) REFERENCES public.students(student_id),
  CONSTRAINT fk_queue_tickets_handled_by FOREIGN KEY (handled_by) REFERENCES public.profiles(profile_id),
  CONSTRAINT uq_queue_tickets_number UNIQUE (service_id, queue_date, ticket_number),
  CONSTRAINT uq_queue_tickets_code UNIQUE (service_id, queue_date, ticket_code),
  CONSTRAINT ck_queue_tickets_number CHECK (ticket_number > 0),
  CONSTRAINT ck_queue_tickets_code CHECK (ticket_code BETWEEN 1000000 AND 9999999),
  CONSTRAINT ck_queue_tickets_status CHECK (status = ANY (ARRAY['Waiting'::text, 'Serving'::text, 'Done'::text, 'No-show'::text, 'Cancelled'::text])),
  CONSTRAINT ck_queue_tickets_window CHECK (window_label IS NULL OR (window_label = btrim(window_label) AND window_label <> '' AND length(window_label) <= 40)),
  CONSTRAINT ck_queue_tickets_state CHECK (
    (status = 'Waiting' AND called_at IS NULL AND finished_at IS NULL AND handled_by IS NULL)
    OR (status = 'Serving' AND called_at IS NOT NULL AND finished_at IS NULL AND handled_by IS NOT NULL)
    OR (status IN ('Done', 'No-show') AND called_at IS NOT NULL AND finished_at IS NOT NULL AND handled_by IS NOT NULL)
    OR (status = 'Cancelled' AND called_at IS NULL AND finished_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS public.queue_counters (
  service_id bigint NOT NULL,
  queue_date date NOT NULL,
  last_number integer NOT NULL,
  CONSTRAINT queue_counters_pkey PRIMARY KEY (service_id, queue_date),
  CONSTRAINT fk_queue_counters_service_id FOREIGN KEY (service_id) REFERENCES public.queue_services(service_id),
  CONSTRAINT ck_queue_counters_last_number CHECK (last_number >= 0)
);

-- One active ticket per student per service per day (decision 3).
CREATE UNIQUE INDEX IF NOT EXISTS uq_queue_tickets_active_student
  ON public.queue_tickets (student_id, service_id, queue_date) WHERE status IN ('Waiting', 'Serving');
-- "Today's tickets of a service ordered by number" is uq_queue_tickets_number's index
-- (service_id, queue_date, ticket_number). The two below serve call_next and the student.
CREATE INDEX IF NOT EXISTS queue_tickets_waiting_idx
  ON public.queue_tickets (service_id, queue_date, ticket_number) WHERE status = 'Waiting';
CREATE INDEX IF NOT EXISTS queue_tickets_student_idx
  ON public.queue_tickets (student_id, queue_date);

ALTER TABLE public.queue_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.queue_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.queue_counters ENABLE ROW LEVEL SECURITY;

-- The two services (a re-run keeps whatever is there, including is_open).
INSERT INTO public.queue_services (service_code, service_name, ticket_prefix)
VALUES ('Enrollment', 'Enrollment', 'E'), ('Documents', 'Document claim', 'D')
ON CONFLICT (service_code) DO NOTHING;

-- ------------------------------------------
-- 3. Internal helpers (schema private, SECURITY INVOKER, not callable by API users; the
--    SECURITY DEFINER functions below call them as their owner)
-- ------------------------------------------

-- The queue day: today's date in Asia/Manila (decision 1), in ONE place.
CREATE OR REPLACE FUNCTION private.queue_today()
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  SELECT (pg_catalog.now() AT TIME ZONE 'Asia/Manila')::date
$function$;

-- The label shown to people (decision 2): '#' || the random code, e.g. #8124231.
CREATE OR REPLACE FUNCTION private.queue_label(p_code integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT '#' || p_code::text
$function$;

-- A random 7-digit code (decision 1a): the first 32 bits (8 hex digits) of a version-4 UUID
-- from the core gen_random_uuid() (strong random source), mapped onto 1000000..9999999.
-- Never random().
CREATE OR REPLACE FUNCTION private.queue_random_code()
 RETURNS integer
 LANGUAGE sql
 VOLATILE
 SET search_path TO ''
AS $function$
  SELECT (1000000 + (('x' || pg_catalog.left(pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', ''), 8))::bit(32)::bigint
                     % 9000000))::integer
$function$;

-- The caller must be a signed-in, ACTIVE account of the given role; returns its id.
CREATE OR REPLACE FUNCTION private.queue_require_role(p_role text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := private.active_uid();
  v_role text := private.current_role_name();
BEGIN
  IF v_uid IS NULL OR v_role IS DISTINCT FROM p_role THEN
    RAISE EXCEPTION 'not allowed: only a signed-in, active % account can do this', p_role
      USING ERRCODE = '42501';
  END IF;
  RETURN v_uid;
END
$function$;

-- The service row for a service_code, or 22023.
CREATE OR REPLACE FUNCTION private.queue_service_row(p_service text)
 RETURNS public.queue_services
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v public.queue_services;
BEGIN
  SELECT s.* INTO v FROM public.queue_services s WHERE s.service_code = p_service;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid ticket request: unknown service [%]', COALESCE(pg_catalog.left(p_service, 40), 'NULL')
      USING ERRCODE = '22023';
  END IF;
  RETURN v;
END
$function$;

REVOKE ALL ON FUNCTION private.queue_today() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.queue_label(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.queue_random_code() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.queue_require_role(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.queue_service_row(text) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------
-- 4. Trigger function and triggers on queue_tickets (decisions 7 and 12)
-- ------------------------------------------
CREATE OR REPLACE FUNCTION private.require_queue_ticket_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_old  text;
  v_new  text;
  v_step text;
BEGIN
  IF TG_OP <> 'UPDATE' OR TG_WHEN <> 'BEFORE' OR TG_LEVEL <> 'ROW'
     OR TG_TABLE_SCHEMA <> 'public' OR TG_TABLE_NAME <> 'queue_tickets' THEN
    RAISE EXCEPTION 'private.require_queue_ticket_rules must be a BEFORE UPDATE FOR EACH ROW trigger on public.queue_tickets';
  END IF;

  v_old := OLD.status;
  v_new := NEW.status;

  -- What the ticket is never changes.
  IF NEW.ticket_id IS DISTINCT FROM OLD.ticket_id
     OR NEW.student_id IS DISTINCT FROM OLD.student_id
     OR NEW.service_id IS DISTINCT FROM OLD.service_id
     OR NEW.queue_date IS DISTINCT FROM OLD.queue_date
     OR NEW.ticket_number IS DISTINCT FROM OLD.ticket_number
     OR NEW.ticket_code IS DISTINCT FROM OLD.ticket_code
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'bad ticket change: the student, service, date, number, code and creation time of ticket % cannot be changed', OLD.ticket_id
      USING ERRCODE = 'P0001';
  END IF;

  -- Final states: nothing changes any more.
  IF v_old IN ('Done', 'No-show', 'Cancelled') THEN
    IF pg_catalog.to_jsonb(NEW) IS DISTINCT FROM pg_catalog.to_jsonb(OLD) THEN
      RAISE EXCEPTION 'bad ticket change: ticket % is % (final) and cannot be changed', OLD.ticket_id, v_old
        USING ERRCODE = 'P0001',
              HINT = 'Done, No-show and Cancelled are final. The student gets a new ticket instead.';
    END IF;
    RETURN NEW;
  END IF;

  -- One step of the flow.
  IF v_new IS DISTINCT FROM v_old THEN
    v_step := COALESCE(v_old, 'NULL') || ' -> ' || COALESCE(v_new, 'NULL');
    IF v_step NOT IN ('Waiting -> Serving', 'Waiting -> Cancelled', 'Serving -> Done', 'Serving -> No-show') THEN
      RAISE EXCEPTION 'bad ticket change: % is not allowed (ticket %)', v_step, OLD.ticket_id
        USING ERRCODE = 'P0001',
              HINT = 'Allowed: Waiting -> Serving or Cancelled; Serving -> Done or No-show.';
    END IF;
  END IF;

  IF v_old = 'Waiting' AND v_new = 'Serving' THEN
    -- The call: who calls it and at which window; the time is the database's.
    IF v_uid IS NOT NULL THEN
      NEW.handled_by := v_uid;
    END IF;
    NEW.window_label := NULLIF(pg_catalog.btrim(NEW.window_label), '');
    NEW.called_at := pg_catalog.now();
    NEW.finished_at := NULL;
  ELSE
    IF NEW.handled_by IS DISTINCT FROM OLD.handled_by
       OR NEW.window_label IS DISTINCT FROM OLD.window_label THEN
      RAISE EXCEPTION 'bad ticket change: handled_by and window_label of ticket % are set only when it is called', OLD.ticket_id
        USING ERRCODE = 'P0001';
    END IF;
    NEW.called_at := OLD.called_at;
    IF v_new IS DISTINCT FROM v_old THEN
      NEW.finished_at := pg_catalog.now();   -- Done, No-show or Cancelled
    ELSE
      NEW.finished_at := OLD.finished_at;
    END IF;
  END IF;

  RETURN NEW;
END
$function$;

-- Same grant style as the other trigger functions (hardening2.sql section C).
REVOKE EXECUTE ON FUNCTION private.require_queue_ticket_rules() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.require_queue_ticket_rules() TO authenticated;

DROP TRIGGER IF EXISTS require_queue_ticket_rules ON public.queue_tickets;
CREATE TRIGGER require_queue_ticket_rules BEFORE UPDATE ON public.queue_tickets
  FOR EACH ROW EXECUTE FUNCTION private.require_queue_ticket_rules();

-- Audit, exactly as hardening2.sql section B (argument = the single-column primary key).
DROP TRIGGER IF EXISTS audit_log ON public.queue_tickets;
CREATE TRIGGER audit_log AFTER INSERT OR UPDATE OR DELETE ON public.queue_tickets
  FOR EACH ROW EXECUTE FUNCTION private.audit_log('ticket_id');

-- ------------------------------------------
-- 5. The callable functions (schema public, SECURITY DEFINER)
-- ------------------------------------------

-- Registrar: issue a ticket for a student (decisions 1 to 4).
-- DROP first: an earlier draft of this file had another result shape, and CREATE OR REPLACE
-- cannot change a result type (the grants are given again below).
DROP FUNCTION IF EXISTS public.issue_queue_ticket(uuid, text);
CREATE OR REPLACE FUNCTION public.issue_queue_ticket(p_student_id uuid, p_service text)
 RETURNS TABLE(ticket_id bigint, ticket_label text, status text, queue_date date, people_ahead integer)
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
DECLARE
  v_svc    public.queue_services;
  v_today  date;
  v_number integer;
  v_code   integer;
  v_id     bigint;
  v_con    text;
  i        integer;
BEGIN
  PERFORM private.queue_require_role('Registrar');
  v_svc := private.queue_service_row(p_service);

  IF p_student_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.students s
       JOIN public.profiles p ON p.profile_id = s.student_id
       JOIN public.roles r ON r.role_id = p.role_id
       WHERE s.student_id = p_student_id AND p.is_active AND r.role_name = 'Student') THEN
    RAISE EXCEPTION 'invalid ticket request: the person is not an active student'
      USING ERRCODE = '22023';
  END IF;

  IF NOT v_svc.is_open THEN
    RAISE EXCEPTION 'queue closed: % is not taking new tickets now', v_svc.service_name
      USING ERRCODE = 'P0001';
  END IF;

  v_today := private.queue_today();

  -- One issue per student and service at a time (decision 3).
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'queue_tickets:' || v_svc.service_id::text || ':' || p_student_id::text, 0));

  SELECT t.ticket_code INTO v_code
  FROM public.queue_tickets t
  WHERE t.student_id = p_student_id AND t.service_id = v_svc.service_id
    AND t.queue_date = v_today AND t.status IN ('Waiting', 'Serving')
  ORDER BY t.ticket_number
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'already queued: %', private.queue_label(v_code)
      USING ERRCODE = 'P0001';
  END IF;

  -- The next internal number of this service today, atomically (decision 1).
  INSERT INTO public.queue_counters AS c (service_id, queue_date, last_number)
  VALUES (v_svc.service_id, v_today, 1)
  ON CONFLICT ON CONSTRAINT queue_counters_pkey DO UPDATE SET last_number = c.last_number + 1
  RETURNING c.last_number INTO v_number;

  -- The random display code (decision 1a): a new draw on a code collision, 20 tries.
  v_id := NULL;
  FOR i IN 1..20 LOOP
    v_code := private.queue_random_code();
    BEGIN
      INSERT INTO public.queue_tickets AS t (service_id, student_id, queue_date, ticket_number, ticket_code)
      VALUES (v_svc.service_id, p_student_id, v_today, v_number, v_code)
      RETURNING t.ticket_id INTO v_id;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
      IF v_con IS DISTINCT FROM 'uq_queue_tickets_code' THEN
        RAISE;
      END IF;
    END;
  END LOOP;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'queue busy: try again'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT v_id,
         private.queue_label(v_code),
         'Waiting'::text,
         v_today,
         (SELECT pg_catalog.count(*)::integer FROM public.queue_tickets w
           WHERE w.service_id = v_svc.service_id AND w.queue_date = v_today
             AND w.status = 'Waiting' AND w.ticket_number < v_number);
END
$function$;

-- Registrar: call the next Waiting ticket of today (decision 5). 0 rows = nobody waiting.
CREATE OR REPLACE FUNCTION public.queue_call_next(p_service text, p_window text DEFAULT NULL)
 RETURNS TABLE(ticket_id bigint, ticket_label text, student_id uuid, student_number text, student_name text, window_label text, called_at timestamp with time zone)
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
DECLARE
  v_uid    uuid;
  v_svc    public.queue_services;
  v_today  date;
  v_window text;
  v_code   integer;
  v_id     bigint;
BEGIN
  v_uid := private.queue_require_role('Registrar');
  v_svc := private.queue_service_row(p_service);

  v_window := NULLIF(pg_catalog.btrim(p_window), '');
  IF v_window IS NOT NULL AND (pg_catalog.length(v_window) > 40 OR v_window ~ '[[:cntrl:]]') THEN
    RAISE EXCEPTION 'invalid ticket request: the window label must be at most 40 characters, without control characters'
      USING ERRCODE = '22023';
  END IF;

  v_today := private.queue_today();

  -- One call per Registrar and service at a time (double click).
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'queue_call:' || v_svc.service_id::text || ':' || v_uid::text, 0));

  SELECT t.ticket_code INTO v_code
  FROM public.queue_tickets t
  WHERE t.service_id = v_svc.service_id AND t.queue_date = v_today
    AND t.status = 'Serving' AND t.handled_by = v_uid
  ORDER BY t.ticket_number
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'finish first: %', private.queue_label(v_code)
      USING ERRCODE = 'P0001',
            HINT = 'Mark the ticket you are serving as Done or No-show, then call the next one.';
  END IF;

  SELECT t.ticket_id INTO v_id
  FROM public.queue_tickets t
  WHERE t.service_id = v_svc.service_id AND t.queue_date = v_today AND t.status = 'Waiting'
  ORDER BY t.ticket_number
  LIMIT 1
  FOR UPDATE OF t SKIP LOCKED;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- called_at is set by the trigger.
  UPDATE public.queue_tickets AS t
  SET status = 'Serving', handled_by = v_uid, window_label = v_window
  WHERE t.ticket_id = v_id;

  RETURN QUERY
  SELECT t.ticket_id,
         private.queue_label(t.ticket_code),
         t.student_id,
         s.student_number::text,
         (p.last_name::text || ', ' || p.first_name::text),
         t.window_label,
         t.called_at
  FROM public.queue_tickets t
  JOIN public.students s ON s.student_id = t.student_id
  JOIN public.profiles p ON p.profile_id = t.student_id
  WHERE t.ticket_id = v_id;
END
$function$;

-- Registrar: finish a Serving ticket as Done or No-show (decision 6).
CREATE OR REPLACE FUNCTION public.queue_finish(p_ticket_id bigint, p_outcome text)
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_status text;
BEGIN
  PERFORM private.queue_require_role('Registrar');

  IF p_outcome IS NULL OR p_outcome NOT IN ('Done', 'No-show') THEN
    RAISE EXCEPTION 'invalid ticket request: the outcome must be Done or No-show, not [%]', COALESCE(pg_catalog.left(p_outcome, 40), 'NULL')
      USING ERRCODE = '22023';
  END IF;

  SELECT t.status INTO v_status
  FROM public.queue_tickets t
  WHERE t.ticket_id = p_ticket_id
  FOR UPDATE OF t;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'bad ticket change: ticket % does not exist', COALESCE(p_ticket_id::text, 'NULL')
      USING ERRCODE = 'P0001';
  END IF;
  IF v_status <> 'Serving' THEN
    RAISE EXCEPTION 'bad ticket change: ticket % is %; only a Serving ticket can be finished', p_ticket_id, v_status
      USING ERRCODE = 'P0001';
  END IF;

  -- finished_at is set by the trigger.
  UPDATE public.queue_tickets AS t SET status = p_outcome WHERE t.ticket_id = p_ticket_id;
END
$function$;

-- Student: cancel the own Waiting ticket of today in a service.
CREATE OR REPLACE FUNCTION public.queue_cancel_my_ticket(p_service text)
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid    uuid;
  v_svc    public.queue_services;
  v_id     bigint;
  v_status text;
  v_code   integer;
BEGIN
  v_uid := private.queue_require_role('Student');
  v_svc := private.queue_service_row(p_service);

  SELECT t.ticket_id, t.status, t.ticket_code INTO v_id, v_status, v_code
  FROM public.queue_tickets t
  WHERE t.student_id = v_uid AND t.service_id = v_svc.service_id
    AND t.queue_date = private.queue_today() AND t.status IN ('Waiting', 'Serving')
  ORDER BY t.ticket_number
  LIMIT 1
  FOR UPDATE OF t;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'bad ticket change: no waiting ticket'
      USING ERRCODE = 'P0001';
  END IF;
  IF v_status <> 'Waiting' THEN
    RAISE EXCEPTION 'bad ticket change: ticket % is being served and cannot be cancelled', private.queue_label(v_code)
      USING ERRCODE = 'P0001';
  END IF;

  -- finished_at is set by the trigger.
  UPDATE public.queue_tickets AS t SET status = 'Cancelled' WHERE t.ticket_id = v_id;
END
$function$;

-- Student: the own ticket of today plus aggregate numbers only (decision 8). Always 1 row.
-- DROP first: the result shape changed during the design (window_label added).
DROP FUNCTION IF EXISTS public.queue_my_status(text);
CREATE OR REPLACE FUNCTION public.queue_my_status(p_service text)
 RETURNS TABLE(is_open boolean, has_ticket boolean, ticket_label text, ticket_status text, people_ahead integer, now_serving text, waiting_total integer, avg_service_seconds integer, window_label text)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
DECLARE
  v_uid   uuid;
  v_svc   public.queue_services;
  v_today date;
  v_t     public.queue_tickets;
  v_has   boolean;
  v_ahead integer;
  v_now   text;
  v_wait  integer;
  v_avg   integer;
BEGIN
  v_uid := private.queue_require_role('Student');
  v_svc := private.queue_service_row(p_service);
  v_today := private.queue_today();

  -- The caller's own ticket of today: the active one first, else the latest.
  SELECT t.* INTO v_t
  FROM public.queue_tickets t
  WHERE t.student_id = v_uid AND t.service_id = v_svc.service_id AND t.queue_date = v_today
  ORDER BY (t.status IN ('Waiting', 'Serving')) DESC, t.created_at DESC, t.ticket_id DESC
  LIMIT 1;
  v_has := FOUND;

  IF v_has AND v_t.status = 'Waiting' THEN
    SELECT pg_catalog.count(*)::integer INTO v_ahead
    FROM public.queue_tickets w
    WHERE w.service_id = v_svc.service_id AND w.queue_date = v_today
      AND w.status = 'Waiting' AND w.ticket_number < v_t.ticket_number;
  ELSIF v_has AND v_t.status = 'Serving' THEN
    v_ahead := 0;
  ELSE
    v_ahead := NULL;
  END IF;

  SELECT private.queue_label(t.ticket_code) INTO v_now
  FROM public.queue_tickets t
  WHERE t.service_id = v_svc.service_id AND t.queue_date = v_today AND t.status = 'Serving'
  ORDER BY t.ticket_number
  LIMIT 1;
  IF v_now IS NULL THEN
    SELECT private.queue_label(t.ticket_code) INTO v_now
    FROM public.queue_tickets t
    WHERE t.service_id = v_svc.service_id AND t.queue_date = v_today AND t.called_at IS NOT NULL
    ORDER BY t.called_at DESC, t.ticket_number DESC
    LIMIT 1;
  END IF;

  SELECT pg_catalog.count(*)::integer INTO v_wait
  FROM public.queue_tickets t
  WHERE t.service_id = v_svc.service_id AND t.queue_date = v_today AND t.status = 'Waiting';

  SELECT pg_catalog.round(pg_catalog.avg(EXTRACT(EPOCH FROM (x.finished_at - x.called_at))))::integer INTO v_avg
  FROM (SELECT t.finished_at, t.called_at
        FROM public.queue_tickets t
        WHERE t.service_id = v_svc.service_id AND t.queue_date = v_today AND t.status = 'Done'
        ORDER BY t.finished_at DESC, t.ticket_id DESC
        LIMIT 20) x;

  RETURN QUERY
  SELECT v_svc.is_open,
         v_has,
         CASE WHEN v_has THEN private.queue_label(v_t.ticket_code) END,
         CASE WHEN v_has THEN v_t.status END,
         v_ahead,
         v_now,
         v_wait,
         v_avg,
         CASE WHEN v_has AND v_t.status = 'Serving' THEN v_t.window_label END;
END
$function$;

-- Registrar: today's tickets of a service, all statuses, ordered by number.
CREATE OR REPLACE FUNCTION public.queue_staff_list(p_service text)
 RETURNS TABLE(ticket_id bigint, ticket_label text, ticket_number integer, status text, student_id uuid, student_number text, student_name text, window_label text, created_at timestamp with time zone, called_at timestamp with time zone, finished_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
DECLARE
  v_svc public.queue_services;
BEGIN
  PERFORM private.queue_require_role('Registrar');
  v_svc := private.queue_service_row(p_service);

  RETURN QUERY
  SELECT t.ticket_id,
         private.queue_label(t.ticket_code),
         t.ticket_number,
         t.status,
         t.student_id,
         s.student_number::text,
         (p.last_name::text || ', ' || p.first_name::text),
         t.window_label,
         t.created_at,
         t.called_at,
         t.finished_at
  FROM public.queue_tickets t
  JOIN public.students s ON s.student_id = t.student_id
  JOIN public.profiles p ON p.profile_id = t.student_id
  WHERE t.service_id = v_svc.service_id AND t.queue_date = private.queue_today()
  ORDER BY t.ticket_number;
END
$function$;

-- Registrar: one student's card for the scan screen (looked at before a ticket is issued).
-- Exactly one row. already_queued_label = the student's active (Waiting / Serving) ticket of
-- the Enrollment service today, else NULL.
-- >>> PHOTO PLACEHOLDER: the student's photo path will be added to this result later (a
-- >>> new output column, so the function will then be dropped and created again). Nothing
-- >>> about photos exists now.
CREATE OR REPLACE FUNCTION public.queue_student_card(p_student_id uuid)
 RETURNS TABLE(student_id uuid, student_number text, student_name text, program_code text, program_name text, already_queued_label text)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
BEGIN
  PERFORM private.queue_require_role('Registrar');

  IF p_student_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.students s
       JOIN public.profiles p ON p.profile_id = s.student_id
       JOIN public.roles r ON r.role_id = p.role_id
       WHERE s.student_id = p_student_id AND p.is_active AND r.role_name = 'Student') THEN
    RAISE EXCEPTION 'invalid ticket request: the person is not an active student'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT s.student_id,
         s.student_number::text,
         (p.last_name::text || ', ' || p.first_name::text),
         pr.code::text,
         pr.name::text,
         (SELECT private.queue_label(t.ticket_code)
            FROM public.queue_tickets t
            JOIN public.queue_services qs ON qs.service_id = t.service_id
           WHERE qs.service_code = 'Enrollment' AND t.student_id = s.student_id
             AND t.queue_date = private.queue_today() AND t.status IN ('Waiting', 'Serving')
           ORDER BY t.ticket_number
           LIMIT 1)
  FROM public.students s
  JOIN public.profiles p ON p.profile_id = s.student_id
  JOIN public.programs pr ON pr.program_id = s.program_id
  WHERE s.student_id = p_student_id;
END
$function$;

REVOKE ALL ON FUNCTION public.issue_queue_ticket(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_call_next(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_finish(bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_cancel_my_ticket(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_my_status(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_staff_list(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_student_card(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_queue_ticket(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_call_next(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_finish(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_cancel_my_ticket(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_my_status(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_staff_list(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_student_card(uuid) TO authenticated;

-- ------------------------------------------
-- 6. Policies and grants (rebuilt from nothing; decisions 8 to 10)
-- ------------------------------------------
DROP POLICY IF EXISTS queue_services_read ON public.queue_services;
CREATE POLICY queue_services_read ON public.queue_services
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS queue_tickets_read ON public.queue_tickets;
CREATE POLICY queue_tickets_read ON public.queue_tickets
  FOR SELECT TO authenticated
  USING (((student_id = ( SELECT private.active_uid() AS active_uid)) OR (( SELECT private.current_role_name() AS current_role_name) = 'Registrar'::text)));

-- queue_counters: RLS on and NO policy, so nobody reads a row through the API.

REVOKE ALL ON public.queue_services FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.queue_tickets FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.queue_counters FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.queue_services TO authenticated;
GRANT SELECT ON public.queue_tickets TO authenticated;
GRANT SELECT ON public.queue_counters TO authenticated;   -- 0 rows (no policy); decision 9

DO $$
BEGIN
  EXECUTE pg_catalog.format('REVOKE ALL ON SEQUENCE %s FROM PUBLIC, anon, authenticated',
                            pg_catalog.pg_get_serial_sequence('public.queue_services', 'service_id'));
  EXECUTE pg_catalog.format('REVOKE ALL ON SEQUENCE %s FROM PUBLIC, anon, authenticated',
                            pg_catalog.pg_get_serial_sequence('public.queue_tickets', 'ticket_id'));
END
$$;

-- ------------------------------------------
-- 7. Checks after the change (any failure rolls back the whole file)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
BEGIN
  -- a) All functions exist.
  SELECT string_agg(e.sig, ', ') INTO v_bad
  FROM (VALUES ('public.issue_queue_ticket(uuid, text)'), ('public.queue_call_next(text, text)'),
               ('public.queue_finish(bigint, text)'), ('public.queue_cancel_my_ticket(text)'),
               ('public.queue_my_status(text)'), ('public.queue_staff_list(text)'),
               ('public.queue_student_card(uuid)'),
               ('private.queue_today()'), ('private.queue_label(integer)'), ('private.queue_random_code()'),
               ('private.queue_require_role(text)'), ('private.queue_service_row(text)'),
               ('private.require_queue_ticket_rules()')) AS e(sig)
  WHERE pg_catalog.to_regprocedure(e.sig) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: function(s) not created: %; rolled back', v_bad;
  END IF;

  -- b) Public functions: SECURITY DEFINER, empty search_path, owned by the running role,
  --    no PUBLIC, anon cannot execute, authenticated can.
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE p.oid IN (pg_catalog.to_regprocedure('public.issue_queue_ticket(uuid, text)'),
                  pg_catalog.to_regprocedure('public.queue_call_next(text, text)'),
                  pg_catalog.to_regprocedure('public.queue_finish(bigint, text)'),
                  pg_catalog.to_regprocedure('public.queue_cancel_my_ticket(text)'),
                  pg_catalog.to_regprocedure('public.queue_my_status(text)'),
                  pg_catalog.to_regprocedure('public.queue_staff_list(text)'),
                  pg_catalog.to_regprocedure('public.queue_student_card(uuid)'))
    AND NOT (p.prosecdef
             AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
             AND p.proowner = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
             AND p.proacl IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)
             AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
             AND pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: not SECURITY DEFINER / empty search_path / owner / grants as intended: %; rolled back', v_bad;
  END IF;

  -- c) Private helpers and the trigger function: SECURITY INVOKER, empty search_path, no
  --    PUBLIC, no anon; helpers also not authenticated (the trigger function is, like the
  --    other trigger functions).
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE p.oid IN (pg_catalog.to_regprocedure('private.queue_today()'),
                  pg_catalog.to_regprocedure('private.queue_label(integer)'),
                  pg_catalog.to_regprocedure('private.queue_random_code()'),
                  pg_catalog.to_regprocedure('private.queue_require_role(text)'),
                  pg_catalog.to_regprocedure('private.queue_service_row(text)'),
                  pg_catalog.to_regprocedure('private.require_queue_ticket_rules()'))
    AND NOT (NOT p.prosecdef
             AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
             AND p.proacl IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)
             AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
             AND (p.proname = 'require_queue_ticket_rules'
                  OR NOT pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE')));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: private function(s) not locked down: %; rolled back', v_bad;
  END IF;

  -- d) Triggers: on queue_tickets exactly require_queue_ticket_rules BEFORE UPDATE ROW
  --    (1+2+16 = 19) and audit_log AFTER INSERT OR DELETE OR UPDATE ROW (1+4+8+16 = 29),
  --    both enabled, calling this file's functions; none on the other two tables.
  SELECT string_agg(t.tgname || ' ' || t.tgtype || ' ' || t.tgenabled::text, ', ' ORDER BY t.tgname) INTO v_bad
  FROM pg_catalog.pg_trigger t
  WHERE t.tgrelid = 'public.queue_tickets'::pg_catalog.regclass AND NOT t.tgisinternal
    AND t.tgfoid IN (pg_catalog.to_regprocedure('private.audit_log()'),
                     pg_catalog.to_regprocedure('private.require_queue_ticket_rules()'));
  IF v_bad IS DISTINCT FROM 'audit_log 29 O, require_queue_ticket_rules 19 O'
     OR (SELECT pg_catalog.count(*) FROM pg_catalog.pg_trigger t
          WHERE t.tgrelid = 'public.queue_tickets'::pg_catalog.regclass AND NOT t.tgisinternal) <> 2
     OR EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                 WHERE t.tgrelid IN ('public.queue_services'::pg_catalog.regclass, 'public.queue_counters'::pg_catalog.regclass)
                   AND NOT t.tgisinternal) THEN
    RAISE EXCEPTION 'queue_rules: triggers on the queue tables not as intended ([%]); rolled back', v_bad;
  END IF;

  -- e) RLS on for the three tables; exactly the two SELECT policies.
  SELECT string_agg(p.tablename || '.' || p.policyname || ' (' || p.cmd || ')', ', ' ORDER BY p.tablename, p.policyname) INTO v_bad
  FROM pg_catalog.pg_policies p
  WHERE p.schemaname = 'public' AND p.tablename IN ('queue_services', 'queue_tickets', 'queue_counters');
  IF v_bad IS DISTINCT FROM 'queue_services.queue_services_read (SELECT), queue_tickets.queue_tickets_read (SELECT)'
     OR EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                 WHERE c.oid IN ('public.queue_services'::pg_catalog.regclass, 'public.queue_tickets'::pg_catalog.regclass,
                                 'public.queue_counters'::pg_catalog.regclass)
                   AND NOT c.relrowsecurity) THEN
    RAISE EXCEPTION 'queue_rules: RLS or policies on the queue tables not as intended ([%]); rolled back', v_bad;
  END IF;

  -- f) Table privileges: anon nothing; authenticated SELECT only, no column grants; the
  --    identity sequences: nothing for anon / authenticated.
  SELECT string_agg(c.relname, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  WHERE c.oid IN ('public.queue_services'::pg_catalog.regclass, 'public.queue_tickets'::pg_catalog.regclass,
                  'public.queue_counters'::pg_catalog.regclass)
    AND (pg_catalog.has_table_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
         OR pg_catalog.has_any_column_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')
         OR NOT pg_catalog.has_table_privilege('authenticated', c.oid, 'SELECT')
         OR pg_catalog.has_table_privilege('authenticated', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
         OR pg_catalog.has_any_column_privilege('authenticated', c.oid, 'INSERT, UPDATE, REFERENCES')
         OR EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                     WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped AND a.attacl IS NOT NULL));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: table privileges not as intended on %; rolled back', v_bad;
  END IF;
  SELECT string_agg(q.s || ' ' || q.who, ', ') INTO v_bad
  FROM (SELECT seq.s, w.who
        FROM (VALUES (pg_catalog.pg_get_serial_sequence('public.queue_services', 'service_id')),
                     (pg_catalog.pg_get_serial_sequence('public.queue_tickets', 'ticket_id'))) AS seq(s)
        CROSS JOIN (VALUES ('anon'), ('authenticated')) AS w(who)
        WHERE pg_catalog.has_sequence_privilege(w.who, seq.s, 'USAGE, SELECT, UPDATE')) q;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_rules: sequence privileges still present: %; rolled back', v_bad;
  END IF;

  -- g) The two services, the partial unique index, ticket_id is the single-column primary key
  --    (the audit trigger's argument).
  IF (SELECT pg_catalog.count(*) FROM public.queue_services s
       WHERE (s.service_code, s.service_name, s.ticket_prefix) IN
             (('Enrollment', 'Enrollment', 'E'), ('Documents', 'Document claim', 'D'))) <> 2 THEN
    RAISE EXCEPTION 'queue_rules: the services Enrollment (E) / Documents (D) are not as intended; rolled back';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                 WHERE i.indexrelid = pg_catalog.to_regclass('public.uq_queue_tickets_active_student')
                   AND i.indrelid = 'public.queue_tickets'::pg_catalog.regclass
                   AND i.indisunique AND i.indpred IS NOT NULL) THEN
    RAISE EXCEPTION 'queue_rules: partial unique index uq_queue_tickets_active_student missing; rolled back';
  END IF;
  -- The random code: its CHECK and its UNIQUE per service and day (decision 1a).
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                 WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'u'
                   AND k.conname = 'uq_queue_tickets_code')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'c'
                      AND k.conname = 'ck_queue_tickets_code') THEN
    RAISE EXCEPTION 'queue_rules: uq_queue_tickets_code / ck_queue_tickets_code missing; rolled back';
  END IF;
  IF (SELECT pg_catalog.count(*) FROM pg_catalog.generate_series(1, 20) g
       WHERE private.queue_random_code() BETWEEN 1000000 AND 9999999) <> 20 THEN
    RAISE EXCEPTION 'queue_rules: private.queue_random_code() returned a value outside 1000000..9999999; rolled back';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                 JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
                 WHERE i.indrelid = 'public.queue_tickets'::pg_catalog.regclass
                   AND i.indisprimary AND i.indnatts = 1 AND a.attname = 'ticket_id') THEN
    RAISE EXCEPTION 'queue_rules: ticket_id is not the single-column primary key of queue_tickets; rolled back';
  END IF;
END
$$;

-- Ask PostgREST to reload its schema cache (sent when the transaction commits).
NOTIFY pgrst, 'reload schema';

COMMIT;


-- ------------------------------------------
-- ROLLBACK (back to the state before this file)
-- ------------------------------------------
-- DESTROYS every ticket, counter and service. Remove the queue pages and RPC calls from the
-- app FIRST. Audit rows of queue_tickets stay (append-only). Nothing else was changed by
-- this file (no existing grant, policy or trigger was touched).
--
-- BEGIN;
--
-- DROP FUNCTION IF EXISTS public.issue_queue_ticket(uuid, text);
-- DROP FUNCTION IF EXISTS public.queue_call_next(text, text);
-- DROP FUNCTION IF EXISTS public.queue_finish(bigint, text);
-- DROP FUNCTION IF EXISTS public.queue_cancel_my_ticket(text);
-- DROP FUNCTION IF EXISTS public.queue_my_status(text);
-- DROP FUNCTION IF EXISTS public.queue_staff_list(text);
-- DROP FUNCTION IF EXISTS public.queue_student_card(uuid);
-- DROP TABLE IF EXISTS public.queue_tickets;    -- drops its triggers, policy, indexes
-- DROP TABLE IF EXISTS public.queue_counters;
-- DROP FUNCTION IF EXISTS private.queue_service_row(text);   -- before queue_services (its row type)
-- DROP TABLE IF EXISTS public.queue_services;
-- DROP FUNCTION IF EXISTS private.require_queue_ticket_rules();
-- DROP FUNCTION IF EXISTS private.queue_require_role(text);
-- DROP FUNCTION IF EXISTS private.queue_label(integer);
-- DROP FUNCTION IF EXISTS private.queue_random_code();
-- DROP FUNCTION IF EXISTS private.queue_today();
-- NOTIFY pgrst, 'reload schema';
--
-- COMMIT;


-- ==========================================
-- DIAGNOSTICS (read-only; run one at a time and send the output back)
-- ==========================================
-- Nothing here changes the database.
--
-- a) BEFORE and AFTER: every CHECK, UNIQUE, PRIMARY KEY and FOREIGN KEY constraint on the
--    tables this feature reads or writes. READ IT: the live database has CHECK constraints
--    that are not in schema.sql (safety check (g) tests the single-column ones on
--    audit_logs.action / table_name / record_id with sample values).
-- select c.conrelid::regclass as table_name, c.conname, c.contype, pg_get_constraintdef(c.oid) as definition
-- from pg_constraint c
-- where c.conrelid in ('public.profiles'::regclass, 'public.students'::regclass, 'public.audit_logs'::regclass)
--    or c.conrelid in (to_regclass('public.queue_services'), to_regclass('public.queue_tickets'),
--                      to_regclass('public.queue_counters'))
-- order by 1, 3, 2;
--
-- b) BEFORE and AFTER: functions with these names, their properties and grants.
-- select p.oid::regprocedure as function, pg_get_userbyid(p.proowner) as owner,
--        p.prosecdef as security_definer, p.proconfig, p.proacl::text as acl,
--        has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute
-- from pg_proc p
-- where p.proname in ('issue_queue_ticket', 'queue_call_next', 'queue_finish', 'queue_cancel_my_ticket',
--                     'queue_my_status', 'queue_staff_list', 'queue_student_card', 'queue_today',
--                     'queue_label', 'queue_random_code', 'queue_require_role', 'queue_service_row', 'require_queue_ticket_rules')
-- order by 1;
--
-- c) BEFORE and AFTER: privileges, RLS flags, policies and triggers of the queue tables.
-- select c.relname, c.relkind, c.relacl::text as acl, c.relrowsecurity, c.relforcerowsecurity,
--        pg_get_userbyid(c.relowner) as owner
-- from pg_class c
-- where c.relnamespace = 'public'::regnamespace and c.relname like 'queue%' order by 1;
-- select tablename, policyname, cmd, roles, qual, with_check from pg_policies
-- where schemaname = 'public' and tablename like 'queue%' order by 1, 2;
-- select t.tgrelid::regclass, t.tgname, t.tgtype, t.tgenabled, t.tgfoid::regprocedure from pg_trigger t
-- where t.tgrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace and relname like 'queue%')
--   and not t.tgisinternal order by 1, 2;
--
-- d) AFTER: today's queue per service (counts only, no personal data).
-- select s.service_code, s.is_open, t.status, count(t.ticket_id),
--        (select c.last_number from public.queue_counters c
--          where c.service_id = s.service_id and c.queue_date = (now() at time zone 'Asia/Manila')::date) as last_number
-- from public.queue_services s
-- left join public.queue_tickets t on t.service_id = s.service_id
--                                 and t.queue_date = (now() at time zone 'Asia/Manila')::date
-- group by s.service_id, s.service_code, s.is_open, t.status order by 1, 3;
--
-- e) AFTER: the latest ticket changes in the audit log.
-- select l.log_id, l.created_at, l.action, l.record_id as ticket_id, l.actor_id,
--        l.old_data ->> 'status' as old_status, l.new_data ->> 'status' as new_status
-- from public.audit_logs l where l.table_name = 'queue_tickets'
-- order by l.log_id desc limit 20;
--
-- f) AFTER: stale tickets of earlier days that are still active (maintenance m1 closes them).
-- select s.service_code, t.queue_date, t.status, count(*)
-- from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
-- where t.queue_date < (now() at time zone 'Asia/Manila')::date and t.status in ('Waiting', 'Serving')
-- group by 1, 2, 3 order by 2, 1, 3;


-- ==========================================
-- MAINTENANCE (these WRITE; run only on purpose, as postgres)
-- ==========================================
-- m1) Close the stale tickets of earlier days (R2): Waiting -> Cancelled, Serving -> No-show
--     (both allowed steps; finished_at = now() by the trigger; audited with actor NULL).
-- UPDATE public.queue_tickets
-- SET status = CASE status WHEN 'Waiting' THEN 'Cancelled' ELSE 'No-show' END
-- WHERE queue_date < (now() AT TIME ZONE 'Asia/Manila')::date AND status IN ('Waiting', 'Serving');
--
-- m2) Open or close a service for new tickets (decision 4):
-- UPDATE public.queue_services SET is_open = false WHERE service_code = 'Documents';
-- UPDATE public.queue_services SET is_open = true  WHERE service_code = 'Documents';
--
-- m3) Retention (PM to confirm the 12 months): delete tickets and counters older than 12
--     months together with their audit rows. The row delete itself is not audited.
-- BEGIN;
-- CREATE TEMP TABLE purge_tickets ON COMMIT DROP AS
--   SELECT t.ticket_id FROM public.queue_tickets t
--   WHERE t.queue_date < (now() AT TIME ZONE 'Asia/Manila')::date - interval '12 months';
-- ALTER TABLE public.queue_tickets DISABLE TRIGGER audit_log;
-- DELETE FROM public.queue_tickets t USING purge_tickets p WHERE t.ticket_id = p.ticket_id;
-- ALTER TABLE public.queue_tickets ENABLE TRIGGER audit_log;
-- DELETE FROM public.queue_counters c
--   WHERE c.queue_date < (now() AT TIME ZONE 'Asia/Manila')::date - interval '12 months';
-- ALTER TABLE public.audit_logs DISABLE TRIGGER audit_logs_readonly;
-- DELETE FROM public.audit_logs l USING purge_tickets p
--   WHERE l.table_name = 'queue_tickets' AND l.record_id = p.ticket_id::text;
-- ALTER TABLE public.audit_logs ENABLE ALWAYS TRIGGER audit_logs_readonly;
-- SELECT count(*) AS purged FROM purge_tickets;
-- COMMIT;
