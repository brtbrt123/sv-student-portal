-- ==========================================
-- ADMIN USER ACCOUNTS: DATA API GRANTS AND LAST-ADMIN GUARD (GitHub issue 40, REQ-ADM-01)
-- ==========================================
-- The Admin edits profiles (name, role, active / deactivated) and assigns staff to a
-- department. REQ-ADM-01 (create, update, deactivate accounts), REQ-ADM-02 (RBAC), SEC-02
-- (least privilege), SEC-06 (the admin key stays on the server, see
-- docs/decisions/sprint4-admin-users.md). Pattern: grades_rules.sql.
-- Runs AFTER hardening.sql, hardening2.sql (A, B, C) and applications_server_grants.sql
-- (all live). Independent of issue_39_catalog_grants.sql.
--
-- WHAT IT DOES
--   1. Trigger prevent_last_admin_deactivation (BEFORE UPDATE OF role_id, is_active, FOR
--      EACH ROW) on public.profiles, function private.trg_prevent_last_admin_deactivation()
--      (SECURITY DEFINER, empty search_path): an UPDATE that would leave NO active Admin is
--      refused, SQLSTATE P0001, message prefix "last admin:". "Would leave none" = the row
--      being updated is an active Admin before the update and, after it, is inactive or has
--      another role, and no other active Admin exists.
--   2. Grants, to the role authenticated only (REVOKE ALL first, so the result does not
--      depend on what was there):
--        profiles         SELECT; UPDATE (role_id, is_active, first_name, last_name)
--                         no INSERT, no DELETE (see decision 4)
--        department_staff SELECT; INSERT (profile_id, department_id); UPDATE (department_id);
--                         DELETE
--      Nothing for anon, nothing for PUBLIC, no TRUNCATE / REFERENCES / TRIGGER / MAINTAIN.
--      EXECUTE on the new function: authenticated only (like the other trigger functions,
--      hardening2.sql section C).
--   Already in place and NOT changed here (checked in section 1):
--     - RLS on both tables: profiles_read, profiles_admin_write (ALL, Admin only),
--       dept_staff_read, dept_staff_admin_write (ALL, Admin only) (rls.sql).
--     - audit_log on both tables (hardening2.sql B): every change is logged with the Admin
--       as actor. A refused update writes nothing.
--     - private.active_uid() and private.current_role_name() ignore a profile whose
--       is_active is false, so a deactivated user is locked out of every RLS-protected row
--       at once, even with a session token that has not expired yet.
--
-- DESIGN DECISIONS
--   1. "Admin only" = grants to authenticated + RLS (all signed-in users share the role
--      authenticated). A non-Admin gets "new row violates row-level security policy" on
--      INSERT and changes 0 rows on UPDATE / DELETE. Same approach as grades_rules.sql.
--   2. The issue lists profiles.department_id. profiles has no such column: a staff
--      member's department is the row in department_staff (profile_id -> department_id),
--      which is why department_staff gets write grants and profiles does not.
--      Rule used by the app (not a database rule): role Department = one Academic
--      department; role Cashier = the Financial department (as in the seed; the Cashier's
--      office itself is found by private.my_department_id()); Student, Registrar, Admin =
--      no row.
--   3. Not granted on profiles: email (it is the sign-in identity held by Supabase Auth;
--      changing it needs the admin API and a matching Auth change, not offered),
--      profile_id (the key and the link to auth.users) and created_at.
--   4. profiles INSERT and DELETE are NOT granted to authenticated. An account is created
--      and removed only by the app's server-side admin client (applications_server_grants.sql
--      already gives it INSERT / DELETE on profiles), after the caller's session proved an
--      active Admin. Users are deactivated, never deleted (is_active = false); the delete
--      path exists only to undo a half-created account.
--   5. Last-admin guard:
--      - It applies to EVERY role, postgres and the SQL editor included. A deliberate
--        change of the last Admin (for example a handover) needs a second Admin first, or
--        a reviewed change that disables the trigger for that run.
--      - Two Admins deactivating each other at the same moment cannot both succeed: the
--        guard takes a transaction-level advisory lock before it counts, and the count is a
--        new statement (READ COMMITTED), so the second one sees the first one's result.
--      - It fires only when role_id or is_active is in the SET list; the function returns
--        at once when the row is not an active Admin or stays one.
--      - SECURITY DEFINER so the count sees every profile whatever the caller's RLS says
--        (the same reason as private.current_role_name()); the function name is the one the
--        issue gives, placed in schema private (not exposed by the Data API) like the other
--        trigger functions; the trigger is named like the other triggers (no trg_ prefix).
--   6. Deactivation also has an Auth side (ban the Auth user); that is done by the server
--      action with the admin client, not by this file.
--
-- KNOWN LIMITS (not done here, on purpose)
--   - DELETE of the last Admin's profile is not guarded: no API role can delete a profile
--     (decision 4); only the owner can, and the audit foreign key keeps profiles with
--     audit history from being deleted at all (hardening2.sql B).
--   - A profile whose Auth user was deleted directly in Supabase Auth cannot be fixed from
--     the app; the foreign key fk_profiles_profile_id prevents the reverse.
--
-- How to run: Supabase SQL editor, as postgres. Copy from "BEGIN;" to "COMMIT;" inclusive
-- into a new tab and run that tab as a whole (never a selection). One transaction: any
-- error, including a failed check, rolls back everything. Re-runnable.
--   - Before running: run diagnostics (a) and (b) at the bottom and SAVE the output.
--   - Rehearse first: docs/database/issue_40_admin_users_rehearsal.sql runs this change and
--     the tests below in ONE rolled-back transaction.
--   - Deploy the app change that calls the account actions only AFTER this file is live.
-- Test AFTER: the rehearsal block at the bottom of this file (TC-147 to TC-154).
-- Undo: the ROLLBACK block after COMMIT.
--
-- Status: NOT RUN LIVE YET. Tested 2026-10-13 on a local PostgreSQL 16 rebuilt from schema.sql,
-- views.sql, seed.sql, private_functions.sql, rls.sql, hardening.sql and hardening2.sql (with
-- a stand-in for auth.users / auth.uid() and Supabase-style default grants): the change ran
-- clean, a second run was clean too, TC-147 to TC-154 pass (all_ok true), the rehearsal file
-- leaves the database unchanged, a database with no active Admin stops the run in section 1,
-- the ROLLBACK block restored the old grants, and this file together with
-- issue_39_catalog_grants.sql also passes. The race between two simultaneous Admin changes
-- (advisory lock) is by design and was NOT exercised (needs two connections). NOT yet
-- rehearsed on the live project (PostgreSQL 17); do that first.


