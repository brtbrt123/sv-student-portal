-- ==========================================
-- ACADEMIC CATALOG: DATA API GRANTS, INTEGRITY RULES, AUDIT (GitHub issue 39, REQ-ADM-04)
-- ==========================================
-- The Admin maintains the academic catalog (departments, programs, terms, subjects,
-- sections). SEC-02 (least privilege), REQ-ADM-03 (audit). Pattern: grades_rules.sql.
-- Runs AFTER hardening.sql, hardening2.sql (A, B, C) and enrollment_rules.sql (all live).
--
-- WHAT IT DOES
--   1. Integrity rules on public.terms and public.sections (added only if missing):
--        uq_terms_one_current_term  UNIQUE (is_current) WHERE is_current   (one current term)
--        terms_dates_order          CHECK (start_date < end_date)
--        sections.capacity > 0      already live as the inline CHECK sections_capacity_check
--                                   (schema.sql); this file only verifies it is there and
--                                   adds sections_capacity_positive if some project lost it.
--   2. Audit triggers (REQ-ADM-03): trigger audit_log, AFTER INSERT OR UPDATE OR DELETE FOR
--      EACH ROW, calling private.audit_log('<primary key column>') on departments,
--      programs, terms, subjects and sections. Not audited before this file (hardening2.sql
--      section B covers 12 other tables).
--   3. Grants, to the role authenticated only (REVOKE ALL first, so the result does not
--      depend on what was there):
--        SELECT  on all 5 tables
--        INSERT / UPDATE on the columns below. No DELETE, no TRUNCATE, no table-level
--        INSERT / UPDATE, NOTHING for anon and nothing for PUBLIC.
--        table        INSERT (columns)                                        UPDATE (columns)
--        departments  code, name, department_type                             code, name
--        programs     department_id, code, name                               code, name
--        terms        school_year, semester, start_date, end_date, is_current same as INSERT
--        subjects     department_id, code, title, units                       code, title, units
--        sections     subject_id, term_id, section_code, schedule, capacity   section_code, schedule, capacity
--      The identity key columns are never granted (GENERATED ALWAYS AS IDENTITY).
--   Already in place and NOT changed here (checked in section 1):
--     - RLS is enabled on the 5 tables, with <table>_read (SELECT, every signed-in user)
--       and <table>_admin (FOR ALL, Admin only) policies (rls.sql).
--
-- DESIGN DECISIONS
--   1. "Admin only" = grants to authenticated + RLS. All signed-in users share the database
--      role authenticated, so the column grants open the columns to every signed-in user
--      and the <table>_admin policies decide who may write: only an active Admin. A
--      Student, Registrar, Cashier or Department user can read the catalog and gets "new
--      row violates row-level security policy" on INSERT and changes 0 rows on UPDATE.
--      Same approach as grants_clearance.sql and grades_rules.sql.
--   2. Rule for UPDATE: a column that links a row to another catalog row (programs.
--      department_id, subjects.department_id, sections.subject_id, sections.term_id) is set
--      when the row is created and cannot be changed through the API. Moving a section to
--      another term or subject would break enrollment items that point at it (the
--      enrollment rules check the term of the section), and moving a program to another
--      department changes which department's holds apply to its students (hardening2.sql
--      section A). To move one, delete-and-recreate is also unavailable (no DELETE), so the
--      Backend team does it in the SQL editor in a reviewed change.
--   3. departments.department_type is INSERT only. private.my_department_id() maps the
--      Cashier to "the Financial department" (LIMIT 1) and clearance items are created per
--      department type; changing the type of a live department would re-classify existing
--      clearance items and a Cashier's office. Fix a wrong type in the SQL editor.
--   4. No DELETE grant on any catalog table: rows are referenced by enrollments, clearance
--      items, charges and holds, so a catalog row is retired, never removed.
--   5. One current term: only one row may have is_current = true, enforced by a partial
--      unique index (PostgreSQL has no partial unique CONSTRAINT; the index is the
--      mechanism). To change the current term the app must clear the old one FIRST and then
--      set the new one, as two statements (a single UPDATE of both rows can fail depending
--      on the order the rows are checked).
--   6. Names of the objects: the issue calls the audit trigger function trg_audit_log. The
--      live function is private.audit_log() and the trigger is called audit_log on every
--      table (hardening2.sql B); this file reuses both so there is one audit mechanism.
--   7. The app's server-side admin client is untouched: this file only revokes from
--      PUBLIC, anon and authenticated.
--
-- KNOWN LIMITS (not done here, on purpose)
--   - Lowering sections.capacity below the number of already approved enrollments is not
--     blocked (the seat check runs when an enrollment is approved).
--   - A second Financial department is not blocked (my_department_id() would pick one).
--   - A term can be made current even if its dates are in the past (no rule in the SRS).
--
-- How to run: Supabase SQL editor, as postgres. Copy from "BEGIN;" to "COMMIT;" inclusive
-- into a new tab and run that tab as a whole (never a partial selection). One transaction:
-- any error, including a failed check, rolls back everything. Re-runnable.
--   - Before running: run diagnostics (a), (b) and (c) at the bottom and SAVE the output.
--     (c) must return no rows, or the checks in section 1 stop the run.
--   - Rehearse first: docs/database/issue_39_catalog_grants_rehearsal.sql runs this change
--     and the tests below in ONE rolled-back transaction.
-- Test AFTER: the rehearsal block at the bottom of this file (TC-139 to TC-146).
-- Undo: the ROLLBACK block after COMMIT.
--
-- Status: NOT RUN LIVE YET. Tested 2026-10-13 on a local PostgreSQL 16 rebuilt from schema.sql,
-- views.sql, seed.sql, private_functions.sql, rls.sql, hardening.sql and hardening2.sql (with
-- a stand-in for auth.users / auth.uid() and Supabase-style default grants): the change ran
-- clean, a second run was clean too, TC-139 to TC-146 pass (all_ok true), the rehearsal file
-- leaves the database unchanged, a second current term in the data stops the run in section
-- 1, and the ROLLBACK block restored the old grants. NOT yet rehearsed on the live project
-- (PostgreSQL 17); do that first.


