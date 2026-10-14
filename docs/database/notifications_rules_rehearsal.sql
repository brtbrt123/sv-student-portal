-- ==========================================
-- REHEARSAL: notifications_rules.sql + TC-167 to TC-198 in ONE rolled-back transaction
-- ==========================================
-- In-app notifications for every role (feature/notifications). One paste, one run, ONE
-- result row, nothing committed. This is TC-167R.
--
-- How to run: Supabase SQL editor, as postgres, a new tab, at a quiet time. Paste the whole
-- file (from "begin;" to "rollback;") and click Run on the whole tab, never a selection. If
-- the script stops with an error, run "rollback;" as its own query and send the error back.
--
-- What it does:
--   1. begin;
--   2. the body of docs/database/notifications_rules.sql (everything between its "BEGIN;" and
--      "COMMIT;" lines, copied verbatim by a script: safety checks, table, helpers, triggers,
--      functions, policy, grants, checks after the change; the NOTIFY is never sent because
--      of the rollback). A "notifications_rules: ..." error here means the live state is not
--      what the file assumes: do NOT run the file live; send the error back. The NOTICE
--      lines of safety checks (g) and (h) list the live CHECK constraints and the Cashier's
--      office: read them.
--   3. TC-167 to TC-198 (docs/database/notifications_rules_test.sql from its "begin;" line,
--      verbatim). The tests create a throwaway term, clearance, holds, document requests,
--      grades, two applications and a throwaway queue service TCN-A (TC-173 adds one ticket
--      to each real queue service); seed accounts are only recipients (no account is
--      created). TC-196 adds a temporary CHECK (false) to notifications and TC-197 replaces
--      private.notify by a raising version to prove that a failing notification never
--      fails the original change (both undone inside the case). Each result is stored with
--      set_config('app.rNNN', ...).
--   4. One final row: one cell per case, each ending in "-> OK" or "-> FAIL", plus "all_ok".
--      TC-170 also lists the live CHECK constraints of the tables involved (read it).
--   5. rollback; (the table, functions, triggers, grants and all test data disappear)
--
-- RUNNING ONLY THE TESTS (after the change is live): the test part starts at the line
-- "-- TESTS START HERE" and is self-contained: copy from the "begin;" line right below that
-- marker to the end of the file into a new tab and run it (or run
-- docs/database/notifications_rules_test.sql, which is the same). It ends in rollback.
--
-- Every statement that is expected to fail runs inside a do block with an exception
-- handler, so the transaction is never aborted by an expected error.
--
-- Status: NOT RUN YET (written 2026-10-13 without a local PostgreSQL).

begin;

-- ==========================================
-- 1. The change (body of notifications_rules.sql, verbatim)
-- ==========================================


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



-- ==========================================
-- TESTS START HERE (TC-167 to TC-198)
-- ==========================================
-- To run ONLY the tests once notifications_rules.sql is live: copy from the next line
-- ("begin;") to the end of this file into a new tab and run that tab as a whole.
-- In the full rehearsal the next line is a second BEGIN inside the open transaction;
-- PostgreSQL only answers "WARNING: there is already a transaction in progress" and carries
-- on (nothing is committed either way; the file ends in rollback).
begin;

-- ==========================================
-- 1. Accounts, ids, throwaway data (as postgres, no user JWT)
-- ==========================================
select set_config('request.jwt.claims', '', true);
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
  if to_regclass('public.notifications') is null
     or to_regprocedure('public.list_my_notifications(integer, boolean)') is null
     or to_regprocedure('public.notification_unread_count()') is null
     or to_regprocedure('public.mark_notifications_read(bigint[])') is null
     or to_regprocedure('private.notify(uuid, text, text, text, text)') is null
     or to_regprocedure('public.issue_queue_ticket(uuid, text)') is null then
    raise exception 'TC setup: notifications_rules.sql (or queue_rules.sql) is not installed (run it, or use notifications_rules_rehearsal.sql)';
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
  if not exists (select 1 from public.department_staff ds where ds.profile_id::text = current_setting('app.dept')) then
    raise exception 'TC setup: dept@pnc.test has no department_staff row';
  end if;
  if not exists (select 1 from public.departments d where d.department_type = 'Financial') then
    raise exception 'TC setup: no department of type Financial';
  end if;
  if (select ds.department_id from public.department_staff ds where ds.profile_id::text = current_setting('app.dept')
       order by ds.department_id limit 1)
     = (select d.department_id from public.departments d where d.department_type = 'Financial'
         order by d.department_id limit 1) then
    raise exception 'TC setup: dept@pnc.test belongs to the Financial department; the tests need an academic department';
  end if;
  if exists (select 1 from public.queue_services where service_code = 'TCN-A') then
    raise exception 'TC setup: a queue service TCN-A exists; the tests need the code free';
  end if;
  if not exists (select 1 from public.queue_services where service_code = 'Enrollment')
     or not exists (select 1 from public.queue_services where service_code = 'Documents') then
    raise exception 'TC setup: the queue services Enrollment / Documents are missing';
  end if;
  if exists (select 1 from public.applications where email like '%@notify.test') then
    raise exception 'TC setup: applications under @notify.test exist; the tests need them free';
  end if;
  if exists (select 1 from public.terms where school_year = '2091-2092' and semester = '1st') then
    raise exception 'TC setup: a term 2091-2092 1st exists; the tests need it free';
  end if;
  if not exists (select 1 from public.grade_scale where grade_code = '1.75')
     or not exists (select 1 from public.grade_scale where grade_code = '2.00')
     or not exists (select 1 from public.subjects) or not exists (select 1 from public.document_types)
     or not exists (select 1 from public.programs) then
    raise exception 'TC setup: grade_scale 1.75 / 2.00, a subject, a document type or a program is missing';
  end if;
end $$;
select set_config('app.ddep', (select ds.department_id::text from public.department_staff ds
  where ds.profile_id::text = current_setting('app.dept') order by ds.department_id limit 1), true);
select set_config('app.ddep_name', (select d.name::text from public.departments d where d.department_id::text = current_setting('app.ddep')), true);
select set_config('app.fin', (select d.department_id::text from public.departments d
  where d.department_type = 'Financial' order by d.department_id limit 1), true);
select set_config('app.dt', (select min(document_type_id)::text from public.document_types), true);
select set_config('app.dt_name', (select name::text from public.document_types where document_type_id::text = current_setting('app.dt')), true);
select set_config('app.prog', (select min(program_id)::text from public.programs), true);
select set_config('app.prog_code', (select code::text from public.programs where program_id::text = current_setting('app.prog')), true);
select set_config('app.subj', (select min(subject_id)::text from public.subjects), true);
select set_config('app.subj_code', (select code::text from public.subjects where subject_id::text = current_setting('app.subj')), true);
select set_config('app.s1name', (select last_name::text || ', ' || first_name::text from public.profiles where profile_id::text = current_setting('app.s1')), true);
select set_config('app.s2name', (select last_name::text || ', ' || first_name::text from public.profiles where profile_id::text = current_setting('app.s2')), true);
select set_config('app.log_mark', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);
-- the throwaway queue service (a free prefix letter), term and section
insert into public.queue_services (service_code, service_name, ticket_prefix, is_open)
select 'TCN-A', 'TC notifications queue', chr(g), true
from generate_series(65, 90) g
where chr(g) not in (select ticket_prefix from public.queue_services)
order by g desc
limit 1;
with t as (insert into public.terms (school_year, semester, start_date, end_date, is_current)
           values ('2091-2092', '1st', '2091-08-01', '2092-01-01', false) returning term_id)
select set_config('app.term', term_id::text, true) from t;
with s as (insert into public.sections (subject_id, term_id, section_code, schedule, capacity)
           values (current_setting('app.subj')::bigint, current_setting('app.term')::bigint, 'TCN-1', 'TC-167 test', 40)
           returning section_id)
select set_config('app.sec', section_id::text, true) from s;
-- known start: Student 1 has no active hold (require_no_active_hold would refuse to clear)
update public.academic_holds set lifted_at = now(), lifted_by = current_setting('app.dept')::uuid
where student_id::text = current_setting('app.s1') and lifted_at is null;

-- helpers for the checks (temporary, gone with the transaction; called as postgres only)
create function pg_temp.mark() returns bigint language sql stable as $f$
  select coalesce(max(n.notification_id), 0) from public.notifications n
$f$;
create function pg_temp.notes(p_mark bigint, p_tag text) returns text language sql stable as $f$
  select coalesce(string_agg(n.kind || '|' || n.title || '|' || n.body || '|' || coalesce(n.link, 'NULL'), ' ; '
                             order by n.notification_id), '')
  from public.notifications n
  where n.notification_id > p_mark and n.created_at = now()
    and n.recipient_id::text = current_setting('app.' || p_tag)
$f$;
create function pg_temp.nkind(p_mark bigint, p_kind text) returns bigint language sql stable as $f$
  select count(*) from public.notifications n
  where n.notification_id > p_mark and n.created_at = now() and n.kind = p_kind
$f$;
create function pg_temp.nall(p_mark bigint) returns bigint language sql stable as $f$
  select count(*) from public.notifications n
  where n.notification_id > p_mark and n.created_at = now()
$f$;
create function pg_temp.role_count(p_role text) returns bigint language sql stable as $f$
  select count(*) from public.profiles p join public.roles r on r.role_id = p.role_id
  where r.role_name::text = p_role and p.is_active
$f$;
create function pg_temp.heads(p_dep bigint) returns bigint language sql stable as $f$
  select count(*) from public.department_staff ds
  join public.profiles p on p.profile_id = ds.profile_id
  join public.roles r on r.role_id = p.role_id
  where ds.department_id = p_dep and r.role_name::text = 'Department' and p.is_active
$f$;
-- every ACTIVE profile of the role has exactly one row of that kind with that
-- 'title|body|link', and nobody else has a row of that kind
create function pg_temp.role_ok(p_mark bigint, p_kind text, p_role text, p_text text) returns boolean language sql stable as $f$
  select pg_temp.role_count(p_role) > 0
     and pg_temp.nkind(p_mark, p_kind) = pg_temp.role_count(p_role)
     and not exists (
       select 1 from public.profiles p join public.roles r on r.role_id = p.role_id
       where r.role_name::text = p_role and p.is_active
         and (select count(*) from public.notifications n
               where n.notification_id > p_mark and n.created_at = now() and n.kind = p_kind
                 and n.recipient_id = p.profile_id
                 and n.title || '|' || n.body || '|' || coalesce(n.link, 'NULL') = p_text) <> 1)
$f$;
create function pg_temp.ahead_text(p_n bigint) returns text language sql immutable as $f$
  select case when p_n = 0 then 'No one is ahead of you.'
              when p_n = 1 then '1 person is ahead of you.'
              else p_n::text || ' people are ahead of you.' end
$f$;