BEGIN;

-- ------------------------------------------
-- 1. Safety checks (stop before changing anything)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
BEGIN
  -- a) The tables exist and RLS is enabled on them.
  SELECT string_agg(e.name, ', ') INTO v_bad
  FROM (VALUES ('profiles'), ('department_staff'), ('roles'), ('departments')) AS e(name)
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                    WHERE c.relnamespace = 'public'::regnamespace AND c.relname = e.name
                      AND c.relkind::text = 'r' AND c.relrowsecurity);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_40: missing table or RLS not enabled: %; stop', v_bad;
  END IF;

  -- b) Every column used by the trigger and the grants exists with this type.
  SELECT string_agg(e.t || '.' || e.col || ' ' || e.typ, ', ') INTO v_bad
  FROM (VALUES
    ('profiles', 'profile_id', 'uuid'), ('profiles', 'role_id', 'smallint'),
    ('profiles', 'first_name', 'character varying'), ('profiles', 'last_name', 'character varying'),
    ('profiles', 'email', 'character varying'), ('profiles', 'is_active', 'boolean'),
    ('profiles', 'created_at', 'timestamp with time zone'),
    ('department_staff', 'profile_id', 'uuid'), ('department_staff', 'department_id', 'bigint'),
    ('roles', 'role_id', 'smallint'), ('roles', 'role_name', 'character varying')) AS e(t, col, typ)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = pg_catalog.to_regclass('public.' || e.t)
      AND a.attname = e.col AND a.attnum > 0 AND NOT a.attisdropped
      AND pg_catalog.format_type(a.atttypid, NULL) = e.typ);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_40: missing column or other type: %; stop', v_bad;
  END IF;

  -- c) The policies are exactly the reviewed set (rls.sql), all PERMISSIVE, TO authenticated;
  --    the two write policies are ALL and Admin only (USING and WITH CHECK).
  WITH expected(tablename, policyname, cmd) AS (VALUES
    ('profiles', 'profiles_read', 'SELECT'), ('profiles', 'profiles_admin_write', 'ALL'),
    ('department_staff', 'dept_staff_read', 'SELECT'), ('department_staff', 'dept_staff_admin_write', 'ALL')),
  live AS (
    SELECT p.tablename::text, p.policyname::text, p.cmd::text
    FROM pg_catalog.pg_policies p
    WHERE p.schemaname = 'public' AND p.tablename IN ('profiles', 'department_staff')
      AND p.permissive = 'PERMISSIVE' AND p.roles = ARRAY['authenticated']::name[]),
  diff AS (
    (SELECT 'missing ' || policyname AS d FROM (SELECT * FROM expected EXCEPT SELECT * FROM live) m)
    UNION ALL
    (SELECT 'unexpected ' || policyname FROM (SELECT * FROM live EXCEPT SELECT * FROM expected) x)
    UNION ALL
    (SELECT 'not permissive / not TO authenticated: ' || p.policyname
     FROM pg_catalog.pg_policies p
     WHERE p.schemaname = 'public' AND p.tablename IN ('profiles', 'department_staff')
       AND NOT (p.permissive = 'PERMISSIVE' AND p.roles = ARRAY['authenticated']::name[])))
  SELECT string_agg(d, '; ') INTO v_bad FROM diff;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_40: policies on profiles / department_staff differ from the reviewed set: %; stop', v_bad;
  END IF;
  SELECT string_agg(p.policyname, ', ') INTO v_bad
  FROM pg_catalog.pg_policies p
  WHERE p.schemaname = 'public' AND p.policyname IN ('profiles_admin_write', 'dept_staff_admin_write')
    AND (position('''Admin''' IN coalesce(p.qual, '')) = 0 OR position('''Admin''' IN coalesce(p.with_check, '')) = 0);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_40: write policy text is not Admin only: %; stop', v_bad;
  END IF;

  -- d) The five roles exist (the app and the guard look the Admin role up by name).
  IF (SELECT count(*) FROM public.roles WHERE role_name IN ('Student', 'Registrar', 'Cashier', 'Department', 'Admin')) <> 5 THEN
    RAISE EXCEPTION 'issue_40: public.roles does not hold the five role names; stop';
  END IF;

  -- e) The audit trigger of hardening2.sql B is on both tables, and nothing else is, except
  --    this file's own trigger when it is run a second time.
  IF pg_catalog.to_regprocedure('private.audit_log()') IS NULL THEN
    RAISE EXCEPTION 'issue_40: private.audit_log() is missing (hardening2.sql section B); stop';
  END IF;
  SELECT string_agg(e.t, ', ') INTO v_bad
  FROM (VALUES ('profiles'), ('department_staff')) AS e(t)
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid = pg_catalog.to_regclass('public.' || e.t) AND t.tgname = 'audit_log'
                      AND NOT t.tgisinternal AND t.tgfoid = 'private.audit_log()'::pg_catalog.regprocedure);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_40: audit_log trigger missing on %; stop', v_bad;
  END IF;
  SELECT string_agg(c.relname || '.' || t.tgname, ', ') INTO v_bad
  FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
  WHERE NOT t.tgisinternal AND c.relnamespace = 'public'::regnamespace
    AND c.relname IN ('profiles', 'department_staff')
    AND t.tgname NOT IN ('audit_log', 'prevent_last_admin_deactivation');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_40: unexpected trigger(s): %; stop and review', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
             WHERE t.tgname = 'prevent_last_admin_deactivation' AND NOT t.tgisinternal
               AND t.tgrelid = 'public.profiles'::regclass
               AND t.tgfoid <> pg_catalog.to_regprocedure('private.trg_prevent_last_admin_deactivation()')) THEN
    RAISE EXCEPTION 'issue_40: a different trigger named prevent_last_admin_deactivation exists; stop and review';
  END IF;

  -- f) Today's data: there IS an active Admin (the guard protects the last one; with none
  --    there is nothing to protect and the state is already broken).
  IF NOT EXISTS (SELECT 1 FROM public.profiles p JOIN public.roles r ON r.role_id = p.role_id
                 WHERE r.role_name = 'Admin' AND p.is_active) THEN
    RAISE EXCEPTION 'issue_40: no active Admin exists; fix the data first';
  END IF;
