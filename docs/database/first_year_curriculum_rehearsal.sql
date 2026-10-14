-- ==========================================
-- REHEARSAL: first_year_curriculum.sql + TC-234 to TC-247 in ONE rolled-back transaction
-- ==========================================
-- Auto first-year enrollment (feature/auto-first-year). One paste, one run, ONE result row,
-- nothing committed. Run this on the live project BEFORE the live change; it must leave no
-- trace.
--
-- How to run: Supabase SQL editor, as postgres, a new tab, at a quiet time (ALTER TABLE
-- locks public.applications until the rollback, a few seconds). Paste the whole file (from
-- "begin;" to "rollback;") and click Run on the whole tab, never a selection. If the script
-- stops with an error, run "rollback;" as its own query and send the error back.
--
-- What it does:
--   1. begin;
--   2. the body of docs/database/first_year_curriculum.sql (everything between its "BEGIN;"
--      and "COMMIT;" lines, copied verbatim by a script: safety checks, table, sample data,
--      applicant_type column, submit_application replaced, create_first_year_enrollment,
--      grants, checks after the change and its result row; the NOTIFY is never sent because
--      of the rollback). A "first_year_curriculum: ..." error here means the live state is
--      not what the file assumes: do NOT run the file live; send the error back.
--   3. TC-234 to TC-247 (docs/database/first_year_curriculum_test.sql from its "begin;"
--      line, verbatim; that second "begin;" only prints a harmless WARNING "there is already
--      a transaction in progress"). The tests switch the current term to a throwaway
--      2088-2089 term and create throwaway sections, enrollments and applications.
--   4. One final row: all_ok, then one cell per case, each ending in "-> OK" or "-> FAIL".
--   5. rollback; (the table, the column, the sample subjects / sections, the new functions,
--      the grants and all test data disappear; the old submit_application is back. Identity
--      values used inside the transaction are not given back: a few subject / section /
--      enrollment / audit ids are skipped, which is harmless.)
--
-- RUNNING ONLY THE TESTS (after the change is live): the test part starts at the line
-- "-- TESTS START HERE" and is self-contained: copy from the "begin;" line right below that
-- marker to the end of the file into a new tab and run it (or run
-- docs/database/first_year_curriculum_test.sql, which is the same). It ends in rollback.

begin;

-- ==========================================
-- THE CHANGE (body of first_year_curriculum.sql, verbatim)
-- ==========================================

-- ------------------------------------------
-- 1. Safety checks (stop before changing anything)
-- ------------------------------------------
DO $$
DECLARE
  v_bad  text;
  v_n    integer;
  v_srv  text := 'service' || '_role';
  v_old  regprocedure := pg_catalog.to_regprocedure('public.submit_application(text, text, text, text, bigint)');
  v_new  regprocedure := pg_catalog.to_regprocedure('public.submit_application(text, text, text, text, bigint, text)');
  v_fn   regprocedure;
  v_src  text;
BEGIN
  IF current_setting('server_version_num')::int < 170000 THEN
    RAISE EXCEPTION 'first_year_curriculum: PostgreSQL 17+ expected (REVOKE ALL includes MAINTAIN); found %', current_setting('server_version');
  END IF;

  -- a) The tables exist.
  SELECT string_agg(e.t, ', ') INTO v_bad
  FROM (VALUES ('departments'), ('programs'), ('terms'), ('subjects'), ('sections'), ('students'),
               ('profiles'), ('enrollments'), ('enrollment_items'), ('applications'), ('audit_logs')) AS e(t)
  WHERE pg_catalog.to_regclass('public.' || e.t) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'first_year_curriculum: missing table(s) public.%; stop', v_bad;
  END IF;

  -- b) The columns used here exist with these types (format_type with a NULL typmod).
  SELECT string_agg(e.t || '.' || e.col || ' ' || e.typ, ', ') INTO v_bad
  FROM (VALUES
    ('departments', 'department_id', 'bigint'), ('departments', 'code', 'character varying'),
    ('programs', 'program_id', 'bigint'), ('programs', 'code', 'character varying'),
    ('terms', 'term_id', 'bigint'), ('terms', 'semester', 'character varying'),
    ('terms', 'is_current', 'boolean'),
    ('subjects', 'subject_id', 'bigint'), ('subjects', 'department_id', 'bigint'),
    ('subjects', 'code', 'character varying'), ('subjects', 'title', 'character varying'),
    ('subjects', 'units', 'smallint'),
    ('sections', 'section_id', 'bigint'), ('sections', 'subject_id', 'bigint'),
    ('sections', 'term_id', 'bigint'), ('sections', 'section_code', 'character varying'),
    ('sections', 'schedule', 'character varying'), ('sections', 'capacity', 'smallint'),
    ('students', 'student_id', 'uuid'), ('students', 'program_id', 'bigint'),
    ('enrollments', 'enrollment_id', 'bigint'), ('enrollments', 'student_id', 'uuid'),
    ('enrollments', 'term_id', 'bigint'), ('enrollments', 'year_level', 'smallint'),
    ('enrollments', 'status', 'character varying'),
    ('enrollment_items', 'enrollment_item_id', 'bigint'), ('enrollment_items', 'enrollment_id', 'bigint'),
    ('enrollment_items', 'section_id', 'bigint'),
    ('applications', 'application_id', 'bigint'), ('applications', 'email', 'character varying'),
    ('applications', 'program_id', 'bigint'), ('applications', 'mobile', 'character varying')) AS e(t, col, typ)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = pg_catalog.to_regclass('public.' || e.t)
      AND a.attname = e.col AND a.attnum > 0 AND NOT a.attisdropped
      AND pg_catalog.format_type(a.atttypid, NULL) = e.typ);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'first_year_curriculum: missing column or other type: %; stop', v_bad;
  END IF;

  -- c) The enrollment rules (enrollment_rules.sql) are installed and enabled: the function
  --    relies on them. enrollments BEFORE INSERT OR UPDATE ROW = 23, enrollment_items BEFORE
  --    INSERT OR UPDATE OR DELETE ROW = 31.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                 WHERE t.tgrelid = 'public.enrollments'::pg_catalog.regclass
                   AND t.tgname = 'require_enrollment_rules' AND NOT t.tgisinternal
                   AND t.tgfoid = pg_catalog.to_regprocedure('private.require_enrollment_rules()')
                   AND t.tgtype = 23 AND t.tgenabled = 'O')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid = 'public.enrollment_items'::pg_catalog.regclass
                      AND t.tgname = 'require_enrollment_item_rules' AND NOT t.tgisinternal
                      AND t.tgfoid = pg_catalog.to_regprocedure('private.require_enrollment_item_rules()')
                      AND t.tgtype = 31 AND t.tgenabled = 'O') THEN
    RAISE EXCEPTION 'first_year_curriculum: the enrollment triggers require_enrollment_rules / require_enrollment_item_rules are missing, disabled or not as in enrollment_rules.sql; stop';
  END IF;

  -- d) One enrollment per student per term is enforced by a unique key.
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_index i
    WHERE i.indrelid = 'public.enrollments'::pg_catalog.regclass AND i.indisunique
      AND i.indpred IS NULL AND i.indexprs IS NULL AND i.indnatts = 2
      AND (SELECT array_agg(a.attname::text ORDER BY a.attname::text)
             FROM pg_catalog.unnest(i.indkey::int2[]) AS k(attnum)
             JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum)
          = ARRAY['student_id', 'term_id']) THEN
    RAISE EXCEPTION 'first_year_curriculum: no unique key on enrollments (student_id, term_id); run enrollment_rules.sql first; stop';
  END IF;

  -- e) Exactly one current term.
  SELECT pg_catalog.count(*) INTO v_n FROM public.terms t WHERE t.is_current;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'first_year_curriculum: % current terms found, exactly 1 expected (the sample sections go into it); stop', v_n;
  END IF;

  -- f) The programs, departments and the existing GE101 subject.
  SELECT string_agg(e.what, ', ') INTO v_bad
  FROM (SELECT 'program ' || v.code AS what FROM (VALUES ('BSCS'), ('BSIT'), ('BSBA')) AS v(code)
         WHERE NOT EXISTS (SELECT 1 FROM public.programs p WHERE p.code::text = v.code)
        UNION ALL
        SELECT 'department ' || v.code FROM (VALUES ('CCS'), ('CBA'), ('CAS')) AS v(code)
         WHERE NOT EXISTS (SELECT 1 FROM public.departments d WHERE d.code::text = v.code)
        UNION ALL
        SELECT 'subject GE101' WHERE NOT EXISTS (SELECT 1 FROM public.subjects s WHERE s.code::text = 'GE101')) e;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'first_year_curriculum: missing %; stop', v_bad;
  END IF;

  -- g) subjects.code is unique (ON CONFLICT (code) below needs a unique index on exactly it).
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_index i
    WHERE i.indrelid = 'public.subjects'::pg_catalog.regclass AND i.indisunique
      AND i.indpred IS NULL AND i.indexprs IS NULL AND i.indnatts = 1
      AND (SELECT a.attname::text FROM pg_catalog.pg_attribute a
            WHERE a.attrelid = i.indrelid AND a.attnum = i.indkey[0]) = 'code') THEN
    RAISE EXCEPTION 'first_year_curriculum: no unique index on subjects (code); stop';
  END IF;

  -- h) No unique index on sections that includes section_code without subject_id (a new
  --    section 'A' per subject would collide with it).
  SELECT string_agg(ic.relname::text, ', ') INTO v_bad
  FROM pg_catalog.pg_index i
  JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
  WHERE i.indrelid = 'public.sections'::pg_catalog.regclass AND i.indisunique AND NOT i.indisprimary
    AND EXISTS (SELECT 1 FROM pg_catalog.unnest(i.indkey::int2[]) AS k(attnum)
                JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                WHERE a.attname = 'section_code')
    AND NOT EXISTS (SELECT 1 FROM pg_catalog.unnest(i.indkey::int2[]) AS k(attnum)
                    JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                    WHERE a.attname = 'subject_id');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'first_year_curriculum: unique index(es) % on sections cover section_code without subject_id; section ''A'' per subject would collide; stop and review', v_bad;
  END IF;

  -- i) program_curriculum: absent (first run) or exactly this file's shape (re-run).
  IF pg_catalog.to_regclass('public.program_curriculum') IS NOT NULL THEN
    WITH expected(col, typ) AS (VALUES ('program_id', 'bigint'), ('year_level', 'smallint'),
                                       ('semester', 'text'), ('subject_id', 'bigint')),
    live AS (
      SELECT a.attname::text AS col, pg_catalog.format_type(a.atttypid, NULL) AS typ
      FROM pg_catalog.pg_attribute a
      WHERE a.attrelid = 'public.program_curriculum'::pg_catalog.regclass AND a.attnum > 0 AND NOT a.attisdropped)
    SELECT string_agg(d, '; ') INTO v_bad FROM (
      (SELECT 'missing ' || col || ' ' || typ AS d FROM (SELECT * FROM expected EXCEPT SELECT * FROM live) m)
      UNION ALL
      (SELECT 'unexpected ' || col || ' ' || typ FROM (SELECT * FROM live EXCEPT SELECT * FROM expected) u)) dd;
    IF v_bad IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                      WHERE k.conrelid = 'public.program_curriculum'::pg_catalog.regclass AND k.contype = 'p'
                        AND (SELECT array_agg(a.attname::text ORDER BY a.attname::text)
                               FROM pg_catalog.unnest(k.conkey) AS c(attnum)
                               JOIN pg_catalog.pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = c.attnum)
                            = ARRAY['program_id', 'semester', 'subject_id', 'year_level']) THEN
      RAISE EXCEPTION 'first_year_curriculum: public.program_curriculum exists with another shape (% / primary key); stop and review', coalesce(v_bad, 'columns ok');
    END IF;
  END IF;

  -- j) applications.applicant_type: absent (first run) or text NOT NULL DEFAULT 'New' (re-run).
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
             WHERE a.attrelid = 'public.applications'::pg_catalog.regclass
               AND a.attname = 'applicant_type' AND NOT a.attisdropped)
     AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                     JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                     WHERE a.attrelid = 'public.applications'::pg_catalog.regclass
                       AND a.attname = 'applicant_type' AND NOT a.attisdropped AND a.attnotnull
                       AND pg_catalog.format_type(a.atttypid, NULL) = 'text'
                       AND pg_catalog.pg_get_expr(d.adbin, d.adrelid) = '''New''::text') THEN
    RAISE EXCEPTION 'first_year_curriculum: applications.applicant_type exists but is not text NOT NULL DEFAULT ''New''; stop and review';
  END IF;

  -- k) submit_application: exactly one of the two signatures, no other overload, the live
  --    body is the applications_rules.sql body (markers), EXECUTE: PUBLIC none, anon and
  --    authenticated yes.
  IF (v_old IS NULL) = (v_new IS NULL) THEN
    RAISE EXCEPTION 'first_year_curriculum: expected exactly one of submit_application(5 args) / submit_application(6 args); found old % / new %; stop',
      v_old IS NOT NULL, v_new IS NOT NULL;
  END IF;
  v_fn := coalesce(v_old, v_new);
  SELECT pg_catalog.count(*) INTO v_n FROM pg_catalog.pg_proc p
  WHERE p.pronamespace = 'public'::pg_catalog.regnamespace AND p.proname = 'submit_application';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'first_year_curriculum: % functions named public.submit_application exist, 1 expected; stop', v_n;
  END IF;
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p WHERE p.oid = v_fn;
  IF NOT (v_src LIKE '%private.application_name(p_first_name, ''first_name'')%'
          AND v_src LIKE '%private.application_email(p_email)%'
          AND v_src LIKE '%private.application_mobile(p_mobile)%'
          AND v_src LIKE '%try later:%'
          AND v_src LIKE '%pg_advisory_xact_lock(pg_catalog.hashtextextended(''applications:'' || v_email, 0))%'
          AND v_src LIKE '%auth.users%'
          AND v_src LIKE '%s.per_email_window) >= s.max_per_email%'
          AND v_src LIKE '%INSERT INTO public.applications (first_name, last_name, email, mobile, program_id%')
     OR (v_new IS NOT NULL AND v_src NOT LIKE '%applicant_type%') THEN
    RAISE EXCEPTION 'first_year_curriculum: the live body of % differs from applications_rules.sql (markers missing); it would be overwritten; stop and review', v_fn;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid = v_fn
               AND (p.proacl IS NULL
                    OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)))
     OR NOT pg_catalog.has_function_privilege('anon', v_fn, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'first_year_curriculum: % grants are not PUBLIC none / anon EXECUTE / authenticated EXECUTE; stop and review', v_fn;
  END IF;
  IF pg_catalog.to_regprocedure('private.application_settings()') IS NULL THEN
    RAISE EXCEPTION 'first_year_curriculum: private.application_settings() is missing; stop';
  END IF;

  -- l) create_first_year_enrollment: absent, or only the (uuid) version returning bigint.
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
             WHERE p.pronamespace = 'public'::pg_catalog.regnamespace AND p.proname = 'create_first_year_enrollment'
               AND (p.oid IS DISTINCT FROM pg_catalog.to_regprocedure('public.create_first_year_enrollment(uuid)')::oid
                    OR p.prorettype <> 'pg_catalog.int8'::pg_catalog.regtype)) THEN
    RAISE EXCEPTION 'first_year_curriculum: another public.create_first_year_enrollment exists (other arguments or result); stop and review';
  END IF;

  -- m) The server role exists, bypasses RLS and is not a superuser (it receives EXECUTE).
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles r
                 WHERE r.rolname = v_srv AND r.rolbypassrls AND NOT r.rolsuper) THEN
    RAISE EXCEPTION 'first_year_curriculum: the server role was not found (or does not bypass RLS / is a superuser); stop';
  END IF;

  -- n) SECURITY DEFINER sees every row only if its owner (the role running this file)
  --    bypasses RLS on the tables it reads and writes: owner without FORCE RLS, or BYPASSRLS.
  SELECT string_agg(c.relname::text, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  WHERE c.oid IN ('public.students'::pg_catalog.regclass, 'public.programs'::pg_catalog.regclass,
                  'public.terms'::pg_catalog.regclass, 'public.subjects'::pg_catalog.regclass,
                  'public.sections'::pg_catalog.regclass, 'public.enrollments'::pg_catalog.regclass,
                  'public.enrollment_items'::pg_catalog.regclass, 'public.applications'::pg_catalog.regclass)
    AND NOT (SELECT r.rolbypassrls FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
    AND NOT (c.relowner = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
             AND NOT c.relforcerowsecurity);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'first_year_curriculum: % would not bypass RLS on %; run as the table owner (postgres); stop', current_user, v_bad;
  END IF;

  -- o) Information only: sample codes that already exist are used as they are.
  SELECT string_agg(s.code::text || ' "' || s.title::text || '"', ', ' ORDER BY s.code) INTO v_bad
  FROM public.subjects s
  WHERE s.code::text IN ('CS111', 'CS112', 'MATH101', 'CS113', 'CS114', 'IT101', 'IT102', 'IT103',
                         'IT104', 'BA101', 'BA102', 'BA103', 'BA104');
  IF v_bad IS NOT NULL THEN
    RAISE NOTICE 'first_year_curriculum: these sample codes already exist and are kept unchanged: %', v_bad;
  END IF;
END
$$;

-- Remember who may execute submit_application today (every grantee except the owner), so
-- the new signature gets exactly the same EXECUTE rights (section 7).
DO $$
DECLARE
  v_fn regprocedure := coalesce(pg_catalog.to_regprocedure('public.submit_application(text, text, text, text, bigint)'),
                                pg_catalog.to_regprocedure('public.submit_application(text, text, text, text, bigint, text)'));
  v    text;
BEGIN
  SELECT coalesce(string_agg(DISTINCT r.rolname::text, ',' ORDER BY r.rolname::text), '') INTO v
  FROM pg_catalog.pg_proc p
  CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) a
  JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
  WHERE p.oid = v_fn AND a.privilege_type = 'EXECUTE' AND a.grantee <> p.proowner;
  PERFORM pg_catalog.set_config('first_year.submit_grantees', v, true);
END
$$;

-- ------------------------------------------
-- 2. The curriculum table
-- ------------------------------------------
CREATE TABLE IF NOT EXISTS public.program_curriculum (
  program_id bigint NOT NULL,
  year_level smallint NOT NULL,
  semester text NOT NULL,
  subject_id bigint NOT NULL,
  CONSTRAINT program_curriculum_pkey PRIMARY KEY (program_id, year_level, semester, subject_id),
  CONSTRAINT fk_program_curriculum_program_id FOREIGN KEY (program_id) REFERENCES public.programs(program_id),
  CONSTRAINT fk_program_curriculum_subject_id FOREIGN KEY (subject_id) REFERENCES public.subjects(subject_id),
  CONSTRAINT ck_program_curriculum_year_level CHECK (year_level >= 1 AND year_level <= 6),
  CONSTRAINT ck_program_curriculum_semester CHECK (semester = ANY (ARRAY['1st'::text, '2nd'::text, 'Summer'::text]))
);

CREATE INDEX IF NOT EXISTS program_curriculum_subject_id_idx ON public.program_curriculum (subject_id);

ALTER TABLE public.program_curriculum ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS program_curriculum_read ON public.program_curriculum;
CREATE POLICY program_curriculum_read ON public.program_curriculum
  FOR SELECT TO authenticated
  USING (true);

-- ------------------------------------------
-- 3. SAMPLE data (not a real curriculum; header, item 2)
-- ------------------------------------------
-- Subjects: existing codes are kept exactly as they are.
INSERT INTO public.subjects (department_id, code, title, units)
SELECT d.department_id, v.code, v.title, 3
FROM (VALUES
  ('CCS', 'CS111',   'Introduction to Programming'),
  ('CCS', 'CS112',   'Discrete Mathematics'),
  ('CAS', 'MATH101', 'Calculus'),
  ('CCS', 'CS113',   'Web Development'),
  ('CCS', 'CS114',   'Human-Computer Interaction'),
  ('CCS', 'IT101',   'Introduction to Programming'),
  ('CCS', 'IT102',   'Discrete Mathematics'),
  ('CCS', 'IT103',   'Web Development'),
  ('CCS', 'IT104',   'Computer Hardware and Networking Basics'),
  ('CBA', 'BA101',   'Principles of Management'),
  ('CBA', 'BA102',   'Business Mathematics'),
  ('CBA', 'BA103',   'Fundamentals of Accounting'),
  ('CBA', 'BA104',   'Introduction to Marketing')
) AS v(dept, code, title)
JOIN public.departments d ON d.code::text = v.dept
ON CONFLICT (code) DO NOTHING;

-- Sections: one section 'A' in the current term, only for a subject that has no section in
-- the current term yet. Schedules do not overlap within a program (GE101 keeps its own
-- section; in seed.sql it is MWF 10-11).
INSERT INTO public.sections (subject_id, term_id, section_code, schedule, capacity)
SELECT s.subject_id, t.term_id, 'A', v.schedule, 40
FROM (VALUES
  ('CS111',   'MWF 8:00-9:00'),
  ('CS112',   'MWF 9:00-10:00'),
  ('MATH101', 'MWF 11:00-12:00'),
  ('CS113',   'TTh 8:00-9:30'),
  ('CS114',   'TTh 9:30-11:00'),
  ('IT101',   'MWF 8:00-9:00'),
  ('IT102',   'MWF 9:00-10:00'),
  ('IT103',   'TTh 8:00-9:30'),
  ('IT104',   'TTh 9:30-11:00'),
  ('BA101',   'MWF 8:00-9:00'),
  ('BA102',   'MWF 9:00-10:00'),
  ('BA103',   'TTh 8:00-9:30'),
  ('BA104',   'TTh 9:30-11:00')
) AS v(code, schedule)
JOIN public.subjects s ON s.code::text = v.code
CROSS JOIN (SELECT t0.term_id FROM public.terms t0 WHERE t0.is_current) t
WHERE NOT EXISTS (SELECT 1 FROM public.sections x
                  WHERE x.subject_id = s.subject_id AND x.term_id = t.term_id);

-- Curriculum: year 1, 1st semester, 5 subjects per program.
INSERT INTO public.program_curriculum (program_id, year_level, semester, subject_id)
SELECT p.program_id, 1, '1st', s.subject_id
FROM (VALUES
  ('BSCS', 'CS111'), ('BSCS', 'CS112'), ('BSCS', 'MATH101'), ('BSCS', 'CS113'), ('BSCS', 'CS114'),
  ('BSIT', 'IT101'), ('BSIT', 'IT102'), ('BSIT', 'IT103'), ('BSIT', 'IT104'), ('BSIT', 'GE101'),
  ('BSBA', 'BA101'), ('BSBA', 'BA102'), ('BSBA', 'BA103'), ('BSBA', 'BA104'), ('BSBA', 'GE101')
) AS v(program, code)
JOIN public.programs p ON p.code::text = v.program
JOIN public.subjects s ON s.code::text = v.code
ON CONFLICT DO NOTHING;

-- ------------------------------------------
-- 4. applications.applicant_type
-- ------------------------------------------
ALTER TABLE public.applications ADD COLUMN IF NOT EXISTS applicant_type text NOT NULL DEFAULT 'New';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                 WHERE k.conrelid = 'public.applications'::pg_catalog.regclass
                   AND k.conname = 'ck_applications_applicant_type') THEN
    ALTER TABLE public.applications ADD CONSTRAINT ck_applications_applicant_type
      CHECK (applicant_type = ANY (ARRAY['New'::text, 'Transferee'::text]));
  END IF;
END
$$;

-- ------------------------------------------
-- 5. submit_application with the optional applicant type (header: THE submit_application
--    CHANGE). The old 5-argument signature is dropped in this same transaction.
-- ------------------------------------------
DROP FUNCTION IF EXISTS public.submit_application(text, text, text, text, bigint);

CREATE OR REPLACE FUNCTION public.submit_application(
  p_first_name     text,
  p_last_name      text,
  p_email          text,
  p_mobile         text,
  p_program_id     bigint,
  p_applicant_type text DEFAULT 'New')
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  s        record;
  v_first  text := private.application_name(p_first_name, 'first_name');
  v_last   text := private.application_name(p_last_name, 'last_name');
  v_email  text := private.application_email(p_email);
  v_mobile text := private.application_mobile(p_mobile);
  v_type   text := COALESCE(NULLIF(pg_catalog.btrim(p_applicant_type), ''), 'New');
BEGIN
  SELECT * INTO STRICT s FROM private.application_settings();

  IF p_program_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.programs p WHERE p.program_id = p_program_id) THEN
    RAISE EXCEPTION 'invalid application: program_id is not an offered program' USING ERRCODE = '22023';
  END IF;

  -- New (first_year_curriculum.sql): New or Transferee; NULL / blank = New.
  IF v_type NOT IN ('New', 'Transferee') THEN
    RAISE EXCEPTION 'invalid application: applicant_type must be New or Transferee' USING ERRCODE = '22023';
  END IF;

  -- Flood valve: the same answer for every email (applications_rules.sql decision 6).
  IF (SELECT pg_catalog.count(*) FROM public.applications a
       WHERE a.submitted_at > pg_catalog.now() - interval '1 hour') >= s.max_per_hour THEN
    RAISE EXCEPTION 'try later: the enrollment site received too many applications in the last hour'
      USING ERRCODE = 'P0001';
  END IF;

  -- One submission per email at a time.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('applications:' || v_email, 0));

  -- Duplicate, existing account or cap reached: success without inserting (decision 4).
  IF EXISTS (SELECT 1 FROM public.applications a
              WHERE a.email = v_email AND a.status::text IN ('Pending', 'Accepted'))
     OR EXISTS (SELECT 1 FROM public.profiles p WHERE pg_catalog.lower(pg_catalog.btrim(p.email::text)) = v_email)
     OR EXISTS (SELECT 1 FROM auth.users u WHERE pg_catalog.lower(pg_catalog.btrim(u.email::text)) = v_email)
     OR (SELECT pg_catalog.count(*) FROM public.applications a
          WHERE a.email = v_email AND a.submitted_at > pg_catalog.now() - s.per_email_window) >= s.max_per_email THEN
    RETURN;
  END IF;

  INSERT INTO public.applications (first_name, last_name, email, mobile, program_id, applicant_type)
  VALUES (v_first, v_last, v_email, v_mobile, p_program_id, v_type);
END
$function$;

-- ------------------------------------------
-- 6. create_first_year_enrollment (header: THE FUNCTION)
-- ------------------------------------------
CREATE OR REPLACE FUNCTION public.create_first_year_enrollment(p_student_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  -- The fixed set (PM decision): first year, 1st semester. One place to change it.
  c_year     constant smallint := 1;
  c_semester constant text     := '1st';
  v_program  bigint;
  v_pcode    text;
  v_nterms   bigint;
  v_term     bigint;
  v_existing bigint;
  v_nsubj    bigint;
  v_missing  text;
  v_enroll   bigint;
  v_items    bigint;
BEGIN
  IF p_student_id IS NULL THEN
    RAISE EXCEPTION 'unknown student: no student id given'
      USING ERRCODE = 'P0001';
  END IF;

  -- The student, locked: concurrent calls (and the student's own enrollment insert, whose
  -- foreign-key check needs a KEY SHARE lock) wait here.
  SELECT s.program_id, p.code::text INTO v_program, v_pcode
  FROM public.students s
  JOIN public.programs p ON p.program_id = s.program_id
  WHERE s.student_id = p_student_id
  FOR UPDATE OF s;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown student: no student with id %', p_student_id
      USING ERRCODE = 'P0001',
            HINT = 'Create the profiles and students rows first (account setup), then call this function.';
  END IF;

  SELECT pg_catalog.count(*), pg_catalog.min(t.term_id) INTO v_nterms, v_term
  FROM public.terms t
  WHERE t.is_current;
  IF v_nterms <> 1 THEN
    RAISE EXCEPTION 'no current term: % terms are marked current, exactly 1 is needed', v_nterms
      USING ERRCODE = 'P0001',
            HINT = 'The Admin marks one term as current.';
  END IF;

  -- Idempotent: an enrollment for the current term already exists -> its id, no change.
  SELECT e.enrollment_id INTO v_existing
  FROM public.enrollments e
  WHERE e.student_id = p_student_id AND e.term_id = v_term
  ORDER BY e.enrollment_id
  LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT pg_catalog.count(*) INTO v_nsubj
  FROM public.program_curriculum c
  WHERE c.program_id = v_program AND c.year_level = c_year AND c.semester = c_semester;
  IF v_nsubj = 0 THEN
    RAISE EXCEPTION 'no curriculum: program % has no year % / % semester subjects', v_pcode, c_year, c_semester
      USING ERRCODE = 'P0001',
            HINT = 'Add the program''s rows to public.program_curriculum (owner), or enroll the student by hand.';
  END IF;

  SELECT pg_catalog.string_agg(sub.code::text, ', ' ORDER BY sub.code) INTO v_missing
  FROM public.program_curriculum c
  JOIN public.subjects sub ON sub.subject_id = c.subject_id
  WHERE c.program_id = v_program AND c.year_level = c_year AND c.semester = c_semester
    AND NOT EXISTS (SELECT 1 FROM public.sections x
                    WHERE x.subject_id = c.subject_id AND x.term_id = v_term);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'no section: subject(s) % of program % have no section in the current term (term %)', v_missing, v_pcode, v_term
      USING ERRCODE = 'P0001',
            HINT = 'The Admin adds a section of each subject to the current term first.';
  END IF;

  -- The enrollment (Pending; the trigger require_enrollment_rules checks it again).
  INSERT INTO public.enrollments (student_id, term_id, year_level, status)
  VALUES (p_student_id, v_term, c_year, 'Pending')
  RETURNING enrollment_id INTO v_enroll;

  -- One item per curriculum subject: its section in the current term with the lowest id
  -- (the trigger require_enrollment_item_rules checks Pending, same term, no duplicate).
  INSERT INTO public.enrollment_items (enrollment_id, section_id)
  SELECT v_enroll,
         (SELECT pg_catalog.min(x.section_id) FROM public.sections x
           WHERE x.subject_id = c.subject_id AND x.term_id = v_term)
  FROM public.program_curriculum c
  WHERE c.program_id = v_program AND c.year_level = c_year AND c.semester = c_semester
  ORDER BY c.subject_id;
  GET DIAGNOSTICS v_items = ROW_COUNT;
  IF v_items <> v_nsubj THEN
    RAISE EXCEPTION 'no section: % of % subjects of program % could be added', v_items, v_nsubj, v_pcode
      USING ERRCODE = 'P0001';
  END IF;

  RETURN v_enroll;
END
$function$;

-- ------------------------------------------
-- 7. Grants
-- ------------------------------------------
-- program_curriculum: authenticated SELECT; anon / PUBLIC nothing; server role SELECT only;
-- writes: owner only.
REVOKE ALL ON public.program_curriculum FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.program_curriculum TO authenticated;

DO $$
DECLARE
  v_srv text := 'service' || '_role';
BEGIN
  EXECUTE pg_catalog.format('REVOKE ALL ON public.program_curriculum FROM %I', v_srv);
  EXECUTE pg_catalog.format('GRANT SELECT ON public.program_curriculum TO %I', v_srv);
END
$$;

-- submit_application (new signature): exactly the grantees the old one had (saved above).
-- First remove PUBLIC and every default grant a new function receives.
DO $$
DECLARE
  v_fn   regprocedure := 'public.submit_application(text, text, text, text, bigint, text)'::pg_catalog.regprocedure;
  r      record;
  v_role text;
BEGIN
  REVOKE ALL ON FUNCTION public.submit_application(text, text, text, text, bigint, text) FROM PUBLIC;
  FOR r IN SELECT DISTINCT a.grantee::pg_catalog.regrole::text AS who
           FROM pg_catalog.pg_proc p CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) a
           WHERE p.oid = v_fn AND a.grantee <> 0 AND a.grantee <> p.proowner
  LOOP
    EXECUTE pg_catalog.format('REVOKE ALL ON FUNCTION public.submit_application(text, text, text, text, bigint, text) FROM %s', r.who);
  END LOOP;
  FOREACH v_role IN ARRAY coalesce(pg_catalog.string_to_array(NULLIF(current_setting('first_year.submit_grantees'), ''), ','), '{}'::text[])
  LOOP
    EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION public.submit_application(text, text, text, text, bigint, text) TO %I', v_role);
  END LOOP;
END
$$;

-- create_first_year_enrollment: the server role only.
DO $$
DECLARE
  v_fn  regprocedure := 'public.create_first_year_enrollment(uuid)'::pg_catalog.regprocedure;
  v_srv text := 'service' || '_role';
  r     record;
BEGIN
  REVOKE ALL ON FUNCTION public.create_first_year_enrollment(uuid) FROM PUBLIC;
  FOR r IN SELECT DISTINCT a.grantee::pg_catalog.regrole::text AS who
           FROM pg_catalog.pg_proc p CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) a
           WHERE p.oid = v_fn AND a.grantee <> 0 AND a.grantee <> p.proowner
  LOOP
    EXECUTE pg_catalog.format('REVOKE ALL ON FUNCTION public.create_first_year_enrollment(uuid) FROM %s', r.who);
  END LOOP;
  REVOKE ALL ON FUNCTION public.create_first_year_enrollment(uuid) FROM anon, authenticated;
  EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION public.create_first_year_enrollment(uuid) TO %I', v_srv);
END
$$;

-- ------------------------------------------
-- 8. Checks after the change (any failure rolls back the whole file)
-- ------------------------------------------
DO $$
DECLARE
  v_bad  text;
  v_srv  text := 'service' || '_role';
  v_sub  regprocedure := pg_catalog.to_regprocedure('public.submit_application(text, text, text, text, bigint, text)');
  v_fy   regprocedure := pg_catalog.to_regprocedure('public.create_first_year_enrollment(uuid)');
  v_now  text;
BEGIN
  -- a) program_curriculum: RLS on, exactly the read policy, keys and checks.
  IF NOT (SELECT c.relrowsecurity FROM pg_catalog.pg_class c WHERE c.oid = 'public.program_curriculum'::pg_catalog.regclass)
     OR (SELECT coalesce(string_agg(p.policyname || ' ' || p.cmd || ' ' || p.permissive || ' ' || array_to_string(p.roles, ',') || ' ' || coalesce(p.qual, ''), '; '), '')
           FROM pg_catalog.pg_policies p WHERE p.schemaname = 'public' AND p.tablename = 'program_curriculum')
        <> 'program_curriculum_read SELECT PERMISSIVE authenticated true'
     OR (SELECT pg_catalog.count(*) FROM pg_catalog.pg_constraint k
          WHERE k.conrelid = 'public.program_curriculum'::pg_catalog.regclass
            AND k.conname IN ('program_curriculum_pkey', 'fk_program_curriculum_program_id', 'fk_program_curriculum_subject_id',
                              'ck_program_curriculum_year_level', 'ck_program_curriculum_semester')
            AND k.convalidated) <> 5 THEN
    RAISE EXCEPTION 'first_year_curriculum: program_curriculum RLS / policy / constraints not as intended; rolled back';
  END IF;

  -- b) program_curriculum privileges: anon and PUBLIC nothing; authenticated SELECT only;
  --    server role SELECT only; no column grants.
  IF pg_catalog.has_table_privilege('anon', 'public.program_curriculum', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR pg_catalog.has_any_column_privilege('anon', 'public.program_curriculum', 'SELECT, INSERT, UPDATE, REFERENCES')
     OR EXISTS (SELECT 1 FROM pg_catalog.pg_class c CROSS JOIN LATERAL pg_catalog.aclexplode(c.relacl) a
                 WHERE c.oid = 'public.program_curriculum'::pg_catalog.regclass AND a.grantee = 0)
     OR NOT pg_catalog.has_table_privilege('authenticated', 'public.program_curriculum', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.program_curriculum', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR NOT pg_catalog.has_table_privilege(v_srv, 'public.program_curriculum', 'SELECT')
     OR pg_catalog.has_table_privilege(v_srv, 'public.program_curriculum', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = 'public.program_curriculum'::pg_catalog.regclass
                   AND a.attnum > 0 AND NOT a.attisdropped AND a.attacl IS NOT NULL) THEN
    RAISE EXCEPTION 'first_year_curriculum: privileges on program_curriculum not as intended; rolled back';
  END IF;

  -- c) Sample data: exactly 5 year-1 / 1st-semester rows per program, the expected codes,
  --    and every curriculum subject has a section in the current term.
  WITH expected(program, codes) AS (VALUES
    ('BSBA', 'BA101,BA102,BA103,BA104,GE101'),
    ('BSCS', 'CS111,CS112,CS113,CS114,MATH101'),
    ('BSIT', 'GE101,IT101,IT102,IT103,IT104')),
  live AS (
    SELECT p.code::text AS program, string_agg(s.code::text, ',' ORDER BY s.code::text COLLATE "C") AS codes
    FROM public.program_curriculum c
    JOIN public.programs p ON p.program_id = c.program_id
    JOIN public.subjects s ON s.subject_id = c.subject_id
    WHERE c.year_level = 1 AND c.semester = '1st' AND p.code::text IN ('BSCS', 'BSIT', 'BSBA')
    GROUP BY p.code)
  SELECT string_agg(e.program || ' [' || coalesce(l.codes, 'none') || ']', '; ') INTO v_bad
  FROM expected e LEFT JOIN live l ON l.program = e.program
  WHERE l.codes IS DISTINCT FROM e.codes;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'first_year_curriculum: curriculum is not exactly the 5 sample subjects per program: %; rolled back', v_bad;
  END IF;
  SELECT string_agg(DISTINCT s.code::text, ', ') INTO v_bad
  FROM public.program_curriculum c
  JOIN public.subjects s ON s.subject_id = c.subject_id
  WHERE NOT EXISTS (SELECT 1 FROM public.sections x JOIN public.terms t ON t.term_id = x.term_id AND t.is_current
                    WHERE x.subject_id = c.subject_id);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'first_year_curriculum: curriculum subject(s) without a section in the current term: %; rolled back', v_bad;
  END IF;

  -- d) applications.applicant_type: text NOT NULL DEFAULT 'New', CHECK validated.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                 JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                 WHERE a.attrelid = 'public.applications'::pg_catalog.regclass
                   AND a.attname = 'applicant_type' AND NOT a.attisdropped AND a.attnotnull
                   AND pg_catalog.format_type(a.atttypid, NULL) = 'text'
                   AND pg_catalog.pg_get_expr(d.adbin, d.adrelid) = '''New''::text')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.applications'::pg_catalog.regclass
                      AND k.conname = 'ck_applications_applicant_type' AND k.contype = 'c' AND k.convalidated
                      AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%New%Transferee%') THEN
    RAISE EXCEPTION 'first_year_curriculum: applications.applicant_type or its CHECK not as intended; rolled back';
  END IF;

  -- e) submit_application: only the new signature; SECURITY DEFINER, empty search_path,
  --    owner = the running role; EXECUTE grantees identical to before; PUBLIC none.
  IF v_sub IS NULL
     OR pg_catalog.to_regprocedure('public.submit_application(text, text, text, text, bigint)') IS NOT NULL
     OR (SELECT pg_catalog.count(*) FROM pg_catalog.pg_proc p
          WHERE p.pronamespace = 'public'::pg_catalog.regnamespace AND p.proname = 'submit_application') <> 1
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                    WHERE p.oid = v_sub AND p.prosecdef
                      AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
                      AND p.proowner = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
                      AND p.proacl IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)) THEN
    RAISE EXCEPTION 'first_year_curriculum: submit_application is not the single new SECURITY DEFINER function; rolled back';
  END IF;
  SELECT coalesce(string_agg(DISTINCT r.rolname::text, ',' ORDER BY r.rolname::text), '') INTO v_now
  FROM pg_catalog.pg_proc p
  CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) a
  JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
  WHERE p.oid = v_sub AND a.privilege_type = 'EXECUTE' AND a.grantee <> p.proowner;
  IF v_now IS DISTINCT FROM current_setting('first_year.submit_grantees')
     OR NOT pg_catalog.has_function_privilege('anon', v_sub, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', v_sub, 'EXECUTE') THEN
    RAISE EXCEPTION 'first_year_curriculum: submit_application EXECUTE grantees changed (before %, after %); rolled back',
      current_setting('first_year.submit_grantees'), v_now;
  END IF;

  -- f) create_first_year_enrollment: SECURITY DEFINER, empty search_path, owner, bigint;
  --    EXECUTE for the server role only (no PUBLIC, no anon, no authenticated, no one else).
  IF v_fy IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                    WHERE p.oid = v_fy AND p.prosecdef
                      AND p.prorettype = 'pg_catalog.int8'::pg_catalog.regtype
                      AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
                      AND p.proowner = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
                      AND p.proacl IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0))
     OR pg_catalog.has_function_privilege('anon', v_fy, 'EXECUTE')
     OR pg_catalog.has_function_privilege('authenticated', v_fy, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(v_srv, v_fy, 'EXECUTE')
     OR (SELECT coalesce(string_agg(DISTINCT r.rolname::text, ','), '')
           FROM pg_catalog.pg_proc p
           CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) a
           JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
          WHERE p.oid = v_fy AND a.grantee <> p.proowner) <> v_srv THEN
    RAISE EXCEPTION 'first_year_curriculum: create_first_year_enrollment properties or grants not as intended; rolled back';
  END IF;

  -- g) The enrollment triggers are still there and enabled.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                 WHERE t.tgrelid = 'public.enrollments'::pg_catalog.regclass
                   AND t.tgname = 'require_enrollment_rules' AND t.tgenabled = 'O')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid = 'public.enrollment_items'::pg_catalog.regclass
                      AND t.tgname = 'require_enrollment_item_rules' AND t.tgenabled = 'O') THEN
    RAISE EXCEPTION 'first_year_curriculum: enrollment triggers missing after the change; rolled back';
  END IF;