BEGIN;

-- ------------------------------------------
-- 1. Safety checks (stop before changing anything)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
BEGIN
  -- a) The 5 tables exist and RLS is enabled on them.
  SELECT string_agg(e.name, ', ') INTO v_bad
  FROM (VALUES ('departments'), ('programs'), ('terms'), ('subjects'), ('sections')) AS e(name)
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                    WHERE c.relnamespace = 'public'::regnamespace AND c.relname = e.name
                      AND c.relkind::text = 'r' AND c.relrowsecurity);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: missing table or RLS not enabled: %; stop', v_bad;
  END IF;

  -- b) Every column used by the constraints, triggers and grants exists with this type.
  SELECT string_agg(e.t || '.' || e.col || ' ' || e.typ, ', ') INTO v_bad
  FROM (VALUES
    ('departments', 'department_id', 'bigint'), ('departments', 'code', 'character varying'),
    ('departments', 'name', 'character varying'), ('departments', 'department_type', 'character varying'),
    ('programs', 'program_id', 'bigint'), ('programs', 'department_id', 'bigint'),
    ('programs', 'code', 'character varying'), ('programs', 'name', 'character varying'),
    ('terms', 'term_id', 'bigint'), ('terms', 'school_year', 'character varying'),
    ('terms', 'semester', 'character varying'), ('terms', 'start_date', 'date'),
    ('terms', 'end_date', 'date'), ('terms', 'is_current', 'boolean'),
    ('subjects', 'subject_id', 'bigint'), ('subjects', 'department_id', 'bigint'),
    ('subjects', 'code', 'character varying'), ('subjects', 'title', 'character varying'),
    ('subjects', 'units', 'smallint'),
    ('sections', 'section_id', 'bigint'), ('sections', 'subject_id', 'bigint'),
    ('sections', 'term_id', 'bigint'), ('sections', 'section_code', 'character varying'),
    ('sections', 'schedule', 'character varying'), ('sections', 'capacity', 'smallint')) AS e(t, col, typ)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = pg_catalog.to_regclass('public.' || e.t)
      AND a.attname = e.col AND a.attnum > 0 AND NOT a.attisdropped
      AND pg_catalog.format_type(a.atttypid, NULL) = e.typ);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: missing column or other type: %; stop', v_bad;
  END IF;

  -- c) The policies are the reviewed ones (rls.sql): <t>_read = SELECT for everyone signed
  --    in, <t>_admin = ALL and Admin only (USING and WITH CHECK), all PERMISSIVE, TO
  --    authenticated. The grants below rely on them.
  SELECT string_agg(e.t, ', ') INTO v_bad
  FROM (VALUES ('departments'), ('programs'), ('terms'), ('subjects'), ('sections')) AS e(t)
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
                    WHERE p.schemaname = 'public' AND p.tablename = e.t AND p.policyname = e.t || '_read'
                      AND p.cmd = 'SELECT' AND p.permissive = 'PERMISSIVE'
                      AND p.roles = ARRAY['authenticated']::name[])
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
                    WHERE p.schemaname = 'public' AND p.tablename = e.t AND p.policyname = e.t || '_admin'
                      AND p.cmd = 'ALL' AND p.permissive = 'PERMISSIVE'
                      AND p.roles = ARRAY['authenticated']::name[]
                      AND position('''Admin''' IN coalesce(p.qual, '')) > 0
                      AND position('''Admin''' IN coalesce(p.with_check, '')) > 0);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: policies on % differ from the reviewed set (<t>_read, <t>_admin); stop', v_bad;
  END IF;
  SELECT string_agg(p.tablename || '.' || p.policyname, ', ') INTO v_bad
  FROM pg_catalog.pg_policies p
  WHERE p.schemaname = 'public' AND p.tablename IN ('departments', 'programs', 'terms', 'subjects', 'sections')
    AND p.policyname NOT IN (p.tablename || '_read', p.tablename || '_admin');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: unexpected extra policy: %; stop and review', v_bad;
  END IF;

  -- d) The audit function and table exist, and no DIFFERENT trigger called audit_log sits on
  --    the 5 tables (the generic function also checks the key column when it fires).
  IF pg_catalog.to_regprocedure('private.audit_log()') IS NULL
     OR pg_catalog.to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'issue_39: private.audit_log() or public.audit_logs is missing (hardening2.sql section B); stop';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
             WHERE t.tgname = 'audit_log' AND NOT t.tgisinternal
               AND t.tgrelid IN ('public.departments'::regclass, 'public.programs'::regclass,
                                 'public.terms'::regclass, 'public.subjects'::regclass,
                                 'public.sections'::regclass)
               AND t.tgfoid <> 'private.audit_log()'::pg_catalog.regprocedure) THEN
    RAISE EXCEPTION 'issue_39: a different trigger named audit_log exists on a catalog table; stop and review';
  END IF;

  -- e) No other trigger sits on the 5 tables (the expected set afterwards is audit_log only).
  SELECT string_agg(c.relname || '.' || t.tgname, ', ') INTO v_bad
  FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
  WHERE NOT t.tgisinternal AND t.tgname <> 'audit_log'
    AND c.relnamespace = 'public'::regnamespace
    AND c.relname IN ('departments', 'programs', 'terms', 'subjects', 'sections');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: unexpected trigger(s) on catalog tables: %; stop and review', v_bad;
  END IF;

  -- f) Existing rows already follow the new rules (otherwise the constraints cannot be added).
  IF (SELECT count(*) FROM public.terms WHERE is_current) > 1 THEN
    RAISE EXCEPTION 'issue_39: more than one term has is_current = true (term_id: %); fix the data first',
      (SELECT string_agg(term_id::text, ', ') FROM public.terms WHERE is_current);
  END IF;
  SELECT string_agg(term_id::text, ', ') INTO v_bad FROM public.terms WHERE NOT (start_date < end_date);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: terms with start_date >= end_date (term_id: %); fix the data first', v_bad;
  END IF;
  SELECT string_agg(section_id::text, ', ') INTO v_bad FROM public.sections WHERE NOT (capacity > 0);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: sections with capacity <= 0 (section_id: %); fix the data first', v_bad;
  END IF;

  -- g) If something called uq_terms_one_current_term already exists it must be the intended
  --    index, otherwise CREATE ... IF NOT EXISTS below would skip it silently.
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c
             WHERE c.relnamespace = 'public'::regnamespace AND c.relname = 'uq_terms_one_current_term')
     AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_indexes i
                     WHERE i.schemaname = 'public' AND i.tablename = 'terms'
                       AND i.indexname = 'uq_terms_one_current_term'
                       AND i.indexdef LIKE 'CREATE UNIQUE INDEX%(is_current)%WHERE%is_current%') THEN
    RAISE EXCEPTION 'issue_39: uq_terms_one_current_term exists but is not a partial unique index on terms (is_current); stop and review';
  END IF;
