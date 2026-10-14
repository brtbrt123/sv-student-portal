-- ==========================================
-- TESTS TC-248 to TC-259 for queue_hold_v2.sql (30-minute hold, automatic No-show of expired
-- holds, its notification, the Registrar's own DELETE on enrollment_items)
-- ==========================================
-- Run AFTER queue_hold_v2.sql is live (or use queue_hold_v2_rehearsal.sql, which runs the change
-- and these tests together). This file is the same as the test part of the rehearsal (from its
-- "TESTS START HERE" marker). Needs queue_rules.sql, notifications_rules.sql, queue_hold.sql and
-- enrollment_rules.sql (all live).
--
-- How to run: Supabase SQL editor, as postgres, a new tab, at a QUIET time. Paste the whole file
-- and click Run on the whole tab, never a selection. It ends in rollback: nothing is committed.
-- If it stops with an error, run "rollback;" as its own query and send the error back.
--   - pg_temp.backdate() switches off the trigger require_queue_ticket_rules for one UPDATE (to
--     put held_at in the past) and on again, like queue_hold_test.sql TC-207: that ALTER TABLE
--     locks queue_tickets until the rollback (a few seconds; other sessions only wait).
--   - TC-251 calls queue_expire_holds(), which also closes REAL expired holds (if any) inside
--     this transaction (rolled back; their rows stay locked until the rollback). The expected
--     count is computed first ("pre" = real expired holds). A real held ticket locked by another
--     session at that moment is skipped and would make the count differ: run it again then.
--
-- Data: five THROWAWAY services TCV-A .. TCV-E (open, free prefix letters; a new service starts
-- at number 1), a throwaway term 2087-2088 '2nd' (not current) with two sections Z248A / Z248B
-- of an existing subject and three enrollments (s1 and s2 Pending, s3 Approved). Students:
-- student1/2/3@pnc.test; staff: registrar, cashier, admin @pnc.test. No account is created.
-- Users are simulated with SET LOCAL ROLE authenticated + request.jwt.claims (sub = the user's
-- id); anon with SET LOCAL ROLE anon; "none" = authenticated without a JWT; postgres = no JWT.
-- now() is the same for the whole transaction, so held_at / finished_at = now() is exact and
-- held_until = now() + 30 minutes.
--
-- Result: ONE row, all_ok first, then one cell per case ending in "-> OK" or "-> FAIL". Every
-- statement that is expected to fail runs inside a do block with an exception handler and is
-- recorded as "ERR [SQLSTATE]: message". Notation: "A1" = the ticket with internal number 1 in
-- TCV-A, L(A1) its label '#' || ticket_code; st(...) = 'status #number held=.. called=.. fin=..
-- by=.. win=..' where a time is now / null / other and by is s1 / s2 / s3 / reg / null.
--
--   TC-248 installed as intended: limit 30 minutes; queue_expire_holds() SECURITY DEFINER,
--          no arguments, integer, EXECUTE authenticated + server role only; queue_finish;
--          the CHECKs validated; notify function with queue_hold_expired; triggers unchanged;
--          DELETE policies on enrollment_items (student's + Registrar's); DELETE grant
--   TC-249 hold limit 30: hold returns now() + 30 min, held_until the same; at 29 minutes
--          unhold works; at 31 minutes "hold expired: ... more than 30 minutes"
--   TC-250 Registrar No-show of a held ticket: at 10 minutes refused "hold active:"; Done
--          refused; a student cannot finish; at 31 minutes allowed (never called, handled_by =
--          the Registrar, no window); a second time refused
--   TC-251 queue_expire_holds (called by a Student): closes only the expired hold (31 min),
--          returns pre + 1; a hold at 29 / 10 minutes, Waiting, Serving, Done, Cancelled and
--          No-show tickets are untouched; the closed row is No-show, never called, no handler;
--          audited with the caller as actor; a second call (Registrar) returns 0
--   TC-252 Call next skips held tickets (expired or not), serves the next Waiting one, and with
--          only held tickets left returns no row; the held ones stay Held
--   TC-253 notifications: exactly one queue_hold_expired for the automatic close (s1) and one
--          for the Registrar's No-show after the deadline (s2), with the exact title and body
--          ("... over 30 minutes ...") and no link (throwaway service); an owner's early
--          maintenance No-show is silent; an owner's close of an expired hold notifies
--   TC-254 no notification for hold, unhold, a refused unhold and the cancel of a held ticket
--   TC-255 anon cannot execute queue_expire_holds; Cashier, Admin and an authenticated call
--          without a JWT can (0 closed); the server role has EXECUTE; direct INSERT / UPDATE /
--          DELETE on queue_tickets by a Student and the Registrar: permission denied
--   TC-256 trigger as the owner: Held -> No-show without a handler is refused while the hold
--          runs, allowed after it ran out (by=null); then final
--   TC-257 the Registrar's DELETE (own session) of an item of a Pending enrollment removes it;
--          the audit row (DELETE, enrollment_items, that id) has actor_id = the Registrar
--   TC-258 the Registrar cannot delete an item of an Approved enrollment ("enrollment
--          locked:"); the row stays; no audit row
--   TC-259 a student cannot delete another student's item (0 rows), the Cashier neither (0
--          rows), anon gets permission denied; a student's own Pending delete still works and
--          is audited with the student as actor
--
-- Status: NOT RUN YET (written 2026-10-14 without a local PostgreSQL).

begin;

-- ==========================================
-- 1. Accounts, ids, throwaway services, helpers (as postgres, no user JWT)
-- ==========================================
select set_config('request.jwt.claims', '', true);
select set_config('app.none', '', true);
select set_config('app.srv',  'service' || '_role', true);
select set_config('app.s1',   coalesce((select id::text from auth.users where email = 'student1@pnc.test'), ''), true);
select set_config('app.s2',   coalesce((select id::text from auth.users where email = 'student2@pnc.test'), ''), true);
select set_config('app.s3',   coalesce((select id::text from auth.users where email = 'student3@pnc.test'), ''), true);
select set_config('app.reg',  coalesce((select id::text from auth.users where email = 'registrar@pnc.test'), ''), true);
select set_config('app.cash', coalesce((select id::text from auth.users where email = 'cashier@pnc.test'), ''), true);
select set_config('app.adm',  coalesce((select id::text from auth.users where email = 'admin@pnc.test'), ''), true);
select set_config('app.today', ((now() at time zone 'Asia/Manila')::date)::text, true);
do $$
declare v_bad text;
begin
  if to_regprocedure('public.queue_expire_holds()') is null
     or to_regprocedure('private.queue_hold_limit()') is null
     or to_regprocedure('public.queue_hold_my_ticket(text)') is null then
    raise exception 'TC setup: queue_hold_v2.sql is not installed (run it, or use queue_hold_v2_rehearsal.sql)';
  end if;
  if to_regclass('public.notifications') is null or to_regprocedure('private.notify_on_queue_tickets()') is null then
    raise exception 'TC setup: notifications_rules.sql is not installed';
  end if;
  select string_agg(v.who || ' (' || v.role_name || ')', ', ') into v_bad
  from (values ('s1', 'Student'), ('s2', 'Student'), ('s3', 'Student'), ('reg', 'Registrar'),
               ('cash', 'Cashier'), ('adm', 'Admin')) as v(who, role_name)
  where current_setting('app.' || v.who) = ''
     or not exists (select 1 from public.profiles p join public.roles r on r.role_id = p.role_id
                    where p.profile_id::text = current_setting('app.' || v.who)
                      and p.is_active and r.role_name = v.role_name)
     or (v.role_name = 'Student'
         and not exists (select 1 from public.students s where s.student_id::text = current_setting('app.' || v.who)));
  if v_bad is not null then
    raise exception 'TC setup: seed account missing, inactive or with another role: %', v_bad;
  end if;
  if exists (select 1 from public.queue_services where service_code like 'TCV-_') then
    raise exception 'TC setup: a queue service TCV-? exists; the tests need the codes TCV-A .. TCV-E free';
  end if;
  if exists (select 1 from public.terms where school_year = '2087-2088') then
    raise exception 'TC setup: a term 2087-2088 exists; the tests need that school year free';
  end if;
  if not exists (select 1 from public.subjects) then
    raise exception 'TC setup: no subject exists (TC-257 needs one)';
  end if;
end $$;
select set_config('app.log_mark', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);
-- five throwaway services, each with a free prefix letter
do $$
declare c text;
begin
  foreach c in array array['TCV-A', 'TCV-B', 'TCV-C', 'TCV-D', 'TCV-E'] loop
    insert into public.queue_services (service_code, service_name, ticket_prefix, is_open)
    select c, 'TC hold v2 queue ' || right(c, 1), chr(g), true
    from generate_series(65, 90) g
    where chr(g) not in (select ticket_prefix from public.queue_services)
    order by g desc
    limit 1;
    if not found then
      raise exception 'TC setup: no free ticket prefix letter for %', c;
    end if;
  end loop;
end $$;
select set_config('app.sve', (select service_id::text from public.queue_services where service_code = 'TCV-E'), true);

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
              when p::text = current_setting('app.cash') then 'cash'
              when p::text = current_setting('app.adm') then 'adm'
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
-- every throwaway ticket except one, as st() text (to show nothing else changed)
create function pg_temp.fp(p_skip bigint) returns text language sql stable as $f$
  select coalesce(string_agg(s.service_code || ':' || pg_temp.st(t.ticket_id), ',' order by s.service_code, t.ticket_number), '')
  from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
  where s.service_code like 'TCV-_' and t.ticket_id <> p_skip
$f$;
-- put a Held ticket's held_at p_minutes in the past (the trigger would keep it, so it is switched
-- off for this one UPDATE; the CHECKs still apply). Returns the number of rows changed.
create function pg_temp.backdate(p_id bigint, p_minutes integer) returns text language plpgsql as $f$
declare v_n integer;
begin
  alter table public.queue_tickets disable trigger require_queue_ticket_rules;
  update public.queue_tickets set held_at = now() - make_interval(mins => p_minutes)
  where ticket_id = p_id and status = 'Held';
  get diagnostics v_n = row_count;
  alter table public.queue_tickets enable trigger require_queue_ticket_rules;
  return v_n::text;
