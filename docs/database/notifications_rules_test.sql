-- ==========================================
-- TESTS TC-167 to TC-198 for notifications_rules.sql (in-app notifications)
-- ==========================================
-- Run AFTER notifications_rules.sql is live (or use notifications_rules_rehearsal.sql, which
-- runs the change and these tests together, TC-167R). This file is the same as the test part
-- of the rehearsal (from its "TESTS START HERE" marker).
--
-- How to run: Supabase SQL editor, as postgres, a new tab. Paste the whole file and click Run
-- on the whole tab, never a selection. It ends in rollback: nothing is committed. If it stops
-- with an error, run "rollback;" as its own query and send the error back. Run it at a quiet
-- time: TC-196 adds a temporary CHECK to notifications (ACCESS EXCLUSIVE lock until the
-- rollback, a few seconds), and TC-197 replaces private.notify inside the transaction (other
-- sessions keep seeing the committed version).
--
-- Data: everything is created inside the transaction and rolled back. A throwaway term
-- (2091-2092, 1st) with one section, enrollments, a clearance, holds, document requests and
-- grades of the seed students; two throwaway applications (@notify.test); a throwaway queue
-- service TCN-A (open, a free prefix letter) so the real queues are not used for the flow
-- tests. TC-173 inserts one Waiting ticket in each REAL service (Enrollment, Documents) for a
-- seed student who has no active ticket there today, with a number far above today's (people
-- ahead are read from the table, so a busy live queue does not matter). Seed accounts:
-- student1/2/3, registrar, cashier, dept, admin @pnc.test. No account is created: "inactive"
-- is simulated by setting is_active = false on a seed profile and back to true right after.
-- Users are simulated with SET LOCAL ROLE authenticated + request.jwt.claims (sub = the
-- user's id); anon with SET LOCAL ROLE anon; "postgres" = no JWT (auth.uid() NULL).
-- now() is the same for the whole transaction: every notification created here has
-- created_at = now(), which is how the checks tell this run's rows from live rows. Each case
-- takes a mark (the highest notification_id) first and looks only at rows above it.
-- Live data the checks depend on is read, never assumed: "every Registrar" means every
-- ACTIVE profile with role Registrar (there may be more than the seed one), and so on.
--
-- Result: ONE row, one cell per case ending in "-> OK" or "-> FAIL", plus all_ok. Every
-- statement that is expected to fail runs inside a do block with an exception handler, so
-- the transaction is never aborted by an expected error. Each step is recorded as its
-- result text ("rows N", a value) or "ERR [SQLSTATE]: message".
-- Notation: N(tag) = the rows created in the case for that seed account, written as
-- kind|title|body|link joined with " ; " ('' = none). <s1name> = 'Last, First' of Student 1.
--
--   TC-167 installed as intended: columns, 4 CHECKs, FK ON DELETE CASCADE, 2 indexes, RLS,
--          one SELECT policy, the 9 triggers (types, functions, enabled), every notification
--          trigger is the LAST AFTER trigger of its table, 3 public functions, 4 helpers and
--          9 trigger functions with the intended security and grants
--   TC-168 table grants: anon nothing (and denied), authenticated SELECT only, no column
--          grants, no sequence privileges
--   TC-169 EXECUTE grants exactly as specified; anon cannot execute the 3 functions; the
--          anon-executable list in public is unchanged; published shapes
--   TC-170 notifications CHECKs and FK refuse bad rows (as the owner); live CHECK constraints
--          of the tables involved listed (informational)
--   TC-171 queue: issuing tickets (issue_queue_ticket still works) -> queue_ticket rows
--   TC-172 queue: call / finish (queue_call_next / queue_finish still work) -> queue_turn,
--          queue_skipped; Done -> nothing
--   TC-173 queue: links of the real services Enrollment / Documents
--   TC-174 enrollments INSERT -> every active Registrar, nobody else
--   TC-175 enrollment decided: approved / rejected with remarks; Pending -> Pending -> nothing
--   TC-176 document_requests INSERT -> every active Registrar
--   TC-177 document status flow -> one row per status change; remarks-only -> nothing
--   TC-178 clearance created -> clearance_waiting for the offices: the department head only
--          for their own department, the Cashier only for the Financial item, nobody else
--   TC-179 clearance note; the same remarks again or cleared remarks -> nothing
--   TC-180 one item cleared -> clearance_cleared; no clearance_ready yet
--   TC-181 the last items cleared in ONE statement -> one clearance_cleared per item and
--          exactly ONE clearance_ready per active Registrar
--   TC-182 clearance approved -> clearance_approved; a no-change update -> nothing
--   TC-183 hold placed / lifted; a second update of a lifted hold -> nothing
--   TC-184 grade posted / changed; an update that keeps grade_code -> nothing
--   TC-185 applications INSERT -> every active Registrar exactly once, nobody else
--   TC-186 inactive recipients (student, Registrar, Cashier) get nothing
--   TC-187 private.notify never raises: 500-character title, NULL / unknown / inactive
--          recipient, bad link, bad kind, blank title, 1000-character body, control
--          characters, 201-character link, NULL kind; writes only what is valid, trimmed
--   TC-188 private.notify_role / notify_office / person_name directly
--   TC-189 RLS: each user sees exactly their own rows; anon is denied
--   TC-190 list_my_notifications: newest first, limit clamped to 1..100 (NULL = 30),
--          unread filter
--   TC-191 mark_notifications_read with someone else's ids changes nothing
--   TC-192 notification_unread_count and mark_notifications_read: own rows, counts,
--          idempotent, empty array, NULL = all
--   TC-193 the 3 functions refuse an inactive account, a missing JWT and an unknown user
--   TC-194 direct INSERT / UPDATE / DELETE / TRUNCATE on notifications by authenticated:
--          permission denied
--   TC-195 BEFORE UPDATE trigger (as the owner): only read_at, NULL -> now() (the sent value
--          is ignored), never back to NULL, a second time keeps the first, other columns
--          immutable
--   TC-196 KEY SAFETY 1: notifications cannot be written at all (a temporary CHECK (false));
--          a document status change, a hold and a queue ticket still succeed
--   TC-197 KEY SAFETY 2: private.notify raises (replaced on purpose); the source changes still
--          succeed; private.notify restored from its saved definition
--   TC-198 notifications is not audited; it has only the BEFORE UPDATE trigger; the trigger
--          functions write nothing but notifications (no loop)
--
-- Status: NOT RUN YET (written 2026-10-13 without a local PostgreSQL).

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