END
$$;

-- One result row (all_ok first). The DO block above already stopped on any failure.
SELECT
  (x.bscs = 5 AND x.bsit = 5 AND x.bsba = 5 AND x.no_section = 0 AND x.type_col AND x.old_sig_gone
   AND x.fy_server AND NOT x.fy_anon AND NOT x.fy_auth AND x.sub_anon AND x.sub_auth) AS all_ok,
  x.bscs AS bscs_rows, x.bsit AS bsit_rows, x.bsba AS bsba_rows,
  x.no_section AS subjects_without_current_section,
  x.type_col AS applicant_type_column, x.old_sig_gone AS old_submit_signature_gone,
  x.sub_anon AS submit_anon_execute, x.sub_auth AS submit_authenticated_execute,
  x.fy_server AS first_year_server_execute, x.fy_anon AS first_year_anon_execute,
  x.fy_auth AS first_year_authenticated_execute
FROM (SELECT
  (SELECT pg_catalog.count(*) FROM public.program_curriculum c JOIN public.programs p ON p.program_id = c.program_id
    WHERE p.code::text = 'BSCS' AND c.year_level = 1 AND c.semester = '1st') AS bscs,
  (SELECT pg_catalog.count(*) FROM public.program_curriculum c JOIN public.programs p ON p.program_id = c.program_id
    WHERE p.code::text = 'BSIT' AND c.year_level = 1 AND c.semester = '1st') AS bsit,
  (SELECT pg_catalog.count(*) FROM public.program_curriculum c JOIN public.programs p ON p.program_id = c.program_id
    WHERE p.code::text = 'BSBA' AND c.year_level = 1 AND c.semester = '1st') AS bsba,
  (SELECT pg_catalog.count(DISTINCT c.subject_id) FROM public.program_curriculum c
    WHERE NOT EXISTS (SELECT 1 FROM public.sections x JOIN public.terms t ON t.term_id = x.term_id AND t.is_current
                      WHERE x.subject_id = c.subject_id)) AS no_section,
  EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid = 'public.applications'::pg_catalog.regclass
           AND a.attname = 'applicant_type' AND NOT a.attisdropped) AS type_col,
  pg_catalog.to_regprocedure('public.submit_application(text, text, text, text, bigint)') IS NULL AS old_sig_gone,
  pg_catalog.has_function_privilege('anon', 'public.submit_application(text, text, text, text, bigint, text)', 'EXECUTE') AS sub_anon,
  pg_catalog.has_function_privilege('authenticated', 'public.submit_application(text, text, text, text, bigint, text)', 'EXECUTE') AS sub_auth,
  pg_catalog.has_function_privilege('service' || '_role', 'public.create_first_year_enrollment(uuid)', 'EXECUTE') AS fy_server,
  pg_catalog.has_function_privilege('anon', 'public.create_first_year_enrollment(uuid)', 'EXECUTE') AS fy_anon,
  pg_catalog.has_function_privilege('authenticated', 'public.create_first_year_enrollment(uuid)', 'EXECUTE') AS fy_auth) x;