-- ==========================================
-- 2. TC-167: installed as intended (catalog)
-- ==========================================
-- Expected: columns_diff empty, checks 4, fk_cascade true, indexes 2, rls true, policy
-- 'notifications_own_read (SELECT authenticated)' using active_uid, triggers 9/9,
-- notifications_triggers 1, after_ours '' (nothing fires after a notification trigger),
-- public 3/3, helpers 4/4, trigger functions 9/9.
select set_config('app.r167', (select format('columns_diff [%s], checks %s, fk_cascade %s, indexes %s, rls %s, policy [%s], policy_uses_active_uid %s, triggers_ok %s/9, notifications_triggers %s, after_ours [%s], public_fns_ok %s/3, helpers_ok %s/4, trigger_fns_ok %s/9 -> %s',
    x.cols_diff, x.checks, x.fk, x.idx, x.rls, x.pol, x.pol_uid, x.trg, x.ntrg, x.after_ours, x.pub_ok, x.help_ok, x.tfn_ok,
    case when x.cols_diff = '' and x.checks = 4 and x.fk and x.idx = 2 and x.rls
          and x.pol = 'notifications_own_read (SELECT authenticated)' and x.pol_uid
          and x.trg = 9 and x.ntrg = 1 and x.after_ours = ''
          and x.pub_ok = 3 and x.help_ok = 4 and x.tfn_ok = 9
         then 'OK' else 'FAIL' end)
  from (select
    coalesce((with expected(col, typ) as (values
                ('notification_id', 'bigint'), ('recipient_id', 'uuid'), ('kind', 'text'), ('title', 'text'),
                ('body', 'text'), ('link', 'text'), ('created_at', 'timestamp with time zone'),
                ('read_at', 'timestamp with time zone')),
              live as (
                select a.attname::text as col, format_type(a.atttypid, null) as typ
                from pg_attribute a
                where a.attrelid = 'public.notifications'::regclass and a.attnum > 0 and not a.attisdropped)
              select string_agg(d, '; ' order by d) from (
                (select 'missing ' || col || ' ' || typ as d from (select * from expected except select * from live) m)
                union all
                (select 'unexpected ' || col || ' ' || typ from (select * from live except select * from expected) u)) dd), '') as cols_diff,
    (select count(*) from pg_constraint c
      where c.conrelid = 'public.notifications'::regclass and c.contype = 'c'
        and c.conname in ('ck_notifications_kind', 'ck_notifications_title', 'ck_notifications_body', 'ck_notifications_link')) as checks,
    exists (select 1 from pg_constraint c
             where c.conrelid = 'public.notifications'::regclass and c.contype = 'f'
               and c.conname = 'fk_notifications_recipient_id' and c.confrelid = 'public.profiles'::regclass
               and c.confdeltype = 'c') as fk,
    (select count(*) from pg_index i
      where i.indrelid = 'public.notifications'::regclass
        and (i.indexrelid = to_regclass('public.notifications_recipient_created_idx')
             or (i.indexrelid = to_regclass('public.notifications_unread_idx') and i.indpred is not null))) as idx,
    (select c.relrowsecurity from pg_class c where c.oid = 'public.notifications'::regclass) as rls,
    coalesce((select string_agg(p.policyname || ' (' || p.cmd || ' ' || array_to_string(p.roles, ',') || ')', ', ')
                from pg_policies p where p.schemaname = 'public' and p.tablename = 'notifications'), '') as pol,
    coalesce((select bool_and(p.qual like '%recipient_id%active_uid()%')
                from pg_policies p where p.schemaname = 'public' and p.tablename = 'notifications'), false) as pol_uid,
    (select count(*) from (values
        ('queue_tickets', 'trg_notify_queue_tickets', 'private.notify_on_queue_tickets()', 21),
        ('enrollments', 'trg_notify_enrollments', 'private.notify_on_enrollments()', 21),
        ('document_requests', 'trg_notify_document_requests', 'private.notify_on_document_requests()', 21),
        ('clearance_items', 'trg_notify_clearance_items', 'private.notify_on_clearance_items()', 21),
        ('clearances', 'trg_notify_clearances', 'private.notify_on_clearances()', 17),
        ('academic_holds', 'trg_notify_academic_holds', 'private.notify_on_academic_holds()', 21),
        ('grades', 'trg_notify_grades', 'private.notify_on_grades()', 21),
        ('applications', 'trg_notify_applications', 'private.notify_on_applications()', 5),
        ('notifications', 'require_notification_rules', 'private.require_notification_rules()', 19)) as e(tbl, tg, fn, typ)
      where exists (select 1 from pg_trigger t
                     where t.tgrelid = to_regclass('public.' || e.tbl) and t.tgname = e.tg and not t.tgisinternal
                       and t.tgfoid = to_regprocedure(e.fn) and t.tgtype::int = e.typ and t.tgenabled = 'O')) as trg,
    (select count(*) from pg_trigger t where t.tgrelid = 'public.notifications'::regclass and not t.tgisinternal) as ntrg,
    coalesce((select string_agg(c.relname || '.' || t.tgname, ', ')
                from pg_trigger t join pg_class c on c.oid = t.tgrelid
               where c.relnamespace = 'public'::regnamespace
                 and c.relname in ('queue_tickets', 'enrollments', 'document_requests', 'clearance_items',
                                   'clearances', 'academic_holds', 'grades', 'applications')
                 and not t.tgisinternal and (t.tgtype::int & 2) = 0
                 and (t.tgname::text collate "C") > (('trg_notify_' || c.relname::text) collate "C")), '') as after_ours,
    (select count(*) from pg_proc p
      where p.oid in (to_regprocedure('public.list_my_notifications(integer, boolean)'),
                      to_regprocedure('public.notification_unread_count()'),
                      to_regprocedure('public.mark_notifications_read(bigint[])'))
        and p.prosecdef and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
        and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
        and not has_function_privilege('anon', p.oid, 'EXECUTE')
        and has_function_privilege('authenticated', p.oid, 'EXECUTE')
        and exists (select 1 from pg_roles r join pg_class c on c.oid = 'public.notifications'::regclass
                     where r.oid = p.proowner
                       and (r.rolbypassrls or (c.relowner = r.oid and not c.relforcerowsecurity)))) as pub_ok,
    (select count(*) from pg_proc p
      where p.oid in (to_regprocedure('private.notify(uuid, text, text, text, text)'),
                      to_regprocedure('private.notify_role(text, text, text, text, text)'),
                      to_regprocedure('private.notify_office(bigint, text, text, text, text, text)'),
                      to_regprocedure('private.person_name(uuid)'))
        and not p.prosecdef and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
        and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
        and not has_function_privilege('anon', p.oid, 'EXECUTE')
        and not has_function_privilege('authenticated', p.oid, 'EXECUTE')) as help_ok,
    (select count(*) from pg_proc p
      where p.oid in (to_regprocedure('private.require_notification_rules()'),
                      to_regprocedure('private.notify_on_queue_tickets()'),
                      to_regprocedure('private.notify_on_enrollments()'),
                      to_regprocedure('private.notify_on_document_requests()'),
                      to_regprocedure('private.notify_on_clearance_items()'),
                      to_regprocedure('private.notify_on_clearances()'),
                      to_regprocedure('private.notify_on_academic_holds()'),
                      to_regprocedure('private.notify_on_grades()'),
                      to_regprocedure('private.notify_on_applications()'))
        and p.prosecdef = (p.proname <> 'require_notification_rules')
        and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
        and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
        and not has_function_privilege('anon', p.oid, 'EXECUTE')) as tfn_ok
  ) x), true);

-- ==========================================
-- 3. TC-168: table grants
-- ==========================================
-- Expected: anon_select 'denied', anon_privs '', auth_select true, auth_other_privs '',
-- column_acls 0, seq_privs ''.
set local role anon;
do $$
declare n bigint;
begin
  begin
    select count(*) into n from public.notifications;
    perform set_config('app.c168_anon', 'ALLOWED rows ' || n, true);
  exception when others then
    perform set_config('app.c168_anon', case when sqlerrm like 'permission denied%' then 'denied'
                                             else 'ERR [' || sqlstate || ']: ' || sqlerrm end, true);
  end;
end $$;
reset role;
select set_config('app.r168', (select format('anon_select [%s], anon_privs [%s], auth_select %s, auth_other_privs [%s], column_acls %s, seq_privs [%s] -> %s',
    current_setting('app.c168_anon'), x.anon_privs, x.auth_select, x.auth_other, x.col_acls, x.seq_privs,
    case when current_setting('app.c168_anon') = 'denied' and x.anon_privs = '' and x.auth_select
          and x.auth_other = '' and x.col_acls = 0 and x.seq_privs = ''
         then 'OK' else 'FAIL' end)
  from (select
    coalesce((select string_agg(v.priv, ', ')
                from (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'),
                             ('TRIGGER'), ('MAINTAIN')) as v(priv)
               where has_table_privilege('anon', 'public.notifications', v.priv)
                  or (v.priv in ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
                      and has_any_column_privilege('anon', 'public.notifications', v.priv))), '') as anon_privs,
    has_table_privilege('authenticated', 'public.notifications', 'SELECT') as auth_select,
    coalesce((select string_agg(v.priv, ', ')
                from (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'),
                             ('TRIGGER'), ('MAINTAIN')) as v(priv)
               where has_table_privilege('authenticated', 'public.notifications', v.priv)
                  or (v.priv in ('INSERT', 'UPDATE', 'REFERENCES')
                      and has_any_column_privilege('authenticated', 'public.notifications', v.priv))), '') as auth_other,
    (select count(*) from pg_attribute a
      where a.attrelid = 'public.notifications'::regclass and a.attnum > 0 and not a.attisdropped
        and a.attacl is not null) as col_acls,
    coalesce((select string_agg(w.who, ', ')
                from (values ('anon'), ('authenticated')) as w(who)
               where has_sequence_privilege(w.who, pg_get_serial_sequence('public.notifications', 'notification_id'),
                                            'USAGE, SELECT, UPDATE')), '') as seq_privs
  ) x), true);

-- ==========================================
-- 4. TC-169: EXECUTE grants, anon, published shapes
-- ==========================================
-- Expected: grantees (other than the owner and the bypass-RLS server roles) exactly
-- authenticated for the 3 public functions; nobody for the 4 helpers; anon calling each of
-- the 3: 3 x 'permission denied for function'; the anon-executable functions in public are
-- still exactly check_login_lockout(text), list_programs(), login_email_for_student_id(text),
-- record_login_attempt(text, boolean, inet), submit_application(text, text, text, text,
-- bigint); shapes: list TABLE(...) with the documented 7 columns and arguments
-- 'p_limit integer DEFAULT 30, p_unread_only boolean DEFAULT false'; count integer; mark
-- integer with 'p_ids bigint[] DEFAULT NULL...'.
set local role anon;
do $$
declare
  s     text;
  v_ok  integer := 0;
  v_bad text := '';
begin
  foreach s in array array[
    $q$select * from public.list_my_notifications()$q$,
    $q$select * from public.notification_unread_count()$q$,
    $q$select * from public.mark_notifications_read()$q$]
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
  perform set_config('app.t169_anon_ok', v_ok::text, true);
  perform set_config('app.t169_anon_bad', v_bad, true);
end $$;
reset role;
select set_config('app.t169_grantees', coalesce((select string_agg(f.fn || '=' || f.who, '; ' order by f.fn collate "C") from (
    select p.proname::text as fn,
           coalesce((select string_agg(distinct coalesce(r.rolname::text, 'PUBLIC'), ',')
                       from aclexplode(p.proacl) a left join pg_roles r on r.oid = a.grantee
                      where a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner
                        and not coalesce(r.rolbypassrls, false)), '') as who
    from pg_proc p
    where p.oid in (to_regprocedure('public.list_my_notifications(integer, boolean)'),
                    to_regprocedure('public.notification_unread_count()'),
                    to_regprocedure('public.mark_notifications_read(bigint[])'),
                    to_regprocedure('private.notify(uuid, text, text, text, text)'),
                    to_regprocedure('private.notify_role(text, text, text, text, text)'),
                    to_regprocedure('private.notify_office(bigint, text, text, text, text, text)'),
                    to_regprocedure('private.person_name(uuid)'))) f), ''), true);
select set_config('app.t169_anon_list', coalesce((select string_agg(p.proname || '(' || oidvectortypes(p.proargtypes) || ')', ', ' order by p.proname)
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and has_function_privilege('anon', p.oid, 'EXECUTE')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass
                    and d.objid = p.oid and d.deptype = 'e')), ''), true);
select set_config('app.t169_shapes',
  coalesce(pg_get_function_result(to_regprocedure('public.list_my_notifications(integer, boolean)')), 'none') || ' / '
  || coalesce(pg_get_function_arguments(to_regprocedure('public.list_my_notifications(integer, boolean)')), 'none') || ' / '
  || coalesce(pg_get_function_result(to_regprocedure('public.notification_unread_count()')), 'none') || ' / '
  || coalesce(pg_get_function_result(to_regprocedure('public.mark_notifications_read(bigint[])')), 'none') || ' / '
  || coalesce(pg_get_function_arguments(to_regprocedure('public.mark_notifications_read(bigint[])')), 'none'), true);