END $$;

-- ------------------------------------------
-- 2. The trigger function (design decision 5)
-- ------------------------------------------
CREATE OR REPLACE FUNCTION private.trg_prevent_last_admin_deactivation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_admin_role smallint;
  v_others     integer;
BEGIN
  IF TG_OP <> 'UPDATE' OR TG_LEVEL <> 'ROW' OR TG_WHEN <> 'BEFORE' THEN
    RAISE EXCEPTION 'private.trg_prevent_last_admin_deactivation must be a BEFORE UPDATE ... FOR EACH ROW trigger';
  END IF;

  SELECT r.role_id INTO v_admin_role FROM public.roles r WHERE r.role_name = 'Admin';
  IF v_admin_role IS NULL THEN
    RETURN NEW;
  END IF;

  -- Only an active Admin that stops being an active Admin matters.
  IF NOT (OLD.is_active AND OLD.role_id = v_admin_role) THEN
    RETURN NEW;
  END IF;
  IF NEW.is_active AND NEW.role_id = v_admin_role THEN
    RETURN NEW;
  END IF;

  -- One at a time: the second of two simultaneous changes waits here, then counts again
  -- (a new statement, so it sees the first change once that is committed).
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('private.last_admin'));

  SELECT count(*) INTO v_others
  FROM public.profiles p
  WHERE p.role_id = v_admin_role AND p.is_active AND p.profile_id <> OLD.profile_id;

  IF v_others = 0 THEN
    RAISE EXCEPTION 'last admin: this is the only active Admin account; it cannot be deactivated or given another role'
      USING ERRCODE = 'P0001',
            DETAIL = format('profile_id %s', OLD.profile_id),
            HINT = 'Make another account an active Admin first.';
  END IF;

  RETURN NEW;
END
$fn$;

REVOKE ALL ON FUNCTION private.trg_prevent_last_admin_deactivation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.trg_prevent_last_admin_deactivation() TO authenticated;

-- ------------------------------------------
-- 3. The trigger
-- ------------------------------------------
DROP TRIGGER IF EXISTS prevent_last_admin_deactivation ON public.profiles;
CREATE TRIGGER prevent_last_admin_deactivation BEFORE UPDATE OF role_id, is_active ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION private.trg_prevent_last_admin_deactivation();

-- ------------------------------------------
-- 4. Grants (authenticated only). RLS decides who may write (design decision 1).
-- ------------------------------------------
-- REVOKE on a table also removes its column grants, so this starts from nothing.
REVOKE ALL ON public.profiles, public.department_staff FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.profiles, public.department_staff TO authenticated;

GRANT UPDATE (role_id, is_active, first_name, last_name) ON public.profiles TO authenticated;

GRANT INSERT (profile_id, department_id) ON public.department_staff TO authenticated;
GRANT UPDATE (department_id)             ON public.department_staff TO authenticated;
GRANT DELETE                             ON public.department_staff TO authenticated;

