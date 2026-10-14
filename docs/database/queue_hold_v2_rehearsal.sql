-- ==========================================
-- REHEARSAL: queue_hold_v2.sql + TC-248 to TC-259 in ONE rolled-back transaction
-- ==========================================
-- 30-minute hold, automatic No-show of expired holds and its notification, the Registrar's own
-- DELETE on enrollment_items (feature/hold-and-documents). One paste, one run, ONE result row,
-- nothing committed. Run this on the live project BEFORE the live change; it must leave no
-- trace.
--
-- How to run: Supabase SQL editor, as postgres, a new tab, at a QUIET time (ALTER TABLE locks
-- public.queue_tickets until the rollback, a few seconds; TC-251 also closes real expired holds
-- inside the transaction, rolled back). Paste the whole file (from "begin;" to "rollback;") and
-- click Run on the whole tab, never a selection. If the script stops with an error, run
-- "rollback;" as its own query and send the error back.
--
-- What it does:
--   1. begin;
--   2. the body of docs/database/queue_hold_v2.sql (everything between its "BEGIN;" and
--      "COMMIT;" lines, copied verbatim by a script: safety checks, the 30-minute limit, the
--      CHECK, the trigger function, queue_finish, queue_expire_holds, the notification
--      function, the enrollment_items policy, checks after the change and its result row; the
--      NOTIFY is never sent because of the rollback). A "queue_hold_v2: ..." error here means
--      the live state is not what the file assumes: do NOT run the file live; send the error
--      back.
--   3. TC-248 to TC-259 (docs/database/queue_hold_v2_test.sql from its "begin;" line,
--      verbatim; that second "begin;" only prints a harmless WARNING "there is already a
--      transaction in progress"). The tests use throwaway queue services TCV-A .. TCV-E and a
--      throwaway term 2087-2088.
--   4. One final row: all_ok, then one cell per case, each ending in "-> OK" or "-> FAIL".
--   5. rollback; (the old limit, CHECK, functions and policies are back; all test data
--      disappears. Identity values used inside the transaction are not given back: a few
--      ticket / term / section / enrollment / notification / audit ids are skipped, which is
--      harmless.)
--
-- RUNNING ONLY THE TESTS (after the change is live): the test part starts at the line
-- "-- TESTS START HERE" and is self-contained: copy from the "begin;" line right below that
-- marker to the end of the file into a new tab and run it (or run
-- docs/database/queue_hold_v2_test.sql, which is the same). It ends in rollback.

begin;

-- ==========================================
-- THE CHANGE (body of queue_hold_v2.sql, verbatim)
-- ==========================================

-- ------------------------------------------
-- 1. Safety checks (stop before changing anything)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
  v_src text;
  v_srv text := 'service' || '_role';
BEGIN
  IF current_setting('server_version_num')::int < 170000 THEN
    RAISE EXCEPTION 'queue_hold_v2: PostgreSQL 17+ expected (REVOKE ALL includes MAINTAIN); found %', current_setting('server_version');
  END IF;

  -- a) The tables exist.
  SELECT string_agg(e.t, ', ') INTO v_bad
  FROM (VALUES ('queue_services'), ('queue_tickets'), ('notifications'), ('profiles'), ('roles'),
               ('audit_logs'), ('enrollments'), ('enrollment_items')) AS e(t)
  WHERE pg_catalog.to_regclass('public.' || e.t) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold_v2: missing table(s) public.%; stop', v_bad;
  END IF;

  -- b) The functions this file uses or replaces exist (queue_hold.sql and
  --    notifications_rules.sql are live).
  SELECT string_agg(e.sig, ', ') INTO v_bad
  FROM (VALUES ('public.queue_hold_my_ticket(text)'), ('public.queue_unhold_my_ticket(text)'),
               ('public.queue_finish(bigint, text)'), ('public.queue_call_next(text, text)'),
               ('public.queue_cancel_my_ticket(text)'), ('public.queue_my_status(text)'),
               ('private.queue_hold_limit()'), ('private.require_queue_ticket_rules()'),
               ('private.notify_on_queue_tickets()'), ('private.notify(uuid, text, text, text, text)'),
               ('private.queue_label(integer)'), ('private.queue_require_role(text)'),
               ('private.audit_log()'), ('private.current_role_name()'), ('private.active_uid()'),
               ('auth.uid()')) AS e(sig)
  WHERE pg_catalog.to_regprocedure(e.sig) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold_v2: missing function(s) %; run queue_hold.sql and notifications_rules.sql first; stop', v_bad;
  END IF;

  -- c) The server role exists (it gets EXECUTE on queue_expire_holds).
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = v_srv) THEN
    RAISE EXCEPTION 'queue_hold_v2: the server role is missing; stop';
  END IF;

  -- d) queue_tickets is as queue_hold.sql made it: held_at, and the three CHECKs with Held.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = 'public.queue_tickets'::pg_catalog.regclass AND a.attname = 'held_at'
                   AND NOT a.attisdropped AND pg_catalog.format_type(a.atttypid, NULL) = 'timestamp with time zone')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'c'
                      AND k.conname = 'ck_queue_tickets_status'
                      AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%''Held''::text%')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'c'
                      AND k.conname = 'ck_queue_tickets_state'
                      AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%Held%'
                      AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%No-show%'
                      AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%window_label IS NULL%')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'c'
                      AND k.conname = 'ck_queue_tickets_held') THEN
    RAISE EXCEPTION 'queue_hold_v2: queue_tickets.held_at or the CHECKs ck_queue_tickets_status / _state / _held are not as queue_hold.sql made them; stop and review';
  END IF;

  -- e) Triggers on queue_tickets exactly as queue_hold.sql left them.
  SELECT string_agg(t.tgname || ' ' || t.tgtype || ' ' || t.tgenabled::text || ' ' || t.tgfoid::pg_catalog.regprocedure::text, ', ' ORDER BY t.tgname) INTO v_bad
  FROM pg_catalog.pg_trigger t
  WHERE t.tgrelid = 'public.queue_tickets'::pg_catalog.regclass AND NOT t.tgisinternal;
  IF v_bad IS DISTINCT FROM 'audit_log 29 O private.audit_log(), require_queue_ticket_rules 19 O private.require_queue_ticket_rules(), trg_notify_queue_tickets 21 O private.notify_on_queue_tickets()' THEN
    RAISE EXCEPTION 'queue_hold_v2: triggers on queue_tickets not as expected ([%]); stop and review', v_bad;
  END IF;

  -- f) The live bodies are queue_hold.sql's (or this file's, on a re-run).
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'private.require_queue_ticket_rules()'::pg_catalog.regprocedure;
  IF NOT ((pg_catalog.strpos(v_src, '''Held -> No-show''') > 0 AND pg_catalog.strpos(v_src, 'held_at belongs to the database') > 0)
          OR pg_catalog.strpos(v_src, 'queue_hold_v2') > 0) THEN
    RAISE EXCEPTION 'queue_hold_v2: the live private.require_queue_ticket_rules is not queue_hold.sql''s; stop and review';
  END IF;
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.queue_finish(bigint, text)'::pg_catalog.regprocedure;
  IF pg_catalog.strpos(v_src, 'it can only be marked No-show') = 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: the live public.queue_finish is not queue_hold.sql''s; stop and review';
  END IF;
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.queue_call_next(text, text)'::pg_catalog.regprocedure;
  IF pg_catalog.strpos(v_src, 'AND t.status = ''Waiting''') = 0 OR pg_catalog.strpos(v_src, 'SKIP LOCKED') = 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: the live public.queue_call_next does not take only Waiting tickets (SKIP LOCKED); stop and review';
  END IF;
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.queue_unhold_my_ticket(text)'::pg_catalog.regprocedure;
  IF pg_catalog.strpos(v_src, 'hold expired:') = 0 OR pg_catalog.strpos(v_src, 'private.queue_hold_limit()') = 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: the live public.queue_unhold_my_ticket does not use private.queue_hold_limit(); stop and review';
  END IF;
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.queue_my_status(text)'::pg_catalog.regprocedure;
  IF pg_catalog.strpos(v_src, 'private.queue_hold_limit()') = 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: the live public.queue_my_status does not use private.queue_hold_limit(); stop and review';
  END IF;
  IF private.queue_hold_limit() NOT IN (interval '15 minutes', interval '30 minutes') THEN
    RAISE EXCEPTION 'queue_hold_v2: private.queue_hold_limit() is %, expected 15 minutes (or 30 on a re-run); stop and review', private.queue_hold_limit();
  END IF;

  -- g) Notifications (V4): the live queue trigger function must react only to a Waiting
  --    INSERT, Waiting -> Serving and Serving -> No-show (queue_hold.sql check (g)), or be
  --    this file's version (re-run).
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'private.notify_on_queue_tickets()'::pg_catalog.regprocedure;
  IF NOT ((pg_catalog.strpos(v_src, 'IF NEW.status IS DISTINCT FROM ''Waiting'' THEN') > 0
           AND pg_catalog.strpos(v_src, 'IF NOT ((OLD.status = ''Waiting'' AND NEW.status = ''Serving'')') > 0
           AND pg_catalog.strpos(v_src, 'OR (OLD.status = ''Serving'' AND NEW.status = ''No-show'')) THEN') > 0
           AND pg_catalog.strpos(v_src, 'Held') = 0)
          OR (pg_catalog.strpos(v_src, 'queue_hold_v2') > 0
              AND pg_catalog.strpos(v_src, 'OR (OLD.status = ''Held'' AND NEW.status = ''No-show''') > 0
              AND pg_catalog.strpos(v_src, '''queue_hold_expired''') > 0)) THEN
    RAISE EXCEPTION 'queue_hold_v2: private.notify_on_queue_tickets is neither the notifications_rules.sql version nor this file''s; stop and review';
  END IF;

  -- h) No queue_expire_holds with another signature (PostgREST ambiguity).
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE p.pronamespace = 'public'::pg_catalog.regnamespace AND p.proname = 'queue_expire_holds'
    AND p.oid IS DISTINCT FROM pg_catalog.to_regprocedure('public.queue_expire_holds()');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold_v2: function(s) with another signature already exist: %; stop and review', v_bad;
  END IF;

  -- i) SECURITY DEFINER sees every row only if its owner (the running role) bypasses RLS.
  SELECT string_agg(c.relname, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  WHERE c.oid IN ('public.queue_tickets'::pg_catalog.regclass, 'public.notifications'::pg_catalog.regclass,
                  'public.profiles'::pg_catalog.regclass, 'public.queue_services'::pg_catalog.regclass)
    AND NOT (SELECT r2.rolbypassrls FROM pg_catalog.pg_roles r2 WHERE r2.rolname = current_user)
    AND NOT (c.relowner = (SELECT r2.oid FROM pg_catalog.pg_roles r2 WHERE r2.rolname = current_user)
             AND NOT c.relforcerowsecurity);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold_v2: % would not bypass RLS on %; run as the table owner (postgres); stop', current_user, v_bad;
  END IF;

  -- j) enrollment_items (E): RLS on; the item rule trigger (BEFORE INSERT OR UPDATE OR DELETE
  --    ROW = 31) and the audit trigger (AFTER INSERT OR UPDATE OR DELETE ROW = 29) enabled; the
  --    audit function records auth.uid(); the DELETE policies are the student's (and this
  --    file's on a re-run), nothing else.
  IF NOT (SELECT c.relrowsecurity FROM pg_catalog.pg_class c WHERE c.oid = 'public.enrollment_items'::pg_catalog.regclass)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid = 'public.enrollment_items'::pg_catalog.regclass AND NOT t.tgisinternal
                      AND t.tgname = 'require_enrollment_item_rules' AND t.tgtype = 31 AND t.tgenabled = 'O'
                      AND t.tgfoid = 'private.require_enrollment_item_rules()'::pg_catalog.regprocedure)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid = 'public.enrollment_items'::pg_catalog.regclass AND NOT t.tgisinternal
                      AND t.tgname = 'audit_log' AND t.tgtype = 29 AND t.tgenabled = 'O'
                      AND t.tgfoid = 'private.audit_log()'::pg_catalog.regprocedure)
     OR pg_catalog.strpos((SELECT p.prosrc FROM pg_catalog.pg_proc p
                            WHERE p.oid = 'private.audit_log()'::pg_catalog.regprocedure), 'auth.uid()') = 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: enrollment_items RLS, its triggers require_enrollment_item_rules / audit_log or private.audit_log() are not as enrollment_rules.sql / hardening2.sql made them; stop';
  END IF;
  SELECT string_agg(p.policyname::text, ', ' ORDER BY p.policyname) INTO v_bad
  FROM pg_catalog.pg_policies p
  WHERE p.schemaname = 'public' AND p.tablename = 'enrollment_items' AND p.cmd IN ('DELETE', 'ALL');
  IF v_bad IS DISTINCT FROM 'enrollment_items_student_remove'
     AND v_bad IS DISTINCT FROM 'enrollment_items_registrar_delete, enrollment_items_student_remove' THEN
    RAISE EXCEPTION 'queue_hold_v2: the DELETE policies on enrollment_items are [%], expected enrollment_items_student_remove only; stop and review', v_bad;
  END IF;

  -- k) No row has a status outside the known ones.
  IF EXISTS (SELECT 1 FROM public.queue_tickets t
             WHERE t.status NOT IN ('Waiting', 'Serving', 'Held', 'Done', 'No-show', 'Cancelled')) THEN
    RAISE EXCEPTION 'queue_hold_v2: queue_tickets has a status outside the known ones; stop and review';
  END IF;

  -- l) pg_cron: information only (V5); nothing here depends on it.
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_extension x WHERE x.extname = 'pg_cron') THEN
    RAISE NOTICE 'queue_hold_v2: pg_cron is installed; the optional schedule in the header may be used';
  ELSE
    RAISE NOTICE 'queue_hold_v2: pg_cron is not installed; the app calls queue_expire_holds() (header V5)';
  END IF;