-- Ask PostgREST to reload its schema cache (sent when the transaction commits).
NOTIFY pgrst, 'reload schema';


-- ==========================================
-- TESTS START HERE (TC-234 to TC-247)
-- ==========================================
begin;

-- ==========================================
-- 1. Accounts, ids and a clean start (as postgres, no user JWT)
-- ==========================================
select set_config('request.jwt.claims', '', true);
select set_config('app.srv',  'service' || '_role', true);
select set_config('app.s1',   coalesce((select id::text from auth.users where email = 'student1@pnc.test'), ''), true);
select set_config('app.reg',  coalesce((select id::text from auth.users where email = 'registrar@pnc.test'), ''), true);
select set_config('app.adm',  coalesce((select id::text from auth.users where email = 'admin@pnc.test'), ''), true);
select set_config('app.real_term', coalesce((select term_id::text from public.terms where is_current), ''), true);
select set_config('app.p_bscs', coalesce((select program_id::text from public.programs where code = 'BSCS'), ''), true);
select set_config('app.p_bsit', coalesce((select program_id::text from public.programs where code = 'BSIT'), ''), true);
select set_config('app.p_bsba', coalesce((select program_id::text from public.programs where code = 'BSBA'), ''), true);
-- One student per program: the seed student (studentN@pnc.test) first, else the lowest number.
select set_config('app.st_' || lower(v.code), coalesce((
  select s.student_id::text
  from public.students s
  join public.programs p on p.program_id = s.program_id
  join public.profiles pr on pr.profile_id = s.student_id
  where p.code = v.code
  order by (pr.email like 'student_@pnc.test') desc, s.student_number
  limit 1), ''), true)