-- ------------------------------------------
-- 5. Checks after the change (any failure rolls back the whole file)
-- ------------------------------------------
DO $$
DECLARE
  v_fn  regprocedure := pg_catalog.to_regprocedure('private.trg_prevent_last_admin_deactivation()');
  v_bad text;
BEGIN
  IF v_fn IS NULL THEN
    RAISE EXCEPTION 'issue_40: function not created; rolled back';
  END IF;

  -- a) Function: SECURITY DEFINER, empty search_path; no PUBLIC / anon EXECUTE, authenticated can.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                 WHERE p.oid = v_fn AND p.prosecdef
                   AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']) THEN
    RAISE EXCEPTION 'issue_40: function is not SECURITY DEFINER with an empty search_path; rolled back';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
             WHERE p.oid = v_fn
               AND (p.proacl IS NULL
                    OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)
                    OR pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
                    OR NOT pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'issue_40: function grants are not PUBLIC none / anon none / authenticated EXECUTE; rolled back';
  END IF;

  -- b) Trigger: BEFORE UPDATE OF role_id, is_active, FOR EACH ROW (tgtype 1 ROW + 2 BEFORE +
  --    16 UPDATE = 19), enabled (origin), right function; profiles has exactly this and audit_log.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                 WHERE t.tgrelid = 'public.profiles'::regclass AND t.tgname = 'prevent_last_admin_deactivation'
                   AND NOT t.tgisinternal AND t.tgfoid = v_fn AND t.tgtype = 19 AND t.tgenabled = 'O'
                   AND position('UPDATE OF role_id, is_active ON' IN pg_catalog.pg_get_triggerdef(t.oid)) > 0) THEN
    RAISE EXCEPTION 'issue_40: trigger missing or not as intended; rolled back';
  END IF;
  SELECT string_agg(t.tgname, ', ' ORDER BY t.tgname) INTO v_bad
  FROM pg_catalog.pg_trigger t WHERE t.tgrelid = 'public.profiles'::regclass AND NOT t.tgisinternal;
  IF v_bad IS DISTINCT FROM 'audit_log, prevent_last_admin_deactivation' THEN
    RAISE EXCEPTION 'issue_40: triggers on profiles are [%]; rolled back', v_bad;
  END IF;

  -- c) anon and PUBLIC: no privilege of any kind on the two tables or their columns.
  SELECT string_agg(DISTINCT c.relname, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  WHERE c.relnamespace = 'public'::regnamespace AND c.relname IN ('profiles', 'department_staff')
    AND (pg_catalog.has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES')
         OR pg_catalog.has_table_privilege('anon', c.oid, 'DELETE,TRUNCATE,TRIGGER')
         OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(c.relacl) a
                    LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
                    WHERE a.grantee = 0 OR r.rolname = 'anon'));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_40: anon or PUBLIC still has a privilege on %; rolled back', v_bad;
  END IF;

  -- d) authenticated, TABLE level: profiles = SELECT only; department_staff = SELECT and DELETE only.
  SELECT string_agg(DISTINCT c.relname || ':' || a.privilege_type, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  CROSS JOIN LATERAL pg_catalog.aclexplode(c.relacl) a
  JOIN pg_catalog.pg_roles r ON r.oid = a.grantee AND r.rolname = 'authenticated'
  WHERE c.relnamespace = 'public'::regnamespace
    AND ((c.relname = 'profiles' AND a.privilege_type <> 'SELECT')
         OR (c.relname = 'department_staff' AND a.privilege_type NOT IN ('SELECT', 'DELETE')));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_40: authenticated has table-level privileges beyond the intended: %; rolled back', v_bad;
  END IF;
  IF NOT (pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'SELECT')
          AND pg_catalog.has_table_privilege('authenticated', 'public.department_staff', 'SELECT')
          AND pg_catalog.has_table_privilege('authenticated', 'public.department_staff', 'DELETE')) THEN
    RAISE EXCEPTION 'issue_40: authenticated lost SELECT or DELETE it should have; rolled back';
  END IF;

  -- e) authenticated, column by column (INSERT / UPDATE), exactly as in the header.
  SELECT string_agg(e.t || '.' || e.col || ' insert=' || e.ins || ' update=' || e.upd, ', ') INTO v_bad
  FROM (VALUES
    ('profiles', 'profile_id', false, false), ('profiles', 'role_id', false, true),
    ('profiles', 'first_name', false, true), ('profiles', 'last_name', false, true),
    ('profiles', 'email', false, false), ('profiles', 'is_active', false, true),
    ('profiles', 'created_at', false, false),
    ('department_staff', 'profile_id', true, false), ('department_staff', 'department_id', true, true)) AS e(t, col, ins, upd)
  WHERE pg_catalog.has_column_privilege('authenticated', 'public.' || e.t, e.col, 'INSERT') <> e.ins
     OR pg_catalog.has_column_privilege('authenticated', 'public.' || e.t, e.col, 'UPDATE') <> e.upd;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_40: column privileges differ from the header: %; rolled back', v_bad;
  END IF;
END $$;

COMMIT;


