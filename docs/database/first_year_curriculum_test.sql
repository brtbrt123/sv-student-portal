-- ==========================================
-- TESTS TC-234 to TC-247 for first_year_curriculum.sql (auto first-year enrollment)
-- ==========================================
-- Run AFTER first_year_curriculum.sql is live (or use first_year_curriculum_rehearsal.sql,
-- which runs the change and these tests together). This file is the same as the test part of
-- the rehearsal (from its "TESTS START HERE" marker).
--
-- How to run: Supabase SQL editor, as postgres, a new tab, at a quiet time (TC-236 / TC-240
-- briefly switch the current term inside the transaction, TC-238 / TC-239 delete rows inside
-- a sub-block that is undone at once). Paste the whole file and click Run on the whole tab,
-- never a selection. It ends in rollback: nothing is committed. If it stops with an error,
-- run "rollback;" as its own query and send the error back.
--
-- Data (all inside the transaction, undone by the rollback):
--   - No new Auth user is created (profiles.profile_id references auth.users, and no test
--     in this repo writes auth.users). The "new students" are existing students (the seed
--     students of BSCS / BSIT / BSBA if present, else the first student of each program)
--     made NEW for the function by a throwaway CURRENT term 2088-2089 '1st': the real
--     current term is set to is_current = false and 2088-2089 becomes current, so none of
--     them has an enrollment in the current term. Throwaway sections Z234 / Z234Y are added
--     to 2088-2089 for every curriculum subject (Z234Y only for CS111, created first, so the
--     "lowest section_id" rule is visible).
--   - Applications under @firstyear.test (no profile / Auth user may exist there; checked).
--   - TC-238 / TC-239 delete the BSBA curriculum rows / the IT104 section of 2088-2089
--     inside a sub-block; the function's error undoes the delete at once.
-- Users are simulated with SET LOCAL ROLE authenticated + request.jwt.claims (sub = the
-- user's id); anon with SET LOCAL ROLE anon; the server role with SET LOCAL ROLE to it and a
-- JWT without "sub" (when postgres may not switch to it, the call runs as postgres without
-- a JWT, which is the same trigger path: auth.uid() NULL; the cell says which mode ran).
-- Its name is built as 'service' || '_role'.
--
-- Result: ONE row, all_ok plus one cell per case ending in "-> OK" or "-> FAIL". Every
-- statement expected to fail runs inside a do block with an exception handler and is
-- recorded as "ERR [SQLSTATE]: message"; a statement that ran is "rows N" or "id N".
--
--   TC-234 installed as intended (program_curriculum shape, keys, RLS, policy, privileges;
--          create_first_year_enrollment properties and EXECUTE (server role only);
--          applications.applicant_type; submit_application new signature only, anon and
--          authenticated EXECUTE)
--   TC-235 sample curriculum: BSCS / BSIT / BSBA have exactly the 5 sample subjects (year 1,
--          1st) and each has a section in the real current term
--   TC-236 a student who already has an enrollment in the current term: the function
--          returns THAT id and changes nothing
--   TC-237 an unknown student id (and NULL) is refused: P0001 "unknown student:"
--   TC-238 a program without curriculum rows is refused: P0001 "no curriculum:"; nothing
--          written
--   TC-239 a curriculum subject without a section in the current term: P0001 "no section:"
--          (names the subject); nothing written
--   TC-240 a not-yet-enrolled student of each program (BSCS, BSIT, BSBA) gets ONE Pending
--          Year 1 enrollment in the current term with exactly its 5 curriculum subjects,
--          each in the lowest section_id of the term; audited with actor NULL (server role)
--   TC-241 calling again returns the same id and creates no second enrollment / no items
--   TC-242 anon, a Student, the Registrar and the Admin cannot execute the function and
--          cannot write program_curriculum; the server role has EXECUTE
--   TC-243 a signed-in user reads program_curriculum (every row); anon cannot
--   TC-244 submit_application (anon): 5 arguments -> applicant_type 'New'; 'Transferee'
--          stored; named arguments; NULL -> 'New'; a signed-in user too; old signature gone
--   TC-245 an invalid applicant_type is refused (22023 "invalid application:"), nothing
--          written; the CHECK refuses a bad value from the owner (23514)
--   TC-246 the Registrar approves an auto-created enrollment (seats free): Approved, reviewer
--          and time by the database; afterwards removing an item is refused
--          ("enrollment locked:")
--   TC-247 while Pending an item can be removed (server / owner path); a section of another
--          term ("wrong term:") and a section twice ("duplicate section:") are still refused.
--          Informational (not judged): what the student's own DELETE and the Registrar's API
--          DELETE do today (header D3 of the live file)
--
-- Status: NOT RUN YET (written 2026-10-14 without a local PostgreSQL).

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