from (values ('BSCS'), ('BSIT'), ('BSBA')) as v(code);
do $$
declare v_bad text;
begin
  if to_regprocedure('public.create_first_year_enrollment(uuid)') is null
     or to_regclass('public.program_curriculum') is null
     or to_regprocedure('public.submit_application(text, text, text, text, bigint, text)') is null then
    raise exception 'TC setup: first_year_curriculum.sql is not installed (run it, or use first_year_curriculum_rehearsal.sql)';
  end if;
  select string_agg(v.who || ' (' || v.role_name || ')', ', ') into v_bad
  from (values ('s1', 'Student'), ('reg', 'Registrar'), ('adm', 'Admin')) as v(who, role_name)
  where current_setting('app.' || v.who) = ''
     or not exists (select 1 from public.profiles p join public.roles r on r.role_id = p.role_id
                    where p.profile_id::text = current_setting('app.' || v.who)
                      and p.is_active and r.role_name = v.role_name);
  if v_bad is not null then
    raise exception 'TC setup: seed account missing, inactive or with another role: %', v_bad;
  end if;
  if '' in (current_setting('app.real_term'), current_setting('app.p_bscs'), current_setting('app.p_bsit'),
            current_setting('app.p_bsba'), current_setting('app.st_bscs'), current_setting('app.st_bsit'),
            current_setting('app.st_bsba')) then
    raise exception 'TC setup: no current term, a program, or a student of BSCS / BSIT / BSBA is missing';
  end if;
  if exists (select 1 from public.terms where school_year = '2088-2089') then
    raise exception 'TC setup: a term 2088-2089 exists; the tests need that school year free';
  end if;
  if exists (select 1 from public.profiles where lower(email) like '%@firstyear.test')
     or exists (select 1 from auth.users where lower(email) like '%@firstyear.test') then
    raise exception 'TC setup: a profile or Auth user under @firstyear.test exists; the tests need that domain free';
  end if;