end
$f$;
-- the exact body of a queue_hold_expired notification for a label
create function pg_temp.xbody(p_label text) returns text language sql immutable as $f$
  select 'Ticket ' || p_label || ' was closed because your hold lasted over 30 minutes. Show your QR code again at the Registrar to get a new number.'
$f$;

-- ==========================================
-- 2. TC-248: installed as intended (catalog)
-- ==========================================
-- Expected: limit '00:30:00', expire_fn true, finish_fn true, state_check true, notify_fn
-- true, triggers 'audit_log 29 O, require_queue_ticket_rules 19 O, trg_notify_queue_tickets
-- 21 O', delete_policies 'enrollment_items_registrar_delete PERMISSIVE authenticated;
-- enrollment_items_student_remove PERMISSIVE authenticated', registrar_policy true, grants true.
select set_config('app.r248', (select format('limit %s, expire_fn %s, finish_fn %s, state_check %s, notify_fn %s, triggers [%s], delete_policies [%s], registrar_policy %s, items_grants %s -> %s',
    x.lim, x.expire_fn, x.finish_fn, x.state_ck, x.notify_fn, x.trg, x.del_pol, x.reg_pol, x.grants,
    case when x.lim = '00:30:00' and x.expire_fn = 'true' and x.finish_fn = 'true' and x.state_ck and x.notify_fn = 'true'
          and x.trg = 'audit_log 29 O, require_queue_ticket_rules 19 O, trg_notify_queue_tickets 21 O'
          and x.del_pol = 'enrollment_items_registrar_delete PERMISSIVE authenticated; enrollment_items_student_remove PERMISSIVE authenticated'
          and x.reg_pol and x.grants
         then 'OK' else 'FAIL' end)
  from (select
    private.queue_hold_limit()::text as lim,
    coalesce((select (p.prosecdef and p.prorettype = 'integer'::regtype and p.pronargs = 0
                      and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
                      and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
                      and not has_function_privilege('anon', p.oid, 'EXECUTE')
                      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
                      and has_function_privilege(current_setting('app.srv'), p.oid, 'EXECUTE')
                      and exists (select 1 from pg_roles r join pg_class c on c.oid = 'public.queue_tickets'::regclass
                                   where r.oid = p.proowner
                                     and (r.rolbypassrls or (c.relowner = r.oid and not c.relforcerowsecurity))))::text
                from pg_proc p where p.oid = to_regprocedure('public.queue_expire_holds()')), 'missing') as expire_fn,
    coalesce((select (p.prosecdef
                      and array_to_string(p.proconfig, ',') in ('search_path=""', 'search_path=''''')
                      and p.proacl is not null and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
                      and not has_function_privilege('anon', p.oid, 'EXECUTE')
                      and has_function_privilege('authenticated', p.oid, 'EXECUTE'))::text
                from pg_proc p where p.oid = to_regprocedure('public.queue_finish(bigint, text)')), 'missing') as finish_fn,
    ((select count(*) from pg_constraint k
       where k.conrelid = 'public.queue_tickets'::regclass and k.contype = 'c' and k.convalidated
         and k.conname in ('ck_queue_tickets_status', 'ck_queue_tickets_state', 'ck_queue_tickets_held')) = 3) as state_ck,
    coalesce((select (p.prosecdef and p.prosrc like '%''queue_hold_expired''%'
                      and not has_function_privilege('anon', p.oid, 'EXECUTE'))::text
                from pg_proc p where p.oid = to_regprocedure('private.notify_on_queue_tickets()')), 'missing') as notify_fn,
    coalesce((select string_agg(t.tgname || ' ' || t.tgtype || ' ' || t.tgenabled::text, ', ' order by t.tgname)
                from pg_trigger t where t.tgrelid = 'public.queue_tickets'::regclass and not t.tgisinternal), '') as trg,
    coalesce((select string_agg(p.policyname || ' ' || p.permissive || ' ' || array_to_string(p.roles, ','), '; ' order by p.policyname)
                from pg_policies p
               where p.schemaname = 'public' and p.tablename = 'enrollment_items' and p.cmd in ('DELETE', 'ALL')), '') as del_pol,
    exists (select 1 from pg_policies p
             where p.schemaname = 'public' and p.tablename = 'enrollment_items'
               and p.policyname = 'enrollment_items_registrar_delete' and p.with_check is null
               and p.qual like '%current_role_name%''Registrar''%') as reg_pol,
    (has_table_privilege('authenticated', 'public.enrollment_items', 'DELETE')
     and not has_table_privilege('anon', 'public.enrollment_items', 'SELECT, INSERT, UPDATE, DELETE')) as grants
  ) x), true);

-- ==========================================
-- 3. TC-249 and TC-254 (TCV-A): the 30-minute limit; hold steps are silent
-- ==========================================
-- Step A1: the Registrar issues A1 (s1), A2 (s2), A3 (s3).
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'ca_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCV-A') i$q$),
    (2, 'ca_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCV-A') i$q$),
    (3, 'ca_issue3', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCV-A') i$q$)
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
select set_config('app.t_a1', coalesce(pg_temp.tid('TCV-A', 's1'), 0)::text, true);
select set_config('app.t_a2', coalesce(pg_temp.tid('TCV-A', 's2'), 0)::text, true);
select set_config('app.l_a2', pg_temp.lbl(current_setting('app.t_a2')::bigint), true);
select set_config('app.n_mark_a', pg_temp.nmark()::text, true);

-- Step A2: s1, s2, s3 hold; s1 reads the status; s3 comes back at once.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c249_hold1',   's1', $q$select (public.queue_hold_my_ticket('TCV-A') = now() + interval '30 minutes')::text$q$),
    (2, 'c249_hold2',   's2', $q$select (public.queue_hold_my_ticket('TCV-A') = now() + interval '30 minutes')::text$q$),
    (3, 'c249_hold3',   's3', $q$select (public.queue_hold_my_ticket('TCV-A') = now() + interval '30 minutes')::text$q$),
    (4, 'c249_status1', 's1', $q$select m.ticket_status || '|' || (m.held_until = now() + interval '30 minutes') from public.queue_my_status('TCV-A') m$q$),
    (5, 'c254_unhold3', 's3', $q$select 'ok'::text from public.queue_unhold_my_ticket('TCV-A')$q$)
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
-- A1 held 29 minutes ago, A2 31 minutes ago.
select set_config('app.bd_a1', pg_temp.backdate(current_setting('app.t_a1')::bigint, 29), true);
select set_config('app.bd_a2', pg_temp.backdate(current_setting('app.t_a2')::bigint, 31), true);

-- Step A3: both read their status; s1 (29 min) and s2 (31 min) try to come back; s2 cancels.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c249_status29', 's1', $q$select m.ticket_status || '|' || (m.held_until = now() + interval '1 minute') from public.queue_my_status('TCV-A') m$q$),
    (2, 'c249_status31', 's2', $q$select m.ticket_status || '|' || (m.held_until = now() - interval '1 minute') from public.queue_my_status('TCV-A') m$q$),
    (3, 'c249_unhold29', 's1', $q$select 'ok'::text from public.queue_unhold_my_ticket('TCV-A')$q$),
    (4, 'c249_unhold31', 's2', $q$select 'ok'::text from public.queue_unhold_my_ticket('TCV-A')$q$),
    (5, 'c254_cancel',   's2', $q$select 'ok'::text from public.queue_cancel_my_ticket('TCV-A')$q$)
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
select set_config('app.c254_silent', pg_temp.nkinds(current_setting('app.n_mark_a')::bigint), true);

-- TC-249. Expected: holds 'true' (held_until = now() + 30 minutes); status 'Held|true'; backdated
-- 1 and 1 row; at 29 minutes 'Held|true' (one minute left) and unhold 'ok'; at 31 minutes
-- 'Held|true' (one minute past) and 'ERR [P0001]: hold expired: ticket L(A2) was on hold for
-- more than 30 minutes'; st(A1) 'Waiting #1 held=null ...'.
select set_config('app.r249', format('holds [%s, %s, %s], status [%s], backdated [%s, %s], at_29 [%s], unhold_29 [%s], at_31 [%s], unhold_31 [%s], a1 [%s] -> %s',
  current_setting('app.c249_hold1'), current_setting('app.c249_hold2'), current_setting('app.c249_hold3'),
  current_setting('app.c249_status1'), current_setting('app.bd_a1'), current_setting('app.bd_a2'),
  current_setting('app.c249_status29'), current_setting('app.c249_unhold29'),
  current_setting('app.c249_status31'), current_setting('app.c249_unhold31'),
  pg_temp.st(current_setting('app.t_a1')::bigint),
  case when current_setting('app.c249_hold1') = 'true' and current_setting('app.c249_hold2') = 'true'
        and current_setting('app.c249_hold3') = 'true' and current_setting('app.c249_status1') = 'Held|true'
        and current_setting('app.bd_a1') = '1' and current_setting('app.bd_a2') = '1'
        and current_setting('app.c249_status29') = 'Held|true' and current_setting('app.c249_unhold29') = 'ok'
        and current_setting('app.c249_status31') = 'Held|true'
        and current_setting('app.c249_unhold31') = format('ERR [P0001]: hold expired: ticket %s was on hold for more than 30 minutes', current_setting('app.l_a2'))
        and pg_temp.st(current_setting('app.t_a1')::bigint) = 'Waiting #1 held=null called=null fin=null by=null win=null'
       then 'OK' else 'FAIL' end), true);

-- TC-254. Expected: s3's unhold 'ok', s2's cancel of the held (expired) A2 'ok', st(A2)
-- 'Cancelled #2 held=null called=null fin=now by=null win=null', and NO notification for
-- anyone after the mark (three holds, two unholds, a refused unhold, a cancel).
select set_config('app.r254', format('unhold [%s], cancel [%s], a2 [%s], notifications [%s] -> %s',
  current_setting('app.c254_unhold3'), current_setting('app.c254_cancel'),
  pg_temp.st(current_setting('app.t_a2')::bigint), current_setting('app.c254_silent'),
  case when current_setting('app.c254_unhold3') = 'ok' and current_setting('app.c254_cancel') = 'ok'
        and pg_temp.st(current_setting('app.t_a2')::bigint) = 'Cancelled #2 held=null called=null fin=now by=null win=null'
        and current_setting('app.c254_silent') = ''
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 4. TC-250 (TCV-B): the Registrar's No-show of a held ticket
-- ==========================================
-- Step B1: B1 (s1), B2 (s2), B3 (s3) issued; s1 and s2 hold.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'cb_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCV-B') i$q$),
    (2, 'cb_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCV-B') i$q$),
    (3, 'cb_issue3', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCV-B') i$q$),
    (4, 'cb_hold1',  's1',  $q$select public.queue_hold_my_ticket('TCV-B')::text$q$),
    (5, 'cb_hold2',  's2',  $q$select public.queue_hold_my_ticket('TCV-B')::text$q$)
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
select set_config('app.t_b1', coalesce(pg_temp.tid('TCV-B', 's1'), 0)::text, true);
select set_config('app.t_b2', coalesce(pg_temp.tid('TCV-B', 's2'), 0)::text, true);
select set_config('app.l_b1', pg_temp.lbl(current_setting('app.t_b1')::bigint), true);
select set_config('app.l_b2', pg_temp.lbl(current_setting('app.t_b2')::bigint), true);
-- B1 held 10 minutes ago, B2 31 minutes ago.
select set_config('app.bd_b1', pg_temp.backdate(current_setting('app.t_b1')::bigint, 10), true);
select set_config('app.bd_b2', pg_temp.backdate(current_setting('app.t_b2')::bigint, 31), true);
select set_config('app.n_mark_b', pg_temp.nmark()::text, true);

-- Step B2: No-show at 10 minutes; a student tries; Done on the expired hold; No-show at 31
-- minutes; again.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c250_at10',    'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_b1')::bigint, 'No-show')$q$),
    (2, 'c250_student', 's1',  $q$select 'done'::text from public.queue_finish(current_setting('app.t_b2')::bigint, 'No-show')$q$),
    (3, 'c250_done',    'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_b2')::bigint, 'Done')$q$),
    (4, 'c250_at31',    'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_b2')::bigint, 'No-show')$q$),
    (5, 'c250_again',   'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_b2')::bigint, 'No-show')$q$)
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
select set_config('app.c253_reg_kinds', pg_temp.nkinds(current_setting('app.n_mark_b')::bigint), true);
select set_config('app.c253_reg_note', coalesce((
  select string_agg(pg_temp.who(n.recipient_id) || '|' || n.title || '|' || n.body || '|' || coalesce(n.link, 'NULL'), ' ;; ')
  from public.notifications n
  where n.notification_id > current_setting('app.n_mark_b')::bigint and n.kind = 'queue_hold_expired'), 'none'), true);

-- TC-250. Expected: at 10 minutes 'ERR [P0001]: hold active: ticket L(B1) is on hold until
-- <now() + 20 min, Manila HH24:MI> (Manila time); it can be marked No-show only after the hold
-- runs out'; the student 'ERR [42501]: not allowed: ...'; Done 'ERR [P0001]: bad ticket change:
-- ticket <B2 id> is on hold; it can only be marked No-show'; at 31 minutes 'done'; again 'ERR
-- [P0001]: bad ticket change: ticket <B2 id> is No-show; only a Serving ticket can be
-- finished'; st(B1) still Held (held=other); st(B2) 'No-show #2 held=null called=null fin=now
-- by=reg win=null'.
select set_config('app.r250', format('backdated [%s, %s], at_10 [%s], student [%s], done [%s], at_31 [%s], again [%s], b1 [%s], b2 [%s] -> %s',
  current_setting('app.bd_b1'), current_setting('app.bd_b2'),
  current_setting('app.c250_at10'), current_setting('app.c250_student'), current_setting('app.c250_done'),
  current_setting('app.c250_at31'), current_setting('app.c250_again'),
  pg_temp.st(current_setting('app.t_b1')::bigint), pg_temp.st(current_setting('app.t_b2')::bigint),
  case when current_setting('app.bd_b1') = '1' and current_setting('app.bd_b2') = '1'
        and current_setting('app.c250_at10') = format('ERR [P0001]: hold active: ticket %s is on hold until %s (Manila time); it can be marked No-show only after the hold runs out',
                                                      current_setting('app.l_b1'),
                                                      to_char((now() + interval '20 minutes') at time zone 'Asia/Manila', 'HH24:MI'))
        and current_setting('app.c250_student') like 'ERR [42501]: not allowed:%'
        and current_setting('app.c250_done') = format('ERR [P0001]: bad ticket change: ticket %s is on hold; it can only be marked No-show', current_setting('app.t_b2'))
        and current_setting('app.c250_at31') = 'done'
        and current_setting('app.c250_again') = format('ERR [P0001]: bad ticket change: ticket %s is No-show; only a Serving ticket can be finished', current_setting('app.t_b2'))
        and pg_temp.st(current_setting('app.t_b1')::bigint) = 'Held #1 held=other called=null fin=null by=null win=null'
        and pg_temp.st(current_setting('app.t_b2')::bigint) = 'No-show #2 held=null called=null fin=now by=reg win=null'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 5. TC-252 (TCV-C): Call next never serves a held ticket
-- ==========================================
-- Step C1: C1 (s1), C2 (s2), C3 (s3) issued; s1 and s2 hold.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'cc_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCV-C') i$q$),
    (2, 'cc_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCV-C') i$q$),
    (3, 'cc_issue3', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCV-C') i$q$),
    (4, 'cc_hold1',  's1',  $q$select public.queue_hold_my_ticket('TCV-C')::text$q$),
    (5, 'cc_hold2',  's2',  $q$select public.queue_hold_my_ticket('TCV-C')::text$q$)
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
select set_config('app.t_c1', coalesce(pg_temp.tid('TCV-C', 's1'), 0)::text, true);
select set_config('app.t_c2', coalesce(pg_temp.tid('TCV-C', 's2'), 0)::text, true);
select set_config('app.t_c3', coalesce(pg_temp.tid('TCV-C', 's3'), 0)::text, true);
select set_config('app.l_c1', pg_temp.lbl(current_setting('app.t_c1')::bigint), true);
select set_config('app.l_c3', pg_temp.lbl(current_setting('app.t_c3')::bigint), true);
-- C1 held 31 minutes ago (expired, not closed yet), C2 29 minutes ago.
select set_config('app.bd_c1', pg_temp.backdate(current_setting('app.t_c1')::bigint, 31), true);
select set_config('app.bd_c2', pg_temp.backdate(current_setting('app.t_c2')::bigint, 29), true);

-- Step C2: Call next (skips C1 and C2), Done, Call next with only held tickets left.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c252_call1', 'reg', $q$select c.ticket_label from public.queue_call_next('TCV-C', 'W1') c$q$),
    (2, 'c252_fin',   'reg', $q$select 'done'::text from public.queue_finish(current_setting('app.t_c3')::bigint, 'Done')$q$),
    (3, 'c252_call2', 'reg', $q$select c.ticket_label from public.queue_call_next('TCV-C', 'W1') c$q$)
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

-- TC-252. Expected: first call L(C3); Done 'done'; second call 'NULL' (no row); C1 and C2 still
-- 'Held ... held=other called=null fin=null by=null win=null'; C3 'Done #3 held=null called=now
-- fin=now by=reg win=W1'.
select set_config('app.r252', format('backdated [%s, %s], call1 [%s], done [%s], call2 [%s], c1 [%s], c2 [%s], c3 [%s] -> %s',
  current_setting('app.bd_c1'), current_setting('app.bd_c2'),
  current_setting('app.c252_call1'), current_setting('app.c252_fin'), current_setting('app.c252_call2'),
  pg_temp.st(current_setting('app.t_c1')::bigint), pg_temp.st(current_setting('app.t_c2')::bigint),
  pg_temp.st(current_setting('app.t_c3')::bigint),
  case when current_setting('app.bd_c1') = '1' and current_setting('app.bd_c2') = '1'
        and current_setting('app.c252_call1') = current_setting('app.l_c3')
        and current_setting('app.c252_fin') = 'done' and current_setting('app.c252_call2') = 'NULL'
        and pg_temp.st(current_setting('app.t_c1')::bigint) = 'Held #1 held=other called=null fin=null by=null win=null'
        and pg_temp.st(current_setting('app.t_c2')::bigint) = 'Held #2 held=other called=null fin=null by=null win=null'
        and pg_temp.st(current_setting('app.t_c3')::bigint) = 'Done #3 held=null called=now fin=now by=reg win=W1'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 6. TC-251 (TCV-D plus everything above): queue_expire_holds
-- ==========================================
-- Step D1: D1 (s1) Done, D2 (s2) Serving, D3 (s3) Waiting.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'cd_issue1', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s1')::uuid, 'TCV-D') i$q$),
    (2, 'cd_issue2', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s2')::uuid, 'TCV-D') i$q$),
    (3, 'cd_issue3', 'reg', $q$select i.ticket_label from public.issue_queue_ticket(current_setting('app.s3')::uuid, 'TCV-D') i$q$),
    (4, 'cd_call1',  'reg', $q$select c.ticket_label from public.queue_call_next('TCV-D', 'W2') c$q$),
    (5, 'cd_fin1',   'reg', $q$select 'done'::text from public.queue_finish((select t.ticket_id from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id where s.service_code = 'TCV-D' and t.status = 'Serving'), 'Done')$q$),
    (6, 'cd_call2',  'reg', $q$select c.ticket_label from public.queue_call_next('TCV-D', 'W2') c$q$)
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
select set_config('app.d_states', coalesce((select string_agg(t.ticket_number || ':' || t.status, ',' order by t.ticket_number)
  from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id where s.service_code = 'TCV-D'), ''), true);
-- Before: every throwaway ticket except C1, the real expired holds ("pre"), the marks.
select set_config('app.fp_before', pg_temp.fp(current_setting('app.t_c1')::bigint), true);
select set_config('app.pre', (select count(*) from public.queue_tickets t
  join public.queue_services s on s.service_id = t.service_id
  where t.status = 'Held' and now() > t.held_at + private.queue_hold_limit() and s.service_code not like 'TCV-_')::text, true);
select set_config('app.n_mark_d', pg_temp.nmark()::text, true);
select set_config('app.log_mark_d', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);

-- Step D2: a Student calls the expiry, then the Registrar calls it again.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c251_first',  's3',  $q$select public.queue_expire_holds()::text$q$),
    (2, 'c251_second', 'reg', $q$select public.queue_expire_holds()::text$q$)
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
select set_config('app.c251_audit', coalesce((
  select string_agg(l.action || ':' || pg_temp.who(l.actor_id) || ':' || (l.old_data ->> 'status') || '->' || (l.new_data ->> 'status'), ',')
  from public.audit_logs l
  where l.log_id > current_setting('app.log_mark_d')::bigint and l.table_name = 'queue_tickets'
    and l.record_id = current_setting('app.t_c1')), 'none'), true);
-- The automatic-close notifications about throwaway tickets (real expired holds are ignored).
select set_config('app.c253_auto_note', coalesce((
  select string_agg(pg_temp.who(n.recipient_id) || '|' || n.title || '|' || n.body || '|' || coalesce(n.link, 'NULL'), ' ;; ' order by n.notification_id)
  from public.notifications n
  where n.notification_id > current_setting('app.n_mark_d')::bigint and n.kind = 'queue_hold_expired'
    and exists (select 1 from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
                 where s.service_code like 'TCV-_' and n.body like 'Ticket #' || t.ticket_code || ' %')), 'none'), true);
select set_config('app.c251_other_kinds', coalesce((
  select string_agg(n.kind || ':' || pg_temp.who(n.recipient_id), ',' order by n.notification_id)
  from public.notifications n
  where n.notification_id > current_setting('app.n_mark_d')::bigint and n.kind <> 'queue_hold_expired'), ''), true);

-- TC-251. Expected: TCV-D '1:Done,2:Serving,3:Waiting'; first call = pre + 1; second '0';
-- st(C1) 'No-show #1 held=null called=null fin=now by=null win=null'; every other throwaway
-- ticket unchanged (A Waiting / Cancelled, B Held 10 min and No-show, C2 Held 29 min, C3 Done,
-- D Done / Serving / Waiting); the audit row of C1 'UPDATE:s3:Held->No-show' (the caller is
-- the actor); no other notification kind was written.
select set_config('app.r251', format('tcv_d [%s], pre %s, first [%s], second [%s], c1 [%s], others_unchanged %s, audit [%s], other_kinds [%s] -> %s',
  current_setting('app.d_states'), current_setting('app.pre'), current_setting('app.c251_first'),
  current_setting('app.c251_second'), pg_temp.st(current_setting('app.t_c1')::bigint),
  (pg_temp.fp(current_setting('app.t_c1')::bigint) = current_setting('app.fp_before')),
  current_setting('app.c251_audit'), current_setting('app.c251_other_kinds'),
  case when current_setting('app.d_states') = '1:Done,2:Serving,3:Waiting'
        and current_setting('app.c251_first') = (current_setting('app.pre')::integer + 1)::text
        and current_setting('app.c251_second') = '0'
        and pg_temp.st(current_setting('app.t_c1')::bigint) = 'No-show #1 held=null called=null fin=now by=null win=null'
        and pg_temp.fp(current_setting('app.t_c1')::bigint) = current_setting('app.fp_before')
        and current_setting('app.c251_audit') = 'UPDATE:s3:Held->No-show'
        and current_setting('app.c251_other_kinds') = ''
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 7. TC-256 (TCV-E) and the owner's maintenance No-show of B1
-- ==========================================
insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code, status, held_at)
values (current_setting('app.sve')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 9001, 1000001, 'Held', now());
select set_config('app.t_e1', (select ticket_id::text from public.queue_tickets where service_id = current_setting('app.sve')::bigint and ticket_number = 9001), true);
select set_config('app.l_e1', pg_temp.lbl(current_setting('app.t_e1')::bigint), true);
select set_config('app.n_mark_e', pg_temp.nmark()::text, true);
do $$
declare r record;
begin
  for r in select * from (values
    (1, 'c256_running', $q$update public.queue_tickets set status = 'No-show' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (2, 'c253_maint',   $q$update public.queue_tickets set status = 'No-show', handled_by = current_setting('app.reg')::uuid where ticket_id = current_setting('app.t_b1')::bigint$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      perform set_config('app.' || r.label, 'ok', true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.c253_maint_kinds', pg_temp.nkinds(current_setting('app.n_mark_e')::bigint), true);
select set_config('app.bd_e1', pg_temp.backdate(current_setting('app.t_e1')::bigint, 31), true);
select set_config('app.n_mark_e2', pg_temp.nmark()::text, true);
do $$
declare r record;
begin
  for r in select * from (values
    (1, 'c256_expired', $q$update public.queue_tickets set status = 'No-show' where ticket_id = current_setting('app.t_e1')::bigint$q$),
    (2, 'c256_final',   $q$update public.queue_tickets set status = 'Held' where ticket_id = current_setting('app.t_e1')::bigint$q$)
  ) as t(ord, label, stmt) order by ord
  loop
    begin
      execute r.stmt;
      perform set_config('app.' || r.label, 'ok', true);
    exception when others then
      perform set_config('app.' || r.label, 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
    end;
  end loop;
end $$;
select set_config('app.c253_owner_kinds', pg_temp.nkinds(current_setting('app.n_mark_e2')::bigint), true);

-- TC-256. Expected: while the hold runs 'ERR [P0001]: bad ticket change: ticket <E1 id> is still
-- on hold; only an expired hold is closed without a handler'; backdated 1; after it ran out
-- 'ok' -> 'No-show #9001 held=null called=null fin=now by=null win=null'; then 'ERR [P0001]:
-- bad ticket change: ... (final) ...'.
select set_config('app.r256', format('running [%s], backdated [%s], expired [%s], e1 [%s], final [%s] -> %s',
  current_setting('app.c256_running'), current_setting('app.bd_e1'), current_setting('app.c256_expired'),
  pg_temp.st(current_setting('app.t_e1')::bigint), current_setting('app.c256_final'),
  case when current_setting('app.c256_running') = format('ERR [P0001]: bad ticket change: ticket %s is still on hold; only an expired hold is closed without a handler', current_setting('app.t_e1'))
        and current_setting('app.bd_e1') = '1' and current_setting('app.c256_expired') = 'ok'
        and pg_temp.st(current_setting('app.t_e1')::bigint) = 'No-show #9001 held=null called=null fin=now by=null win=null'
        and current_setting('app.c256_final') like 'ERR [P0001]: bad ticket change:%(final)%'
       then 'OK' else 'FAIL' end), true);

-- TC-253. Expected: Registrar No-show (TC-250) kinds 'queue_hold_expired:s2' and note
-- 's2|Your hold ran out|<xbody(L(B2))>|NULL'; automatic close (TC-251) 's1|Your hold ran
-- out|<xbody(L(C1))>|NULL' exactly once (after both calls); the owner's early No-show of B1
-- (10 minutes, with a handler) 'ok' and silent ''; st(B1) 'No-show #1 held=null called=null
-- fin=now by=reg win=null'; the owner's close of the expired E1 'queue_hold_expired:s1'.
select set_config('app.r253', format('registrar_kinds [%s], registrar_note [%s], auto_note [%s], maint [%s], maint_kinds [%s], b1 [%s], owner_expired_kinds [%s] -> %s',
  current_setting('app.c253_reg_kinds'), current_setting('app.c253_reg_note'), current_setting('app.c253_auto_note'),
  current_setting('app.c253_maint'), current_setting('app.c253_maint_kinds'), pg_temp.st(current_setting('app.t_b1')::bigint),
  current_setting('app.c253_owner_kinds'),
  case when current_setting('app.c253_reg_kinds') = 'queue_hold_expired:s2'
        and current_setting('app.c253_reg_note') = 's2|Your hold ran out|' || pg_temp.xbody(current_setting('app.l_b2')) || '|NULL'
        and current_setting('app.c253_auto_note') = 's1|Your hold ran out|' || pg_temp.xbody(current_setting('app.l_c1')) || '|NULL'
        and current_setting('app.c253_maint') = 'ok' and current_setting('app.c253_maint_kinds') = ''
        and pg_temp.st(current_setting('app.t_b1')::bigint) = 'No-show #1 held=null called=null fin=now by=reg win=null'
        and current_setting('app.c253_owner_kinds') = 'queue_hold_expired:s1'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 8. TC-255: who may call queue_expire_holds; no direct table writes
-- ==========================================
set local role anon;
do $$
begin
  begin
    perform public.queue_expire_holds();
    perform set_config('app.c255_anon', 'ALLOWED', true);
  exception when others then
    perform set_config('app.c255_anon', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
  end;
end $$;
reset role;
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1,  'c255_cash',     'cash', $q$select public.queue_expire_holds()::text$q$),
    (2,  'c255_adm',      'adm',  $q$select public.queue_expire_holds()::text$q$),
    (3,  'c255_none',     'none', $q$select public.queue_expire_holds()::text$q$),
    (4,  'c255_s_update', 's1',   $q$update public.queue_tickets set status = 'No-show' where ticket_id = current_setting('app.t_c2')::bigint returning 'x'::text$q$),
    (5,  'c255_s_insert', 's1',   $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code) values (current_setting('app.sve')::bigint, current_setting('app.s1')::uuid, current_setting('app.today')::date, 9101, 1000101) returning 'x'::text$q$),
    (6,  'c255_s_delete', 's1',   $q$delete from public.queue_tickets where ticket_id = current_setting('app.t_c2')::bigint returning 'x'::text$q$),
    (7,  'c255_r_update', 'reg',  $q$update public.queue_tickets set status = 'No-show' where ticket_id = current_setting('app.t_c2')::bigint returning 'x'::text$q$),
    (8,  'c255_r_insert', 'reg',  $q$insert into public.queue_tickets (service_id, student_id, queue_date, ticket_number, ticket_code) values (current_setting('app.sve')::bigint, current_setting('app.s2')::uuid, current_setting('app.today')::date, 9102, 1000102) returning 'x'::text$q$),
    (9,  'c255_r_delete', 'reg',  $q$delete from public.queue_tickets where ticket_id = current_setting('app.t_c2')::bigint returning 'x'::text$q$)
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
-- Expected: anon 'ERR [42501]: permission denied for function queue_expire_holds'; Cashier,
-- Admin, no JWT '0'; the server role has EXECUTE, PUBLIC has none; the six direct writes
-- 'ERR [42501]: permission denied for table queue_tickets'; C2 still Held.
select set_config('app.r255', format('anon [%s], cashier [%s], admin [%s], no_jwt [%s], server %s, public_none %s, writes [%s; %s; %s; %s; %s; %s], c2 [%s] -> %s',
  current_setting('app.c255_anon'), current_setting('app.c255_cash'), current_setting('app.c255_adm'),
  current_setting('app.c255_none'),
  has_function_privilege(current_setting('app.srv'), 'public.queue_expire_holds()', 'EXECUTE'),
  not exists (select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a
               where p.oid = 'public.queue_expire_holds()'::regprocedure and a.grantee = 0),
  current_setting('app.c255_s_update'), current_setting('app.c255_s_insert'), current_setting('app.c255_s_delete'),
  current_setting('app.c255_r_update'), current_setting('app.c255_r_insert'), current_setting('app.c255_r_delete'),
  pg_temp.st(current_setting('app.t_c2')::bigint),
  case when current_setting('app.c255_anon') = 'ERR [42501]: permission denied for function queue_expire_holds'
        and current_setting('app.c255_cash') = '0' and current_setting('app.c255_adm') = '0'
        and current_setting('app.c255_none') = '0'
        and has_function_privilege(current_setting('app.srv'), 'public.queue_expire_holds()', 'EXECUTE')
        and not exists (select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a
                         where p.oid = 'public.queue_expire_holds()'::regprocedure and a.grantee = 0)
        and current_setting('app.c255_s_update') = 'ERR [42501]: permission denied for table queue_tickets'
        and current_setting('app.c255_s_insert') = 'ERR [42501]: permission denied for table queue_tickets'
        and current_setting('app.c255_s_delete') = 'ERR [42501]: permission denied for table queue_tickets'
        and current_setting('app.c255_r_update') = 'ERR [42501]: permission denied for table queue_tickets'
        and current_setting('app.c255_r_insert') = 'ERR [42501]: permission denied for table queue_tickets'
        and current_setting('app.c255_r_delete') = 'ERR [42501]: permission denied for table queue_tickets'
        and pg_temp.st(current_setting('app.t_c2')::bigint) = 'Held #2 held=other called=null fin=null by=null win=null'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- 9. TC-257 to TC-259: deleting enrollment items (throwaway term 2087-2088)
-- ==========================================
-- As postgres: a term (not current), two sections of the lowest subject, three enrollments
-- with items (owner path: the item trigger still requires Pending, same term, no duplicate),
-- then s3's enrollment approved (owner path: reviewer given).
insert into public.terms (school_year, semester, start_date, end_date, is_current)
values ('2087-2088', '2nd', date '2088-01-10', date '2088-05-20', false);
select set_config('app.term', (select term_id::text from public.terms where school_year = '2087-2088' and semester = '2nd'), true);
insert into public.sections (subject_id, term_id, section_code, schedule, capacity)
select (select min(s.subject_id) from public.subjects s), current_setting('app.term')::bigint, v.code, 'MWF 7:00-8:00', 40
from (values ('Z248A'), ('Z248B')) as v(code);
select set_config('app.sec_a', (select section_id::text from public.sections where term_id = current_setting('app.term')::bigint and section_code = 'Z248A'), true);
select set_config('app.sec_b', (select section_id::text from public.sections where term_id = current_setting('app.term')::bigint and section_code = 'Z248B'), true);
insert into public.enrollments (student_id, term_id, year_level)
select current_setting('app.' || v.who)::uuid, current_setting('app.term')::bigint, 1
from (values ('s1'), ('s2'), ('s3')) as v(who);
select set_config('app.e_' || v.who, (select enrollment_id::text from public.enrollments
  where term_id = current_setting('app.term')::bigint and student_id::text = current_setting('app.' || v.who)), true)
from (values ('s1'), ('s2'), ('s3')) as v(who);
insert into public.enrollment_items (enrollment_id, section_id)
values (current_setting('app.e_s1')::bigint, current_setting('app.sec_a')::bigint),
       (current_setting('app.e_s1')::bigint, current_setting('app.sec_b')::bigint),
       (current_setting('app.e_s2')::bigint, current_setting('app.sec_a')::bigint),
       (current_setting('app.e_s3')::bigint, current_setting('app.sec_a')::bigint);
select set_config('app.i1', (select enrollment_item_id::text from public.enrollment_items where enrollment_id = current_setting('app.e_s1')::bigint and section_id = current_setting('app.sec_a')::bigint), true);
select set_config('app.i2', (select enrollment_item_id::text from public.enrollment_items where enrollment_id = current_setting('app.e_s1')::bigint and section_id = current_setting('app.sec_b')::bigint), true);
select set_config('app.i3', (select enrollment_item_id::text from public.enrollment_items where enrollment_id = current_setting('app.e_s2')::bigint), true);
select set_config('app.i4', (select enrollment_item_id::text from public.enrollment_items where enrollment_id = current_setting('app.e_s3')::bigint), true);
update public.enrollments set status = 'Approved', reviewed_by = current_setting('app.reg')::uuid
where enrollment_id = current_setting('app.e_s3')::bigint;
select set_config('app.e3_status', (select status::text from public.enrollments where enrollment_id = current_setting('app.e_s3')::bigint), true);
select set_config('app.log_mark_e', (select coalesce(max(log_id), 0)::text from public.audit_logs), true);

-- The DELETEs through the API (user sessions), then anon.
set local role authenticated;
do $$
declare r record; v text;
begin
  for r in select * from (values
    (1, 'c257_reg',        'reg',  $q$with d as (delete from public.enrollment_items where enrollment_item_id = current_setting('app.i1')::bigint returning 1) select count(*)::text from d$q$),
    (2, 'c258_reg_locked', 'reg',  $q$with d as (delete from public.enrollment_items where enrollment_item_id = current_setting('app.i4')::bigint returning 1) select count(*)::text from d$q$),
    (3, 'c259_other',      's1',   $q$with d as (delete from public.enrollment_items where enrollment_item_id = current_setting('app.i3')::bigint returning 1) select count(*)::text from d$q$),
    (4, 'c259_cashier',    'cash', $q$with d as (delete from public.enrollment_items where enrollment_item_id = current_setting('app.i3')::bigint returning 1) select count(*)::text from d$q$),
    (5, 'c259_own',        's1',   $q$with d as (delete from public.enrollment_items where enrollment_item_id = current_setting('app.i2')::bigint returning 1) select count(*)::text from d$q$)
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
begin
  begin
    delete from public.enrollment_items where enrollment_item_id = current_setting('app.i3')::bigint;
    perform set_config('app.c259_anon', 'ALLOWED', true);
  exception when others then
    perform set_config('app.c259_anon', 'ERR [' || sqlstate || ']: ' || sqlerrm, true);
  end;
end $$;
reset role;
-- What is left and what the audit log says (as postgres).
select set_config('app.items_left', coalesce((select string_agg(v.k, ',' order by v.k)
  from (values ('i1'), ('i2'), ('i3'), ('i4')) as v(k)
  where exists (select 1 from public.enrollment_items i where i.enrollment_item_id::text = current_setting('app.' || v.k))), ''), true);
create function pg_temp.del_audit(p_item text) returns text language sql stable as $f$
  select coalesce(string_agg(pg_temp.who(l.actor_id), ',' order by l.log_id), 'none')
  from public.audit_logs l
  where l.log_id > current_setting('app.log_mark_e')::bigint and l.table_name = 'enrollment_items'
    and l.action = 'DELETE' and l.record_id = p_item
$f$;

-- TC-257. Expected: setup e3 'Approved'; the Registrar's DELETE '1'; i1 gone; exactly one
-- audit row DELETE for i1 with actor 'reg'.
select set_config('app.r257', format('e3 %s, registrar_delete [%s], i1_left %s, audit_actor [%s] -> %s',
  current_setting('app.e3_status'), current_setting('app.c257_reg'),
  (position('i1' in current_setting('app.items_left')) > 0), pg_temp.del_audit(current_setting('app.i1')),
  case when current_setting('app.e3_status') = 'Approved' and current_setting('app.c257_reg') = '1'
        and position('i1' in current_setting('app.items_left')) = 0
        and pg_temp.del_audit(current_setting('app.i1')) = 'reg'
       then 'OK' else 'FAIL' end), true);

-- TC-258. Expected: 'ERR [P0001]: enrollment locked: enrollment <e3> is Approved and its
-- sections can no longer be changed'; i4 still there; no audit row.
select set_config('app.r258', format('registrar_delete_approved [%s], i4_left %s, audit [%s] -> %s',
  current_setting('app.c258_reg_locked'), (position('i4' in current_setting('app.items_left')) > 0),
  pg_temp.del_audit(current_setting('app.i4')),
  case when current_setting('app.c258_reg_locked') = format('ERR [P0001]: enrollment locked: enrollment %s is Approved and its sections can no longer be changed', current_setting('app.e_s3'))
        and position('i4' in current_setting('app.items_left')) > 0
        and pg_temp.del_audit(current_setting('app.i4')) = 'none'
       then 'OK' else 'FAIL' end), true);

-- TC-259. Expected: s1 on s2's item '0', the Cashier '0', anon 'ERR [42501]: permission denied
-- for table enrollment_items'; i3 still there, no audit for it; s1's own item '1', gone,
-- audited with actor 's1'. Items left 'i3,i4'.
select set_config('app.r259', format('other_student [%s], cashier [%s], anon [%s], own [%s], items_left [%s], audit_i3 [%s], audit_i2 [%s] -> %s',
  current_setting('app.c259_other'), current_setting('app.c259_cashier'), current_setting('app.c259_anon'),
  current_setting('app.c259_own'), current_setting('app.items_left'),
  pg_temp.del_audit(current_setting('app.i3')), pg_temp.del_audit(current_setting('app.i2')),
  case when current_setting('app.c259_other') = '0' and current_setting('app.c259_cashier') = '0'
        and current_setting('app.c259_anon') = 'ERR [42501]: permission denied for table enrollment_items'
        and current_setting('app.c259_own') = '1' and current_setting('app.items_left') = 'i3,i4'
        and pg_temp.del_audit(current_setting('app.i3')) = 'none'
        and pg_temp.del_audit(current_setting('app.i2')) = 's1'
       then 'OK' else 'FAIL' end), true);

-- ==========================================
-- Result: ONE row
-- ==========================================
select (current_setting('app.r248') like '%-> OK' and current_setting('app.r249') like '%-> OK'
        and current_setting('app.r250') like '%-> OK' and current_setting('app.r251') like '%-> OK'
        and current_setting('app.r252') like '%-> OK' and current_setting('app.r253') like '%-> OK'
        and current_setting('app.r254') like '%-> OK' and current_setting('app.r255') like '%-> OK'
        and current_setting('app.r256') like '%-> OK' and current_setting('app.r257') like '%-> OK'
        and current_setting('app.r258') like '%-> OK' and current_setting('app.r259') like '%-> OK') as all_ok,
  current_setting('app.r248') as tc248, current_setting('app.r249') as tc249, current_setting('app.r250') as tc250,
  current_setting('app.r251') as tc251, current_setting('app.r252') as tc252, current_setting('app.r253') as tc253,
  current_setting('app.r254') as tc254, current_setting('app.r255') as tc255, current_setting('app.r256') as tc256,
  current_setting('app.r257') as tc257, current_setting('app.r258') as tc258, current_setting('app.r259') as tc259;

rollback;