END
$$;

-- ------------------------------------------
-- 2. The hold limit: 30 minutes (one place, A)
-- ------------------------------------------
CREATE OR REPLACE FUNCTION private.queue_hold_limit()
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT interval '30 minutes'
$function$;

REVOKE ALL ON FUNCTION private.queue_hold_limit() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------
-- 3. The state CHECK: a never-called No-show may have no handler (V1)
-- ------------------------------------------
ALTER TABLE public.queue_tickets DROP CONSTRAINT IF EXISTS ck_queue_tickets_state;
ALTER TABLE public.queue_tickets ADD CONSTRAINT ck_queue_tickets_state CHECK (
    (status IN ('Waiting', 'Held') AND called_at IS NULL AND finished_at IS NULL AND handled_by IS NULL)
    OR (status = 'Serving' AND called_at IS NOT NULL AND finished_at IS NULL AND handled_by IS NOT NULL)
    OR (status IN ('Done', 'No-show') AND called_at IS NOT NULL AND finished_at IS NOT NULL AND handled_by IS NOT NULL)
    OR (status = 'No-show' AND called_at IS NULL AND finished_at IS NOT NULL AND window_label IS NULL)
    OR (status = 'Cancelled' AND called_at IS NULL AND finished_at IS NOT NULL));

-- ------------------------------------------
-- 4. The status-flow trigger function (queue_hold.sql, with V2 for Held -> No-show)
-- ------------------------------------------
CREATE OR REPLACE FUNCTION private.require_queue_ticket_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $function$
-- queue_hold_v2: Held -> No-show keeps the handled_by the statement sends (NULL = closed
-- automatically after the hold ran out).
DECLARE
  v_uid     uuid := auth.uid();
  v_old     text;
  v_new     text;
  v_step    text;
  v_expired boolean;
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
    -- A held ticket closed as No-show (V2): never called, no window. Expired = the same
    -- comparison as queue_unhold_my_ticket. handled_by is the statement's: queue_finish sends
    -- the Registrar, queue_expire_holds sends NULL.
    v_expired := pg_catalog.now() > OLD.held_at + private.queue_hold_limit();
    IF NOT v_expired AND v_uid IS NOT NULL THEN
      RAISE EXCEPTION 'hold active: ticket % is still on hold; it can be marked No-show only after the hold runs out', '#' || OLD.ticket_code::text
        USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_expired AND NEW.handled_by IS NULL THEN
      RAISE EXCEPTION 'bad ticket change: ticket % is still on hold; only an expired hold is closed without a handler', OLD.ticket_id
        USING ERRCODE = 'P0001';
    END IF;
    IF v_uid IS NOT NULL AND NEW.handled_by IS NOT NULL AND NEW.handled_by IS DISTINCT FROM v_uid THEN
      RAISE EXCEPTION 'bad ticket change: handled_by of ticket % must be the signed-in caller or empty', OLD.ticket_id
        USING ERRCODE = 'P0001';
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

  -- held_at belongs to the database (queue_hold.sql H3).
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
-- 5. queue_finish (B) and queue_expire_holds (C)
-- ------------------------------------------

-- Registrar: finish a Serving ticket as Done or No-show, or mark a Held ticket No-show once
-- its hold ran out (queue_hold_v2 B).
CREATE OR REPLACE FUNCTION public.queue_finish(p_ticket_id bigint, p_outcome text)
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid    uuid;
  v_status text;
  v_held   timestamp with time zone;
  v_code   integer;
BEGIN
  v_uid := private.queue_require_role('Registrar');

  IF p_outcome IS NULL OR p_outcome NOT IN ('Done', 'No-show') THEN
    RAISE EXCEPTION 'invalid ticket request: the outcome must be Done or No-show, not [%]', COALESCE(pg_catalog.left(p_outcome, 40), 'NULL')
      USING ERRCODE = '22023';
  END IF;

  SELECT t.status, t.held_at, t.ticket_code INTO v_status, v_held, v_code
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
    IF pg_catalog.now() <= v_held + private.queue_hold_limit() THEN
      RAISE EXCEPTION 'hold active: ticket % is on hold until % (Manila time); it can be marked No-show only after the hold runs out',
                      private.queue_label(v_code),
                      pg_catalog.to_char((v_held + private.queue_hold_limit()) AT TIME ZONE 'Asia/Manila', 'HH24:MI')
        USING ERRCODE = 'P0001',
              HINT = 'Wait until the hold runs out; the ticket is then closed automatically.';
    END IF;
    -- The handler is the Registrar (V2); finished_at is set and held_at cleared by the trigger.
    UPDATE public.queue_tickets AS t SET status = 'No-show', handled_by = v_uid WHERE t.ticket_id = p_ticket_id;
    RETURN;
  ELSIF v_status <> 'Serving' THEN
    RAISE EXCEPTION 'bad ticket change: ticket % is %; only a Serving ticket can be finished', p_ticket_id, v_status
      USING ERRCODE = 'P0001';
  END IF;

  -- finished_at is set by the trigger.
  UPDATE public.queue_tickets AS t SET status = p_outcome WHERE t.ticket_id = p_ticket_id;
END
$function$;

