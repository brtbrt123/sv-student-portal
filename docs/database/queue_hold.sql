-- ==========================================
-- QUEUE HOLD ("I need a few minutes"): DATABASE SIDE (feature/queue-hold-sql)
-- ==========================================
-- A student who is waiting in the virtual queue (queue_rules.sql) can put their own ticket
-- ON HOLD for at most 15 minutes (for example to fetch a missing document). While it is held
-- the Registrar's "Call next" skips it and the people behind are served; when the student
-- comes back and un-holds, the ticket is Waiting again with its ORIGINAL internal number, so
-- the student is simply the next one called (nobody jumps: the order is ticket_number only,
-- there is no priority column). A hold that lasted longer than 15 minutes cannot be undone by
-- the student any more; the Registrar may mark a held ticket No-show at any time and the
-- student may cancel it.
-- Runs AFTER queue_rules.sql and notifications_rules.sql (both live). Changes queue_tickets
-- and the queue functions in place; notifications_rules.sql is NOT changed (decision H8).
--
-- WHAT IT DOES
--   1. queue_tickets:
--        new column  held_at timestamptz NULL  (set by the database when the ticket becomes
--                    Held, NULL in every other status)
--        ck_queue_tickets_status  now: Waiting | Serving | Held | Done | No-show | Cancelled
--        ck_queue_tickets_state   now also: Held (no call / finish / handler, like Waiting) and
--                                 a No-show that was never called (came from Held: called_at
--                                 NULL, handled_by = the Registrar who marked it, no window)
--        ck_queue_tickets_held    NEW: (status = 'Held' AND held_at IS NOT NULL)
--                                       OR (status <> 'Held' AND held_at IS NULL)
--        uq_queue_tickets_active_student  rebuilt: WHERE status IN ('Waiting', 'Serving', 'Held')
--                                 (a held ticket is still the student's one active ticket)
--   2. New helper (schema private, SECURITY INVOKER, no EXECUTE for PUBLIC, anon,
--      authenticated):
--        private.queue_hold_limit() RETURNS interval   -- '15 minutes', the ONE place to change it
--   3. New callable functions (SECURITY DEFINER, owner postgres, search_path '', EXECUTE for
--      authenticated only, not PUBLIC, not anon; caller must be an ACTIVE Student; they only
--      ever touch the CALLER's own ticket of TODAY in that service, no ticket id is accepted):
--        queue_hold_my_ticket(p_service text) RETURNS timestamp with time zone
--          Waiting -> Held; returns held_until (= held_at + the limit)
--        queue_unhold_my_ticket(p_service text) RETURNS void
--          Held -> Waiting (same ticket_number and ticket_code), only within the limit
--   4. Changed functions (same names and arguments; EXECUTE re-granted to authenticated only):
--        issue_queue_ticket(p_student_id uuid, p_service text)        CREATE OR REPLACE
--          RETURNS TABLE(ticket_id bigint, ticket_label text, status text, queue_date date,
--                        people_ahead integer)                        (unchanged shape)
--          "already queued:" now also when the student's active ticket is Held
--        queue_finish(p_ticket_id bigint, p_outcome text) RETURNS void  CREATE OR REPLACE
--          also Held -> No-show (any time); Held -> Done is refused
--        queue_cancel_my_ticket(p_service text) RETURNS void          CREATE OR REPLACE
--          also cancels a Held ticket
--        queue_my_status(p_service text)                              DROP + CREATE
--          RETURNS TABLE(is_open boolean, has_ticket boolean, ticket_label text,
--                        ticket_status text, people_ahead integer, now_serving text,
--                        waiting_total integer, avg_service_seconds integer,
--                        window_label text, held_until timestamp with time zone)
--          ticket_status may be 'Held'; held_until = held_at + the limit when Held, else NULL;
--          people_ahead of a Held ticket = Waiting tickets with a lower number (as Waiting);
--          held tickets never count in anyone's people_ahead nor in waiting_total
--        queue_staff_list(p_service text)                             DROP + CREATE
--          RETURNS TABLE(ticket_id bigint, ticket_label text, ticket_number integer,
--                        status text, student_id uuid, student_number text,
--                        student_name text, window_label text, created_at timestamptz,
--                        called_at timestamptz, finished_at timestamptz,
--                        held_at timestamptz)
--        queue_student_card(p_student_id uuid)                        CREATE OR REPLACE
--          (unchanged shape) already_queued_label also shows a Held Enrollment ticket
--        private.require_queue_ticket_rules()  (BEFORE UPDATE trigger)  CREATE OR REPLACE
--          new steps Waiting -> Held, Held -> Waiting, Held -> Cancelled, Held -> No-show;
--          held_at is the database's (decision H3)
--      NOT changed (reviewed): queue_call_next (it already takes only status = 'Waiting', so a
--      held ticket is never called; safety check (f) verifies the live body), the audit
--      trigger (it logs the whole row, held_at included), private.notify_on_queue_tickets
--      (decision H8), the policies and table grants.
--
-- ERRORS (PostgREST: code = SQLSTATE, message = text; same prefixes as queue_rules.sql)
--   42501  "not allowed: only a signed-in, active Student account can do this"  (hold / unhold
--          by another role, an inactive account or no JWT)
--   42501  "permission denied for function ..."   anon
--   22023  "invalid ticket request: unknown service [...]"
--   P0001  "bad ticket change: no waiting ticket"                     hold: no active ticket
--   P0001  "bad ticket change: ticket #1234567 is already on hold"    hold twice
--   P0001  "bad ticket change: ticket #1234567 is being served and cannot be put on hold"
--   P0001  "bad ticket change: no ticket on hold"                     unhold: nothing Held
--   P0001  "hold expired: ticket #1234567 was on hold for more than 15 minutes"   (NEW prefix;
--          HINT: cancel it and ask the Registrar for a new number)
--   P0001  "bad ticket change: ticket 123 is on hold; it can only be marked No-show"  (finish)
--   P0001  "bad ticket change: Held -> Serving is not allowed (ticket 123)"  (trigger, any role)
--
-- DESIGN DECISIONS
--   H1. No new order column: the queue order stays ticket_number (queue_rules.sql decision 5).
--       Holding takes the ticket out of "Call next"; un-holding puts it back with its old
--       number, so it is ahead of everybody who came later. Hold + unhold at once changes
--       nothing (nobody was called in between).
--   H2. Hold only from Waiting. A Serving ticket cannot be held (the student is at the window);
--       Done / No-show / Cancelled are final.
--   H3. held_at is written by the trigger: now() on Waiting -> Held, kept while Held, NULL in
--       every other status (any value the statement sends is replaced), so a client can never
--       extend its own hold. ck_queue_tickets_held enforces the same on INSERT (owner only).
--   H4. The 15-minute limit is checked by queue_unhold_my_ticket (now() > held_at + limit ->
--       "hold expired:"). Nothing expires automatically: an expired hold stays Held (and keeps
--       blocking a new ticket for that student and service today) until the student cancels
--       it or the Registrar marks it No-show. queue_my_status returns held_until so the app
--       can show the deadline and the Registrar's list shows held_at.
--   H5. Held -> No-show (queue_finish): the ticket was never called, so called_at stays NULL;
--       handled_by = the Registrar who marked it (auth.uid(); the owner without a JWT must give
--       it, the CHECK requires it); window_label stays NULL. avg_service_seconds uses Done only
--       and now_serving uses called_at, so neither is affected. Held -> Done is refused.
--   H6. The student functions take no ticket id: they find the caller's own active ticket of
--       today in that service (FOR UPDATE), so nobody can hold, unhold or cancel someone
--       else's ticket. Direct table writes stay impossible (no privilege).
--   H7. Races: hold and queue_call_next both lock the row. If Call next locks it first, the
--       hold waits, then sees Serving and is refused; if the hold locks it first, Call next
--       skips it (SKIP LOCKED) and takes the next Waiting ticket. The trigger refuses
--       Held -> Serving for every role, so a held ticket can never be called.
--   H8. Notifications: private.notify_on_queue_tickets reacts only to INSERT of a Waiting
--       ticket, Waiting -> Serving and Serving -> No-show. Waiting -> Held, Held -> Waiting,
--       Held -> Cancelled and Held -> No-show are therefore SILENT; no notification kind is
--       added and notifications_rules.sql is not changed. Safety check (g) stops if the live
--       function does not have exactly those conditions. (Possible later change: tell the
--       student when the Registrar marks a held ticket No-show.)
--   H9. Repeated holds: a student may hold again after un-holding (each hold is at most 15
--       minutes). This lets one student stay at the front while repeatedly stepping aside;
--       nobody behind is harmed (they are served meanwhile). Limiting holds per ticket would
--       need a counter column; not done (PM decision).
--
-- RESIDUAL RISKS
--   RH1 OLDER CHECKS: queue_rules.sql must NOT be run again as it stands (its safety check (c)
--       refuses the new held_at column, and since notifications_rules.sql also its trigger
--       count). queue_rules_test.sql TC-139 will report "unexpected queue_tickets.held_at" in
--       columns_diff; the other queue tests are not affected (the new rules only add steps).
--   RH2 Stale holds of earlier days: maintenance m1 below now closes Held tickets too
--       (Held -> Cancelled).
--   RH3 The server role keeps Supabase's default table rights (queue_rules.sql R4); the trigger
--       still applies to it.
--
-- How to run: Supabase SQL editor, as postgres, at a quiet time (ALTER TABLE takes a short
-- ACCESS EXCLUSIVE lock on queue_tickets). Copy from "BEGIN;" to "COMMIT;" inclusive into a new
-- tab and run that tab as a whole. One transaction: any error, including a failed check, rolls
-- back everything. Re-runnable (ADD COLUMN IF NOT EXISTS, constraints and index dropped and
-- added again, CREATE OR REPLACE, DROP FUNCTION IF EXISTS before the two shape changes, grants
-- rebuilt from REVOKE ALL).
--   - Rehearse first: docs/database/queue_hold_rehearsal.sql (this change and TC-199 to TC-217
--     in ONE rolled-back transaction, one result row, TC-199R).
--   - Test afterwards: docs/database/queue_hold_test.sql (TC-199 to TC-217), then
--     regression_after_grants.sql (unchanged results expected).
--   - Deploy the app change (hold / unhold buttons, the new held_until / held_at columns, the
--     "hold expired:" message) only AFTER this file is live. The current app keeps working:
--     the new result columns are added at the END and the existing ones are unchanged.
-- Undo: the ROLLBACK block after COMMIT.
--
-- Status: NOT RUN YET (written 2026-10-13 without a local PostgreSQL; rehearse first).


BEGIN;

-- ------------------------------------------
-- 1. Safety checks (stop before changing anything)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
  v_src text;
BEGIN
  IF current_setting('server_version_num')::int < 170000 THEN
    RAISE EXCEPTION 'queue_hold: PostgreSQL 17+ expected (REVOKE ALL includes MAINTAIN); found %', current_setting('server_version');
  END IF;

  -- a) The queue (queue_rules.sql) and the helpers it uses are installed.
  SELECT string_agg(e.t, ', ') INTO v_bad
  FROM (VALUES ('queue_services'), ('queue_tickets'), ('queue_counters'), ('students'), ('profiles'),
               ('roles'), ('programs'), ('audit_logs')) AS e(t)
  WHERE pg_catalog.to_regclass('public.' || e.t) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold: missing table(s) public.%; run queue_rules.sql first; stop', v_bad;
  END IF;
  SELECT string_agg(e.sig, ', ') INTO v_bad
  FROM (VALUES ('public.issue_queue_ticket(uuid, text)'), ('public.queue_call_next(text, text)'),
               ('public.queue_finish(bigint, text)'), ('public.queue_cancel_my_ticket(text)'),
               ('public.queue_my_status(text)'), ('public.queue_staff_list(text)'),
               ('public.queue_student_card(uuid)'),
               ('private.queue_today()'), ('private.queue_label(integer)'), ('private.queue_random_code()'),
               ('private.queue_require_role(text)'), ('private.queue_service_row(text)'),
               ('private.require_queue_ticket_rules()'), ('private.audit_log()'),
               ('private.active_uid()'), ('private.current_role_name()'), ('auth.uid()')) AS e(sig)
  WHERE pg_catalog.to_regprocedure(e.sig) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold: missing function(s) %; run queue_rules.sql first; stop', v_bad;
  END IF;

  -- b) queue_tickets has exactly queue_rules.sql's columns (plus held_at on a re-run).
  WITH expected(col, typ) AS (VALUES
    ('ticket_id', 'bigint'), ('service_id', 'bigint'), ('student_id', 'uuid'), ('queue_date', 'date'),
    ('ticket_number', 'integer'), ('ticket_code', 'integer'), ('status', 'text'),
    ('window_label', 'text'), ('handled_by', 'uuid'), ('created_at', 'timestamp with time zone'),
    ('called_at', 'timestamp with time zone'), ('finished_at', 'timestamp with time zone'),
    ('checkin_photo_path', 'text'), ('held_at', 'timestamp with time zone')),
  live AS (
    SELECT a.attname::text AS col, pg_catalog.format_type(a.atttypid, NULL) AS typ
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = 'public.queue_tickets'::pg_catalog.regclass AND a.attnum > 0 AND NOT a.attisdropped)
  SELECT string_agg(d, '; ') INTO v_bad
  FROM ((SELECT 'missing ' || e.col || ' ' || e.typ AS d
         FROM (SELECT * FROM expected EXCEPT SELECT * FROM live) e WHERE e.col <> 'held_at')
        UNION ALL
        (SELECT 'unexpected ' || x.col || ' ' || x.typ FROM (SELECT * FROM live EXCEPT SELECT * FROM expected) x)) dd;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold: public.queue_tickets has other columns than expected: %; stop and review', v_bad;
  END IF;

  -- c) The constraints and the index this file replaces exist (under these names).
  SELECT string_agg(e.n, ', ') INTO v_bad
  FROM (VALUES ('ck_queue_tickets_status'), ('ck_queue_tickets_state')) AS e(n)
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'c'
                      AND k.conname = e.n);
  IF v_bad IS NOT NULL
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                    WHERE i.indexrelid = pg_catalog.to_regclass('public.uq_queue_tickets_active_student')
                      AND i.indrelid = 'public.queue_tickets'::pg_catalog.regclass
                      AND i.indisunique AND i.indpred IS NOT NULL) THEN
    RAISE EXCEPTION 'queue_hold: constraint(s) [%] or the partial unique index uq_queue_tickets_active_student missing; stop and review', v_bad;
  END IF;

  -- d) Triggers on queue_tickets: require_queue_ticket_rules and audit_log as queue_rules.sql
  --    made them, plus at most trg_notify_queue_tickets (notifications_rules.sql); nothing else.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                 WHERE t.tgrelid = 'public.queue_tickets'::pg_catalog.regclass AND NOT t.tgisinternal
                   AND t.tgname = 'require_queue_ticket_rules' AND t.tgtype = 19
                   AND t.tgfoid = 'private.require_queue_ticket_rules()'::pg_catalog.regprocedure)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid = 'public.queue_tickets'::pg_catalog.regclass AND NOT t.tgisinternal
                      AND t.tgname = 'audit_log' AND t.tgtype = 29
                      AND t.tgfoid = 'private.audit_log()'::pg_catalog.regprocedure) THEN
    RAISE EXCEPTION 'queue_hold: triggers require_queue_ticket_rules / audit_log on queue_tickets not as queue_rules.sql made them; stop';
  END IF;
  SELECT string_agg(t.tgname::text, ', ') INTO v_bad
  FROM pg_catalog.pg_trigger t
  WHERE t.tgrelid = 'public.queue_tickets'::pg_catalog.regclass AND NOT t.tgisinternal
    AND t.tgname NOT IN ('require_queue_ticket_rules', 'audit_log', 'trg_notify_queue_tickets');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold: unexpected trigger(s) on queue_tickets: %; stop and review', v_bad;
  END IF;

  -- e) No function with the new names and another signature (PostgREST ambiguity).
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE ((p.pronamespace = 'public'::pg_catalog.regnamespace
          AND p.proname IN ('queue_hold_my_ticket', 'queue_unhold_my_ticket'))
      OR (p.pronamespace = 'private'::pg_catalog.regnamespace AND p.proname = 'queue_hold_limit'))
    AND p.oid NOT IN (SELECT s.o::oid FROM (VALUES
          (pg_catalog.to_regprocedure('public.queue_hold_my_ticket(text)')),
          (pg_catalog.to_regprocedure('public.queue_unhold_my_ticket(text)')),
          (pg_catalog.to_regprocedure('private.queue_hold_limit()'))) AS s(o)
        WHERE o IS NOT NULL);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold: function(s) with another signature already exist: %; stop and review', v_bad;
  END IF;

  -- f) The live queue_call_next takes only Waiting tickets (so it skips Held ones; H7).
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.queue_call_next(text, text)'::pg_catalog.regprocedure;
  IF pg_catalog.strpos(v_src, 'AND t.status = ''Waiting''') = 0 OR pg_catalog.strpos(v_src, 'SKIP LOCKED') = 0 THEN
    RAISE EXCEPTION 'queue_hold: the live public.queue_call_next does not look like queue_rules.sql''s (status = ''Waiting'' ... SKIP LOCKED); stop and review';
  END IF;

  -- g) Notifications (H8): if installed, the queue trigger function must react only to a
  --    Waiting INSERT, Waiting -> Serving and Serving -> No-show (so every hold step is silent).
  IF pg_catalog.to_regprocedure('private.notify_on_queue_tickets()') IS NOT NULL THEN
    SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
    WHERE p.oid = 'private.notify_on_queue_tickets()'::pg_catalog.regprocedure;
    IF pg_catalog.strpos(v_src, 'IF NEW.status IS DISTINCT FROM ''Waiting'' THEN') = 0
       OR pg_catalog.strpos(v_src, 'IF NOT ((OLD.status = ''Waiting'' AND NEW.status = ''Serving'')') = 0
       OR pg_catalog.strpos(v_src, 'OR (OLD.status = ''Serving'' AND NEW.status = ''No-show'')) THEN') = 0
       OR pg_catalog.strpos(v_src, 'Held') > 0 THEN
      RAISE EXCEPTION 'queue_hold: private.notify_on_queue_tickets is not the notifications_rules.sql version; hold steps might notify; stop and review';
    END IF;
  ELSE
    RAISE NOTICE 'queue_hold: notifications_rules.sql is not installed (private.notify_on_queue_tickets missing); nothing to check there';
  END IF;

  -- h) SECURITY DEFINER sees every row only if its owner (the running role) bypasses RLS.
  SELECT string_agg(c.relname, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  WHERE c.oid IN ('public.queue_tickets'::pg_catalog.regclass, 'public.queue_services'::pg_catalog.regclass,
                  'public.profiles'::pg_catalog.regclass, 'public.students'::pg_catalog.regclass,
                  'public.roles'::pg_catalog.regclass, 'public.programs'::pg_catalog.regclass)
    AND NOT (SELECT r2.rolbypassrls FROM pg_catalog.pg_roles r2 WHERE r2.rolname = current_user)
    AND NOT (c.relowner = (SELECT r2.oid FROM pg_catalog.pg_roles r2 WHERE r2.rolname = current_user)
             AND NOT c.relforcerowsecurity);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold: % would not bypass RLS on %; run as the table owner (postgres); stop', current_user, v_bad;
  END IF;

  -- i) No row breaks the new rules already (a re-run: Held rows must have held_at).
  IF EXISTS (SELECT 1 FROM public.queue_tickets t
             WHERE t.status NOT IN ('Waiting', 'Serving', 'Held', 'Done', 'No-show', 'Cancelled')) THEN
    RAISE EXCEPTION 'queue_hold: queue_tickets has a status outside the known ones; stop and review';
  END IF;
