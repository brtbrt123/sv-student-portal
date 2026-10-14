-- ==========================================
-- REHEARSAL: queue_rules.sql + TC-139 to TC-166 in ONE rolled-back transaction
-- ==========================================
-- Virtual queue (ticket numbers) for the Registrar window (feature/queue-system). One paste,
-- one run, ONE result row, nothing committed. This is TC-139R.
--
-- How to run: Supabase SQL editor, as postgres, a new tab. Paste the whole file (from
-- "begin;" to "rollback;") and click Run on the whole tab, never a selection. If the script
-- stops with an error, run "rollback;" as its own query and send the error back.
--
-- What it does:
--   1. begin;
--   2. the body of docs/database/queue_rules.sql (everything between its "BEGIN;" and
--      "COMMIT;" lines, copied verbatim: safety checks, tables, services, helpers, trigger,
--      functions, policies, grants, checks after the change; the NOTIFY is never sent because
--      of the rollback). A "queue_rules: ..." error here means the live state is not what the
--      file assumes: do NOT run the file live; send the error back.
--   3. TC-139 to TC-166 (docs/database/queue_rules_test.sql, verbatim). The tests create
--      three throwaway services (TCQ-A / TCQ-B / TCQ-C) and their tickets (TC-165 may add one
--      ticket of Student 2 to the real Enrollment service, rolled back); seed students are
--      only ticket holders (no account is created). Each result is stored with
--      set_config('app.rNNN', ...).
--   4. One final row: one cell per case, each ending in "-> OK" or "-> FAIL", plus "all_ok".
--      TC-162 also lists every CHECK / UNIQUE constraint on profiles, students, audit_logs
--      and the queue tables (informational: read it).
--   5. rollback; (tables, functions, policies, grants and all test data disappear)
--
-- RUNNING ONLY THE TESTS (after the change is live): the test part starts at the line
-- "-- TESTS START HERE" and is self-contained: copy from the "begin;" line right below that
-- marker to the end of the file into a new tab and run it (or run
-- docs/database/queue_rules_test.sql, which is the same). It ends in rollback.
--
-- Every statement that is expected to fail runs inside a do block with an exception
-- handler, so the transaction is never aborted by an expected error.
--
-- Status: NOT RUN YET (written 2026-10-13 without a local PostgreSQL).

begin;

-- ==========================================
-- 1. The change (body of queue_rules.sql, verbatim)
-- ==========================================


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






-- ==========================================
-- TESTS START HERE (TC-139 to TC-166)
-- ==========================================
-- To run ONLY the tests once queue_rules.sql is live: copy from the next line ("begin;") to
-- the end of this file into a new tab and run that tab as a whole.
-- In the full rehearsal the next line is a second BEGIN inside the open transaction;
-- PostgreSQL only answers "WARNING: there is already a transaction in progress" and carries
-- on (nothing is committed either way; the file ends in rollback).
begin;

-- ==========================================
-- 1. Accounts, ids, throwaway services (as postgres, no user JWT)
-- ==========================================
select set_config('request.jwt.claims', '', true);
select set_config('app.cur', '', true);
select set_config('app.s1',   coalesce((select id::text from auth.users where email = 'student1@pnc.test'), ''), true);
select set_config('app.s2',   coalesce((select id::text from auth.users where email = 'student2@pnc.test'), ''), true);
select set_config('app.s3',   coalesce((select id::text from auth.users where email = 'student3@pnc.test'), ''), true);
select set_config('app.reg',  coalesce((select id::text from auth.users where email = 'registrar@pnc.test'), ''), true);
select set_config('app.cash', coalesce((select id::text from auth.users where email = 'cashier@pnc.test'), ''), true);
select set_config('app.dept', coalesce((select id::text from auth.users where email = 'dept@pnc.test'), ''), true);
select set_config('app.adm',  coalesce((select id::text from auth.users where email = 'admin@pnc.test'), ''), true);
select set_config('app.today',     ((now() at time zone 'Asia/Manila')::date)::text, true);
select set_config('app.yesterday', ((now() at time zone 'Asia/Manila')::date - 1)::text, true);
do $$
declare v_bad text;
begin
  if to_regclass('public.queue_tickets') is null or to_regclass('public.queue_services') is null
     or to_regclass('public.queue_counters') is null
     or to_regprocedure('public.issue_queue_ticket(uuid, text)') is null
     or to_regprocedure('public.queue_student_card(uuid)') is null then
    raise exception 'TC setup: queue_rules.sql is not installed (run it, or use queue_rules_rehearsal.sql)';
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
  if exists (select 1 from public.queue_services
              where service_code in ('TCQ-A', 'TCQ-B', 'TCQ-C', 'TCQ-D', 'TCQ-Z') or ticket_prefix in ('X', 'Y', 'W', 'Z')) then
    raise exception 'TC setup: a queue service with code TCQ-A..D / TCQ-Z or prefix X, Y, W, Z exists; the tests need them free';
  end if;
  if not exists (select 1 from public.queue_services where service_code = 'Enrollment') then
    raise exception 'TC setup: the Enrollment service is missing';
  end if;
end $$;
select set_config('app.s1num',  (select student_number::text from public.students where student_id::text = current_setting('app.s1')), true);
select set_config('app.s2num',  (select student_number::text from public.students where student_id::text = current_setting('app.s2')), true);
select set_config('app.s3num',  (select student_number::text from public.students where student_id::text = current_setting('app.s3')), true);
select set_config('app.s1name', (select last_name::text || ', ' || first_name::text from public.profiles where profile_id::text = current_setting('app.s1')), true);
select set_config('app.s2name', (select last_name::text || ', ' || first_name::text from public.profiles where profile_id::text = current_setting('app.s2')), true);
select set_config('app.s1last', (select last_name::text from public.profiles where profile_id::text = current_setting('app.s1')), true);
select set_config('app.s3last', (select last_name::text from public.profiles where profile_id::text = current_setting('app.s3')), true);
select set_config('app.log_mark', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);
insert into public.queue_services (service_code, service_name, ticket_prefix, is_open) values
  ('TCQ-A', 'TC queue A', 'X', true), ('TCQ-B', 'TC queue B (closed)', 'Y', false), ('TCQ-C', 'TC queue C', 'W', true);
select set_config('app.sva', (select service_id::text from public.queue_services where service_code = 'TCQ-A'), true);
select set_config('app.svb', (select service_id::text from public.queue_services where service_code = 'TCQ-B'), true);
select set_config('app.svc', (select service_id::text from public.queue_services where service_code = 'TCQ-C'), true);
select set_config('app.enr', (select service_id::text from public.queue_services where service_code = 'Enrollment'), true);

-- ==========================================
-- 2. TC-139: installed as intended (catalog)
-- ==========================================
-- Expected: columns_diff empty, checks 9, code_unique true, active_index true, rls 3, the 2
-- SELECT policies, triggers 'audit_log 29 O, require_queue_ticket_rules 19 O', no trigger on
-- the other two tables, services 'Documents:Document claim:D, Enrollment:Enrollment:E',
-- 7/7 and 6/6.
select set_config('app.r139', (select format('columns_diff [%s], checks %s, code_unique %s, active_index %s, rls %s, policies [%s], triggers [%s], other_triggers %s, services [%s], public_fns_ok %s/7, private_fns_ok %s/6 -> %s',
    x.cols_diff, x.checks, x.code_uq, x.active_idx, x.rls, x.pol, x.trg, x.other_trg, x.svc, x.pub_ok, x.priv_ok,
    case when x.cols_diff = '' and x.checks = 9 and x.code_uq and x.active_idx and x.rls = 3
          and x.pol = 'queue_services.queue_services_read (SELECT), queue_tickets.queue_tickets_read (SELECT)'
          and x.trg = 'audit_log 29 O, require_queue_ticket_rules 19 O' and x.other_trg = 0
          and x.svc = 'Documents:Document claim:D, Enrollment:Enrollment:E'
          and x.pub_ok = 7 and x.priv_ok = 6
         then 'OK' else 'FAIL' end)
  from (select
    coalesce((with expected(t, col, typ) as (values
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
              live as (
                select c.relname::text as t, a.attname::text as col, format_type(a.atttypid, null) as typ
                from pg_attribute a join pg_class c on c.oid = a.attrelid
                where c.relnamespace = 'public'::regnamespace
                  and c.relname in ('queue_services', 'queue_tickets', 'queue_counters')
                  and a.attnum > 0 and not a.attisdropped)
              select string_agg(d, '; ' order by d) from (
                (select 'missing ' || t || '.' || col || ' ' || typ as d from (select * from expected except select * from live) m)
                union all
                (select 'unexpected ' || t || '.' || col || ' ' || typ from (select * from live except select * from expected) u)) dd), '') as cols_diff,
    (select count(*) from pg_constraint c
      where c.contype = 'c'
        and c.conrelid in ('public.queue_services'::regclass, 'public.queue_tickets'::regclass, 'public.queue_counters'::regclass)
        and c.conname in ('ck_queue_services_code', 'ck_queue_services_name', 'ck_queue_services_prefix',
                          'ck_queue_tickets_number', 'ck_queue_tickets_code', 'ck_queue_tickets_status',
                          'ck_queue_tickets_window', 'ck_queue_tickets_state', 'ck_queue_counters_last_number')) as checks,
    exists (select 1 from pg_constraint c
             where c.conrelid = 'public.queue_tickets'::regclass and c.contype = 'u' and c.conname = 'uq_queue_tickets_code'
               and pg_get_constraintdef(c.oid) = 'UNIQUE (service_id, queue_date, ticket_code)') as code_uq,
    exists (select 1 from pg_index i
             where i.indexrelid = to_regclass('public.uq_queue_tickets_active_student')
               and i.indrelid = 'public.queue_tickets'::regclass and i.indisunique and i.indpred is not null
               and pg_get_indexdef(i.indexrelid) like '%(student_id, service_id, queue_date)%Waiting%Serving%') as active_idx,
    (select count(*) from pg_class c
      where c.oid in ('public.queue_services'::regclass, 'public.queue_tickets'::regclass, 'public.queue_counters'::regclass)
        and c.relrowsecurity) as rls,
    coalesce((select string_agg(p.tablename || '.' || p.policyname || ' (' || p.cmd || ')', ', ' order by p.tablename, p.policyname)
                from pg_policies p
               where p.schemaname = 'public' and p.tablename in ('queue_services', 'queue_tickets', 'queue_counters')), '') as pol,
    coalesce((select string_agg(t.tgname || ' ' || t.tgtype || ' ' || t.tgenabled::text, ', ' order by t.tgname)
                from pg_trigger t
               where t.tgrelid = 'public.queue_tickets'::regclass and not t.tgisinternal
                 and t.tgfoid in (to_regprocedure('private.audit_log()'), to_regprocedure('private.require_queue_ticket_rules()'))), '') as trg,
    (select count(*) from pg_trigger t
      where t.tgrelid in ('public.queue_services'::regclass, 'public.queue_counters'::regclass) and not t.tgisinternal) as other_trg,
    coalesce((select string_agg(s.service_code || ':' || s.service_name || ':' || s.ticket_prefix, ', ' order by s.service_code)
                from public.queue_services s where s.service_code in ('Enrollment', 'Documents')), '') as svc,
    (select count(*) from pg_proc p
      where p.oid in (to_regprocedure('public.issue_queue_ticket(uuid, text)'),
                      to_regprocedure('public.queue_call_next(text, text)'),
                      to_regprocedure('public.queue_finish(bigint, text)'),
                      to_regprocedure('public.queue_cancel_my_ticket(text)'),
                      to_regprocedure('public.queue_my_status(text)'),
                      to_regprocedure('public.queue_staff_list(text)'),
                      to_regprocedure('public.queue_student_card(uuid)'))
        and p.prosecdef and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
        and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
        and not has_function_privilege('anon', p.oid, 'EXECUTE')
        and has_function_privilege('authenticated', p.oid, 'EXECUTE')
        and exists (select 1 from pg_roles r join pg_class c on c.oid = 'public.students'::regclass
                     where r.oid = p.proowner
                       and (r.rolbypassrls or (c.relowner = r.oid and not c.relforcerowsecurity)))) as pub_ok,
    (select count(*) from pg_proc p
      where p.oid in (to_regprocedure('private.queue_today()'),
                      to_regprocedure('private.queue_label(integer)'),
                      to_regprocedure('private.queue_random_code()'),
                      to_regprocedure('private.queue_require_role(text)'),
                      to_regprocedure('private.queue_service_row(text)'),
                      to_regprocedure('private.require_queue_ticket_rules()'))
        and not p.prosecdef and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
        and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
        and not has_function_privilege('anon', p.oid, 'EXECUTE')
        and (p.proname = 'require_queue_ticket_rules' or not has_function_privilege('authenticated', p.oid, 'EXECUTE'))) as priv_ok
  ) x), true);

-- ==========================================
-- 3. TC-140: table grants
-- ==========================================
-- Expected: anon_selects 'queue_services denied; queue_tickets denied; queue_counters denied; ',
-- anon_privs '', auth_select_all true, auth_other_privs '', column_acls 0, seq_privs ''.
set local role anon;
do $$
declare t text; n bigint; v_out text := '';
begin
  foreach t in array array['queue_services', 'queue_tickets', 'queue_counters'] loop
    begin
      execute 'select count(*) from public.' || t into n;
      v_out := v_out || t || ' ALLOWED rows ' || n || '; ';
    exception when others then
      v_out := v_out || t || case when sqlerrm like 'permission denied%' then ' denied; '
                                  else ' ERR [' || sqlstate || ']: ' || sqlerrm || '; ' end;
    end;
  end loop;
  perform set_config('app.t140_anon', v_out, true);
end $$;
reset role;
select set_config('app.r140', (select format('anon_selects [%s], anon_privs [%s], auth_select_all %s, auth_other_privs [%s], column_acls %s, seq_privs [%s] -> %s',
    current_setting('app.t140_anon'), x.anon_privs, x.auth_select, x.auth_other, x.col_acls, x.seq_privs,
    case when current_setting('app.t140_anon') = 'queue_services denied; queue_tickets denied; queue_counters denied; '
          and x.anon_privs = '' and x.auth_select and x.auth_other = '' and x.col_acls = 0 and x.seq_privs = ''
         then 'OK' else 'FAIL' end)
  from (select
    coalesce((select string_agg(tt.t || ' ' || v.priv, ', ')
                from (values ('queue_services'), ('queue_tickets'), ('queue_counters')) as tt(t)
                cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'),
                                   ('TRIGGER'), ('MAINTAIN')) as v(priv)
               where has_table_privilege('anon', 'public.' || tt.t, v.priv)
                  or (v.priv in ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
                      and has_any_column_privilege('anon', 'public.' || tt.t, v.priv))), '') as anon_privs,
    (has_table_privilege('authenticated', 'public.queue_services', 'SELECT')
     and has_table_privilege('authenticated', 'public.queue_tickets', 'SELECT')
     and has_table_privilege('authenticated', 'public.queue_counters', 'SELECT')) as auth_select,
    coalesce((select string_agg(tt.t || ' ' || v.priv, ', ')
                from (values ('queue_services'), ('queue_tickets'), ('queue_counters')) as tt(t)
                cross join (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'),
                                   ('TRIGGER'), ('MAINTAIN')) as v(priv)
               where has_table_privilege('authenticated', 'public.' || tt.t, v.priv)
                  or (v.priv in ('INSERT', 'UPDATE', 'REFERENCES')
                      and has_any_column_privilege('authenticated', 'public.' || tt.t, v.priv))), '') as auth_other,
    (select count(*) from pg_attribute a
      where a.attrelid in ('public.queue_services'::regclass, 'public.queue_tickets'::regclass, 'public.queue_counters'::regclass)
        and a.attnum > 0 and not a.attisdropped and a.attacl is not null) as col_acls,
    coalesce((select string_agg(s.s || ' ' || w.who, ', ')
                from (values (pg_get_serial_sequence('public.queue_services', 'service_id')),
                             (pg_get_serial_sequence('public.queue_tickets', 'ticket_id'))) as s(s)
                cross join (values ('anon'), ('authenticated')) as w(who)
               where has_sequence_privilege(w.who, s.s, 'USAGE, SELECT, UPDATE')), '') as seq_privs
  ) x), true);