-- Anyone signed in (and the server role, and the owner): close every hold that ran out
-- (Held -> No-show, no handler). Returns how many were closed now (V3).
CREATE OR REPLACE FUNCTION public.queue_expire_holds()
 RETURNS integer
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_n integer;
BEGIN
  -- Rows another transaction holds (unhold, cancel, finish, a parallel call) are skipped; a
  -- later call closes them if they are still expired holds then.
  WITH due AS (
    SELECT t.ticket_id
    FROM public.queue_tickets t
    WHERE t.status = 'Held' AND pg_catalog.now() > t.held_at + private.queue_hold_limit()
    ORDER BY t.ticket_id
    FOR UPDATE OF t SKIP LOCKED
  )
  UPDATE public.queue_tickets AS t
  SET status = 'No-show', handled_by = NULL
  FROM due
  WHERE t.ticket_id = due.ticket_id AND t.status = 'Held';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$function$;

REVOKE ALL ON FUNCTION public.queue_finish(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_finish(bigint, text) TO authenticated;
REVOKE ALL ON FUNCTION public.queue_expire_holds() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_expire_holds() TO authenticated;
DO $$
BEGIN
  EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION public.queue_expire_holds() TO %I', 'service' || '_role');
END
$$;

-- ------------------------------------------
-- 6. The queue notifications: plus queue_hold_expired (D, V4)
-- ------------------------------------------
-- queue_tickets: queue_ticket, queue_turn, queue_skipped (notifications_rules.sql decision 6),
-- queue_hold_expired (queue_hold_v2).
CREATE OR REPLACE FUNCTION private.notify_on_queue_tickets()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- queue_hold_v2: Held -> No-show after the hold ran out sends queue_hold_expired.
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
              OR (OLD.status = 'Serving' AND NEW.status = 'No-show')
              OR (OLD.status = 'Held' AND NEW.status = 'No-show'
                  AND pg_catalog.now() > OLD.held_at + private.queue_hold_limit())) THEN
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
    ELSIF OLD.status = 'Held' THEN
      PERFORM private.notify(NEW.student_id, 'queue_hold_expired', 'Your hold ran out',
        'Ticket ' || v_label || ' was closed because your hold lasted over '
          || ((EXTRACT(EPOCH FROM private.queue_hold_limit()) / 60)::integer)::text
          || ' minutes. Show your QR code again at the Registrar to get a new number.',
        v_link);
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

-- Same grant style as the other trigger functions (hardening2.sql section C).
REVOKE EXECUTE ON FUNCTION private.notify_on_queue_tickets() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.notify_on_queue_tickets() TO authenticated;

-- ------------------------------------------
-- 7. enrollment_items: the Registrar's own DELETE (E, V6)
-- ------------------------------------------
DROP POLICY IF EXISTS enrollment_items_registrar_delete ON public.enrollment_items;
CREATE POLICY enrollment_items_registrar_delete ON public.enrollment_items
  AS PERMISSIVE
  FOR DELETE TO authenticated
  USING ((( SELECT private.current_role_name() AS current_role_name) = 'Registrar'::text));

-- Already granted by enrollment_rules.sql section 6 (a no-op then); DELETE needs no column list.
GRANT DELETE ON public.enrollment_items TO authenticated;

-- ------------------------------------------
-- 8. Checks after the change (any failure rolls back the whole file)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
  v_srv text := 'service' || '_role';
  v_fn  regprocedure := pg_catalog.to_regprocedure('public.queue_expire_holds()');
BEGIN
  -- a) The limit is 30 minutes and the helper is still locked down.
  IF private.queue_hold_limit() <> interval '30 minutes'
     OR pg_catalog.has_function_privilege('authenticated', 'private.queue_hold_limit()', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'private.queue_hold_limit()', 'EXECUTE') THEN
    RAISE EXCEPTION 'queue_hold_v2: private.queue_hold_limit() not as intended; rolled back';
  END IF;

  -- b) queue_finish and queue_expire_holds: SECURITY DEFINER, empty search_path, owned by the
  --    running role, no PUBLIC, anon cannot execute, authenticated can; the expiry function
  --    also for the server role, no arguments, returns integer.
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE p.oid IN (pg_catalog.to_regprocedure('public.queue_finish(bigint, text)'), v_fn)
    AND NOT (p.prosecdef
             AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
             AND p.proowner = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
             AND p.proacl IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)
             AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
             AND pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  IF v_bad IS NOT NULL OR v_fn IS NULL
     OR NOT pg_catalog.has_function_privilege(v_srv, v_fn, 'EXECUTE')
     OR (SELECT p.prorettype FROM pg_catalog.pg_proc p WHERE p.oid = v_fn) <> 'integer'::pg_catalog.regtype
     OR (SELECT p.pronargs FROM pg_catalog.pg_proc p WHERE p.oid = v_fn) <> 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: queue_finish / queue_expire_holds properties or grants not as intended (%); rolled back', COALESCE(v_bad, 'queue_expire_holds');
  END IF;

  -- c) The trigger functions: the status rule is SECURITY INVOKER, the notification one
  --    SECURITY DEFINER with the new kind; neither executable by anon.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                 WHERE p.oid = 'private.require_queue_ticket_rules()'::pg_catalog.regprocedure
                   AND NOT p.prosecdef AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
                   AND pg_catalog.strpos(p.prosrc, 'queue_hold_v2') > 0
                   AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE'))
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                    WHERE p.oid = 'private.notify_on_queue_tickets()'::pg_catalog.regprocedure
                      AND p.prosecdef AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
                      AND pg_catalog.strpos(p.prosrc, '''queue_hold_expired''') > 0
                      AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')) THEN
    RAISE EXCEPTION 'queue_hold_v2: the trigger functions are not as intended; rolled back';
  END IF;

  -- d) Triggers on queue_tickets unchanged.
  SELECT string_agg(t.tgname || ' ' || t.tgtype || ' ' || t.tgenabled::text, ', ' ORDER BY t.tgname) INTO v_bad
  FROM pg_catalog.pg_trigger t
  WHERE t.tgrelid = 'public.queue_tickets'::pg_catalog.regclass AND NOT t.tgisinternal;
  IF v_bad IS DISTINCT FROM 'audit_log 29 O, require_queue_ticket_rules 19 O, trg_notify_queue_tickets 21 O' THEN
    RAISE EXCEPTION 'queue_hold_v2: triggers on queue_tickets not as intended ([%]); rolled back', v_bad;
  END IF;

  -- e) The CHECKs are there and validated.
  IF (SELECT pg_catalog.count(*) FROM pg_catalog.pg_constraint k
       WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'c' AND k.convalidated
         AND k.conname IN ('ck_queue_tickets_status', 'ck_queue_tickets_state', 'ck_queue_tickets_held')) <> 3 THEN
    RAISE EXCEPTION 'queue_hold_v2: the CHECK constraints on queue_tickets are not as intended; rolled back';
  END IF;

  -- f) Table privileges on queue_tickets unchanged: anon nothing; authenticated SELECT only.
  IF pg_catalog.has_table_privilege('anon', 'public.queue_tickets', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR NOT pg_catalog.has_table_privilege('authenticated', 'public.queue_tickets', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.queue_tickets', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR pg_catalog.has_any_column_privilege('authenticated', 'public.queue_tickets', 'INSERT, UPDATE, REFERENCES') THEN
    RAISE EXCEPTION 'queue_hold_v2: privileges on public.queue_tickets not as intended; rolled back';
  END IF;

  -- g) enrollment_items: the new policy as intended, the student's still there, DELETE
  --    granted to authenticated, nothing for anon.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
                 WHERE p.schemaname = 'public' AND p.tablename = 'enrollment_items'
                   AND p.policyname = 'enrollment_items_registrar_delete' AND p.cmd = 'DELETE'
                   AND p.permissive = 'PERMISSIVE' AND p.roles = ARRAY['authenticated']::name[]
                   AND p.with_check IS NULL
                   AND pg_catalog.strpos(COALESCE(p.qual, ''), 'current_role_name') > 0
                   AND pg_catalog.strpos(COALESCE(p.qual, ''), '''Registrar''') > 0)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
                    WHERE p.schemaname = 'public' AND p.tablename = 'enrollment_items'
                      AND p.policyname = 'enrollment_items_student_remove' AND p.cmd = 'DELETE')
     OR NOT pg_catalog.has_table_privilege('authenticated', 'public.enrollment_items', 'DELETE')
     OR pg_catalog.has_table_privilege('anon', 'public.enrollment_items', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN') THEN
    RAISE EXCEPTION 'queue_hold_v2: enrollment_items policy or grants not as intended; rolled back';
  END IF;
END
$$;

-- One result row (all true). The DO block above already stopped on any failure.
SELECT
  (private.queue_hold_limit() = interval '30 minutes') AS limit_30,
  pg_catalog.has_function_privilege('authenticated', 'public.queue_expire_holds()', 'EXECUTE') AS expire_authenticated,
  NOT pg_catalog.has_function_privilege('anon', 'public.queue_expire_holds()', 'EXECUTE') AS expire_not_anon,
  pg_catalog.has_function_privilege('service' || '_role', 'public.queue_expire_holds()', 'EXECUTE') AS expire_server,
  EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = 'enrollment_items'
             AND p.policyname = 'enrollment_items_registrar_delete') AS registrar_delete_policy;

-- Ask PostgREST to reload its schema cache (sent when the transaction commits).
NOTIFY pgrst, 'reload schema';


-- ==========================================
-- TESTS START HERE (TC-248 to TC-259)
-- ==========================================
begin;