-- ------------------------------------------
-- ROLLBACK (back to the state before this file)
-- ------------------------------------------
-- The state before: authenticated had table-level SELECT / INSERT / UPDATE / DELETE on both
-- tables (the Supabase default; section C of hardening2.sql left it, grants_snapshot_2026-10-11.txt
-- shows profiles = arwd), anon none on profiles writes (section C) and no SELECT. Compare
-- with the SAVED diagnostic (a) and restore exactly that. The usual restore:
--
-- BEGIN;
--
-- DROP TRIGGER IF EXISTS prevent_last_admin_deactivation ON public.profiles;
-- DROP FUNCTION IF EXISTS private.trg_prevent_last_admin_deactivation();
--
-- GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles, public.department_staff TO authenticated;
-- -- anon: only if saved diagnostic (a) showed anon entries; then repeat them exactly.
--
-- COMMIT;


-- ==========================================
-- DIAGNOSTICS (read-only; run one at a time and send the output back)
-- ==========================================
-- a) BEFORE and AFTER: exact ACLs of profiles and department_staff (table and column level).
-- select c.relname, c.relacl::text as table_acl,
--        (select string_agg(a.attname || '=' || a.attacl::text, '; ' order by a.attnum)
--           from pg_attribute a where a.attrelid = c.oid and a.attacl is not null) as column_acls
-- from pg_class c
-- where c.relnamespace = 'public'::regnamespace and c.relname in ('profiles', 'department_staff')
-- order by 1;
--
-- b) BEFORE: the active Admins (at least one; two or more is safer before the guard goes live).
-- select p.profile_id, p.email, p.is_active
-- from public.profiles p join public.roles r on r.role_id = p.role_id
-- where r.role_name = 'Admin' order by p.email;
--
-- c) AFTER: triggers on the two tables.
-- select c.relname, t.tgname, t.tgenabled, pg_get_triggerdef(t.oid) as definition
-- from pg_trigger t join pg_class c on c.oid = t.tgrelid
-- where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
--   and c.relname in ('profiles', 'department_staff') order by 1, 2;
--
-- d) AFTER: the function's properties and grants.
-- select p.oid::regprocedure as fn, p.prosecdef as security_definer, p.proconfig, p.proacl::text
-- from pg_proc p where p.oid = 'private.trg_prevent_last_admin_deactivation()'::regprocedure;


-- ==========================================
-- REHEARSAL / TESTS TC-147 to TC-154 (run AFTER the change is live; ends in ROLLBACK)
-- ==========================================
-- One script, one transaction that ends in ROLLBACK, ONE result row. Nothing is committed.
-- docs/database/issue_40_admin_users_rehearsal.sql is this file's change (sections 1 to 5,
-- without COMMIT) plus this block, for a run BEFORE the live change.
-- How to run: Supabase SQL editor, as postgres, a new tab, from "begin;" to "rollback;",
-- whole tab, never a selection. If it stops with an error, run "rollback;" on its own.
-- Rules as in the earlier test files: seed accounts impersonated by e-mail, no temporary
-- GRANT, everything undone by the rollback. Cells end in "-> OK" or "-> FAIL"; all_ok must
-- be true. The seed has ONE Admin (admin@pnc.test); TC-152 makes the Registrar a second one.
--
--   TC-147 installed as intended (function, trigger, grants, anon nothing)
--   TC-148 the Admin edits a profile (name, role, active); locked columns are refused
--   TC-149 the Admin cannot INSERT or DELETE a profile through the API
--   TC-150 Student and Registrar cannot change profiles or department_staff (RLS)
--   TC-151 anon is denied everything
--   TC-152 last-admin guard (Admin session, second Admin session, and postgres)
--   TC-153 the Admin inserts, updates and deletes a department_staff row
--   TC-154 the Admin's writes are in the audit log; refused ones are not

begin;

select set_config('request.jwt.claims', '', true);
select set_config('app.adm', coalesce((select id::text from auth.users where email = 'admin@pnc.test'), ''), true);
select set_config('app.s1',  coalesce((select id::text from auth.users where email = 'student1@pnc.test'), ''), true);
select set_config('app.s2',  coalesce((select id::text from auth.users where email = 'student2@pnc.test'), ''), true);
select set_config('app.reg', coalesce((select id::text from auth.users where email = 'registrar@pnc.test'), ''), true);
do $$
begin
  if '' in (current_setting('app.adm'), current_setting('app.s1'), current_setting('app.s2'), current_setting('app.reg'))
     or (select count(*) from public.profiles p join public.roles r on r.role_id = p.role_id
          where r.role_name = 'Admin' and p.is_active) <> 1
     or not exists (select 1 from public.profiles p join public.roles r on r.role_id = p.role_id
                     where p.profile_id::text = current_setting('app.adm') and r.role_name = 'Admin')
     or exists (select 1 from public.department_staff where profile_id::text = current_setting('app.s2')) then
    raise exception 'TC setup: seed accounts missing, or not exactly one active Admin, or student2 already has a department_staff row';
  end if;
end $$;
select set_config('app.log_mark', coalesce((select max(log_id)::text from public.audit_logs), '0'), true);
select set_config('app.admin_role', (select role_id::text from public.roles where role_name = 'Admin'), true);
select set_config('app.reg_role', (select role_id::text from public.roles where role_name = 'Registrar'), true);
select set_config('app.dept1', (select min(department_id)::text from public.departments), true);
select set_config('app.dept2', (select max(department_id)::text from public.departments), true);