END
$$;

-- ------------------------------------------
-- 2. The table: column, constraints, the one-active-ticket index
-- ------------------------------------------
ALTER TABLE public.queue_tickets ADD COLUMN IF NOT EXISTS held_at timestamp with time zone;

ALTER TABLE public.queue_tickets DROP CONSTRAINT IF EXISTS ck_queue_tickets_status;
ALTER TABLE public.queue_tickets ADD CONSTRAINT ck_queue_tickets_status
  CHECK (status = ANY (ARRAY['Waiting'::text, 'Serving'::text, 'Held'::text, 'Done'::text, 'No-show'::text, 'Cancelled'::text]));

ALTER TABLE public.queue_tickets DROP CONSTRAINT IF EXISTS ck_queue_tickets_state;
ALTER TABLE public.queue_tickets ADD CONSTRAINT ck_queue_tickets_state CHECK (
    (status IN ('Waiting', 'Held') AND called_at IS NULL AND finished_at IS NULL AND handled_by IS NULL)
    OR (status = 'Serving' AND called_at IS NOT NULL AND finished_at IS NULL AND handled_by IS NOT NULL)
    OR (status IN ('Done', 'No-show') AND called_at IS NOT NULL AND finished_at IS NOT NULL AND handled_by IS NOT NULL)
    OR (status = 'No-show' AND called_at IS NULL AND finished_at IS NOT NULL AND handled_by IS NOT NULL AND window_label IS NULL)
    OR (status = 'Cancelled' AND called_at IS NULL AND finished_at IS NOT NULL));