-- ==========================================
-- 1. Accounts, ids, throwaway services, helpers (as postgres, no user JWT)
-- ==========================================
select set_config('request.jwt.claims', '', true);
select set_config('app.none', '', true);
select set_config('app.srv',  'service' || '_role', true);
select set_config('app.s1',   coalesce((select id::text from auth.users where email = 'student1@pnc.test'), ''), true);
select set_config('app.s2',   coalesce((select id::text from auth.users where email = 'student2@pnc.test'), ''), true);
select set_config('app.s3',   coalesce((select id::text from auth.users where email = 'student3@pnc.test'), ''), true);
select set_config('app.reg',  coalesce((select id::text from auth.users where email = 'registrar@pnc.test'), ''), true);
select set_config('app.cash', coalesce((select id::text from auth.users where email = 'cashier@pnc.test'), ''), true);
select set_config('app.adm',  coalesce((select id::text from auth.users where email = 'admin@pnc.test'), ''), true);
select set_config('app.today', ((now() at time zone 'Asia/Manila')::date)::text, true);
do $$
declare v_bad text;
begin
  if to_regprocedure('public.queue_expire_holds()') is null
     or to_regprocedure('private.queue_hold_limit()') is null
     or to_regprocedure('public.queue_hold_my_ticket(text)') is null then
    raise exception 'TC setup: queue_hold_v2.sql is not installed (run it, or use queue_hold_v2_rehearsal.sql)';
  end if;
  if to_regclass('public.notifications') is null or to_regprocedure('private.notify_on_queue_tickets()') is null then
    raise exception 'TC setup: notifications_rules.sql is not installed';
  end if;
  select string_agg(v.who || ' (' || v.role_name || ')', ', ') into v_bad
  from (values ('s1', 'Student'), ('s2', 'Student'), ('s3', 'Student'), ('reg', 'Registrar'),
               ('cash', 'Cashier'), ('adm', 'Admin')) as v(who, role_name)
  where current_setting('app.' || v.who) = ''
     or not exists (select 1 from public.profiles p join public.roles r on r.role_id = p.role_id
                    where p.profile_id::text = current_setting('app.' || v.who)
                      and p.is_active and r.role_name = v.role_name)
     or (v.role_name = 'Student'
         and not exists (select 1 from public.students s where s.student_id::text = current_setting('app.' || v.who)));
  if v_bad is not null then
    raise exception 'TC setup: seed account missing, inactive or with another role: %', v_bad;
  end if;
  if exists (select 1 from public.queue_services where service_code like 'TCV-_') then
    raise exception 'TC setup: a queue service TCV-? exists; the tests need the codes TCV-A .. TCV-E free';
  end if;
  if exists (select 1 from public.terms where school_year = '2087-2088') then
    raise exception 'TC setup: a term 2087-2088 exists; the tests need that school year free';
  end if;
  if not exists (select 1 from public.subjects) then
    raise exception 'TC setup: no subject exists (TC-257 needs one)';
  end if;
end $$;
select set_config('app.log_mark', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);
-- five throwaway services, each with a free prefix letter
do $$
declare c text;
begin
  foreach c in array array['TCV-A', 'TCV-B', 'TCV-C', 'TCV-D', 'TCV-E'] loop
    insert into public.queue_services (service_code, service_name, ticket_prefix, is_open)
    select c, 'TC hold v2 queue ' || right(c, 1), chr(g), true
    from generate_series(65, 90) g
    where chr(g) not in (select ticket_prefix from public.queue_services)
    order by g desc
    limit 1;
    if not found then
      raise exception 'TC setup: no free ticket prefix letter for %', c;
    end if;
  end loop;
end $$;
select set_config('app.sve', (select service_id::text from public.queue_services where service_code = 'TCV-E'), true);

-- helpers for the checks (temporary, gone with the transaction; called as postgres only)
create function pg_temp.tid(p_svc text, p_who text) returns bigint language sql stable as $f$
  select max(t.ticket_id) from public.queue_tickets t
  join public.queue_services s on s.service_id = t.service_id
  where s.service_code = p_svc and t.student_id::text = current_setting('app.' || p_who)
    and t.queue_date = current_setting('app.today')::date
$f$;
create function pg_temp.lbl(p_id bigint) returns text language sql stable as $f$
  select coalesce((select '#' || t.ticket_code from public.queue_tickets t where t.ticket_id = p_id), 'none')
$f$;
create function pg_temp.ts(p timestamptz) returns text language sql stable as $f$
  select case when p is null then 'null' when p = now() then 'now' else 'other' end
$f$;
create function pg_temp.who(p uuid) returns text language sql stable as $f$
  select case when p is null then 'null'
              when p::text = current_setting('app.s1') then 's1'
              when p::text = current_setting('app.s2') then 's2'
              when p::text = current_setting('app.s3') then 's3'
              when p::text = current_setting('app.reg') then 'reg'
              when p::text = current_setting('app.cash') then 'cash'
              when p::text = current_setting('app.adm') then 'adm'
              else 'other' end
$f$;
create function pg_temp.st(p_id bigint) returns text language sql stable as $f$
  select coalesce((select t.status || ' #' || t.ticket_number || ' held=' || pg_temp.ts(t.held_at)
                          || ' called=' || pg_temp.ts(t.called_at) || ' fin=' || pg_temp.ts(t.finished_at)
                          || ' by=' || pg_temp.who(t.handled_by) || ' win=' || coalesce(t.window_label, 'null')
                   from public.queue_tickets t where t.ticket_id = p_id), 'none')
$f$;
create function pg_temp.nmark() returns bigint language sql stable as $f$
  select coalesce(max(n.notification_id), 0) from public.notifications n
$f$;
-- the notification kinds written after a mark (anyone), in order
create function pg_temp.nkinds(p_mark bigint) returns text language sql stable as $f$
  select coalesce(string_agg(n.kind || ':' || pg_temp.who(n.recipient_id), ',' order by n.notification_id), '')
  from public.notifications n
  where n.notification_id > p_mark and n.created_at = now()
$f$;
-- every throwaway ticket except one, as st() text (to show nothing else changed)
create function pg_temp.fp(p_skip bigint) returns text language sql stable as $f$
  select coalesce(string_agg(s.service_code || ':' || pg_temp.st(t.ticket_id), ',' order by s.service_code, t.ticket_number), '')
  from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
  where s.service_code like 'TCV-_' and t.ticket_id <> p_skip
$f$;
-- put a Held ticket's held_at p_minutes in the past (the trigger would keep it, so it is switched
-- off for this one UPDATE; the CHECKs still apply). Returns the number of rows changed.
create function pg_temp.backdate(p_id bigint, p_minutes integer) returns text language plpgsql as $f$
declare v_n integer;
begin
  alter table public.queue_tickets disable trigger require_queue_ticket_rules;
  update public.queue_tickets set held_at = now() - make_interval(mins => p_minutes)
  where ticket_id = p_id and status = 'Held';
  get diagnostics v_n = row_count;
  alter table public.queue_tickets enable trigger require_queue_ticket_rules;
  return v_n::text;
end
$f$;
-- the exact body of a queue_hold_expired notification for a label
create function pg_temp.xbody(p_label text) returns text language sql immutable as $f$
  select 'Ticket ' || p_label || ' was closed because your hold lasted over 30 minutes. Show your QR code again at the Registrar to get a new number.'
$f$;

-- ==========================================
-- 2. TC-248: installed as intended (catalog)
-- ==========================================
-- Expected: limit '00:30:00', expire_fn true, finish_fn true, state_check true, notify_fn
-- true, triggers 'audit_log 29 O, require_queue_ticket_rules 19 O, trg_notify_queue_tickets
-- 21 O', delete_policies 'enrollment_items_registrar_delete PERMISSIVE authenticated;
-- enrollment_items_student_remove PERMISSIVE authenticated', registrar_policy true, grants true.
select set_config('app.r248', (select format('limit %s, expire_fn %s, finish_fn %s, state_check %s, notify_fn %s, triggers [%s], delete_policies [%s], registrar_policy %s, items_grants %s -> %s',
    x.lim, x.expire_fn, x.finish_fn, x.state_ck, x.notify_fn, x.trg, x.del_pol, x.reg_pol, x.grants,
    case when x.lim = '00:30:00' and x.expire_fn = 'true' and x.finish_fn = 'true' and x.state_ck and x.notify_fn = 'true'
          and x.trg = 'audit_log 29 O, require_queue_ticket_rules 19 O, trg_notify_queue_tickets 21 O'
          and x.del_pol = 'enrollment_items_registrar_delete PERMISSIVE authenticated; enrollment_items_student_remove PERMISSIVE authenticated'
          and x.reg_pol and x.grants
         then 'OK' else 'FAIL' end)
  from (select
    private.queue_hold_limit()::text as lim,
    coalesce((select (p.prosecdef and p.prorettype = 'integer'::regtype and p.pronargs = 0
                      and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
                      and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
                      and not has_function_privilege('anon', p.oid, 'EXECUTE')
                      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
                      and has_function_privilege(current_setting('app.srv'), p.oid, 'EXECUTE')
                      and exists (select 1 from pg_roles r join pg_class c on c.oid = 'public.queue_tickets'::regclass
                                   where r.oid = p.proowner
                                     and (r.rolbypassrls or (c.relowner = r.oid and not c.relforcerowsecurity))))::text
                from pg_proc p where p.oid = to_regprocedure('public.queue_expire_holds()')), 'missing') as expire_fn,
    coalesce((select (p.prosecdef
                      and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
                      and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
                      and not has_function_privilege('anon', p.oid, 'EXECUTE')
                      and has_function_privilege('authenticated', p.oid, 'EXECUTE'))::text
                from pg_proc p where p.oid = to_regprocedure('public.queue_finish(bigint, text)')), 'missing') as finish_fn,
    ((select count(*) from pg_constraint k
       where k.conrelid = 'public.queue_tickets'::regclass and k.contype = 'c' and k.convalidated
         and k.conname in ('ck_queue_tickets_status', 'ck_queue_tickets_state', 'ck_queue_tickets_held')) = 3) as state_ck,
    coalesce((select (p.prosecdef and p.prosrc like '%''queue_hold_expired''%'
                      and not has_function_privilege('anon', p.oid, 'EXECUTE'))::text
                from pg_proc p where p.oid = to_regprocedure('private.notify_on_queue_tickets()')), 'missing') as notify_fn,
    coalesce((select string_agg(t.tgname || ' ' || t.tgtype || ' ' || t.tgenabled::text, ', ' order by t.tgname)
                from pg_trigger t where t.tgrelid = 'public.queue_tickets'::regclass and not t.tgisinternal), '') as trg,
    coalesce((select string_agg(p.policyname || ' ' || p.permissive || ' ' || array_to_string(p.roles, ','), '; ' order by p.policyname)
                from pg_policies p
               where p.schemaname = 'public' and p.tablename = 'enrollment_items' and p.cmd in ('DELETE', 'ALL')), '') as del_pol,
    exists (select 1 from pg_policies p
             where p.schemaname = 'public' and p.tablename = 'enrollment_items'
               and p.policyname = 'enrollment_items_registrar_delete' and p.with_check is null
               and p.qual like '%current_role_name%''Registrar''%') as reg_pol,
    (has_table_privilege('authenticated', 'public.enrollment_items', 'DELETE')
     and not has_table_privilege('anon', 'public.enrollment_items', 'SELECT, INSERT, UPDATE, DELETE')) as grants
  ) x), true);