end $$;
delete from public.applications where email like '%@firstyear.test';
select set_config('app.log_mark', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);

-- ==========================================
-- 2. TC-234: installed as intended (catalog)
-- ==========================================
select set_config('app.k_cols', coalesce((
  with expected(col, typ) as (values ('program_id', 'bigint'), ('year_level', 'smallint'),
                                     ('semester', 'text'), ('subject_id', 'bigint')),
  live as (select a.attname::text as col, format_type(a.atttypid, null) as typ
           from pg_attribute a
           where a.attrelid = 'public.program_curriculum'::regclass and a.attnum > 0 and not a.attisdropped)
  select string_agg(d, '; ' order by d) from (
    (select 'missing ' || col || ' ' || typ as d from (select * from expected except select * from live) m)
    union all
    (select 'unexpected ' || col || ' ' || typ from (select * from live except select * from expected) u)) dd), ''), true);
select set_config('app.k_pk', (exists (
  select 1 from pg_constraint k
  where k.conrelid = 'public.program_curriculum'::regclass and k.contype = 'p'
    and (select array_agg(a.attname::text order by a.attname::text)
           from unnest(k.conkey) as c(attnum)
           join pg_attribute a on a.attrelid = k.conrelid and a.attnum = c.attnum)
        = array['program_id', 'semester', 'subject_id', 'year_level']))::text, true);
select set_config('app.k_fk', (select count(*) from pg_constraint k
  where k.conrelid = 'public.program_curriculum'::regclass and k.contype = 'f'
    and k.confrelid in ('public.programs'::regclass, 'public.subjects'::regclass))::text, true);
select set_config('app.k_ck', (select count(*) from pg_constraint k
  where k.conrelid = 'public.program_curriculum'::regclass and k.contype = 'c'
    and k.conname in ('ck_program_curriculum_year_level', 'ck_program_curriculum_semester'))::text, true);
select set_config('app.k_rls', (select c.relrowsecurity from pg_class c where c.oid = 'public.program_curriculum'::regclass)::text, true);
select set_config('app.k_pol', coalesce((select string_agg(p.policyname || ' ' || p.cmd || ' ' || array_to_string(p.roles, ',') || ' ' || coalesce(p.qual, ''), '; ')
  from pg_policies p where p.schemaname = 'public' and p.tablename = 'program_curriculum'), ''), true);
