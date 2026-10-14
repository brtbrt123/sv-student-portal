-- ==========================================
-- REHEARSAL: queue_hold.sql + TC-199 to TC-217 in ONE rolled-back transaction
-- ==========================================
-- Queue hold / unhold (feature/queue-hold-sql). One paste, one run, ONE result row, nothing
-- committed. This is TC-199R.
--
-- How to run: Supabase SQL editor, as postgres, a new tab, at a quiet time (the ALTER TABLE
-- statements lock queue_tickets until the rollback, a few seconds). Paste the whole file (from
-- "begin;" to "rollback;") and click Run on the whole tab, never a selection. If the script
-- stops with an error, run "rollback;" as its own query and send the error back.
--
-- What it does:
--   1. begin;
--   2. the body of docs/database/queue_hold.sql (everything between its "BEGIN;" and "COMMIT;"
--      lines, copied verbatim by a script: safety checks, column, constraints, index, helper,
--      trigger function, functions, grants, checks after the change; the NOTIFY is never sent
--      because of the rollback). A "queue_hold: ..." error here means the live state is not
--      what the file assumes: do NOT run the file live; send the error back.
--   3. TC-199 to TC-217 (docs/database/queue_hold_test.sql from its "begin;" line, verbatim).
--      The tests create six throwaway services TCH-A .. TCH-F; TC-210 may add one Held ticket
--      of a seed student to the real Enrollment service; TC-207 switches the trigger
--      require_queue_ticket_rules off for two UPDATEs and on again. Each result is stored
--      with set_config('app.rNNN', ...).
--   4. One final row: all_ok, then one cell per case, each ending in "-> OK" or "-> FAIL".
--   5. rollback; (the column, constraints, functions, grants and all test data disappear)
--
-- RUNNING ONLY THE TESTS (after the change is live): the test part starts at the line
-- "-- TESTS START HERE" and is self-contained: copy from the "begin;" line right below that
-- marker to the end of the file into a new tab and run it (or run
-- docs/database/queue_hold_test.sql, which is the same). It ends in rollback.
--
-- Every statement that is expected to fail runs inside a do block with an exception
-- handler, so the transaction is never aborted by an expected error.
--
-- Status: NOT RUN YET (written 2026-10-13 without a local PostgreSQL).

begin;

-- ==========================================
-- 1. The change (body of queue_hold.sql, verbatim)
-- ==========================================


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




-- ==========================================
-- TESTS START HERE (TC-199 to TC-217)
-- ==========================================
-- To run ONLY the tests once queue_hold.sql is live: copy from the next line ("begin;") to
-- the end of this file into a new tab and run that tab as a whole.
-- In the full rehearsal the next line is a second BEGIN inside the open transaction;
-- PostgreSQL only answers "WARNING: there is already a transaction in progress" and carries
-- on (nothing is committed either way; the file ends in rollback).
begin;

-- ==========================================
-- 1. Accounts, ids, throwaway services, helpers (as postgres, no user JWT)
-- ==========================================
select set_config('request.jwt.claims', '', true);
select set_config('app.none', '', true);
select set_config('app.s1',   coalesce((select id::text from auth.users where email = 'student1@pnc.test'), ''), true);
select set_config('app.s2',   coalesce((select id::text from auth.users where email = 'student2@pnc.test'), ''), true);
select set_config('app.s3',   coalesce((select id::text from auth.users where email = 'student3@pnc.test'), ''), true);
select set_config('app.reg',  coalesce((select id::text from auth.users where email = 'registrar@pnc.test'), ''), true);
select set_config('app.cash', coalesce((select id::text from auth.users where email = 'cashier@pnc.test'), ''), true);
select set_config('app.dept', coalesce((select id::text from auth.users where email = 'dept@pnc.test'), ''), true);
select set_config('app.adm',  coalesce((select id::text from auth.users where email = 'admin@pnc.test'), ''), true);
select set_config('app.today', ((now() at time zone 'Asia/Manila')::date)::text, true);
do $$
declare v_bad text;
begin
  if to_regprocedure('public.queue_hold_my_ticket(text)') is null
     or to_regprocedure('public.queue_unhold_my_ticket(text)') is null
     or to_regprocedure('private.queue_hold_limit()') is null then
    raise exception 'TC setup: queue_hold.sql is not installed (run it, or use queue_hold_rehearsal.sql)';
  end if;
  if to_regclass('public.notifications') is null or to_regprocedure('private.notify_on_queue_tickets()') is null then
    raise exception 'TC setup: notifications_rules.sql is not installed (TC-214 needs it)';
  end if;
  select string_agg(v.who || ' (' || v.role_name || ')', ', ') into v_bad
  from (values ('s1', 'Student'), ('s2', 'Student'), ('s3', 'Student'), ('reg', 'Registrar'),
               ('cash', 'Cashier'), ('dept', 'Department'), ('adm', 'Admin')) as v(who, role_name)
  where current_setting('app.' || v.who) = ''
     or not exists (select 1 from public.profiles p join public.roles r on r.role_id = p.role_id
                    where p.profile_id::text = current_setting('app.' || v.who)
                      and p.is_active and r.role_name = v.role_name)
     or (v.role_name = 'Student'
         and not exists (select 1 from public.students s where s.student_id::text = current_setting('app.' || v.who)));
  if v_bad is not null then
    raise exception 'TC setup: seed account missing, inactive or with another role: %', v_bad;
  end if;
  if exists (select 1 from public.queue_services where service_code like 'TCH-_') then
    raise exception 'TC setup: a queue service TCH-? exists; the tests need the codes TCH-A .. TCH-F free';
  end if;
  if not exists (select 1 from public.queue_services where service_code = 'Enrollment') then
    raise exception 'TC setup: the Enrollment service is missing';
  end if;
end $$;
select set_config('app.s1num', (select student_number::text from public.students where student_id::text = current_setting('app.s1')), true);
select set_config('app.log_mark', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);
-- six throwaway services, each with a free prefix letter
do $$
declare c text;
begin
  foreach c in array array['TCH-A', 'TCH-B', 'TCH-C', 'TCH-D', 'TCH-E', 'TCH-F'] loop
    insert into public.queue_services (service_code, service_name, ticket_prefix, is_open)
    select c, 'TC hold queue ' || right(c, 1), chr(g), true
    from generate_series(65, 90) g
    where chr(g) not in (select ticket_prefix from public.queue_services)
    order by g desc
    limit 1;
    if not found then
      raise exception 'TC setup: no free ticket prefix letter for %', c;
    end if;
  end loop;
end $$;
select set_config('app.sve', (select service_id::text from public.queue_services where service_code = 'TCH-E'), true);
select set_config('app.enr', (select service_id::text from public.queue_services where service_code = 'Enrollment'), true);

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