-- ==========================================
-- 3. TC-249 and TC-254 (TCV-A): the 30-minute limit; hold steps are silent
-- ==========================================
-- Step A1: the Registrar issues A1 (s1), A2 (s2), A3 (s3).
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'ca_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCV-A') i$q$),
    (2, 'ca_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCV-A') i$q$),
    (3, 'ca_issue3', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCV-A') i$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.t_a1', coalesce(pg_temp.tid('TCV-A', 's1'), 0)::text, true);
select set_config('app.t_a2', coalesce(pg_temp.tid('TCV-A', 's2'), 0)::text, true);
select set_config('app.l_a2', pg_temp.lbl(current_setting('app.t_a2')::bigint), true);
select set_config('app.n_mark_a', pg_temp.nmark()::text, true);

-- Step A2: s1, s2, s3 hold; s1 reads the status; s3 comes back at once.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c249_hold1',   's1', $q$select (public.queue_hold_my_ticket('TCV-A') = now() + interval '30 minutes')::text$q$),
    (2, 'c249_hold2',   's2', $q$select (public.queue_hold_my_ticket('TCV-A') = now() + interval '30 minutes')::text$q$),
    (3, 'c249_hold3',   's3', $q$select (public.queue_hold_my_ticket('TCV-A') = now() + interval '30 minutes')::text$q$),
    (4, 'c249_status1', 's1', $q$select m.ticket_status || '|' || (m.held_until = now() + interval '30 minutes') from public.queue_my_status('TCV-A') m$q$),
    (5, 'c254_unhold3', 's3', $q$select 'ok'::text from public.queue_unhold_my_ticket('TCV-A')$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
-- A1 held 29 minutes ago, A2 31 minutes ago.
select set_config('app.bd_a1', pg_temp.backdate(current_setting('app.t_a1')::bigint, 29), true);
select set_config('app.bd_a2', pg_temp.backdate(current_setting('app.t_a2')::bigint, 31), true);

-- Step A3: both read their status; s1 (29 min) and s2 (31 min) try to come back; s2 cancels.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c249_status29', 's1', $q$select m.ticket_status || '|' || (m.held_until = now() + interval '1 minute') from public.queue_my_status('TCV-A') m$q$),
    (2, 'c249_status31', 's2', $q$select m.ticket_status || '|' || (m.held_until = now() - interval '1 minute') from public.queue_my_status('TCV-A') m$q$),
    (3, 'c249_unhold29', 's1', $q$select 'ok'::text from public.queue_unhold_my_ticket('TCV-A')$q$),
    (4, 'c249_unhold31', 's2', $q$select 'ok'::text from public.queue_unhold_my_ticket('TCV-A')$q$),
    (5, 'c254_cancel',   's2', $q$select 'ok'::text from public.queue_cancel_my_ticket('TCV-A')$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.c254_silent', pg_temp.nkinds(current_setting('app.n_mark_a')::bigint), true);

-- TC-249. Expected: holds 'true' (held_until = now() + 30 minutes); status 'Held|true'; backdated
-- 1 and 1 row; at 29 minutes 'Held|true' (one minute left) and unhold 'ok'; at 31 minutes
-- 'Held|true' (one minute past) and 'ERR [P0001]: hold expired: ticket L(A2) was on hold for
-- more than 30 minutes'; st(A1) 'Waiting #1 held=null ...'.
select set_config('app.r249', format('holds [%s, %s, %s], status [%s], backdated [%s, %s], at_29 [%s], unhold_29 [%s], at_31 [%s], unhold_31 [%s], a1 [%s] -> %s',
  current_setting('app.c249_hold1'), current_setting('app.c249_hold2'), current_setting('app.c249_hold3'),
  current_setting('app.c249_status1'), current_setting('app.bd_a1'), current_setting('app.bd_a2'),
  current_setting('app.c249_status29'), current_setting('app.c249_unhold29'),
  current_setting('app.c249_status31'), current_setting('app.c249_unhold31'),
  pg_temp.st(current_setting('app.t_a1')::bigint),
  case when current_setting('app.c249_hold1') = 'true' and current_setting('app.c249_hold2') = 'true'
        and current_setting('app.c249_hold3') = 'true' and current_setting('app.c249_status1') = 'Held|true'
        and current_setting('app.bd_a1') = '1' and current_setting('app.bd_a2') = '1'
        and current_setting('app.c249_status29') = 'Held|true' and current_setting('app.c249_unhold29') = 'ok'
        and current_setting('app.c249_status31') = 'Held|true'
        and current_setting('app.c249_unhold31') = format('ERR [P0001]: hold expired: ticket %s was on hold for more than 30 minutes', current_setting('app.l_a2'))
        and pg_temp.st(current_setting('app.t_a1')::bigint) = 'Waiting #1 held=null called=null fin=null by=null win=null'
       then 'OK' else 'FAIL' end), true);

-- TC-254. Expected: s3's unhold 'ok', s2's cancel of the held (expired) A2 'ok', st(A2)
-- 'Cancelled #2 held=null called=null fin=now by=null win=null', and NO notification for
-- anyone after the mark (three holds, two unholds, a refused unhold, a cancel).
select set_config('app.r254', format('unhold [%s], cancel [%s], a2 [%s], notifications [%s] -> %s',
  current_setting('app.c254_unhold3'), current_setting('app.c254_cancel'),
  pg_temp.st(current_setting('app.t_a2')::bigint), current_setting('app.c254_silent'),
  case when current_setting('app.c254_unhold3') = 'ok' and current_setting('app.c254_cancel') = 'ok'
        and pg_temp.st(current_setting('app.t_a2')::bigint) = 'Cancelled #2 held=null called=null fin=now by=null win=null'
        and current_setting('app.c254_silent') = ''
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 4. TC-250 (TCV-B): the Registrar's No-show of a held ticket
-- ==========================================
-- Step B1: B1 (s1), B2 (s2), B3 (s3) issued; s1 and s2 hold.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'cb_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCV-B') i$q$),
    (2, 'cb_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCV-B') i$q$),
    (3, 'cb_issue3', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCV-B') i$q$),
    (4, 'cb_hold1',  's1',  $q$select public.queue_hold_my_ticket('TCV-B')::text$q$),
    (5, 'cb_hold2',  's2',  $q$select public.queue_hold_my_ticket('TCV-B')::text$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.t_b1', coalesce(pg_temp.tid('TCV-B', 's1'), 0)::text, true);
select set_config('app.t_b2', coalesce(pg_temp.tid('TCV-B', 's2'), 0)::text, true);
select set_config('app.l_b1', pg_temp.lbl(current_setting('app.t_b1')::bigint), true);
select set_config('app.l_b2', pg_temp.lbl(current_setting('app.t_b2')::bigint), true);
-- B1 held 10 minutes ago, B2 31 minutes ago.
select set_config('app.bd_b1', pg_temp.backdate(current_setting('app.t_b1')::bigint, 10), true);
select set_config('app.bd_b2', pg_temp.backdate(current_setting('app.t_b2')::bigint, 31), true);
select set_config('app.n_mark_b', pg_temp.nmark()::text, true);

-- Step B2: No-show at 10 minutes; a student tries; Done on the expired hold; No-show at 31
-- minutes; again.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c250_at10',    'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_b1')::bigint, 'No-show')$q$),
    (2, 'c250_student', 's1',  $q$select 'done'::text from public.queue_finish(current_setting('app.t_b2')::bigint, 'No-show')$q$),
    (3, 'c250_done',    'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_b2')::bigint, 'Done')$q$),
    (4, 'c250_at31',    'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_b2')::bigint, 'No-show')$q$),
    (5, 'c250_again',   'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_b2')::bigint, 'No-show')$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.c253_reg_kinds', pg_temp.nkinds(current_setting('app.n_mark_b')::bigint), true);