-- ==========================================
-- 4. TC-141 and TC-142: the Registrar issues tickets
-- ==========================================
-- Expected TC-141: '<id>|L(1)|Waiting|<today>|0' with L(1) = '#' + 7 digits = '#' ||
-- ticket_code of the stored row; internal number 1; code in 1000000..9999999; the row is
-- Waiting, created_at = now(), no call / finish / handler / window.
-- Expected TC-142: '<id>|L(2)|Waiting|<today>|1'; internal number 2; counter 2; L(2) <> L(1).
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c141', 'reg', $q$select i.ticket_id || '|' || i.ticket_label || '|' || i.status || '|' || i.queue_date || '|' || i.people_ahead
                          from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCQ-A') i$q$),
    (2, 'c142', 'reg', $q$select i.ticket_id || '|' || i.ticket_label || '|' || i.status || '|' || i.queue_date || '|' || i.people_ahead
                          from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCQ-A') i$q$)
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
select set_config('app.t_x1', coalesce((select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.sva')::bigint and queue_date = current_setting('app.today')::date and ticket_number = 1), '0'), true);
select set_config('app.t_x2', coalesce((select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.sva')::bigint and queue_date = current_setting('app.today')::date and ticket_number = 2), '0'), true);
select set_config('app.l_x1', coalesce((select '#' || ticket_code from public.queue_tickets where ticket_id = current_setting('app.t_x1')::bigint), 'none'), true);
select set_config('app.l_x2', coalesce((select '#' || ticket_code from public.queue_tickets where ticket_id = current_setting('app.t_x2')::bigint), 'none'), true);
select set_config('app.r141', format('issued [%s], label_format %s, row_ok %s -> %s',
  current_setting('app.c141'), current_setting('app.l_x1') ~ '^#[1-9][0-9]{6}$',
  coalesce((select (t.status = 'Waiting' and t.student_id::text = current_setting('app.s1') and t.created_at = now()
                    and t.called_at is null and t.finished_at is null and t.handled_by is null and t.window_label is null
                    and t.checkin_photo_path is null and t.ticket_code between 1000000 and 9999999)::text
              from public.queue_tickets t where t.ticket_id = current_setting('app.t_x1')::bigint), 'none'),
  case when current_setting('app.c141') = format('%s|%s|Waiting|%s|0', current_setting('app.t_x1'), current_setting('app.l_x1'), current_setting('app.today'))
        and current_setting('app.l_x1') ~ '^#[1-9][0-9]{6}$'
        and coalesce((select t.status = 'Waiting' and t.student_id::text = current_setting('app.s1') and t.created_at = now()
                             and t.called_at is null and t.finished_at is null and t.handled_by is null and t.window_label is null
                             and t.ticket_code between 1000000 and 9999999
                        from public.queue_tickets t where t.ticket_id = current_setting('app.t_x1')::bigint), false)
       then 'OK' else 'FAIL' end), true);
select set_config('app.r142', format('issued [%s], counter %s, codes_differ %s -> %s',
  current_setting('app.c142'),
  coalesce((select c.last_number::text from public.queue_counters c
             where c.service_id = current_setting('app.sva')::bigint and c.queue_date = current_setting('app.today')::date), 'none'),
  current_setting('app.l_x1') <> current_setting('app.l_x2'),
  case when current_setting('app.c142') = format('%s|%s|Waiting|%s|1', current_setting('app.t_x2'), current_setting('app.l_x2'), current_setting('app.today'))
        and current_setting('app.l_x2') ~ '^#[1-9][0-9]{6}$'
        and current_setting('app.l_x1') <> current_setting('app.l_x2')
        and (select c.last_number from public.queue_counters c
              where c.service_id = current_setting('app.sva')::bigint and c.queue_date = current_setting('app.today')::date) = 2
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 5. TC-143: the same student twice
-- ==========================================
-- Expected: 'ERR [P0001]: already queued: L(1)'; still one ticket of Student 1, counter 2.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c143', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCQ-A') i$q$)
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
select set_config('app.r143', format('second issue [%s], s1_tickets %s, counter %s -> %s',
  current_setting('app.c143'),
  (select count(*) from public.queue_tickets where service_id = current_setting('app.sva')::bigint
     and student_id::text = current_setting('app.s1')),
  (select c.last_number from public.queue_counters c
    where c.service_id = current_setting('app.sva')::bigint and c.queue_date = current_setting('app.today')::date),
  case when current_setting('app.c143') = 'ERR [P0001]: already queued: ' || current_setting('app.l_x1')
        and (select count(*) from public.queue_tickets where service_id = current_setting('app.sva')::bigint
               and student_id::text = current_setting('app.s1')) = 1
        and (select c.last_number from public.queue_counters c
              where c.service_id = current_setting('app.sva')::bigint and c.queue_date = current_setting('app.today')::date) = 2
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 6. TC-144: who may issue
-- ==========================================
-- Expected: Student / Cashier / Department / Admin: 'ERR [42501]: not allowed: ...'; anon:
-- 'ERR [42501]: permission denied for function issue_queue_ticket'; the Registrar made
-- inactive: 'ERR [42501]: not allowed: ...'; no ticket for Student 3, counter still 2.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c144_student', 's1',   $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCQ-A') i$q$),
    (2, 'c144_cashier', 'cash', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCQ-A') i$q$),
    (3, 'c144_dept',    'dept', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCQ-A') i$q$),
    (4, 'c144_admin',   'adm',  $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCQ-A') i$q$)
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
declare v text;
begin
  select i.ticket_label into v from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCQ-A') i;
  perform set_config('app.c144_anon', coalesce(v, 'NULL'), true);
exception when others then
  perform set_config('app.c144_anon', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
reset role;
update public.profiles set is_active = false where profile_id::text = current_setting('app.reg');
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c144_inactive', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCQ-A') i$q$)
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
update public.profiles set is_active = true where profile_id::text = current_setting('app.reg');
select set_config('app.r144', format('student [%s], cashier [%s], department [%s], admin [%s], anon [%s], inactive_registrar [%s], s3_tickets %s, counter %s -> %s',
  current_setting('app.c144_student'), current_setting('app.c144_cashier'), current_setting('app.c144_dept'),
  current_setting('app.c144_admin'), current_setting('app.c144_anon'), current_setting('app.c144_inactive'),
  (select count(*) from public.queue_tickets where service_id = current_setting('app.sva')::bigint
     and student_id::text = current_setting('app.s3')),
  (select c.last_number from public.queue_counters c
    where c.service_id = current_setting('app.sva')::bigint and c.queue_date = current_setting('app.today')::date),
  case when current_setting('app.c144_student') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c144_cashier') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c144_dept') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c144_admin') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c144_anon') like 'ERR [42501]: permission denied for function issue_queue_ticket%'
        and current_setting('app.c144_inactive') like 'ERR [42501]: not allowed:%'
        and (select count(*) from public.queue_tickets where service_id = current_setting('app.sva')::bigint
               and student_id::text = current_setting('app.s3')) = 0
        and (select c.last_number from public.queue_counters c
              where c.service_id = current_setting('app.sva')::bigint and c.queue_date = current_setting('app.today')::date) = 2
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 7. TC-145: bad targets and services
-- ==========================================
-- Expected: every case 'ERR [22023]: invalid ticket request: ...' (not a student, unknown id,
-- NULL id, inactive student, unknown service, NULL service); no ticket for Student 3,
-- counter still 2.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c145_nonstudent', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.reg')::uuid, 'TCQ-A') i$q$),
    (2, 'c145_unknown',    'reg', $q$select i.ticket_label from public.issue_queue_ticket(gen_random_uuid(), 'TCQ-A') i$q$),
    (3, 'c145_null',       'reg', $q$select i.ticket_label from public.issue_queue_ticket(null::uuid, 'TCQ-A') i$q$),
    (4, 'c145_service',    'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'NoSuchService') i$q$),
    (5, 'c145_nullsvc',    'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, null) i$q$)
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
update public.profiles set is_active = false where profile_id::text = current_setting('app.s3');
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c145_inactive', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCQ-A') i$q$)
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
update public.profiles set is_active = true where profile_id::text = current_setting('app.s3');
select set_config('app.r145', format('non_student [%s], unknown_id [%s], null_id [%s], unknown_service [%s], null_service [%s], inactive_student [%s], s3_tickets %s, counter %s -> %s',
  current_setting('app.c145_nonstudent'), current_setting('app.c145_unknown'), current_setting('app.c145_null'),
  current_setting('app.c145_service'), current_setting('app.c145_nullsvc'), current_setting('app.c145_inactive'),
  (select count(*) from public.queue_tickets where student_id::text = current_setting('app.s3')
     and service_id = current_setting('app.sva')::bigint),
  (select c.last_number from public.queue_counters c
    where c.service_id = current_setting('app.sva')::bigint and c.queue_date = current_setting('app.today')::date),
  case when current_setting('app.c145_nonstudent') = 'ERR [22023]: invalid ticket request: the person is not an active student'
        and current_setting('app.c145_unknown') = 'ERR [22023]: invalid ticket request: the person is not an active student'
        and current_setting('app.c145_null') = 'ERR [22023]: invalid ticket request: the person is not an active student'
        and current_setting('app.c145_service') like 'ERR [22023]: invalid ticket request: unknown service%'
        and current_setting('app.c145_nullsvc') like 'ERR [22023]: invalid ticket request: unknown service%'
        and current_setting('app.c145_inactive') = 'ERR [22023]: invalid ticket request: the person is not an active student'
        and (select count(*) from public.queue_tickets where student_id::text = current_setting('app.s3')
               and service_id = current_setting('app.sva')::bigint) = 0
        and (select c.last_number from public.queue_counters c
              where c.service_id = current_setting('app.sva')::bigint and c.queue_date = current_setting('app.today')::date) = 2
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 8. TC-146: closed service
-- ==========================================
-- Expected: 'ERR [P0001]: queue closed: ...'; no counter row and no ticket for TCQ-B.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c146', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCQ-B') i$q$)
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
select set_config('app.r146', format('closed [%s], counters %s, tickets %s -> %s',
  current_setting('app.c146'),
  (select count(*) from public.queue_counters where service_id = current_setting('app.svb')::bigint),
  (select count(*) from public.queue_tickets where service_id = current_setting('app.svb')::bigint),
  case when current_setting('app.c146') like 'ERR [P0001]: queue closed:%'
        and (select count(*) from public.queue_counters where service_id = current_setting('app.svb')::bigint) = 0
        and (select count(*) from public.queue_tickets where service_id = current_setting('app.svb')::bigint) = 0
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 9. TC-147: numbering restarts on a new Manila day
-- ==========================================
-- Setup as postgres: TCQ-C's counter for yesterday is 57 and Student 3 has yesterday's
-- ticket 57 (code 5757575) still Waiting. Expected: the Registrar issues Student 3 a ticket
-- today: '<id>|L(W1)|Waiting|<today>|0' with internal number 1; yesterday's counter still
-- 57, today's 1; Student 3 has two Waiting tickets in TCQ-C.
insert into public.queue_counters (service_id, queue_date, last_number)
values (current_setting('app.svc')::bigint, current_setting('app.yesterday')::date, 57);
insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, created_at)
values (current_setting('app.svc')::bigint, current_setting('app.s3')::uuid, current_setting('app.yesterday')::date, 57,
        5757575, now() - interval '1 day');
select set_config('app.t_w57', (select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.svc')::bigint and queue_date = current_setting('app.yesterday')::date and ticket_number = 57), true);
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c147', 'reg', $q$select i.ticket_id || '|' || i.ticket_label || '|' || i.status || '|' || i.queue_date || '|' || i.people_ahead
                          from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCQ-C') i$q$)
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
select set_config('app.t_w1', coalesce((select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.svc')::bigint and queue_date = current_setting('app.today')::date and ticket_number = 1), '0'), true);
select set_config('app.l_w1', coalesce((select '#' || ticket_code from public.queue_tickets where ticket_id = current_setting('app.t_w1')::bigint), 'none'), true);
select set_config('app.r147', format('issued [%s], counter_yesterday %s, counter_today %s, s3_waiting_in_TCQ-C %s -> %s',
  current_setting('app.c147'),
  (select c.last_number from public.queue_counters c
    where c.service_id = current_setting('app.svc')::bigint and c.queue_date = current_setting('app.yesterday')::date),
  (select c.last_number from public.queue_counters c
    where c.service_id = current_setting('app.svc')::bigint and c.queue_date = current_setting('app.today')::date),
  (select count(*) from public.queue_tickets where service_id = current_setting('app.svc')::bigint
     and student_id::text = current_setting('app.s3') and status = 'Waiting'),
  case when current_setting('app.c147') = format('%s|%s|Waiting|%s|0', current_setting('app.t_w1'), current_setting('app.l_w1'), current_setting('app.today'))
        and current_setting('app.l_w1') ~ '^#[1-9][0-9]{6}$'
        and (select c.last_number from public.queue_counters c
              where c.service_id = current_setting('app.svc')::bigint and c.queue_date = current_setting('app.yesterday')::date) = 57
        and (select c.last_number from public.queue_counters c
              where c.service_id = current_setting('app.svc')::bigint and c.queue_date = current_setting('app.today')::date) = 1
        and (select count(*) from public.queue_tickets where service_id = current_setting('app.svc')::bigint
               and student_id::text = current_setting('app.s3') and status = 'Waiting') = 2
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 10. TC-148 and TC-149: call next
-- ==========================================
-- Expected TC-148: '<ticket 1 id>|L(1)|<Student 1 id>|<number>|<Last, First>|Window 2|true'
-- (window trimmed, called_at = now()); the row is Serving, handled_by = the Registrar,
-- called_at = now(), finished_at NULL; ticket 2 still Waiting.
-- Expected TC-149: a second call while ticket 1 is served: 'ERR [P0001]: finish first: L(1)'.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c148', 'reg', $q$select c.ticket_id || '|' || c.ticket_label || '|' || c.student_id || '|' || c.student_number || '|' || c.student_name
                                 || '|' || coalesce(c.window_label, 'NULL') || '|' || (c.called_at = now())::text
                          from public.queue_call_next('TCQ-A', '  Window 2  ') c$q$),
    (2, 'c149', 'reg', $q$select c.ticket_label from public.queue_call_next('TCQ-A') c$q$)
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
select set_config('app.r148', format('called [%s], row_ok %s, ticket2 %s -> %s',
  current_setting('app.c148'),
  coalesce((select (t.status = 'Serving' and t.handled_by::text = current_setting('app.reg') and t.called_at = now()
                    and t.finished_at is null and t.window_label = 'Window 2')::text
              from public.queue_tickets t where t.ticket_id = current_setting('app.t_x1')::bigint), 'none'),
  (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x2')::bigint),
  case when current_setting('app.c148') = format('%s|%s|%s|%s|%s|Window 2|true', current_setting('app.t_x1'), current_setting('app.l_x1'),
                                                  current_setting('app.s1'), current_setting('app.s1num'), current_setting('app.s1name'))
        and coalesce((select t.status = 'Serving' and t.handled_by::text = current_setting('app.reg') and t.called_at = now()
                             and t.finished_at is null and t.window_label = 'Window 2'
                        from public.queue_tickets t where t.ticket_id = current_setting('app.t_x1')::bigint), false)
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x2')::bigint) = 'Waiting'
       then 'OK' else 'FAIL' end), true);
select set_config('app.r149', format('second call [%s], ticket2 %s, serving %s -> %s',
  current_setting('app.c149'),
  (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x2')::bigint),
  (select count(*) from public.queue_tickets t where t.service_id = current_setting('app.sva')::bigint and t.status = 'Serving'),
  case when current_setting('app.c149') = 'ERR [P0001]: finish first: ' || current_setting('app.l_x1')
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x2')::bigint) = 'Waiting'
        and (select count(*) from public.queue_tickets t where t.service_id = current_setting('app.sva')::bigint and t.status = 'Serving') = 1
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 11. TC-150 and TC-151: finish, call again, empty queue
-- ==========================================
-- Expected TC-150: finish ticket 1 Done 'done'; call next 'L(2)|<Student 2 id>|NULL';
-- finish ticket 2 No-show 'done'; times and handler set by the database.
-- Expected TC-151: call next on TCQ-A: '0' rows; Student 1's status on TCQ-A:
-- 'true|true|L(1)|Done|NULL|L(2)|0|0|NULL' (format: is_open|has_ticket|label|status|ahead|
-- now_serving|waiting|avg|window); call next on TCQ-C (window 'Desk 1') takes today's L(W1),
-- never yesterday's ticket 57.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c150_done',   'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_x1')::bigint, 'Done')$q$),
    (2, 'c150_next',   'reg', $q$select c.ticket_label || '|' || c.student_id || '|' || coalesce(c.window_label, 'NULL')
                                 from public.queue_call_next('TCQ-A') c$q$),
    (3, 'c150_noshow', 'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_x2')::bigint, 'No-show')$q$),
    (4, 'c151_empty',  'reg', $q$select count(*)::text from public.queue_call_next('TCQ-A') c$q$),
    (5, 'c151_status', 's1',  $q$select s.is_open::text || '|' || s.has_ticket::text || '|' || coalesce(s.ticket_label, 'NULL') || '|'
                                 || coalesce(s.ticket_status, 'NULL') || '|' || coalesce(s.people_ahead::text, 'NULL') || '|'
                                 || coalesce(s.now_serving, 'NULL') || '|' || coalesce(s.waiting_total::text, 'NULL') || '|'
                                 || coalesce(s.avg_service_seconds::text, 'NULL') || '|' || coalesce(s.window_label, 'NULL')
                                 from public.queue_my_status('TCQ-A') s$q$),
    (6, 'c151_w',      'reg', $q$select c.ticket_label from public.queue_call_next('TCQ-C', 'Desk 1') c$q$)
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
select set_config('app.r150', format('finish_done [%s], next [%s], finish_noshow [%s], t1_ok %s, t2_ok %s -> %s',
  current_setting('app.c150_done'), current_setting('app.c150_next'), current_setting('app.c150_noshow'),
  coalesce((select (t.status = 'Done' and t.finished_at = now() and t.called_at = now()
                    and t.handled_by::text = current_setting('app.reg') and t.window_label = 'Window 2')::text
              from public.queue_tickets t where t.ticket_id = current_setting('app.t_x1')::bigint), 'none'),
  coalesce((select (t.status = 'No-show' and t.finished_at = now() and t.called_at = now()
                    and t.handled_by::text = current_setting('app.reg') and t.window_label is null)::text
              from public.queue_tickets t where t.ticket_id = current_setting('app.t_x2')::bigint), 'none'),
  case when current_setting('app.c150_done') = 'done'
        and current_setting('app.c150_next') = current_setting('app.l_x2') || '|' || current_setting('app.s2') || '|NULL'
        and current_setting('app.c150_noshow') = 'done'
        and coalesce((select t.status = 'Done' and t.finished_at = now() and t.called_at = now()
                             and t.handled_by::text = current_setting('app.reg') and t.window_label = 'Window 2'
                        from public.queue_tickets t where t.ticket_id = current_setting('app.t_x1')::bigint), false)
        and coalesce((select t.status = 'No-show' and t.finished_at = now() and t.called_at = now()
                             and t.handled_by::text = current_setting('app.reg') and t.window_label is null
                        from public.queue_tickets t where t.ticket_id = current_setting('app.t_x2')::bigint), false)
       then 'OK' else 'FAIL' end), true);
select set_config('app.r151', format('empty_call_rows [%s], s1_status [%s], tcq_c_call [%s], w57 %s -> %s',
  current_setting('app.c151_empty'), current_setting('app.c151_status'), current_setting('app.c151_w'),
  (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_w57')::bigint),
  case when current_setting('app.c151_empty') = '0'
        and current_setting('app.c151_status') = format('true|true|%s|Done|NULL|%s|0|0|NULL', current_setting('app.l_x1'), current_setting('app.l_x2'))
        and current_setting('app.c151_w') = current_setting('app.l_w1')
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_w57')::bigint) = 'Waiting'
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_w1')::bigint) = 'Serving'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 12. TC-152: finish from a wrong state, bad input, wrong role
-- ==========================================
-- Expected: Done again, No-show -> Done, a Waiting ticket, an unknown id: 'ERR [P0001]: bad
-- ticket change: ...'; outcome 'Cancelled', NULL, 'done': 'ERR [22023]: invalid ticket
-- request: ...'; a Student: 'ERR [42501]: not allowed: ...'. Nothing changes.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c152_done_again', 'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_x1')::bigint, 'Done')$q$),
    (2, 'c152_noshow',     'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_x2')::bigint, 'Done')$q$),
    (3, 'c152_waiting',    'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_w57')::bigint, 'Done')$q$),
    (4, 'c152_unknown',    'reg', $q$select 'done'::text from public.queue_finish(-1, 'Done')$q$),
    (5, 'c152_cancelled',  'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_w1')::bigint, 'Cancelled')$q$),
    (6, 'c152_null',       'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_w1')::bigint, null)$q$),
    (7, 'c152_lower',      'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_w1')::bigint, 'done')$q$),
    (8, 'c152_student',    's1',  $q$select 'done'::text from public.queue_finish(current_setting('app.t_w1')::bigint, 'Done')$q$)
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
select set_config('app.r152', format('done_again [%s], noshow_to_done [%s], waiting [%s], unknown [%s], cancelled [%s], null [%s], lower_case [%s], student [%s] -> %s',
  current_setting('app.c152_done_again'), current_setting('app.c152_noshow'), current_setting('app.c152_waiting'),
  current_setting('app.c152_unknown'), current_setting('app.c152_cancelled'), current_setting('app.c152_null'),
  current_setting('app.c152_lower'), current_setting('app.c152_student'),
  case when current_setting('app.c152_done_again') like 'ERR [P0001]: bad ticket change:%'
        and current_setting('app.c152_noshow') like 'ERR [P0001]: bad ticket change:%'
        and current_setting('app.c152_waiting') like 'ERR [P0001]: bad ticket change:%'
        and current_setting('app.c152_unknown') like 'ERR [P0001]: bad ticket change:%'
        and current_setting('app.c152_cancelled') like 'ERR [22023]: invalid ticket request:%'
        and current_setting('app.c152_null') like 'ERR [22023]: invalid ticket request:%'
        and current_setting('app.c152_lower') like 'ERR [22023]: invalid ticket request:%'
        and current_setting('app.c152_student') like 'ERR [42501]: not allowed:%'
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x1')::bigint) = 'Done'
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x2')::bigint) = 'No-show'
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_w57')::bigint) = 'Waiting'
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_w1')::bigint) = 'Serving'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 13. TC-153: direct UPDATE as the owner (no JWT): the trigger rules apply to every role
-- ==========================================
-- Setup: Student 2 gets a Waiting ticket 58 (code 5858585) of yesterday in TCQ-C.
-- Expected: cases 1 to 13 'ERR [P0001]: bad ticket change: ...' (Done -> Waiting,
-- No-show -> Done, window of a final row, Waiting -> Done, Serving -> Waiting,
-- Serving -> Cancelled, student / service / date / number / code / created_at, handled_by
-- while Waiting); cases 14 to 16 'rows 1' (Waiting -> Serving, Serving -> No-show,
-- Waiting -> Cancelled) with called_at / finished_at = now() although the statement sent
-- 2000 / 2001 dates; window trimmed to 'Desk 9'; ticket 57 keeps code 5757575.
insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, created_at)
values (current_setting('app.svc')::bigint, current_setting('app.s2')::uuid, current_setting('app.yesterday')::date, 58,
        5858585, now() - interval '1 day');
select set_config('app.t_w58', (select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.svc')::bigint and queue_date = current_setting('app.yesterday')::date and ticket_number = 58), true);
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1,  'c153_done_back',   $q$update public.queue_tickets set status = 'Waiting' where ticket_id = current_setting('app.t_x1')::bigint$q$),
    (2,  'c153_noshow_done', $q$update public.queue_tickets set status = 'Done' where ticket_id = current_setting('app.t_x2')::bigint$q$),
    (3,  'c153_final_win',   $q$update public.queue_tickets set window_label = 'Window 9' where ticket_id = current_setting('app.t_x1')::bigint$q$),
    (4,  'c153_skip',        $q$update public.queue_tickets set status = 'Done' where ticket_id = current_setting('app.t_w57')::bigint$q$),
    (5,  'c153_back',        $q$update public.queue_tickets set status = 'Waiting' where ticket_id = current_setting('app.t_w1')::bigint$q$),
    (6,  'c153_srv_cancel',  $q$update public.queue_tickets set status = 'Cancelled' where ticket_id = current_setting('app.t_w1')::bigint$q$),
    (7,  'c153_student',     $q$update public.queue_tickets set student_id = current_setting('app.s1')::uuid where ticket_id = current_setting('app.t_w57')::bigint$q$),
    (8,  'c153_service',     $q$update public.queue_tickets set service_id = current_setting('app.sva')::bigint where ticket_id = current_setting('app.t_w57')::bigint$q$),
    (9,  'c153_date',        $q$update public.queue_tickets set queue_date = current_setting('app.today')::date where ticket_id = current_setting('app.t_w57')::bigint$q$),
    (10, 'c153_number',      $q$update public.queue_tickets set ticket_number = 99 where ticket_id = current_setting('app.t_w57')::bigint$q$),
    (11, 'c153_code',        $q$update public.queue_tickets set ticket_code = 1234567 where ticket_id = current_setting('app.t_w57')::bigint$q$),
    (12, 'c153_created',     $q$update public.queue_tickets set created_at = now() where ticket_id = current_setting('app.t_w57')::bigint$q$),
    (13, 'c153_handler',     $q$update public.queue_tickets set handled_by = current_setting('app.reg')::uuid where ticket_id = current_setting('app.t_w57')::bigint$q$),
    (14, 'c153_call',        $q$update public.queue_tickets set status = 'Serving', handled_by = current_setting('app.reg')::uuid,
                                  window_label = ' Desk 9 ', called_at = '2000-01-01 00:00:00+00'
                                where ticket_id = current_setting('app.t_w57')::bigint$q$),
    (15, 'c153_finish',      $q$update public.queue_tickets set status = 'No-show', called_at = '2001-01-01 00:00:00+00',
                                  finished_at = '2000-01-01 00:00:00+00'
                                where ticket_id = current_setting('app.t_w57')::bigint$q$),
    (16, 'c153_cancel',      $q$update public.queue_tickets set status = 'Cancelled', finished_at = '2000-01-01 00:00:00+00'
                                where ticket_id = current_setting('app.t_w58')::bigint$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      get diagnostics n = row_count;
      perform set_config('app.' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.t153_blocked', (select count(*)::text from (values
    ('c153_done_back'), ('c153_noshow_done'), ('c153_final_win'), ('c153_skip'), ('c153_back'), ('c153_srv_cancel'),
    ('c153_student'), ('c153_service'), ('c153_date'), ('c153_number'), ('c153_code'), ('c153_created'), ('c153_handler')) as v(l)
  where current_setting('app.' || v.l) like 'ERR [P0001]: bad ticket change:%'), true);
select set_config('app.t153_unexpected', coalesce((select string_agg(v.l || ' [' || current_setting('app.' || v.l) || ']', ', ') from (values
    ('c153_done_back'), ('c153_noshow_done'), ('c153_final_win'), ('c153_skip'), ('c153_back'), ('c153_srv_cancel'),
    ('c153_student'), ('c153_service'), ('c153_date'), ('c153_number'), ('c153_code'), ('c153_created'), ('c153_handler')) as v(l)
  where current_setting('app.' || v.l) not like 'ERR [P0001]: bad ticket change:%'), ''), true);
select set_config('app.r153', format('blocked %s/13 [%s], call [%s], finish [%s], cancel [%s], w57_ok %s, w58_ok %s, t1_unchanged %s -> %s',
  current_setting('app.t153_blocked'), current_setting('app.t153_unexpected'),
  current_setting('app.c153_call'), current_setting('app.c153_finish'), current_setting('app.c153_cancel'),
  coalesce((select (t.status = 'No-show' and t.called_at = now() and t.finished_at = now()
                    and t.handled_by::text = current_setting('app.reg') and t.window_label = 'Desk 9'
                    and t.student_id::text = current_setting('app.s3') and t.ticket_number = 57 and t.ticket_code = 5757575)::text
              from public.queue_tickets t where t.ticket_id = current_setting('app.t_w57')::bigint), 'none'),
  coalesce((select (t.status = 'Cancelled' and t.finished_at = now() and t.called_at is null and t.handled_by is null)::text
              from public.queue_tickets t where t.ticket_id = current_setting('app.t_w58')::bigint), 'none'),
  coalesce((select (t.status = 'Done' and t.window_label = 'Window 2')::text
              from public.queue_tickets t where t.ticket_id = current_setting('app.t_x1')::bigint), 'none'),
  case when current_setting('app.t153_blocked') = '13'
        and current_setting('app.c153_call') = 'rows 1' and current_setting('app.c153_finish') = 'rows 1'
        and current_setting('app.c153_cancel') = 'rows 1'
        and coalesce((select t.status = 'No-show' and t.called_at = now() and t.finished_at = now()
                             and t.handled_by::text = current_setting('app.reg') and t.window_label = 'Desk 9'
                             and t.student_id::text = current_setting('app.s3') and t.ticket_number = 57 and t.ticket_code = 5757575
                        from public.queue_tickets t where t.ticket_id = current_setting('app.t_w57')::bigint), false)
        and coalesce((select t.status = 'Cancelled' and t.finished_at = now() and t.called_at is null and t.handled_by is null
                        from public.queue_tickets t where t.ticket_id = current_setting('app.t_w58')::bigint), false)
        and coalesce((select t.status = 'Done' and t.window_label = 'Window 2'
                        from public.queue_tickets t where t.ticket_id = current_setting('app.t_x1')::bigint), false)
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 14. TC-154: no direct writes through the API (Student and Registrar)
-- ==========================================
-- Expected: all 18 statements (9 each for Student 1 and the Registrar) fail with
-- 'permission denied'; the tables are unchanged.
select set_config('app.t154_before', (select (select count(*) from public.queue_tickets) || '/' || (select count(*) from public.queue_services)
                                             || '/' || (select count(*) from public.queue_counters)), true);
set local role authenticated;
do $$
declare
  r     record;
  v_ok  integer := 0;
  v_bad text := '';
begin
  for r in select w.who, s.ord, s.stmt
           from (values ('s1'), ('reg')) as w(who)
           cross join (values
             (1, $q$insert into public.queue_tickets (service_id, student_id, ticket_number, ticket_code)
                   values (current_setting('app.sva')::bigint, current_setting('app.s1')::uuid, 999, 2222222)$q$),
             (2, $q$update public.queue_tickets set status = 'Cancelled' where ticket_id = current_setting('app.t_w1')::bigint$q$),
             (3, $q$delete from public.queue_tickets where ticket_id = current_setting('app.t_x2')::bigint$q$),
             (4, $q$insert into public.queue_services (service_code, service_name, ticket_prefix) values ('TCQ-Z', 'z', 'Z')$q$),
             (5, $q$update public.queue_services set is_open = false where service_id = current_setting('app.sva')::bigint$q$),
             (6, $q$delete from public.queue_services where service_id = current_setting('app.svb')::bigint$q$),
             (7, $q$insert into public.queue_counters (service_id, queue_date, last_number)
                   values (current_setting('app.svb')::bigint, current_setting('app.today')::date, 5)$q$),
             (8, $q$update public.queue_counters set last_number = 0$q$),
             (9, $q$delete from public.queue_counters$q$)
           ) as s(ord, stmt)
           order by w.who, s.ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt;
      v_bad := v_bad || r.who || ' #' || r.ord || ' ALLOWED; ';
    exception when others then
      if sqlstate = '42501' and sqlerrm like 'permission denied%' then
        v_ok := v_ok + 1;
      else
        v_bad := v_bad || r.who || ' #' || r.ord || ' ' || sqlstate || ' ' || sqlerrm || '; ';
      end if;
    end;
  end loop;
  perform set_config('app.t154_ok', v_ok::text, true);
  perform set_config('app.t154_bad', v_bad, true);
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r154', format('denied %s/18, other [%s], unchanged %s -> %s',
  current_setting('app.t154_ok'), current_setting('app.t154_bad'),
  (select (select count(*) from public.queue_tickets) || '/' || (select count(*) from public.queue_services)
          || '/' || (select count(*) from public.queue_counters)) = current_setting('app.t154_before'),
  case when current_setting('app.t154_ok') = '18' and current_setting('app.t154_bad') = ''
        and (select (select count(*) from public.queue_tickets) || '/' || (select count(*) from public.queue_services)
                    || '/' || (select count(*) from public.queue_counters)) = current_setting('app.t154_before')
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 15. TC-155: who sees which tickets (SELECT through RLS)
-- ==========================================
-- Each cell: tickets in the 3 test services / visible tickets of OTHER students (whole
-- table) / visible queue_counters rows / visible services among the 5 known codes.
-- Expected: Student 1 '1/0/0/5', Student 2 '2/0/0/5' (ticket 2, yesterday's 58), Student 3
-- '2/0/0/5' (yesterday's 57, today's W1), Registrar '5/<any>/0/5', Cashier, Department,
-- Admin '0/0/0/5'.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c155_s1', 's1'), (2, 'c155_s2', 's2'), (3, 'c155_s3', 's3'), (4, 'c155_reg', 'reg'),
    (5, 'c155_cash', 'cash'), (6, 'c155_dept', 'dept'), (7, 'c155_adm', 'adm')
  ) as t(ord, label, who) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    perform set_config('app.cur', current_setting('app.' || r.who), true);
    begin
      execute $q$select (select count(*) from public.queue_tickets t
                          where t.service_id in (current_setting('app.sva')::bigint, current_setting('app.svb')::bigint,
                                                 current_setting('app.svc')::bigint))
                        || '/' || (select count(*) from public.queue_tickets t where t.student_id::text <> current_setting('app.cur'))
                        || '/' || (select count(*) from public.queue_counters)
                        || '/' || (select count(*) from public.queue_services s
                                    where s.service_code in ('Enrollment', 'Documents', 'TCQ-A', 'TCQ-B', 'TCQ-C'))$q$ into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r155', format('student1 [%s], student2 [%s], student3 [%s], registrar [%s], cashier [%s], department [%s], admin [%s] -> %s',
  current_setting('app.c155_s1'), current_setting('app.c155_s2'), current_setting('app.c155_s3'), current_setting('app.c155_reg'),
  current_setting('app.c155_cash'), current_setting('app.c155_dept'), current_setting('app.c155_adm'),
  case when current_setting('app.c155_s1') = '1/0/0/5' and current_setting('app.c155_s2') = '2/0/0/5'
        and current_setting('app.c155_s3') = '2/0/0/5' and current_setting('app.c155_reg') like '5/%/0/5'
        and current_setting('app.c155_cash') = '0/0/0/5' and current_setting('app.c155_dept') = '0/0/0/5'
        and current_setting('app.c155_adm') = '0/0/0/5'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 16. TC-156: queue_my_status (numbers, labels, window, privacy)
-- ==========================================
-- Setup: a Done ticket 900 of Student 3 served in 240 s (called now() - 300 s, finished
-- now() - 60 s; as postgres, with a free code), then the Registrar issues ticket 3 (Student
-- 1) and ticket 4 (Student 2) and calls ticket 3 at 'Window 5'. Format: is_open|has_ticket|
-- label|status|people_ahead|now_serving|waiting_total|avg_service_seconds|window_label.
-- Expected:
--   Student 2 TCQ-A 'true|true|L(4)|Waiting|0|L(3)|1|120|NULL' (average of 0 s and 240 s)
--   Student 1 TCQ-A 'true|true|L(3)|Serving|0|L(3)|1|120|Window 5' (own Serving window)
--   Student 3 TCQ-A 'true|true|L(900)|Done|NULL|L(3)|1|120|NULL' (no active: the latest)
--   Student 1 TCQ-B 'false|false|NULL|NULL|NULL|NULL|0|NULL|NULL'
--   Student 3 TCQ-C 'true|true|L(W1)|Serving|0|L(W1)|0|NULL|Desk 1'
--   after ticket 5 is issued to Student 3: 'true|true|L(5)|Waiting|1|L(3)|2|120|NULL'
--   Registrar: 'ERR [42501]: not allowed: ...'; unknown service: 'ERR [22023]: ...'
--   the result type is exactly the 9 documented columns; Student 2's raw row contains no id,
--   student number or last name of Student 1 or 3, and not Student 1's window 'Window 5'.
insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, status, window_label,
                                  handled_by, created_at, called_at, finished_at)
values (current_setting('app.sva')::bigint, current_setting('app.s3')::uuid, current_setting('app.today')::date, 900,
        (select min(g)::integer from generate_series(1000000, 1001000) g
          where not exists (select 1 from public.queue_tickets q
                             where q.service_id = current_setting('app.sva')::bigint
                               and q.queue_date = current_setting('app.today')::date and q.ticket_code = g)),
        'Done', 'Window 1', current_setting('app.reg')::uuid, now() - interval '400 seconds', now() - interval '300 seconds',
        now() - interval '60 seconds');
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1,  'c156_i1',      'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCQ-A') i$q$),
    (2,  'c156_i2',      'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCQ-A') i$q$),
    (3,  'c156_call',    'reg', $q$select c.ticket_label from public.queue_call_next('TCQ-A', 'Window 5') c$q$),
    (4,  'c156_s2',      's2',  $q$select s.is_open::text || '|' || s.has_ticket::text || '|' || coalesce(s.ticket_label, 'NULL') || '|'
                                   || coalesce(s.ticket_status, 'NULL') || '|' || coalesce(s.people_ahead::text, 'NULL') || '|'
                                   || coalesce(s.now_serving, 'NULL') || '|' || coalesce(s.waiting_total::text, 'NULL') || '|'
                                   || coalesce(s.avg_service_seconds::text, 'NULL') || '|' || coalesce(s.window_label, 'NULL')
                                   from public.queue_my_status('TCQ-A') s$q$),
    (5,  'c156_s1',      's1',  $q$select s.is_open::text || '|' || s.has_ticket::text || '|' || coalesce(s.ticket_label, 'NULL') || '|'
                                   || coalesce(s.ticket_status, 'NULL') || '|' || coalesce(s.people_ahead::text, 'NULL') || '|'
                                   || coalesce(s.now_serving, 'NULL') || '|' || coalesce(s.waiting_total::text, 'NULL') || '|'
                                   || coalesce(s.avg_service_seconds::text, 'NULL') || '|' || coalesce(s.window_label, 'NULL')
                                   from public.queue_my_status('TCQ-A') s$q$),
    (6,  'c156_s3a',     's3',  $q$select s.is_open::text || '|' || s.has_ticket::text || '|' || coalesce(s.ticket_label, 'NULL') || '|'
                                   || coalesce(s.ticket_status, 'NULL') || '|' || coalesce(s.people_ahead::text, 'NULL') || '|'
                                   || coalesce(s.now_serving, 'NULL') || '|' || coalesce(s.waiting_total::text, 'NULL') || '|'
                                   || coalesce(s.avg_service_seconds::text, 'NULL') || '|' || coalesce(s.window_label, 'NULL')
                                   from public.queue_my_status('TCQ-A') s$q$),
    (7,  'c156_closed',  's1',  $q$select s.is_open::text || '|' || s.has_ticket::text || '|' || coalesce(s.ticket_label, 'NULL') || '|'
                                   || coalesce(s.ticket_status, 'NULL') || '|' || coalesce(s.people_ahead::text, 'NULL') || '|'
                                   || coalesce(s.now_serving, 'NULL') || '|' || coalesce(s.waiting_total::text, 'NULL') || '|'
                                   || coalesce(s.avg_service_seconds::text, 'NULL') || '|' || coalesce(s.window_label, 'NULL')
                                   from public.queue_my_status('TCQ-B') s$q$),
    (8,  'c156_w',       's3',  $q$select s.is_open::text || '|' || s.has_ticket::text || '|' || coalesce(s.ticket_label, 'NULL') || '|'
                                   || coalesce(s.ticket_status, 'NULL') || '|' || coalesce(s.people_ahead::text, 'NULL') || '|'
                                   || coalesce(s.now_serving, 'NULL') || '|' || coalesce(s.waiting_total::text, 'NULL') || '|'
                                   || coalesce(s.avg_service_seconds::text, 'NULL') || '|' || coalesce(s.window_label, 'NULL')
                                   from public.queue_my_status('TCQ-C') s$q$),
    (9,  'c156_raw_s2',  's2',  $q$select row_to_json(s)::text from public.queue_my_status('TCQ-A') s$q$),
    (10, 'c156_reg',     'reg', $q$select s.ticket_label from public.queue_my_status('TCQ-A') s$q$),
    (11, 'c156_unknown', 's1',  $q$select s.ticket_label from public.queue_my_status('NoSuchService') s$q$),
    (12, 'c156_i3',      'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCQ-A') i$q$),
    (13, 'c156_s3b',     's3',  $q$select s.is_open::text || '|' || s.has_ticket::text || '|' || coalesce(s.ticket_label, 'NULL') || '|'
                                   || coalesce(s.ticket_status, 'NULL') || '|' || coalesce(s.people_ahead::text, 'NULL') || '|'
                                   || coalesce(s.now_serving, 'NULL') || '|' || coalesce(s.waiting_total::text, 'NULL') || '|'
                                   || coalesce(s.avg_service_seconds::text, 'NULL') || '|' || coalesce(s.window_label, 'NULL')
                                   from public.queue_my_status('TCQ-A') s$q$)
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
select set_config('app.t_x3', coalesce((select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.sva')::bigint and queue_date = current_setting('app.today')::date and ticket_number = 3), '0'), true);
select set_config('app.t_x4', coalesce((select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.sva')::bigint and queue_date = current_setting('app.today')::date and ticket_number = 4), '0'), true);
select set_config('app.t_x5', coalesce((select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.sva')::bigint and queue_date = current_setting('app.today')::date and ticket_number = 5), '0'), true);
select set_config('app.l_x3', coalesce((select '#' || ticket_code from public.queue_tickets where ticket_id = current_setting('app.t_x3')::bigint), 'none'), true);
select set_config('app.l_x4', coalesce((select '#' || ticket_code from public.queue_tickets where ticket_id = current_setting('app.t_x4')::bigint), 'none'), true);
select set_config('app.l_x5', coalesce((select '#' || ticket_code from public.queue_tickets where ticket_id = current_setting('app.t_x5')::bigint), 'none'), true);
select set_config('app.l_x900', coalesce((select '#' || ticket_code from public.queue_tickets
  where service_id = current_setting('app.sva')::bigint and queue_date = current_setting('app.today')::date and ticket_number = 900), 'none'), true);
select set_config('app.t156_sig', coalesce(pg_get_function_result(to_regprocedure('public.queue_my_status(text)')), 'none'), true);
select set_config('app.t156_leak', (select coalesce(string_agg(v.n, ', '), '') from (values
    ('s1 id', current_setting('app.s1')), ('s3 id', current_setting('app.s3')),
    ('s1 number', current_setting('app.s1num')), ('s3 number', current_setting('app.s3num')),
    ('s1 last name', current_setting('app.s1last')), ('s3 last name', current_setting('app.s3last')),
    ('s1 window', 'Window 5')) as v(n, val)
  where position(v.val in current_setting('app.c156_raw_s2')) > 0), true);
select set_config('app.r156', format('issued [%s, %s], called [%s], s2 [%s], s1 [%s], s3 [%s], closed [%s], tcq_c [%s], s3_after_ticket5 [%s] (issued %s), registrar [%s], unknown [%s], signature [%s], leaks [%s] -> %s',
  current_setting('app.c156_i1'), current_setting('app.c156_i2'), current_setting('app.c156_call'),
  current_setting('app.c156_s2'), current_setting('app.c156_s1'), current_setting('app.c156_s3a'),
  current_setting('app.c156_closed'), current_setting('app.c156_w'), current_setting('app.c156_s3b'),
  current_setting('app.c156_i3'), current_setting('app.c156_reg'), current_setting('app.c156_unknown'),
  current_setting('app.t156_sig'), current_setting('app.t156_leak'),
  case when current_setting('app.c156_i1') = current_setting('app.l_x3') and current_setting('app.c156_i2') = current_setting('app.l_x4')
        and current_setting('app.c156_call') = current_setting('app.l_x3')
        and current_setting('app.c156_s2') = format('true|true|%s|Waiting|0|%s|1|120|NULL', current_setting('app.l_x4'), current_setting('app.l_x3'))
        and current_setting('app.c156_s1') = format('true|true|%s|Serving|0|%s|1|120|Window 5', current_setting('app.l_x3'), current_setting('app.l_x3'))
        and current_setting('app.c156_s3a') = format('true|true|%s|Done|NULL|%s|1|120|NULL', current_setting('app.l_x900'), current_setting('app.l_x3'))
        and current_setting('app.c156_closed') = 'false|false|NULL|NULL|NULL|NULL|0|NULL|NULL'
        and current_setting('app.c156_w') = format('true|true|%s|Serving|0|%s|0|NULL|Desk 1', current_setting('app.l_w1'), current_setting('app.l_w1'))
        and current_setting('app.c156_i3') = current_setting('app.l_x5')
        and current_setting('app.c156_s3b') = format('true|true|%s|Waiting|1|%s|2|120|NULL', current_setting('app.l_x5'), current_setting('app.l_x3'))
        and current_setting('app.c156_reg') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c156_unknown') like 'ERR [22023]: invalid ticket request: unknown service%'
        and current_setting('app.t156_sig') = 'TABLE(is_open boolean, has_ticket boolean, ticket_label text, ticket_status text, people_ahead integer, now_serving text, waiting_total integer, avg_service_seconds integer, window_label text)'
        and current_setting('app.c156_raw_s2') like '{%'
        and current_setting('app.t156_leak') = ''
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 17. TC-157: a student cancels
-- ==========================================
-- State: ticket 3 Student 1 Serving, ticket 4 Student 2 Waiting, ticket 5 Student 3 Waiting.
-- Expected: Student 2 cancels 'done'; again 'ERR [P0001]: bad ticket change: no waiting
-- ticket'; Student 1 (Serving) 'ERR [P0001]: bad ticket change: ...'; the Registrar
-- 'ERR [42501]: not allowed: ...'; Student 1 on TCQ-B 'ERR [P0001]: bad ticket change: no
-- waiting ticket'; Student 2 can then be issued ticket 6 (its label is returned). Ticket 4
-- Cancelled with finished_at = now(), no call, no handler; ticket 3 Serving; ticket 5 Waiting.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c157_cancel',  's2',  $q$select 'done'::text from public.queue_cancel_my_ticket('TCQ-A')$q$),
    (2, 'c157_again',   's2',  $q$select 'done'::text from public.queue_cancel_my_ticket('TCQ-A')$q$),
    (3, 'c157_serving', 's1',  $q$select 'done'::text from public.queue_cancel_my_ticket('TCQ-A')$q$),
    (4, 'c157_reg',     'reg', $q$select 'done'::text from public.queue_cancel_my_ticket('TCQ-A')$q$),
    (5, 'c157_none',    's1',  $q$select 'done'::text from public.queue_cancel_my_ticket('TCQ-B')$q$),
    (6, 'c157_reissue', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCQ-A') i$q$)
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
select set_config('app.l_x6', coalesce((select '#' || ticket_code from public.queue_tickets
  where service_id = current_setting('app.sva')::bigint and queue_date = current_setting('app.today')::date and ticket_number = 6), 'none'), true);
select set_config('app.r157', format('cancel [%s], again [%s], serving [%s], registrar [%s], none [%s], reissue [%s], t4_ok %s, t3 %s, t5 %s -> %s',
  current_setting('app.c157_cancel'), current_setting('app.c157_again'), current_setting('app.c157_serving'),
  current_setting('app.c157_reg'), current_setting('app.c157_none'), current_setting('app.c157_reissue'),
  coalesce((select (t.status = 'Cancelled' and t.finished_at = now() and t.called_at is null and t.handled_by is null)::text
              from public.queue_tickets t where t.ticket_id = current_setting('app.t_x4')::bigint), 'none'),
  (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x3')::bigint),
  (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x5')::bigint),
  case when current_setting('app.c157_cancel') = 'done'
        and current_setting('app.c157_again') = 'ERR [P0001]: bad ticket change: no waiting ticket'
        and current_setting('app.c157_serving') like 'ERR [P0001]: bad ticket change:%'
        and current_setting('app.c157_serving') <> 'ERR [P0001]: bad ticket change: no waiting ticket'
        and current_setting('app.c157_reg') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c157_none') = 'ERR [P0001]: bad ticket change: no waiting ticket'
        and current_setting('app.c157_reissue') = current_setting('app.l_x6')
        and current_setting('app.l_x6') ~ '^#[1-9][0-9]{6}$'
        and coalesce((select t.status = 'Cancelled' and t.finished_at = now() and t.called_at is null and t.handled_by is null
                        from public.queue_tickets t where t.ticket_id = current_setting('app.t_x4')::bigint), false)
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x3')::bigint) = 'Serving'
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x5')::bigint) = 'Waiting'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 18. TC-158: queue_staff_list
-- ==========================================
-- Expected: the Registrar gets TCQ-A in internal order: ticket_number:status
-- '1:Done,2:No-show,3:Serving,4:Cancelled,5:Waiting,6:Waiting,900:Done', and labels equal
-- to '#' || ticket_code of the stored rows in the same order; ticket 1's row
-- '<Student 1 id>|<number>|<Last, First>|Window 2|true|true|true'; TCQ-C lists only today's
-- L(W1); Student, Cashier, Department, Admin 'ERR [42501]: not allowed: ...'; anon
-- 'ERR [42501]: permission denied for function queue_staff_list'; result type as published.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c158_n',    'reg',  $q$select string_agg(l.ticket_number || ':' || l.status, ',' order by l.ord)
                                from public.queue_staff_list('TCQ-A') with ordinality as l(ticket_id, ticket_label, ticket_number, status,
                                     student_id, student_number, student_name, window_label, created_at, called_at, finished_at, ord)$q$),
    (2, 'c158_a',    'reg',  $q$select string_agg(l.ticket_label || ':' || l.status, ',' order by l.ord)
                                from public.queue_staff_list('TCQ-A') with ordinality as l(ticket_id, ticket_label, ticket_number, status,
                                     student_id, student_number, student_name, window_label, created_at, called_at, finished_at, ord)$q$),
    (3, 'c158_x1',   'reg',  $q$select l.student_id || '|' || l.student_number || '|' || l.student_name || '|' || coalesce(l.window_label, 'NULL')
                                       || '|' || (l.called_at = now())::text || '|' || (l.finished_at = now())::text || '|' || (l.created_at = now())::text
                                from public.queue_staff_list('TCQ-A') l where l.ticket_number = 1$q$),
    (4, 'c158_w',    'reg',  $q$select string_agg(l.ticket_label, ',') from public.queue_staff_list('TCQ-C') l$q$),
    (5, 'c158_s1',   's1',   $q$select count(*)::text from public.queue_staff_list('TCQ-A') l$q$),
    (6, 'c158_cash', 'cash', $q$select count(*)::text from public.queue_staff_list('TCQ-A') l$q$),
    (7, 'c158_dept', 'dept', $q$select count(*)::text from public.queue_staff_list('TCQ-A') l$q$),
    (8, 'c158_adm',  'adm',  $q$select count(*)::text from public.queue_staff_list('TCQ-A') l$q$)
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
declare v text;
begin
  select count(*)::text into v from public.queue_staff_list('TCQ-A') l;
  perform set_config('app.c158_anon', coalesce(v, 'NULL'), true);
exception when others then
  perform set_config('app.c158_anon', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
reset role;
select set_config('app.t158_expected', coalesce((select string_agg('#' || t.ticket_code || ':' || t.status, ',' order by t.ticket_number)
  from public.queue_tickets t
  where t.service_id = current_setting('app.sva')::bigint and t.queue_date = current_setting('app.today')::date), ''), true);
select set_config('app.r158', format('numbers [%s], labels_as_stored %s, x1 [%s], tcq_c [%s], student [%s], cashier [%s], department [%s], admin [%s], anon [%s], signature_ok %s -> %s',
  current_setting('app.c158_n'), current_setting('app.c158_a') = current_setting('app.t158_expected'),
  current_setting('app.c158_x1'), current_setting('app.c158_w'),
  current_setting('app.c158_s1'), current_setting('app.c158_cash'), current_setting('app.c158_dept'),
  current_setting('app.c158_adm'), current_setting('app.c158_anon'),
  pg_get_function_result(to_regprocedure('public.queue_staff_list(text)')) = 'TABLE(ticket_id bigint, ticket_label text, ticket_number integer, status text, student_id uuid, student_number text, student_name text, window_label text, created_at timestamp with time zone, called_at timestamp with time zone, finished_at timestamp with time zone)',
  case when current_setting('app.c158_n') = '1:Done,2:No-show,3:Serving,4:Cancelled,5:Waiting,6:Waiting,900:Done'
        and current_setting('app.c158_a') = current_setting('app.t158_expected')
        and current_setting('app.c158_x1') = format('%s|%s|%s|Window 2|true|true|true', current_setting('app.s1'),
                                                    current_setting('app.s1num'), current_setting('app.s1name'))
        and current_setting('app.c158_w') = current_setting('app.l_w1')
        and current_setting('app.c158_s1') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c158_cash') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c158_dept') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c158_adm') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c158_anon') like 'ERR [42501]: permission denied for function queue_staff_list%'
        and pg_get_function_result(to_regprocedure('public.queue_staff_list(text)')) = 'TABLE(ticket_id bigint, ticket_label text, ticket_number integer, status text, student_id uuid, student_number text, student_name text, window_label text, created_at timestamp with time zone, called_at timestamp with time zone, finished_at timestamp with time zone)'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 19. TC-159: audit rows
-- ==========================================
-- Expected (audit rows after the start of this script): ticket 1 INSERT 1 (actor
-- Registrar); ticket 1 UPDATE statuses 'Serving,Done', all by the Registrar (refused changes
-- of TC-152 and TC-153 wrote none); ticket 4 cancel by Student 2: 1; ticket 57 owner changes
-- with actor NULL: 2; rows for queue_counters / queue_services: 0.
select set_config('app.r159', (select format('t1_insert_by_registrar %s, t1_updates [%s], t1_update_not_registrar %s, t4_cancel_by_student2 %s, t57_owner_updates %s, counters_services_rows %s -> %s',
    x.ins, x.upd, x.upd_other, x.cancel, x.owner, x.other,
    case when x.ins = 1 and x.upd = 'Serving,Done' and x.upd_other = 0 and x.cancel = 1 and x.owner = 2 and x.other = 0
         then 'OK' else 'FAIL' end)
  from (select
    (select count(*) from public.audit_logs l
      where l.log_id > current_setting('app.log_mark')::bigint and l.table_name = 'queue_tickets'
        and l.record_id = current_setting('app.t_x1') and l.action = 'INSERT'
        and l.actor_id::text = current_setting('app.reg')) as ins,
    coalesce((select string_agg(l.new_data ->> 'status', ',' order by l.log_id) from public.audit_logs l
               where l.log_id > current_setting('app.log_mark')::bigint and l.table_name = 'queue_tickets'
                 and l.record_id = current_setting('app.t_x1') and l.action = 'UPDATE'), '') as upd,
    (select count(*) from public.audit_logs l
      where l.log_id > current_setting('app.log_mark')::bigint and l.table_name = 'queue_tickets'
        and l.record_id = current_setting('app.t_x1') and l.action = 'UPDATE'
        and l.actor_id::text is distinct from current_setting('app.reg')) as upd_other,
    (select count(*) from public.audit_logs l
      where l.log_id > current_setting('app.log_mark')::bigint and l.table_name = 'queue_tickets'
        and l.record_id = current_setting('app.t_x4') and l.action = 'UPDATE'
        and l.new_data ->> 'status' = 'Cancelled' and l.old_data ->> 'status' = 'Waiting'
        and l.actor_id::text = current_setting('app.s2')) as cancel,
    (select count(*) from public.audit_logs l
      where l.log_id > current_setting('app.log_mark')::bigint and l.table_name = 'queue_tickets'
        and l.record_id = current_setting('app.t_w57') and l.action = 'UPDATE' and l.actor_id is null) as owner,
    (select count(*) from public.audit_logs l
      where l.log_id > current_setting('app.log_mark')::bigint
        and l.table_name in ('queue_counters', 'queue_services')) as other
  ) x), true);

-- ==========================================
-- 20. TC-160: queue_finish needs no table UPDATE privilege
-- ==========================================
-- Expected: authenticated has no table- or column-level UPDATE on queue_tickets; the
-- Registrar's direct UPDATE of ticket 3 fails with 'permission denied'; queue_finish(ticket
-- 3, 'Done') returns 'done'; ticket 3 is Done, finished_at = now(), handled_by the Registrar.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c160_direct', 'reg', $q$update public.queue_tickets set status = 'Done' where ticket_id = current_setting('app.t_x3')::bigint returning 'updated'::text$q$),
    (2, 'c160_rpc',    'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_x3')::bigint, 'Done')$q$)
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
select set_config('app.r160', format('table_update %s, column_update %s, direct [%s], rpc [%s], t3_ok %s -> %s',
  has_table_privilege('authenticated', 'public.queue_tickets', 'UPDATE'),
  has_any_column_privilege('authenticated', 'public.queue_tickets', 'UPDATE'),
  current_setting('app.c160_direct'), current_setting('app.c160_rpc'),
  coalesce((select (t.status = 'Done' and t.finished_at = now() and t.handled_by::text = current_setting('app.reg'))::text
              from public.queue_tickets t where t.ticket_id = current_setting('app.t_x3')::bigint), 'none'),
  case when not has_table_privilege('authenticated', 'public.queue_tickets', 'UPDATE')
        and not has_any_column_privilege('authenticated', 'public.queue_tickets', 'UPDATE')
        and current_setting('app.c160_direct') like 'ERR [42501]: permission denied%'
        and current_setting('app.c160_rpc') = 'done'
        and coalesce((select t.status = 'Done' and t.finished_at = now() and t.handled_by::text = current_setting('app.reg')
                        from public.queue_tickets t where t.ticket_id = current_setting('app.t_x3')::bigint), false)
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 21. TC-161: EXECUTE grants and published return types
-- ==========================================
-- Expected: each of the 7 functions is executable by authenticated and by no other API role
-- (grantees other than the owner and the bypass-RLS server roles: exactly 'authenticated');
-- anon calling each of them: 7 x 'permission denied for function'; issue_queue_ticket,
-- queue_call_next, queue_finish, queue_cancel_my_ticket, queue_student_card return exactly
-- the published shapes; the functions in public that anon can execute are still exactly
-- check_login_lockout(text), list_programs(), login_email_for_student_id(text),
-- record_login_attempt(text, boolean, inet), submit_application(text, text, text, text, bigint).
set local role anon;
do $$
declare
  s     text;
  v_ok  integer := 0;
  v_bad text := '';
begin
  foreach s in array array[
    $q$select * from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCQ-A')$q$,
    $q$select * from public.queue_call_next('TCQ-A')$q$,
    $q$select * from public.queue_finish(1, 'Done')$q$,
    $q$select * from public.queue_cancel_my_ticket('TCQ-A')$q$,
    $q$select * from public.queue_my_status('TCQ-A')$q$,
    $q$select * from public.queue_staff_list('TCQ-A')$q$,
    $q$select * from public.queue_student_card(current_setting('app.s1')::uuid)$q$]
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
  perform set_config('app.t161_anon_ok', v_ok::text, true);
  perform set_config('app.t161_anon_bad', v_bad, true);
end $$;
reset role;
select set_config('app.t161_grantees', coalesce((select string_agg(f.fn || '=' || f.who, '; ' order by f.fn) from (
    select p.proname::text as fn,
           coalesce((select string_agg(distinct coalesce(r.rolname::text, 'PUBLIC'), ',')
                       from aclexplode(p.proacl) a left join pg_roles r on r.oid = a.grantee
                      where a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner
                        and not coalesce(r.rolbypassrls, false)), '') as who
    from pg_proc p
    where p.oid in (to_regprocedure('public.issue_queue_ticket(uuid, text)'),
                    to_regprocedure('public.queue_call_next(text, text)'),
                    to_regprocedure('public.queue_finish(bigint, text)'),
                    to_regprocedure('public.queue_cancel_my_ticket(text)'),
                    to_regprocedure('public.queue_my_status(text)'),
                    to_regprocedure('public.queue_staff_list(text)'),
                    to_regprocedure('public.queue_student_card(uuid)'))) f), ''), true);
select set_config('app.t161_types', (select
    (pg_get_function_result(to_regprocedure('public.issue_queue_ticket(uuid, text)'))
       = 'TABLE(ticket_id bigint, ticket_label text, status text, queue_date date, people_ahead integer)')::text
    || ',' || (pg_get_function_result(to_regprocedure('public.queue_call_next(text, text)'))
       = 'TABLE(ticket_id bigint, ticket_label text, student_id uuid, student_number text, student_name text, window_label text, called_at timestamp with time zone)')::text
    || ',' || (pg_get_function_result(to_regprocedure('public.queue_finish(bigint, text)')) = 'void')::text
    || ',' || (pg_get_function_result(to_regprocedure('public.queue_cancel_my_ticket(text)')) = 'void')::text
    || ',' || (pg_get_function_result(to_regprocedure('public.queue_student_card(uuid)'))
       = 'TABLE(student_id uuid, student_number text, student_name text, program_code text, program_name text, already_queued_label text)')::text), true);
select set_config('app.t161_anon_list', coalesce((select string_agg(p.proname || '(' || oidvectortypes(p.proargtypes) || ')', ', ' order by p.proname)
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and has_function_privilege('anon', p.oid, 'EXECUTE')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass
                    and d.objid = p.oid and d.deptype = 'e')), ''), true);
select set_config('app.r161', format('grantees [%s], anon_denied %s/7 [%s], types [%s], anon-executable in public [%s] -> %s',
  current_setting('app.t161_grantees'), current_setting('app.t161_anon_ok'), current_setting('app.t161_anon_bad'),
  current_setting('app.t161_types'), current_setting('app.t161_anon_list'),
  case when current_setting('app.t161_grantees') = 'issue_queue_ticket=authenticated; queue_call_next=authenticated; queue_cancel_my_ticket=authenticated; queue_finish=authenticated; queue_my_status=authenticated; queue_staff_list=authenticated; queue_student_card=authenticated'
        and current_setting('app.t161_anon_ok') = '7' and current_setting('app.t161_anon_bad') = ''
        and current_setting('app.t161_types') = 'true,true,true,true,true'
        and current_setting('app.t161_anon_list') = 'check_login_lockout(text), list_programs(), login_email_for_student_id(text), record_login_attempt(text, boolean, inet), submit_application(text, text, text, text, bigint)'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 22. TC-162: table constraints; window label; live CHECK constraints (informational)
-- ==========================================
-- Expected (as postgres): ticket number 0, code 999999 (below range), code 10000000 (above),
-- status 'Lost', window ' A', Waiting with called_at, prefix 'xy', empty service code,
-- counter -1: 'ERR [23514]' (check violation); a second active ticket of Student 3 in
-- TCQ-A today, internal number 1 again, ticket 1's code again in TCQ-A today, prefix 'X'
-- again: 'ERR [23505]' (unique violation); a ticket without ticket_code: 'ERR [23502]'
-- (not null); the Registrar's call with a 41-character window: 'ERR [22023]: invalid ticket
-- request: ...' (ticket 5 stays Waiting). The constraint list is printed.
do $$
declare r record;
begin
  for r in select * from (values
    (1,  'c162_number0',  $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
                             values (current_setting('app.svb')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 0, 2000001)$q$),
    (2,  'c162_code_low', $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
                             values (current_setting('app.svb')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 907, 999999)$q$),
    (3,  'c162_code_high',$q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
                             values (current_setting('app.svb')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 908, 10000000)$q$),
    (4,  'c162_status',   $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, status)
                             values (current_setting('app.svb')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 901, 2000002, 'Lost')$q$),
    (5,  'c162_window',   $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, window_label)
                             values (current_setting('app.svb')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 902, 2000003, ' A')$q$),
    (6,  'c162_state',    $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, called_at)
                             values (current_setting('app.svb')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 903, 2000004, now())$q$),
    (7,  'c162_active',   $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
                             values (current_setting('app.sva')::bigint, current_setting('app.s3')::uuid, current_setting('app.today')::date, 904,
                                     (select min(g)::integer from generate_series(3000000, 3001000) g
                                       where not exists (select 1 from public.queue_tickets q where q.service_id = current_setting('app.sva')::bigint
                                                           and q.queue_date = current_setting('app.today')::date and q.ticket_code = g)))$q$),
    (8,  'c162_dupnum',   $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
                             values (current_setting('app.sva')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 1,
                                     (select min(g)::integer from generate_series(3000000, 3001000) g
                                       where not exists (select 1 from public.queue_tickets q where q.service_id = current_setting('app.sva')::bigint
                                                           and q.queue_date = current_setting('app.today')::date and q.ticket_code = g)))$q$),
    (9,  'c162_dupcode',  $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
                             values (current_setting('app.sva')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 905,
                                     (select q.ticket_code from public.queue_tickets q where q.ticket_id = current_setting('app.t_x1')::bigint))$q$),
    (10, 'c162_nocode',   $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number)
                             values (current_setting('app.svb')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 906)$q$),
    (11, 'c162_prefix',   $q$insert into public.queue_services (service_code, service_name, ticket_prefix) values ('TCQ-D', 'TC queue D', 'xy')$q$),
    (12, 'c162_dupprefix',$q$insert into public.queue_services (service_code, service_name, ticket_prefix) values ('TCQ-D', 'TC queue D', 'X')$q$),
    (13, 'c162_code',     $q$insert into public.queue_services (service_code, service_name, ticket_prefix) values ('', 'TC queue D', 'Z')$q$),
    (14, 'c162_counter',  $q$insert into public.queue_counters (service_id, queue_date, last_number)
                             values (current_setting('app.svb')::bigint, current_setting('app.today')::date, -1)$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      perform set_config('app.' || r.label, 'ACCEPTED', true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']', true);
    end;
  end loop;
end $$;
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c162_long_window', 'reg', $q$select c.ticket_label from public.queue_call_next('TCQ-A', repeat('w', 41)) c$q$)
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
select set_config('app.r162', format('number0 %s, code_low %s, code_high %s, status %s, window %s, state %s, second_active %s, duplicate_number %s, duplicate_code %s, no_code %s, prefix %s, duplicate_prefix %s, empty_code %s, counter %s, long_window [%s], t5 %s, live_constraints [%s] -> %s',
  current_setting('app.c162_number0'), current_setting('app.c162_code_low'), current_setting('app.c162_code_high'),
  current_setting('app.c162_status'), current_setting('app.c162_window'),
  current_setting('app.c162_state'), current_setting('app.c162_active'), current_setting('app.c162_dupnum'),
  current_setting('app.c162_dupcode'), current_setting('app.c162_nocode'),
  current_setting('app.c162_prefix'), current_setting('app.c162_dupprefix'), current_setting('app.c162_code'),
  current_setting('app.c162_counter'), current_setting('app.c162_long_window'),
  (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x5')::bigint),
  coalesce((select string_agg(c.conrelid::regclass::text || '.' || c.conname || ' ' || pg_get_constraintdef(c.oid), '; '
                              order by c.conrelid::regclass::text, c.conname)
              from pg_constraint c
             where c.contype in ('c', 'u')
               and c.conrelid in ('public.profiles'::regclass, 'public.students'::regclass, 'public.audit_logs'::regclass,
                                  'public.queue_services'::regclass, 'public.queue_tickets'::regclass,
                                  'public.queue_counters'::regclass)), ''),
  case when current_setting('app.c162_number0') = 'ERR [23514]' and current_setting('app.c162_code_low') = 'ERR [23514]'
        and current_setting('app.c162_code_high') = 'ERR [23514]' and current_setting('app.c162_status') = 'ERR [23514]'
        and current_setting('app.c162_window') = 'ERR [23514]' and current_setting('app.c162_state') = 'ERR [23514]'
        and current_setting('app.c162_active') = 'ERR [23505]' and current_setting('app.c162_dupnum') = 'ERR [23505]'
        and current_setting('app.c162_dupcode') = 'ERR [23505]' and current_setting('app.c162_nocode') = 'ERR [23502]'
        and current_setting('app.c162_prefix') = 'ERR [23514]' and current_setting('app.c162_dupprefix') = 'ERR [23505]'
        and current_setting('app.c162_code') = 'ERR [23514]' and current_setting('app.c162_counter') = 'ERR [23514]'
        and current_setting('app.c162_long_window') like 'ERR [22023]: invalid ticket request:%'
        and (select t.status from public.queue_tickets t where t.ticket_id = current_setting('app.t_x5')::bigint) = 'Waiting'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 23. TC-163: the random display code
-- ==========================================
-- Expected (no statistics, only facts): every ticket issued by the function today in TCQ-A
-- and TCQ-C has a code in 1000000..9999999 (out_of_range 0); codes are unique per service
-- and day (duplicates 0); the internal numbers of TCQ-A's issued tickets follow the issue
-- order (by ticket_id): '1,2,3,4,5,6'; every label returned by queue_staff_list matches
-- '#' + 7 digits (bad_labels NULL); private.queue_label(1234567) = '#1234567'; 50 calls of
-- private.queue_random_code() all in range; its source uses gen_random_uuid() and neither it
-- nor issue_queue_ticket contains random(); uq_queue_tickets_code and ck_queue_tickets_code
-- exist (also TC-139).
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c163_labels', 'reg', $q$select string_agg(l.ticket_label, ',') from public.queue_staff_list('TCQ-A') l
                                 where l.ticket_label !~ '^#[1-9][0-9]{6}$'$q$)
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
select set_config('app.r163', (select format('out_of_range %s, duplicates %s, issue_order [%s], bad_labels [%s], label_fn [%s], random_in_range %s/50, source_ok %s, constraints %s -> %s',
    x.oor, x.dups, x.ord, current_setting('app.c163_labels'), x.lbl, x.rnd, x.src, x.cons,
    case when x.oor = 0 and x.dups = 0 and x.ord = '1,2,3,4,5,6' and current_setting('app.c163_labels') = 'NULL'
          and x.lbl = '#1234567' and x.rnd = 50 and x.src and x.cons = 2
         then 'OK' else 'FAIL' end)
  from (select
    (select count(*) from public.queue_tickets t
      where t.service_id in (current_setting('app.sva')::bigint, current_setting('app.svc')::bigint)
        and t.queue_date = current_setting('app.today')::date
        and t.ticket_code not between 1000000 and 9999999) as oor,
    (select count(*) from (select t.service_id, t.queue_date, t.ticket_code from public.queue_tickets t
                            where t.service_id in (current_setting('app.sva')::bigint, current_setting('app.svb')::bigint,
                                                   current_setting('app.svc')::bigint)
                            group by 1, 2, 3 having count(*) > 1) d) as dups,
    coalesce((select string_agg(t.ticket_number::text, ',' order by t.ticket_id) from public.queue_tickets t
               where t.service_id = current_setting('app.sva')::bigint and t.queue_date = current_setting('app.today')::date
                 and t.ticket_number < 900), '') as ord,
    private.queue_label(1234567) as lbl,
    (select count(*) from generate_series(1, 50) g where private.queue_random_code() between 1000000 and 9999999) as rnd,
    ((select p.prosrc from pg_proc p where p.oid = to_regprocedure('private.queue_random_code()')) like '%gen_random_uuid()%'
     and (select p.prosrc from pg_proc p where p.oid = to_regprocedure('private.queue_random_code()')) not like '% random()%'
     and (select p.prosrc from pg_proc p where p.oid = to_regprocedure('private.queue_random_code()')) not like '%(random()%'
     and (select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.issue_queue_ticket(uuid, text)')) not like '% random()%'
     and (select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.issue_queue_ticket(uuid, text)')) not like '%(random()%') as src,
    (select count(*) from pg_constraint c
      where c.conrelid = 'public.queue_tickets'::regclass
        and ((c.conname = 'uq_queue_tickets_code' and c.contype = 'u')
          or (c.conname = 'ck_queue_tickets_code' and c.contype = 'c'))) as cons
  ) x), true);

-- ==========================================
-- 24. TC-164: order follows the internal number, not the code; window_label; no leaks
-- ==========================================
-- Setup as postgres in the closed TCQ-B (closed only stops NEW tickets): ticket 1 of
-- Student 1 with code 9999999 (issued first), ticket 2 of Student 2 with code 1000000.
-- Expected: the Registrar's call (window 'Desk 3') takes '#9999999' (internal number 1),
-- not the lowest code; Student 1's status 'false|true|#9999999|Serving|0|#9999999|1|NULL|Desk 3';
-- Student 2's status 'false|true|#1000000|Waiting|0|#9999999|1|NULL|NULL' and its raw row
-- contains neither Student 1's id, number or last name nor 'Desk 3'; after finishing it
-- Done, Student 1's status 'false|true|#9999999|Done|NULL|#9999999|1|0|NULL' (window NULL
-- once not Serving).
insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
values (current_setting('app.svb')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 1, 9999999);
insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
values (current_setting('app.svb')::bigint, current_setting('app.s2')::uuid, current_setting('app.today')::date, 2, 1000000);
select set_config('app.t_y1', (select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.svb')::bigint and queue_date = current_setting('app.today')::date and ticket_number = 1), true);
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c164_call',   'reg', $q$select c.ticket_label || '|' || c.student_id || '|' || coalesce(c.window_label, 'NULL')
                                from public.queue_call_next('TCQ-B', 'Desk 3') c$q$),
    (2, 'c164_s1',     's1',  $q$select s.is_open::text || '|' || s.has_ticket::text || '|' || coalesce(s.ticket_label, 'NULL') || '|'
                                  || coalesce(s.ticket_status, 'NULL') || '|' || coalesce(s.people_ahead::text, 'NULL') || '|'
                                  || coalesce(s.now_serving, 'NULL') || '|' || coalesce(s.waiting_total::text, 'NULL') || '|'
                                  || coalesce(s.avg_service_seconds::text, 'NULL') || '|' || coalesce(s.window_label, 'NULL')
                                  from public.queue_my_status('TCQ-B') s$q$),
    (3, 'c164_s2',     's2',  $q$select s.is_open::text || '|' || s.has_ticket::text || '|' || coalesce(s.ticket_label, 'NULL') || '|'
                                  || coalesce(s.ticket_status, 'NULL') || '|' || coalesce(s.people_ahead::text, 'NULL') || '|'
                                  || coalesce(s.now_serving, 'NULL') || '|' || coalesce(s.waiting_total::text, 'NULL') || '|'
                                  || coalesce(s.avg_service_seconds::text, 'NULL') || '|' || coalesce(s.window_label, 'NULL')
                                  from public.queue_my_status('TCQ-B') s$q$),
    (4, 'c164_raw_s2', 's2',  $q$select row_to_json(s)::text from public.queue_my_status('TCQ-B') s$q$),
    (5, 'c164_finish', 'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_y1')::bigint, 'Done')$q$),
    (6, 'c164_s1done', 's1',  $q$select s.is_open::text || '|' || s.has_ticket::text || '|' || coalesce(s.ticket_label, 'NULL') || '|'
                                  || coalesce(s.ticket_status, 'NULL') || '|' || coalesce(s.people_ahead::text, 'NULL') || '|'
                                  || coalesce(s.now_serving, 'NULL') || '|' || coalesce(s.waiting_total::text, 'NULL') || '|'
                                  || coalesce(s.avg_service_seconds::text, 'NULL') || '|' || coalesce(s.window_label, 'NULL')
                                  from public.queue_my_status('TCQ-B') s$q$)
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
select set_config('app.t164_leak', (select coalesce(string_agg(v.n, ', '), '') from (values
    ('s1 id', current_setting('app.s1')), ('s1 number', current_setting('app.s1num')),
    ('s1 last name', current_setting('app.s1last')), ('s1 window', 'Desk 3')) as v(n, val)
  where position(v.val in current_setting('app.c164_raw_s2')) > 0), true);
select set_config('app.r164', format('call [%s], s1_serving [%s], s2_waiting [%s], leaks [%s], finish [%s], s1_done [%s] -> %s',
  current_setting('app.c164_call'), current_setting('app.c164_s1'), current_setting('app.c164_s2'),
  current_setting('app.t164_leak'), current_setting('app.c164_finish'), current_setting('app.c164_s1done'),
  case when current_setting('app.c164_call') = '#9999999|' || current_setting('app.s1') || '|Desk 3'
        and current_setting('app.c164_s1') = 'false|true|#9999999|Serving|0|#9999999|1|NULL|Desk 3'
        and current_setting('app.c164_s2') = 'false|true|#1000000|Waiting|0|#9999999|1|NULL|NULL'
        and current_setting('app.c164_raw_s2') like '{%'
        and current_setting('app.t164_leak') = ''
        and current_setting('app.c164_finish') = 'done'
        and current_setting('app.c164_s1done') = 'false|true|#9999999|Done|NULL|#9999999|1|0|NULL'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 25. TC-165: queue_student_card for the Registrar
-- ==========================================
-- Setup as postgres: Student 2 gets an active ticket in the REAL Enrollment service today
-- (a high internal number and a free code; ON CONFLICT DO NOTHING if Student 2 already has
-- one live). Expected: each card has exactly 1 row
-- '<id>|<number>|<Last, First>|<program code>|<program name>|<label or NULL>' where the
-- label is the student's active Enrollment ticket of today read from the table: for Student
-- 2 it is filled ('#' + 7 digits); for Student 1 it is whatever the table holds (NULL unless
-- Student 1 is queued live in Enrollment; the cell shows which). The TCQ-A tickets of
-- Student 1 are never reported (only Enrollment counts).
insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
select current_setting('app.enr')::bigint, current_setting('app.s2')::uuid, current_setting('app.today')::date,
       (select coalesce(max(q.ticket_number), 0) + 1000 from public.queue_tickets q
         where q.service_id = current_setting('app.enr')::bigint and q.queue_date = current_setting('app.today')::date),
       (select min(g)::integer from generate_series(1000000, 1001000) g
         where not exists (select 1 from public.queue_tickets q where q.service_id = current_setting('app.enr')::bigint
                             and q.queue_date = current_setting('app.today')::date and q.ticket_code = g))
on conflict do nothing;
select set_config('app.t165_s1_label', coalesce((select '#' || t.ticket_code from public.queue_tickets t
  where t.service_id = current_setting('app.enr')::bigint and t.student_id::text = current_setting('app.s1')
    and t.queue_date = current_setting('app.today')::date and t.status in ('Waiting', 'Serving')
  order by t.ticket_number limit 1), 'NULL'), true);
select set_config('app.t165_s2_label', coalesce((select '#' || t.ticket_code from public.queue_tickets t
  where t.service_id = current_setting('app.enr')::bigint and t.student_id::text = current_setting('app.s2')
    and t.queue_date = current_setting('app.today')::date and t.status in ('Waiting', 'Serving')
  order by t.ticket_number limit 1), 'NULL'), true);
select set_config('app.t165_s1_prog', (select pr.code::text || '|' || pr.name::text from public.students s
  join public.programs pr on pr.program_id = s.program_id where s.student_id::text = current_setting('app.s1')), true);
select set_config('app.t165_s2_prog', (select pr.code::text || '|' || pr.name::text from public.students s
  join public.programs pr on pr.program_id = s.program_id where s.student_id::text = current_setting('app.s2')), true);
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c165_s1',   'reg', $q$select c.student_id || '|' || c.student_number || '|' || c.student_name || '|' || c.program_code || '|'
                               || c.program_name || '|' || coalesce(c.already_queued_label, 'NULL')
                               from public.queue_student_card(current_setting('app.s1')::uuid) c$q$),
    (2, 'c165_s2',   'reg', $q$select c.student_id || '|' || c.student_number || '|' || c.student_name || '|' || c.program_code || '|'
                               || c.program_name || '|' || coalesce(c.already_queued_label, 'NULL')
                               from public.queue_student_card(current_setting('app.s2')::uuid) c$q$),
    (3, 'c165_rows', 'reg', $q$select count(*)::text from public.queue_student_card(current_setting('app.s1')::uuid) c$q$)
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
select set_config('app.r165', format('student1 [%s], student2 [%s], rows %s -> %s',
  current_setting('app.c165_s1'), current_setting('app.c165_s2'), current_setting('app.c165_rows'),
  case when current_setting('app.c165_s1') = format('%s|%s|%s|%s|%s', current_setting('app.s1'), current_setting('app.s1num'),
                                                   current_setting('app.s1name'), current_setting('app.t165_s1_prog'), current_setting('app.t165_s1_label'))
        and current_setting('app.c165_s2') = format('%s|%s|%s|%s|%s', current_setting('app.s2'), current_setting('app.s2num'),
                                                   current_setting('app.s2name'), current_setting('app.t165_s2_prog'), current_setting('app.t165_s2_label'))
        and current_setting('app.t165_s2_label') ~ '^#[1-9][0-9]{6}$'
        and current_setting('app.c165_rows') = '1'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 26. TC-166: queue_student_card refusals
-- ==========================================
-- Expected: Student, Cashier, Department, Admin 'ERR [42501]: not allowed: ...'; anon
-- 'ERR [42501]: permission denied for function queue_student_card'; the Registrar asking
-- for a non-student (the Registrar's own id), an unknown id, NULL, or an inactive student
-- (Student 3 deactivated for the call): 'ERR [22023]: invalid ticket request: the person is
-- not an active student'.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c166_student',    's1',   $q$select c.student_number from public.queue_student_card(current_setting('app.s2')::uuid) c$q$),
    (2, 'c166_cashier',    'cash', $q$select c.student_number from public.queue_student_card(current_setting('app.s2')::uuid) c$q$),
    (3, 'c166_dept',       'dept', $q$select c.student_number from public.queue_student_card(current_setting('app.s2')::uuid) c$q$),
    (4, 'c166_admin',      'adm',  $q$select c.student_number from public.queue_student_card(current_setting('app.s2')::uuid) c$q$),
    (5, 'c166_nonstudent', 'reg',  $q$select c.student_number from public.queue_student_card(current_setting('app.reg')::uuid) c$q$),
    (6, 'c166_unknown',    'reg',  $q$select c.student_number from public.queue_student_card(gen_random_uuid()) c$q$),
    (7, 'c166_null',       'reg',  $q$select c.student_number from public.queue_student_card(null) c$q$)
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
declare v text;
begin
  select c.student_number into v from public.queue_student_card(current_setting('app.s2')::uuid) c;
  perform set_config('app.c166_anon', coalesce(v, 'NULL'), true);
exception when others then
  perform set_config('app.c166_anon', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
reset role;
update public.profiles set is_active = false where profile_id::text = current_setting('app.s3');
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c166_inactive', 'reg', $q$select c.student_number from public.queue_student_card(current_setting('app.s3')::uuid) c$q$)
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
update public.profiles set is_active = true where profile_id::text = current_setting('app.s3');
select set_config('app.r166', format('student [%s], cashier [%s], department [%s], admin [%s], anon [%s], non_student [%s], unknown [%s], null [%s], inactive [%s] -> %s',
  current_setting('app.c166_student'), current_setting('app.c166_cashier'), current_setting('app.c166_dept'),
  current_setting('app.c166_admin'), current_setting('app.c166_anon'), current_setting('app.c166_nonstudent'),
  current_setting('app.c166_unknown'), current_setting('app.c166_null'), current_setting('app.c166_inactive'),
  case when current_setting('app.c166_student') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c166_cashier') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c166_dept') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c166_admin') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c166_anon') like 'ERR [42501]: permission denied for function queue_student_card%'
        and current_setting('app.c166_nonstudent') = 'ERR [22023]: invalid ticket request: the person is not an active student'
        and current_setting('app.c166_unknown') = 'ERR [22023]: invalid ticket request: the person is not an active student'
        and current_setting('app.c166_null') = 'ERR [22023]: invalid ticket request: the person is not an active student'
        and current_setting('app.c166_inactive') = 'ERR [22023]: invalid ticket request: the person is not an active student'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- Result: ONE row
-- ==========================================
select (current_setting('app.r139') like '%-> OK' and current_setting('app.r140') like '%-> OK'
        and current_setting('app.r141') like '%-> OK' and current_setting('app.r142') like '%-> OK'
        and current_setting('app.r143') like '%-> OK' and current_setting('app.r144') like '%-> OK'
        and current_setting('app.r145') like '%-> OK' and current_setting('app.r146') like '%-> OK'
        and current_setting('app.r147') like '%-> OK' and current_setting('app.r148') like '%-> OK'
        and current_setting('app.r149') like '%-> OK' and current_setting('app.r150') like '%-> OK'
        and current_setting('app.r151') like '%-> OK' and current_setting('app.r152') like '%-> OK'
        and current_setting('app.r153') like '%-> OK' and current_setting('app.r154') like '%-> OK'
        and current_setting('app.r155') like '%-> OK' and current_setting('app.r156') like '%-> OK'
        and current_setting('app.r157') like '%-> OK' and current_setting('app.r158') like '%-> OK'
        and current_setting('app.r159') like '%-> OK' and current_setting('app.r160') like '%-> OK'
        and current_setting('app.r161') like '%-> OK' and current_setting('app.r162') like '%-> OK'
        and current_setting('app.r163') like '%-> OK' and current_setting('app.r164') like '%-> OK'
        and current_setting('app.r165') like '%-> OK' and current_setting('app.r166') like '%-> OK') as all_ok,
  current_setting('app.r139') as tc139, current_setting('app.r140') as tc140, current_setting('app.r141') as tc141,
  current_setting('app.r142') as tc142, current_setting('app.r143') as tc143, current_setting('app.r144') as tc144,
  current_setting('app.r145') as tc145, current_setting('app.r146') as tc146, current_setting('app.r147') as tc147,
  current_setting('app.r148') as tc148, current_setting('app.r149') as tc149, current_setting('app.r150') as tc150,
  current_setting('app.r151') as tc151, current_setting('app.r152') as tc152, current_setting('app.r153') as tc153,
  current_setting('app.r154') as tc154, current_setting('app.r155') as tc155, current_setting('app.r156') as tc156,
  current_setting('app.r157') as tc157, current_setting('app.r158') as tc158, current_setting('app.r159') as tc159,
  current_setting('app.r160') as tc160, current_setting('app.r161') as tc161, current_setting('app.r162') as tc162,
  current_setting('app.r163') as tc163, current_setting('app.r164') as tc164, current_setting('app.r165') as tc165,
  current_setting('app.r166') as tc166;

rollback;