-- ==========================================
-- 2. TC-199: installed as intended (catalog)
-- ==========================================
-- Expected: held_col 'timestamp with time zone null', status_check true, state_check true,
-- held_check true, index true, triggers 'audit_log 29 O, require_queue_ticket_rules 19 O,
-- trg_notify_queue_tickets 21 O', public 9/9, new_fn_grantees 'authenticated', helper true,
-- limit '00:15:00', shapes true.
select set_config('app.r199', (select format('held_col [%s], status_check %s, state_check %s, held_check %s, index %s, triggers [%s], public_fns_ok %s/9, new_fn_grantees [%s], helper_locked %s, limit %s, shapes %s -> %s',
    x.held_col, x.status_ck, x.state_ck, x.held_ck, x.idx, x.trg, x.pub_ok, x.grantees, x.helper, x.lim, x.shapes,
    case when x.held_col = 'timestamp with time zone null' and x.status_ck and x.state_ck and x.held_ck and x.idx
          and x.trg = 'audit_log 29 O, require_queue_ticket_rules 19 O, trg_notify_queue_tickets 21 O'
          and x.pub_ok = 9 and x.grantees = 'authenticated' and x.helper and x.lim = '00:15:00' and x.shapes
         then 'OK' else 'FAIL' end)
  from (select
    coalesce((select format_type(a.atttypid, null) || case when a.attnotnull then ' not null' else ' null' end
                from pg_attribute a
               where a.attrelid = 'public.queue_tickets'::regclass and a.attname = 'held_at' and not a.attisdropped), 'missing') as held_col,
    exists (select 1 from pg_constraint k where k.conrelid = 'public.queue_tickets'::regclass and k.conname = 'ck_queue_tickets_status'
              and k.convalidated and pg_get_constraintdef(k.oid) like '%''Held''::text%') as status_ck,
    exists (select 1 from pg_constraint k where k.conrelid = 'public.queue_tickets'::regclass and k.conname = 'ck_queue_tickets_state'
              and k.convalidated and pg_get_constraintdef(k.oid) like '%Held%') as state_ck,
    exists (select 1 from pg_constraint k where k.conrelid = 'public.queue_tickets'::regclass and k.conname = 'ck_queue_tickets_held'
              and k.contype = 'c' and k.convalidated and pg_get_constraintdef(k.oid) like '%held_at IS NOT NULL%') as held_ck,
    exists (select 1 from pg_index i
             where i.indexrelid = to_regclass('public.uq_queue_tickets_active_student')
               and i.indrelid = 'public.queue_tickets'::regclass and i.indisunique and i.indisvalid
               and pg_get_indexdef(i.indexrelid) like '%(student_id, service_id, queue_date)%Waiting%Serving%Held%') as idx,
    coalesce((select string_agg(t.tgname || ' ' || t.tgtype || ' ' || t.tgenabled::text, ', ' order by t.tgname)
                from pg_trigger t where t.tgrelid = 'public.queue_tickets'::regclass and not t.tgisinternal), '') as trg,
    (select count(*) from pg_proc p
      where p.oid in (to_regprocedure('public.issue_queue_ticket(uuid, text)'),
                      to_regprocedure('public.queue_call_next(text, text)'),
                      to_regprocedure('public.queue_finish(bigint, text)'),
                      to_regprocedure('public.queue_cancel_my_ticket(text)'),
                      to_regprocedure('public.queue_hold_my_ticket(text)'),
                      to_regprocedure('public.queue_unhold_my_ticket(text)'),
                      to_regprocedure('public.queue_my_status(text)'),
                      to_regprocedure('public.queue_staff_list(text)'),
                      to_regprocedure('public.queue_student_card(uuid)'))
        and p.prosecdef and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
        and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
        and not has_function_privilege('anon', p.oid, 'EXECUTE')
        and has_function_privilege('authenticated', p.oid, 'EXECUTE')
        and exists (select 1 from pg_roles r join pg_class c on c.oid = 'public.queue_tickets'::regclass
                     where r.oid = p.proowner
                       and (r.rolbypassrls or (c.relowner = r.oid and not c.relforcerowsecurity)))) as pub_ok,
    coalesce((select string_agg(distinct g.rolname::text, ',' order by g.rolname::text)
                from pg_proc p
                cross join lateral aclexplode(p.proacl) a
                join pg_roles g on g.oid = a.grantee
               where p.oid in (to_regprocedure('public.queue_hold_my_ticket(text)'), to_regprocedure('public.queue_unhold_my_ticket(text)'))
                 and a.grantee <> p.proowner and not g.rolbypassrls), '') as grantees,
    exists (select 1 from pg_proc p
             where p.oid = to_regprocedure('private.queue_hold_limit()')
               and not p.prosecdef and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
               and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
               and not has_function_privilege('anon', p.oid, 'EXECUTE')
               and not has_function_privilege('authenticated', p.oid, 'EXECUTE')) as helper,
    private.queue_hold_limit()::text as lim,
    (pg_get_function_result('public.queue_my_status(text)'::regprocedure)
       = 'TABLE(is_open boolean, has_ticket boolean, ticket_label text, ticket_status text, people_ahead integer, now_serving text, waiting_total integer, avg_service_seconds integer, window_label text, held_until timestamp with time zone)'
     and pg_get_function_result('public.queue_staff_list(text)'::regprocedure)
       = 'TABLE(ticket_id bigint, ticket_label text, ticket_number integer, status text, student_id uuid, student_number text, student_name text, window_label text, created_at timestamp with time zone, called_at timestamp with time zone, finished_at timestamp with time zone, held_at timestamp with time zone)'
     and pg_get_function_result('public.queue_hold_my_ticket(text)'::regprocedure) = 'timestamp with time zone'
     and pg_get_function_result('public.queue_unhold_my_ticket(text)'::regprocedure) = 'void'
     and pg_get_function_arguments('public.queue_hold_my_ticket(text)'::regprocedure) = 'p_service text'
     and pg_get_function_arguments('public.queue_unhold_my_ticket(text)'::regprocedure) = 'p_service text') as shapes
  ) x), true);

-- ==========================================
-- 3. TC-200: who may hold / unhold
-- ==========================================
-- Expected: anon '2 denied'; Registrar / Cashier / Department / Admin / no JWT / inactive
-- student: 'ERR [42501]: not allowed: ...'; unknown service: 'ERR [22023]: invalid ticket
-- request: unknown service [NOPE]'.
set local role anon;
do $$
declare s text; v_ok integer := 0; v_bad text := '';
begin
  foreach s in array array[
    $q$select public.queue_hold_my_ticket('TCH-A')::text$q$,
    $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-A')$q$]
  loop
    begin
      execute s;
      v_bad := v_bad || 'ALLOWED: ' || s || '; ';
    exception when others then
      if sqlstate = '42501' and sqlerrm like 'permission denied for function%' then
        v_ok := v_ok + 1;
      else
        v_bad := v_bad || sqlstate || ' ' || sqlerrm || '; ';
      end if;
    end;
  end loop;
  perform set_config('app.c200_anon', v_ok || ' denied' || case when v_bad <> '' then ', ' || v_bad else '' end, true);
end $$;
reset role;
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c200_reg',      'reg',  $q$select public.queue_hold_my_ticket('TCH-A')::text$q$),
    (2, 'c200_reg_un',   'reg',  $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-A')$q$),
    (3, 'c200_cash',     'cash', $q$select public.queue_hold_my_ticket('TCH-A')::text$q$),
    (4, 'c200_dept',     'dept', $q$select public.queue_hold_my_ticket('TCH-A')::text$q$),
    (5, 'c200_adm',      'adm',  $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-A')$q$),
    (6, 'c200_none',     'none', $q$select public.queue_hold_my_ticket('TCH-A')::text$q$),
    (7, 'c200_service',  's1',   $q$select public.queue_hold_my_ticket('NOPE')::text$q$)
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
update public.profiles set is_active = false where profile_id::text = current_setting('app.s1');
set local role authenticated;
do $$
declare v text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('app.s1'), 'role', 'authenticated')::text, true);
  begin
    select public.queue_hold_my_ticket('TCH-A')::text into v;
    perform set_config('app.c200_inactive', coalesce(v, 'NULL'), true);
  exception when others then
    perform set_config('app.c200_inactive', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
update public.profiles set is_active = true where profile_id::text = current_setting('app.s1');
select set_config('app.r200', format('anon [%s], registrar [%s], registrar_unhold [%s], cashier [%s], department [%s], admin_unhold [%s], no_jwt [%s], inactive [%s], unknown_service [%s] -> %s',
  current_setting('app.c200_anon'), current_setting('app.c200_reg'), current_setting('app.c200_reg_un'),
  current_setting('app.c200_cash'), current_setting('app.c200_dept'), current_setting('app.c200_adm'),
  current_setting('app.c200_none'), current_setting('app.c200_inactive'), current_setting('app.c200_service'),
  case when current_setting('app.c200_anon') = '2 denied'
        and current_setting('app.c200_reg') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c200_reg_un') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c200_cash') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c200_dept') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c200_adm') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c200_none') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c200_inactive') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c200_service') = 'ERR [22023]: invalid ticket request: unknown service [NOPE]'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 4. Flow A (TCH-A): TC-201, TC-204, TC-212, TC-203, TC-202, TC-205, TC-213
-- ==========================================
-- Step A1: the Registrar issues A1 (s1), A2 (s2), A3 (s3); s1 holds, then holds again; the
-- three students read their status; the Registrar reads the list; a student tries the list.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1,  'ca_issue1',  'reg', $q$select i.ticket_label || '|' || i.people_ahead from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCH-A') i$q$),
    (2,  'ca_issue2',  'reg', $q$select i.ticket_label || '|' || i.people_ahead from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCH-A') i$q$),
    (3,  'ca_issue3',  'reg', $q$select i.ticket_label || '|' || i.people_ahead from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCH-A') i$q$),
    (4,  'c201_hold',  's1',  $q$select (public.queue_hold_my_ticket('TCH-A') = now() + interval '15 minutes')::text$q$),
    (5,  'c201_again', 's1',  $q$select public.queue_hold_my_ticket('TCH-A')::text$q$),
    (6,  'c204_s1',    's1',  $q$select m.ticket_label || '|' || m.ticket_status || '|' || coalesce(m.people_ahead::text, 'NULL') || '|' || m.waiting_total || '|' || coalesce((m.held_until = now() + interval '15 minutes')::text, 'NULL') || '|' || coalesce(m.window_label, 'NULL') from public.queue_my_status('TCH-A') m$q$),
    (7,  'c204_s2',    's2',  $q$select m.ticket_label || '|' || m.ticket_status || '|' || coalesce(m.people_ahead::text, 'NULL') || '|' || m.waiting_total || '|' || coalesce((m.held_until = now() + interval '15 minutes')::text, 'NULL') || '|' || coalesce(m.window_label, 'NULL') from public.queue_my_status('TCH-A') m$q$),
    (8,  'c204_s3',    's3',  $q$select m.ticket_label || '|' || m.ticket_status || '|' || coalesce(m.people_ahead::text, 'NULL') || '|' || m.waiting_total || '|' || coalesce((m.held_until = now() + interval '15 minutes')::text, 'NULL') || '|' || coalesce(m.window_label, 'NULL') from public.queue_my_status('TCH-A') m$q$),
    (9,  'c212_list',  'reg', $q$select string_agg(s.ticket_number || ':' || s.status || ':' || coalesce((s.held_at = now())::text, 'NULL'), ',' order by s.ticket_number) from public.queue_staff_list('TCH-A') s$q$),
    (10, 'c212_student', 's2', $q$select count(*)::text from public.queue_staff_list('TCH-A') s$q$)
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
select set_config('app.t_a1', coalesce(pg_temp.tid('TCH-A', 's1'), 0)::text, true);
select set_config('app.t_a2', coalesce(pg_temp.tid('TCH-A', 's2'), 0)::text, true);
select set_config('app.t_a3', coalesce(pg_temp.tid('TCH-A', 's3'), 0)::text, true);
select set_config('app.l_a1', pg_temp.lbl(current_setting('app.t_a1')::bigint), true);
select set_config('app.l_a2', pg_temp.lbl(current_setting('app.t_a2')::bigint), true);
select set_config('app.l_a3', pg_temp.lbl(current_setting('app.t_a3')::bigint), true);
select set_config('app.st_a1_held', pg_temp.st(current_setting('app.t_a1')::bigint), true);

-- Step A2: Call next (skips A1), Done; s2 (Done) and s3 (Serving) try to hold; Done; Call
-- next with only the held A1 left.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c203_call1',  'reg', $q$select c.ticket_label from public.queue_call_next('TCH-A', 'W1') c$q$),
    (2, 'c203_fin1',   'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_a2')::bigint, 'Done')$q$),
    (3, 'c202_done',   's2',  $q$select public.queue_hold_my_ticket('TCH-A')::text$q$),
    (4, 'c203_call2',  'reg', $q$select c.ticket_label from public.queue_call_next('TCH-A', 'W1') c$q$),
    (5, 'c202_serving','s3',  $q$select public.queue_hold_my_ticket('TCH-A')::text$q$),
    (6, 'c203_fin2',   'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_a3')::bigint, 'Done')$q$),
    (7, 'c203_call3',  'reg', $q$select c.ticket_label from public.queue_call_next('TCH-A', 'W1') c$q$)
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
select set_config('app.st_a1_after_calls', pg_temp.st(current_setting('app.t_a1')::bigint), true);

