-- ============================================================================================================
-- DEMO DATA: a grade history for student 2026-0008 (three past terms with approved enrollments and posted grades)
-- ============================================================================================================
-- Why: the Student dashboard (GWA by term, Progress, Current grades) shows one bar when a student has grades for only
-- one term. This adds three earlier terms so the charts look like a real record. It is DEMO data (fictional grades).
--
-- What it adds (all fictional, all inside ONE transaction because it is a single DO block):
--   * 3 past terms: 2nd 2024-2025, 1st 2025-2026, 2nd 2025-2026 (is_current = false; the current term is not touched)
--   * 15 subjects (codes CS121.., ON CONFLICT DO NOTHING) and one section per subject and term ('A')
--   * 3 Approved enrollments for student 2026-0008 (reviewed by registrar@pnc.test) with their items
--   * 15 grades (units-weighted GWA about 2.14, 1.95 and 1.65; the current term stays 1.75)
-- What it does NOT touch: the current term, the student's current enrollment, clearance, charges, queue, accounts.
--
-- How the rules are handled: the enrollment rules only allow a new Pending enrollment and an item only while Pending,
-- so for the length of this block (run as the table owner in the SQL editor) the two enrollment triggers are switched
-- OFF and switched back ON at the end, together with the two notification triggers (so the student does not get 15
-- "new grade" notifications for old grades). Audit rows ARE written (no actor). If anything fails, everything rolls back.
--
-- Run order: 1) the rehearsal (v_dry = true: does everything, then raises an exception with the numbers, so nothing
-- is kept), 2) the live file (v_dry = false). Both files are the same except the one line `v_dry`.
-- Undo (owner, if ever needed): delete the grades, enrollment_items, enrollments, sections of the three past terms
-- of student 2026-0008, then the terms; the audit rows stay (append-only).
-- ============================================================================================================

DO $demo$
DECLARE
  v_dry     constant boolean := true;       -- REHEARSAL: nothing is kept (the live file has false)
  v_student uuid;
  v_reg     uuid;
  v_n       integer;
  v_summary text;
  t         record;