ALTER TABLE public.queue_tickets DROP CONSTRAINT IF EXISTS ck_queue_tickets_held;
ALTER TABLE public.queue_tickets ADD CONSTRAINT ck_queue_tickets_held CHECK (
    (status = 'Held' AND held_at IS NOT NULL) OR (status <> 'Held' AND held_at IS NULL));

-- One active ticket per student per service per day, Held included (the table is locked by
-- the ALTERs above, so no ticket can slip in between the DROP and the CREATE).
DROP INDEX IF EXISTS public.uq_queue_tickets_active_student;
CREATE UNIQUE INDEX uq_queue_tickets_active_student
  ON public.queue_tickets (student_id, service_id, queue_date) WHERE status IN ('Waiting', 'Serving', 'Held');

-- ------------------------------------------
-- 3. The hold limit (one place to change it)
-- ------------------------------------------
CREATE OR REPLACE FUNCTION private.queue_hold_limit()
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT interval '15 minutes'
$function$;

REVOKE ALL ON FUNCTION private.queue_hold_limit() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------
-- 4. The status-flow trigger function (queue_rules.sql decision 7, plus H3 and H5)
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
    IF v_step NOT IN ('Waiting -> Serving', 'Waiting -> Cancelled', 'Waiting -> Held',
                      'Held -> Waiting', 'Held -> Cancelled', 'Held -> No-show',
                      'Serving -> Done', 'Serving -> No-show') THEN
      RAISE EXCEPTION 'bad ticket change: % is not allowed (ticket %)', v_step, OLD.ticket_id
        USING ERRCODE = 'P0001',
              HINT = 'Allowed: Waiting -> Serving, Held or Cancelled; Held -> Waiting, Cancelled or No-show; Serving -> Done or No-show.';
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
  ELSIF v_old = 'Held' AND v_new = 'No-show' THEN
    -- A held ticket marked No-show by the Registrar (H5): never called, no window.
    IF v_uid IS NOT NULL THEN
      NEW.handled_by := v_uid;
    END IF;
    IF NEW.window_label IS DISTINCT FROM OLD.window_label THEN
      RAISE EXCEPTION 'bad ticket change: window_label of ticket % is set only when it is called', OLD.ticket_id
        USING ERRCODE = 'P0001';
    END IF;
    NEW.called_at := OLD.called_at;
    NEW.finished_at := pg_catalog.now();
  ELSE
    IF NEW.handled_by IS DISTINCT FROM OLD.handled_by
       OR NEW.window_label IS DISTINCT FROM OLD.window_label THEN
      RAISE EXCEPTION 'bad ticket change: handled_by and window_label of ticket % are set only when it is called', OLD.ticket_id
        USING ERRCODE = 'P0001';
    END IF;
    NEW.called_at := OLD.called_at;
    IF v_new IS DISTINCT FROM v_old AND v_new IN ('Done', 'No-show', 'Cancelled') THEN
      NEW.finished_at := pg_catalog.now();
    ELSE
      NEW.finished_at := OLD.finished_at;   -- Waiting <-> Held, or no status change
    END IF;
  END IF;

  -- held_at belongs to the database (H3).
  IF v_new = 'Held' THEN
    IF v_old = 'Held' THEN
      NEW.held_at := OLD.held_at;
    ELSE
      NEW.held_at := pg_catalog.now();
    END IF;
  ELSE
    NEW.held_at := NULL;
  END IF;

  RETURN NEW;