END $$;

-- ------------------------------------------
-- 2. Integrity rules (added only if missing)
-- ------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_terms_one_current_term
  ON public.terms (is_current) WHERE is_current;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                 WHERE k.conrelid = 'public.terms'::regclass AND k.contype = 'c'
                   AND pg_catalog.pg_get_constraintdef(k.oid) ~ 'start_date\s*<\s*end_date') THEN
    ALTER TABLE public.terms ADD CONSTRAINT terms_dates_order CHECK (start_date < end_date);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                 WHERE k.conrelid = 'public.sections'::regclass AND k.contype = 'c'
                   AND pg_catalog.pg_get_constraintdef(k.oid) ~ 'capacity\s*>\s*0') THEN
    ALTER TABLE public.sections ADD CONSTRAINT sections_capacity_positive CHECK (capacity > 0);
  END IF;
END $$;

-- ------------------------------------------
-- 3. Audit triggers (REQ-ADM-03). Argument = the primary key column, checked by the function.
-- ------------------------------------------
DROP TRIGGER IF EXISTS audit_log ON public.departments;
CREATE TRIGGER audit_log AFTER INSERT OR UPDATE OR DELETE ON public.departments
  FOR EACH ROW EXECUTE FUNCTION private.audit_log('department_id');

DROP TRIGGER IF EXISTS audit_log ON public.programs;
CREATE TRIGGER audit_log AFTER INSERT OR UPDATE OR DELETE ON public.programs
  FOR EACH ROW EXECUTE FUNCTION private.audit_log('program_id');

DROP TRIGGER IF EXISTS audit_log ON public.terms;
CREATE TRIGGER audit_log AFTER INSERT OR UPDATE OR DELETE ON public.terms
  FOR EACH ROW EXECUTE FUNCTION private.audit_log('term_id');

DROP TRIGGER IF EXISTS audit_log ON public.subjects;
CREATE TRIGGER audit_log AFTER INSERT OR UPDATE OR DELETE ON public.subjects
  FOR EACH ROW EXECUTE FUNCTION private.audit_log('subject_id');

DROP TRIGGER IF EXISTS audit_log ON public.sections;
CREATE TRIGGER audit_log AFTER INSERT OR UPDATE OR DELETE ON public.sections
  FOR EACH ROW EXECUTE FUNCTION private.audit_log('section_id');

-- ------------------------------------------
-- 4. Grants (authenticated only). RLS decides who may write (design decision 1).
-- ------------------------------------------
-- REVOKE on a table also removes its column grants, so this starts from nothing.
REVOKE ALL ON public.departments, public.programs, public.terms, public.subjects, public.sections
  FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.departments, public.programs, public.terms, public.subjects, public.sections
  TO authenticated;

GRANT INSERT (code, name, department_type) ON public.departments TO authenticated;
GRANT UPDATE (code, name)                  ON public.departments TO authenticated;

GRANT INSERT (department_id, code, name)   ON public.programs TO authenticated;
GRANT UPDATE (code, name)                  ON public.programs TO authenticated;

GRANT INSERT (school_year, semester, start_date, end_date, is_current) ON public.terms TO authenticated;
GRANT UPDATE (school_year, semester, start_date, end_date, is_current) ON public.terms TO authenticated;

GRANT INSERT (department_id, code, title, units) ON public.subjects TO authenticated;
GRANT UPDATE (code, title, units)                 ON public.subjects TO authenticated;

GRANT INSERT (subject_id, term_id, section_code, schedule, capacity) ON public.sections TO authenticated;
GRANT UPDATE (section_code, schedule, capacity)                      ON public.sections TO authenticated;