-- Step A3: s1 comes back (unhold), unholds again; s2 gets a new ticket A4; Call next must
-- take A1 (before A4); Done.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c205_unhold', 's1',  $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-A')$q$),
    (2, 'c205_again',  's1',  $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-A')$q$),
    (3, 'c205_issue4', 'reg', $q$select i.ticket_label || '|' || i.people_ahead from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCH-A') i$q$),
    (4, 'c205_s1',     's1',  $q$select m.ticket_label || '|' || m.ticket_status || '|' || coalesce(m.people_ahead::text, 'NULL') || '|' || m.waiting_total || '|' || coalesce((m.held_until = now() + interval '15 minutes')::text, 'NULL') || '|' || coalesce(m.window_label, 'NULL') from public.queue_my_status('TCH-A') m$q$),
    (5, 'c205_call',   'reg', $q$select c.ticket_label from public.queue_call_next('TCH-A', 'W1') c$q$),
    (6, 'c205_fin',    'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_a1')::bigint, 'Done')$q$)
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
select set_config('app.t_a4', coalesce(pg_temp.tid('TCH-A', 's2'), 0)::text, true);
select set_config('app.l_a4', pg_temp.lbl(current_setting('app.t_a4')::bigint), true);

-- TC-201. Expected: issues 'L(A1)|0', 'L(A2)|1', 'L(A3)|2'; hold 'true'; again 'ERR [P0001]:
-- bad ticket change: ticket L(A1) is already on hold'; st(A1) 'Held #1 held=now called=null
-- fin=null by=null win=null'; the label (code) unchanged.
select set_config('app.r201', format('issued [%s; %s; %s], hold [%s], again [%s], row [%s] -> %s',
  current_setting('app.ca_issue1'), current_setting('app.ca_issue2'), current_setting('app.ca_issue3'),
  current_setting('app.c201_hold'), current_setting('app.c201_again'), current_setting('app.st_a1_held'),
  case when current_setting('app.ca_issue1') = current_setting('app.l_a1') || '|0'
        and current_setting('app.ca_issue2') = current_setting('app.l_a2') || '|1'
        and current_setting('app.ca_issue3') = current_setting('app.l_a3') || '|2'
        and current_setting('app.c201_hold') = 'true'
        and current_setting('app.c201_again') = format('ERR [P0001]: bad ticket change: ticket %s is already on hold', current_setting('app.l_a1'))
        and current_setting('app.st_a1_held') = 'Held #1 held=now called=null fin=null by=null win=null'
        and current_setting('app.l_a1') ~ '^#[1-9][0-9]{6}$'
       then 'OK' else 'FAIL' end), true);

-- TC-202. Expected: Done ticket 'ERR [P0001]: bad ticket change: no waiting ticket'; Serving
-- ticket 'ERR [P0001]: bad ticket change: ticket L(A3) is being served and cannot be put on hold'.
select set_config('app.r202', format('done [%s], serving [%s] -> %s',
  current_setting('app.c202_done'), current_setting('app.c202_serving'),
  case when current_setting('app.c202_done') = 'ERR [P0001]: bad ticket change: no waiting ticket'
        and current_setting('app.c202_serving') = format('ERR [P0001]: bad ticket change: ticket %s is being served and cannot be put on hold', current_setting('app.l_a3'))
       then 'OK' else 'FAIL' end), true);

-- TC-203. Expected: call1 L(A2), finish 'done', call2 L(A3), finish 'done', call3 'NULL' (only
-- the held A1 is left); A1 still 'Held #1 held=now ...'.
select set_config('app.r203', format('call1 [%s], call2 [%s], call3 [%s], finishes [%s, %s], a1 [%s] -> %s',
  current_setting('app.c203_call1'), current_setting('app.c203_call2'), current_setting('app.c203_call3'),
  current_setting('app.c203_fin1'), current_setting('app.c203_fin2'), current_setting('app.st_a1_after_calls'),
  case when current_setting('app.c203_call1') = current_setting('app.l_a2')
        and current_setting('app.c203_call2') = current_setting('app.l_a3')
        and current_setting('app.c203_call3') = 'NULL'
        and current_setting('app.c203_fin1') = 'done' and current_setting('app.c203_fin2') = 'done'
        and current_setting('app.st_a1_after_calls') = 'Held #1 held=now called=null fin=null by=null win=null'
       then 'OK' else 'FAIL' end), true);

-- TC-204. Expected (A1 held, A2 and A3 waiting): s1 'L(A1)|Held|0|2|true|NULL'; s2
-- 'L(A2)|Waiting|0|2|NULL|NULL' (the held A1 is not ahead); s3 'L(A3)|Waiting|1|2|NULL|NULL'.
select set_config('app.r204', format('s1 [%s], s2 [%s], s3 [%s] -> %s',
  current_setting('app.c204_s1'), current_setting('app.c204_s2'), current_setting('app.c204_s3'),
  case when current_setting('app.c204_s1') = current_setting('app.l_a1') || '|Held|0|2|true|NULL'
        and current_setting('app.c204_s2') = current_setting('app.l_a2') || '|Waiting|0|2|NULL|NULL'
        and current_setting('app.c204_s3') = current_setting('app.l_a3') || '|Waiting|1|2|NULL|NULL'
       then 'OK' else 'FAIL' end), true);