END
$function$;

-- Same grant style as the other trigger functions (hardening2.sql section C).
REVOKE EXECUTE ON FUNCTION private.require_queue_ticket_rules() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.require_queue_ticket_rules() TO authenticated;

-- ------------------------------------------
-- 5. The callable functions (schema public, SECURITY DEFINER)
-- ------------------------------------------

-- Registrar: issue a ticket (queue_rules.sql decisions 1 to 4); a Held ticket also counts as
-- the student's active ticket.
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
    AND t.queue_date = v_today AND t.status IN ('Waiting', 'Serving', 'Held')
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

-- Registrar: finish a Serving ticket as Done or No-show, or mark a Held ticket No-show (H5).
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
  IF v_status = 'Held' THEN
    IF p_outcome <> 'No-show' THEN
      RAISE EXCEPTION 'bad ticket change: ticket % is on hold; it can only be marked No-show', p_ticket_id
        USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_status <> 'Serving' THEN
    RAISE EXCEPTION 'bad ticket change: ticket % is %; only a Serving ticket can be finished', p_ticket_id, v_status
      USING ERRCODE = 'P0001';
  END IF;

  -- finished_at (and handled_by for a held ticket) are set by the trigger.
  UPDATE public.queue_tickets AS t SET status = p_outcome WHERE t.ticket_id = p_ticket_id;
END
$function$;

-- Student: cancel the own Waiting or Held ticket of today in a service.
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
    AND t.queue_date = private.queue_today() AND t.status IN ('Waiting', 'Serving', 'Held')
  ORDER BY t.ticket_number
  LIMIT 1
  FOR UPDATE OF t;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'bad ticket change: no waiting ticket'
      USING ERRCODE = 'P0001';
  END IF;
  IF v_status = 'Serving' THEN
    RAISE EXCEPTION 'bad ticket change: ticket % is being served and cannot be cancelled', private.queue_label(v_code)
      USING ERRCODE = 'P0001';
  END IF;

  -- finished_at is set and held_at cleared by the trigger.
  UPDATE public.queue_tickets AS t SET status = 'Cancelled' WHERE t.ticket_id = v_id;
END
$function$;

-- Student: put the own Waiting ticket of today on hold (H1 to H3). Returns held_until.
CREATE OR REPLACE FUNCTION public.queue_hold_my_ticket(p_service text)
 RETURNS timestamp with time zone
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
  v_held   timestamp with time zone;
BEGIN
  v_uid := private.queue_require_role('Student');
  v_svc := private.queue_service_row(p_service);

  SELECT t.ticket_id, t.status, t.ticket_code INTO v_id, v_status, v_code
  FROM public.queue_tickets t
  WHERE t.student_id = v_uid AND t.service_id = v_svc.service_id
    AND t.queue_date = private.queue_today() AND t.status IN ('Waiting', 'Serving', 'Held')
  ORDER BY t.ticket_number
  LIMIT 1
  FOR UPDATE OF t;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'bad ticket change: no waiting ticket'
      USING ERRCODE = 'P0001';
  END IF;
  IF v_status = 'Held' THEN
    RAISE EXCEPTION 'bad ticket change: ticket % is already on hold', private.queue_label(v_code)
      USING ERRCODE = 'P0001';
  END IF;
  IF v_status <> 'Waiting' THEN
    RAISE EXCEPTION 'bad ticket change: ticket % is being served and cannot be put on hold', private.queue_label(v_code)
      USING ERRCODE = 'P0001';
  END IF;

  -- held_at = now() is set by the trigger.
  UPDATE public.queue_tickets AS t SET status = 'Held' WHERE t.ticket_id = v_id
  RETURNING t.held_at INTO v_held;

  RETURN v_held + private.queue_hold_limit();
END
$function$;

-- Student: take the own Held ticket of today off hold, within the limit (H1, H4). The
-- ticket keeps its number, so the student is ahead of everybody who came later.
CREATE OR REPLACE FUNCTION public.queue_unhold_my_ticket(p_service text)
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
  v_held   timestamp with time zone;
BEGIN
  v_uid := private.queue_require_role('Student');
  v_svc := private.queue_service_row(p_service);

  SELECT t.ticket_id, t.status, t.ticket_code, t.held_at INTO v_id, v_status, v_code, v_held
  FROM public.queue_tickets t
  WHERE t.student_id = v_uid AND t.service_id = v_svc.service_id
    AND t.queue_date = private.queue_today() AND t.status IN ('Waiting', 'Serving', 'Held')
  ORDER BY t.ticket_number
  LIMIT 1
  FOR UPDATE OF t;
  IF NOT FOUND OR v_status <> 'Held' THEN
    RAISE EXCEPTION 'bad ticket change: no ticket on hold'
      USING ERRCODE = 'P0001';
  END IF;
  IF pg_catalog.now() > v_held + private.queue_hold_limit() THEN
    RAISE EXCEPTION 'hold expired: ticket % was on hold for more than % minutes', private.queue_label(v_code),
                    (EXTRACT(EPOCH FROM private.queue_hold_limit()) / 60)::integer
      USING ERRCODE = 'P0001',
            HINT = 'Cancel the ticket and ask the Registrar for a new number.';
  END IF;

  -- held_at is cleared by the trigger.
  UPDATE public.queue_tickets AS t SET status = 'Waiting' WHERE t.ticket_id = v_id;
END
$function$;

-- Student: the own ticket of today plus aggregate numbers only. Always 1 row.
-- DROP first: the result shape changes (held_until added at the end).
DROP FUNCTION IF EXISTS public.queue_my_status(text);
CREATE OR REPLACE FUNCTION public.queue_my_status(p_service text)
 RETURNS TABLE(is_open boolean, has_ticket boolean, ticket_label text, ticket_status text, people_ahead integer, now_serving text, waiting_total integer, avg_service_seconds integer, window_label text, held_until timestamp with time zone)
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

  -- The caller's own ticket of today: the active one (Waiting / Serving / Held) first, else
  -- the latest.
  SELECT t.* INTO v_t
  FROM public.queue_tickets t
  WHERE t.student_id = v_uid AND t.service_id = v_svc.service_id AND t.queue_date = v_today
  ORDER BY (t.status IN ('Waiting', 'Serving', 'Held')) DESC, t.created_at DESC, t.ticket_id DESC
  LIMIT 1;
  v_has := FOUND;

  -- Only Waiting tickets are ever "ahead" (held ones are skipped by Call next).
  IF v_has AND v_t.status IN ('Waiting', 'Held') THEN
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
         CASE WHEN v_has AND v_t.status = 'Serving' THEN v_t.window_label END,
         CASE WHEN v_has AND v_t.status = 'Held' THEN v_t.held_at + private.queue_hold_limit() END;
END
$function$;

-- Registrar: today's tickets of a service, all statuses (Held included), ordered by number.
-- DROP first: the result shape changes (held_at added at the end).
DROP FUNCTION IF EXISTS public.queue_staff_list(text);
CREATE OR REPLACE FUNCTION public.queue_staff_list(p_service text)
 RETURNS TABLE(ticket_id bigint, ticket_label text, ticket_number integer, status text, student_id uuid, student_number text, student_name text, window_label text, created_at timestamp with time zone, called_at timestamp with time zone, finished_at timestamp with time zone, held_at timestamp with time zone)
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
         t.finished_at,
         t.held_at
  FROM public.queue_tickets t
  JOIN public.students s ON s.student_id = t.student_id
  JOIN public.profiles p ON p.profile_id = t.student_id
  WHERE t.service_id = v_svc.service_id AND t.queue_date = private.queue_today()
  ORDER BY t.ticket_number;
END
$function$;

-- Registrar: one student's card for the scan screen. already_queued_label = the student's
-- active (Waiting / Serving / Held) Enrollment ticket of today, else NULL.
-- >>> PHOTO PLACEHOLDER (queue_rules.sql): the photo path will be added here later.
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
             AND t.queue_date = private.queue_today() AND t.status IN ('Waiting', 'Serving', 'Held')
           ORDER BY t.ticket_number
           LIMIT 1)
  FROM public.students s
  JOIN public.profiles p ON p.profile_id = s.student_id
  JOIN public.programs pr ON pr.program_id = s.program_id
  WHERE s.student_id = p_student_id;