BEGIN
  SELECT s.student_id INTO v_student FROM public.students s WHERE s.student_number = '2026-0008';
  IF v_student IS NULL THEN RAISE EXCEPTION 'demo history: student 2026-0008 not found'; END IF;
  SELECT p.profile_id INTO v_reg FROM public.profiles p WHERE p.email = 'registrar@pnc.test';
  IF v_reg IS NULL THEN RAISE EXCEPTION 'demo history: registrar@pnc.test not found'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.departments WHERE code = 'CCS') OR NOT EXISTS (SELECT 1 FROM public.departments WHERE code = 'CAS') THEN
    RAISE EXCEPTION 'demo history: departments CCS and CAS are needed';
  END IF;

  -- 1. switch the enrollment rules and the notifications off for this block
  ALTER TABLE public.enrollments DISABLE TRIGGER require_enrollment_rules;
  ALTER TABLE public.enrollment_items DISABLE TRIGGER require_enrollment_item_rules;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.enrollments'::regclass AND tgname = 'trg_notify_enrollments') THEN
    ALTER TABLE public.enrollments DISABLE TRIGGER trg_notify_enrollments;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.grades'::regclass AND tgname = 'trg_notify_grades') THEN
    ALTER TABLE public.grades DISABLE TRIGGER trg_notify_grades;
  END IF;

  -- 2. past terms
  INSERT INTO public.terms (school_year, semester, start_date, end_date, is_current)
  SELECT v.sy, v.sem, v.s::date, v.e::date, false
  FROM (VALUES ('2024-2025', '2nd', '2025-01-13', '2025-05-30'),
               ('2025-2026', '1st', '2025-08-04', '2025-12-19'),
               ('2025-2026', '2nd', '2026-01-12', '2026-05-29')) AS v(sy, sem, s, e)
  WHERE NOT EXISTS (SELECT 1 FROM public.terms x WHERE x.school_year = v.sy AND x.semester = v.sem);

  -- 3. subjects (code is unique; an existing code is left as it is)
  INSERT INTO public.subjects (department_id, code, title, units)
  SELECT d.department_id, v.code, v.title, v.units
  FROM (VALUES
    ('CAS', 'GE102',    'Readings in Philippine History',   3), ('CAS', 'MATH102', 'Discrete Mathematics',          3),
    ('CCS', 'CS121',    'Computer Programming 2',           3), ('CCS', 'CS122',   'Digital Logic Design',          3),
    ('CAS', 'PE101',    'Physical Fitness 1',               2),
    ('CCS', 'CS131',    'Data Structures and Algorithms',   3), ('CCS', 'CS132',   'Object-Oriented Programming',   3),
    ('CAS', 'MATH103',  'Linear Algebra',                   3), ('CAS', 'GE103',   'Ethics',                        3),
    ('CCS', 'CS133',    'Computer Organization and Architecture', 3),
    ('CCS', 'CS141',    'Database Systems',                 3), ('CCS', 'CS142',   'Operating Systems',             3),
    ('CCS', 'CS143',    'Web Development',                  3), ('CAS', 'MATH104', 'Probability and Statistics',    3),
    ('CAS', 'PE102',    'Physical Fitness 2',               2)
  ) AS v(dept, code, title, units)
  JOIN public.departments d ON d.code = v.dept
  ON CONFLICT (code) DO NOTHING;

  -- the plan: term, subject, schedule, grade
  CREATE TEMP TABLE _plan (sy text, sem text, code text, sched text, grade text, yr smallint) ON COMMIT DROP;
  INSERT INTO _plan VALUES
    ('2024-2025','2nd','GE102',   'MWF 8-9 AM',      '2.00', 1), ('2024-2025','2nd','MATH102', 'TTh 9-10:30 AM',  '2.50', 1),
    ('2024-2025','2nd','CS121',   'MWF 10-11 AM',    '2.25', 1), ('2024-2025','2nd','CS122',   'TTh 1-2:30 PM',   '2.25', 1),
    ('2024-2025','2nd','PE101',   'F 1-3 PM',        '1.50', 1),
    ('2025-2026','1st','CS131',   'MWF 8-9 AM',      '2.00', 2), ('2025-2026','1st','CS132',   'TTh 9-10:30 AM',  '1.75', 2),
    ('2025-2026','1st','MATH103', 'MWF 10-11 AM',    '2.25', 2), ('2025-2026','1st','GE103',   'TTh 1-2:30 PM',   '1.75', 2),
    ('2025-2026','1st','CS133',   'MWF 1-2 PM',      '2.00', 2),
    ('2025-2026','2nd','CS141',   'MWF 8-9 AM',      '1.50', 2), ('2025-2026','2nd','CS142',   'TTh 9-10:30 AM',  '1.75', 2),
    ('2025-2026','2nd','CS143',   'MWF 10-11 AM',    '1.50', 2), ('2025-2026','2nd','MATH104', 'TTh 1-2:30 PM',   '2.00', 2),
    ('2025-2026','2nd','PE102',   'F 1-3 PM',        '1.25', 2);

  -- 4. one section 'A' per subject and term
  INSERT INTO public.sections (subject_id, term_id, section_code, schedule, capacity)
  SELECT s.subject_id, tm.term_id, 'A', p.sched, 40
  FROM _plan p
  JOIN public.subjects s ON s.code = p.code
  JOIN public.terms tm ON tm.school_year = p.sy AND tm.semester = p.sem
  WHERE NOT EXISTS (SELECT 1 FROM public.sections x WHERE x.subject_id = s.subject_id AND x.term_id = tm.term_id AND x.section_code = 'A');

  -- 5. Approved enrollments (one per past term), reviewed by the Registrar a few days after the term started
  INSERT INTO public.enrollments (student_id, term_id, year_level, status, submitted_at, reviewed_by, reviewed_at)
  SELECT v_student, tm.term_id, y.yr, 'Approved', tm.start_date::timestamptz - interval '10 days', v_reg, tm.start_date::timestamptz - interval '8 days'
  FROM (SELECT DISTINCT sy, sem, yr FROM _plan) y
  JOIN public.terms tm ON tm.school_year = y.sy AND tm.semester = y.sem
  WHERE NOT EXISTS (SELECT 1 FROM public.enrollments e WHERE e.student_id = v_student AND e.term_id = tm.term_id);

  -- 6. items
  INSERT INTO public.enrollment_items (enrollment_id, section_id)
  SELECT e.enrollment_id, sec.section_id
  FROM _plan p
  JOIN public.terms tm ON tm.school_year = p.sy AND tm.semester = p.sem
  JOIN public.subjects s ON s.code = p.code
  JOIN public.sections sec ON sec.subject_id = s.subject_id AND sec.term_id = tm.term_id AND sec.section_code = 'A'
  JOIN public.enrollments e ON e.student_id = v_student AND e.term_id = tm.term_id
  WHERE NOT EXISTS (SELECT 1 FROM public.enrollment_items x WHERE x.enrollment_id = e.enrollment_id AND x.section_id = sec.section_id);

  -- 7. grades (the grades trigger still runs: an item of an Approved enrollment only)
  INSERT INTO public.grades (enrollment_item_id, grade_code, encoded_by)
  SELECT ei.enrollment_item_id, p.grade, v_reg
  FROM _plan p
  JOIN public.terms tm ON tm.school_year = p.sy AND tm.semester = p.sem
  JOIN public.subjects s ON s.code = p.code
  JOIN public.sections sec ON sec.subject_id = s.subject_id AND sec.term_id = tm.term_id AND sec.section_code = 'A'
  JOIN public.enrollments e ON e.student_id = v_student AND e.term_id = tm.term_id
  JOIN public.enrollment_items ei ON ei.enrollment_id = e.enrollment_id AND ei.section_id = sec.section_id
  ON CONFLICT (enrollment_item_id) DO NOTHING;

  -- 8. the triggers back on
  ALTER TABLE public.enrollments ENABLE TRIGGER require_enrollment_rules;
  ALTER TABLE public.enrollment_items ENABLE TRIGGER require_enrollment_item_rules;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.enrollments'::regclass AND tgname = 'trg_notify_enrollments') THEN
    ALTER TABLE public.enrollments ENABLE TRIGGER trg_notify_enrollments;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.grades'::regclass AND tgname = 'trg_notify_grades') THEN
    ALTER TABLE public.grades ENABLE TRIGGER trg_notify_grades;
  END IF;

  -- 9. checks: every trigger is back on, three past enrollments Approved, 15 grades, one current term unchanged
  SELECT count(*) INTO v_n FROM pg_trigger
   WHERE tgname IN ('require_enrollment_rules', 'require_enrollment_item_rules', 'trg_notify_enrollments', 'trg_notify_grades')
     AND tgenabled <> 'O';
  IF v_n <> 0 THEN RAISE EXCEPTION 'demo history: % trigger(s) not enabled again', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.terms WHERE is_current;
  IF v_n <> 1 THEN RAISE EXCEPTION 'demo history: expected exactly one current term, found %', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.grades g
    JOIN public.enrollment_items ei ON ei.enrollment_item_id = g.enrollment_item_id
    JOIN public.enrollments e ON e.enrollment_id = ei.enrollment_id
    JOIN public.terms tm ON tm.term_id = e.term_id
   WHERE e.student_id = v_student AND e.status = 'Approved' AND NOT tm.is_current;
  IF v_n < 15 THEN RAISE EXCEPTION 'demo history: expected 15 past grades, found %', v_n; END IF;

  SELECT string_agg(x.line, '; ' ORDER BY x.start_date) INTO v_summary FROM (
    SELECT tm.start_date, tm.semester || ' ' || tm.school_year || ': ' || count(*) || ' grades, GWA '
           || round(sum(gs.numeric_value * sb.units) / sum(sb.units), 2) AS line
    FROM public.grades g
    JOIN public.grade_scale gs ON gs.grade_code = g.grade_code
    JOIN public.enrollment_items ei ON ei.enrollment_item_id = g.enrollment_item_id
    JOIN public.sections sec ON sec.section_id = ei.section_id
    JOIN public.subjects sb ON sb.subject_id = sec.subject_id
    JOIN public.enrollments e ON e.enrollment_id = ei.enrollment_id
    JOIN public.terms tm ON tm.term_id = e.term_id
    WHERE e.student_id = v_student
    GROUP BY tm.term_id, tm.start_date, tm.semester, tm.school_year) x;

  IF v_dry THEN
    RAISE EXCEPTION 'REHEARSAL OK, nothing kept. %', v_summary;
  END IF;
END
$demo$;

-- Result (live file): one row per term of the student with the number of grades and the GWA.
SELECT tm.semester || ' ' || tm.school_year AS term, tm.start_date, count(*) AS grades,
       round(sum(gs.numeric_value * sb.units) / sum(sb.units), 2) AS gwa
FROM public.grades g
JOIN public.grade_scale gs ON gs.grade_code = g.grade_code
JOIN public.enrollment_items ei ON ei.enrollment_item_id = g.enrollment_item_id
JOIN public.sections sec ON sec.section_id = ei.section_id
JOIN public.subjects sb ON sb.subject_id = sec.subject_id
JOIN public.enrollments e ON e.enrollment_id = ei.enrollment_id
JOIN public.terms tm ON tm.term_id = e.term_id
JOIN public.students st ON st.student_id = e.student_id AND st.student_number = '2026-0008'
GROUP BY tm.term_id, tm.start_date, tm.semester, tm.school_year
ORDER BY tm.start_date;