-- ------------------------------------------
-- 5. Checks after the change (any failure rolls back the whole file)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
BEGIN
  -- a) anon and PUBLIC: no privilege of any kind, on the tables or on any column.
  SELECT string_agg(DISTINCT c.relname, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  WHERE c.relnamespace = 'public'::regnamespace
    AND c.relname IN ('departments', 'programs', 'terms', 'subjects', 'sections')
    AND (pg_catalog.has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES')
         OR pg_catalog.has_table_privilege('anon', c.oid, 'DELETE,TRUNCATE,TRIGGER')
         OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(c.relacl) a
                    LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
                    WHERE a.grantee = 0 OR r.rolname = 'anon'));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: anon or PUBLIC still has a privilege on %; rolled back', v_bad;
  END IF;

  -- b) authenticated: the only TABLE-level privilege is SELECT (so no DELETE, TRUNCATE,
  --    REFERENCES, TRIGGER, MAINTAIN, and no table-level INSERT / UPDATE).
  SELECT string_agg(DISTINCT c.relname || ':' || a.privilege_type, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  CROSS JOIN LATERAL pg_catalog.aclexplode(c.relacl) a
  JOIN pg_catalog.pg_roles r ON r.oid = a.grantee AND r.rolname = 'authenticated'
  WHERE c.relnamespace = 'public'::regnamespace
    AND c.relname IN ('departments', 'programs', 'terms', 'subjects', 'sections')
    AND a.privilege_type <> 'SELECT';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: authenticated has table-level privileges beyond SELECT: %; rolled back', v_bad;
  END IF;
  SELECT string_agg(e.t, ', ') INTO v_bad
  FROM (VALUES ('departments'), ('programs'), ('terms'), ('subjects'), ('sections')) AS e(t)
  WHERE NOT pg_catalog.has_table_privilege('authenticated', 'public.' || e.t, 'SELECT');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: authenticated lost SELECT on %; rolled back', v_bad;
  END IF;

  -- c) authenticated: INSERT / UPDATE column by column, exactly as in the header table.
  SELECT string_agg(e.t || '.' || e.col || ' insert=' || e.ins || ' update=' || e.upd, ', ') INTO v_bad
  FROM (VALUES
    ('departments', 'department_id', false, false), ('departments', 'code', true, true),
    ('departments', 'name', true, true), ('departments', 'department_type', true, false),
    ('programs', 'program_id', false, false), ('programs', 'department_id', true, false),
    ('programs', 'code', true, true), ('programs', 'name', true, true),
    ('terms', 'term_id', false, false), ('terms', 'school_year', true, true),
    ('terms', 'semester', true, true), ('terms', 'start_date', true, true),
    ('terms', 'end_date', true, true), ('terms', 'is_current', true, true),
    ('subjects', 'subject_id', false, false), ('subjects', 'department_id', true, false),
    ('subjects', 'code', true, true), ('subjects', 'title', true, true), ('subjects', 'units', true, true),
    ('sections', 'section_id', false, false), ('sections', 'subject_id', true, false),
    ('sections', 'term_id', true, false), ('sections', 'section_code', true, true),
    ('sections', 'schedule', true, true), ('sections', 'capacity', true, true)) AS e(t, col, ins, upd)
  WHERE pg_catalog.has_column_privilege('authenticated', 'public.' || e.t, e.col, 'INSERT') <> e.ins
     OR pg_catalog.has_column_privilege('authenticated', 'public.' || e.t, e.col, 'UPDATE') <> e.upd;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: column privileges differ from the header table: %; rolled back', v_bad;
  END IF;

  -- d) The integrity rules are in place.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_indexes i
                 WHERE i.schemaname = 'public' AND i.tablename = 'terms'
                   AND i.indexname = 'uq_terms_one_current_term'
                   AND i.indexdef LIKE 'CREATE UNIQUE INDEX%(is_current)%WHERE%is_current%') THEN
    RAISE EXCEPTION 'issue_39: uq_terms_one_current_term is not the partial unique index; rolled back';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                 WHERE k.conrelid = 'public.terms'::regclass AND k.contype = 'c' AND k.convalidated
                   AND pg_catalog.pg_get_constraintdef(k.oid) ~ 'start_date\s*<\s*end_date')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.sections'::regclass AND k.contype = 'c' AND k.convalidated
                      AND pg_catalog.pg_get_constraintdef(k.oid) ~ 'capacity\s*>\s*0') THEN
    RAISE EXCEPTION 'issue_39: the term date check or the section capacity check is missing; rolled back';
  END IF;

  -- e) Exactly one trigger on each table: audit_log, AFTER ROW INSERT OR UPDATE OR DELETE
  --    (tgtype 1 ROW + 4 INSERT + 8 DELETE + 16 UPDATE = 29), enabled (origin), right
  --    function, the table's primary key column as its argument.
  SELECT string_agg(e.t, ', ') INTO v_bad
  FROM (VALUES ('departments', 'department_id'), ('programs', 'program_id'), ('terms', 'term_id'),
               ('subjects', 'subject_id'), ('sections', 'section_id')) AS e(t, pk)
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger tg
                    WHERE tg.tgrelid = pg_catalog.to_regclass('public.' || e.t)
                      AND tg.tgname = 'audit_log' AND NOT tg.tgisinternal
                      AND tg.tgfoid = 'private.audit_log()'::pg_catalog.regprocedure
                      AND tg.tgtype = 29 AND tg.tgenabled = 'O'
                      AND position('audit_log(''' || e.pk || ''')' IN pg_catalog.pg_get_triggerdef(tg.oid)) > 0)
     OR (SELECT count(*) FROM pg_catalog.pg_trigger tg
         WHERE tg.tgrelid = pg_catalog.to_regclass('public.' || e.t) AND NOT tg.tgisinternal) <> 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'issue_39: audit trigger missing or not as intended on %; rolled back', v_bad;
  END IF;
END $$;

COMMIT;


-- ------------------------------------------
-- ROLLBACK (back to the state before this file)
-- ------------------------------------------
-- The state before: authenticated had full table-level SELECT / INSERT / UPDATE / DELETE
-- on the 5 tables (the Supabase default; only TRUNCATE, REFERENCES, TRIGGER, MAINTAIN were
-- revoked by hardening2.sql section C), and anon may still have had INSERT / UPDATE /
-- DELETE (section C only removed SELECT from anon). Compare with the SAVED diagnostic (a)
-- and restore exactly that. The usual restore:
--
-- BEGIN;
--
-- DROP TRIGGER IF EXISTS audit_log ON public.departments;
-- DROP TRIGGER IF EXISTS audit_log ON public.programs;
-- DROP TRIGGER IF EXISTS audit_log ON public.terms;
-- DROP TRIGGER IF EXISTS audit_log ON public.subjects;
-- DROP TRIGGER IF EXISTS audit_log ON public.sections;
--
-- -- Drop a rule only if saved diagnostic (b) showed it did NOT exist before this file:
-- DROP INDEX IF EXISTS public.uq_terms_one_current_term;
-- ALTER TABLE public.terms    DROP CONSTRAINT IF EXISTS terms_dates_order;
-- ALTER TABLE public.sections DROP CONSTRAINT IF EXISTS sections_capacity_positive;
--
-- GRANT SELECT, INSERT, UPDATE, DELETE ON public.departments, public.programs, public.terms,
--   public.subjects, public.sections TO authenticated;
-- -- anon: only if saved diagnostic (a) showed anon entries; then repeat them exactly.
--
-- COMMIT;


-- ==========================================
-- DIAGNOSTICS (read-only; run one at a time and send the output back)
-- ==========================================
-- a) BEFORE and AFTER: exact ACLs of the 5 tables (table and column level). Save the BEFORE.
-- select c.relname, c.relacl::text as table_acl,
--        (select string_agg(a.attname || '=' || a.attacl::text, '; ' order by a.attnum)
--           from pg_attribute a where a.attrelid = c.oid and a.attacl is not null) as column_acls
-- from pg_class c
-- where c.relnamespace = 'public'::regnamespace
--   and c.relname in ('departments', 'programs', 'terms', 'subjects', 'sections')
-- order by 1;
--
-- b) BEFORE and AFTER: indexes and CHECK constraints that this file adds or relies on.
-- select 'index' as kind, indexname as name, indexdef as definition from pg_indexes
-- where schemaname = 'public' and tablename = 'terms'
-- union all
-- select 'check', conrelid::regclass::text || '.' || conname, pg_get_constraintdef(oid)
-- from pg_constraint
-- where contype = 'c' and conrelid in ('public.terms'::regclass, 'public.sections'::regclass)
-- order by 1, 2;
--
-- c) BEFORE: rows that break a new rule (must return no rows).
-- select 'more than one current term' as problem, term_id::text as id from public.terms
--   where is_current and (select count(*) from public.terms where is_current) > 1
-- union all select 'start_date >= end_date', term_id::text from public.terms where not (start_date < end_date)
-- union all select 'capacity <= 0', section_id::text from public.sections where not (capacity > 0);
--
-- d) AFTER: triggers on the 5 tables.
-- select c.relname, t.tgname, t.tgenabled, pg_get_triggerdef(t.oid) as definition
-- from pg_trigger t join pg_class c on c.oid = t.tgrelid
-- where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
--   and c.relname in ('departments', 'programs', 'terms', 'subjects', 'sections')
-- order by 1, 2;


-- ==========================================
-- REHEARSAL / TESTS TC-139 to TC-146 (run AFTER the change is live; ends in ROLLBACK)
-- ==========================================
-- One script, one transaction that ends in ROLLBACK, ONE result row. Nothing is committed.
-- docs/database/issue_39_catalog_grants_rehearsal.sql is this file's change (sections 1 to
-- 5, without COMMIT) plus this block, for a run BEFORE the live change.
--
-- How to run: Supabase SQL editor, as postgres, a new tab. Paste from "begin;" (below) to
-- "rollback;" and click Run on the whole tab, never a selection. If the script stops with
-- an error, run "rollback;" as its own query and send the error back.
--
-- Rules (same as the earlier test files): the seed accounts are impersonated by e-mail
-- ("set local role authenticated" or anon, and request.jwt.claims via set_config(..., true));
-- no temporary GRANT; the script creates its own throwaway rows (codes starting with Z39,
-- school year 2091-2092) as the Admin, undone by the rollback. Expected errors are caught
-- inside do blocks and shown as text: "denied: ..." = permission denied (grants),
-- "rls: ..." = row-level security, "unique [23505]: ..." and "check [23514]: ..." =
-- constraint, "rows N" = the statement ran and changed N rows. Every cell ends in "-> OK"
-- or "-> FAIL"; all_ok must be true.
--
-- Cases:
--   TC-139 installed as intended (index, checks, 5 audit triggers, grants, anon nothing)
--   TC-140 the Admin inserts and updates a row in each of the 5 tables
--   TC-141 the Admin cannot DELETE, and cannot change the locked columns
--   TC-142 Student and Registrar read the catalog and cannot write it (RLS)
--   TC-143 anon is denied everything
--   TC-144 a second current term is refused; clearing the old one first then works
--   TC-145 bad term dates and capacity 0 are refused (insert and update)
--   TC-146 the Admin's writes are in the audit log (actor = the Admin)

begin;

-- ==========================================
-- Setup (as postgres, no user JWT; undone by the rollback)
-- ==========================================
select set_config('request.jwt.claims', '', true);
select set_config('app.adm', coalesce((select id::text from auth.users where email = 'admin@pnc.test'), ''), true);
select set_config('app.s1',  coalesce((select id::text from auth.users where email = 'student1@pnc.test'), ''), true);
select set_config('app.reg', coalesce((select id::text from auth.users where email = 'registrar@pnc.test'), ''), true);
do $$
begin
  if '' in (current_setting('app.adm'), current_setting('app.s1'), current_setting('app.reg'))
     or not exists (select 1 from public.profiles p join public.roles r on r.role_id = p.role_id
                     where p.profile_id::text = current_setting('app.adm') and p.is_active and r.role_name = 'Admin')
     or not exists (select 1 from public.terms where is_current)
     or exists (select 1 from public.departments where code like 'Z39%')
     or exists (select 1 from public.terms where school_year = '2091-2092') then
    raise exception 'TC setup: seed accounts missing, no current term, or throwaway rows (Z39, 2091-2092) already exist';
  end if;
end $$;
select set_config('app.log_mark', coalesce((select max(log_id)::text from public.audit_logs), '0'), true);
select set_config('app.cur_term', (select term_id::text from public.terms where is_current), true);

-- ==========================================
-- TC-139: installed as intended (as postgres)
-- ==========================================
select set_config('app.r139', format(
  'unique_index %s, date_check %s, capacity_check %s, audit_triggers %s/5, auth_table_privs_beyond_select %s, anon_any %s -> %s',
  (select count(*) from pg_indexes where schemaname = 'public' and tablename = 'terms'
     and indexname = 'uq_terms_one_current_term' and indexdef like 'CREATE UNIQUE INDEX%(is_current)%WHERE%is_current%'),
  (select count(*) from pg_constraint where conrelid = 'public.terms'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ~ 'start_date\s*<\s*end_date'),
  (select count(*) from pg_constraint where conrelid = 'public.sections'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ~ 'capacity\s*>\s*0'),
  (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid
     where not t.tgisinternal and t.tgname = 'audit_log' and t.tgtype = 29 and c.relnamespace = 'public'::regnamespace
       and c.relname in ('departments', 'programs', 'terms', 'subjects', 'sections')),
  (select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a
     join pg_roles r on r.oid = a.grantee and r.rolname = 'authenticated'
     where c.relnamespace = 'public'::regnamespace and c.relname in ('departments', 'programs', 'terms', 'subjects', 'sections')
       and a.privilege_type <> 'SELECT'),
  (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace
     and c.relname in ('departments', 'programs', 'terms', 'subjects', 'sections')
     and (has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES')
          or has_table_privilege('anon', c.oid, 'DELETE,TRUNCATE,TRIGGER'))),
  case when (select count(*) from pg_indexes where schemaname = 'public' and tablename = 'terms'
               and indexname = 'uq_terms_one_current_term' and indexdef like 'CREATE UNIQUE INDEX%(is_current)%WHERE%is_current%') = 1
        and (select count(*) from pg_constraint where conrelid = 'public.terms'::regclass and contype = 'c'
               and pg_get_constraintdef(oid) ~ 'start_date\s*<\s*end_date') >= 1
        and (select count(*) from pg_constraint where conrelid = 'public.sections'::regclass and contype = 'c'
               and pg_get_constraintdef(oid) ~ 'capacity\s*>\s*0') >= 1
        and (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid
               where not t.tgisinternal and t.tgname = 'audit_log' and t.tgtype = 29 and c.relnamespace = 'public'::regnamespace
                 and c.relname in ('departments', 'programs', 'terms', 'subjects', 'sections')) = 5
        and (select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a
               join pg_roles r on r.oid = a.grantee and r.rolname = 'authenticated'
               where c.relnamespace = 'public'::regnamespace and c.relname in ('departments', 'programs', 'terms', 'subjects', 'sections')
                 and a.privilege_type <> 'SELECT') = 0
        and (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace
               and c.relname in ('departments', 'programs', 'terms', 'subjects', 'sections')
               and (has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES')
                    or has_table_privilege('anon', c.oid, 'DELETE,TRUNCATE,TRIGGER'))) = 0
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- TC-140: the Admin inserts and updates a row in each table
-- ==========================================
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.adm'), 'role', 'authenticated')::text, true);
do $$
declare
  r record;
  n bigint;
begin
  for r in select * from (values
    (1, 't140_dep_ins',  $q$insert into public.departments (code, name, department_type) values ('Z39', 'Test 39', 'Academic')$q$),
    (2, 't140_dep_upd',  $q$update public.departments set name = 'Test 39b' where code = 'Z39'$q$),
    (3, 't140_prg_ins',  $q$insert into public.programs (department_id, code, name) select department_id, 'Z39P', 'Prog 39' from public.departments where code = 'Z39'$q$),
    (4, 't140_prg_upd',  $q$update public.programs set name = 'Prog 39b' where code = 'Z39P'$q$),
    (5, 't140_trm_ins',  $q$insert into public.terms (school_year, semester, start_date, end_date, is_current) values ('2091-2092', '1st', '2091-08-01', '2092-01-15', false)$q$),
    (6, 't140_trm_upd',  $q$update public.terms set end_date = '2092-01-20' where school_year = '2091-2092'$q$),
    (7, 't140_sub_ins',  $q$insert into public.subjects (department_id, code, title, units) select department_id, 'Z39S', 'Subject 39', 3 from public.departments where code = 'Z39'$q$),
    (8, 't140_sub_upd',  $q$update public.subjects set units = 4 where code = 'Z39S'$q$),
    (9, 't140_sec_ins',  $q$insert into public.sections (subject_id, term_id, section_code, schedule, capacity) select s.subject_id, t.term_id, 'Z39A', 'MWF 8-9', 30 from public.subjects s, public.terms t where s.code = 'Z39S' and t.school_year = '2091-2092'$q$),
    (10, 't140_sec_upd', $q$update public.sections set capacity = 35 where section_code = 'Z39A'$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      get diagnostics n = row_count;
      perform set_config('app.' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: '
             when sqlerrm like 'new row violates row-level security%' then 'rls: '
             when sqlstate = '23505' then 'unique [23505]: ' when sqlstate = '23514' then 'check [23514]: '
             else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r140', format('dep %s/%s, prg %s/%s, trm %s/%s, sub %s/%s, sec %s/%s -> %s',
  current_setting('app.t140_dep_ins'), current_setting('app.t140_dep_upd'),
  current_setting('app.t140_prg_ins'), current_setting('app.t140_prg_upd'),
  current_setting('app.t140_trm_ins'), current_setting('app.t140_trm_upd'),
  current_setting('app.t140_sub_ins'), current_setting('app.t140_sub_upd'),
  current_setting('app.t140_sec_ins'), current_setting('app.t140_sec_upd'),
  case when (select bool_and(current_setting('app.t140_' || x) = 'rows 1')
             from unnest(array['dep_ins', 'dep_upd', 'prg_ins', 'prg_upd', 'trm_ins', 'trm_upd',
                               'sub_ins', 'sub_upd', 'sec_ins', 'sec_upd']) as x)
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- TC-141: the Admin cannot DELETE and cannot change the locked columns
-- ==========================================
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.adm'), 'role', 'authenticated')::text, true);
do $$
declare
  r record;
  n bigint;
begin
  for r in select * from (values
    (1, 't141_del_dep', $q$delete from public.departments where code = 'Z39'$q$),
    (2, 't141_del_prg', $q$delete from public.programs where code = 'Z39P'$q$),
    (3, 't141_del_trm', $q$delete from public.terms where school_year = '2091-2092'$q$),
    (4, 't141_del_sub', $q$delete from public.subjects where code = 'Z39S'$q$),
    (5, 't141_del_sec', $q$delete from public.sections where section_code = 'Z39A'$q$),
    (6, 't141_dep_type', $q$update public.departments set department_type = 'Financial' where code = 'Z39'$q$),
    (7, 't141_prg_dep',  $q$update public.programs set department_id = (select min(department_id) from public.departments) where code = 'Z39P'$q$),
    (8, 't141_sub_dep',  $q$update public.subjects set department_id = (select min(department_id) from public.departments) where code = 'Z39S'$q$),
    (9, 't141_sec_trm',  $q$update public.sections set term_id = current_setting('app.cur_term')::bigint where section_code = 'Z39A'$q$),
    (10, 't141_sec_sub', $q$update public.sections set subject_id = (select min(subject_id) from public.subjects) where section_code = 'Z39A'$q$),
    (11, 't141_pk',      $q$update public.departments set department_id = 999999 where code = 'Z39'$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      get diagnostics n = row_count;
      perform set_config('app.' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: '
             when sqlstate = '428C9' then 'denied: identity ' -- GENERATED ALWAYS key: refused before the grant check
             else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r141', format('%s of 11 denied, rows still there: dep %s prg %s trm %s sub %s sec %s, type %s -> %s',
  (select count(*) from unnest(array['del_dep', 'del_prg', 'del_trm', 'del_sub', 'del_sec', 'dep_type', 'prg_dep',
                                      'sub_dep', 'sec_trm', 'sec_sub', 'pk']) as x
    where current_setting('app.t141_' || x) like 'denied: %'),
  (select count(*) from public.departments where code = 'Z39'), (select count(*) from public.programs where code = 'Z39P'),
  (select count(*) from public.terms where school_year = '2091-2092'), (select count(*) from public.subjects where code = 'Z39S'),
  (select count(*) from public.sections where section_code = 'Z39A'),
  (select department_type from public.departments where code = 'Z39'),
  case when (select count(*) from unnest(array['del_dep', 'del_prg', 'del_trm', 'del_sub', 'del_sec', 'dep_type', 'prg_dep',
                                                'sub_dep', 'sec_trm', 'sec_sub', 'pk']) as x
              where current_setting('app.t141_' || x) like 'denied: %') = 11
        and (select count(*) from public.departments where code = 'Z39') = 1
        and (select count(*) from public.sections where section_code = 'Z39A') = 1
        and (select department_type from public.departments where code = 'Z39') = 'Academic'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- TC-142: Student 1 and the Registrar read the catalog and cannot write it
-- ==========================================
select set_config('app.who', 's1', true);
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.s1'), 'role', 'authenticated')::text, true);
do $$
declare
  r record;
  n bigint;
begin
  for r in select * from (values
    (1, 'read', $q$select count(*) from public.departments d, public.programs p, public.terms t, public.subjects s, public.sections c$q$),
    (2, 'ins_dep', $q$insert into public.departments (code, name, department_type) values ('Z39X', 'Nope', 'Academic')$q$),
    (3, 'ins_trm', $q$insert into public.terms (school_year, semester, start_date, end_date, is_current) values ('2095-2096', '1st', '2095-08-01', '2096-01-15', false)$q$),
    (4, 'upd_dep', $q$update public.departments set name = 'Hacked' where code = 'Z39'$q$),
    (5, 'upd_sec', $q$update public.sections set capacity = 1 where section_code = 'Z39A'$q$),
    (6, 'upd_trm', $q$update public.terms set is_current = false where is_current$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      get diagnostics n = row_count;
      perform set_config('app.t142s_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t142s_' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: ' when sqlerrm like 'new row violates row-level security%' then 'rls: '
             else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.reg'), 'role', 'authenticated')::text, true);
do $$
declare
  r record;
  n bigint;
begin
  for r in select * from (values
    (1, 'read', $q$select count(*) from public.departments d, public.programs p, public.terms t, public.subjects s, public.sections c$q$),
    (2, 'ins_dep', $q$insert into public.departments (code, name, department_type) values ('Z39X', 'Nope', 'Academic')$q$),
    (3, 'upd_dep', $q$update public.departments set name = 'Hacked' where code = 'Z39'$q$),
    (4, 'upd_sec', $q$update public.sections set capacity = 1 where section_code = 'Z39A'$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      get diagnostics n = row_count;
      perform set_config('app.t142r_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t142r_' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: ' when sqlerrm like 'new row violates row-level security%' then 'rls: '
             else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r142', format('student read %s, ins %s/%s, upd %s/%s/%s; registrar read %s, ins %s, upd %s/%s -> %s',
  current_setting('app.t142s_read'), current_setting('app.t142s_ins_dep'), current_setting('app.t142s_ins_trm'),
  current_setting('app.t142s_upd_dep'), current_setting('app.t142s_upd_sec'), current_setting('app.t142s_upd_trm'),
  current_setting('app.t142r_read'), current_setting('app.t142r_ins_dep'),
  current_setting('app.t142r_upd_dep'), current_setting('app.t142r_upd_sec'),
  case when current_setting('app.t142s_read') like 'rows 1' and current_setting('app.t142r_read') like 'rows 1'
        and current_setting('app.t142s_ins_dep') like 'rls: %' and current_setting('app.t142s_ins_trm') like 'rls: %'
        and current_setting('app.t142s_upd_dep') = 'rows 0' and current_setting('app.t142s_upd_sec') = 'rows 0'
        and current_setting('app.t142s_upd_trm') = 'rows 0'
        and current_setting('app.t142r_ins_dep') like 'rls: %'
        and current_setting('app.t142r_upd_dep') = 'rows 0' and current_setting('app.t142r_upd_sec') = 'rows 0'
        and (select name from public.departments where code = 'Z39') = 'Test 39b'
        and (select count(*) from public.terms where is_current) = 1
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- TC-143: anon is denied everything
-- ==========================================
set local role anon;
do $$
declare
  r record;
  n bigint;
begin
  for r in select * from (values
    (1, 'sel_dep', $q$select count(*) from public.departments$q$),
    (2, 'sel_prg', $q$select count(*) from public.programs$q$),
    (3, 'sel_trm', $q$select count(*) from public.terms$q$),
    (4, 'sel_sub', $q$select count(*) from public.subjects$q$),
    (5, 'sel_sec', $q$select count(*) from public.sections$q$),
    (6, 'ins_dep', $q$insert into public.departments (code, name, department_type) values ('Z39Y', 'Nope', 'Academic')$q$),
    (7, 'upd_trm', $q$update public.terms set is_current = false$q$),
    (8, 'del_sec', $q$delete from public.sections$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      get diagnostics n = row_count;
      perform set_config('app.t143_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t143_' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: ' else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('app.r143', format('%s of 8 denied -> %s',
  (select count(*) from unnest(array['sel_dep', 'sel_prg', 'sel_trm', 'sel_sub', 'sel_sec', 'ins_dep', 'upd_trm', 'del_sec']) as x
    where current_setting('app.t143_' || x) like 'denied: %'),
  case when (select count(*) from unnest(array['sel_dep', 'sel_prg', 'sel_trm', 'sel_sub', 'sel_sec', 'ins_dep', 'upd_trm', 'del_sec']) as x
              where current_setting('app.t143_' || x) like 'denied: %') = 8 then 'OK' else 'FAIL' end), true);

-- ==========================================
-- TC-144: one current term (Admin session)
-- ==========================================
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.adm'), 'role', 'authenticated')::text, true);
do $$
declare
  r record;
  n bigint;
begin
  for r in select * from (values
    (1, 'second_current', $q$insert into public.terms (school_year, semester, start_date, end_date, is_current) values ('2093-2094', '1st', '2093-08-01', '2094-01-15', true)$q$),
    (2, 'set_without_clear', $q$update public.terms set is_current = true where school_year = '2091-2092'$q$),
    (3, 'clear_old', $q$update public.terms set is_current = false where term_id = current_setting('app.cur_term')::bigint$q$),
    (4, 'set_new', $q$update public.terms set is_current = true where school_year = '2091-2092'$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      get diagnostics n = row_count;
      perform set_config('app.t144_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t144_' || r.label,
        case when sqlerrm like 'permission denied%' then 'denied: ' when sqlstate = '23505' then 'unique [23505]: '
             else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r144', format('second_current [%s], set_without_clear [%s], clear_old %s, set_new %s, current terms %s -> %s',
  split_part(current_setting('app.t144_second_current'), ' (', 1), split_part(current_setting('app.t144_set_without_clear'), ' (', 1),
  current_setting('app.t144_clear_old'), current_setting('app.t144_set_new'), (select count(*) from public.terms where is_current),
  case when current_setting('app.t144_second_current') like 'unique [23505]: %uq_terms_one_current_term%'
        and current_setting('app.t144_set_without_clear') like 'unique [23505]: %uq_terms_one_current_term%'
        and current_setting('app.t144_clear_old') = 'rows 1' and current_setting('app.t144_set_new') = 'rows 1'
        and (select count(*) from public.terms where is_current) = 1
        and (select school_year from public.terms where is_current) = '2091-2092'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- TC-145: bad term dates and capacity 0 are refused (Admin session)
-- ==========================================
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.adm'), 'role', 'authenticated')::text, true);
do $$
declare
  r record;
  n bigint;
begin
  for r in select * from (values
    (1, 'trm_equal',  $q$insert into public.terms (school_year, semester, start_date, end_date, is_current) values ('2097-2098', '1st', '2097-08-01', '2097-08-01', false)$q$),
    (2, 'trm_back',   $q$insert into public.terms (school_year, semester, start_date, end_date, is_current) values ('2097-2098', '2nd', '2098-01-15', '2097-08-01', false)$q$),
    (3, 'trm_upd',    $q$update public.terms set end_date = start_date where school_year = '2091-2092'$q$),
    (4, 'sec_zero',   $q$insert into public.sections (subject_id, term_id, section_code, schedule, capacity) select s.subject_id, t.term_id, 'Z39B', 'TTh 8-9', 0 from public.subjects s, public.terms t where s.code = 'Z39S' and t.school_year = '2091-2092'$q$),
    (5, 'sec_upd0',   $q$update public.sections set capacity = 0 where section_code = 'Z39A'$q$),
    (6, 'sec_neg',    $q$update public.sections set capacity = -5 where section_code = 'Z39A'$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      get diagnostics n = row_count;
      perform set_config('app.t145_' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.t145_' || r.label,
        case when sqlstate = '23514' then 'check [23514]: ' else 'ERROR [' || sqlstate || ']: ' end || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r145', format('%s of 6 refused (check), capacity now %s -> %s',
  (select count(*) from unnest(array['trm_equal', 'trm_back', 'trm_upd', 'sec_zero', 'sec_upd0', 'sec_neg']) as x
    where current_setting('app.t145_' || x) like 'check [23514]: %'),
  (select capacity from public.sections where section_code = 'Z39A'),
  case when (select count(*) from unnest(array['trm_equal', 'trm_back', 'trm_upd', 'sec_zero', 'sec_upd0', 'sec_neg']) as x
              where current_setting('app.t145_' || x) like 'check [23514]: %') = 6
        and (select capacity from public.sections where section_code = 'Z39A') = 35
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- TC-146: the Admin's writes are in the audit log
-- ==========================================
select set_config('app.r146', (select format('%s -> %s',
  string_agg(format('%s i%s u%s', a.table_name, a.ins, a.upd), ', ' order by a.table_name),
  case when count(*) = 5 and bool_and(a.ins = 1 and a.upd >= 1 and a.other = 0) then 'OK' else 'FAIL' end)
  from (select l.table_name,
               count(*) filter (where l.action = 'INSERT' and l.actor_id = current_setting('app.adm')::uuid) as ins,
               count(*) filter (where l.action = 'UPDATE' and l.actor_id = current_setting('app.adm')::uuid) as upd,
               count(*) filter (where l.actor_id is distinct from current_setting('app.adm')::uuid) as other
        from public.audit_logs l
        where l.log_id > current_setting('app.log_mark')::bigint
          and l.table_name in ('departments', 'programs', 'terms', 'subjects', 'sections')
        group by l.table_name) a), true);

-- ==========================================
-- Result: ONE row. Every cell must end in "-> OK"; all_ok must be true.
-- ==========================================
select (current_setting('app.r139') like '%-> OK' and current_setting('app.r140') like '%-> OK'
        and current_setting('app.r141') like '%-> OK' and current_setting('app.r142') like '%-> OK'
        and current_setting('app.r143') like '%-> OK' and current_setting('app.r144') like '%-> OK'
        and current_setting('app.r145') like '%-> OK' and current_setting('app.r146') like '%-> OK') as all_ok,
  current_setting('app.r139') as tc139, current_setting('app.r140') as tc140, current_setting('app.r141') as tc141,
  current_setting('app.r142') as tc142, current_setting('app.r143') as tc143, current_setting('app.r144') as tc144,
  current_setting('app.r145') as tc145, current_setting('app.r146') as tc146;

rollback;