-- TC-147
select set_config('app.r147', format('function_ok %s, trigger_ok %s, profiles_table_privs_beyond_select %s, anon_any %s, exec_authenticated %s -> %s',
  (select count(*) from pg_proc p where p.oid = 'private.trg_prevent_last_admin_deactivation()'::regprocedure and p.prosecdef),
  (select count(*) from pg_trigger t where t.tgrelid = 'public.profiles'::regclass and t.tgname = 'prevent_last_admin_deactivation' and t.tgtype = 19 and t.tgenabled = 'O'),
  (select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a join pg_roles r on r.oid = a.grantee and r.rolname = 'authenticated'
     where c.relnamespace = 'public'::regnamespace and c.relname = 'profiles' and a.privilege_type <> 'SELECT'),
  (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in ('profiles', 'department_staff')
     and (has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES') or has_table_privilege('anon', c.oid, 'DELETE,TRUNCATE,TRIGGER'))),
  has_function_privilege('authenticated', 'private.trg_prevent_last_admin_deactivation()', 'EXECUTE'),
  case when (select count(*) from pg_proc p where p.oid = 'private.trg_prevent_last_admin_deactivation()'::regprocedure and p.prosecdef) = 1
        and (select count(*) from pg_trigger t where t.tgrelid = 'public.profiles'::regclass and t.tgname = 'prevent_last_admin_deactivation' and t.tgtype = 19 and t.tgenabled = 'O') = 1
        and (select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a join pg_roles r on r.oid = a.grantee and r.rolname = 'authenticated'
               where c.relnamespace = 'public'::regnamespace and c.relname = 'profiles' and a.privilege_type <> 'SELECT') = 0
        and (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in ('profiles', 'department_staff')
               and (has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES') or has_table_privilege('anon', c.oid, 'DELETE,TRUNCATE,TRIGGER'))) = 0
        and has_function_privilege('authenticated', 'private.trg_prevent_last_admin_deactivation()', 'EXECUTE')
       then 'OK' else 'FAIL' end), true);

-- TC-148 + TC-149 (Admin session)
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.adm'), 'role', 'authenticated')::text, true);
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 't148_names',  $q$update public.profiles set first_name = 'Z40first', last_name = 'Z40last' where profile_id = current_setting('app.s2')::uuid$q$),
    (2, 't148_off',    $q$update public.profiles set is_active = false where profile_id = current_setting('app.s2')::uuid$q$),
    (3, 't148_on',     $q$update public.profiles set is_active = true where profile_id = current_setting('app.s2')::uuid$q$),
    (4, 't148_role',   $q$update public.profiles set role_id = current_setting('app.reg_role')::smallint where profile_id = current_setting('app.s2')::uuid$q$),
    (5, 't148_email',  $q$update public.profiles set email = 'x@x.test' where profile_id = current_setting('app.s2')::uuid$q$),
    (6, 't148_pk',     $q$update public.profiles set profile_id = gen_random_uuid() where profile_id = current_setting('app.s2')::uuid$q$),
    (7, 't148_created',$q$update public.profiles set created_at = now() where profile_id = current_setting('app.s2')::uuid$q$),
    (8, 't149_ins',    $q$insert into public.profiles (profile_id, role_id, first_name, last_name, email) values (gen_random_uuid(), 1, 'a', 'b', 'z40@x.test')$q$),
    (9, 't149_del',    $q$delete from public.profiles where profile_id = current_setting('app.s2')::uuid$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt; get diagnostics n = row_count;
      perform set_config('app.' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: ' when sqlerrm like 'new row violates row-level security%' then 'rls: '
             else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r148', format('names %s, off %s, on %s, role %s; email/pk/created_at %s/%s/%s -> %s',
  current_setting('app.t148_names'), current_setting('app.t148_off'), current_setting('app.t148_on'), current_setting('app.t148_role'),
  left(current_setting('app.t148_email'), 7), left(current_setting('app.t148_pk'), 7), left(current_setting('app.t148_created'), 7),
  case when current_setting('app.t148_names') = 'rows 1' and current_setting('app.t148_off') = 'rows 1'
        and current_setting('app.t148_on') = 'rows 1' and current_setting('app.t148_role') = 'rows 1'
        and current_setting('app.t148_email') like 'denied: %' and current_setting('app.t148_pk') like 'denied: %'
        and current_setting('app.t148_created') like 'denied: %'
        and (select first_name || ' ' || last_name from public.profiles where profile_id::text = current_setting('app.s2')) = 'Z40first Z40last'
       then 'OK' else 'FAIL' end), true);
select set_config('app.r149', format('insert %s, delete %s -> %s',
  left(current_setting('app.t149_ins'), 7), left(current_setting('app.t149_del'), 7),
  case when current_setting('app.t149_ins') like 'denied: %' and current_setting('app.t149_del') like 'denied: %'
        and exists (select 1 from public.profiles where profile_id::text = current_setting('app.s2')) then 'OK' else 'FAIL' end), true);

-- TC-150 (Student 1, then Registrar; neither is Admin at this point)
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.s1'), 'role', 'authenticated')::text, true);
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 'upd_self',  $q$update public.profiles set first_name = 'Hacked' where profile_id = current_setting('app.s1')::uuid$q$),
    (2, 'upd_other', $q$update public.profiles set is_active = false where profile_id = current_setting('app.s2')::uuid$q$),
    (3, 'ins_ds',    $q$insert into public.department_staff (profile_id, department_id) values (current_setting('app.s1')::uuid, current_setting('app.dept1')::bigint)$q$),
    (4, 'del_ds',    $q$delete from public.department_staff$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt; get diagnostics n = row_count;
      perform set_config('app.t150s_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t150s_' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: ' when sqlerrm like 'new row violates row-level security%' then 'rls: '
             else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.reg'), 'role', 'authenticated')::text, true);
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 'upd_self',  $q$update public.profiles set first_name = 'Hacked' where profile_id = current_setting('app.reg')::uuid$q$),
    (2, 'upd_admin', $q$update public.profiles set is_active = false where profile_id = current_setting('app.adm')::uuid$q$),
    (3, 'ins_ds',    $q$insert into public.department_staff (profile_id, department_id) values (current_setting('app.reg')::uuid, current_setting('app.dept1')::bigint)$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt; get diagnostics n = row_count;
      perform set_config('app.t150r_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t150r_' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: ' when sqlerrm like 'new row violates row-level security%' then 'rls: '
             else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r150', format('student: self %s, other %s, ins %s, del %s; registrar: self %s, admin %s, ins %s -> %s',
  current_setting('app.t150s_upd_self'), current_setting('app.t150s_upd_other'), left(current_setting('app.t150s_ins_ds'), 4), current_setting('app.t150s_del_ds'),
  current_setting('app.t150r_upd_self'), current_setting('app.t150r_upd_admin'), left(current_setting('app.t150r_ins_ds'), 4),
  case when current_setting('app.t150s_upd_self') = 'rows 0' and current_setting('app.t150s_upd_other') = 'rows 0'
        and current_setting('app.t150s_ins_ds') like 'rls: %' and current_setting('app.t150s_del_ds') = 'rows 0'
        and current_setting('app.t150r_upd_self') = 'rows 0' and current_setting('app.t150r_upd_admin') = 'rows 0'
        and current_setting('app.t150r_ins_ds') like 'rls: %'
        and (select is_active from public.profiles where profile_id::text = current_setting('app.adm'))
       then 'OK' else 'FAIL' end), true);

-- TC-151 anon
set local role anon;
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 'sel_prof', $q$select count(*) from public.profiles$q$),
    (2, 'sel_ds',   $q$select count(*) from public.department_staff$q$),
    (3, 'upd_prof', $q$update public.profiles set is_active = false$q$),
    (4, 'ins_ds',   $q$insert into public.department_staff (profile_id, department_id) values (gen_random_uuid(), 1)$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt; get diagnostics n = row_count;
      perform set_config('app.t151_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t151_' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: ' else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('app.r151', format('%s of 4 denied -> %s',
  (select count(*) from unnest(array['sel_prof', 'sel_ds', 'upd_prof', 'ins_ds']) x where current_setting('app.t151_' || x) like 'denied: %'),
  case when (select count(*) from unnest(array['sel_prof', 'sel_ds', 'upd_prof', 'ins_ds']) x where current_setting('app.t151_' || x) like 'denied: %') = 4
       then 'OK' else 'FAIL' end), true);

-- TC-152 last-admin guard. Session 1: the Admin.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.adm'), 'role', 'authenticated')::text, true);
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 'a_off_self',  $q$update public.profiles set is_active = false where profile_id = current_setting('app.adm')::uuid$q$),
    (2, 'b_role_self', $q$update public.profiles set role_id = current_setting('app.reg_role')::smallint where profile_id = current_setting('app.adm')::uuid$q$),
    (3, 'c_promote',   $q$update public.profiles set role_id = current_setting('app.admin_role')::smallint where profile_id = current_setting('app.reg')::uuid$q$),
    (4, 'd_off_reg',   $q$update public.profiles set is_active = false where profile_id = current_setting('app.reg')::uuid$q$),
    (5, 'e_on_reg',    $q$update public.profiles set is_active = true where profile_id = current_setting('app.reg')::uuid$q$),
    (6, 'f0_name_self',$q$update public.profiles set first_name = first_name where profile_id = current_setting('app.adm')::uuid$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt; get diagnostics n = row_count;
      perform set_config('app.t152_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t152_' || r.label,
        case when sqlerrm like 'last admin:%' then 'blocked [' || sqlstate || ']: ' else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
-- Session 2: the Registrar, now an Admin too.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.reg'), 'role', 'authenticated')::text, true);
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 'f_off_adm',  $q$update public.profiles set is_active = false where profile_id = current_setting('app.adm')::uuid$q$),
    (2, 'g_off_self', $q$update public.profiles set is_active = false where profile_id = current_setting('app.reg')::uuid$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt; get diagnostics n = row_count;
      perform set_config('app.t152_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t152_' || r.label,
        case when sqlerrm like 'last admin:%' then 'blocked [' || sqlstate || ']: ' else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
-- Session 3: postgres (no JWT): the guard applies to every role.
do $$
begin
  begin
    update public.profiles set is_active = false where profile_id = current_setting('app.reg')::uuid;
    perform set_config('app.t152_h_postgres', 'rows', true);
  exception when others then
    perform set_config('app.t152_h_postgres', case when sqlerrm like 'last admin:%' then 'blocked [' || sqlstate || ']: ' else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
  end;
end $$;
select set_config('app.r152', format('a %s, b %s, c %s, d %s, e %s, f %s, g %s, h %s, active admins %s -> %s',
  left(current_setting('app.t152_a_off_self'), 18), left(current_setting('app.t152_b_role_self'), 18), current_setting('app.t152_c_promote'),
  current_setting('app.t152_d_off_reg'), current_setting('app.t152_e_on_reg'), current_setting('app.t152_f_off_adm'),
  left(current_setting('app.t152_g_off_self'), 18), left(current_setting('app.t152_h_postgres'), 18),
  (select count(*) from public.profiles p where p.role_id = current_setting('app.admin_role')::smallint and p.is_active),
  case when current_setting('app.t152_a_off_self') like 'blocked [P0001]: last admin:%'
        and current_setting('app.t152_b_role_self') like 'blocked [P0001]: last admin:%'
        and current_setting('app.t152_c_promote') = 'rows 1' and current_setting('app.t152_d_off_reg') = 'rows 1'
        and current_setting('app.t152_e_on_reg') = 'rows 1' and current_setting('app.t152_f0_name_self') = 'rows 1'
        and current_setting('app.t152_f_off_adm') = 'rows 1'
        and current_setting('app.t152_g_off_self') like 'blocked [P0001]: last admin:%'
        and current_setting('app.t152_h_postgres') like 'blocked [P0001]: last admin:%'
        and (select count(*) from public.profiles p where p.role_id = current_setting('app.admin_role')::smallint and p.is_active) = 1
       then 'OK' else 'FAIL' end), true);

-- TC-153 department_staff (Admin session: the original Admin is inactive now, so use the second Admin)
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('app.reg'), 'role', 'authenticated')::text, true);
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 'ins',    $q$insert into public.department_staff (profile_id, department_id) values (current_setting('app.s2')::uuid, current_setting('app.dept1')::bigint)$q$),
    (2, 'upd',    $q$update public.department_staff set department_id = current_setting('app.dept2')::bigint where profile_id = current_setting('app.s2')::uuid$q$),
    (3, 'upd_pk', $q$update public.department_staff set profile_id = current_setting('app.s1')::uuid where profile_id = current_setting('app.s2')::uuid$q$),
    (4, 'del',    $q$delete from public.department_staff where profile_id = current_setting('app.s2')::uuid$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt; get diagnostics n = row_count;
      perform set_config('app.t153_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t153_' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: ' else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r153', format('ins %s, upd %s, upd_pk %s, del %s -> %s',
  current_setting('app.t153_ins'), current_setting('app.t153_upd'), left(current_setting('app.t153_upd_pk'), 7), current_setting('app.t153_del'),
  case when current_setting('app.t153_ins') = 'rows 1' and current_setting('app.t153_upd') = 'rows 1'
        and current_setting('app.t153_upd_pk') like 'denied: %' and current_setting('app.t153_del') = 'rows 1'
        and not exists (select 1 from public.department_staff where profile_id::text = current_setting('app.s2'))
       then 'OK' else 'FAIL' end), true);

-- TC-154 audit
select set_config('app.r154', (select format('profiles updates by Admins %s, other-actor rows %s, dept_staff i%s u%s d%s, refused changes logged %s -> %s',
  a.p_upd, a.other, a.d_ins, a.d_upd, a.d_del, a.refused,
  case when a.p_upd >= 5 and a.other = 0 and a.d_ins = 1 and a.d_upd = 1 and a.d_del = 1 and a.refused = 0 then 'OK' else 'FAIL' end)
  from (select
    count(*) filter (where l.table_name = 'profiles' and l.action = 'UPDATE' and l.actor_id in (current_setting('app.adm')::uuid, current_setting('app.reg')::uuid)) as p_upd,
    count(*) filter (where l.actor_id is null or l.actor_id not in (current_setting('app.adm')::uuid, current_setting('app.reg')::uuid)) as other,
    count(*) filter (where l.table_name = 'department_staff' and l.action = 'INSERT') as d_ins,
    count(*) filter (where l.table_name = 'department_staff' and l.action = 'UPDATE') as d_upd,
    count(*) filter (where l.table_name = 'department_staff' and l.action = 'DELETE') as d_del,
    count(*) filter (where l.table_name = 'profiles' and l.new_data ->> 'first_name' = 'Hacked') as refused
    from public.audit_logs l where l.log_id > current_setting('app.log_mark')::bigint) a), true);

select (current_setting('app.r147') like '%-> OK' and current_setting('app.r148') like '%-> OK'
        and current_setting('app.r149') like '%-> OK' and current_setting('app.r150') like '%-> OK'
        and current_setting('app.r151') like '%-> OK' and current_setting('app.r152') like '%-> OK'
        and current_setting('app.r153') like '%-> OK' and current_setting('app.r154') like '%-> OK') as all_ok,
  current_setting('app.r147') as tc147, current_setting('app.r148') as tc148, current_setting('app.r149') as tc149,
  current_setting('app.r150') as tc150, current_setting('app.r151') as tc151, current_setting('app.r152') as tc152,
  current_setting('app.r153') as tc153, current_setting('app.r154') as tc154;

rollback;