select set_config('app.c253_reg_note', coalesce((
  select string_agg(pg_temp.who(n.recipient_id) || '|' || n.title || '|' || n.body || '|' || coalesce(n.link, 'NULL'), ' ;; ')
  from public.notifications n
  where n.notification_id > current_setting('app.n_mark_b')::bigint and n.kind = 'queue_hold_expired'), 'none'), true);

-- TC-250. Expected: at 10 minutes 'ERR [P0001]: hold active: ticket L(B1) is on hold until
-- <now() + 20 min, Manila HH24:MI> (Manila time); it can be marked No-show only after the hold
-- runs out'; the student 'ERR [42501]: not allowed: ...'; Done 'ERR [P0001]: bad ticket change:
-- ticket <B2 id> is on hold; it can only be marked No-show'; at 31 minutes 'done'; again 'ERR
-- [P0001]: bad ticket change: ticket <B2 id> is No-show; only a Serving ticket can be
-- finished'; st(B1) still Held (held=other); st(B2) 'No-show #2 held=null called=null fin=now
-- by=reg win=null'.
select set_config('app.r250', format('backdated [%s, %s], at_10 [%s], student [%s], done [%s], at_31 [%s], again [%s], b1 [%s], b2 [%s] -> %s',
  current_setting('app.bd_b1'), current_setting('app.bd_b2'),
  current_setting('app.c250_at10'), current_setting('app.c250_student'), current_setting('app.c250_done'),
  current_setting('app.c250_at31'), current_setting('app.c250_again'),
  pg_temp.st(current_setting('app.t_b1')::bigint), pg_temp.st(current_setting('app.t_b2')::bigint),
  case when current_setting('app.bd_b1') = '1' and current_setting('app.bd_b2') = '1'
        and current_setting('app.c250_at10') = format('ERR [P0001]: hold active: ticket %s is on hold until %s (Manila time); it can be marked No-show only after the hold runs out',
                                                      current_setting('app.l_b1'),
                                                      to_char((now() + interval '20 minutes') at time zone 'Asia/Manila', 'HH24:MI'))
        and current_setting('app.c250_student') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c250_done') = format('ERR [P0001]: bad ticket change: ticket %s is on hold; it can only be marked No-show', current_setting('app.t_b2'))
        and current_setting('app.c250_at31') = 'done'
        and current_setting('app.c250_again') = format('ERR [P0001]: bad ticket change: ticket %s is No-show; only a Serving ticket can be finished', current_setting('app.t_b2'))
        and pg_temp.st(current_setting('app.t_b1')::bigint) = 'Held #1 held=other called=null fin=null by=null win=null'
        and pg_temp.st(current_setting('app.t_b2')::bigint) = 'No-show #2 held=null called=null fin=now by=reg win=null'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 5. TC-252 (TCV-C): Call next never serves a held ticket
-- ==========================================
-- Step C1: C1 (s1), C2 (s2), C3 (s3) issued; s1 and s2 hold.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'cc_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCV-C') i$q$),
    (2, 'cc_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCV-C') i$q$),
    (3, 'cc_issue3', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCV-C') i$q$),
    (4, 'cc_hold1',  's1',  $q$select public.queue_hold_my_ticket('TCV-C')::text$q$),
    (5, 'cc_hold2',  's2',  $q$select public.queue_hold_my_ticket('TCV-C')::text$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.t_c1', coalesce(pg_temp.tid('TCV-C', 's1'), 0)::text, true);
select set_config('app.t_c2', coalesce(pg_temp.tid('TCV-C', 's2'), 0)::text, true);
select set_config('app.t_c3', coalesce(pg_temp.tid('TCV-C', 's3'), 0)::text, true);
select set_config('app.l_c1', pg_temp.lbl(current_setting('app.t_c1')::bigint), true);
select set_config('app.l_c3', pg_temp.lbl(current_setting('app.t_c3')::bigint), true);
-- C1 held 31 minutes ago (expired, not closed yet), C2 29 minutes ago.
select set_config('app.bd_c1', pg_temp.backdate(current_setting('app.t_c1')::bigint, 31), true);
select set_config('app.bd_c2', pg_temp.backdate(current_setting('app.t_c2')::bigint, 29), true);

-- Step C2: Call next (skips C1 and C2), Done, Call next with only held tickets left.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c252_call1', 'reg', $q$select c.ticket_label from public.queue_call_next('TCV-C', 'W1') c$q$),
    (2, 'c252_fin',   'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_c3')::bigint, 'Done')$q$),
    (3, 'c252_call2', 'reg', $q$select c.ticket_label from public.queue_call_next('TCV-C', 'W1') c$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- TC-252. Expected: first call L(C3); Done 'done'; second call 'NULL' (no row); C1 and C2 still
-- 'Held ... held=other called=null fin=null by=null win=null'; C3 'Done #3 held=null called=now
-- fin=now by=reg win=W1'.
select set_config('app.r252', format('backdated [%s, %s], call1 [%s], done [%s], call2 [%s], c1 [%s], c2 [%s], c3 [%s] -> %s',
  current_setting('app.bd_c1'), current_setting('app.bd_c2'),
  current_setting('app.c252_call1'), current_setting('app.c252_fin'), current_setting('app.c252_call2'),
  pg_temp.st(current_setting('app.t_c1')::bigint), pg_temp.st(current_setting('app.t_c2')::bigint),
  pg_temp.st(current_setting('app.t_c3')::bigint),
  case when current_setting('app.bd_c1') = '1' and current_setting('app.bd_c2') = '1'
        and current_setting('app.c252_call1') = current_setting('app.l_c3')
        and current_setting('app.c252_fin') = 'done' and current_setting('app.c252_call2') = 'NULL'
        and pg_temp.st(current_setting('app.t_c1')::bigint) = 'Held #1 held=other called=null fin=null by=null win=null'
        and pg_temp.st(current_setting('app.t_c2')::bigint) = 'Held #2 held=other called=null fin=null by=null win=null'
        and pg_temp.st(current_setting('app.t_c3')::bigint) = 'Done #3 held=null called=now fin=now by=reg win=W1'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 6. TC-251 (TCV-D plus everything above): queue_expire_holds
-- ==========================================
-- Step D1: D1 (s1) Done, D2 (s2) Serving, D3 (s3) Waiting.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'cd_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCV-D') i$q$),
    (2, 'cd_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCV-D') i$q$),
    (3, 'cd_issue3', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCV-D') i$q$),
    (4, 'cd_call1',  'reg', $q$select c.ticket_label from public.queue_call_next('TCV-D', 'W2') c$q$),
    (5, 'cd_fin1',   'reg', $q$select 'done'::text from public.queue_finish((select t.ticket_id from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id where s.service_code = 'TCV-D' and t.status = 'Serving'), 'Done')$q$),
    (6, 'cd_call2',  'reg', $q$select c.ticket_label from public.queue_call_next('TCV-D', 'W2') c$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.d_states', coalesce((select string_agg(t.ticket_number || ':' || t.status, ',' order by t.ticket_number)
  from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id where s.service_code = 'TCV-D'), ''), true);
-- Before: every throwaway ticket except C1, the real expired holds ("pre"), the marks.
select set_config('app.fp_before', pg_temp.fp(current_setting('app.t_c1')::bigint), true);
select set_config('app.pre', (select count(*) from public.queue_tickets t
  join public.queue_services s on s.service_id = t.service_id
  where t.status = 'Held' and now() > t.held_at + private.queue_hold_limit() and s.service_code not like 'TCV-_')::text, true);
select set_config('app.n_mark_d', pg_temp.nmark()::text, true);
select set_config('app.log_mark_d', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);

-- Step D2: a Student calls the expiry, then the Registrar calls it again.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c251_first',  's3',  $q$select public.queue_expire_holds()::text$q$),
    (2, 'c251_second', 'reg', $q$select public.queue_expire_holds()::text$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.c251_audit', coalesce((
  select string_agg(l.action || ':' || pg_temp.who(l.actor_id) || ':' || (l.old_data ->> 'status') || '->' || (l.new_data ->> 'status'), ',')
  from public.audit_logs l
  where l.log_id > current_setting('app.log_mark_d')::bigint and l.table_name = 'queue_tickets'
    and l.record_id = current_setting('app.t_c1')), 'none'), true);
-- The automatic-close notifications about throwaway tickets (real expired holds are ignored).
select set_config('app.c253_auto_note', coalesce((
  select string_agg(pg_temp.who(n.recipient_id) || '|' || n.title || '|' || n.body || '|' || coalesce(n.link, 'NULL'), ' ;; ' order by n.notification_id)
  from public.notifications n
  where n.notification_id > current_setting('app.n_mark_d')::bigint and n.kind = 'queue_hold_expired'
    and exists (select 1 from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
                 where s.service_code like 'TCV-_' and n.body like 'Ticket #' || t.ticket_code || ' %')), 'none'), true);
select set_config('app.c251_other_kinds', coalesce((
  select string_agg(n.kind || ':' || pg_temp.who(n.recipient_id), ',' order by n.notification_id)
  from public.notifications n
  where n.notification_id > current_setting('app.n_mark_d')::bigint and n.kind <> 'queue_hold_expired'), ''), true);