-- TC-205. Expected: unhold 'ok'; again 'ERR [P0001]: bad ticket change: no ticket on hold';
-- A4 issued 'L(A4)|1' (A1 is Waiting again and ahead); s1 'L(A1)|Waiting|0|2|NULL|NULL' (A1 and
-- A4 waiting); Call next L(A1); finish 'done'; A1 kept number 1 and its code.
select set_config('app.r205', format('unhold [%s], again [%s], issue_a4 [%s], s1_status [%s], call [%s], finish [%s], a1_final [%s] -> %s',
  current_setting('app.c205_unhold'), current_setting('app.c205_again'), current_setting('app.c205_issue4'),
  current_setting('app.c205_s1'), current_setting('app.c205_call'), current_setting('app.c205_fin'),
  pg_temp.st(current_setting('app.t_a1')::bigint),
  case when current_setting('app.c205_unhold') = 'ok'
        and current_setting('app.c205_again') = 'ERR [P0001]: bad ticket change: no ticket on hold'
        and current_setting('app.c205_issue4') = current_setting('app.l_a4') || '|1'
        and current_setting('app.c205_s1') = current_setting('app.l_a1') || '|Waiting|0|2|NULL|NULL'
        and current_setting('app.c205_call') = current_setting('app.l_a1')
        and current_setting('app.c205_fin') = 'done'
        and pg_temp.st(current_setting('app.t_a1')::bigint) = 'Done #1 held=null called=now fin=now by=reg win=W1'
        and pg_temp.lbl(current_setting('app.t_a1')::bigint) = current_setting('app.l_a1')
       then 'OK' else 'FAIL' end), true);

-- TC-212. Expected: '1:Held:true,2:Waiting:NULL,3:Waiting:NULL' for the Registrar; a student
-- 'ERR [42501]: not allowed: ...'.
select set_config('app.r212', format('registrar [%s], student [%s] -> %s',
  current_setting('app.c212_list'), current_setting('app.c212_student'),
  case when current_setting('app.c212_list') = '1:Held:true,2:Waiting:NULL,3:Waiting:NULL'
        and current_setting('app.c212_student') like 'ERR [42501]: not allowed:%'
       then 'OK' else 'FAIL' end), true);

-- TC-213. Expected audit trail of A1 (old>new:actor:held_at of the new row):
-- '>Waiting:reg:null ; Waiting>Held:s1:set ; Held>Waiting:s1:null ; Waiting>Serving:reg:null ;
-- Serving>Done:reg:null' (exactly 5 rows: the refused second hold / unhold wrote nothing).
select set_config('app.r213', (select format('trail [%s] -> %s', x.trail,
    case when x.trail = '>Waiting:reg:null ; Waiting>Held:s1:set ; Held>Waiting:s1:null ; Waiting>Serving:reg:null ; Serving>Done:reg:null'
         then 'OK' else 'FAIL' end)
  from (select coalesce(string_agg(coalesce(l.old_data ->> 'status', '') || '>' || coalesce(l.new_data ->> 'status', '')
                                   || ':' || pg_temp.who(l.actor_id) || ':'
                                   || case when not (l.new_data ? 'held_at') then 'missing'
                                           when l.new_data ->> 'held_at' is null then 'null' else 'set' end,
                                   ' ; ' order by l.log_id), '') as trail
        from public.audit_logs l
        where l.log_id > current_setting('app.log_mark')::bigint and l.table_name = 'queue_tickets'
          and l.record_id = current_setting('app.t_a1')) x), true);