select set_config('app.k_tpriv', (
  not has_table_privilege('anon', 'public.program_curriculum', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('anon', 'public.program_curriculum', 'SELECT, INSERT, UPDATE, REFERENCES')
  and has_table_privilege('authenticated', 'public.program_curriculum', 'SELECT')
  and not has_table_privilege('authenticated', 'public.program_curriculum', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'public.program_curriculum', 'INSERT, UPDATE, REFERENCES')
  and not exists (select 1 from pg_class c cross join lateral aclexplode(c.relacl) a
                   where c.oid = 'public.program_curriculum'::regclass and a.grantee = 0))::text, true);
select set_config('app.k_fn', coalesce((select (p.prosecdef
    and p.prorettype = 'bigint'::regtype
    and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
    and p.proacl is not null
    and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
    and not has_function_privilege('anon', p.oid, 'EXECUTE')
    and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and has_function_privilege(current_setting('app.srv'), p.oid, 'EXECUTE'))::text
  from pg_proc p where p.oid = to_regprocedure('public.create_first_year_enrollment(uuid)')), 'false'), true);
select set_config('app.k_col', (exists (
  select 1 from pg_attribute a join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = 'public.applications'::regclass and a.attname = 'applicant_type' and not a.attisdropped
    and a.attnotnull and format_type(a.atttypid, null) = 'text' and pg_get_expr(d.adbin, d.adrelid) = '''New''::text')
  and exists (select 1 from pg_constraint k where k.conrelid = 'public.applications'::regclass
               and k.conname = 'ck_applications_applicant_type' and k.convalidated))::text, true);
select set_config('app.k_sub', coalesce((select (p.prosecdef
    and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
    and p.proacl is not null
    and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
    and has_function_privilege('anon', p.oid, 'EXECUTE')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and to_regprocedure('public.submit_application(text, text, text, text, bigint)') is null
    and (select count(*) from pg_proc q where q.pronamespace = 'public'::regnamespace and q.proname = 'submit_application') = 1)::text
  from pg_proc p where p.oid = to_regprocedure('public.submit_application(text, text, text, text, bigint, text)')), 'false'), true);
select set_config('app.r234', format('cols_diff [%s], pk %s, fks %s/2, checks %s/2, rls %s, policy [%s], table_privs %s, function %s, applicant_type %s, submit %s -> %s',
  current_setting('app.k_cols'), current_setting('app.k_pk'), current_setting('app.k_fk'), current_setting('app.k_ck'),
  current_setting('app.k_rls'), current_setting('app.k_pol'), current_setting('app.k_tpriv'), current_setting('app.k_fn'),
  current_setting('app.k_col'), current_setting('app.k_sub'),
  case when current_setting('app.k_cols') = '' and current_setting('app.k_pk') = 'true'
        and current_setting('app.k_fk') = '2' and current_setting('app.k_ck') = '2'
        and current_setting('app.k_rls') = 'true'
        and current_setting('app.k_pol') = 'program_curriculum_read SELECT authenticated true'
        and current_setting('app.k_tpriv') = 'true' and current_setting('app.k_fn') = 'true'
        and current_setting('app.k_col') = 'true' and current_setting('app.k_sub') = 'true'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 3. TC-235: sample curriculum and its sections in the real current term
-- ==========================================
select set_config('app.r235', (select format('BSCS [%s], BSIT [%s], BSBA [%s], subjects_without_section [%s] -> %s',
    x.bscs, x.bsit, x.bsba, x.nosec,
    case when x.bscs = 'CS111,CS112,CS113,CS114,MATH101' and x.bsit = 'GE101,IT101,IT102,IT103,IT104'
          and x.bsba = 'BA101,BA102,BA103,BA104,GE101' and x.nosec = '' then 'OK' else 'FAIL' end)
  from (select
    coalesce((select string_agg(s.code, ',' order by s.code::text collate "C") from public.program_curriculum c
               join public.subjects s on s.subject_id = c.subject_id
              where c.program_id = current_setting('app.p_bscs')::bigint and c.year_level = 1 and c.semester = '1st'), '') as bscs,
    coalesce((select string_agg(s.code, ',' order by s.code::text collate "C") from public.program_curriculum c
               join public.subjects s on s.subject_id = c.subject_id
              where c.program_id = current_setting('app.p_bsit')::bigint and c.year_level = 1 and c.semester = '1st'), '') as bsit,
    coalesce((select string_agg(s.code, ',' order by s.code::text collate "C") from public.program_curriculum c
               join public.subjects s on s.subject_id = c.subject_id
              where c.program_id = current_setting('app.p_bsba')::bigint and c.year_level = 1 and c.semester = '1st'), '') as bsba,
    coalesce((select string_agg(distinct s.code, ',') from public.program_curriculum c
               join public.subjects s on s.subject_id = c.subject_id
              where not exists (select 1 from public.sections x
                                 where x.subject_id = c.subject_id and x.term_id = current_setting('app.real_term')::bigint)), '') as nosec
  ) x), true);

-- ==========================================
-- 4. TC-236: an existing enrollment in the current term is returned unchanged
--    (real current term; the student's own enrollment, or one made here as the owner)
-- ==========================================
do $$
declare
  v_e  bigint;
  v_st uuid;
begin
  select e.enrollment_id, e.student_id into v_e, v_st
  from public.enrollments e
  where e.term_id = current_setting('app.real_term')::bigint
  order by e.enrollment_id
  limit 1;
  if v_e is null then
    insert into public.enrollments (student_id, term_id, year_level)
    values (current_setting('app.st_bscs')::uuid, current_setting('app.real_term')::bigint, 2)
    returning enrollment_id into v_e;
    v_st := current_setting('app.st_bscs')::uuid;
  end if;
  perform set_config('app.t236_e', v_e::text, true);
  perform set_config('app.t236_st', v_st::text, true);
  perform set_config('app.t236_before', (
    select e.status || ' y' || e.year_level || ' items ' || (select count(*) from public.enrollment_items i where i.enrollment_id = e.enrollment_id)
           || ' enrollments ' || (select count(*) from public.enrollments x where x.student_id = v_st and x.term_id = e.term_id)
    from public.enrollments e where e.enrollment_id = v_e), true);
end $$;
do $$
declare v_ret bigint;
begin
  v_ret := public.create_first_year_enrollment(current_setting('app.t236_st')::uuid);
  perform set_config('app.t236_call', 'id ' || v_ret, true);
exception when others then
  perform set_config('app.t236_call', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
select set_config('app.r236', (select format('call [%s], expected id %s, before [%s], after [%s] -> %s',
    current_setting('app.t236_call'), current_setting('app.t236_e'), current_setting('app.t236_before'), x.after,
    case when current_setting('app.t236_call') = 'id ' || current_setting('app.t236_e')
          and x.after = current_setting('app.t236_before') then 'OK' else 'FAIL' end)
  from (select (select e.status || ' y' || e.year_level || ' items ' || (select count(*) from public.enrollment_items i where i.enrollment_id = e.enrollment_id)
                       || ' enrollments ' || (select count(*) from public.enrollments x where x.student_id = e.student_id and x.term_id = e.term_id)
                from public.enrollments e where e.enrollment_id = current_setting('app.t236_e')::bigint) as after) x), true);

-- ==========================================
-- 5. Throwaway current term 2088-2089 with a section of every curriculum subject
--    (as postgres; the real current term is switched off until the rollback)
-- ==========================================
update public.terms set is_current = false where term_id = current_setting('app.real_term')::bigint;
insert into public.terms (school_year, semester, start_date, end_date, is_current)
values ('2088-2089', '1st', date '2088-08-01', date '2088-12-20', true);
select set_config('app.t1', (select term_id::text from public.terms where school_year = '2088-2089' and semester = '1st'), true);
-- CS111 gets two sections; Z234Y is created first, so it has the lower section_id.
insert into public.sections (subject_id, term_id, section_code, schedule, capacity)
select s.subject_id, current_setting('app.t1')::bigint, 'Z234Y', 'TTh 1:00-2:30', 40
from public.subjects s where s.code = 'CS111';
insert into public.sections (subject_id, term_id, section_code, schedule, capacity)
select distinct c.subject_id, current_setting('app.t1')::bigint, 'Z234', 'MWF 8:00-9:00', 40
from public.program_curriculum c
where c.year_level = 1 and c.semester = '1st'
  and c.program_id in (current_setting('app.p_bscs')::bigint, current_setting('app.p_bsit')::bigint,
                       current_setting('app.p_bsba')::bigint);

-- ==========================================
-- 6. TC-237: unknown student refused
-- ==========================================
do $$
declare
  r record;
  v_ret bigint;
begin
  for r in select * from (values
    (1, 'c237_random', gen_random_uuid()),
    (2, 'c237_null',   null::uuid)
  ) as t(ord, label, sid) order by ord
  loop
    begin
      v_ret := public.create_first_year_enrollment(r.sid);
      perform set_config('app.' || r.label, 'id ' || coalesce(v_ret::text, 'NULL'), true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.r237', format('random [%s], null [%s], enrollments_in_t1 %s -> %s',
  current_setting('app.c237_random'), current_setting('app.c237_null'),
  (select count(*) from public.enrollments where term_id = current_setting('app.t1')::bigint),
  case when current_setting('app.c237_random') like 'ERR [P0001]: unknown student:%'
        and current_setting('app.c237_null') like 'ERR [P0001]: unknown student:%'
        and (select count(*) from public.enrollments where term_id = current_setting('app.t1')::bigint) = 0
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 7. TC-238: program without curriculum (BSBA rows removed inside a sub-block)
-- ==========================================
do $$
declare
  v_res text;
  v_ret bigint;
begin
  begin
    delete from public.program_curriculum c where c.program_id = current_setting('app.p_bsba')::bigint;
    v_ret := public.create_first_year_enrollment(current_setting('app.st_bsba')::uuid);
    v_res := 'id ' || v_ret;
    raise exception 'undo the test delete';
  exception when others then
    if v_res is null then
      v_res := 'ERR [' || sqlstate || ']: ' || sqlerrm;
    end if;
  end;
  perform set_config('app.c238', v_res, true);
end $$;
select set_config('app.r238', format('call [%s], bsba_enrollments_in_t1 %s, bsba_curriculum_rows_back %s -> %s',
  current_setting('app.c238'),
  (select count(*) from public.enrollments where student_id = current_setting('app.st_bsba')::uuid
     and term_id = current_setting('app.t1')::bigint),
  (select count(*) from public.program_curriculum where program_id = current_setting('app.p_bsba')::bigint),
  case when current_setting('app.c238') like 'ERR [P0001]: no curriculum:%'
        and (select count(*) from public.enrollments where student_id = current_setting('app.st_bsba')::uuid
               and term_id = current_setting('app.t1')::bigint) = 0
        and (select count(*) from public.program_curriculum where program_id = current_setting('app.p_bsba')::bigint) = 5
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 8. TC-239: a subject without a section (IT104's 2088-2089 section removed in a sub-block)
-- ==========================================
do $$
declare
  v_res text;
  v_ret bigint;
begin
  begin
    delete from public.sections x
    using public.subjects s
    where s.subject_id = x.subject_id and s.code = 'IT104' and x.term_id = current_setting('app.t1')::bigint;
    v_ret := public.create_first_year_enrollment(current_setting('app.st_bsit')::uuid);
    v_res := 'id ' || v_ret;
    raise exception 'undo the test delete';
  exception when others then
    if v_res is null then
      v_res := 'ERR [' || sqlstate || ']: ' || sqlerrm;
    end if;
  end;
  perform set_config('app.c239', v_res, true);
end $$;
select set_config('app.r239', format('call [%s], bsit_enrollments_in_t1 %s, it104_section_back %s -> %s',
  current_setting('app.c239'),
  (select count(*) from public.enrollments where student_id = current_setting('app.st_bsit')::uuid
     and term_id = current_setting('app.t1')::bigint),
  (select count(*) from public.sections x join public.subjects s on s.subject_id = x.subject_id
    where s.code = 'IT104' and x.term_id = current_setting('app.t1')::bigint),
  case when current_setting('app.c239') like 'ERR [P0001]: no section:%IT104%'
        and (select count(*) from public.enrollments where student_id = current_setting('app.st_bsit')::uuid
               and term_id = current_setting('app.t1')::bigint) = 0
        and (select count(*) from public.sections x join public.subjects s on s.subject_id = x.subject_id
              where s.code = 'IT104' and x.term_id = current_setting('app.t1')::bigint) = 1
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 9. TC-240: one new Pending Year 1 enrollment per program (server role path)
-- ==========================================
select set_config('app.log_mark2', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);
do $$
declare
  r      record;
  v_ret  bigint;
  v_mode text := 'server role';
begin
  begin
    execute format('set local role %I', current_setting('app.srv'));
  exception when others then
    v_mode := 'postgres without JWT';
  end;
  perform set_config('request.jwt.claims', json_build_object('role', current_setting('app.srv'))::text, true);
  for r in select * from (values (1, 'bscs'), (2, 'bsit'), (3, 'bsba')) as t(ord, prog) order by ord
  loop
    begin
      v_ret := public.create_first_year_enrollment(current_setting('app.st_' || r.prog)::uuid);
      perform set_config('app.e240_' || r.prog, v_ret::text, true);
      perform set_config('app.c240_' || r.prog, 'id ' || v_ret, true);
    exception when others then
      perform set_config('app.e240_' || r.prog, '0', true);
      perform set_config('app.c240_' || r.prog, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
  perform set_config('app.m240', v_mode, true);
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r240', (select format('mode %s; %s; CS111 section %s -> %s',
    current_setting('app.m240'),
    string_agg(format('%s [%s] %s y%s term_ok %s reviewed %s items %s/%s subjects_match %s lowest %s audit %s',
                      upper(x.prog), x.call, x.status, x.year_level, x.term_ok, x.reviewed, x.items, x.cur,
                      x.subjects_match, x.lowest, x.audit), '; ' order by x.prog),
    coalesce((select sec.section_code from public.enrollment_items i
               join public.sections sec on sec.section_id = i.section_id
               join public.subjects s on s.subject_id = sec.subject_id
              where i.enrollment_id = current_setting('app.e240_bscs')::bigint and s.code = 'CS111'), 'none'),
    case when count(*) = 3
          and bool_and(x.call like 'id %' and x.status = 'Pending' and x.year_level = 1 and x.term_ok
                       and x.reviewed = 'none' and x.items = 5 and x.cur = 5 and x.subjects_match
                       and x.lowest = 0 and x.audit = 'insert 1, items 5')
          and (select sec.section_code from public.enrollment_items i
                join public.sections sec on sec.section_id = i.section_id
                join public.subjects s on s.subject_id = sec.subject_id
               where i.enrollment_id = current_setting('app.e240_bscs')::bigint and s.code = 'CS111') = 'Z234Y'
         then 'OK' else 'FAIL' end)
  from (select v.prog, current_setting('app.c240_' || v.prog) as call,
               coalesce(e.status::text, 'none') as status, coalesce(e.year_level, 0) as year_level,
               (e.term_id = current_setting('app.t1')::bigint and e.student_id::text = current_setting('app.st_' || v.prog)) is true as term_ok,
               coalesce(e.reviewed_by::text, 'none') as reviewed,
               (select count(*) from public.enrollment_items i where i.enrollment_id = e.enrollment_id) as items,
               (select count(*) from public.program_curriculum c
                 where c.program_id = current_setting('app.p_' || v.prog)::bigint and c.year_level = 1 and c.semester = '1st') as cur,
               (coalesce((select string_agg(sec.subject_id::text, ',' order by sec.subject_id)
                            from public.enrollment_items i join public.sections sec on sec.section_id = i.section_id
                           where i.enrollment_id = e.enrollment_id), '')
                = coalesce((select string_agg(c.subject_id::text, ',' order by c.subject_id)
                              from public.program_curriculum c
                             where c.program_id = current_setting('app.p_' || v.prog)::bigint
                               and c.year_level = 1 and c.semester = '1st'), 'x')) as subjects_match,
               (select count(*) from public.enrollment_items i join public.sections sec on sec.section_id = i.section_id
                 where i.enrollment_id = e.enrollment_id
                   and i.section_id <> (select min(y.section_id) from public.sections y
                                         where y.subject_id = sec.subject_id and y.term_id = current_setting('app.t1')::bigint)) as lowest,
               format('insert %s, items %s',
                 (select count(*) from public.audit_logs l
                   where l.log_id > current_setting('app.log_mark2')::bigint and l.table_name = 'enrollments'
                     and l.action = 'INSERT' and l.record_id = e.enrollment_id::text and l.actor_id is null),
                 (select count(*) from public.audit_logs l
                   where l.log_id > current_setting('app.log_mark2')::bigint and l.table_name = 'enrollment_items'
                     and l.action = 'INSERT' and l.actor_id is null
                     and (l.new_data ->> 'enrollment_id') = e.enrollment_id::text)) as audit
        from (values ('bscs'), ('bsit'), ('bsba')) as v(prog)
        left join public.enrollments e on e.enrollment_id = current_setting('app.e240_' || v.prog)::bigint) x), true);

-- ==========================================
-- 10. TC-241: a second call returns the same id and adds nothing
-- ==========================================
select set_config('app.t241_items_before', (select count(*) from public.enrollment_items i
  join public.enrollments e on e.enrollment_id = i.enrollment_id
  where e.term_id = current_setting('app.t1')::bigint)::text, true);
do $$
declare
  r     record;
  v_ret bigint;
begin
  begin
    execute format('set local role %I', current_setting('app.srv'));
  exception when others then
    null;
  end;
  perform set_config('request.jwt.claims', json_build_object('role', current_setting('app.srv'))::text, true);
  for r in select * from (values (1, 'bscs'), (2, 'bsit')) as t(ord, prog) order by ord
  loop
    begin
      v_ret := public.create_first_year_enrollment(current_setting('app.st_' || r.prog)::uuid);
      perform set_config('app.c241_' || r.prog, 'id ' || v_ret, true);
    exception when others then
      perform set_config('app.c241_' || r.prog, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r241', format('bscs [%s] first id %s, bsit [%s] first id %s, enrollments bscs %s bsit %s, items in t1 before %s after %s -> %s',
  current_setting('app.c241_bscs'), current_setting('app.e240_bscs'),
  current_setting('app.c241_bsit'), current_setting('app.e240_bsit'),
  (select count(*) from public.enrollments where student_id = current_setting('app.st_bscs')::uuid and term_id = current_setting('app.t1')::bigint),
  (select count(*) from public.enrollments where student_id = current_setting('app.st_bsit')::uuid and term_id = current_setting('app.t1')::bigint),
  current_setting('app.t241_items_before'),
  (select count(*) from public.enrollment_items i join public.enrollments e on e.enrollment_id = i.enrollment_id
    where e.term_id = current_setting('app.t1')::bigint),
  case when current_setting('app.c241_bscs') = 'id ' || current_setting('app.e240_bscs')
        and current_setting('app.c241_bsit') = 'id ' || current_setting('app.e240_bsit')
        and current_setting('app.e240_bscs') <> '0'
        and (select count(*) from public.enrollments where student_id = current_setting('app.st_bscs')::uuid and term_id = current_setting('app.t1')::bigint) = 1
        and (select count(*) from public.enrollments where student_id = current_setting('app.st_bsit')::uuid and term_id = current_setting('app.t1')::bigint) = 1
        and (select count(*) from public.enrollment_items i join public.enrollments e on e.enrollment_id = i.enrollment_id
              where e.term_id = current_setting('app.t1')::bigint)::text = current_setting('app.t241_items_before')
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 11. TC-242: nobody but the server role executes the function; nobody writes the curriculum
-- ==========================================
select set_config('app.t242_before', (select count(*) || ' rows, ' || count(*) filter (where semester = '1st' and year_level = 1) || ' y1/1st'
                                        from public.program_curriculum)::text, true);
set local role anon;
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 'c242_anon_fn',  $q$select public.create_first_year_enrollment(current_setting('app.st_bsba')::uuid)$q$),
    (2, 'c242_anon_ins', $q$insert into public.program_curriculum (program_id, year_level, semester, subject_id)
                            select current_setting('app.p_bscs')::bigint, 2, '1st', min(subject_id) from public.subjects$q$)
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
reset role;
set local role authenticated;
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 'c242_s1_fn',  's1',  $q$select public.create_first_year_enrollment(current_setting('app.st_bsba')::uuid)$q$),
    (2, 'c242_reg_fn', 'reg', $q$select public.create_first_year_enrollment(current_setting('app.st_bsba')::uuid)$q$),
    (3, 'c242_adm_fn', 'adm', $q$select public.create_first_year_enrollment(current_setting('app.st_bsba')::uuid)$q$),
    (4, 'c242_adm_ins', 'adm', $q$insert into public.program_curriculum (program_id, year_level, semester, subject_id)
                                  select current_setting('app.p_bscs')::bigint, 2, '1st', min(subject_id) from public.subjects$q$),
    (5, 'c242_adm_upd', 'adm', $q$update public.program_curriculum set semester = '2nd'
                                  where program_id = current_setting('app.p_bscs')::bigint$q$),
    (6, 'c242_adm_del', 'adm', $q$delete from public.program_curriculum where program_id = current_setting('app.p_bscs')::bigint$q$),
    (7, 'c242_reg_del', 'reg', $q$delete from public.program_curriculum where program_id = current_setting('app.p_bsit')::bigint$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt;
      get diagnostics n = row_count;
      perform set_config('app.' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r242', format('%s of 9 denied, server_role_execute %s, curriculum before [%s] after [%s], bsba enrollments in t1 %s -> %s',
  (select count(*) from unnest(array['c242_anon_fn', 'c242_anon_ins', 'c242_s1_fn', 'c242_reg_fn', 'c242_adm_fn',
                                     'c242_adm_ins', 'c242_adm_upd', 'c242_adm_del', 'c242_reg_del']) as x
    where current_setting('app.' || x) like 'ERR [42501]: permission denied%'),
  has_function_privilege(current_setting('app.srv'), 'public.create_first_year_enrollment(uuid)', 'EXECUTE'),
  current_setting('app.t242_before'),
  (select count(*) || ' rows, ' || count(*) filter (where semester = '1st' and year_level = 1) || ' y1/1st'
     from public.program_curriculum),
  (select count(*) from public.enrollments where student_id = current_setting('app.st_bsba')::uuid
     and term_id = current_setting('app.t1')::bigint),
  case when (select count(*) from unnest(array['c242_anon_fn', 'c242_anon_ins', 'c242_s1_fn', 'c242_reg_fn', 'c242_adm_fn',
                                               'c242_adm_ins', 'c242_adm_upd', 'c242_adm_del', 'c242_reg_del']) as x
              where current_setting('app.' || x) like 'ERR [42501]: permission denied%') = 9
        and has_function_privilege(current_setting('app.srv'), 'public.create_first_year_enrollment(uuid)', 'EXECUTE')
        and (select count(*) || ' rows, ' || count(*) filter (where semester = '1st' and year_level = 1) || ' y1/1st'
               from public.program_curriculum) = current_setting('app.t242_before')
        and (select count(*) from public.enrollments where student_id = current_setting('app.st_bsba')::uuid
               and term_id = current_setting('app.t1')::bigint) = 1
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 12. TC-243: a signed-in user reads the curriculum; anon cannot
-- ==========================================
select set_config('app.t243_owner', (select count(*) from public.program_curriculum)::text, true);
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.s1'), 'role', 'authenticated')::text, true);
do $$
declare n bigint;
begin
  execute 'select count(*) from public.program_curriculum' into n;
  perform set_config('app.c243_s1', 'count ' || n, true);
exception when others then
  perform set_config('app.c243_s1', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
do $$
declare n bigint;
begin
  execute 'select count(*) from public.program_curriculum' into n;
  perform set_config('app.c243_anon', 'count ' || n, true);
exception when others then
  perform set_config('app.c243_anon', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
reset role;
select set_config('app.r243', format('student [%s] of %s, anon [%s] -> %s',
  current_setting('app.c243_s1'), current_setting('app.t243_owner'), current_setting('app.c243_anon'),
  case when current_setting('app.c243_s1') = 'count ' || current_setting('app.t243_owner')
        and current_setting('app.t243_owner')::bigint >= 15
        and current_setting('app.c243_anon') like 'ERR [42501]: permission denied%'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 13. TC-244: submit_application with and without the applicant type
-- ==========================================
set local role anon;
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 'c244_five',   $q$select public.submit_application('Nina', 'Nuevo', 'tc244-five@firstyear.test', null,
                                                           current_setting('app.p_bscs')::bigint)$q$),
    (2, 'c244_trans',  $q$select public.submit_application('Tomas', 'Lipat', 'tc244-trans@firstyear.test', '09171234567',
                                                           current_setting('app.p_bsit')::bigint, 'Transferee')$q$),
    (3, 'c244_named',  $q$select public.submit_application(p_first_name => 'Nora', p_last_name => 'Bago',
                                                           p_email => 'tc244-named@firstyear.test', p_mobile => null,
                                                           p_program_id => current_setting('app.p_bsba')::bigint,
                                                           p_applicant_type => 'New')$q$),
    (4, 'c244_null',   $q$select public.submit_application('Nilo', 'Wala', 'tc244-null@firstyear.test', null,
                                                           current_setting('app.p_bscs')::bigint, null)$q$),
    (5, 'c244_padded', $q$select public.submit_application('Pia', 'Lipat', 'tc244-padded@firstyear.test', null,
                                                           current_setting('app.p_bsit')::bigint, ' Transferee ')$q$)
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
reset role;
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.s1'), 'role', 'authenticated')::text, true);
do $$
begin
  perform public.submit_application('Sara', 'Lipat', 'tc244-signed-in@firstyear.test', null,
                                    current_setting('app.p_bsba')::bigint, 'Transferee');
  perform set_config('app.c244_signed', 'rows 1', true);
exception when others then
  perform set_config('app.c244_signed', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r244', (select format('calls [%s | %s | %s | %s | %s | %s], stored [%s], old_signature_gone %s -> %s',
    current_setting('app.c244_five'), current_setting('app.c244_trans'), current_setting('app.c244_named'),
    current_setting('app.c244_null'), current_setting('app.c244_padded'), current_setting('app.c244_signed'),
    coalesce(string_agg(split_part(a.email, '@', 1) || '=' || a.applicant_type || '/' || a.status, ', ' order by a.email::text collate "C"), 'none'),
    to_regprocedure('public.submit_application(text, text, text, text, bigint)') is null,
    case when current_setting('app.c244_five') = 'rows 1' and current_setting('app.c244_trans') = 'rows 1'
          and current_setting('app.c244_named') = 'rows 1' and current_setting('app.c244_null') = 'rows 1'
          and current_setting('app.c244_padded') = 'rows 1' and current_setting('app.c244_signed') = 'rows 1'
          and coalesce(string_agg(split_part(a.email, '@', 1) || '=' || a.applicant_type || '/' || a.status, ', ' order by a.email::text collate "C"), '')
              = 'tc244-five=New/Pending, tc244-named=New/Pending, tc244-null=New/Pending, tc244-padded=Transferee/Pending, tc244-signed-in=Transferee/Pending, tc244-trans=Transferee/Pending'
          and to_regprocedure('public.submit_application(text, text, text, text, bigint)') is null
         then 'OK' else 'FAIL' end)
  from public.applications a where a.email like 'tc244-%@firstyear.test'), true);

-- ==========================================
-- 14. TC-245: an invalid applicant type is refused
-- ==========================================
set local role anon;
do $$
declare r record; n bigint;
begin
  for r in select * from (values
    (1, 'c245_other', $q$select public.submit_application('Ola', 'Mali', 'tc245-a@firstyear.test', null,
                                                          current_setting('app.p_bscs')::bigint, 'Returnee')$q$),
    (2, 'c245_lower', $q$select public.submit_application('Ola', 'Mali', 'tc245-b@firstyear.test', null,
                                                          current_setting('app.p_bscs')::bigint, 'transferee')$q$),
    (3, 'c245_long',  $q$select public.submit_application('Ola', 'Mali', 'tc245-c@firstyear.test', null,
                                                          current_setting('app.p_bscs')::bigint, repeat('New', 50))$q$)
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
reset role;
do $$
begin
  insert into public.applications (first_name, last_name, email, mobile, program_id, applicant_type)
  values ('Ola', 'Mali', 'tc245-owner@firstyear.test', null, current_setting('app.p_bscs')::bigint, 'Other');
  perform set_config('app.c245_owner', 'rows 1', true);
exception when others then
  perform set_config('app.c245_owner', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
select set_config('app.r245', format('other [%s], lower [%s], long [%s], owner [%s], rows written %s -> %s',
  current_setting('app.c245_other'), current_setting('app.c245_lower'), current_setting('app.c245_long'),
  split_part(current_setting('app.c245_owner'), ' (', 1),
  (select count(*) from public.applications where email like 'tc245-%@firstyear.test'),
  case when current_setting('app.c245_other') like 'ERR [22023]: invalid application: applicant_type%'
        and current_setting('app.c245_lower') like 'ERR [22023]: invalid application: applicant_type%'
        and current_setting('app.c245_long') like 'ERR [22023]: invalid application: applicant_type%'
        and current_setting('app.c245_owner') like 'ERR [23514]:%ck_applications_applicant_type%'
        and (select count(*) from public.applications where email like 'tc245-%@firstyear.test') = 0
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 15. TC-246: the Registrar approves an auto-created enrollment; then it is locked
-- ==========================================
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('app.reg'), 'role', 'authenticated')::text, true);
do $$
declare n bigint;
begin
  update public.enrollments set status = 'Approved'
  where enrollment_id = current_setting('app.e240_bscs')::bigint;
  get diagnostics n = row_count;
  perform set_config('app.c246_approve', 'rows ' || n, true);
exception when others then
  perform set_config('app.c246_approve', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
do $$
declare n bigint;
begin
  delete from public.enrollment_items
  where enrollment_item_id = (select min(i.enrollment_item_id) from public.enrollment_items i
                               where i.enrollment_id = current_setting('app.e240_bscs')::bigint);
  get diagnostics n = row_count;
  perform set_config('app.c246_remove', 'rows ' || n, true);
exception when others then
  perform set_config('app.c246_remove', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
end $$;
select set_config('app.r246', (select format('approve [%s], status %s, reviewed_by_registrar %s, reviewed_at_now %s, remove_after [%s], items %s -> %s',
    current_setting('app.c246_approve'), e.status, e.reviewed_by::text = current_setting('app.reg'),
    e.reviewed_at = now(), split_part(current_setting('app.c246_remove'), ' because', 1),
    (select count(*) from public.enrollment_items i where i.enrollment_id = e.enrollment_id),
    case when current_setting('app.c246_approve') = 'rows 1' and e.status = 'Approved'
          and e.reviewed_by::text = current_setting('app.reg') and e.reviewed_at = now()
          and current_setting('app.c246_remove') like 'ERR [P0001]: enrollment locked:%'
          and (select count(*) from public.enrollment_items i where i.enrollment_id = e.enrollment_id) = 5
         then 'OK' else 'FAIL' end)
  from public.enrollments e where e.enrollment_id = current_setting('app.e240_bscs')::bigint), true);

-- ==========================================
-- 16. TC-247: items while Pending (BSIT's auto-created enrollment)
-- ==========================================
do $$
declare
  r record;
  n bigint;
begin
  for r in select * from (values
    (1, 'c247_remove', $q$delete from public.enrollment_items i
                          using public.sections sec, public.subjects s
                          where i.enrollment_id = current_setting('app.e240_bsit')::bigint
                            and sec.section_id = i.section_id and s.subject_id = sec.subject_id and s.code = 'IT104'$q$),
    (2, 'c247_wrong_term', $q$insert into public.enrollment_items (enrollment_id, section_id)
                              select current_setting('app.e240_bsit')::bigint, min(x.section_id)
                              from public.sections x where x.term_id = current_setting('app.real_term')::bigint$q$),
    (3, 'c247_duplicate', $q$insert into public.enrollment_items (enrollment_id, section_id)
                             select current_setting('app.e240_bsit')::bigint, min(i.section_id)
                             from public.enrollment_items i where i.enrollment_id = current_setting('app.e240_bsit')::bigint$q$)
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
select set_config('app.t247_items', (select count(*) from public.enrollment_items
  where enrollment_id = current_setting('app.e240_bsit')::bigint)::text, true);
-- Informational: the API paths as they are today (not judged; header D3 of the live file).
set local role authenticated;
do $$
declare
  r record;
  n bigint;
begin
  for r in select * from (values
    (1, 'c247_info_reg', 'reg', $q$delete from public.enrollment_items
                                   where enrollment_item_id = (select min(enrollment_item_id) from public.enrollment_items
                                                               where enrollment_id = current_setting('app.e240_bsit')::bigint)$q$),
    (2, 'c247_info_student', 'st_bsit', $q$delete from public.enrollment_items
                                   where enrollment_item_id = (select min(enrollment_item_id) from public.enrollment_items
                                                               where enrollment_id = current_setting('app.e240_bsit')::bigint)$q$)
  ) as t(ord, label, who, stmt) order by ord
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', current_setting('app.' || r.who), 'role', 'authenticated')::text, true);
    begin
      execute r.stmt;
      get diagnostics n = row_count;
      perform set_config('app.' || r.label, 'rows ' || n, true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
select set_config('app.r247', format('owner_remove [%s], items now %s, wrong_term [%s], duplicate [%s], info: registrar_api_delete [%s] student_api_delete [%s] -> %s',
  current_setting('app.c247_remove'), current_setting('app.t247_items'),
  split_part(current_setting('app.c247_wrong_term'), ',', 1), split_part(current_setting('app.c247_duplicate'), ' is', 1),
  current_setting('app.c247_info_reg'), current_setting('app.c247_info_student'),
  case when current_setting('app.c247_remove') = 'rows 1' and current_setting('app.t247_items') = '4'
        and current_setting('app.c247_wrong_term') like 'ERR [P0001]: wrong term:%'
        and current_setting('app.c247_duplicate') like 'ERR [P0001]: duplicate section:%'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- Result: ONE row. Every cell must end in "-> OK"; all_ok must be true.
-- ==========================================
select (current_setting('app.r234') like '%-> OK' and current_setting('app.r235') like '%-> OK'
        and current_setting('app.r236') like '%-> OK' and current_setting('app.r237') like '%-> OK'
        and current_setting('app.r238') like '%-> OK' and current_setting('app.r239') like '%-> OK'
        and current_setting('app.r240') like '%-> OK' and current_setting('app.r241') like '%-> OK'
        and current_setting('app.r242') like '%-> OK' and current_setting('app.r243') like '%-> OK'
        and current_setting('app.r244') like '%-> OK' and current_setting('app.r245') like '%-> OK'
        and current_setting('app.r246') like '%-> OK' and current_setting('app.r247') like '%-> OK') as all_ok,
  current_setting('app.r234') as tc234, current_setting('app.r235') as tc235, current_setting('app.r236') as tc236,
  current_setting('app.r237') as tc237, current_setting('app.r238') as tc238, current_setting('app.r239') as tc239,
  current_setting('app.r240') as tc240, current_setting('app.r241') as tc241, current_setting('app.r242') as tc242,
  current_setting('app.r243') as tc243, current_setting('app.r244') as tc244, current_setting('app.r245') as tc245,
  current_setting('app.r246') as tc246, current_setting('app.r247') as tc247;

rollback;