END
$function$;

REVOKE ALL ON FUNCTION public.issue_queue_ticket(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_finish(bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_cancel_my_ticket(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_hold_my_ticket(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_unhold_my_ticket(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_my_status(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_staff_list(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.queue_student_card(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_queue_ticket(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_finish(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_cancel_my_ticket(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_hold_my_ticket(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_unhold_my_ticket(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_my_status(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_staff_list(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.queue_student_card(uuid) TO authenticated;

-- ------------------------------------------
-- 6. Checks after the change (any failure rolls back the whole file)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
BEGIN
  -- a) Every queue function exists, including the new ones.
  SELECT string_agg(e.sig, ', ') INTO v_bad
  FROM (VALUES ('public.issue_queue_ticket(uuid, text)'), ('public.queue_call_next(text, text)'),
               ('public.queue_finish(bigint, text)'), ('public.queue_cancel_my_ticket(text)'),
               ('public.queue_hold_my_ticket(text)'), ('public.queue_unhold_my_ticket(text)'),
               ('public.queue_my_status(text)'), ('public.queue_staff_list(text)'),
               ('public.queue_student_card(uuid)'), ('private.queue_hold_limit()'),
               ('private.require_queue_ticket_rules()')) AS e(sig)
  WHERE pg_catalog.to_regprocedure(e.sig) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold: function(s) not created: %; rolled back', v_bad;
  END IF;

  -- b) The nine public queue functions: SECURITY DEFINER, empty search_path, owned by the
  --    running role, no PUBLIC, anon cannot execute, authenticated can.
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE p.oid IN (pg_catalog.to_regprocedure('public.issue_queue_ticket(uuid, text)'),
                  pg_catalog.to_regprocedure('public.queue_call_next(text, text)'),
                  pg_catalog.to_regprocedure('public.queue_finish(bigint, text)'),
                  pg_catalog.to_regprocedure('public.queue_cancel_my_ticket(text)'),
                  pg_catalog.to_regprocedure('public.queue_hold_my_ticket(text)'),
                  pg_catalog.to_regprocedure('public.queue_unhold_my_ticket(text)'),
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
    RAISE EXCEPTION 'queue_hold: not SECURITY DEFINER / empty search_path / owner / grants as intended: %; rolled back', v_bad;
  END IF;

  -- c) The helper is locked down; the trigger function is SECURITY INVOKER, house grants.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                 WHERE p.oid = 'private.queue_hold_limit()'::pg_catalog.regprocedure
                   AND NOT p.prosecdef AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
                   AND p.proacl IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)
                   AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
                   AND NOT pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE'))
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                    WHERE p.oid = 'private.require_queue_ticket_rules()'::pg_catalog.regprocedure
                      AND NOT p.prosecdef AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
                      AND p.proacl IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)
                      AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE'))
     OR private.queue_hold_limit() <> interval '15 minutes' THEN
    RAISE EXCEPTION 'queue_hold: private.queue_hold_limit() or private.require_queue_ticket_rules() not as intended; rolled back';
  END IF;

  -- d) Triggers on queue_tickets unchanged: require_queue_ticket_rules 19, audit_log 29, both
  --    enabled, plus at most trg_notify_queue_tickets.
  SELECT string_agg(t.tgname || ' ' || t.tgtype || ' ' || t.tgenabled::text, ', ' ORDER BY t.tgname) INTO v_bad
  FROM pg_catalog.pg_trigger t
  WHERE t.tgrelid = 'public.queue_tickets'::pg_catalog.regclass AND NOT t.tgisinternal
    AND t.tgname <> 'trg_notify_queue_tickets';
  IF v_bad IS DISTINCT FROM 'audit_log 29 O, require_queue_ticket_rules 19 O' THEN
    RAISE EXCEPTION 'queue_hold: triggers on queue_tickets not as intended ([%]); rolled back', v_bad;
  END IF;

  -- e) The column, the three CHECKs and the rebuilt index.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = 'public.queue_tickets'::pg_catalog.regclass AND a.attname = 'held_at'
                   AND NOT a.attisdropped AND NOT a.attnotnull
                   AND pg_catalog.format_type(a.atttypid, NULL) = 'timestamp with time zone')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.conname = 'ck_queue_tickets_status'
                      AND k.convalidated AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%''Held''::text%')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.conname = 'ck_queue_tickets_state'
                      AND k.convalidated AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%Held%')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.conname = 'ck_queue_tickets_held'
                      AND k.convalidated)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                    WHERE i.indexrelid = pg_catalog.to_regclass('public.uq_queue_tickets_active_student')
                      AND i.indrelid = 'public.queue_tickets'::pg_catalog.regclass AND i.indisunique AND i.indisvalid
                      AND pg_catalog.pg_get_indexdef(i.indexrelid) LIKE '%(student_id, service_id, queue_date)%Waiting%Serving%Held%') THEN
    RAISE EXCEPTION 'queue_hold: held_at, the CHECK constraints or uq_queue_tickets_active_student not as intended; rolled back';
  END IF;

  -- f) Published shapes.
  IF pg_catalog.pg_get_function_result('public.queue_my_status(text)'::pg_catalog.regprocedure)
       <> 'TABLE(is_open boolean, has_ticket boolean, ticket_label text, ticket_status text, people_ahead integer, now_serving text, waiting_total integer, avg_service_seconds integer, window_label text, held_until timestamp with time zone)'
     OR pg_catalog.pg_get_function_result('public.queue_staff_list(text)'::pg_catalog.regprocedure)
       <> 'TABLE(ticket_id bigint, ticket_label text, ticket_number integer, status text, student_id uuid, student_number text, student_name text, window_label text, created_at timestamp with time zone, called_at timestamp with time zone, finished_at timestamp with time zone, held_at timestamp with time zone)'
     OR pg_catalog.pg_get_function_result('public.queue_hold_my_ticket(text)'::pg_catalog.regprocedure) <> 'timestamp with time zone'
     OR pg_catalog.pg_get_function_result('public.queue_unhold_my_ticket(text)'::pg_catalog.regprocedure) <> 'void' THEN
    RAISE EXCEPTION 'queue_hold: a result shape is not as published; rolled back';
  END IF;

  -- g) Table privileges still: anon nothing; authenticated SELECT only; no column grants.
  IF pg_catalog.has_table_privilege('anon', 'public.queue_tickets', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR pg_catalog.has_any_column_privilege('anon', 'public.queue_tickets', 'SELECT, INSERT, UPDATE, REFERENCES')
     OR NOT pg_catalog.has_table_privilege('authenticated', 'public.queue_tickets', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.queue_tickets', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR pg_catalog.has_any_column_privilege('authenticated', 'public.queue_tickets', 'INSERT, UPDATE, REFERENCES')
     OR EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = 'public.queue_tickets'::pg_catalog.regclass
                   AND a.attnum > 0 AND NOT a.attisdropped AND a.attacl IS NOT NULL) THEN
    RAISE EXCEPTION 'queue_hold: privileges on public.queue_tickets not as intended; rolled back';
  END IF;
END
$$;

-- Ask PostgREST to reload its schema cache (sent when the transaction commits).
NOTIFY pgrst, 'reload schema';

COMMIT;


-- ------------------------------------------
-- ROLLBACK (back to queue_rules.sql's behaviour)
-- ------------------------------------------
-- Remove the hold buttons and the held_until / held_at use from the app FIRST. Step 1 puts
-- every Held ticket back to Waiting (same number; audited with actor NULL). Tickets that went
-- Held -> No-show keep called_at NULL, which the old ck_queue_tickets_state does not allow, so
-- that constraint is added back NOT VALID (still enforced for every new or changed row; those
-- final rows never change again). Old function bodies below are copied verbatim from
-- queue_rules.sql.
--
-- BEGIN;
--
-- UPDATE public.queue_tickets SET status = 'Waiting' WHERE status = 'Held';
-- DROP FUNCTION IF EXISTS public.queue_hold_my_ticket(text);
-- DROP FUNCTION IF EXISTS public.queue_unhold_my_ticket(text);
-- DROP FUNCTION IF EXISTS private.queue_hold_limit();
--
-- CREATE OR REPLACE FUNCTION private.require_queue_ticket_rules()
--  RETURNS trigger
--  LANGUAGE plpgsql
--  SECURITY INVOKER
--  SET search_path TO ''
-- AS $function$
-- DECLARE
--   v_uid  uuid := auth.uid();
--   v_old  text;
--   v_new  text;
--   v_step text;
-- BEGIN
--   IF TG_OP <> 'UPDATE' OR TG_WHEN <> 'BEFORE' OR TG_LEVEL <> 'ROW'
--      OR TG_TABLE_SCHEMA <> 'public' OR TG_TABLE_NAME <> 'queue_tickets' THEN
--     RAISE EXCEPTION 'private.require_queue_ticket_rules must be a BEFORE UPDATE FOR EACH ROW trigger on public.queue_tickets';
--   END IF;
--
--   v_old := OLD.status;
--   v_new := NEW.status;
--
--   -- What the ticket is never changes.
--   IF NEW.ticket_id IS DISTINCT FROM OLD.ticket_id
--      OR NEW.student_id IS DISTINCT FROM OLD.student_id
--      OR NEW.service_id IS DISTINCT FROM OLD.service_id
--      OR NEW.queue_date IS DISTINCT FROM OLD.queue_date
--      OR NEW.ticket_number IS DISTINCT FROM OLD.ticket_number
--      OR NEW.ticket_code IS DISTINCT FROM OLD.ticket_code
--      OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
--     RAISE EXCEPTION 'bad ticket change: the student, service, date, number, code and creation time of ticket % cannot be changed', OLD.ticket_id
--       USING ERRCODE = 'P0001';
--   END IF;
--
--   -- Final states: nothing changes any more.
--   IF v_old IN ('Done', 'No-show', 'Cancelled') THEN
--     IF pg_catalog.to_jsonb(NEW) IS DISTINCT FROM pg_catalog.to_jsonb(OLD) THEN
--       RAISE EXCEPTION 'bad ticket change: ticket % is % (final) and cannot be changed', OLD.ticket_id, v_old
--         USING ERRCODE = 'P0001',
--               HINT = 'Done, No-show and Cancelled are final. The student gets a new ticket instead.';
--     END IF;
--     RETURN NEW;
--   END IF;
--
--   -- One step of the flow.
--   IF v_new IS DISTINCT FROM v_old THEN
--     v_step := COALESCE(v_old, 'NULL') || ' -> ' || COALESCE(v_new, 'NULL');
--     IF v_step NOT IN ('Waiting -> Serving', 'Waiting -> Cancelled', 'Serving -> Done', 'Serving -> No-show') THEN
--       RAISE EXCEPTION 'bad ticket change: % is not allowed (ticket %)', v_step, OLD.ticket_id
--         USING ERRCODE = 'P0001',
--               HINT = 'Allowed: Waiting -> Serving or Cancelled; Serving -> Done or No-show.';
--     END IF;
--   END IF;
--
--   IF v_old = 'Waiting' AND v_new = 'Serving' THEN
--     -- The call: who calls it and at which window; the time is the database's.
--     IF v_uid IS NOT NULL THEN
--       NEW.handled_by := v_uid;
--     END IF;
--     NEW.window_label := NULLIF(pg_catalog.btrim(NEW.window_label), '');
--     NEW.called_at := pg_catalog.now();
--     NEW.finished_at := NULL;
--   ELSE
--     IF NEW.handled_by IS DISTINCT FROM OLD.handled_by
--        OR NEW.window_label IS DISTINCT FROM OLD.window_label THEN
--       RAISE EXCEPTION 'bad ticket change: handled_by and window_label of ticket % are set only when it is called', OLD.ticket_id
--         USING ERRCODE = 'P0001';
--     END IF;
--     NEW.called_at := OLD.called_at;
--     IF v_new IS DISTINCT FROM v_old THEN
--       NEW.finished_at := pg_catalog.now();   -- Done, No-show or Cancelled
--     ELSE
--       NEW.finished_at := OLD.finished_at;
--     END IF;
--   END IF;
--
--   RETURN NEW;
-- END
-- $function$;
--
-- -- Same grant style as the other trigger functions (hardening2.sql section C).
-- REVOKE EXECUTE ON FUNCTION private.require_queue_ticket_rules() FROM PUBLIC, anon;
-- GRANT EXECUTE ON FUNCTION private.require_queue_ticket_rules() TO authenticated;
--
-- -- Registrar: issue a ticket for a student (decisions 1 to 4).
-- -- DROP first: an earlier draft of this file had another result shape, and CREATE OR REPLACE
-- -- cannot change a result type (the grants are given again below).
-- DROP FUNCTION IF EXISTS public.issue_queue_ticket(uuid, text);
-- CREATE OR REPLACE FUNCTION public.issue_queue_ticket(p_student_id uuid, p_service text)
--  RETURNS TABLE(ticket_id bigint, ticket_label text, status text, queue_date date, people_ahead integer)
--  LANGUAGE plpgsql
--  VOLATILE
--  SECURITY DEFINER
--  SET search_path TO ''
-- AS $function$
-- #variable_conflict use_column
-- DECLARE
--   v_svc    public.queue_services;
--   v_today  date;
--   v_number integer;
--   v_code   integer;
--   v_id     bigint;
--   v_con    text;
--   i        integer;
-- BEGIN
--   PERFORM private.queue_require_role('Registrar');
--   v_svc := private.queue_service_row(p_service);
--
--   IF p_student_id IS NULL OR NOT EXISTS (
--        SELECT 1 FROM public.students s
--        JOIN public.profiles p ON p.profile_id = s.student_id
--        JOIN public.roles r ON r.role_id = p.role_id
--        WHERE s.student_id = p_student_id AND p.is_active AND r.role_name = 'Student') THEN
--     RAISE EXCEPTION 'invalid ticket request: the person is not an active student'
--       USING ERRCODE = '22023';
--   END IF;
--
--   IF NOT v_svc.is_open THEN
--     RAISE EXCEPTION 'queue closed: % is not taking new tickets now', v_svc.service_name
--       USING ERRCODE = 'P0001';
--   END IF;
--
--   v_today := private.queue_today();
--
--   -- One issue per student and service at a time (decision 3).
--   PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
--     'queue_tickets:' || v_svc.service_id::text || ':' || p_student_id::text, 0));
--
--   SELECT t.ticket_code INTO v_code
--   FROM public.queue_tickets t
--   WHERE t.student_id = p_student_id AND t.service_id = v_svc.service_id
--     AND t.queue_date = v_today AND t.status IN ('Waiting', 'Serving')
--   ORDER BY t.ticket_number
--   LIMIT 1;
--   IF FOUND THEN
--     RAISE EXCEPTION 'already queued: %', private.queue_label(v_code)
--       USING ERRCODE = 'P0001';
--   END IF;
--
--   -- The next internal number of this service today, atomically (decision 1).
--   INSERT INTO public.queue_counters AS c (service_id, queue_date, last_number)
--   VALUES (v_svc.service_id, v_today, 1)
--   ON CONFLICT ON CONSTRAINT queue_counters_pkey DO UPDATE SET last_number = c.last_number + 1
--   RETURNING c.last_number INTO v_number;
--
--   -- The random display code (decision 1a): a new draw on a code collision, 20 tries.
--   v_id := NULL;
--   FOR i IN 1..20 LOOP
--     v_code := private.queue_random_code();
--     BEGIN
--       INSERT INTO public.queue_tickets AS t (service_id, student_id, queue_date, ticket_number, ticket_code)
--       VALUES (v_svc.service_id, p_student_id, v_today, v_number, v_code)
--       RETURNING t.ticket_id INTO v_id;
--       EXIT;
--     EXCEPTION WHEN unique_violation THEN
--       GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
--       IF v_con IS DISTINCT FROM 'uq_queue_tickets_code' THEN
--         RAISE;
--       END IF;
--     END;
--   END LOOP;
--   IF v_id IS NULL THEN
--     RAISE EXCEPTION 'queue busy: try again'
--       USING ERRCODE = 'P0001';
--   END IF;
--
--   RETURN QUERY
--   SELECT v_id,
--          private.queue_label(v_code),
--          'Waiting'::text,
--          v_today,
--          (SELECT pg_catalog.count(*)::integer FROM public.queue_tickets w
--            WHERE w.service_id = v_svc.service_id AND w.queue_date = v_today
--              AND w.status = 'Waiting' AND w.ticket_number < v_number);
-- END
-- $function$;
--
-- -- Registrar: finish a Serving ticket as Done or No-show (decision 6).
-- CREATE OR REPLACE FUNCTION public.queue_finish(p_ticket_id bigint, p_outcome text)
--  RETURNS void
--  LANGUAGE plpgsql
--  VOLATILE
--  SECURITY DEFINER
--  SET search_path TO ''
-- AS $function$
-- DECLARE
--   v_status text;
-- BEGIN
--   PERFORM private.queue_require_role('Registrar');
--
--   IF p_outcome IS NULL OR p_outcome NOT IN ('Done', 'No-show') THEN
--     RAISE EXCEPTION 'invalid ticket request: the outcome must be Done or No-show, not [%]', COALESCE(pg_catalog.left(p_outcome, 40), 'NULL')
--       USING ERRCODE = '22023';
--   END IF;
--
--   SELECT t.status INTO v_status
--   FROM public.queue_tickets t
--   WHERE t.ticket_id = p_ticket_id
--   FOR UPDATE OF t;
--   IF NOT FOUND THEN
--     RAISE EXCEPTION 'bad ticket change: ticket % does not exist', COALESCE(p_ticket_id::text, 'NULL')
--       USING ERRCODE = 'P0001';
--   END IF;
--   IF v_status <> 'Serving' THEN
--     RAISE EXCEPTION 'bad ticket change: ticket % is %; only a Serving ticket can be finished', p_ticket_id, v_status
--       USING ERRCODE = 'P0001';
--   END IF;
--
--   -- finished_at is set by the trigger.
--   UPDATE public.queue_tickets AS t SET status = p_outcome WHERE t.ticket_id = p_ticket_id;
-- END
-- $function$;
--
-- -- Student: cancel the own Waiting ticket of today in a service.
-- CREATE OR REPLACE FUNCTION public.queue_cancel_my_ticket(p_service text)
--  RETURNS void
--  LANGUAGE plpgsql
--  VOLATILE
--  SECURITY DEFINER
--  SET search_path TO ''
-- AS $function$
-- DECLARE
--   v_uid    uuid;
--   v_svc    public.queue_services;
--   v_id     bigint;
--   v_status text;
--   v_code   integer;
-- BEGIN
--   v_uid := private.queue_require_role('Student');
--   v_svc := private.queue_service_row(p_service);
--
--   SELECT t.ticket_id, t.status, t.ticket_code INTO v_id, v_status, v_code
--   FROM public.queue_tickets t
--   WHERE t.student_id = v_uid AND t.service_id = v_svc.service_id
--     AND t.queue_date = private.queue_today() AND t.status IN ('Waiting', 'Serving')
--   ORDER BY t.ticket_number
--   LIMIT 1
--   FOR UPDATE OF t;
--   IF NOT FOUND THEN
--     RAISE EXCEPTION 'bad ticket change: no waiting ticket'
--       USING ERRCODE = 'P0001';
--   END IF;
--   IF v_status <> 'Waiting' THEN
--     RAISE EXCEPTION 'bad ticket change: ticket % is being served and cannot be cancelled', private.queue_label(v_code)
--       USING ERRCODE = 'P0001';
--   END IF;
--
--   -- finished_at is set by the trigger.
--   UPDATE public.queue_tickets AS t SET status = 'Cancelled' WHERE t.ticket_id = v_id;
-- END
-- $function$;
--
-- -- Student: the own ticket of today plus aggregate numbers only (decision 8). Always 1 row.
-- -- DROP first: the result shape changed during the design (window_label added).
-- DROP FUNCTION IF EXISTS public.queue_my_status(text);
-- CREATE OR REPLACE FUNCTION public.queue_my_status(p_service text)
--  RETURNS TABLE(is_open boolean, has_ticket boolean, ticket_label text, ticket_status text, people_ahead integer, now_serving text, waiting_total integer, avg_service_seconds integer, window_label text)
--  LANGUAGE plpgsql
--  STABLE
--  SECURITY DEFINER
--  SET search_path TO ''
-- AS $function$
-- #variable_conflict use_column
-- DECLARE
--   v_uid   uuid;
--   v_svc   public.queue_services;
--   v_today date;
--   v_t     public.queue_tickets;
--   v_has   boolean;
--   v_ahead integer;
--   v_now   text;
--   v_wait  integer;
--   v_avg   integer;
-- BEGIN
--   v_uid := private.queue_require_role('Student');
--   v_svc := private.queue_service_row(p_service);
--   v_today := private.queue_today();
--
--   -- The caller's own ticket of today: the active one first, else the latest.
--   SELECT t.* INTO v_t
--   FROM public.queue_tickets t
--   WHERE t.student_id = v_uid AND t.service_id = v_svc.service_id AND t.queue_date = v_today
--   ORDER BY (t.status IN ('Waiting', 'Serving')) DESC, t.created_at DESC, t.ticket_id DESC
--   LIMIT 1;
--   v_has := FOUND;
--
--   IF v_has AND v_t.status = 'Waiting' THEN
--     SELECT pg_catalog.count(*)::integer INTO v_ahead
--     FROM public.queue_tickets w
--     WHERE w.service_id = v_svc.service_id AND w.queue_date = v_today
--       AND w.status = 'Waiting' AND w.ticket_number < v_t.ticket_number;
--   ELSIF v_has AND v_t.status = 'Serving' THEN
--     v_ahead := 0;
--   ELSE
--     v_ahead := NULL;
--   END IF;
--
--   SELECT private.queue_label(t.ticket_code) INTO v_now
--   FROM public.queue_tickets t
--   WHERE t.service_id = v_svc.service_id AND t.queue_date = v_today AND t.status = 'Serving'
--   ORDER BY t.ticket_number
--   LIMIT 1;
--   IF v_now IS NULL THEN
--     SELECT private.queue_label(t.ticket_code) INTO v_now
--     FROM public.queue_tickets t
--     WHERE t.service_id = v_svc.service_id AND t.queue_date = v_today AND t.called_at IS NOT NULL
--     ORDER BY t.called_at DESC, t.ticket_number DESC
--     LIMIT 1;
--   END IF;
--
--   SELECT pg_catalog.count(*)::integer INTO v_wait
--   FROM public.queue_tickets t
--   WHERE t.service_id = v_svc.service_id AND t.queue_date = v_today AND t.status = 'Waiting';
--
--   SELECT pg_catalog.round(pg_catalog.avg(EXTRACT(EPOCH FROM (x.finished_at - x.called_at))))::integer INTO v_avg
--   FROM (SELECT t.finished_at, t.called_at
--         FROM public.queue_tickets t
--         WHERE t.service_id = v_svc.service_id AND t.queue_date = v_today AND t.status = 'Done'
--         ORDER BY t.finished_at DESC, t.ticket_id DESC
--         LIMIT 20) x;
--
--   RETURN QUERY
--   SELECT v_svc.is_open,
--          v_has,
--          CASE WHEN v_has THEN private.queue_label(v_t.ticket_code) END,
--          CASE WHEN v_has THEN v_t.status END,
--          v_ahead,
--          v_now,
--          v_wait,
--          v_avg,
--          CASE WHEN v_has AND v_t.status = 'Serving' THEN v_t.window_label END;
-- END
-- $function$;
--
-- -- DROP first: queue_hold.sql changed the result shape.
-- DROP FUNCTION IF EXISTS public.queue_staff_list(text);
-- -- Registrar: today's tickets of a service, all statuses, ordered by number.
-- CREATE OR REPLACE FUNCTION public.queue_staff_list(p_service text)
--  RETURNS TABLE(ticket_id bigint, ticket_label text, ticket_number integer, status text, student_id uuid, student_number text, student_name text, window_label text, created_at timestamp with time zone, called_at timestamp with time zone, finished_at timestamp with time zone)
--  LANGUAGE plpgsql
--  STABLE
--  SECURITY DEFINER
--  SET search_path TO ''
-- AS $function$
-- #variable_conflict use_column
-- DECLARE
--   v_svc public.queue_services;
-- BEGIN
--   PERFORM private.queue_require_role('Registrar');
--   v_svc := private.queue_service_row(p_service);
--
--   RETURN QUERY
--   SELECT t.ticket_id,
--          private.queue_label(t.ticket_code),
--          t.ticket_number,
--          t.status,
--          t.student_id,
--          s.student_number::text,
--          (p.last_name::text || ', ' || p.first_name::text),
--          t.window_label,
--          t.created_at,
--          t.called_at,
--          t.finished_at
--   FROM public.queue_tickets t
--   JOIN public.students s ON s.student_id = t.student_id
--   JOIN public.profiles p ON p.profile_id = t.student_id
--   WHERE t.service_id = v_svc.service_id AND t.queue_date = private.queue_today()
--   ORDER BY t.ticket_number;
-- END
-- $function$;
--
-- -- Registrar: one student's card for the scan screen (looked at before a ticket is issued).
-- -- Exactly one row. already_queued_label = the student's active (Waiting / Serving) ticket of
-- -- the Enrollment service today, else NULL.
-- -- >>> PHOTO PLACEHOLDER: the student's photo path will be added to this result later (a
-- -- >>> new output column, so the function will then be dropped and created again). Nothing
-- -- >>> about photos exists now.
-- CREATE OR REPLACE FUNCTION public.queue_student_card(p_student_id uuid)
--  RETURNS TABLE(student_id uuid, student_number text, student_name text, program_code text, program_name text, already_queued_label text)
--  LANGUAGE plpgsql
--  STABLE
--  SECURITY DEFINER
--  SET search_path TO ''
-- AS $function$
-- #variable_conflict use_column
-- BEGIN
--   PERFORM private.queue_require_role('Registrar');
--
--   IF p_student_id IS NULL OR NOT EXISTS (
--        SELECT 1 FROM public.students s
--        JOIN public.profiles p ON p.profile_id = s.student_id
--        JOIN public.roles r ON r.role_id = p.role_id
--        WHERE s.student_id = p_student_id AND p.is_active AND r.role_name = 'Student') THEN
--     RAISE EXCEPTION 'invalid ticket request: the person is not an active student'
--       USING ERRCODE = '22023';
--   END IF;
--
--   RETURN QUERY
--   SELECT s.student_id,
--          s.student_number::text,
--          (p.last_name::text || ', ' || p.first_name::text),
--          pr.code::text,
--          pr.name::text,
--          (SELECT private.queue_label(t.ticket_code)
--             FROM public.queue_tickets t
--             JOIN public.queue_services qs ON qs.service_id = t.service_id
--            WHERE qs.service_code = 'Enrollment' AND t.student_id = s.student_id
--              AND t.queue_date = private.queue_today() AND t.status IN ('Waiting', 'Serving')
--            ORDER BY t.ticket_number
--            LIMIT 1)
--   FROM public.students s
--   JOIN public.profiles p ON p.profile_id = s.student_id
--   JOIN public.programs pr ON pr.program_id = s.program_id
--   WHERE s.student_id = p_student_id;
-- END
-- $function$;
--
-- REVOKE ALL ON FUNCTION public.issue_queue_ticket(uuid, text) FROM PUBLIC, anon, authenticated;
-- REVOKE ALL ON FUNCTION public.queue_call_next(text, text) FROM PUBLIC, anon, authenticated;
-- REVOKE ALL ON FUNCTION public.queue_finish(bigint, text) FROM PUBLIC, anon, authenticated;
-- REVOKE ALL ON FUNCTION public.queue_cancel_my_ticket(text) FROM PUBLIC, anon, authenticated;
-- REVOKE ALL ON FUNCTION public.queue_my_status(text) FROM PUBLIC, anon, authenticated;
-- REVOKE ALL ON FUNCTION public.queue_staff_list(text) FROM PUBLIC, anon, authenticated;
-- REVOKE ALL ON FUNCTION public.queue_student_card(uuid) FROM PUBLIC, anon, authenticated;
-- GRANT EXECUTE ON FUNCTION public.issue_queue_ticket(uuid, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.queue_call_next(text, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.queue_finish(bigint, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.queue_cancel_my_ticket(text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.queue_my_status(text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.queue_staff_list(text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.queue_student_card(uuid) TO authenticated;
--
-- ALTER TABLE public.queue_tickets DROP CONSTRAINT IF EXISTS ck_queue_tickets_held;
-- ALTER TABLE public.queue_tickets DROP CONSTRAINT IF EXISTS ck_queue_tickets_status;
-- ALTER TABLE public.queue_tickets ADD CONSTRAINT ck_queue_tickets_status
--   CHECK (status = ANY (ARRAY['Waiting'::text, 'Serving'::text, 'Done'::text, 'No-show'::text, 'Cancelled'::text]));
-- ALTER TABLE public.queue_tickets DROP CONSTRAINT IF EXISTS ck_queue_tickets_state;
-- ALTER TABLE public.queue_tickets ADD CONSTRAINT ck_queue_tickets_state CHECK (
--     (status = 'Waiting' AND called_at IS NULL AND finished_at IS NULL AND handled_by IS NULL)
--     OR (status = 'Serving' AND called_at IS NOT NULL AND finished_at IS NULL AND handled_by IS NOT NULL)
--     OR (status IN ('Done', 'No-show') AND called_at IS NOT NULL AND finished_at IS NOT NULL AND handled_by IS NOT NULL)
--     OR (status = 'Cancelled' AND called_at IS NULL AND finished_at IS NOT NULL)) NOT VALID;
-- DROP INDEX IF EXISTS public.uq_queue_tickets_active_student;
-- CREATE UNIQUE INDEX uq_queue_tickets_active_student
--   ON public.queue_tickets (student_id, service_id, queue_date) WHERE status IN ('Waiting', 'Serving');
-- ALTER TABLE public.queue_tickets DROP COLUMN IF EXISTS held_at;
-- NOTIFY pgrst, 'reload schema';
--
-- COMMIT;


-- ==========================================
-- DIAGNOSTICS (read-only)
-- ==========================================
-- a) AFTER: today's held tickets per service with how long they have been held.
-- select s.service_code, t.ticket_number, '#' || t.ticket_code as label, t.held_at,
--        now() - t.held_at as held_for, now() > t.held_at + interval '15 minutes' as expired
-- from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
-- where t.status = 'Held' and t.queue_date = (now() at time zone 'Asia/Manila')::date
-- order by 1, 2;
--
-- b) AFTER: the hold steps in the audit log (latest first).
-- select l.log_id, l.created_at, l.record_id as ticket_id, l.actor_id,
--        l.old_data ->> 'status' as old_status, l.new_data ->> 'status' as new_status,
--        l.new_data ->> 'held_at' as held_at
-- from public.audit_logs l
-- where l.table_name = 'queue_tickets' and 'Held' in (l.old_data ->> 'status', l.new_data ->> 'status')
-- order by l.log_id desc limit 20;
--
-- c) BEFORE and AFTER: the constraints and the index on queue_tickets.
-- select c.conname, pg_get_constraintdef(c.oid) from pg_constraint c
-- where c.conrelid = 'public.queue_tickets'::regclass order by 1;
-- select pg_get_indexdef('public.uq_queue_tickets_active_student'::regclass);


-- ==========================================
-- MAINTENANCE (these WRITE; run only on purpose, as postgres)
-- ==========================================
-- m1) Replaces queue_rules.sql m1: close the stale tickets of earlier days, Held included
--     (Waiting / Held -> Cancelled, Serving -> No-show; finished_at by the trigger).
-- UPDATE public.queue_tickets
-- SET status = CASE status WHEN 'Serving' THEN 'No-show' ELSE 'Cancelled' END
-- WHERE queue_date < (now() AT TIME ZONE 'Asia/Manila')::date AND status IN ('Waiting', 'Serving', 'Held');
--
-- m2) Change the hold limit (example 20 minutes): CREATE OR REPLACE private.queue_hold_limit()
--     with the new interval (keep IMMUTABLE, SET search_path TO '', and run its REVOKE again).
--     queue_hold.sql's post-check (c) expects 15 minutes: update it at the same time.
