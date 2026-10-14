-- ==========================================
-- AUTO FIRST-YEAR ENROLLMENT: CURRICULUM, APPLICANT TYPE, ENROLLMENT FUNCTION
-- (feature/auto-first-year)
-- ==========================================
-- PM decision (approved): when the Registrar accepts a NEW student's application, the student
-- gets a Year 1 enrollment for the current term with the fixed first-year, 1st-semester
-- subjects of their program (no picking). The enrollment stays Pending for the Registrar to
-- approve. Dropping a subject stays a Registrar action. A TRANSFEREE is not auto-enrolled
-- (keeps the current pick-your-own path). Existing students are untouched (nothing here runs
-- for them; the function is only called by the app for a newly provisioned student).
-- Runs AFTER enrollment_rules.sql, applications_rules.sql, applications_server_grants.sql,
-- catalog_grants.sql (all live). Independent of the queue and notification files.
--
-- WHAT IT DOES
--   1. New table public.program_curriculum (RLS on):
--        program_id  bigint   NOT NULL  FK programs
--        year_level  smallint NOT NULL  CHECK 1..6
--        semester    text     NOT NULL  CHECK '1st' | '2nd' | 'Summer'
--        subject_id  bigint   NOT NULL  FK subjects
--        PRIMARY KEY (program_id, year_level, semester, subject_id); index on subject_id.
--      Policy program_curriculum_read: SELECT for every signed-in user (USING true, the same
--      as subjects_read). Grants: authenticated SELECT only; anon and PUBLIC nothing; the
--      server role SELECT only. Writes: the table owner only (SQL editor), on purpose: there
--      is no Admin screen for the curriculum yet (see NOTES).
--   2. SAMPLE DATA (not a real curriculum; replace it when the school gives the real one):
--        BSCS: CS111 Introduction to Programming, CS112 Discrete Mathematics, MATH101
--              Calculus, CS113 Web Development, CS114 Human-Computer Interaction
--        BSIT: IT101 Introduction to Programming, IT102 Discrete Mathematics, IT103 Web
--              Development, IT104 Computer Hardware and Networking Basics, GE101 (existing)
--        BSBA: BA101 Principles of Management, BA102 Business Mathematics, BA103
--              Fundamentals of Accounting, BA104 Introduction to Marketing, GE101 (existing)
--      All 3 units. Departments: CS*, IT* -> CCS; BA* -> CBA; MATH*, GE* -> CAS.
--      Subjects: INSERT ... ON CONFLICT (code) DO NOTHING: a code that already exists is used
--      as it is (never renamed or changed; the Admin may have edited the live catalog; the
--      file prints a NOTICE listing such codes).
--      Sections: ONE section 'A' (capacity 40, schedule like "MWF 8:00-9:00") in the CURRENT
--      term for each of the 13 sample codes, only when that subject has NO section in the
--      current term yet (so no duplicates, and a re-run adds nothing). GE101 already has a
--      section; it gets none (the check after the change stops if it has none).
--      Curriculum rows: year 1, semester '1st', 5 per program (ON CONFLICT DO NOTHING).
--   3. applications.applicant_type text NOT NULL DEFAULT 'New', CHECK
--      ck_applications_applicant_type (applicant_type IN ('New', 'Transferee')). Existing
--      applications become 'New' (they are all decided or pending first-time applicants; no
--      app logic runs on old rows).
--   4. public.submit_application gains ONE optional parameter (see "THE submit_application
--      CHANGE" below):
--        old: submit_application(p_first_name text, p_last_name text, p_email text,
--                                p_mobile text, p_program_id bigint) RETURNS void
--        new: submit_application(p_first_name text, p_last_name text, p_email text,
--                                p_mobile text, p_program_id bigint,
--                                p_applicant_type text DEFAULT 'New') RETURNS void
--   5. New function public.create_first_year_enrollment(p_student_id uuid) RETURNS bigint
--      (SECURITY DEFINER, owner postgres, search_path '', every name schema-qualified).
--      EXECUTE: the server role ONLY (not PUBLIC, not anon, not authenticated).
--
-- THE submit_application CHANGE (why and how; the riskiest part of this file)
--   Why a new parameter instead of a second function: the public form already calls
--   submit_application through PostgREST with named arguments; a 6th parameter WITH A DEFAULT
--   keeps every existing call working unchanged (the current app sends 5 named arguments and
--   gets applicant_type 'New').
--   Why DROP the old signature: PostgreSQL identifies a function by its argument types. With
--   both submit_application(5 args) and submit_application(6 args, last DEFAULT) present, a
--   5-argument call matches both and fails ("function ... is not unique"), and PostgREST would
--   also see two candidates. So the old one is dropped and the new one created in the SAME
--   transaction; nobody can observe a moment without the function.
--   Body: copied verbatim from applications_rules.sql section 6 (validation, flood valve,
--   per-email advisory lock, silent duplicate / existing account / cap), plus: the applicant
--   type is validated after the program and before anything that reads existing data:
--     NULL, '' or blank -> 'New'; else btrim(value) must be exactly 'New' or 'Transferee'
--     (case-sensitive), otherwise SQLSTATE 22023 "invalid application: applicant_type must
--     be New or Transferee" (same prefix and code as the other field errors).
--   Safety check (k) stops the file when the live body does not contain the markers of the
--   applications_rules.sql body (so a body changed outside this repo is not overwritten).
--   EXECUTE rights: the grantees of the live function (every role with EXECUTE, except the
--   owner) are read BEFORE the drop and given EXECUTE on the new function, nothing else
--   (PUBLIC and Supabase's default grants on new functions are removed first). Safety check
--   (k) requires today's state: PUBLIC none, anon and authenticated EXECUTE. The check after
--   the change compares the grantee list before and after (must be identical).
--   Consequence for OLDER test files (not edited here): they name the old signature
--   'public.submit_application(text, text, text, text, bigint)' (applications_rules_test.sql
--   setup and TC-123, login_lockout_test.sql TC-81, student_id_login, queue and notification
--   tests' anon function lists). After this file they must use
--   'public.submit_application(text, text, text, text, bigint, text)'. Their positional
--   5-argument calls still work (the 6th argument defaults to 'New').
--
-- THE FUNCTION public.create_first_year_enrollment(p_student_id uuid) RETURNS bigint
--   1. Locks the student's row (FOR UPDATE), so two calls for the same student, and a
--      student's own enrollment insert, run one after the other.
--   2. Refuses an unknown (or NULL) student: P0001 "unknown student: ...".
--   3. Finds the current term (exactly one row with is_current; else P0001 "no current
--      term: ...").
--   4. IDEMPOTENT: when the student already has an enrollment for the current term (any
--      status, auto-created or picked by the student), returns ITS id and changes nothing.
--      There is never a second enrollment (also the unique key uq_enrollments_student_term).
--   5. Reads the curriculum rows of the student's program for year 1, semester '1st' (the
--      PM's fixed set, also when the current term is a 2nd semester or Summer; see NOTES).
--      None -> P0001 "no curriculum: ...".
--   6. Every curriculum subject must have a section in the current term; otherwise P0001
--      "no section: ..." listing the subject codes. Checked BEFORE anything is written.
--   7. Inserts ONE enrollment (term = current, year_level 1, status 'Pending') and one
--      enrollment_items row per curriculum subject, using that subject's section in the
--      current term with the LOWEST section_id. Returns the new enrollment_id.
--   All of it is one function call = one statement = all-or-nothing: any error (its own or
--   a trigger's) undoes everything the call wrote.
--   How it passes the existing triggers (enrollment_rules.sql, read before writing this):
--     require_enrollment_rules / require_enrollment_item_rules decide "who is calling" with
--     auth.uid() only (v_uid). The app calls this function with the Supabase server-side
--     (admin) client; its JWT has a role claim but no "sub", so auth.uid() is NULL inside
--     the function and inside the triggers: that is the OWNER / no-JWT path, on which every
--     rule still runs (insert must be Pending, one enrollment per student and term, items
--     only while Pending, section of the same term, no section twice). The function inserts
--     Pending, checks the existing enrollment first, and uses sections of the current term
--     only, so it satisfies all of them. If a user JWT were ever present (auth.uid() not
--     NULL), the same rules run (the Registrar path) or RLS is bypassed anyway because the
--     function runs as its owner; nothing in the function depends on auth.uid().
--     SECURITY DEFINER (owner postgres, owner of the tables, no FORCE RLS; safety check (n))
--     is needed because the server role has no INSERT on enrollments / enrollment_items
--     (hardening2.sql section C), and this way it needs none.
--     Audit: the existing audit_log triggers record the enrollment and its items with
--     actor_id NULL (no user JWT), like the provisioning steps. The notifications trigger
--     (trg_notify_enrollments) fires as for any new Pending enrollment.
--   Errors (PostgREST: code = SQLSTATE, message = text; HTTP 400 for P0001):
--     P0001 "unknown student: ..."   no students row for p_student_id (or NULL)
--     P0001 "no current term: ..."   zero (or, impossible with uq_terms_one_current_term,
--                                    more than one) current term
--     P0001 "no curriculum: ..."     the program has no year 1 / '1st' curriculum rows
--     P0001 "no section: ..."        a curriculum subject has no section in the current term
--     P0001 "enrollment exists: ..." (from the trigger) only in a race with a parallel
--                                    insert for the same student; retry returns the id
--     23505                          the unique key, same race (should not happen: the row
--                                    lock in step 1 serialises)
--     42501 "permission denied for function create_first_year_enrollment"  any caller but
--                                    the server role (anon, authenticated)
--   WHO DECIDES "NEW vs TRANSFEREE": the APP. The function does NOT read
--   applications.applicant_type (a student may have no application row: seed students,
--   students created by the Admin). The server-side provisioning code must call it ONLY when
--   the accepted application has applicant_type = 'New'. For a Transferee it must not be
--   called (the student picks sections as today). Calling it for a Transferee would work
--   technically (it creates the 1st-semester set); the guard is the app's.
--
-- HOW THE APP USES IT (contract; the app change is a separate task)
--   Public form (anon): rpc('submit_application', { p_first_name, p_last_name, p_email,
--     p_mobile, p_program_id, p_applicant_type: 'New' | 'Transferee' })
--     p_applicant_type may be left out (= 'New'). New error: 22023 "invalid application:
--     applicant_type must be New or Transferee".
--   Registrar screen: applications.applicant_type is readable (authenticated has table-level
--     SELECT on applications; add the column to the app's select list and types).
--   Server side, server role, after provisioning succeeded (student row exists, application
--     linked) and ONLY when applicant_type = 'New':
--       admin.rpc('create_first_year_enrollment', { p_student_id: <new student uuid> })
--       -> data = enrollment_id (number). Safe to retry (idempotent). On "no curriculum:" /
--       "no section:" the account is still fine: tell the Registrar to set up the sections
--       or to enroll the student by hand; do NOT undo the account.
--
-- DESIGN DECISIONS AND LIMITS
--   D1 Curriculum writes: owner only (no grant to authenticated, no Admin policy). An Admin
--      screen would need a policy + column grants later.
--   D2 program_curriculum is NOT audited: private.audit_log() needs a single-column primary
--      key and this table's key has four columns. Changes are rare and done in the SQL
--      editor (reviewed files).
--   D3 One section per subject is chosen automatically (lowest section_id in the term). The
--      Registrar can drop an item while the enrollment is Pending. NOTE: the existing policy
--      enrollment_items_student_remove (and _student_add) still let the STUDENT remove or add
--      items of their own Pending enrollment; this file does not change policies (it would
--      also change the transferee path). There is NO Registrar DELETE policy on
--      enrollment_items: a Registrar "drop" through the API with the user session removes 0
--      rows; it must go through the server-side admin client (owner path, the trigger still
--      requires Pending) or a new policy. PM decision (see NOTES).
--   D4 Capacity is not checked when the enrollment is created (same as enrollment_rules.sql
--      decision 4): a full section is reported at approval ("section full:").
--   D5 year_level is always 1; the student's profile is not checked for is_active (a new
--      account is active).
--   D6 Grants snapshot convention: grants are not exported from live, so the "before" state
--      of the objects touched here is captured by diagnostics (a) and (b) below; save their
--      output (like grants_snapshot_2026-10-11.txt, writing "server role" instead of the
--      role's real name) before running the file.
--   D7 The server role's name is never written in this repo: where SQL needs it, it is built
--      as 'service' || '_role' (a role-name string, never a key).
--
-- How to run: Supabase SQL editor, as postgres (the owner of the tables), at a quiet time
-- (ALTER TABLE takes a short ACCESS EXCLUSIVE lock on applications). Copy from "BEGIN;" to
-- "COMMIT;" inclusive into a new tab and run that tab as a whole (never a partial selection).
-- One transaction: any error, including a failed check, rolls back everything. Re-runnable:
-- CREATE TABLE IF NOT EXISTS (with a shape check), ON CONFLICT DO NOTHING, sections only
-- when missing, ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE, grants rebuilt.
--   - Before running: run diagnostics (a), (b) and (c) below and SAVE the output.
--   - Rehearse first: docs/database/first_year_curriculum_rehearsal.sql (this change and
--     TC-234 to TC-247 in ONE rolled-back transaction, one result row).
--   - Test afterwards: docs/database/first_year_curriculum_test.sql (TC-234 to TC-247), then
--     regression_after_grants.sql (unchanged results expected).
--   - Deploy the app change (applicant type on the form, the RPC call after provisioning)
--     only AFTER this file is live. The current app keeps working: its 5-argument call is
--     still valid.
-- Undo: the ROLLBACK block below (comments; run it on purpose, as a whole).
--
-- Status: NOT RUN YET (written 2026-10-14 without a local PostgreSQL; rehearse first).
--
-- ------------------------------------------
-- ROLLBACK (back to the state before this file; remove the app calls FIRST)
-- ------------------------------------------
-- Enrollments already created by create_first_year_enrollment are real student data and are
-- NOT removed. Dropping applicant_type loses the New / Transferee answers. Sample sections
-- and subjects are deleted only when this file created them (exact sample code, title,
-- section 'A', sample schedule) and nothing uses them; any other row stays. The old
-- submit_application body is verbatim from applications_rules.sql section 6.
--
-- BEGIN;
--
-- DROP FUNCTION IF EXISTS public.create_first_year_enrollment(uuid);
--
-- DROP FUNCTION IF EXISTS public.submit_application(text, text, text, text, bigint, text);
-- CREATE OR REPLACE FUNCTION public.submit_application(
--   p_first_name text,
--   p_last_name  text,
--   p_email      text,
--   p_mobile     text,
--   p_program_id bigint)
--  RETURNS void
--  LANGUAGE plpgsql
--  VOLATILE
--  SECURITY DEFINER
--  SET search_path TO ''
-- AS $function$
-- DECLARE
--   s        record;
--   v_first  text := private.application_name(p_first_name, 'first_name');
--   v_last   text := private.application_name(p_last_name, 'last_name');
--   v_email  text := private.application_email(p_email);
--   v_mobile text := private.application_mobile(p_mobile);
-- BEGIN
--   SELECT * INTO STRICT s FROM private.application_settings();
--
--   IF p_program_id IS NULL
--      OR NOT EXISTS (SELECT 1 FROM public.programs p WHERE p.program_id = p_program_id) THEN
--     RAISE EXCEPTION 'invalid application: program_id is not an offered program' USING ERRCODE = '22023';
--   END IF;
--
--   IF (SELECT pg_catalog.count(*) FROM public.applications a
--        WHERE a.submitted_at > pg_catalog.now() - interval '1 hour') >= s.max_per_hour THEN
--     RAISE EXCEPTION 'try later: the enrollment site received too many applications in the last hour'
--       USING ERRCODE = 'P0001';
--   END IF;
--
--   PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('applications:' || v_email, 0));
--
--   IF EXISTS (SELECT 1 FROM public.applications a
--               WHERE a.email = v_email AND a.status::text IN ('Pending', 'Accepted'))
--      OR EXISTS (SELECT 1 FROM public.profiles p WHERE pg_catalog.lower(pg_catalog.btrim(p.email::text)) = v_email)
--      OR EXISTS (SELECT 1 FROM auth.users u WHERE pg_catalog.lower(pg_catalog.btrim(u.email::text)) = v_email)
--      OR (SELECT pg_catalog.count(*) FROM public.applications a
--           WHERE a.email = v_email AND a.submitted_at > pg_catalog.now() - s.per_email_window) >= s.max_per_email THEN
--     RETURN;
--   END IF;
--
--   INSERT INTO public.applications (first_name, last_name, email, mobile, program_id)
--   VALUES (v_first, v_last, v_email, v_mobile, p_program_id);
-- END
-- $function$;
-- REVOKE ALL ON FUNCTION public.submit_application(text, text, text, text, bigint) FROM PUBLIC, anon, authenticated;
-- GRANT EXECUTE ON FUNCTION public.submit_application(text, text, text, text, bigint) TO anon, authenticated;
-- -- compare with the saved diagnostic (b): the server role kept the EXECUTE that Supabase's
-- -- default privileges give a new function; nothing else is expected.
--
-- ALTER TABLE public.applications DROP CONSTRAINT IF EXISTS ck_applications_applicant_type;
-- ALTER TABLE public.applications DROP COLUMN IF EXISTS applicant_type;
--
-- DROP TABLE IF EXISTS public.program_curriculum;
--
-- DELETE FROM public.sections x
-- USING public.subjects s,
--   (VALUES ('CS111', 'MWF 8:00-9:00'), ('CS112', 'MWF 9:00-10:00'), ('MATH101', 'MWF 11:00-12:00'),
--           ('CS113', 'TTh 8:00-9:30'), ('CS114', 'TTh 9:30-11:00'),
--           ('IT101', 'MWF 8:00-9:00'), ('IT102', 'MWF 9:00-10:00'), ('IT103', 'TTh 8:00-9:30'),
--           ('IT104', 'TTh 9:30-11:00'),
--           ('BA101', 'MWF 8:00-9:00'), ('BA102', 'MWF 9:00-10:00'), ('BA103', 'TTh 8:00-9:30'),
--           ('BA104', 'TTh 9:30-11:00')) AS v(code, schedule)
-- WHERE s.subject_id = x.subject_id AND s.code = v.code
--   AND x.section_code = 'A' AND x.schedule = v.schedule AND x.capacity = 40
--   AND NOT EXISTS (SELECT 1 FROM public.enrollment_items i WHERE i.section_id = x.section_id);
--
-- DELETE FROM public.subjects s
-- USING (VALUES ('CS111', 'Introduction to Programming'), ('CS112', 'Discrete Mathematics'),
--               ('MATH101', 'Calculus'), ('CS113', 'Web Development'), ('CS114', 'Human-Computer Interaction'),
--               ('IT101', 'Introduction to Programming'), ('IT102', 'Discrete Mathematics'),
--               ('IT103', 'Web Development'), ('IT104', 'Computer Hardware and Networking Basics'),
--               ('BA101', 'Principles of Management'), ('BA102', 'Business Mathematics'),
--               ('BA103', 'Fundamentals of Accounting'), ('BA104', 'Introduction to Marketing')) AS v(code, title)
-- WHERE s.code = v.code AND s.title = v.title AND s.units = 3
--   AND NOT EXISTS (SELECT 1 FROM public.sections x WHERE x.subject_id = s.subject_id);
--
-- NOTIFY pgrst, 'reload schema';
--
-- COMMIT;
--
-- ------------------------------------------
-- DIAGNOSTICS (read-only; run one at a time BEFORE and AFTER, save the output)
-- ------------------------------------------
-- a) Grants on applications, sections, subjects (table and column ACLs) and, after the run,
--    program_curriculum:
-- select c.relname, c.relacl::text as table_acl,
--        (select string_agg(a.attname || '=' || a.attacl::text, '; ' order by a.attnum)
--           from pg_attribute a where a.attrelid = c.oid and a.attacl is not null) as column_acls
-- from pg_class c
-- where c.relnamespace = 'public'::regnamespace
--   and c.relname in ('applications', 'sections', 'subjects', 'program_curriculum')
-- order by 1;
--
-- b) The submit_application and create_first_year_enrollment signatures and ACLs:
-- select p.oid::regprocedure as signature, p.prosecdef, p.proconfig, p.proowner::regrole, p.proacl::text
-- from pg_proc p
-- where p.pronamespace = 'public'::regnamespace
--   and p.proname in ('submit_application', 'create_first_year_enrollment')
-- order by 1;
--
-- c) The sample codes that already exist (they are kept as they are) and their sections in
--    the current term:
-- select s.code, s.title, s.units, d.code as dept,
--        (select string_agg(x.section_code || ' ' || coalesce(x.schedule, '') || ' cap ' || x.capacity, '; ')
--           from public.sections x join public.terms t on t.term_id = x.term_id and t.is_current
--          where x.subject_id = s.subject_id) as current_sections
-- from public.subjects s join public.departments d on d.department_id = s.department_id
-- where s.code in ('CS111', 'CS112', 'MATH101', 'CS113', 'CS114', 'IT101', 'IT102', 'IT103',
--                  'IT104', 'BA101', 'BA102', 'BA103', 'BA104', 'GE101')
-- order by 1;
--
-- d) AFTER: the curriculum with the section the function would pick (lowest id):
-- select p.code as program, c.year_level, c.semester, s.code, s.title,
--        (select min(x.section_id) from public.sections x join public.terms t on t.term_id = x.term_id and t.is_current
--          where x.subject_id = c.subject_id) as section_picked
-- from public.program_curriculum c
-- join public.programs p on p.program_id = c.program_id
-- join public.subjects s on s.subject_id = c.subject_id
-- order by 1, 2, 3, 4;
--
-- ------------------------------------------
-- NOTES FOR THE PM (decisions, not done here)
-- ------------------------------------------
-- - The subject set is SAMPLE data. Replace it with the real curriculum (owner, SQL editor).
-- - The function always uses year 1 / semester '1st' (as decided). A new student accepted
--   while a 2nd-semester term is current still gets the 1st-semester set; changing that is
--   one line (use the current term's semester) plus 2nd-semester curriculum rows.
-- - Who may drop subjects (D3): today the student can remove / add items of a Pending
--   enrollment (existing policies), and the Registrar has no DELETE policy. If "dropping is
--   a Registrar action" must be enforced, a policy change on enrollment_items is needed
--   (and the transferee pick path must keep working).
-- - An Admin screen for the curriculum would need an Admin policy and grants (D1).


BEGIN;

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

COMMIT;
