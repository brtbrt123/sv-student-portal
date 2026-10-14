-- ==========================================
-- TESTS TC-199 to TC-217 for queue_hold.sql (hold / unhold a queue ticket)
-- ==========================================
-- Run AFTER queue_hold.sql is live (or use queue_hold_rehearsal.sql, which runs the change and
-- these tests together, TC-199R). This file is the same as the test part of the rehearsal
-- (from its "TESTS START HERE" marker). Needs queue_rules.sql and notifications_rules.sql.
--
-- How to run: Supabase SQL editor, as postgres, a new tab, at a quiet time. Paste the whole
-- file and click Run on the whole tab, never a selection. It ends in rollback: nothing is
-- committed. If it stops with an error, run "rollback;" as its own query and send the error
-- back. TC-207 disables the trigger require_queue_ticket_rules for two UPDATEs (to put held_at
-- in the past) and enables it again: that ALTER TABLE locks queue_tickets until the rollback
-- (a few seconds; other sessions only wait).
--
-- Data: six THROWAWAY services TCH-A .. TCH-F (open, free prefix letters) so the real queues
-- are not used for the flows and every internal number is predictable (a new service starts
-- at 1). Only TC-210 touches the real Enrollment service: it may insert one Held ticket of a
-- seed student there as postgres (rolled back). Students: student1/2/3@pnc.test; staff:
-- registrar, cashier, dept, admin @pnc.test. No account is created: "inactive" is simulated by
-- setting is_active = false on a seed profile and back to true right after. Users are
-- simulated with SET LOCAL ROLE authenticated + request.jwt.claims (sub = the user's id); anon
-- with SET LOCAL ROLE anon; "none" = authenticated without a JWT; "postgres" = no JWT.
-- now() is the same for the whole transaction, so held_at / finished_at = now() is exact and
-- held_until = now() + 15 minutes.
--
-- Result: ONE row, one cell per case ending in "-> OK" or "-> FAIL", plus all_ok first. Every
-- statement that is expected to fail runs inside a do block with an exception handler, so the
-- transaction is never aborted by an expected error. Each step is recorded as its result text
-- or "ERR [SQLSTATE]: message". Notation: "A1" = the ticket with internal number 1 in TCH-A,
-- L(A1) its label '#' || ticket_code; st(...) = 'status #number held=.. called=.. fin=.. by=..
-- win=..' where a time is now / null / other and by is s1 / s2 / s3 / reg / null.
--
--   TC-199 installed as intended: held_at column, the three CHECKs with Held, the rebuilt
--          active-ticket index, triggers unchanged, 9 public functions SECURITY DEFINER with
--          the intended grants, the limit helper locked down (15 minutes), published shapes
--   TC-200 anon, Registrar, Cashier, Department, Admin, no JWT and an inactive student cannot
--          hold / unhold; unknown service -> 22023
--   TC-201 hold only from Waiting: Held, held_at = now(), same number and code, held_until =
--          now() + 15 minutes; holding again refused
--   TC-202 cannot hold a Serving or a Done ticket
--   TC-203 Call next skips the held ticket and calls the next Waiting one; with only a held
--          ticket left it returns no row
--   TC-204 queue_my_status: Held, held_until, people_ahead and waiting_total ignore Held
--   TC-205 unhold: Waiting again with the same number and code; after others were served the
--          student is the next call (before a later ticket); unhold twice refused
--   TC-206 hold + unhold at once keeps the position (order A, B, C unchanged)
--   TC-207 an expired hold (held_at 16 minutes ago) cannot be undone ("hold expired:"); 14
--          minutes is still fine; held_until shows the deadline
--   TC-208 the Registrar marks a Held ticket No-show (never called, handled_by = Registrar);
--          Done on a Held ticket refused; the student can then get a new ticket
--   TC-209 the student cancels a Held ticket; unhold / cancel afterwards refused
--   TC-210 one active ticket per student includes Held: issue refused "already queued:", the
--          unique index refuses a second active row, queue_student_card shows a Held ticket
--   TC-211 a student cannot hold, unhold or cancel another student's ticket
--   TC-212 queue_staff_list shows Held with held_at; Registrar only
--   TC-213 audit rows for every hold step (actor, held_at), none for refused calls
--   TC-214 notifications: hold / unhold / held cancel / held No-show are silent; issue and call
--          still notify
--   TC-215 trigger as the owner: held_at is the database's, illegal steps with Held refused,
--          Held -> No-show needs a handler and no window, final stays final, CHECKs on INSERT
--   TC-216 direct INSERT / UPDATE / DELETE by a Student or the Registrar: permission denied
--   TC-217 regression: issue, people_ahead, cancel Waiting, call with window, finish first,
--          Done, No-show with its notification, cancel Serving refused, student card
--
-- Status: NOT RUN YET (written 2026-10-13 without a local PostgreSQL).

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