-- ==========================================
-- 5. TC-206 (TCH-B): hold + unhold at once keeps the position
-- ==========================================
-- Expected: s2 hold 'true', unhold 'ok'; s2 people_ahead 1, s3 people_ahead 2; calls in
-- order L(B1), L(B2), L(B3).
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1,  'cb_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCH-B') i$q$),
    (2,  'cb_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCH-B') i$q$),
    (3,  'cb_issue3', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCH-B') i$q$),
    (4,  'c206_hold',   's2', $q$select (public.queue_hold_my_ticket('TCH-B') = now() + interval '15 minutes')::text$q$),
    (5,  'c206_unhold', 's2', $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-B')$q$),
    (6,  'c206_s2',   's2',  $q$select m.ticket_status || '|' || m.people_ahead from public.queue_my_status('TCH-B') m$q$),
    (7,  'c206_s3',   's3',  $q$select m.ticket_status || '|' || m.people_ahead from public.queue_my_status('TCH-B') m$q$),
    (8,  'c206_call1', 'reg', $q$select c.ticket_label from public.queue_call_next('TCH-B') c$q$),
    (9,  'c206_fin1', 'reg', $q$select 'done'::text from public.queue_finish((select max(t.ticket_id) from public.queue_tickets t where t.status = 'Serving' and t.handled_by = auth.uid() and t.service_id = (select s.service_id from public.queue_services s where s.service_code = 'TCH-B')), 'Done')$q$),
    (10, 'c206_call2', 'reg', $q$select c.ticket_label from public.queue_call_next('TCH-B') c$q$),
    (11, 'c206_fin2', 'reg', $q$select 'done'::text from public.queue_finish((select max(t.ticket_id) from public.queue_tickets t where t.status = 'Serving' and t.handled_by = auth.uid() and t.service_id = (select s.service_id from public.queue_services s where s.service_code = 'TCH-B')), 'Done')$q$),
    (12, 'c206_call3', 'reg', $q$select c.ticket_label from public.queue_call_next('TCH-B') c$q$),
    (13, 'c206_fin3', 'reg', $q$select 'done'::text from public.queue_finish((select max(t.ticket_id) from public.queue_tickets t where t.status = 'Serving' and t.handled_by = auth.uid() and t.service_id = (select s.service_id from public.queue_services s where s.service_code = 'TCH-B')), 'Done')$q$)
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
select set_config('app.r206', format('hold [%s], unhold [%s], s2 [%s], s3 [%s], calls [%s, %s, %s], finishes [%s, %s, %s] -> %s',
  current_setting('app.c206_hold'), current_setting('app.c206_unhold'), current_setting('app.c206_s2'), current_setting('app.c206_s3'),
  current_setting('app.c206_call1'), current_setting('app.c206_call2'), current_setting('app.c206_call3'),
  current_setting('app.c206_fin1'), current_setting('app.c206_fin2'), current_setting('app.c206_fin3'),
  case when current_setting('app.c206_hold') = 'true' and current_setting('app.c206_unhold') = 'ok'
        and current_setting('app.c206_s2') = 'Waiting|1' and current_setting('app.c206_s3') = 'Waiting|2'
        and current_setting('app.c206_call1') = current_setting('app.cb_issue1')
        and current_setting('app.c206_call2') = current_setting('app.cb_issue2')
        and current_setting('app.c206_call3') = current_setting('app.cb_issue3')
        and current_setting('app.cb_issue1') like '#%' and current_setting('app.cb_issue2') like '#%' and current_setting('app.cb_issue3') like '#%'
        and current_setting('app.c206_fin1') = 'done' and current_setting('app.c206_fin2') = 'done' and current_setting('app.c206_fin3') = 'done'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 6. Flow C (TCH-C): TC-207 expiry, TC-208 Registrar No-show, TC-209 cancel, TC-210, TC-211
-- ==========================================
-- Step C1: C1 (s1) and C2 (s2) issued and both held.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'cc_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCH-C') i$q$),
    (2, 'cc_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCH-C') i$q$),
    (3, 'cc_hold1',  's1',  $q$select public.queue_hold_my_ticket('TCH-C')::text$q$),
    (4, 'cc_hold2',  's2',  $q$select public.queue_hold_my_ticket('TCH-C')::text$q$)
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
select set_config('app.t_c1', coalesce(pg_temp.tid('TCH-C', 's1'), 0)::text, true);
select set_config('app.t_c2', coalesce(pg_temp.tid('TCH-C', 's2'), 0)::text, true);
select set_config('app.l_c1', pg_temp.lbl(current_setting('app.t_c1')::bigint), true);
-- As the owner: put held_at in the past (the trigger would replace it, so it is switched off
-- for these two statements only; the CHECKs still apply).
alter table public.queue_tickets disable trigger require_queue_ticket_rules;
update public.queue_tickets set held_at = now() - interval '16 minutes' where ticket_id = current_setting('app.t_c1')::bigint and status = 'Held';
update public.queue_tickets set held_at = now() - interval '14 minutes' where ticket_id = current_setting('app.t_c2')::bigint and status = 'Held';
alter table public.queue_tickets enable trigger require_queue_ticket_rules;
select set_config('app.c207_trigger_back', coalesce((select t.tgenabled::text from pg_trigger t
  where t.tgrelid = 'public.queue_tickets'::regclass and t.tgname = 'require_queue_ticket_rules'), 'missing'), true);

-- Step C2: TC-207 (s1 expired, s2 within the limit), TC-208 (Registrar No-show of C1, s1 gets
-- C3), TC-209 (s2 holds again and cancels), TC-210 (s1 holds C3; issue refused), TC-211 (s3
-- has no ticket in TCH-C).
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1,  'c207_status',  's1',  $q$select m.ticket_status || '|' || (m.held_until = now() - interval '1 minute') || '|' || coalesce(m.people_ahead::text, 'NULL') from public.queue_my_status('TCH-C') m$q$),
    (2,  'c207_unhold',  's1',  $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-C')$q$),
    (3,  'c207_in_time', 's2',  $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-C')$q$),
    (4,  'c208_done',    'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_c1')::bigint, 'Done')$q$),
    (5,  'c208_noshow',  'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_c1')::bigint, 'No-show')$q$),
    (6,  'c208_again',   'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_c1')::bigint, 'No-show')$q$),
    (7,  'c208_new',     'reg', $q$select i.ticket_label || '|' || i.people_ahead from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCH-C') i$q$),
    (8,  'c209_hold',    's2',  $q$select (public.queue_hold_my_ticket('TCH-C') = now() + interval '15 minutes')::text$q$),
    (9,  'c209_cancel',  's2',  $q$select 'ok'::text from public.queue_cancel_my_ticket('TCH-C')$q$),
    (10, 'c209_unhold',  's2',  $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-C')$q$),
    (11, 'c209_cancel2', 's2',  $q$select 'ok'::text from public.queue_cancel_my_ticket('TCH-C')$q$),
    (12, 'c209_status',  's2',  $q$select m.ticket_status || '|' || coalesce(m.people_ahead::text, 'NULL') || '|' || coalesce(m.held_until::text, 'NULL') from public.queue_my_status('TCH-C') m$q$),
    (13, 'c210_hold',    's1',  $q$select (public.queue_hold_my_ticket('TCH-C') = now() + interval '15 minutes')::text$q$),
    (14, 'c210_issue',   'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCH-C') i$q$),
    (15, 'c211_hold',    's3',  $q$select public.queue_hold_my_ticket('TCH-C')::text$q$),
    (16, 'c211_unhold',  's3',  $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-C')$q$),
    (17, 'c211_cancel',  's3',  $q$select 'ok'::text from public.queue_cancel_my_ticket('TCH-C')$q$),
    (18, 'c211_status',  's3',  $q$select m.has_ticket || '|' || coalesce(m.ticket_label, 'NULL') || '|' || coalesce(m.ticket_status, 'NULL') || '|' || coalesce(m.people_ahead::text, 'NULL') || '|' || coalesce(m.held_until::text, 'NULL') || '|' || m.waiting_total from public.queue_my_status('TCH-C') m$q$)
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
select set_config('app.t_c3', coalesce(pg_temp.tid('TCH-C', 's1'), 0)::text, true);
select set_config('app.l_c3', pg_temp.lbl(current_setting('app.t_c3')::bigint), true);
select set_config('app.st_c3_held', pg_temp.st(current_setting('app.t_c3')::bigint), true);

-- TC-210 (as the owner): a second active row for s1 in TCH-C is refused by the unique index;
-- the scan card of the real Enrollment service shows a Held ticket.
do $$
begin
  begin
    insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
    select s.service_id, current_setting('app.s1')::uuid, current_setting('app.today')::date, 9001, 1000001
    from public.queue_services s where s.service_code = 'TCH-C';
    perform set_config('app.c210_index', 'ALLOWED', true);
  exception when others then
    perform set_config('app.c210_index', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
  end;
end $$;
select set_config('app.card_who', coalesce((select v.who from (values (1, 's3'), (2, 's2'), (3, 's1')) as v(ord, who)
  where not exists (select 1 from public.queue_tickets t
                     where t.service_id = current_setting('app.enr')::bigint and t.queue_date = current_setting('app.today')::date
                       and t.student_id::text = current_setting('app.' || v.who) and t.status in ('Waiting', 'Serving', 'Held'))
  order by v.ord limit 1), ''), true);
do $$
declare v_id bigint;
begin
  if current_setting('app.card_who') <> '' then
    insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, status, held_at)
    select current_setting('app.enr')::bigint, current_setting('app.' || current_setting('app.card_who'))::uuid,
           current_setting('app.today')::date,
           coalesce((select max(t.ticket_number) from public.queue_tickets t
                      where t.service_id = current_setting('app.enr')::bigint and t.queue_date = current_setting('app.today')::date), 0) + 100000,
           private.queue_random_code(), 'Held', now()
    returning ticket_id into v_id;
    perform set_config('app.card_label', pg_temp.lbl(v_id), true);
  else
    perform set_config('app.card_label', 'skipped', true);
  end if;
end $$;
set local role authenticated;
do $$
declare v text;
begin
  if current_setting('app.card_who') = '' then
    perform set_config('app.c210_card', 'skipped', true);
    return;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('app.reg'), 'role', 'authenticated')::text, true);
  begin
    select coalesce(c.already_queued_label, 'NULL') into v
    from public.queue_student_card(current_setting('app.' || current_setting('app.card_who'))::uuid) c;
    perform set_config('app.c210_card', coalesce(v, 'no row'), true);
  exception when others then
    perform set_config('app.c210_card', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- TC-207. Expected: trigger enabled again ('O'); s1 status 'Held|true|0' (held_until one
-- minute ago; nobody waiting ahead); unhold 'ERR [P0001]: hold expired: ticket L(C1) was on hold
-- for more than 15 minutes'; s2 after 14 minutes 'ok'.
select set_config('app.r207', format('trigger [%s], s1_status [%s], expired_unhold [%s], in_time_unhold [%s] -> %s',
  current_setting('app.c207_trigger_back'), current_setting('app.c207_status'), current_setting('app.c207_unhold'),
  current_setting('app.c207_in_time'),
  case when current_setting('app.c207_trigger_back') = 'O'
        and current_setting('app.c207_status') = 'Held|true|0'
        and current_setting('app.c207_unhold') = format('ERR [P0001]: hold expired: ticket %s was on hold for more than 15 minutes', current_setting('app.l_c1'))
        and current_setting('app.c207_in_time') = 'ok'
       then 'OK' else 'FAIL' end), true);

-- TC-208. Expected: Done 'ERR [P0001]: bad ticket change: ticket <C1> is on hold; it can only
-- be marked No-show'; No-show 'done'; again 'ERR [P0001]: bad ticket change: ...'; st(C1)
-- 'No-show #1 held=null called=null fin=now by=reg win=null'; s1's new ticket C3 'L(C3)|1'
-- (C2 is Waiting ahead of it at that moment).
select set_config('app.r208', format('done [%s], noshow [%s], again [%s], row [%s], new_ticket [%s] -> %s',
  current_setting('app.c208_done'), current_setting('app.c208_noshow'), current_setting('app.c208_again'),
  pg_temp.st(current_setting('app.t_c1')::bigint), current_setting('app.c208_new'),
  case when current_setting('app.c208_done') = format('ERR [P0001]: bad ticket change: ticket %s is on hold; it can only be marked No-show', current_setting('app.t_c1'))
        and current_setting('app.c208_noshow') = 'done'
        and current_setting('app.c208_again') like 'ERR [P0001]: bad ticket change:%'
        and pg_temp.st(current_setting('app.t_c1')::bigint) = 'No-show #1 held=null called=null fin=now by=reg win=null'
        and current_setting('app.c208_new') = current_setting('app.l_c3') || '|1'
       then 'OK' else 'FAIL' end), true);

-- TC-209. Expected: hold 'true'; cancel 'ok'; st(C2) 'Cancelled #2 held=null called=null
-- fin=now by=null win=null'; unhold 'ERR [P0001]: bad ticket change: no ticket on hold'; cancel
-- again 'ERR [P0001]: bad ticket change: no waiting ticket'; status 'Cancelled|NULL|NULL'.
select set_config('app.r209', format('hold [%s], cancel [%s], row [%s], unhold [%s], cancel_again [%s], status [%s] -> %s',
  current_setting('app.c209_hold'), current_setting('app.c209_cancel'), pg_temp.st(current_setting('app.t_c2')::bigint),
  current_setting('app.c209_unhold'), current_setting('app.c209_cancel2'), current_setting('app.c209_status'),
  case when current_setting('app.c209_hold') = 'true' and current_setting('app.c209_cancel') = 'ok'
        and pg_temp.st(current_setting('app.t_c2')::bigint) = 'Cancelled #2 held=null called=null fin=now by=null win=null'
        and current_setting('app.c209_unhold') = 'ERR [P0001]: bad ticket change: no ticket on hold'
        and current_setting('app.c209_cancel2') = 'ERR [P0001]: bad ticket change: no waiting ticket'
        and current_setting('app.c209_status') = 'Cancelled|NULL|NULL'
       then 'OK' else 'FAIL' end), true);

-- TC-210. Expected: s1 holds C3 'true'; issue 'ERR [P0001]: already queued: L(C3)'; the second
-- active row 'ERR [23505]: ... "uq_queue_tickets_active_student"'; card = the Held Enrollment
-- label (or 'skipped' when all three seed students already queue in Enrollment today).
select set_config('app.r210', format('hold [%s], issue [%s], index [%s], card_student [%s], card [%s] expected [%s] -> %s',
  current_setting('app.c210_hold'), current_setting('app.c210_issue'), current_setting('app.c210_index'),
  current_setting('app.card_who'), current_setting('app.c210_card'), current_setting('app.card_label'),
  case when current_setting('app.c210_hold') = 'true'
        and current_setting('app.c210_issue') = format('ERR [P0001]: already queued: %s', current_setting('app.l_c3'))
        and current_setting('app.c210_index') like 'ERR [23505]:%uq_queue_tickets_active_student%'
        and current_setting('app.c210_card') = current_setting('app.card_label')
       then 'OK' else 'FAIL' end), true);

-- TC-211. Expected for s3 (no ticket in TCH-C) while s1's C3 is Held: hold 'ERR [P0001]: bad
-- ticket change: no waiting ticket', unhold '... no ticket on hold', cancel '... no waiting
-- ticket', status 'false|NULL|NULL|NULL|NULL|0' (nothing about s1); C3 unchanged 'Held #3
-- held=now ...'.
select set_config('app.r211', format('hold [%s], unhold [%s], cancel [%s], status [%s], c3_before [%s], c3_after [%s] -> %s',
  current_setting('app.c211_hold'), current_setting('app.c211_unhold'), current_setting('app.c211_cancel'),
  current_setting('app.c211_status'), current_setting('app.st_c3_held'), pg_temp.st(current_setting('app.t_c3')::bigint),
  case when current_setting('app.c211_hold') = 'ERR [P0001]: bad ticket change: no waiting ticket'
        and current_setting('app.c211_unhold') = 'ERR [P0001]: bad ticket change: no ticket on hold'
        and current_setting('app.c211_cancel') = 'ERR [P0001]: bad ticket change: no waiting ticket'
        and current_setting('app.c211_status') = 'false|NULL|NULL|NULL|NULL|0'
        and current_setting('app.st_c3_held') = 'Held #3 held=now called=null fin=null by=null win=null'
        and pg_temp.st(current_setting('app.t_c3')::bigint) = 'Held #3 held=now called=null fin=null by=null win=null'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 7. TC-216: direct writes (s1's C3 is still Held)
-- ==========================================
-- Expected: every statement 'ERR [42501]: permission denied for table queue_tickets'; a
-- student calling queue_finish 'ERR [42501]: not allowed: ...'; C3 unchanged.
set local role authenticated;
do $$
declare r record;
begin
  for r in select * from (values
    (1, 'c216_s1_unhold', 's1',  $q$update public.queue_tickets set status = 'Waiting' where ticket_id = current_setting('app.t_c3')::bigint$q$),
    (2, 's216_s1_held_at', 's1', $q$update public.queue_tickets set held_at = now() + interval '1 day' where ticket_id = current_setting('app.t_c3')::bigint$q$),
    (3, 'c216_s3_other',  's3',  $q$update public.queue_tickets set status = 'Cancelled' where ticket_id = current_setting('app.t_c3')::bigint$q$),
    (4, 'c216_reg',       'reg', $q$update public.queue_tickets set status = 'No-show' where ticket_id = current_setting('app.t_c3')::bigint$q$),
    (5, 'c216_delete',    's1',  $q$delete from public.queue_tickets where ticket_id = current_setting('app.t_c3')::bigint$q$),
    (6, 'c216_insert',    's1',  $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, status, held_at) values (1, current_setting('app.s1')::uuid, current_date, 9999, 1000009, 'Held', now())$q$),
    (7, 'c216_finish',    's1',  $q$select 'done'::text from public.queue_finish(current_setting('app.t_c3')::bigint, 'No-show')$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt;
      perform set_config('app.' || r.label, 'ALLOWED', true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r216', format('s1_unhold [%s], s1_held_at [%s], s3_other [%s], registrar [%s], delete [%s], insert [%s], student_finish [%s], c3 [%s] -> %s',
  current_setting('app.c216_s1_unhold'), current_setting('app.s216_s1_held_at'), current_setting('app.c216_s3_other'),
  current_setting('app.c216_reg'), current_setting('app.c216_delete'), current_setting('app.c216_insert'),
  current_setting('app.c216_finish'), pg_temp.st(current_setting('app.t_c3')::bigint),
  case when current_setting('app.c216_s1_unhold') like 'ERR [42501]: permission denied%'
        and current_setting('app.s216_s1_held_at') like 'ERR [42501]: permission denied%'
        and current_setting('app.c216_s3_other') like 'ERR [42501]: permission denied%'
        and current_setting('app.c216_reg') like 'ERR [42501]: permission denied%'
        and current_setting('app.c216_delete') like 'ERR [42501]: permission denied%'
        and current_setting('app.c216_insert') like 'ERR [42501]: permission denied%'
        and current_setting('app.c216_finish') like 'ERR [42501]: not allowed:%'
        and pg_temp.st(current_setting('app.t_c3')::bigint) = 'Held #3 held=now called=null fin=null by=null win=null'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 8. TC-214 (TCH-D): notifications stay silent for the hold steps
-- ==========================================
-- Step D1: D1 (s1), D2 (s2) issued (two queue_ticket rows, before the mark).
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'cd_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCH-D') i$q$),
    (2, 'cd_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCH-D') i$q$)
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
select set_config('app.t_d1', coalesce(pg_temp.tid('TCH-D', 's1'), 0)::text, true);
select set_config('app.n_mark1', pg_temp.nmark()::text, true);
-- Step D2: hold, unhold, hold (s1); hold, cancel (s2); Registrar No-show of the held D1.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c214_hold1',   's1',  $q$select (public.queue_hold_my_ticket('TCH-D') is not null)::text$q$),
    (2, 'c214_unhold1', 's1',  $q$select 'ok'::text from public.queue_unhold_my_ticket('TCH-D')$q$),
    (3, 'c214_hold2',   's1',  $q$select (public.queue_hold_my_ticket('TCH-D') is not null)::text$q$),
    (4, 'c214_hold3',   's2',  $q$select (public.queue_hold_my_ticket('TCH-D') is not null)::text$q$),
    (5, 'c214_cancel',  's2',  $q$select 'ok'::text from public.queue_cancel_my_ticket('TCH-D')$q$),
    (6, 'c214_noshow',  'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_d1')::bigint, 'No-show')$q$)
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
select set_config('app.c214_silent', pg_temp.nkinds(current_setting('app.n_mark1')::bigint), true);
select set_config('app.n_mark2', pg_temp.nmark()::text, true);
-- Step D3: s1 gets a new ticket D3 and is called: queue_ticket + queue_turn still arrive.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c214_issue', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCH-D') i$q$),
    (2, 'c214_call',  'reg', $q$select c.ticket_label from public.queue_call_next('TCH-D') c$q$)
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
-- Expected: steps 'true, ok, true, true, ok, done'; silent '' (no row for anyone); afterwards
-- 'queue_ticket:s1,queue_turn:s1'; the call took the new ticket (L(D3)).
select set_config('app.r214', format('steps [%s, %s, %s, %s, %s, %s], during_hold_steps [%s], after [%s], call [%s] -> %s',
  current_setting('app.c214_hold1'), current_setting('app.c214_unhold1'), current_setting('app.c214_hold2'),
  current_setting('app.c214_hold3'), current_setting('app.c214_cancel'), current_setting('app.c214_noshow'),
  current_setting('app.c214_silent'), pg_temp.nkinds(current_setting('app.n_mark2')::bigint), current_setting('app.c214_call'),
  case when current_setting('app.c214_hold1') = 'true' and current_setting('app.c214_unhold1') = 'ok'
        and current_setting('app.c214_hold2') = 'true' and current_setting('app.c214_hold3') = 'true'
        and current_setting('app.c214_cancel') = 'ok' and current_setting('app.c214_noshow') = 'done'
        and current_setting('app.c214_silent') = ''
        and pg_temp.nkinds(current_setting('app.n_mark2')::bigint) = 'queue_ticket:s1,queue_turn:s1'
        and current_setting('app.c214_call') = current_setting('app.c214_issue')
        and current_setting('app.c214_issue') like '#%'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 9. TC-215 (TCH-E): the trigger, as the owner (no JWT)
-- ==========================================
insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
values (current_setting('app.sve')::bigint, current_setting('app.s3')::uuid, current_setting('app.today')::date, 9001, 1000001),
       (current_setting('app.sve')::bigint, current_setting('app.s2')::uuid, current_setting('app.today')::date, 9002, 1000002);
select set_config('app.t_e1', (select ticket_id::text from public.queue_tickets where service_id = current_setting('app.sve')::bigint and ticket_number = 9001), true);
select set_config('app.t_e2', (select ticket_id::text from public.queue_tickets where service_id = current_setting('app.sve')::bigint and ticket_number = 9002), true);
do $$
declare r record;
begin
  for r in select * from (values
    (1,  'c215_hold',      $q$update public.queue_tickets set status = 'Held', held_at = '2000-01-01 00:00:00+00' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (2,  'c215_held_at',   $q$update public.queue_tickets set held_at = '2000-01-01 00:00:00+00' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (3,  'c215_serving',   $q$update public.queue_tickets set status = 'Serving', handled_by = current_setting('app.reg')::uuid where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (4,  'c215_done',      $q$update public.queue_tickets set status = 'Done' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (5,  'c215_handler',   $q$update public.queue_tickets set handled_by = current_setting('app.reg')::uuid where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (6,  'c215_noshow_nohandler', $q$update public.queue_tickets set status = 'No-show' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (7,  'c215_noshow_window',    $q$update public.queue_tickets set status = 'No-show', handled_by = current_setting('app.reg')::uuid, window_label = 'W5' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (8,  'c215_noshow',    $q$update public.queue_tickets set status = 'No-show', handled_by = current_setting('app.reg')::uuid, called_at = '2000-01-01 00:00:00+00', finished_at = '2000-01-01 00:00:00+00' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (9,  'c215_final',     $q$update public.queue_tickets set status = 'Held' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (10, 'c215_call',      $q$update public.queue_tickets set status = 'Serving', handled_by = current_setting('app.reg')::uuid where ticket_id = current_setting('app.t_e2')::bigint$q$),
    (11, 'c215_srv_hold',  $q$update public.queue_tickets set status = 'Held' where ticket_id = current_setting('app.t_e2')::bigint$q$),
    (12, 'c215_ins_waiting_held', $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, status, held_at) values (current_setting('app.sve')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 9003, 1000003, 'Waiting', now())$q$),
    (13, 'c215_ins_held_null',    $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, status) values (current_setting('app.sve')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 9004, 1000004, 'Held')$q$),
    (14, 'c215_ins_held',  $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, status, held_at) values (current_setting('app.sve')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 9005, 1000005, 'Held', now())$q$),
    (15, 'c215_back',      $q$update public.queue_tickets set status = 'Waiting', held_at = now() where service_id = current_setting('app.sve')::bigint and ticket_number = 9005$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      perform set_config('app.' || r.label, 'ok', true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
    if r.ord = 2 then
      perform set_config('app.st215_held', pg_temp.st(current_setting('app.t_e1')::bigint), true);
    end if;
  end loop;
end $$;
-- Expected: hold 'ok' and held_at = now() (not 2000) after the hold and after the held_at
-- update ('Held #9001 held=now called=null fin=null by=null win=null'); Held -> Serving and
-- Held -> Done 'ERR [P0001]: bad ticket change: Held -> ... is not allowed (ticket <E1>)';
-- handler change refused (P0001); No-show without a handler 'ERR [23514]: ...
-- ck_queue_tickets_state'; with a window 'ERR [P0001]: bad ticket change: window_label ...';
-- No-show 'ok' -> 'No-show #9001 held=null called=null fin=now by=reg win=null' (the sent
-- times ignored); final -> 'ERR [P0001]: ... (final) ...'; E2 call 'ok', Serving -> Held
-- refused; INSERT Waiting with held_at and Held without held_at: 'ERR [23514]: ...
-- ck_queue_tickets_held'; INSERT Held with held_at 'ok'; back to Waiting with a held_at value
-- -> held=null.
select set_config('app.r215', format('hold [%s], held_row [%s], to_serving [%s], to_done [%s], handler [%s], noshow_nohandler [%s], noshow_window [%s], noshow [%s], noshow_row [%s], final [%s], call [%s], serving_to_held [%s], ins_waiting_held [%s], ins_held_null [%s], ins_held [%s], back [%s], back_row [%s] -> %s',
  current_setting('app.c215_hold'), current_setting('app.st215_held'), current_setting('app.c215_serving'),
  current_setting('app.c215_done'), current_setting('app.c215_handler'), current_setting('app.c215_noshow_nohandler'),
  current_setting('app.c215_noshow_window'), current_setting('app.c215_noshow'), pg_temp.st(current_setting('app.t_e1')::bigint),
  current_setting('app.c215_final'), current_setting('app.c215_call'), current_setting('app.c215_srv_hold'),
  current_setting('app.c215_ins_waiting_held'), current_setting('app.c215_ins_held_null'), current_setting('app.c215_ins_held'),
  current_setting('app.c215_back'),
  pg_temp.st((select ticket_id from public.queue_tickets where service_id = current_setting('app.sve')::bigint and ticket_number = 9005)),
  case when current_setting('app.c215_hold') = 'ok' and current_setting('app.c215_held_at') = 'ok'
        and current_setting('app.st215_held') = 'Held #9001 held=now called=null fin=null by=null win=null'
        and current_setting('app.c215_serving') = format('ERR [P0001]: bad ticket change: Held -> Serving is not allowed (ticket %s)', current_setting('app.t_e1'))
        and current_setting('app.c215_done') = format('ERR [P0001]: bad ticket change: Held -> Done is not allowed (ticket %s)', current_setting('app.t_e1'))
        and current_setting('app.c215_handler') like 'ERR [P0001]: bad ticket change: handled_by and window_label%'
        and current_setting('app.c215_noshow_nohandler') like 'ERR [23514]:%ck_queue_tickets_state%'
        and current_setting('app.c215_noshow_window') like 'ERR [P0001]: bad ticket change: window_label%'
        and current_setting('app.c215_noshow') = 'ok'
        and pg_temp.st(current_setting('app.t_e1')::bigint) = 'No-show #9001 held=null called=null fin=now by=reg win=null'
        and current_setting('app.c215_final') like 'ERR [P0001]: bad ticket change:%(final)%'
        and current_setting('app.c215_call') = 'ok'
        and current_setting('app.c215_srv_hold') = format('ERR [P0001]: bad ticket change: Serving -> Held is not allowed (ticket %s)', current_setting('app.t_e2'))
        and current_setting('app.c215_ins_waiting_held') like 'ERR [23514]:%ck_queue_tickets_held%'
        and current_setting('app.c215_ins_held_null') like 'ERR [23514]:%ck_queue_tickets_held%'
        and current_setting('app.c215_ins_held') = 'ok' and current_setting('app.c215_back') = 'ok'
        and pg_temp.st((select ticket_id from public.queue_tickets where service_id = current_setting('app.sve')::bigint and ticket_number = 9005))
            = 'Waiting #9005 held=null called=null fin=null by=null win=null'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 10. TC-217 (TCH-F): regression of the existing queue behaviour
-- ==========================================
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1,  'cf_issue1',   'reg', $q$select i.ticket_label || '|' || i.status || '|' || i.people_ahead from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCH-F') i$q$),
    (2,  'cf_issue2',   'reg', $q$select i.ticket_label || '|' || i.status || '|' || i.people_ahead from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCH-F') i$q$),
    (3,  'cf_s2',       's2',  $q$select m.ticket_status || '|' || coalesce(m.people_ahead::text, 'NULL') || '|' || m.waiting_total || '|' || coalesce(m.held_until::text, 'NULL') || '|' || coalesce(m.window_label, 'NULL') from public.queue_my_status('TCH-F') m$q$),
    (4,  'cf_cancel2',  's2',  $q$select 'ok'::text from public.queue_cancel_my_ticket('TCH-F')$q$),
    (5,  'cf_call1',    'reg', $q$select c.ticket_label || '|' || c.student_number || '|' || c.window_label from public.queue_call_next('TCH-F', '  W9  ') c$q$),
    (6,  'cf_s1',       's1',  $q$select m.ticket_status || '|' || coalesce(m.people_ahead::text, 'NULL') || '|' || m.waiting_total || '|' || coalesce(m.held_until::text, 'NULL') || '|' || coalesce(m.window_label, 'NULL') || '|' || coalesce(m.now_serving, 'NULL') from public.queue_my_status('TCH-F') m$q$),
    (7,  'cf_cancel1',  's1',  $q$select 'ok'::text from public.queue_cancel_my_ticket('TCH-F')$q$),
    (8,  'cf_first',    'reg', $q$select c.ticket_label from public.queue_call_next('TCH-F') c$q$),
    (9,  'cf_fin1',     'reg', $q$select 'done'::text from public.queue_finish((select max(t.ticket_id) from public.queue_tickets t where t.status = 'Serving' and t.handled_by = auth.uid() and t.service_id = (select s.service_id from public.queue_services s where s.service_code = 'TCH-F')), 'Done')$q$),
    (10, 'cf_s1_done',  's1',  $q$select m.ticket_status || '|' || coalesce(m.people_ahead::text, 'NULL') || '|' || coalesce(m.held_until::text, 'NULL') || '|' || coalesce(m.avg_service_seconds::text, 'NULL') from public.queue_my_status('TCH-F') m$q$),
    (11, 'cf_issue3',   'reg', $q$select i.ticket_label || '|' || i.people_ahead from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCH-F') i$q$),
    (12, 'cf_staff',    'reg', $q$select string_agg(s.ticket_number || ':' || s.status || ':' || coalesce(s.held_at::text, 'NULL'), ',' order by s.ticket_number) from public.queue_staff_list('TCH-F') s$q$),
    (13, 'cf_card',     'reg', $q$select c.student_number || '|' || count(*) over () from public.queue_student_card(current_setting('app.s1')::uuid) c$q$)
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
select set_config('app.t_f1', coalesce(pg_temp.tid('TCH-F', 's1'), 0)::text, true);
select set_config('app.t_f3', coalesce(pg_temp.tid('TCH-F', 's2'), 0)::text, true);
select set_config('app.l_f1', pg_temp.lbl(current_setting('app.t_f1')::bigint), true);
select set_config('app.l_f3', pg_temp.lbl(current_setting('app.t_f3')::bigint), true);
select set_config('app.n_mark3', pg_temp.nmark()::text, true);
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'cf_call3',  'reg', $q$select c.ticket_label from public.queue_call_next('TCH-F') c$q$),
    (2, 'cf_noshow', 'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_f3')::bigint, 'No-show')$q$)
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
-- Expected: issue1 'L(F1)|Waiting|0', issue2 '...|Waiting|1'; s2 'Waiting|1|2|NULL|NULL';
-- cancel 'ok'; call 'L(F1)|<s1 number>|W9' (window trimmed); s1 'Serving|0|0|NULL|W9|L(F1)';
-- s1 cancel 'ERR [P0001]: bad ticket change: ticket L(F1) is being served and cannot be
-- cancelled'; second call 'ERR [P0001]: finish first: L(F1)'; Done 'done'; s1
-- 'Done|NULL|NULL|0'; s2's new ticket 'L(F3)|0'; staff list '1:Done:NULL,2:Cancelled:NULL,
-- 3:Waiting:NULL'; card '<s1 number>|1'; call L(F3), No-show 'done' -> notifications
-- 'queue_turn:s2,queue_skipped:s2'; F1 'Done #1 held=null called=now fin=now by=reg win=W9'.
select set_config('app.r217', format('issue1 [%s], issue2 [%s], s2 [%s], cancel [%s], call [%s], s1 [%s], cancel_serving [%s], finish_first [%s], done [%s], s1_done [%s], reissue [%s], staff [%s], card [%s], call3 [%s], noshow [%s], notes [%s], f1 [%s] -> %s',
  current_setting('app.cf_issue1'), current_setting('app.cf_issue2'), current_setting('app.cf_s2'), current_setting('app.cf_cancel2'),
  current_setting('app.cf_call1'), current_setting('app.cf_s1'), current_setting('app.cf_cancel1'), current_setting('app.cf_first'),
  current_setting('app.cf_fin1'), current_setting('app.cf_s1_done'), current_setting('app.cf_issue3'), current_setting('app.cf_staff'),
  current_setting('app.cf_card'), current_setting('app.cf_call3'), current_setting('app.cf_noshow'),
  pg_temp.nkinds(current_setting('app.n_mark3')::bigint), pg_temp.st(current_setting('app.t_f1')::bigint),
  case when current_setting('app.cf_issue1') = current_setting('app.l_f1') || '|Waiting|0'
        and current_setting('app.cf_issue2') like '#%|Waiting|1'
        and current_setting('app.cf_s2') = 'Waiting|1|2|NULL|NULL'
        and current_setting('app.cf_cancel2') = 'ok'
        and current_setting('app.cf_call1') = current_setting('app.l_f1') || '|' || current_setting('app.s1num') || '|W9'
        and current_setting('app.cf_s1') = 'Serving|0|0|NULL|W9|' || current_setting('app.l_f1')
        and current_setting('app.cf_cancel1') = format('ERR [P0001]: bad ticket change: ticket %s is being served and cannot be cancelled', current_setting('app.l_f1'))
        and current_setting('app.cf_first') = format('ERR [P0001]: finish first: %s', current_setting('app.l_f1'))
        and current_setting('app.cf_fin1') = 'done'
        and current_setting('app.cf_s1_done') = 'Done|NULL|NULL|0'
        and current_setting('app.cf_issue3') = current_setting('app.l_f3') || '|0'
        and current_setting('app.cf_staff') = '1:Done:NULL,2:Cancelled:NULL,3:Waiting:NULL'
        and current_setting('app.cf_card') = current_setting('app.s1num') || '|1'
        and current_setting('app.cf_call3') = current_setting('app.l_f3')
        and current_setting('app.cf_noshow') = 'done'
        and pg_temp.nkinds(current_setting('app.n_mark3')::bigint) = 'queue_turn:s2,queue_skipped:s2'
        and pg_temp.st(current_setting('app.t_f1')::bigint) = 'Done #1 held=null called=now fin=now by=reg win=W9'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- Result: ONE row
-- ==========================================
select (current_setting('app.r199') like '%-> OK' and current_setting('app.r200') like '%-> OK'
        and current_setting('app.r201') like '%-> OK' and current_setting('app.r202') like '%-> OK'
        and current_setting('app.r203') like '%-> OK' and current_setting('app.r204') like '%-> OK'
        and current_setting('app.r205') like '%-> OK' and current_setting('app.r206') like '%-> OK'
        and current_setting('app.r207') like '%-> OK' and current_setting('app.r208') like '%-> OK'
        and current_setting('app.r209') like '%-> OK' and current_setting('app.r210') like '%-> OK'
        and current_setting('app.r211') like '%-> OK' and current_setting('app.r212') like '%-> OK'
        and current_setting('app.r213') like '%-> OK' and current_setting('app.r214') like '%-> OK'
        and current_setting('app.r215') like '%-> OK' and current_setting('app.r216') like '%-> OK'
        and current_setting('app.r217') like '%-> OK') as all_ok,
  current_setting('app.r199') as tc199, current_setting('app.r200') as tc200, current_setting('app.r201') as tc201,
  current_setting('app.r202') as tc202, current_setting('app.r203') as tc203, current_setting('app.r204') as tc204,
  current_setting('app.r205') as tc205, current_setting('app.r206') as tc206, current_setting('app.r207') as tc207,
  current_setting('app.r208') as tc208, current_setting('app.r209') as tc209, current_setting('app.r210') as tc210,
  current_setting('app.r211') as tc211, current_setting('app.r212') as tc212, current_setting('app.r213') as tc213,
  current_setting('app.r214') as tc214, current_setting('app.r215') as tc215, current_setting('app.r216') as tc216,
  current_setting('app.r217') as tc217;

rollback;