select set_config('app.r169', format('grantees [%s], anon_denied %s/3 [%s], anon-executable in public [%s], shapes [%s] -> %s',
  current_setting('app.t169_grantees'), current_setting('app.t169_anon_ok'), current_setting('app.t169_anon_bad'),
  current_setting('app.t169_anon_list'), current_setting('app.t169_shapes'),
  case when current_setting('app.t169_grantees') = 'list_my_notifications=authenticated; mark_notifications_read=authenticated; notification_unread_count=authenticated; notify=; notify_office=; notify_role=; person_name='
        and current_setting('app.t169_anon_ok') = '3' and current_setting('app.t169_anon_bad') = ''
        and current_setting('app.t169_anon_list') = 'check_login_lockout(text), list_programs(), login_email_for_student_id(text), record_login_attempt(text, boolean, inet), submit_application(text, text, text, text, bigint)'
        and current_setting('app.t169_shapes') like 'TABLE(notification_id bigint, kind text, title text, body text, link text, created_at timestamp with time zone, read_at timestamp with time zone) / p_limit integer DEFAULT 30, p_unread_only boolean DEFAULT false / integer / integer / p_ids bigint[] DEFAULT NULL%'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 5. TC-170: table CHECKs and FK (as the owner); live CHECK constraints (informational)
-- ==========================================
-- Expected: kind 'X', kind 'Bad Kind', blank title, 121-character title, 401-character body,
-- an https link, a 201-character link: 'ERR [23514]' (check violation); an unknown recipient:
-- 'ERR [23503]' (foreign key); a valid row for the Admin: 'rows 1'. The live CHECK
-- constraints of the tables involved are printed.
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c170_kind1',  $q$with i as (insert into public.notifications (recipient_id, kind, title) values (current_setting('app.adm')::uuid, 'X', 'TC') returning 1) select 'rows ' || count(*) from i$q$),
    (2, 'c170_kind2',  $q$with i as (insert into public.notifications (recipient_id, kind, title) values (current_setting('app.adm')::uuid, 'Bad Kind', 'TC') returning 1) select 'rows ' || count(*) from i$q$),
    (3, 'c170_blank',  $q$with i as (insert into public.notifications (recipient_id, kind, title) values (current_setting('app.adm')::uuid, 'tc_check', '   ') returning 1) select 'rows ' || count(*) from i$q$),
    (4, 'c170_title',  $q$with i as (insert into public.notifications (recipient_id, kind, title) values (current_setting('app.adm')::uuid, 'tc_check', repeat('t', 121)) returning 1) select 'rows ' || count(*) from i$q$),
    (5, 'c170_body',   $q$with i as (insert into public.notifications (recipient_id, kind, title, body) values (current_setting('app.adm')::uuid, 'tc_check', 'TC', repeat('b', 401)) returning 1) select 'rows ' || count(*) from i$q$),
    (6, 'c170_link1',  $q$with i as (insert into public.notifications (recipient_id, kind, title, link) values (current_setting('app.adm')::uuid, 'tc_check', 'TC', 'https://example.test/x') returning 1) select 'rows ' || count(*) from i$q$),
    (7, 'c170_link2',  $q$with i as (insert into public.notifications (recipient_id, kind, title, link) values (current_setting('app.adm')::uuid, 'tc_check', 'TC', '/' || repeat('a', 200)) returning 1) select 'rows ' || count(*) from i$q$),
    (8, 'c170_fk',     $q$with i as (insert into public.notifications (recipient_id, kind, title) values (gen_random_uuid(), 'tc_check', 'TC') returning 1) select 'rows ' || count(*) from i$q$),
    (9, 'c170_valid',  $q$with i as (insert into public.notifications (recipient_id, kind, title, body, link) values (current_setting('app.adm')::uuid, 'tc_check', 'Valid', '', '/admin') returning 1) select 'rows ' || count(*) from i$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']', true);
    end;
  end loop;
end $$;
select set_config('app.r170', format('kind_X %s, kind_spaces %s, blank_title %s, title_121 %s, body_401 %s, https_link %s, link_201 %s, unknown_recipient %s, valid [%s], live_checks [%s] -> %s',
  current_setting('app.c170_kind1'), current_setting('app.c170_kind2'), current_setting('app.c170_blank'),
  current_setting('app.c170_title'), current_setting('app.c170_body'), current_setting('app.c170_link1'),
  current_setting('app.c170_link2'), current_setting('app.c170_fk'), current_setting('app.c170_valid'),
  coalesce((select string_agg(c.conrelid::regclass::text || '.' || c.conname || ' ' || pg_get_constraintdef(c.oid), '; '
                              order by c.conrelid::regclass::text, c.conname)
              from pg_constraint c
             where c.contype = 'c'
               and c.conrelid in ('public.profiles'::regclass, 'public.enrollments'::regclass,
                                  'public.document_requests'::regclass, 'public.clearances'::regclass,
                                  'public.clearance_items'::regclass, 'public.academic_holds'::regclass,
                                  'public.grades'::regclass, 'public.applications'::regclass,
                                  'public.queue_tickets'::regclass, 'public.notifications'::regclass)), ''),
  case when current_setting('app.c170_kind1') = 'ERR [23514]' and current_setting('app.c170_kind2') = 'ERR [23514]'
        and current_setting('app.c170_blank') = 'ERR [23514]' and current_setting('app.c170_title') = 'ERR [23514]'
        and current_setting('app.c170_body') = 'ERR [23514]' and current_setting('app.c170_link1') = 'ERR [23514]'
        and current_setting('app.c170_link2') = 'ERR [23514]' and current_setting('app.c170_fk') = 'ERR [23503]'
        and current_setting('app.c170_valid') = 'rows 1'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 6. TC-171: queue tickets issued (queue_ticket)
-- ==========================================
-- Expected: the Registrar issues TCN-A tickets to Student 1 ('<L1>|0') and Student 2
-- ('<L2>|1') (issue_queue_ticket works as before); N(s1) = 'queue_ticket|You are in line|Your
-- ticket is <L1>. No one is ahead of you.|NULL'; N(s2) = 'queue_ticket|You are in line|Your
-- ticket is <L2>. 1 person is ahead of you.|NULL' (a throwaway service has no link,
-- decision 6); 2 rows in all.
select set_config('app.m171', pg_temp.mark()::text, true);
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c171_s1', 'reg', $q$select i.ticket_label || '|' || i.people_ahead from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCN-A') i$q$),
    (2, 'c171_s2', 'reg', $q$select i.ticket_label || '|' || i.people_ahead from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCN-A') i$q$)
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
select set_config('app.svn', (select service_id::text from public.queue_services where service_code = 'TCN-A'), true);
select set_config('app.qt1', coalesce((select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.svn')::bigint and ticket_number = 1), '0'), true);
select set_config('app.qt2', coalesce((select ticket_id::text from public.queue_tickets
  where service_id = current_setting('app.svn')::bigint and ticket_number = 2), '0'), true);
select set_config('app.ql1', coalesce((select '#' || ticket_code from public.queue_tickets where ticket_id = current_setting('app.qt1')::bigint), 'none'), true);
select set_config('app.ql2', coalesce((select '#' || ticket_code from public.queue_tickets where ticket_id = current_setting('app.qt2')::bigint), 'none'), true);
select set_config('app.r171', format('issued [%s, %s], N(s1) [%s], N(s2) [%s], rows %s -> %s',
  current_setting('app.c171_s1'), current_setting('app.c171_s2'),
  pg_temp.notes(current_setting('app.m171')::bigint, 's1'), pg_temp.notes(current_setting('app.m171')::bigint, 's2'),
  pg_temp.nall(current_setting('app.m171')::bigint),
  case when current_setting('app.c171_s1') = current_setting('app.ql1') || '|0'
        and current_setting('app.c171_s2') = current_setting('app.ql2') || '|1'
        and current_setting('app.ql1') ~ '^#[1-9][0-9]{6}$'
        and pg_temp.notes(current_setting('app.m171')::bigint, 's1')
            = 'queue_ticket|You are in line|Your ticket is ' || current_setting('app.ql1') || '. No one is ahead of you.|NULL'
        and pg_temp.notes(current_setting('app.m171')::bigint, 's2')
            = 'queue_ticket|You are in line|Your ticket is ' || current_setting('app.ql2') || '. 1 person is ahead of you.|NULL'
        and pg_temp.nall(current_setting('app.m171')::bigint) = 2
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 7. TC-172: call and finish (queue_turn, queue_skipped)
-- ==========================================
-- Expected: call next ('  Window 3  ') returns '<L1>|Window 3'; finish Done 'done'; call next
-- (no window) '<L2>|NULL'; finish No-show 'done' (the queue functions work with the new
-- trigger). N(s1) = 'queue_turn|It is your turn|Go to Window 3 now. Bring your valid ID.|NULL'
-- (Done adds nothing); N(s2) = 'queue_turn|It is your turn|Go to the Registrar window now.
-- Bring your valid ID.|NULL ; queue_skipped|You were skipped|Your number was called and you
-- were not at the window. Show your code again to get a new number.|NULL'; 3 rows in all.
select set_config('app.m172', pg_temp.mark()::text, true);
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c172_call1',  'reg', $q$select c.ticket_label || '|' || coalesce(c.window_label, 'NULL') from public.queue_call_next('TCN-A', '  Window 3  ') c$q$),
    (2, 'c172_done',   'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.qt1')::bigint, 'Done')$q$),
    (3, 'c172_call2',  'reg', $q$select c.ticket_label || '|' || coalesce(c.window_label, 'NULL') from public.queue_call_next('TCN-A') c$q$),
    (4, 'c172_noshow', 'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.qt2')::bigint, 'No-show')$q$)
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
select set_config('app.r172', format('call1 [%s], done [%s], call2 [%s], noshow [%s], N(s1) [%s], N(s2) [%s], rows %s -> %s',
  current_setting('app.c172_call1'), current_setting('app.c172_done'), current_setting('app.c172_call2'),
  current_setting('app.c172_noshow'),
  pg_temp.notes(current_setting('app.m172')::bigint, 's1'), pg_temp.notes(current_setting('app.m172')::bigint, 's2'),
  pg_temp.nall(current_setting('app.m172')::bigint),
  case when current_setting('app.c172_call1') = current_setting('app.ql1') || '|Window 3'
        and current_setting('app.c172_done') = 'done'
        and current_setting('app.c172_call2') = current_setting('app.ql2') || '|NULL'
        and current_setting('app.c172_noshow') = 'done'
        and pg_temp.notes(current_setting('app.m172')::bigint, 's1')
            = 'queue_turn|It is your turn|Go to Window 3 now. Bring your valid ID.|NULL'
        and pg_temp.notes(current_setting('app.m172')::bigint, 's2')
            = 'queue_turn|It is your turn|Go to the Registrar window now. Bring your valid ID.|NULL ; '
              || 'queue_skipped|You were skipped|Your number was called and you were not at the window. Show your code again to get a new number.|NULL'
        and pg_temp.nall(current_setting('app.m172')::bigint) = 3
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 8. TC-173: links of the real services
-- ==========================================
-- Setup as postgres: for each real service, the first seed student without an active ticket
-- there today gets a Waiting ticket with a number 1000 above today's highest and a free code
-- (rolled back). Expected: that student's row 'queue_ticket|You are in line|Your ticket is
-- <label>. <people ahead>|/student/enrollment' (Enrollment) and '...|/student/documents'
-- (Documents), where people ahead = the Waiting tickets of that service today, read from the
-- table just before the insert; one row per insert.
select set_config('app.qe_who', coalesce((select v.tag from (values (1, 's1'), (2, 's2'), (3, 's3')) as v(o, tag)
  where not exists (select 1 from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
                     where s.service_code = 'Enrollment' and t.student_id::text = current_setting('app.' || v.tag)
                       and t.queue_date = current_setting('app.today')::date and t.status in ('Waiting', 'Serving'))
  order by v.o limit 1), ''), true);
select set_config('app.qd_who', coalesce((select v.tag from (values (1, 's1'), (2, 's2'), (3, 's3')) as v(o, tag)
  where not exists (select 1 from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
                     where s.service_code = 'Documents' and t.student_id::text = current_setting('app.' || v.tag)
                       and t.queue_date = current_setting('app.today')::date and t.status in ('Waiting', 'Serving'))
  order by v.o limit 1), ''), true);
select set_config('app.qe_label', 'none', true);
select set_config('app.qd_label', 'none', true);
select set_config('app.qe_ahead', (select count(*)::text from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
  where s.service_code = 'Enrollment' and t.queue_date = current_setting('app.today')::date and t.status = 'Waiting'), true);
select set_config('app.m173e', pg_temp.mark()::text, true);
with t as (
  insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
  select s.service_id, current_setting('app.' || current_setting('app.qe_who'))::uuid, current_setting('app.today')::date,
         (select coalesce(max(q.ticket_number), 0) + 1000 from public.queue_tickets q
           where q.service_id = s.service_id and q.queue_date = current_setting('app.today')::date),
         (select min(g)::integer from generate_series(1000000, 1001000) g
           where not exists (select 1 from public.queue_tickets q where q.service_id = s.service_id
                               and q.queue_date = current_setting('app.today')::date and q.ticket_code = g))
  from public.queue_services s
  where s.service_code = 'Enrollment' and current_setting('app.qe_who') <> ''
  returning ticket_code)
select set_config('app.qe_label', '#' || ticket_code, true) from t;
select set_config('app.qe_notes', case when current_setting('app.qe_who') = '' then 'no free seed student'
  else pg_temp.notes(current_setting('app.m173e')::bigint, current_setting('app.qe_who')) end, true);
select set_config('app.qe_rows', pg_temp.nall(current_setting('app.m173e')::bigint)::text, true);
select set_config('app.qd_ahead', (select count(*)::text from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
  where s.service_code = 'Documents' and t.queue_date = current_setting('app.today')::date and t.status = 'Waiting'), true);
select set_config('app.m173d', pg_temp.mark()::text, true);
with t as (
  insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code)
  select s.service_id, current_setting('app.' || current_setting('app.qd_who'))::uuid, current_setting('app.today')::date,
         (select coalesce(max(q.ticket_number), 0) + 1000 from public.queue_tickets q
           where q.service_id = s.service_id and q.queue_date = current_setting('app.today')::date),
         (select min(g)::integer from generate_series(1000000, 1001000) g
           where not exists (select 1 from public.queue_tickets q where q.service_id = s.service_id
                               and q.queue_date = current_setting('app.today')::date and q.ticket_code = g))
  from public.queue_services s
  where s.service_code = 'Documents' and current_setting('app.qd_who') <> ''
  returning ticket_code)
select set_config('app.qd_label', '#' || ticket_code, true) from t;
select set_config('app.qd_notes', case when current_setting('app.qd_who') = '' then 'no free seed student'
  else pg_temp.notes(current_setting('app.m173d')::bigint, current_setting('app.qd_who')) end, true);
select set_config('app.qd_rows', pg_temp.nall(current_setting('app.m173d')::bigint)::text, true);
select set_config('app.r173', format('enrollment (%s) [%s] rows %s, documents (%s) [%s] rows %s -> %s',
  current_setting('app.qe_who'), current_setting('app.qe_notes'), current_setting('app.qe_rows'),
  current_setting('app.qd_who'), current_setting('app.qd_notes'), current_setting('app.qd_rows'),
  case when current_setting('app.qe_notes') = 'queue_ticket|You are in line|Your ticket is ' || current_setting('app.qe_label')
                                              || '. ' || pg_temp.ahead_text(current_setting('app.qe_ahead')::bigint) || '|/student/enrollment'
        and current_setting('app.qd_notes') = 'queue_ticket|You are in line|Your ticket is ' || current_setting('app.qd_label')
                                              || '. ' || pg_temp.ahead_text(current_setting('app.qd_ahead')::bigint) || '|/student/documents'
        and current_setting('app.qe_rows') = '1' and current_setting('app.qd_rows') = '1'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 9. TC-174: a new enrollment (Registrars)
-- ==========================================
-- Expected: Student 2's Pending enrollment in the throwaway term gives every active
-- Registrar exactly one 'New enrollment to review|<s2name> submitted an enrollment.|
-- /registrar/enrollments', nobody else (rows = active Registrars), N(s2) = ''.
select set_config('app.m174', pg_temp.mark()::text, true);
with e as (insert into public.enrollments (student_id, term_id, year_level)
           values (current_setting('app.s2')::uuid, current_setting('app.term')::bigint, 1) returning enrollment_id)
select set_config('app.enr2', enrollment_id::text, true) from e;
select set_config('app.r174', format('registrars_ok %s, rows %s (active Registrars %s), N(s2) [%s] -> %s',
  pg_temp.role_ok(current_setting('app.m174')::bigint, 'enrollment_submitted', 'Registrar',
                  'New enrollment to review|' || current_setting('app.s2name') || ' submitted an enrollment.|/registrar/enrollments'),
  pg_temp.nall(current_setting('app.m174')::bigint), pg_temp.role_count('Registrar'),
  pg_temp.notes(current_setting('app.m174')::bigint, 's2'),
  case when pg_temp.role_ok(current_setting('app.m174')::bigint, 'enrollment_submitted', 'Registrar',
                            'New enrollment to review|' || current_setting('app.s2name') || ' submitted an enrollment.|/registrar/enrollments')
        and pg_temp.nall(current_setting('app.m174')::bigint) = pg_temp.role_count('Registrar')
        and pg_temp.notes(current_setting('app.m174')::bigint, 's2') = ''
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 10. TC-175: enrollment decisions
-- ==========================================
-- Setup: Student 1's Pending enrollment in the throwaway term with the throwaway section.
-- Expected (as postgres, reviewer given): approve Student 1 'rows 1'; Student 2's year_level
-- changed (Pending -> Pending) 'rows 1'; reject Student 2 with remarks 'Missing
-- requirements' 'rows 1'. N(s1) = 'enrollment_decided|Your enrollment was approved|Open the
-- enrollment page to see your subjects.|/student/enrollment'; N(s2) = 'enrollment_decided|
-- Your enrollment was rejected|Missing requirements|/student/enrollment'; 2 rows in all.
with e as (insert into public.enrollments (student_id, term_id, year_level)
           values (current_setting('app.s1')::uuid, current_setting('app.term')::bigint, 1) returning enrollment_id)
select set_config('app.enr1', enrollment_id::text, true) from e;
with i as (insert into public.enrollment_items (enrollment_id, section_id)
           values (current_setting('app.enr1')::bigint, current_setting('app.sec')::bigint) returning enrollment_item_id)
select set_config('app.item1', enrollment_item_id::text, true) from i;
select set_config('app.m175', pg_temp.mark()::text, true);
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c175_approve', $q$with u as (update public.enrollments set status = 'Approved', reviewed_by = current_setting('app.reg')::uuid, reviewed_at = now()
                                       where enrollment_id = current_setting('app.enr1')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (2, 'c175_same',    $q$with u as (update public.enrollments set year_level = 2
                                       where enrollment_id = current_setting('app.enr2')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (3, 'c175_reject',  $q$with u as (update public.enrollments set status = 'Rejected', remarks = 'Missing requirements',
                                              reviewed_by = current_setting('app.reg')::uuid, reviewed_at = now()
                                       where enrollment_id = current_setting('app.enr2')::bigint returning 1) select 'rows ' || count(*) from u$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.r175', format('approve [%s], pending_edit [%s], reject [%s], N(s1) [%s], N(s2) [%s], rows %s -> %s',
  current_setting('app.c175_approve'), current_setting('app.c175_same'), current_setting('app.c175_reject'),
  pg_temp.notes(current_setting('app.m175')::bigint, 's1'), pg_temp.notes(current_setting('app.m175')::bigint, 's2'),
  pg_temp.nall(current_setting('app.m175')::bigint),
  case when current_setting('app.c175_approve') = 'rows 1' and current_setting('app.c175_same') = 'rows 1'
        and current_setting('app.c175_reject') = 'rows 1'
        and pg_temp.notes(current_setting('app.m175')::bigint, 's1')
            = 'enrollment_decided|Your enrollment was approved|Open the enrollment page to see your subjects.|/student/enrollment'
        and pg_temp.notes(current_setting('app.m175')::bigint, 's2')
            = 'enrollment_decided|Your enrollment was rejected|Missing requirements|/student/enrollment'
        and pg_temp.nall(current_setting('app.m175')::bigint) = 2
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 11. TC-176: a new document request (Registrars)
-- ==========================================
-- Expected: Student 1's Pending request gives every active Registrar exactly one 'New
-- document request|<s1name> requested <document type name>.|/registrar/documents', nobody
-- else; N(s1) = ''.
select set_config('app.m176', pg_temp.mark()::text, true);
with r as (insert into public.document_requests (student_id, document_type_id, purpose)
           values (current_setting('app.s1')::uuid, current_setting('app.dt')::bigint, 'TC notify flow') returning request_id, ticket_number)
select set_config('app.dq1', request_id::text, true), set_config('app.dq1_t', ticket_number::text, true) from r;
select set_config('app.r176', format('registrars_ok %s, rows %s (active Registrars %s), N(s1) [%s] -> %s',
  pg_temp.role_ok(current_setting('app.m176')::bigint, 'document_requested', 'Registrar',
                  'New document request|' || current_setting('app.s1name') || ' requested ' || current_setting('app.dt_name') || '.|/registrar/documents'),
  pg_temp.nall(current_setting('app.m176')::bigint), pg_temp.role_count('Registrar'),
  pg_temp.notes(current_setting('app.m176')::bigint, 's1'),
  case when pg_temp.role_ok(current_setting('app.m176')::bigint, 'document_requested', 'Registrar',
                            'New document request|' || current_setting('app.s1name') || ' requested ' || current_setting('app.dt_name') || '.|/registrar/documents')
        and pg_temp.nall(current_setting('app.m176')::bigint) = pg_temp.role_count('Registrar')
        and pg_temp.notes(current_setting('app.m176')::bigint, 's1') = ''
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 12. TC-177: document status changes
-- ==========================================
-- Setup: a second Pending request of Student 1 (its Registrar rows are before the mark).
-- Expected (as postgres): request 1 Processing (processed_by given), Ready, a remarks-only
-- edit while Ready, Released, and request 2 Rejected with remarks 'Wrong purpose': each
-- 'rows 1'. N(s1) = four rows in this order:
-- 'document_status|Document request <t1>: Processing|The Registrar started working on it.|/student/documents'
-- 'document_status|Document request <t1>: Ready|It is ready. Claim it at the Registrar.|/student/documents'
-- 'document_status|Document request <t1>: Released|It was released to you.|/student/documents'
-- 'document_status|Document request <t2>: Rejected|Wrong purpose|/student/documents'
-- (the remarks-only edit adds nothing); 4 rows in all.
with r as (insert into public.document_requests (student_id, document_type_id, purpose)
           values (current_setting('app.s1')::uuid, current_setting('app.dt')::bigint, 'TC notify reject') returning request_id, ticket_number)
select set_config('app.dq2', request_id::text, true), set_config('app.dq2_t', ticket_number::text, true) from r;
select set_config('app.m177', pg_temp.mark()::text, true);
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c177_proc',    $q$with u as (update public.document_requests set status = 'Processing', processed_by = current_setting('app.reg')::uuid
                                       where request_id = current_setting('app.dq1')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (2, 'c177_ready',   $q$with u as (update public.document_requests set status = 'Ready'
                                       where request_id = current_setting('app.dq1')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (3, 'c177_remarks', $q$with u as (update public.document_requests set remarks = 'Bring two IDs'
                                       where request_id = current_setting('app.dq1')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (4, 'c177_rel',     $q$with u as (update public.document_requests set status = 'Released'
                                       where request_id = current_setting('app.dq1')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (5, 'c177_rej',     $q$with u as (update public.document_requests set status = 'Rejected', remarks = 'Wrong purpose',
                                              processed_by = current_setting('app.reg')::uuid
                                       where request_id = current_setting('app.dq2')::bigint returning 1) select 'rows ' || count(*) from u$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.r177', format('steps [%s, %s, %s, %s, %s], N(s1) [%s], rows %s -> %s',
  current_setting('app.c177_proc'), current_setting('app.c177_ready'), current_setting('app.c177_remarks'),
  current_setting('app.c177_rel'), current_setting('app.c177_rej'),
  pg_temp.notes(current_setting('app.m177')::bigint, 's1'), pg_temp.nall(current_setting('app.m177')::bigint),
  case when current_setting('app.c177_proc') = 'rows 1' and current_setting('app.c177_ready') = 'rows 1'
        and current_setting('app.c177_remarks') = 'rows 1' and current_setting('app.c177_rel') = 'rows 1'
        and current_setting('app.c177_rej') = 'rows 1'
        and pg_temp.notes(current_setting('app.m177')::bigint, 's1')
            = 'document_status|Document request ' || current_setting('app.dq1_t') || ': Processing|The Registrar started working on it.|/student/documents ; '
              || 'document_status|Document request ' || current_setting('app.dq1_t') || ': Ready|It is ready. Claim it at the Registrar.|/student/documents ; '
              || 'document_status|Document request ' || current_setting('app.dq1_t') || ': Released|It was released to you.|/student/documents ; '
              || 'document_status|Document request ' || current_setting('app.dq2_t') || ': Rejected|Wrong purpose|/student/documents'
        and pg_temp.nall(current_setting('app.m177')::bigint) = 4
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 13. TC-178: a new clearance (offices)
-- ==========================================
-- Setup: Student 1 requests a clearance for the throwaway term (the live trigger creates one
-- item per department; any missing item is added, as the other tests do). Student 1 has no
-- charge in that term, so the Financial item stays pending.
-- Expected: N(dept) = exactly 'clearance_waiting|Clearance item waiting|<s1name> is waiting
-- for your office.|/department/clearance' (its own department only, although every
-- department got an item); N(cash) = exactly the same with '/cashier/clearance' (the
-- Financial item only); N(s1) = '' and N(reg) = ''; all clearance_waiting rows = the active
-- department heads of every item's department + the active Cashiers (one Financial item).
select set_config('app.m178', pg_temp.mark()::text, true);
with c as (insert into public.clearances (student_id, term_id)
           values (current_setting('app.s1')::uuid, current_setting('app.term')::bigint) returning clearance_id)
select set_config('app.clr', clearance_id::text, true) from c;
insert into public.clearance_items (clearance_id, department_id)
select current_setting('app.clr')::bigint, d.department_id
from public.departments d
where not exists (select 1 from public.clearance_items i
                  where i.clearance_id = current_setting('app.clr')::bigint and i.department_id = d.department_id);
select set_config('app.t178_expected', ((select coalesce(sum(pg_temp.heads(i.department_id)), 0) from public.clearance_items i
                                          where i.clearance_id = current_setting('app.clr')::bigint)
  + case when exists (select 1 from public.clearance_items i where i.clearance_id = current_setting('app.clr')::bigint
                        and i.department_id = current_setting('app.fin')::bigint)
         then pg_temp.role_count('Cashier') else 0 end)::text, true);
select set_config('app.r178', format('items %s, N(dept) [%s], N(cash) [%s], N(s1) [%s], N(reg) [%s], waiting_rows %s (expected %s) -> %s',
  (select count(*) from public.clearance_items i where i.clearance_id = current_setting('app.clr')::bigint),
  pg_temp.notes(current_setting('app.m178')::bigint, 'dept'), pg_temp.notes(current_setting('app.m178')::bigint, 'cash'),
  pg_temp.notes(current_setting('app.m178')::bigint, 's1'), pg_temp.notes(current_setting('app.m178')::bigint, 'reg'),
  pg_temp.nkind(current_setting('app.m178')::bigint, 'clearance_waiting'), current_setting('app.t178_expected'),
  case when pg_temp.notes(current_setting('app.m178')::bigint, 'dept')
            = 'clearance_waiting|Clearance item waiting|' || current_setting('app.s1name') || ' is waiting for your office.|/department/clearance'
        and pg_temp.notes(current_setting('app.m178')::bigint, 'cash')
            = 'clearance_waiting|Clearance item waiting|' || current_setting('app.s1name') || ' is waiting for your office.|/cashier/clearance'
        and pg_temp.notes(current_setting('app.m178')::bigint, 's1') = ''
        and pg_temp.notes(current_setting('app.m178')::bigint, 'reg') = ''
        and pg_temp.nkind(current_setting('app.m178')::bigint, 'clearance_waiting') = current_setting('app.t178_expected')::bigint
        and pg_temp.nall(current_setting('app.m178')::bigint) = current_setting('app.t178_expected')::bigint
        and (select count(*) from public.clearance_items i where i.clearance_id = current_setting('app.clr')::bigint) > 1
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 14. TC-179: a note on a pending item
-- ==========================================
-- Expected (as postgres): remarks 'Bring your library card' on the item of dept@'s department
-- 'rows 1'; the same remarks again 'rows 1'; remarks NULL 'rows 1'. N(s1) = exactly
-- 'clearance_note|<department name> left a note|Bring your library card|/student/clearance';
-- 1 row in all.
select set_config('app.m179', pg_temp.mark()::text, true);
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c179_note',  $q$with u as (update public.clearance_items set remarks = 'Bring your library card'
                                     where clearance_id = current_setting('app.clr')::bigint and department_id = current_setting('app.ddep')::bigint
                                     returning 1) select 'rows ' || count(*) from u$q$),
    (2, 'c179_same',  $q$with u as (update public.clearance_items set remarks = 'Bring your library card'
                                     where clearance_id = current_setting('app.clr')::bigint and department_id = current_setting('app.ddep')::bigint
                                     returning 1) select 'rows ' || count(*) from u$q$),
    (3, 'c179_clear', $q$with u as (update public.clearance_items set remarks = null
                                     where clearance_id = current_setting('app.clr')::bigint and department_id = current_setting('app.ddep')::bigint
                                     returning 1) select 'rows ' || count(*) from u$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.r179', format('note [%s], same [%s], cleared_remarks [%s], N(s1) [%s], rows %s -> %s',
  current_setting('app.c179_note'), current_setting('app.c179_same'), current_setting('app.c179_clear'),
  pg_temp.notes(current_setting('app.m179')::bigint, 's1'), pg_temp.nall(current_setting('app.m179')::bigint),
  case when current_setting('app.c179_note') = 'rows 1' and current_setting('app.c179_same') = 'rows 1'
        and current_setting('app.c179_clear') = 'rows 1'
        and pg_temp.notes(current_setting('app.m179')::bigint, 's1')
            = 'clearance_note|' || current_setting('app.ddep_name') || ' left a note|Bring your library card|/student/clearance'
        and pg_temp.nall(current_setting('app.m179')::bigint) = 1
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 15. TC-180: one item cleared
-- ==========================================
-- Expected (as postgres): clearing dept@'s department item 'rows 1'. N(s1) = exactly
-- 'clearance_cleared|<department name> cleared you||/student/clearance' (no remarks now);
-- N(reg) = '' (other items still pending); 1 row in all.
select set_config('app.m180', pg_temp.mark()::text, true);
do $$
declare v text;
begin
  with u as (update public.clearance_items set cleared_at = now(), cleared_by = current_setting('app.dept')::uuid
             where clearance_id = current_setting('app.clr')::bigint and department_id = current_setting('app.ddep')::bigint
             returning 1)
  select 'rows ' || count(*) into v from u;
  perform set_config('app.c180', v, true);
exception when others then
  perform set_config('app.c180', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
select set_config('app.r180', format('clear [%s], N(s1) [%s], N(reg) [%s], rows %s -> %s',
  current_setting('app.c180'), pg_temp.notes(current_setting('app.m180')::bigint, 's1'),
  pg_temp.notes(current_setting('app.m180')::bigint, 'reg'), pg_temp.nall(current_setting('app.m180')::bigint),
  case when current_setting('app.c180') = 'rows 1'
        and pg_temp.notes(current_setting('app.m180')::bigint, 's1')
            = 'clearance_cleared|' || current_setting('app.ddep_name') || ' cleared you||/student/clearance'
        and pg_temp.notes(current_setting('app.m180')::bigint, 'reg') = ''
        and pg_temp.nall(current_setting('app.m180')::bigint) = 1
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 16. TC-181: the remaining items cleared in ONE statement
-- ==========================================
-- Expected (as postgres): 'rows K' with K = items - 1; Student 1 gets K clearance_cleared
-- rows (one per office, each '<office name> cleared you'); every active Registrar gets
-- exactly ONE 'A clearance is ready for final approval|<s1name>|/registrar/clearance'
-- (decision 7: not one per item); rows in all = K + active Registrars.
select set_config('app.t181_k', (select count(*)::text from public.clearance_items
  where clearance_id = current_setting('app.clr')::bigint and cleared_at is null), true);
select set_config('app.m181', pg_temp.mark()::text, true);
do $$
declare v text;
begin
  with u as (update public.clearance_items set cleared_at = now(), cleared_by = current_setting('app.dept')::uuid
             where clearance_id = current_setting('app.clr')::bigint and cleared_at is null
             returning 1)
  select 'rows ' || count(*) into v from u;
  perform set_config('app.c181', v, true);
exception when others then
  perform set_config('app.c181', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
select set_config('app.t181_cleared_ok', (
  (select count(*) from public.notifications n
    where n.notification_id > current_setting('app.m181')::bigint and n.created_at = now()
      and n.kind = 'clearance_cleared' and n.recipient_id::text = current_setting('app.s1')
      and n.link = '/student/clearance'
      and n.title in (select d.name::text || ' cleared you' from public.clearance_items i
                       join public.departments d on d.department_id = i.department_id
                      where i.clearance_id = current_setting('app.clr')::bigint
                        and i.department_id <> current_setting('app.ddep')::bigint))
  = current_setting('app.t181_k')::bigint)::text, true);
select set_config('app.r181', format('clear [%s] (pending before %s), cleared_rows %s (titles ok %s), ready_ok %s, ready_rows %s (active Registrars %s), rows %s -> %s',
  current_setting('app.c181'), current_setting('app.t181_k'),
  pg_temp.nkind(current_setting('app.m181')::bigint, 'clearance_cleared'), current_setting('app.t181_cleared_ok'),
  pg_temp.role_ok(current_setting('app.m181')::bigint, 'clearance_ready', 'Registrar',
                  'A clearance is ready for final approval|' || current_setting('app.s1name') || '|/registrar/clearance'),
  pg_temp.nkind(current_setting('app.m181')::bigint, 'clearance_ready'), pg_temp.role_count('Registrar'),
  pg_temp.nall(current_setting('app.m181')::bigint),
  case when current_setting('app.c181') = 'rows ' || current_setting('app.t181_k')
        and current_setting('app.t181_k')::bigint >= 1
        and pg_temp.nkind(current_setting('app.m181')::bigint, 'clearance_cleared') = current_setting('app.t181_k')::bigint
        and current_setting('app.t181_cleared_ok') = 'true'
        and pg_temp.role_ok(current_setting('app.m181')::bigint, 'clearance_ready', 'Registrar',
                            'A clearance is ready for final approval|' || current_setting('app.s1name') || '|/registrar/clearance')
        and pg_temp.nall(current_setting('app.m181')::bigint) = current_setting('app.t181_k')::bigint + pg_temp.role_count('Registrar')
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 17. TC-182: clearance approved
-- ==========================================
-- Expected (as postgres): approve 'rows 1'; an update that changes nothing 'rows 1'.
-- N(s1) = exactly 'clearance_approved|Your clearance is approved|Every office cleared you and
-- the Registrar gave the final approval.|/student/clearance'; 1 row in all.
select set_config('app.m182', pg_temp.mark()::text, true);
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c182_approve', $q$with u as (update public.clearances set approved_at = now(), approved_by = current_setting('app.reg')::uuid
                                       where clearance_id = current_setting('app.clr')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (2, 'c182_again',   $q$with u as (update public.clearances set approved_by = current_setting('app.reg')::uuid
                                       where clearance_id = current_setting('app.clr')::bigint returning 1) select 'rows ' || count(*) from u$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.r182', format('approve [%s], again [%s], N(s1) [%s], rows %s -> %s',
  current_setting('app.c182_approve'), current_setting('app.c182_again'),
  pg_temp.notes(current_setting('app.m182')::bigint, 's1'), pg_temp.nall(current_setting('app.m182')::bigint),
  case when current_setting('app.c182_approve') = 'rows 1' and current_setting('app.c182_again') = 'rows 1'
        and pg_temp.notes(current_setting('app.m182')::bigint, 's1')
            = 'clearance_approved|Your clearance is approved|Every office cleared you and the Registrar gave the final approval.|/student/clearance'
        and pg_temp.nall(current_setting('app.m182')::bigint) = 1
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 18. TC-183: holds
-- ==========================================
-- Expected (as postgres): a hold of dept@'s department on Student 1 ('Unpaid library fine')
-- is placed ('inserted'), lifted ('rows 1'), then its lifter is changed (no new row, whatever
-- the result). N(s1) = 'hold_placed|A hold was placed on your account|<department name>:
-- Unpaid library fine|/student/clearance ; hold_lifted|A hold was lifted|<department name>:
-- Unpaid library fine|/student/clearance'; 2 rows in all.
select set_config('app.m183', pg_temp.mark()::text, true);
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c183_place', $q$with h as (insert into public.academic_holds (student_id, department_id, reason, placed_by)
                                     values (current_setting('app.s1')::uuid, current_setting('app.ddep')::bigint, 'Unpaid library fine', current_setting('app.dept')::uuid)
                                     returning hold_id) select 'inserted ' || hold_id from h$q$),
    (2, 'c183_lift',  $q$with u as (update public.academic_holds set lifted_at = now(), lifted_by = current_setting('app.dept')::uuid
                                     where student_id = current_setting('app.s1')::uuid and reason = 'Unpaid library fine' and lifted_at is null
                                     returning 1) select 'rows ' || count(*) from u$q$),
    (3, 'c183_again', $q$with u as (update public.academic_holds set lifted_by = current_setting('app.reg')::uuid
                                     where student_id = current_setting('app.s1')::uuid and reason = 'Unpaid library fine'
                                     returning 1) select 'rows ' || count(*) from u$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.r183', format('place [%s], lift [%s], second_update [%s], N(s1) [%s], rows %s -> %s',
  current_setting('app.c183_place'), current_setting('app.c183_lift'), current_setting('app.c183_again'),
  pg_temp.notes(current_setting('app.m183')::bigint, 's1'), pg_temp.nall(current_setting('app.m183')::bigint),
  case when current_setting('app.c183_place') like 'inserted %' and current_setting('app.c183_lift') = 'rows 1'
        and pg_temp.notes(current_setting('app.m183')::bigint, 's1')
            = 'hold_placed|A hold was placed on your account|' || current_setting('app.ddep_name') || ': Unpaid library fine|/student/clearance ; '
              || 'hold_lifted|A hold was lifted|' || current_setting('app.ddep_name') || ': Unpaid library fine|/student/clearance'
        and pg_temp.nall(current_setting('app.m183')::bigint) = 2
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 19. TC-184: grades
-- ==========================================
-- Expected (as postgres): a grade 1.75 on Student 1's approved item 'inserted', changed to
-- 2.00 'rows 1', an update that keeps grade_code 'rows 1'. N(s1) = 'grade_posted|A new grade
-- was posted|<subject code>: 1.75|/student/grades ; grade_changed|A grade was updated|
-- <subject code>: 2.00|/student/grades'; 2 rows in all.
select set_config('app.m184', pg_temp.mark()::text, true);
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c184_post',   $q$with g as (insert into public.grades (enrollment_item_id, grade_code, encoded_by)
                                      values (current_setting('app.item1')::bigint, '1.75', current_setting('app.reg')::uuid)
                                      returning grade_id) select 'inserted ' || grade_id from g$q$),
    (2, 'c184_change', $q$with u as (update public.grades set grade_code = '2.00', encoded_by = current_setting('app.reg')::uuid
                                      where enrollment_item_id = current_setting('app.item1')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (3, 'c184_same',   $q$with u as (update public.grades set encoded_by = current_setting('app.reg')::uuid
                                      where enrollment_item_id = current_setting('app.item1')::bigint returning 1) select 'rows ' || count(*) from u$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.r184', format('post [%s], change [%s], same [%s], N(s1) [%s], rows %s -> %s',
  current_setting('app.c184_post'), current_setting('app.c184_change'), current_setting('app.c184_same'),
  pg_temp.notes(current_setting('app.m184')::bigint, 's1'), pg_temp.nall(current_setting('app.m184')::bigint),
  case when current_setting('app.c184_post') like 'inserted %' and current_setting('app.c184_change') = 'rows 1'
        and current_setting('app.c184_same') = 'rows 1'
        and pg_temp.notes(current_setting('app.m184')::bigint, 's1')
            = 'grade_posted|A new grade was posted|' || current_setting('app.subj_code') || ': 1.75|/student/grades ; '
              || 'grade_changed|A grade was updated|' || current_setting('app.subj_code') || ': 2.00|/student/grades'
        and pg_temp.nall(current_setting('app.m184')::bigint) = 2
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 20. TC-185: a new application (every Registrar)
-- ==========================================
-- Expected (as postgres): the application of 'Tess Notify' is inserted; every active
-- Registrar gets exactly one 'New application|Tess Notify applied for <program code>.|
-- /registrar/applications'; nobody else (rows = active Registrars); N(s1) = N(adm) = ''.
select set_config('app.m185', pg_temp.mark()::text, true);
insert into public.applications (first_name, last_name, email, mobile, program_id)
values ('Tess', 'Notify', 'tc185.one@notify.test', null, current_setting('app.prog')::bigint);
select set_config('app.r185', format('registrars_ok %s, rows %s (active Registrars %s), N(s1) [%s], N(adm) [%s] -> %s',
  pg_temp.role_ok(current_setting('app.m185')::bigint, 'application_submitted', 'Registrar',
                  'New application|Tess Notify applied for ' || current_setting('app.prog_code') || '.|/registrar/applications'),
  pg_temp.nall(current_setting('app.m185')::bigint), pg_temp.role_count('Registrar'),
  pg_temp.notes(current_setting('app.m185')::bigint, 's1'), pg_temp.notes(current_setting('app.m185')::bigint, 'adm'),
  case when pg_temp.role_ok(current_setting('app.m185')::bigint, 'application_submitted', 'Registrar',
                            'New application|Tess Notify applied for ' || current_setting('app.prog_code') || '.|/registrar/applications')
        and pg_temp.nall(current_setting('app.m185')::bigint) = pg_temp.role_count('Registrar')
        and pg_temp.notes(current_setting('app.m185')::bigint, 's1') = ''
        and pg_temp.notes(current_setting('app.m185')::bigint, 'adm') = ''
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 21. TC-186: inactive recipients get nothing
-- ==========================================
-- Setup: Student 2, the seed Registrar and the seed Cashier are made inactive (restored
-- right after). Expected: a hold on Student 2 'inserted' but N(s2) = ''; the application of
-- 'Ivy Notify' reaches the OTHER active Registrars only (role_ok over the active ones is true;
-- with only the seed Registrar that means no row at all) and N(reg) = ''; notify_office on
-- the Financial department gives N(cash) = ''. All three are active again afterwards.
update public.profiles set is_active = false
where profile_id::text in (current_setting('app.s2'), current_setting('app.reg'), current_setting('app.cash'));
select set_config('app.m186', pg_temp.mark()::text, true);
do $$
declare v text;
begin
  with h as (insert into public.academic_holds (student_id, department_id, reason, placed_by)
             values (current_setting('app.s2')::uuid, current_setting('app.ddep')::bigint, 'TC inactive hold', current_setting('app.dept')::uuid)
             returning hold_id)
  select 'inserted ' || hold_id into v from h;
  perform set_config('app.c186_hold', v, true);
exception when others then
  perform set_config('app.c186_hold', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
insert into public.applications (first_name, last_name, email, mobile, program_id)
values ('Ivy', 'Notify', 'tc186.two@notify.test', null, current_setting('app.prog')::bigint);
select private.notify_office(current_setting('app.fin')::bigint, 'tc_inactive', 'Office test', '', '/department/x', '/cashier/x');
select set_config('app.t186_other_regs', (pg_temp.role_count('Registrar') = 0
  or pg_temp.role_ok(current_setting('app.m186')::bigint, 'application_submitted', 'Registrar',
                     'New application|Ivy Notify applied for ' || current_setting('app.prog_code') || '.|/registrar/applications'))::text, true);
select set_config('app.t186_apps', pg_temp.nkind(current_setting('app.m186')::bigint, 'application_submitted')::text, true);
select set_config('app.t186_s2', pg_temp.notes(current_setting('app.m186')::bigint, 's2'), true);
select set_config('app.t186_reg', pg_temp.notes(current_setting('app.m186')::bigint, 'reg'), true);
select set_config('app.t186_cash', pg_temp.notes(current_setting('app.m186')::bigint, 'cash'), true);
update public.profiles set is_active = true
where profile_id::text in (current_setting('app.s2'), current_setting('app.reg'), current_setting('app.cash'));
select set_config('app.r186', format('hold [%s], N(s2) [%s], N(reg) [%s], N(cash) [%s], other_registrars_ok %s (application rows %s), restored %s -> %s',
  current_setting('app.c186_hold'), current_setting('app.t186_s2'), current_setting('app.t186_reg'),
  current_setting('app.t186_cash'), current_setting('app.t186_other_regs'), current_setting('app.t186_apps'),
  (select count(*) from public.profiles where is_active
     and profile_id::text in (current_setting('app.s2'), current_setting('app.reg'), current_setting('app.cash'))),
  case when current_setting('app.c186_hold') like 'inserted %'
        and current_setting('app.t186_s2') = '' and current_setting('app.t186_reg') = ''
        and current_setting('app.t186_cash') = '' and current_setting('app.t186_other_regs') = 'true'
        and (select count(*) from public.profiles where is_active
               and profile_id::text in (current_setting('app.s2'), current_setting('app.reg'), current_setting('app.cash'))) = 3
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 22. TC-187: private.notify never raises and writes only what is valid
-- ==========================================
-- Expected (as postgres; Student 2 inactive for call 4): all 11 calls 'ok' (no error):
-- 500-character title, NULL recipient, unknown recipient, inactive recipient, a
-- 'javascript:' link, kind 'Bad Kind', blank title, 1000-character body, control characters,
-- a 201-character link, NULL kind. N(s1) = exactly these 5 rows in order:
-- 'tc_notify|<120 x T>|Long title|/student'
-- 'tc_notify|Bad link|b|NULL'                      (link dropped, row kept)
-- 'tc_notify|Long body|<400 x b>|NULL'
-- 'tc_notify|Two lines|tab here|/student/x'         (control characters -> spaces, trimmed)
-- 'tc_notify|Long link||NULL'                      (201-character link dropped)
-- N(s2) = ''; 5 rows in all.
update public.profiles set is_active = false where profile_id::text = current_setting('app.s2');
select set_config('app.c187', '', true);
select set_config('app.m187', pg_temp.mark()::text, true);
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1,  $q$select 'ok'::text from private.notify(current_setting('app.s1')::uuid, 'tc_notify', repeat('T', 500), 'Long title', '/student')$q$),
    (2,  $q$select 'ok'::text from private.notify(null, 'tc_notify', 'Nobody', '', null)$q$),
    (3,  $q$select 'ok'::text from private.notify(gen_random_uuid(), 'tc_notify', 'Unknown', '', null)$q$),
    (4,  $q$select 'ok'::text from private.notify(current_setting('app.s2')::uuid, 'tc_notify', 'Inactive', '', null)$q$),
    (5,  $q$select 'ok'::text from private.notify(current_setting('app.s1')::uuid, 'tc_notify', 'Bad link', 'b', 'javascript:alert(1)')$q$),
    (6,  $q$select 'ok'::text from private.notify(current_setting('app.s1')::uuid, 'Bad Kind', 'Bad kind', '', null)$q$),
    (7,  $q$select 'ok'::text from private.notify(current_setting('app.s1')::uuid, 'tc_notify', '   ', 'blank title', null)$q$),
    (8,  $q$select 'ok'::text from private.notify(current_setting('app.s1')::uuid, 'tc_notify', 'Long body', repeat('b', 1000), null)$q$),
    (9,  $q$select 'ok'::text from private.notify(current_setting('app.s1')::uuid, 'tc_notify', E'  Two\nlines  ', E'tab\there', '/student/x')$q$),
    (10, $q$select 'ok'::text from private.notify(current_setting('app.s1')::uuid, 'tc_notify', 'Long link', '', '/' || repeat('a', 200))$q$),
    (11, $q$select 'ok'::text from private.notify(current_setting('app.s1')::uuid, null, 'Null kind', '', null)$q$)
  ) as t(ord, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
    exception when others then
      v := 'ERR [' || sqlstate || ']: ' || sqlerrm;
    end;
    perform set_config('app.c187', current_setting('app.c187') || r.ord || ':' || coalesce(v, 'NULL') || ' ', true);
  end loop;
end $$;
update public.profiles set is_active = true where profile_id::text = current_setting('app.s2');
select set_config('app.r187', format('calls [%s], N(s1) [%s], N(s2) [%s], rows %s -> %s',
  current_setting('app.c187'), left(pg_temp.notes(current_setting('app.m187')::bigint, 's1'), 300),
  pg_temp.notes(current_setting('app.m187')::bigint, 's2'), pg_temp.nall(current_setting('app.m187')::bigint),
  case when current_setting('app.c187') = '1:ok 2:ok 3:ok 4:ok 5:ok 6:ok 7:ok 8:ok 9:ok 10:ok 11:ok '
        and pg_temp.notes(current_setting('app.m187')::bigint, 's1')
            = 'tc_notify|' || repeat('T', 120) || '|Long title|/student ; '
              || 'tc_notify|Bad link|b|NULL ; '
              || 'tc_notify|Long body|' || repeat('b', 400) || '|NULL ; '
              || 'tc_notify|Two lines|tab here|/student/x ; '
              || 'tc_notify|Long link||NULL'
        and pg_temp.notes(current_setting('app.m187')::bigint, 's2') = ''
        and pg_temp.nall(current_setting('app.m187')::bigint) = 5
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 23. TC-188: notify_role, notify_office, person_name
-- ==========================================
-- Expected (as postgres): notify_role('Registrar') -> every active Registrar exactly one
-- 'Role test||/registrar/x'; notify_role('NoSuchRole') -> 0 rows; notify_office(dept@'s
-- department) -> N(dept) = 'tc_office_d|Office test||/department/x' and as many rows as
-- that department has active heads, no Cashier; notify_office(the Financial department) ->
-- N(cash) = 'tc_office_f|Office test||/cashier/x', rows = active Cashiers + that
-- department's active heads, nothing for dept@; notify_office(NULL) -> 0 rows;
-- person_name(Student 1) = '<s1name>'; person_name(unknown) NULL.
select set_config('app.m188', pg_temp.mark()::text, true);
select private.notify_role('Registrar', 'tc_role', 'Role test', '', '/registrar/x');
select private.notify_role('NoSuchRole', 'tc_role_none', 'Role test', '', '/registrar/x');
select private.notify_office(current_setting('app.ddep')::bigint, 'tc_office_d', 'Office test', '', '/department/x', '/cashier/x');
select private.notify_office(current_setting('app.fin')::bigint, 'tc_office_f', 'Office test', '', '/department/x', '/cashier/x');
select private.notify_office(null, 'tc_office_n', 'Office test', '', '/department/x', '/cashier/x');
select set_config('app.r188', format('role_ok %s, no_such_role %s, N(dept) [%s] (rows %s, heads %s), N(cash) [%s] (rows %s, expected %s), null_office %s, person_name [%s], unknown_name_null %s -> %s',
  pg_temp.role_ok(current_setting('app.m188')::bigint, 'tc_role', 'Registrar', 'Role test||/registrar/x'),
  pg_temp.nkind(current_setting('app.m188')::bigint, 'tc_role_none'),
  pg_temp.notes(current_setting('app.m188')::bigint, 'dept'),
  pg_temp.nkind(current_setting('app.m188')::bigint, 'tc_office_d'), pg_temp.heads(current_setting('app.ddep')::bigint),
  pg_temp.notes(current_setting('app.m188')::bigint, 'cash'),
  pg_temp.nkind(current_setting('app.m188')::bigint, 'tc_office_f'),
  pg_temp.role_count('Cashier') + pg_temp.heads(current_setting('app.fin')::bigint),
  pg_temp.nkind(current_setting('app.m188')::bigint, 'tc_office_n'),
  private.person_name(current_setting('app.s1')::uuid), private.person_name(gen_random_uuid()) is null,
  case when pg_temp.role_ok(current_setting('app.m188')::bigint, 'tc_role', 'Registrar', 'Role test||/registrar/x')
        and pg_temp.nkind(current_setting('app.m188')::bigint, 'tc_role_none') = 0
        and pg_temp.notes(current_setting('app.m188')::bigint, 'dept') = 'tc_office_d|Office test||/department/x'
        and pg_temp.nkind(current_setting('app.m188')::bigint, 'tc_office_d') = pg_temp.heads(current_setting('app.ddep')::bigint)
        and pg_temp.notes(current_setting('app.m188')::bigint, 'cash') = 'tc_office_f|Office test||/cashier/x'
        and pg_temp.nkind(current_setting('app.m188')::bigint, 'tc_office_f')
            = pg_temp.role_count('Cashier') + pg_temp.heads(current_setting('app.fin')::bigint)
        and pg_temp.nkind(current_setting('app.m188')::bigint, 'tc_office_n') = 0
        and private.person_name(current_setting('app.s1')::uuid) = current_setting('app.s1name')
        and private.person_name(gen_random_uuid()) is null
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 24. TC-189: RLS
-- ==========================================
-- Expected: Student 1 counts exactly their own rows (= the owner's count for Student 1) and
-- 0 rows of anyone else; the Registrar and the Admin count exactly their own; Student 3 sees
-- 0 of Student 1's rows; anon is denied ('permission denied').
select set_config('app.t189_s1',  (select count(*)::text from public.notifications where recipient_id::text = current_setting('app.s1')), true);
select set_config('app.t189_reg', (select count(*)::text from public.notifications where recipient_id::text = current_setting('app.reg')), true);
select set_config('app.t189_adm', (select count(*)::text from public.notifications where recipient_id::text = current_setting('app.adm')), true);
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c189_s1',     's1',  $q$select count(*)::text from public.notifications$q$),
    (2, 'c189_s1oth',  's1',  $q$select count(*)::text from public.notifications where recipient_id <> auth.uid()$q$),
    (3, 'c189_reg',    'reg', $q$select count(*)::text from public.notifications$q$),
    (4, 'c189_adm',    'adm', $q$select count(*)::text from public.notifications$q$),
    (5, 'c189_s3_s1',  's3',  $q$select count(*)::text from public.notifications where recipient_id = current_setting('app.s1')::uuid$q$)
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
  select count(*)::text into v from public.notifications;
  perform set_config('app.c189_anon', v, true);
exception when others then
  perform set_config('app.c189_anon', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
reset role;
select set_config('app.r189', format('s1 %s/%s, s1_others %s, registrar %s/%s, admin %s/%s, s3_sees_s1 %s, anon [%s] -> %s',
  current_setting('app.c189_s1'), current_setting('app.t189_s1'), current_setting('app.c189_s1oth'),
  current_setting('app.c189_reg'), current_setting('app.t189_reg'), current_setting('app.c189_adm'),
  current_setting('app.t189_adm'), current_setting('app.c189_s3_s1'), current_setting('app.c189_anon'),
  case when current_setting('app.c189_s1') = current_setting('app.t189_s1') and current_setting('app.t189_s1')::bigint > 0
        and current_setting('app.c189_s1oth') = '0'
        and current_setting('app.c189_reg') = current_setting('app.t189_reg') and current_setting('app.t189_reg')::bigint > 0
        and current_setting('app.c189_adm') = current_setting('app.t189_adm')
        and current_setting('app.c189_s3_s1') = '0'
        and current_setting('app.c189_anon') like 'ERR [42501]: permission denied%'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 25. TC-190: list_my_notifications
-- ==========================================
-- Setup as postgres: 40 rows 'tc_bulk' for Student 3 through private.notify; the first 5 of
-- them marked read. T3 / U3 = Student 3's total / unread rows (read from the table).
-- Expected as Student 3: the default call returns exactly the ids of the owner's query
-- "newest first (created_at DESC, notification_id DESC), 30 rows"; p_limit 0 -> 1 row;
-- p_limit -5 -> 1; p_limit 1000 -> least(T3, 100); p_limit NULL -> least(T3, 30);
-- p_unread_only true (limit 100) -> least(U3, 100) rows, none read; p_unread_only NULL ->
-- same as false.
do $$
declare g integer;
begin
  for g in 1..40 loop
    perform private.notify(current_setting('app.s3')::uuid, 'tc_bulk', 'TC bulk ' || lpad(g::text, 2, '0'), '', '/student');
  end loop;
end $$;
update public.notifications set read_at = now()
where notification_id in (select n.notification_id from public.notifications n
                          where n.recipient_id::text = current_setting('app.s3') and n.kind = 'tc_bulk'
                          order by n.notification_id limit 5);
select set_config('app.t190_total',  (select count(*)::text from public.notifications where recipient_id::text = current_setting('app.s3')), true);
select set_config('app.t190_unread', (select count(*)::text from public.notifications where recipient_id::text = current_setting('app.s3') and read_at is null), true);
select set_config('app.t190_ids', coalesce((select string_agg(x.notification_id::text, ',' order by x.rn) from (
    select n.notification_id, row_number() over (order by n.created_at desc, n.notification_id desc) as rn
    from public.notifications n where n.recipient_id::text = current_setting('app.s3')) x where x.rn <= 30), ''), true);
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c190_default', 's3', $q$select string_agg(l.notification_id::text, ',' order by l.ord)
                                 from public.list_my_notifications() with ordinality as l(notification_id, kind, title, body, link, created_at, read_at, ord)$q$),
    (2, 'c190_zero',    's3', $q$select count(*)::text from public.list_my_notifications(0)$q$),
    (3, 'c190_neg',     's3', $q$select count(*)::text from public.list_my_notifications(-5)$q$),
    (4, 'c190_big',     's3', $q$select count(*)::text from public.list_my_notifications(1000)$q$),
    (5, 'c190_null',    's3', $q$select count(*)::text from public.list_my_notifications(null)$q$),
    (6, 'c190_unread',  's3', $q$select count(*) || '|' || count(*) filter (where l.read_at is not null) from public.list_my_notifications(100, true) l$q$),
    (7, 'c190_nullflt', 's3', $q$select count(*)::text from public.list_my_notifications(100, null)$q$)
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
select set_config('app.r190', format('default_order_ok %s, zero %s, negative %s, big %s, null %s, unread [%s], unread_null_filter %s (total %s, unread %s) -> %s',
  current_setting('app.c190_default') = current_setting('app.t190_ids'),
  current_setting('app.c190_zero'), current_setting('app.c190_neg'), current_setting('app.c190_big'),
  current_setting('app.c190_null'), current_setting('app.c190_unread'), current_setting('app.c190_nullflt'),
  current_setting('app.t190_total'), current_setting('app.t190_unread'),
  case when current_setting('app.c190_default') = current_setting('app.t190_ids')
        and current_setting('app.t190_total')::bigint >= 40
        and current_setting('app.c190_zero') = '1' and current_setting('app.c190_neg') = '1'
        and current_setting('app.c190_big') = least(current_setting('app.t190_total')::bigint, 100)::text
        and current_setting('app.c190_null') = least(current_setting('app.t190_total')::bigint, 30)::text
        and current_setting('app.c190_unread') = least(current_setting('app.t190_unread')::bigint, 100)::text || '|0'
        and current_setting('app.c190_nullflt') = least(current_setting('app.t190_total')::bigint, 100)::text
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 26. TC-191: someone else's ids
-- ==========================================
-- Setup: b6, b7 = Student 3's 6th and 7th 'tc_bulk' rows (unread); s1u = Student 1's newest
-- unread row. Expected as Student 1: mark(b6, b7) -> '0'; mark(b6, s1u) -> '1'. Afterwards b6
-- and b7 are still unread, s1u is read.
select set_config('app.b6', (select n.notification_id::text from public.notifications n
  where n.recipient_id::text = current_setting('app.s3') and n.kind = 'tc_bulk' order by n.notification_id offset 5 limit 1), true);
select set_config('app.b7', (select n.notification_id::text from public.notifications n
  where n.recipient_id::text = current_setting('app.s3') and n.kind = 'tc_bulk' order by n.notification_id offset 6 limit 1), true);
select set_config('app.s1u', (select max(n.notification_id)::text from public.notifications n
  where n.recipient_id::text = current_setting('app.s1') and n.read_at is null), true);
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c191_other', 's1', $q$select public.mark_notifications_read(array[current_setting('app.b6')::bigint, current_setting('app.b7')::bigint])::text$q$),
    (2, 'c191_mixed', 's1', $q$select public.mark_notifications_read(array[current_setting('app.b6')::bigint, current_setting('app.s1u')::bigint])::text$q$)
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
select set_config('app.r191', format('others_only [%s], mixed [%s], b6_b7_unread %s, own_read %s -> %s',
  current_setting('app.c191_other'), current_setting('app.c191_mixed'),
  (select count(*) from public.notifications where notification_id in (current_setting('app.b6')::bigint, current_setting('app.b7')::bigint) and read_at is null),
  (select read_at is not null from public.notifications where notification_id = current_setting('app.s1u')::bigint),
  case when current_setting('app.c191_other') = '0' and current_setting('app.c191_mixed') = '1'
        and (select count(*) from public.notifications
              where notification_id in (current_setting('app.b6')::bigint, current_setting('app.b7')::bigint) and read_at is null) = 2
        and (select read_at = now() from public.notifications where notification_id = current_setting('app.s1u')::bigint)
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 27. TC-192: unread count and mark read (own rows)
-- ==========================================
-- Expected as Student 3 (U = their unread rows now): count U; mark(b6, b7) 2; count U-2;
-- mark(b6, b7) again 0; mark(empty array) 0; mark(NULL) U-2; count 0; mark() 0. b6's read_at
-- = now() (the database's time).
select set_config('app.t192_u', (select count(*)::text from public.notifications
  where recipient_id::text = current_setting('app.s3') and read_at is null), true);
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c192_1', 's3', $q$select public.notification_unread_count()::text$q$),
    (2, 'c192_2', 's3', $q$select public.mark_notifications_read(array[current_setting('app.b6')::bigint, current_setting('app.b7')::bigint])::text$q$),
    (3, 'c192_3', 's3', $q$select public.notification_unread_count()::text$q$),
    (4, 'c192_4', 's3', $q$select public.mark_notifications_read(array[current_setting('app.b6')::bigint, current_setting('app.b7')::bigint])::text$q$),
    (5, 'c192_5', 's3', $q$select public.mark_notifications_read('{}'::bigint[])::text$q$),
    (6, 'c192_6', 's3', $q$select public.mark_notifications_read(null)::text$q$),
    (7, 'c192_7', 's3', $q$select public.notification_unread_count()::text$q$),
    (8, 'c192_8', 's3', $q$select public.mark_notifications_read()::text$q$)
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
select set_config('app.t192_seq', current_setting('app.c192_1') || '|' || current_setting('app.c192_2') || '|' || current_setting('app.c192_3')
  || '|' || current_setting('app.c192_4') || '|' || current_setting('app.c192_5') || '|' || current_setting('app.c192_6')
  || '|' || current_setting('app.c192_7') || '|' || current_setting('app.c192_8'), true);
select set_config('app.r192', format('sequence [%s] (unread before %s), b6_read_now %s -> %s',
  current_setting('app.t192_seq'), current_setting('app.t192_u'),
  (select read_at = now() from public.notifications where notification_id = current_setting('app.b6')::bigint),
  case when current_setting('app.t192_seq') = format('%s|2|%s|0|0|%s|0|0', current_setting('app.t192_u'),
                                                     current_setting('app.t192_u')::bigint - 2, current_setting('app.t192_u')::bigint - 2)
        and current_setting('app.t192_u')::bigint >= 2
        and (select read_at = now() from public.notifications where notification_id = current_setting('app.b6')::bigint)
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 28. TC-193: refusals
-- ==========================================
-- Expected: Student 3 made inactive: list, count and mark each 'ERR [42501]: not allowed:
-- ...'; authenticated without a JWT and with an unknown user id: count 'ERR [42501]: not
-- allowed: ...'.
update public.profiles set is_active = false where profile_id::text = current_setting('app.s3');
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c193_list',   's3',    $q$select count(*)::text from public.list_my_notifications()$q$),
    (2, 'c193_count',  's3',    $q$select public.notification_unread_count()::text$q$),
    (3, 'c193_mark',   's3',    $q$select public.mark_notifications_read()::text$q$),
    (4, 'c193_nojwt',  'nojwt', $q$select public.notification_unread_count()::text$q$),
    (5, 'c193_ghost',  'ghost', $q$select public.notification_unread_count()::text$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      case r.who when 'nojwt' then ''
                 when 'ghost' then json_build_object('sub', '00000000-0000-4000-8000-0000000000aa', 'role', 'authenticated')::text
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
update public.profiles set is_active = true where profile_id::text = current_setting('app.s3');
select set_config('app.r193', format('inactive list [%s], count [%s], mark [%s], no_jwt [%s], unknown_user [%s] -> %s',
  current_setting('app.c193_list'), current_setting('app.c193_count'), current_setting('app.c193_mark'),
  current_setting('app.c193_nojwt'), current_setting('app.c193_ghost'),
  case when current_setting('app.c193_list') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c193_count') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c193_mark') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c193_nojwt') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c193_ghost') like 'ERR [42501]: not allowed:%'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 29. TC-194: direct writes by authenticated
-- ==========================================
-- Expected as Student 1: INSERT, UPDATE (read_at), DELETE and TRUNCATE on notifications each
-- 'ERR [42501]: permission denied ...'; a SELECT still works (a number).
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c194_insert', 's1', $q$with i as (insert into public.notifications (recipient_id, kind, title) values (auth.uid(), 'tc_direct', 'Direct') returning 1) select 'rows ' || count(*) from i$q$),
    (2, 'c194_update', 's1', $q$with u as (update public.notifications set read_at = now() where recipient_id = auth.uid() returning 1) select 'rows ' || count(*) from u$q$),
    (3, 'c194_delete', 's1', $q$with d as (delete from public.notifications where recipient_id = auth.uid() returning 1) select 'rows ' || count(*) from d$q$),
    (4, 'c194_select', 's1', $q$select count(*)::text from public.notifications$q$)
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
  begin
    truncate public.notifications;
    perform set_config('app.c194_truncate', 'TRUNCATED', true);
  exception when others then
    perform set_config('app.c194_truncate', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r194', format('insert [%s], update [%s], delete [%s], truncate [%s], select [%s] -> %s',
  current_setting('app.c194_insert'), current_setting('app.c194_update'), current_setting('app.c194_delete'),
  current_setting('app.c194_truncate'), current_setting('app.c194_select'),
  case when current_setting('app.c194_insert') like 'ERR [42501]: permission denied%'
        and current_setting('app.c194_update') like 'ERR [42501]: permission denied%'
        and current_setting('app.c194_delete') like 'ERR [42501]: permission denied%'
        and current_setting('app.c194_truncate') like 'ERR [42501]: permission denied%'
        and current_setting('app.c194_select') ~ '^[0-9]+$'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 30. TC-195: the BEFORE UPDATE trigger (as the owner)
-- ==========================================
-- Setup: one unread row for Student 1 ('tc_guard', 'Guard test'). Expected (as postgres):
-- changing title, recipient_id, kind, body, link or created_at: 'ERR [P0001]: bad
-- notification change: ...'; read_at = 2000-01-01 'rows 1' and the stored value is now();
-- read_at = NULL 'ERR [P0001]: bad notification change: ...'; read_at = 2001-01-01 'rows 1'
-- and the stored value is still now(); title still 'Guard test'.
select private.notify(current_setting('app.s1')::uuid, 'tc_guard', 'Guard test', 'Guard body', '/student/guard');
select set_config('app.ng', (select max(notification_id)::text from public.notifications
  where recipient_id::text = current_setting('app.s1') and kind = 'tc_guard'), true);
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c195_title',   $q$with u as (update public.notifications set title = 'Changed' where notification_id = current_setting('app.ng')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (2, 'c195_recip',   $q$with u as (update public.notifications set recipient_id = current_setting('app.s2')::uuid where notification_id = current_setting('app.ng')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (3, 'c195_kind',    $q$with u as (update public.notifications set kind = 'tc_other' where notification_id = current_setting('app.ng')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (4, 'c195_body',    $q$with u as (update public.notifications set body = 'Changed' where notification_id = current_setting('app.ng')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (5, 'c195_link',    $q$with u as (update public.notifications set link = '/changed' where notification_id = current_setting('app.ng')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (6, 'c195_created', $q$with u as (update public.notifications set created_at = now() - interval '1 day' where notification_id = current_setting('app.ng')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (7, 'c195_read',    $q$with u as (update public.notifications set read_at = '2000-01-01T00:00:00Z' where notification_id = current_setting('app.ng')::bigint returning (read_at = now()) as is_now) select 'rows ' || count(*) || ' now ' || coalesce(bool_and(is_now)::text, 'NULL') from u$q$),
    (8, 'c195_unread',  $q$with u as (update public.notifications set read_at = null where notification_id = current_setting('app.ng')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (9, 'c195_reread',  $q$with u as (update public.notifications set read_at = '2001-01-01T00:00:00Z' where notification_id = current_setting('app.ng')::bigint returning (read_at = now()) as is_now) select 'rows ' || count(*) || ' now ' || coalesce(bool_and(is_now)::text, 'NULL') from u$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.r195', format('title [%s], recipient [%s], kind [%s], body [%s], link [%s], created_at [%s], read [%s], unread [%s], read_again [%s], row_ok %s -> %s',
  left(current_setting('app.c195_title'), 60), left(current_setting('app.c195_recip'), 60), left(current_setting('app.c195_kind'), 60),
  left(current_setting('app.c195_body'), 60), left(current_setting('app.c195_link'), 60), left(current_setting('app.c195_created'), 60),
  current_setting('app.c195_read'), left(current_setting('app.c195_unread'), 60), current_setting('app.c195_reread'),
  (select title = 'Guard test' and read_at = now() and kind = 'tc_guard' and recipient_id::text = current_setting('app.s1')
     from public.notifications where notification_id = current_setting('app.ng')::bigint),
  case when current_setting('app.c195_title') like 'ERR [P0001]: bad notification change:%'
        and current_setting('app.c195_recip') like 'ERR [P0001]: bad notification change:%'
        and current_setting('app.c195_kind') like 'ERR [P0001]: bad notification change:%'
        and current_setting('app.c195_body') like 'ERR [P0001]: bad notification change:%'
        and current_setting('app.c195_link') like 'ERR [P0001]: bad notification change:%'
        and current_setting('app.c195_created') like 'ERR [P0001]: bad notification change:%'
        and current_setting('app.c195_read') = 'rows 1 now true'
        and current_setting('app.c195_unread') like 'ERR [P0001]: bad notification change:%'
        and current_setting('app.c195_reread') = 'rows 1 now true'
        and (select title = 'Guard test' and read_at = now() and kind = 'tc_guard' and recipient_id::text = current_setting('app.s1')
               from public.notifications where notification_id = current_setting('app.ng')::bigint)
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 31. TC-196: KEY SAFETY 1 - notifications cannot be written at all
-- ==========================================
-- Setup: a third Pending request of Student 1; then a temporary CHECK (false) NOT VALID on
-- notifications, so EVERY insert into it fails (dropped again inside this case).
-- Expected: the request Pending -> Processing 'rows 1' (and it IS Processing); a new hold
-- 'inserted'; private.notify itself 'ok' (no error); the Registrar issues Student 3 a TCN-A
-- ticket '#' + 7 digits (the queue trigger's write fails silently); 0 notification rows.
-- After the CHECK is dropped one private.notify writes 1 row again.
with r as (insert into public.document_requests (student_id, document_type_id, purpose)
           values (current_setting('app.s1')::uuid, current_setting('app.dt')::bigint, 'TC notify safety') returning request_id)
select set_config('app.dq3', request_id::text, true) from r;
select set_config('app.m196', pg_temp.mark()::text, true);
alter table public.notifications add constraint tc_block_all check (false) not valid;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c196_doc',    $q$with u as (update public.document_requests set status = 'Processing', processed_by = current_setting('app.reg')::uuid
                                      where request_id = current_setting('app.dq3')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (2, 'c196_hold',   $q$with h as (insert into public.academic_holds (student_id, department_id, reason, placed_by)
                                      values (current_setting('app.s1')::uuid, current_setting('app.ddep')::bigint, 'TC blocked notification', current_setting('app.dept')::uuid)
                                      returning hold_id) select 'inserted ' || hold_id from h$q$),
    (3, 'c196_notify', $q$select 'ok'::text from private.notify(current_setting('app.s1')::uuid, 'tc_block', 'Blocked', '', null)$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
set local role authenticated;
do $$
declare v text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('app.reg'), 'role', 'authenticated')::text, true);
  select i.ticket_label into v from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCN-A') i;
  perform set_config('app.c196_queue', coalesce(v, 'NULL'), true);
exception when others then
  perform set_config('app.c196_queue', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.t196_rows', pg_temp.nall(current_setting('app.m196')::bigint)::text, true);
alter table public.notifications drop constraint tc_block_all;
select set_config('app.m196b', pg_temp.mark()::text, true);
select private.notify(current_setting('app.s1')::uuid, 'tc_unblocked', 'Unblocked', '', null);
select set_config('app.r196', format('document [%s] (status %s), hold [%s], notify [%s], queue [%s], rows_while_blocked %s, rows_after %s -> %s',
  current_setting('app.c196_doc'),
  (select status from public.document_requests where request_id = current_setting('app.dq3')::bigint),
  current_setting('app.c196_hold'), current_setting('app.c196_notify'), current_setting('app.c196_queue'),
  current_setting('app.t196_rows'), pg_temp.nall(current_setting('app.m196b')::bigint),
  case when current_setting('app.c196_doc') = 'rows 1'
        and (select status from public.document_requests where request_id = current_setting('app.dq3')::bigint) = 'Processing'
        and current_setting('app.c196_hold') like 'inserted %'
        and current_setting('app.c196_notify') = 'ok'
        and current_setting('app.c196_queue') ~ '^#[1-9][0-9]{6}$'
        and current_setting('app.t196_rows') = '0'
        and pg_temp.nall(current_setting('app.m196b')::bigint) = 1
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 32. TC-197: KEY SAFETY 2 - private.notify raises
-- ==========================================
-- Setup: the definition of private.notify is saved, then the function is replaced by one that
-- always raises 'tc boom' (inside this transaction only). Expected: the request Processing ->
-- Ready 'rows 1' (and it IS Ready); a new hold 'inserted'; notify_role and notify_office 'ok'
-- (their own handlers catch it); the Registrar's call next returns Student 3's TCN-A ticket
-- (the label issued in TC-196); 0 notification rows. Then private.notify is restored from the
-- saved definition: same source, still not executable by anon / authenticated, and one call
-- writes 1 row again.
select set_config('app.notify_def', pg_get_functiondef('private.notify(uuid, text, text, text, text)'::regprocedure), true);
select set_config('app.notify_src', (select prosrc from pg_proc where oid = 'private.notify(uuid, text, text, text, text)'::regprocedure), true);
create or replace function private.notify(p_recipient uuid, p_kind text, p_title text, p_body text, p_link text)
 returns void
 language plpgsql
 volatile
 set search_path to ''
as $f$
begin
  raise exception 'tc boom: private.notify broken on purpose by TC-197';
end
$f$;
select set_config('app.m197', pg_temp.mark()::text, true);
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c197_doc',    $q$with u as (update public.document_requests set status = 'Ready'
                                      where request_id = current_setting('app.dq3')::bigint returning 1) select 'rows ' || count(*) from u$q$),
    (2, 'c197_hold',   $q$with h as (insert into public.academic_holds (student_id, department_id, reason, placed_by)
                                      values (current_setting('app.s2')::uuid, current_setting('app.ddep')::bigint, 'TC broken notification', current_setting('app.dept')::uuid)
                                      returning hold_id) select 'inserted ' || hold_id from h$q$),
    (3, 'c197_role',   $q$select 'ok'::text from private.notify_role('Registrar', 'tc_broken', 'Broken', '', null)$q$),
    (4, 'c197_office', $q$select 'ok'::text from private.notify_office(current_setting('app.fin')::bigint, 'tc_broken', 'Broken', '', null, null)$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt into v;
      perform set_config('app.' || r.label, coalesce(v, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
set local role authenticated;
do $$
declare v text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('app.reg'), 'role', 'authenticated')::text, true);
  select c.ticket_label into v from public.queue_call_next('TCN-A') c;
  perform set_config('app.c197_queue', coalesce(v, 'NULL'), true);
exception when others then
  perform set_config('app.c197_queue', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.t197_rows', pg_temp.nall(current_setting('app.m197')::bigint)::text, true);
do $$
begin
  execute current_setting('app.notify_def');
end $$;
select set_config('app.m197b', pg_temp.mark()::text, true);
select private.notify(current_setting('app.s1')::uuid, 'tc_restored', 'Restored', '', null);
select set_config('app.r197', format('document [%s] (status %s), hold [%s], notify_role [%s], notify_office [%s], queue [%s] (expected %s), rows_while_broken %s, restored_source %s, restored_grants_ok %s, rows_after %s -> %s',
  current_setting('app.c197_doc'),
  (select status from public.document_requests where request_id = current_setting('app.dq3')::bigint),
  current_setting('app.c197_hold'), current_setting('app.c197_role'), current_setting('app.c197_office'),
  current_setting('app.c197_queue'), current_setting('app.c196_queue'), current_setting('app.t197_rows'),
  (select prosrc = current_setting('app.notify_src') from pg_proc where oid = 'private.notify(uuid, text, text, text, text)'::regprocedure),
  (not has_function_privilege('anon', 'private.notify(uuid, text, text, text, text)', 'EXECUTE')
   and not has_function_privilege('authenticated', 'private.notify(uuid, text, text, text, text)', 'EXECUTE')),
  pg_temp.nall(current_setting('app.m197b')::bigint),
  case when current_setting('app.c197_doc') = 'rows 1'
        and (select status from public.document_requests where request_id = current_setting('app.dq3')::bigint) = 'Ready'
        and current_setting('app.c197_hold') like 'inserted %'
        and current_setting('app.c197_role') = 'ok' and current_setting('app.c197_office') = 'ok'
        and current_setting('app.c197_queue') = current_setting('app.c196_queue')
        and current_setting('app.t197_rows') = '0'
        and (select prosrc = current_setting('app.notify_src') from pg_proc where oid = 'private.notify(uuid, text, text, text, text)'::regprocedure)
        and not has_function_privilege('anon', 'private.notify(uuid, text, text, text, text)', 'EXECUTE')
        and not has_function_privilege('authenticated', 'private.notify(uuid, text, text, text, text)', 'EXECUTE')
        and pg_temp.nall(current_setting('app.m197b')::bigint) = 1
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 33. TC-198: not audited, no loop
-- ==========================================
-- Expected: 0 audit rows for table 'notifications' since the start of this script; the only
-- trigger on notifications is require_notification_rules; none of the eight event trigger
-- functions contains an INSERT INTO / UPDATE / DELETE statement (they write only through
-- private.notify, and notifications has no INSERT trigger, so nothing can loop).
select set_config('app.r198', (select format('audit_rows %s, notifications_triggers [%s], writing_functions [%s] -> %s',
    x.audit, x.trg, x.writers,
    case when x.audit = 0 and x.trg = 'require_notification_rules' and x.writers = '' then 'OK' else 'FAIL' end)
  from (select
    (select count(*) from public.audit_logs l
      where l.log_id > current_setting('app.log_mark')::bigint and l.table_name = 'notifications') as audit,
    coalesce((select string_agg(t.tgname::text, ', ' order by t.tgname) from pg_trigger t
               where t.tgrelid = 'public.notifications'::regclass and not t.tgisinternal), '') as trg,
    coalesce((select string_agg(p.proname::text, ', ' order by p.proname) from pg_proc p
               where p.pronamespace = 'private'::regnamespace and p.proname like 'notify\_on\_%'
                 and (p.prosrc ilike '%insert into%' or p.prosrc ilike '%update public.%' or p.prosrc ilike '%delete from%')), '') as writers
  ) x), true);

-- ==========================================
-- Result: ONE row
-- ==========================================
select (current_setting('app.r167') like '%-> OK' and current_setting('app.r168') like '%-> OK'
        and current_setting('app.r169') like '%-> OK' and current_setting('app.r170') like '%-> OK'
        and current_setting('app.r171') like '%-> OK' and current_setting('app.r172') like '%-> OK'
        and current_setting('app.r173') like '%-> OK' and current_setting('app.r174') like '%-> OK'
        and current_setting('app.r175') like '%-> OK' and current_setting('app.r176') like '%-> OK'
        and current_setting('app.r177') like '%-> OK' and current_setting('app.r178') like '%-> OK'
        and current_setting('app.r179') like '%-> OK' and current_setting('app.r180') like '%-> OK'
        and current_setting('app.r181') like '%-> OK' and current_setting('app.r182') like '%-> OK'
        and current_setting('app.r183') like '%-> OK' and current_setting('app.r184') like '%-> OK'
        and current_setting('app.r185') like '%-> OK' and current_setting('app.r186') like '%-> OK'
        and current_setting('app.r187') like '%-> OK' and current_setting('app.r188') like '%-> OK'
        and current_setting('app.r189') like '%-> OK' and current_setting('app.r190') like '%-> OK'
        and current_setting('app.r191') like '%-> OK' and current_setting('app.r192') like '%-> OK'
        and current_setting('app.r193') like '%-> OK' and current_setting('app.r194') like '%-> OK'
        and current_setting('app.r195') like '%-> OK' and current_setting('app.r196') like '%-> OK'
        and current_setting('app.r197') like '%-> OK' and current_setting('app.r198') like '%-> OK') as all_ok,
  current_setting('app.r167') as tc167, current_setting('app.r168') as tc168, current_setting('app.r169') as tc169,
  current_setting('app.r170') as tc170, current_setting('app.r171') as tc171, current_setting('app.r172') as tc172,
  current_setting('app.r173') as tc173, current_setting('app.r174') as tc174, current_setting('app.r175') as tc175,
  current_setting('app.r176') as tc176, current_setting('app.r177') as tc177, current_setting('app.r178') as tc178,
  current_setting('app.r179') as tc179, current_setting('app.r180') as tc180, current_setting('app.r181') as tc181,
  current_setting('app.r182') as tc182, current_setting('app.r183') as tc183, current_setting('app.r184') as tc184,
  current_setting('app.r185') as tc185, current_setting('app.r186') as tc186, current_setting('app.r187') as tc187,
  current_setting('app.r188') as tc188, current_setting('app.r189') as tc189, current_setting('app.r190') as tc190,
  current_setting('app.r191') as tc191, current_setting('app.r192') as tc192, current_setting('app.r193') as tc193,
  current_setting('app.r194') as tc194, current_setting('app.r195') as tc195, current_setting('app.r196') as tc196,
  current_setting('app.r197') as tc197, current_setting('app.r198') as tc198;

rollback;