-- TC-251. Expected: TCV-D '1:Done,2:Serving,3:Waiting'; first call = pre + 1; second '0';
-- st(C1) 'No-show #1 held=null called=null fin=now by=null win=null'; every other throwaway
-- ticket unchanged (A Waiting / Cancelled, B Held 10 min and No-show, C2 Held 29 min, C3 Done,
-- D Done / Serving / Waiting); the audit row of C1 'UPDATE:s3:Held->No-show' (the caller is
-- the actor); no other notification kind was written.
select set_config('app.r251', format('tcv_d [%s], pre %s, first [%s], second [%s], c1 [%s], others_unchanged %s, audit [%s], other_kinds [%s] -> %s',
  current_setting('app.d_states'), current_setting('app.pre'), current_setting('app.c251_first'),
  current_setting('app.c251_second'), pg_temp.st(current_setting('app.t_c1')::bigint),
  (pg_temp.fp(current_setting('app.t_c1')::bigint) = current_setting('app.fp_before')),
  current_setting('app.c251_audit'), current_setting('app.c251_other_kinds'),
  case when current_setting('app.d_states') = '1:Done,2:Serving,3:Waiting'
        and current_setting('app.c251_first') = (current_setting('app.pre')::integer + 1)::text
        and current_setting('app.c251_second') = '0'
        and pg_temp.st(current_setting('app.t_c1')::bigint) = 'No-show #1 held=null called=null fin=now by=null win=null'
        and pg_temp.fp(current_setting('app.t_c1')::bigint) = current_setting('app.fp_before')
        and current_setting('app.c251_audit') = 'UPDATE:s3:Held->No-show'
        and current_setting('app.c251_other_kinds') = ''
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 7. TC-256 (TCV-E) and the owner's maintenance No-show of B1
-- ==========================================
insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, status, held_at)
values (current_setting('app.sve')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 9001, 1000001, 'Held', now());
select set_config('app.t_e1', (select ticket_id::text from public.queue_tickets where service_id = current_setting('app.sve')::bigint and ticket_number = 9001), true);
select set_config('app.l_e1', pg_temp.lbl(current_setting('app.t_e1')::bigint), true);
select set_config('app.n_mark_e', pg_temp.nmark()::text, true);
do $$
declare r record;
begin
  for r in select * from (values
    (1, 'c256_running', $q$update public.queue_tickets set status = 'No-show' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (2, 'c253_maint',   $q$update public.queue_tickets set status = 'No-show', handled_by = current_setting('app.reg')::uuid where ticket_id = current_setting('app.t_b1')::bigint$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      perform set_config('app.' || r.label, 'ok', true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.c253_maint_kinds', pg_temp.nkinds(current_setting('app.n_mark_e')::bigint), true);
select set_config('app.bd_e1', pg_temp.backdate(current_setting('app.t_e1')::bigint, 31), true);
select set_config('app.n_mark_e2', pg_temp.nmark()::text, true);
do $$
declare r record;
begin
  for r in select * from (values
    (1, 'c256_expired', $q$update public.queue_tickets set status = 'No-show' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (2, 'c256_final',   $q$update public.queue_tickets set status = 'Held' where ticket_id = current_setting('app.t_e1')::bigint$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      perform set_config('app.' || r.label, 'ok', true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.c253_owner_kinds', pg_temp.nkinds(current_setting('app.n_mark_e2')::bigint), true);

-- TC-256. Expected: while the hold runs 'ERR [P0001]: bad ticket change: ticket <E1 id> is still
-- on hold; only an expired hold is closed without a handler'; backdated 1; after it ran out
-- 'ok' -> 'No-show #9001 held=null called=null fin=now by=null win=null'; then 'ERR [P0001]:
-- bad ticket change: ... (final) ...'.
select set_config('app.r256', format('running [%s], backdated [%s], expired [%s], e1 [%s], final [%s] -> %s',
  current_setting('app.c256_running'), current_setting('app.bd_e1'), current_setting('app.c256_expired'),
  pg_temp.st(current_setting('app.t_e1')::bigint), current_setting('app.c256_final'),
  case when current_setting('app.c256_running') = format('ERR [P0001]: bad ticket change: ticket %s is still on hold; only an expired hold is closed without a handler', current_setting('app.t_e1'))
        and current_setting('app.bd_e1') = '1' and current_setting('app.c256_expired') = 'ok'
        and pg_temp.st(current_setting('app.t_e1')::bigint) = 'No-show #9001 held=null called=null fin=now by=null win=null'
        and current_setting('app.c256_final') like 'ERR [P0001]: bad ticket change:%(final)%'
       then 'OK' else 'FAIL' end), true);

-- TC-253. Expected: Registrar No-show (TC-250) kinds 'queue_hold_expired:s2' and note
-- 's2|Your hold ran out|<xbody(L(B2))>|NULL'; automatic close (TC-251) 's1|Your hold ran
-- out|<xbody(L(C1))>|NULL' exactly once (after both calls); the owner's early No-show of B1
-- (10 minutes, with a handler) 'ok' and silent ''; st(B1) 'No-show #1 held=null called=null
-- fin=now by=reg win=null'; the owner's close of the expired E1 'queue_hold_expired:s1'.
select set_config('app.r253', format('registrar_kinds [%s], registrar_note [%s], auto_note [%s], maint [%s], maint_kinds [%s], b1 [%s], owner_expired_kinds [%s] -> %s',
  current_setting('app.c253_reg_kinds'), current_setting('app.c253_reg_note'), current_setting('app.c253_auto_note'),
  current_setting('app.c253_maint'), current_setting('app.c253_maint_kinds'), pg_temp.st(current_setting('app.t_b1')::bigint),
  current_setting('app.c253_owner_kinds'),
  case when current_setting('app.c253_reg_kinds') = 'queue_hold_expired:s2'
        and current_setting('app.c253_reg_note') = 's2|Your hold ran out|' || pg_temp.xbody(current_setting('app.l_b2')) || '|NULL'
        and current_setting('app.c253_auto_note') = 's1|Your hold ran out|' || pg_temp.xbody(current_setting('app.l_c1')) || '|NULL'
        and current_setting('app.c253_maint') = 'ok' and current_setting('app.c253_maint_kinds') = ''
        and pg_temp.st(current_setting('app.t_b1')::bigint) = 'No-show #1 held=null called=null fin=now by=reg win=null'
        and current_setting('app.c253_owner_kinds') = 'queue_hold_expired:s1'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 8. TC-255: who may call queue_expire_holds; no direct table writes
-- ==========================================
set local role anon;
do $$
begin
  begin
    perform public.queue_expire_holds();
    perform set_config('app.c255_anon', 'ALLOWED', true);
  exception when others then
    perform set_config('app.c255_anon', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
  end;
end $$;
reset role;
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1,  'c255_cash',     'cash', $q$select public.queue_expire_holds()::text$q$),
    (2,  'c255_adm',      'adm',  $q$select public.queue_expire_holds()::text$q$),
    (3,  'c255_none',     'none', $q$select public.queue_expire_holds()::text$q$),
    (4,  'c255_s_update', 's1',   $q$update public.queue_tickets set status = 'No-show' where ticket_id = current_setting('app.t_c2')::bigint returning 'x'::text$q$),
    (5,  'c255_s_insert', 's1',   $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code) values (current_setting('app.sve')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 9101, 1000101) returning 'x'::text$q$),
    (6,  'c255_s_delete', 's1',   $q$delete from public.queue_tickets where ticket_id = current_setting('app.t_c2')::bigint returning 'x'::text$q$),
    (7,  'c255_r_update', 'reg',  $q$update public.queue_tickets set status = 'No-show' where ticket_id = current_setting('app.t_c2')::bigint returning 'x'::text$q$),
    (8,  'c255_r_insert', 'reg',  $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code) values (current_setting('app.sve')::bigint, current_setting('app.s2')::uuid, current_setting('app.today')::date, 9102, 1000102) returning 'x'::text$q$),
    (9,  'c255_r_delete', 'reg',  $q$delete from public.queue_tickets where ticket_id = current_setting('app.t_c2')::bigint returning 'x'::text$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      case when r.who = 'none' then ''
           else json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text end, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
-- Expected: anon 'ERR [42501]: permission denied for function queue_expire_holds'; Cashier,
-- Admin, no JWT '0'; the server role has EXECUTE, PUBLIC has none; the six direct writes
-- 'ERR [42501]: permission denied for table queue_tickets'; C2 still Held.
select set_config('app.r255', format('anon [%s], cashier [%s], admin [%s], no_jwt [%s], server %s, public_none %s, writes [%s; %s; %s; %s; %s; %s], c2 [%s] -> %s',
  current_setting('app.c255_anon'), current_setting('app.c255_cash'), current_setting('app.c255_adm'),
  current_setting('app.c255_none'),
  has_function_privilege(current_setting('app.srv'), 'public.queue_expire_holds()', 'EXECUTE'),
  not exists (select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a
               where p.oid = 'public.queue_expire_holds()'::regprocedure and a.grantee = 0),
  current_setting('app.c255_s_update'), current_setting('app.c255_s_insert'), current_setting('app.c255_s_delete'),
  current_setting('app.c255_r_update'), current_setting('app.c255_r_insert'), current_setting('app.c255_r_delete'),
  pg_temp.st(current_setting('app.t_c2')::bigint),
  case when current_setting('app.c255_anon') = 'ERR [42501]: permission denied for function queue_expire_holds'
        and current_setting('app.c255_cash') = '0' and current_setting('app.c255_adm') = '0'
        and current_setting('app.c255_none') = '0'
        and has_function_privilege(current_setting('app.srv'), 'public.queue_expire_holds()', 'EXECUTE')
        and not exists (select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a
                         where p.oid = 'public.queue_expire_holds()'::regprocedure and a.grantee = 0)
        and current_setting('app.c255_s_update') = 'ERR [42501]: permission denied for table queue_tickets'
        and current_setting('app.c255_s_insert') = 'ERR [42501]: permission denied for table queue_tickets'
        and current_setting('app.c255_s_delete') = 'ERR [42501]: permission denied for table queue_tickets'
        and current_setting('app.c255_r_update') = 'ERR [42501]: permission denied for table queue_tickets'
        and current_setting('app.c255_r_insert') = 'ERR [42501]: permission denied for table queue_tickets'
        and current_setting('app.c255_r_delete') = 'ERR [42501]: permission denied for table queue_tickets'
        and pg_temp.st(current_setting('app.t_c2')::bigint) = 'Held #2 held=other called=null fin=null by=null win=null'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 9. TC-257 to TC-259: deleting enrollment items (throwaway term 2087-2088)
-- ==========================================
-- As postgres: a term (not current), two sections of the lowest subject, three enrollments
-- with items (owner path: the item trigger still requires Pending, same term, no duplicate),
-- then s3's enrollment approved (owner path: reviewer given).
insert into public.terms (school_year, semester, start_date, end_date, is_current)
values ('2087-2088', '2nd', date '2088-01-10', date '2088-05-20', false);
select set_config('app.term', (select term_id::text from public.terms where school_year = '2087-2088' and semester = '2nd'), true);
insert into public.sections (subject_id, term_id, section_code, schedule, capacity)
select (select min(s.subject_id) from public.subjects s), current_setting('app.term')::bigint, v.code, 'MWF 7:00-8:00', 40
from (values ('Z248A'), ('Z248B')) as v(code);
select set_config('app.sec_a', (select section_id::text from public.sections where term_id = current_setting('app.term')::bigint and section_code = 'Z248A'), true);
select set_config('app.sec_b', (select section_id::text from public.sections where term_id = current_setting('app.term')::bigint and section_code = 'Z248B'), true);
insert into public.enrollments (student_id, term_id, year_level)
select current_setting('app.' || v.who)::uuid, current_setting('app.term')::bigint, 1
from (values ('s1'), ('s2'), ('s3')) as v(who);
select set_config('app.e_' || v.who, (select enrollment_id::text from public.enrollments
  where term_id = current_setting('app.term')::bigint and student_id::text = current_setting('app.' || v.who)), true)
from (values ('s1'), ('s2'), ('s3')) as v(who);
insert into public.enrollment_items (enrollment_id, section_id)
values (current_setting('app.e_s1')::bigint, current_setting('app.sec_a')::bigint),
       (current_setting('app.e_s1')::bigint, current_setting('app.sec_b')::bigint),
       (current_setting('app.e_s2')::bigint, current_setting('app.sec_a')::bigint),
       (current_setting('app.e_s3')::bigint, current_setting('app.sec_a')::bigint);
select set_config('app.i1', (select enrollment_item_id::text from public.enrollment_items where enrollment_id = current_setting('app.e_s1')::bigint and section_id = current_setting('app.sec_a')::bigint), true);
select set_config('app.i2', (select enrollment_item_id::text from public.enrollment_items where enrollment_id = current_setting('app.e_s1')::bigint and section_id = current_setting('app.sec_b')::bigint), true);
select set_config('app.i3', (select enrollment_item_id::text from public.enrollment_items where enrollment_id = current_setting('app.e_s2')::bigint), true);
select set_config('app.i4', (select enrollment_item_id::text from public.enrollment_items where enrollment_id = current_setting('app.e_s3')::bigint), true);
update public.enrollments set status = 'Approved', reviewed_by = current_setting('app.reg')::uuid
where enrollment_id = current_setting('app.e_s3')::bigint;
select set_config('app.e3_status', (select status::text from public.enrollments where enrollment_id = current_setting('app.e_s3')::bigint), true);
select set_config('app.log_mark_e', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);

-- The DELETEs through the API (user sessions), then anon.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c257_reg',        'reg',  $q$with d as (delete from public.enrollment_items where enrollment_item_id = current_setting('app.i1')::bigint returning 1) select count(*)::text from d$q$),
    (2, 'c258_reg_locked', 'reg',  $q$with d as (delete from public.enrollment_items where enrollment_item_id = current_setting('app.i4')::bigint returning 1) select count(*)::text from d$q$),
    (3, 'c259_other',      's1',   $q$with d as (delete from public.enrollment_items where enrollment_item_id = current_setting('app.i3')::bigint returning 1) select count(*)::text from d$q$),
    (4, 'c259_cashier',    'cash', $q$with d as (delete from public.enrollment_items where enrollment_item_id = current_setting('app.i3')::bigint returning 1) select count(*)::text from d$q$),
    (5, 'c259_own',        's1',   $q$with d as (delete from public.enrollment_items where enrollment_item_id = current_setting('app.i2')::bigint returning 1) select count(*)::text from d$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
do $$
begin
  begin
    delete from public.enrollment_items where enrollment_item_id = current_setting('app.i3')::bigint;
    perform set_config('app.c259_anon', 'ALLOWED', true);
  exception when others then
    perform set_config('app.c259_anon', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
  end;
end $$;
reset role;
-- What is left and what the audit log says (as postgres).
select set_config('app.items_left', coalesce((select string_agg(v.k, ',' order by v.k)
  from (values ('i1'), ('i2'), ('i3'), ('i4')) as v(k)
  where exists (select 1 from public.enrollment_items i where i.enrollment_item_id::text = current_setting('app.' || v.k))), ''), true);
create function pg_temp.del_audit(p_item text) returns text language sql stable as $f$
  select coalesce(string_agg(pg_temp.who(l.actor_id), ',' order by l.log_id), 'none')
  from public.audit_logs l
  where l.log_id > current_setting('app.log_mark_e')::bigint and l.table_name = 'enrollment_items'
    and l.action = 'DELETE' and l.record_id = p_item
$f$;

-- TC-257. Expected: setup e3 'Approved'; the Registrar's DELETE '1'; i1 gone; exactly one
-- audit row DELETE for i1 with actor 'reg'.
select set_config('app.r257', format('e3 %s, registrar_delete [%s], i1_left %s, audit_actor [%s] -> %s',
  current_setting('app.e3_status'), current_setting('app.c257_reg'),
  (position('i1' in current_setting('app.items_left')) > 0), pg_temp.del_audit(current_setting('app.i1')),
  case when current_setting('app.e3_status') = 'Approved' and current_setting('app.c257_reg') = '1'
        and position('i1' in current_setting('app.items_left')) = 0
        and pg_temp.del_audit(current_setting('app.i1')) = 'reg'
       then 'OK' else 'FAIL' end), true);

-- TC-258. Expected: 'ERR [P0001]: enrollment locked: enrollment <e3> is Approved and its
-- sections can no longer be changed'; i4 still there; no audit row.
select set_config('app.r258', format('registrar_delete_approved [%s], i4_left %s, audit [%s] -> %s',
  current_setting('app.c258_reg_locked'), (position('i4' in current_setting('app.items_left')) > 0),
  pg_temp.del_audit(current_setting('app.i4')),
  case when current_setting('app.c258_reg_locked') = format('ERR [P0001]: enrollment locked: enrollment %s is Approved and its sections can no longer be changed', current_setting('app.e_s3'))
        and position('i4' in current_setting('app.items_left')) > 0
        and pg_temp.del_audit(current_setting('app.i4')) = 'none'
       then 'OK' else 'FAIL' end), true);

-- TC-259. Expected: s1 on s2's item '0', the Cashier '0', anon 'ERR [42501]: permission denied
-- for table enrollment_items'; i3 still there, no audit for it; s1's own item '1', gone,
-- audited with actor 's1'. Items left 'i3,i4'.
select set_config('app.r259', format('other_student [%s], cashier [%s], anon [%s], own [%s], items_left [%s], audit_i3 [%s], audit_i2 [%s] -> %s',
  current_setting('app.c259_other'), current_setting('app.c259_cashier'), current_setting('app.c259_anon'),
  current_setting('app.c259_own'), current_setting('app.items_left'),
  pg_temp.del_audit(current_setting('app.i3')), pg_temp.del_audit(current_setting('app.i2')),
  case when current_setting('app.c259_other') = '0' and current_setting('app.c259_cashier') = '0'
        and current_setting('app.c259_anon') = 'ERR [42501]: permission denied for table enrollment_items'
        and current_setting('app.c259_own') = '1' and current_setting('app.items_left') = 'i3,i4'
        and pg_temp.del_audit(current_setting('app.i3')) = 'none'
        and pg_temp.del_audit(current_setting('app.i2')) = 's1'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- Result: ONE row
-- ==========================================
select (current_setting('app.r248') like '%-> OK' and current_setting('app.r249') like '%-> OK'
        and current_setting('app.r250') like '%-> OK' and current_setting('app.r251') like '%-> OK'
        and current_setting('app.r252') like '%-> OK' and current_setting('app.r253') like '%-> OK'
        and current_setting('app.r254') like '%-> OK' and current_setting('app.r255') like '%-> OK'
        and current_setting('app.r256') like '%-> OK' and current_setting('app.r257') like '%-> OK'
        and current_setting('app.r258') like '%-> OK' and current_setting('app.r259') like '%-> OK') as all_ok,
  current_setting('app.r248') as tc248, current_setting('app.r249') as tc249, current_setting('app.r250') as tc250,
  current_setting('app.r251') as tc251, current_setting('app.r252') as tc252, current_setting('app.r253') as tc253,
  current_setting('app.r254') as tc254, current_setting('app.r255') as tc255, current_setting('app.r256') as tc256,
  current_setting('app.r257') as tc257, current_setting('app.r258') as tc258, current_setting('app.r259') as tc259;

rollback;
