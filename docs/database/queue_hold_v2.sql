-- ==========================================
-- QUEUE HOLD V2: 30-MINUTE HOLD, AUTOMATIC NO-SHOW OF EXPIRED HOLDS, ITS NOTIFICATION,
-- AND THE REGISTRAR'S OWN DELETE ON enrollment_items (feature/hold-and-documents)
-- ==========================================
-- PM decisions (approved, 2026-10-14 live smoke test):
--   A. A hold lasts 30 minutes instead of 15.
--   B. The Registrar may mark a HELD ticket No-show only after the hold ran out.
--   C. Expired holds are closed by the database (Held -> No-show) through a function the app
--      calls; nothing depends on pg_cron.
--   D. The student is notified when an expired hold is closed (automatically or by the
--      Registrar after the deadline).
--   E. The Registrar drops a subject of a Pending enrollment with their OWN session (a DELETE
--      policy), so the audit row names the Registrar.
-- Runs AFTER queue_hold.sql (live), notifications_rules.sql (live) and enrollment_rules.sql
-- (live). Independent of first_year_curriculum.sql (either order).
--
-- WHAT IT DOES
--   1. private.queue_hold_limit() RETURNS interval   now '30 minutes' (still the ONE place;
--      queue_hold_my_ticket's held_until, queue_unhold_my_ticket's check and message, and
--      queue_my_status's held_until all read it, so they are NOT replaced here).
--   2. queue_tickets: ck_queue_tickets_state dropped and added again. Only one branch changes:
--        before: (status = 'No-show' AND called_at IS NULL AND finished_at IS NOT NULL
--                 AND handled_by IS NOT NULL AND window_label IS NULL)
--        now:    (status = 'No-show' AND called_at IS NULL AND finished_at IS NOT NULL
--                 AND window_label IS NULL)                       -- handled_by may be NULL
--      Every other branch is unchanged. No column is added (decision V1).
--   3. private.require_queue_ticket_rules()  (BEFORE UPDATE trigger)  CREATE OR REPLACE
--      Only the Held -> No-show step changes (decision V2); every other rule is the same.
--   4. public.queue_finish(p_ticket_id bigint, p_outcome text) RETURNS void  CREATE OR REPLACE
--      Held -> No-show is refused while the hold runs ("hold active:"); afterwards it sets
--      handled_by = the Registrar itself. Serving -> Done / No-show unchanged.
--   5. NEW public.queue_expire_holds() RETURNS integer
--      SECURITY DEFINER, owner postgres, search_path '', every name schema-qualified.
--      Sets EVERY Held ticket whose hold ran out (now() > held_at + the limit) to No-show,
--      handled_by NULL, called_at NULL, window NULL, finished_at = now() (trigger), held_at NULL
--      (trigger). Returns how many it closed. EXECUTE: authenticated and the server role; not
--      PUBLIC, not anon. No role check inside: it only ever touches expired holds, so any
--      signed-in user may call it (decision V3).
--   6. private.notify_on_queue_tickets()  CREATE OR REPLACE: one more condition and one new
--      kind (decision V4):
--        queue_hold_expired  Held -> No-show when the hold had run out: "Your hold ran out",
--                            "Ticket #1234567 was closed because your hold lasted over 30
--                            minutes. Show your QR code again at the Registrar to get a new
--                            number." (30 = the limit), link as the other queue kinds
--                            (/student/enrollment, /student/documents, else none).
--      The kind needs no constraint change: ck_notifications_kind is the pattern
--      '^[a-z][a-z_]{2,39}$' (notifications_rules.sql), 'queue_hold_expired' matches.
--   7. NEW policy enrollment_items_registrar_delete ON public.enrollment_items
--        AS PERMISSIVE FOR DELETE TO authenticated
--        USING ((SELECT private.current_role_name()) = 'Registrar')
--      (the same helper and text style as enrollments_registrar_review / grades_registrar_*;
--      current_role_name() returns a role only for an ACTIVE profile). The table-level DELETE
--      grant for authenticated already exists (enrollment_rules.sql section 6); GRANT DELETE is
--      repeated (a no-op when present). enrollment_items_student_remove is NOT changed.
--
-- ERRORS (PostgREST: code = SQLSTATE, message = text)
--   P0001  "hold active: ticket #1234567 is on hold until 14:05 (Manila time); it can be marked
--          No-show only after the hold runs out"            queue_finish(.., 'No-show') on a Held
--          ticket whose hold has not run out (NEW prefix). The trigger raises the same prefix
--          ("hold active: ticket #1234567 is still on hold; ...") for any signed-in caller.
--   P0001  "hold expired: ticket #1234567 was on hold for more than 30 minutes"  (unchanged
--          prefix; the number now says 30)
--   P0001  "bad ticket change: ticket 123 is still on hold; only an expired hold is closed
--          without a handler"                               owner UPDATE Held -> No-show with
--          handled_by NULL before the hold ran out
--   P0001  "bad ticket change: handled_by of ticket 123 must be the signed-in caller or empty"
--   P0001  "enrollment locked: enrollment 5 is Approved and its sections can no longer be
--          changed"   (unchanged, from require_enrollment_item_rules) a Registrar DELETE of an
--          item of a non-Pending enrollment
--   42501  "permission denied for function queue_expire_holds"   anon
--   (queue_expire_holds itself raises nothing; it returns 0 when there is nothing to close.)
--
-- DESIGN DECISIONS
--   V1. handled_by / NOT NULL. The live CHECK required handled_by for a never-called No-show.
--       Options: (a) a new column such as auto_closed boolean, or (b) allow handled_by NULL in
--       that one branch. Chosen (b), the least invasive: no new column (queue_tickets' column
--       list is checked by queue_hold.sql, queue_rules_test.sql TC-139 and the app's types),
--       the meaning is plain ("closed by the system, nobody handled it"), and the trigger
--       (V2) decides who may leave it empty. The CHECK cannot see held_at any more (it is NULL
--       outside Held), so "only an EXPIRED hold may end without a handler" is the trigger's
--       rule, which runs for every role. An owner INSERT could still write such a row
--       directly; INSERT is owner-only (no grant), same as every other shape. Audit: the
--       audit row of an automatic close has actor_id = the signed-in user whose page called
--       queue_expire_holds (or NULL from the SQL editor / pg_cron); handled_by NULL is what
--       marks it as automatic.
--   V2. The trigger's Held -> No-show step (every role):
--         expired := now() > held_at + private.queue_hold_limit()   (the same comparison as
--                    queue_unhold_my_ticket: at exactly 30 minutes the hold is still active)
--         signed-in caller (auth.uid() NOT NULL) and not expired -> "hold active:"
--         handled_by NULL and not expired -> "bad ticket change: ... still on hold"
--         signed-in caller sending a handled_by other than themself -> "bad ticket change:"
--         window_label must not change; called_at stays NULL; finished_at = now().
--       handled_by is now taken from the statement (queue_finish sends the Registrar,
--       queue_expire_holds sends NULL) instead of being replaced by auth.uid(): otherwise an
--       automatic close triggered from a STUDENT's or a Registrar's page would record that
--       person as the handler. Waiting -> Serving still sets handled_by = auth.uid().
--       OWNER PATH (decision B): the owner without a JWT (SQL editor, maintenance) may still
--       mark a held ticket No-show at any time WITH a handler (as in queue_hold.sql's H5), and
--       without a handler only after the hold ran out. Done, No-show and Cancelled stay final.
--   V3. queue_expire_holds and races. It selects the expired Held rows FOR UPDATE SKIP LOCKED
--       (the queue_call_next style) and updates only those, re-checking status = 'Held':
--         - unhold / cancel / queue_finish lock the same row FOR UPDATE. If one of them holds
--           the lock, the expiry skips that row (it is closed by a later call if it is still
--           an expired Held then). If the expiry locks first, they wait, then re-read the row
--           (READ COMMITTED re-check of their WHERE status IN (...)): unhold / cancel answer
--           "bad ticket change: no ticket on hold" / "no waiting ticket", queue_finish answers
--           "bad ticket change: ticket .. is No-show; only a Serving ticket can be finished".
--         - unhold itself refuses an expired hold ("hold expired:"), so the outcome never
--           depends on who wins: an expired hold can only end as No-show or Cancelled.
--         - queue_call_next takes only status = 'Waiting' (SKIP LOCKED) and the trigger
--           refuses Held -> Serving for every role, so a held ticket is never called.
--         - Idempotent: a second call finds nothing (No-show is final) and returns 0.
--       It touches every expired hold of every service and every day (an old day's held
--       ticket is expired by definition), so a stale Held ticket of an earlier day is closed as
--       No-show too (queue_hold.sql maintenance m1 closed those as Cancelled; both are final).
--       Safe for any signed-in caller: it takes no argument, reads no caller data, returns only
--       a count, and only closes holds that already ran out (which the PM wants closed).
--       Cost: one scan of queue_tickets per call (a small table; every 10 s per open Registrar
--       page). An index is not needed now; a partial index on (held_at) WHERE status = 'Held'
--       would make it constant if the table grows.
--   V4. Notifications: the trigger reacts to Held -> No-show ONLY when the hold had run out
--       (now() > OLD.held_at + limit), which is every automatic close and every Registrar
--       No-show of a held ticket after this file (queue_finish refuses earlier). An owner's
--       early maintenance No-show stays silent (the text would be untrue). Hold, unhold and
--       cancel stay silent (queue_hold.sql H8). The notification is written in the same
--       transaction as the close, once per ticket (the step happens once: No-show is final).
--       Safety check (g) requires the live function to be exactly the notifications_rules.sql
--       version (the three conditions queue_hold.sql check (g) expected, no 'Held') or this
--       file's version (re-run), before replacing it.
--   V5. pg_cron. Nothing in this repo enables it (applications_rules.sql, login_lockout.sql
--       and queue_rules.sql only mention it as "a separate decision"), and it cannot be checked
--       from here. This file does not depend on it: the app calls queue_expire_holds()
--       (a) on every refresh of the Registrar's queue page (every 10 s) and (b) when the
--       student's queue page loads. Safety check (l) only prints a NOTICE saying whether
--       pg_cron is installed. OPTIONAL, only if the PM enables the extension (Dashboard ->
--       Database -> Extensions -> pg_cron), as postgres, once:
--         select cron.schedule('queue-expire-holds', '* * * * *',
--                              $cron$select public.queue_expire_holds()$cron$);
--       and to remove it: select cron.unschedule('queue-expire-holds');
--       (pg_cron runs it as postgres without a JWT: the owner path, handled_by NULL, actor
--       NULL in the audit row. The app calls stay useful as a second trigger.)
--   V6. Registrar DELETE on enrollment_items. The policy gives the Registrar every row for
--       DELETE (they already read every row, policy enrollment_items_read). The existing
--       BEFORE DELETE trigger require_enrollment_item_rules (SECURITY DEFINER, every role)
--       locks the enrollment and refuses an item of a non-Pending enrollment ("enrollment
--       locked:"), so only Pending enrollments can lose a subject. The AFTER audit_log trigger
--       (private.audit_log(), hardening2.sql) writes actor_id = auth.uid() when that id has a
--       profile, so a DELETE through the API with the Registrar's session is audited with the
--       Registrar as actor (test TC-257 reads the audit row back). A student's own Pending
--       delete (enrollment_items_student_remove) is unchanged; another student's item is not
--       visible to the student's DELETE (0 rows). Two permissive DELETE policies are OR-ed.
--
-- RESIDUAL RISKS AND OLDER FILES THAT NOW DISAGREE (not edited here)
--   R1 queue_hold.sql must NOT be run again as it stands: its safety check (g) refuses a
--      notify function containing 'Held', and its post-check (c) expects 15 minutes; its
--      constraint text, trigger and queue_finish would also undo this file.
--   R2 queue_hold_test.sql: TC-199 (limit '00:15:00'), TC-201 / TC-204 / TC-205 / TC-209 /
--      TC-210 (held_until = now() + 15 minutes), TC-207 (expects "15 minutes" and 16 minutes
--      as expired), TC-208 and TC-214 (an immediate Registrar No-show of a held ticket is now
--      refused "hold active:"), TC-215 (a handler-less owner No-show is now refused by the
--      trigger with P0001 instead of the CHECK's 23514) will FAIL. Use queue_hold_v2_test.sql.
--   R3 queue_hold_rehearsal.sql: same as R2 and R1 (do not run it any more).
--   R4 enrollment_rules.sql: its safety check (d) compares the policy set and would stop on
--      the new policy (do not re-run it as it stands); enrollment_rules_test.sql TC-119
--      ("Registrar cannot delete") will now FAIL for the Registrar's DELETE. The
--      informational cell of first_year_curriculum_test.sql TC-247 ("registrar_api_delete")
--      will show rows 1 instead of rows 0 (not judged).
--   R5 notifications_rules.sql must not be run again as it stands (it would put back the old
--      queue trigger function: the new kind would stop, nothing else breaks).
--   R6 The CHECK no longer forces a handler on a never-called No-show; the trigger does (V1).
--   R7 Until the app calls queue_expire_holds, expired holds stay Held exactly as today (the
--      Registrar can now close them with No-show after 30 minutes).
--
-- How to run: Supabase SQL editor, as postgres, at a quiet time (ALTER TABLE takes a short
-- ACCESS EXCLUSIVE lock on queue_tickets). Copy from "BEGIN;" to "COMMIT;" inclusive into a new
-- tab and run that tab as a whole (never a partial selection). One transaction: any error,
-- including a failed check, rolls back everything. Re-runnable (CREATE OR REPLACE, the
-- constraint and the policy dropped and added again, grants rebuilt from REVOKE ALL).
--   - Before running: run diagnostics (a), (b), (c) and (d) below and SAVE the output.
--   - Rehearse first: docs/database/queue_hold_v2_rehearsal.sql (this change and TC-248 to
--     TC-259 in ONE rolled-back transaction, one result row).
--   - Test afterwards: docs/database/queue_hold_v2_test.sql (TC-248 to TC-259), then
--     regression_after_grants.sql (unchanged results expected).
--   - Deploy the app change (queue_expire_holds calls, the "hold active:" message, the
--     30-minute texts, the Registrar's drop with the user session) only AFTER this file is
--     live. The current app keeps working: no result shape changes; its "No-show" button on
--     a held ticket gets "hold active:" until 30 minutes have passed.
-- Undo: the ROLLBACK block below (comments; run it on purpose, as a whole).
--
-- Status: NOT RUN YET (written 2026-10-14 without a local PostgreSQL; rehearse first).
--
-- ------------------------------------------
-- ROLLBACK (back to queue_hold.sql + notifications_rules.sql + enrollment_rules.sql)
-- ------------------------------------------
-- Remove the app's queue_expire_holds calls and the Registrar's user-session drop FIRST (the
-- drop goes back to the server-side admin client). Tickets closed automatically keep
-- handled_by NULL, which the old ck_queue_tickets_state does not allow, so that constraint is
-- added back NOT VALID (still enforced for every new or changed row; those final rows never
-- change again). Held tickets stay Held (with 15 minutes, a hold between 15 and 30 minutes old
-- can no longer be undone). Notifications already written stay. The old function bodies are
-- copied verbatim from queue_hold.sql (trigger, queue_finish) and notifications_rules.sql
-- (notify_on_queue_tickets).
--
-- BEGIN;
--
-- DROP POLICY IF EXISTS enrollment_items_registrar_delete ON public.enrollment_items;
-- DROP FUNCTION IF EXISTS public.queue_expire_holds();
--
-- CREATE OR REPLACE FUNCTION private.queue_hold_limit()
--  RETURNS interval
--  LANGUAGE sql
--  IMMUTABLE
--  SET search_path TO ''
-- AS $function$
--   SELECT interval '15 minutes'
-- $function$;
-- REVOKE ALL ON FUNCTION private.queue_hold_limit() FROM PUBLIC, anon, authenticated;
--
-- CREATE OR REPLACE FUNCTION private.require_queue_ticket_rules()
--  RETURNS trigger
--  LANGUAGE plpgsql
--  SECURITY INVOKER
--  SET search_path TO ''
-- AS $function$
-- DECLARE
--   v_uid  uuid := auth.uid();
--   v_old  text;
--   v_new  text;
--   v_step text;
-- BEGIN
--   IF TG_OP <> 'UPDATE' OR TG_WHEN <> 'BEFORE' OR TG_LEVEL <> 'ROW'
--      OR TG_TABLE_SCHEMA <> 'public' OR TG_TABLE_NAME <> 'queue_tickets' THEN
--     RAISE EXCEPTION 'private.require_queue_ticket_rules must be a BEFORE UPDATE FOR EACH ROW trigger on public.queue_tickets';
--   END IF;
--
--   v_old := OLD.status;
--   v_new := NEW.status;
--
--   -- What the ticket is never changes.
--   IF NEW.ticket_id IS DISTINCT FROM OLD.ticket_id
--      OR NEW.student_id IS DISTINCT FROM OLD.student_id
--      OR NEW.service_id IS DISTINCT FROM OLD.service_id
--      OR NEW.queue_date IS DISTINCT FROM OLD.queue_date
--      OR NEW.ticket_number IS DISTINCT FROM OLD.ticket_number
--      OR NEW.ticket_code IS DISTINCT FROM OLD.ticket_code
--      OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
--     RAISE EXCEPTION 'bad ticket change: the student, service, date, number, code and creation time of ticket % cannot be changed', OLD.ticket_id
--       USING ERRCODE = 'P0001';
--   END IF;
--
--   -- Final states: nothing changes any more.
--   IF v_old IN ('Done', 'No-show', 'Cancelled') THEN
--     IF pg_catalog.to_jsonb(NEW) IS DISTINCT FROM pg_catalog.to_jsonb(OLD) THEN
--       RAISE EXCEPTION 'bad ticket change: ticket % is % (final) and cannot be changed', OLD.ticket_id, v_old
--         USING ERRCODE = 'P0001',
--               HINT = 'Done, No-show and Cancelled are final. The student gets a new ticket instead.';
--     END IF;
--     RETURN NEW;
--   END IF;
--
--   -- One step of the flow.
--   IF v_new IS DISTINCT FROM v_old THEN
--     v_step := COALESCE(v_old, 'NULL') || ' -> ' || COALESCE(v_new, 'NULL');
--     IF v_step NOT IN ('Waiting -> Serving', 'Waiting -> Cancelled', 'Waiting -> Held',
--                       'Held -> Waiting', 'Held -> Cancelled', 'Held -> No-show',
--                       'Serving -> Done', 'Serving -> No-show') THEN
--       RAISE EXCEPTION 'bad ticket change: % is not allowed (ticket %)', v_step, OLD.ticket_id
--         USING ERRCODE = 'P0001',
--               HINT = 'Allowed: Waiting -> Serving, Held or Cancelled; Held -> Waiting, Cancelled or No-show; Serving -> Done or No-show.';
--     END IF;
--   END IF;
--
--   IF v_old = 'Waiting' AND v_new = 'Serving' THEN
--     -- The call: who calls it and at which window; the time is the database's.
--     IF v_uid IS NOT NULL THEN
--       NEW.handled_by := v_uid;
--     END IF;
--     NEW.window_label := NULLIF(pg_catalog.btrim(NEW.window_label), '');
--     NEW.called_at := pg_catalog.now();
--     NEW.finished_at := NULL;
--   ELSIF v_old = 'Held' AND v_new = 'No-show' THEN
--     -- A held ticket marked No-show by the Registrar (H5): never called, no window.
--     IF v_uid IS NOT NULL THEN
--       NEW.handled_by := v_uid;
--     END IF;
--     IF NEW.window_label IS DISTINCT FROM OLD.window_label THEN
--       RAISE EXCEPTION 'bad ticket change: window_label of ticket % is set only when it is called', OLD.ticket_id
--         USING ERRCODE = 'P0001';
--     END IF;
--     NEW.called_at := OLD.called_at;
--     NEW.finished_at := pg_catalog.now();
--   ELSE
--     IF NEW.handled_by IS DISTINCT FROM OLD.handled_by
--        OR NEW.window_label IS DISTINCT FROM OLD.window_label THEN
--       RAISE EXCEPTION 'bad ticket change: handled_by and window_label of ticket % are set only when it is called', OLD.ticket_id
--         USING ERRCODE = 'P0001';
--     END IF;
--     NEW.called_at := OLD.called_at;
--     IF v_new IS DISTINCT FROM v_old AND v_new IN ('Done', 'No-show', 'Cancelled') THEN
--       NEW.finished_at := pg_catalog.now();
--     ELSE
--       NEW.finished_at := OLD.finished_at;   -- Waiting <-> Held, or no status change
--     END IF;
--   END IF;
--
--   -- held_at belongs to the database (H3).
--   IF v_new = 'Held' THEN
--     IF v_old = 'Held' THEN
--       NEW.held_at := OLD.held_at;
--     ELSE
--       NEW.held_at := pg_catalog.now();
--     END IF;
--   ELSE
--     NEW.held_at := NULL;
--   END IF;
--
--   RETURN NEW;
-- END
-- $function$;
--
-- -- Same grant style as the other trigger functions (hardening2.sql section C).
-- REVOKE EXECUTE ON FUNCTION private.require_queue_ticket_rules() FROM PUBLIC, anon;
-- GRANT EXECUTE ON FUNCTION private.require_queue_ticket_rules() TO authenticated;
--
-- -- Registrar: finish a Serving ticket as Done or No-show, or mark a Held ticket No-show (H5).
-- CREATE OR REPLACE FUNCTION public.queue_finish(p_ticket_id bigint, p_outcome text)
--  RETURNS void
--  LANGUAGE plpgsql
--  VOLATILE
--  SECURITY DEFINER
--  SET search_path TO ''
-- AS $function$
-- DECLARE
--   v_status text;
-- BEGIN
--   PERFORM private.queue_require_role('Registrar');
--
--   IF p_outcome IS NULL OR p_outcome NOT IN ('Done', 'No-show') THEN
--     RAISE EXCEPTION 'invalid ticket request: the outcome must be Done or No-show, not [%]', COALESCE(pg_catalog.left(p_outcome, 40), 'NULL')
--       USING ERRCODE = '22023';
--   END IF;
--
--   SELECT t.status INTO v_status
--   FROM public.queue_tickets t
--   WHERE t.ticket_id = p_ticket_id
--   FOR UPDATE OF t;
--   IF NOT FOUND THEN
--     RAISE EXCEPTION 'bad ticket change: ticket % does not exist', COALESCE(p_ticket_id::text, 'NULL')
--       USING ERRCODE = 'P0001';
--   END IF;
--   IF v_status = 'Held' THEN
--     IF p_outcome <> 'No-show' THEN
--       RAISE EXCEPTION 'bad ticket change: ticket % is on hold; it can only be marked No-show', p_ticket_id
--         USING ERRCODE = 'P0001';
--     END IF;
--   ELSIF v_status <> 'Serving' THEN
--     RAISE EXCEPTION 'bad ticket change: ticket % is %; only a Serving ticket can be finished', p_ticket_id, v_status
--       USING ERRCODE = 'P0001';
--   END IF;
--
--   -- finished_at (and handled_by for a held ticket) are set by the trigger.
--   UPDATE public.queue_tickets AS t SET status = p_outcome WHERE t.ticket_id = p_ticket_id;
-- END
-- $function$;
-- REVOKE ALL ON FUNCTION public.queue_finish(bigint, text) FROM PUBLIC, anon, authenticated;
-- GRANT EXECUTE ON FUNCTION public.queue_finish(bigint, text) TO authenticated;
--
-- -- queue_tickets: queue_ticket, queue_turn, queue_skipped (decision 6).
-- CREATE OR REPLACE FUNCTION private.notify_on_queue_tickets()
--  RETURNS trigger
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO ''
-- AS $function$
-- DECLARE
--   v_service text;
--   v_link    text;
--   v_label   text;
--   v_ahead   integer;
--   v_where   text;
-- BEGIN
--   BEGIN
--     IF TG_OP = 'INSERT' THEN
--       IF NEW.status IS DISTINCT FROM 'Waiting' THEN
--         RETURN NULL;
--       END IF;
--     ELSIF TG_OP = 'UPDATE' THEN
--       IF NOT ((OLD.status = 'Waiting' AND NEW.status = 'Serving')
--               OR (OLD.status = 'Serving' AND NEW.status = 'No-show')) THEN
--         RETURN NULL;
--       END IF;
--     ELSE
--       RETURN NULL;
--     END IF;
--
--     SELECT s.service_code INTO v_service
--     FROM public.queue_services s
--     WHERE s.service_id = NEW.service_id;
--     v_link := CASE v_service
--                 WHEN 'Enrollment' THEN '/student/enrollment'
--                 WHEN 'Documents' THEN '/student/documents'
--               END;
--     v_label := '#' || NEW.ticket_code::text;
--
--     IF TG_OP = 'INSERT' THEN
--       SELECT pg_catalog.count(*)::integer INTO v_ahead
--       FROM public.queue_tickets w
--       WHERE w.service_id = NEW.service_id AND w.queue_date = NEW.queue_date
--         AND w.status = 'Waiting' AND w.ticket_number < NEW.ticket_number;
--       PERFORM private.notify(NEW.student_id, 'queue_ticket', 'You are in line',
--         'Your ticket is ' || v_label || '. '
--           || CASE WHEN v_ahead = 0 THEN 'No one is ahead of you.'
--                   WHEN v_ahead = 1 THEN '1 person is ahead of you.'
--                   ELSE v_ahead::text || ' people are ahead of you.' END,
--         v_link);
--     ELSIF NEW.status = 'Serving' THEN
--       v_where := COALESCE(NULLIF(pg_catalog.btrim(NEW.window_label), ''), 'the Registrar window');
--       PERFORM private.notify(NEW.student_id, 'queue_turn', 'It is your turn',
--         'Go to ' || v_where || ' now. Bring your valid ID.', v_link);
--     ELSE
--       PERFORM private.notify(NEW.student_id, 'queue_skipped', 'You were skipped',
--         'Your number was called and you were not at the window. Show your code again to get a new number.',
--         v_link);
--     END IF;
--   EXCEPTION WHEN OTHERS THEN
--     RAISE WARNING 'notify_on_queue_tickets: notification skipped (% %)', SQLSTATE, SQLERRM;
--   END;
--   RETURN NULL;
-- END
-- $function$;
-- REVOKE EXECUTE ON FUNCTION private.notify_on_queue_tickets() FROM PUBLIC, anon;
-- GRANT EXECUTE ON FUNCTION private.notify_on_queue_tickets() TO authenticated;
--
-- ALTER TABLE public.queue_tickets DROP CONSTRAINT IF EXISTS ck_queue_tickets_state;
-- ALTER TABLE public.queue_tickets ADD CONSTRAINT ck_queue_tickets_state CHECK (
--     (status IN ('Waiting', 'Held') AND called_at IS NULL AND finished_at IS NULL AND handled_by IS NULL)
--     OR (status = 'Serving' AND called_at IS NOT NULL AND finished_at IS NULL AND handled_by IS NOT NULL)
--     OR (status IN ('Done', 'No-show') AND called_at IS NOT NULL AND finished_at IS NOT NULL AND handled_by IS NOT NULL)
--     OR (status = 'No-show' AND called_at IS NULL AND finished_at IS NOT NULL AND handled_by IS NOT NULL AND window_label IS NULL)
--     OR (status = 'Cancelled' AND called_at IS NULL AND finished_at IS NOT NULL)) NOT VALID;
-- NOTIFY pgrst, 'reload schema';
--
-- COMMIT;
--
-- ------------------------------------------
-- DIAGNOSTICS (read-only; run one at a time BEFORE and AFTER, save the output)
-- ------------------------------------------
-- a) The constraints on queue_tickets (BEFORE: the queue_hold.sql text; AFTER: the No-show
--    branch without handled_by):
-- select c.conname, pg_get_constraintdef(c.oid) from pg_constraint c
-- where c.conrelid = 'public.queue_tickets'::regclass order by 1;
--
-- b) The queue functions, their owner and ACLs (queue_expire_holds only AFTER):
-- select p.oid::regprocedure as signature, p.prosecdef, p.proconfig, p.proowner::regrole, p.proacl::text
-- from pg_proc p
-- where (p.pronamespace = 'public'::regnamespace and p.proname like 'queue\_%')
--    or (p.pronamespace = 'private'::regnamespace
--        and p.proname in ('queue_hold_limit', 'require_queue_ticket_rules', 'notify_on_queue_tickets'))
-- order by 1;
--
-- c) The policies and grants on enrollment_items:
-- select p.policyname, p.cmd, p.permissive, p.roles, p.qual, p.with_check
-- from pg_policies p where p.schemaname = 'public' and p.tablename = 'enrollment_items' order by 1;
-- select c.relacl::text from pg_class c where c.oid = 'public.enrollment_items'::regclass;
--
-- d) Held tickets now, with how long they have been held (BEFORE: these would be closed at
--    once by the first queue_expire_holds call if older than 30 minutes):
-- select s.service_code, t.queue_date, t.ticket_number, '#' || t.ticket_code as label, t.held_at,
--        now() - t.held_at as held_for, now() > t.held_at + interval '30 minutes' as expired_v2
-- from public.queue_tickets t join public.queue_services s on s.service_id = t.service_id
-- where t.status = 'Held' order by t.held_at;
--
-- e) AFTER: automatic closes (No-show, never called, no handler) and their audit actor:
-- select t.ticket_id, '#' || t.ticket_code as label, t.finished_at, l.actor_id
-- from public.queue_tickets t
-- left join public.audit_logs l on l.table_name = 'queue_tickets' and l.record_id = t.ticket_id::text
--   and l.old_data ->> 'status' = 'Held' and l.new_data ->> 'status' = 'No-show'
-- where t.status = 'No-show' and t.called_at is null and t.handled_by is null
-- order by t.finished_at desc limit 20;
--
-- f) Is pg_cron available / installed (information only; see V5)?
-- select name, default_version, installed_version from pg_available_extensions where name = 'pg_cron';
--
-- g) AFTER: the new notifications (counts only):
-- select count(*) as total, count(*) filter (where read_at is null) as unread
-- from public.notifications where kind = 'queue_hold_expired';
--
-- ------------------------------------------
-- WHAT THE APP MUST DO (separate task; contract)
-- ------------------------------------------
-- - Registrar queue page, on every refresh (10 s), BEFORE reading the list:
--     rpc('queue_expire_holds')  -> integer (closed now; ignore errors, never block the page)
-- - Student queue page, when it loads (before queue_my_status): rpc('queue_expire_holds').
-- - queue_finish on a held ticket: new message prefix "hold active:" -> e.g. "This hold has
--   not run out yet. You can mark it No-show after <held_at + 30 min>." Hide or disable the
--   No-show button of a held ticket until held_at + 30 minutes (queue_staff_list gives held_at).
-- - Texts and constants 15 -> 30 minutes (lib/data/queue-actions.ts comment, any UI text,
--   tests\unit\db-errors-queue.test.ts sample message). held_until from queue_my_status is
--   already right.
-- - Notification kind 'queue_hold_expired': lib/notifications/kind.ts maps by the prefix
--   'queue_', so it already gets the queue icon; no change needed (a unit test may be added).
-- - Registrar "drop a subject" (lib/data/enrollments-review-actions.ts dropEnrollmentSection):
--   use the user's own server client (cookies session) instead of getAdminClientFor; same
--   .delete().eq('enrollment_item_id', ..).eq('enrollment_id', ..).select(...). A non-Pending
--   enrollment answers P0001 "enrollment locked:"; 0 rows = not found or not allowed.


BEGIN;

-- ------------------------------------------
-- 1. Safety checks (stop before changing anything)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
  v_src text;
  v_srv text := 'service' || '_role';
BEGIN
  IF current_setting('server_version_num')::int < 170000 THEN
    RAISE EXCEPTION 'queue_hold_v2: PostgreSQL 17+ expected (REVOKE ALL includes MAINTAIN); found %', current_setting('server_version');
  END IF;

  -- a) The tables exist.
  SELECT string_agg(e.t, ', ') INTO v_bad
  FROM (VALUES ('queue_services'), ('queue_tickets'), ('notifications'), ('profiles'), ('roles'),
               ('audit_logs'), ('enrollments'), ('enrollment_items')) AS e(t)
  WHERE pg_catalog.to_regclass('public.' || e.t) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold_v2: missing table(s) public.%; stop', v_bad;
  END IF;

  -- b) The functions this file uses or replaces exist (queue_hold.sql and
  --    notifications_rules.sql are live).
  SELECT string_agg(e.sig, ', ') INTO v_bad
  FROM (VALUES ('public.queue_hold_my_ticket(text)'), ('public.queue_unhold_my_ticket(text)'),
               ('public.queue_finish(bigint, text)'), ('public.queue_call_next(text, text)'),
               ('public.queue_cancel_my_ticket(text)'), ('public.queue_my_status(text)'),
               ('private.queue_hold_limit()'), ('private.require_queue_ticket_rules()'),
               ('private.notify_on_queue_tickets()'), ('private.notify(uuid, text, text, text, text)'),
               ('private.queue_label(integer)'), ('private.queue_require_role(text)'),
               ('private.audit_log()'), ('private.current_role_name()'), ('private.active_uid()'),
               ('auth.uid()')) AS e(sig)
  WHERE pg_catalog.to_regprocedure(e.sig) IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold_v2: missing function(s) %; run queue_hold.sql and notifications_rules.sql first; stop', v_bad;
  END IF;

  -- c) The server role exists (it gets EXECUTE on queue_expire_holds).
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = v_srv) THEN
    RAISE EXCEPTION 'queue_hold_v2: the server role is missing; stop';
  END IF;

  -- d) queue_tickets is as queue_hold.sql made it: held_at, and the three CHECKs with Held.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = 'public.queue_tickets'::pg_catalog.regclass AND a.attname = 'held_at'
                   AND NOT a.attisdropped AND pg_catalog.format_type(a.atttypid, NULL) = 'timestamp with time zone')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'c'
                      AND k.conname = 'ck_queue_tickets_status'
                      AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%''Held''::text%')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'c'
                      AND k.conname = 'ck_queue_tickets_state'
                      AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%Held%'
                      AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%No-show%'
                      AND pg_catalog.pg_get_constraintdef(k.oid) LIKE '%window_label IS NULL%')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                    WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'c'
                      AND k.conname = 'ck_queue_tickets_held') THEN
    RAISE EXCEPTION 'queue_hold_v2: queue_tickets.held_at or the CHECKs ck_queue_tickets_status / _state / _held are not as queue_hold.sql made them; stop and review';
  END IF;

  -- e) Triggers on queue_tickets exactly as queue_hold.sql left them.
  SELECT string_agg(t.tgname || ' ' || t.tgtype || ' ' || t.tgenabled::text || ' ' || t.tgfoid::pg_catalog.regprocedure::text, ', ' ORDER BY t.tgname) INTO v_bad
  FROM pg_catalog.pg_trigger t
  WHERE t.tgrelid = 'public.queue_tickets'::pg_catalog.regclass AND NOT t.tgisinternal;
  IF v_bad IS DISTINCT FROM 'audit_log 29 O private.audit_log(), require_queue_ticket_rules 19 O private.require_queue_ticket_rules(), trg_notify_queue_tickets 21 O private.notify_on_queue_tickets()' THEN
    RAISE EXCEPTION 'queue_hold_v2: triggers on queue_tickets not as expected ([%]); stop and review', v_bad;
  END IF;

  -- f) The live bodies are queue_hold.sql's (or this file's, on a re-run).
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'private.require_queue_ticket_rules()'::pg_catalog.regprocedure;
  IF NOT ((pg_catalog.strpos(v_src, '''Held -> No-show''') > 0 AND pg_catalog.strpos(v_src, 'held_at belongs to the database') > 0)
          OR pg_catalog.strpos(v_src, 'queue_hold_v2') > 0) THEN
    RAISE EXCEPTION 'queue_hold_v2: the live private.require_queue_ticket_rules is not queue_hold.sql''s; stop and review';
  END IF;
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.queue_finish(bigint, text)'::pg_catalog.regprocedure;
  IF pg_catalog.strpos(v_src, 'it can only be marked No-show') = 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: the live public.queue_finish is not queue_hold.sql''s; stop and review';
  END IF;
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.queue_call_next(text, text)'::pg_catalog.regprocedure;
  IF pg_catalog.strpos(v_src, 'AND t.status = ''Waiting''') = 0 OR pg_catalog.strpos(v_src, 'SKIP LOCKED') = 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: the live public.queue_call_next does not take only Waiting tickets (SKIP LOCKED); stop and review';
  END IF;
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.queue_unhold_my_ticket(text)'::pg_catalog.regprocedure;
  IF pg_catalog.strpos(v_src, 'hold expired:') = 0 OR pg_catalog.strpos(v_src, 'private.queue_hold_limit()') = 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: the live public.queue_unhold_my_ticket does not use private.queue_hold_limit(); stop and review';
  END IF;
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.queue_my_status(text)'::pg_catalog.regprocedure;
  IF pg_catalog.strpos(v_src, 'private.queue_hold_limit()') = 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: the live public.queue_my_status does not use private.queue_hold_limit(); stop and review';
  END IF;
  IF private.queue_hold_limit() NOT IN (interval '15 minutes', interval '30 minutes') THEN
    RAISE EXCEPTION 'queue_hold_v2: private.queue_hold_limit() is %, expected 15 minutes (or 30 on a re-run); stop and review', private.queue_hold_limit();
  END IF;

  -- g) Notifications (V4): the live queue trigger function must react only to a Waiting
  --    INSERT, Waiting -> Serving and Serving -> No-show (queue_hold.sql check (g)), or be
  --    this file's version (re-run).
  SELECT p.prosrc INTO v_src FROM pg_catalog.pg_proc p
  WHERE p.oid = 'private.notify_on_queue_tickets()'::pg_catalog.regprocedure;
  IF NOT ((pg_catalog.strpos(v_src, 'IF NEW.status IS DISTINCT FROM ''Waiting'' THEN') > 0
           AND pg_catalog.strpos(v_src, 'IF NOT ((OLD.status = ''Waiting'' AND NEW.status = ''Serving'')') > 0
           AND pg_catalog.strpos(v_src, 'OR (OLD.status = ''Serving'' AND NEW.status = ''No-show'')) THEN') > 0
           AND pg_catalog.strpos(v_src, 'Held') = 0)
          OR (pg_catalog.strpos(v_src, 'queue_hold_v2') > 0
              AND pg_catalog.strpos(v_src, 'OR (OLD.status = ''Held'' AND NEW.status = ''No-show''') > 0
              AND pg_catalog.strpos(v_src, '''queue_hold_expired''') > 0)) THEN
    RAISE EXCEPTION 'queue_hold_v2: private.notify_on_queue_tickets is neither the notifications_rules.sql version nor this file''s; stop and review';
  END IF;

  -- h) No queue_expire_holds with another signature (PostgREST ambiguity).
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE p.pronamespace = 'public'::pg_catalog.regnamespace AND p.proname = 'queue_expire_holds'
    AND p.oid IS DISTINCT FROM pg_catalog.to_regprocedure('public.queue_expire_holds()');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold_v2: function(s) with another signature already exist: %; stop and review', v_bad;
  END IF;

  -- i) SECURITY DEFINER sees every row only if its owner (the running role) bypasses RLS.
  SELECT string_agg(c.relname, ', ') INTO v_bad
  FROM pg_catalog.pg_class c
  WHERE c.oid IN ('public.queue_tickets'::pg_catalog.regclass, 'public.notifications'::pg_catalog.regclass,
                  'public.profiles'::pg_catalog.regclass, 'public.queue_services'::pg_catalog.regclass)
    AND NOT (SELECT r2.rolbypassrls FROM pg_catalog.pg_roles r2 WHERE r2.rolname = current_user)
    AND NOT (c.relowner = (SELECT r2.oid FROM pg_catalog.pg_roles r2 WHERE r2.rolname = current_user)
             AND NOT c.relforcerowsecurity);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'queue_hold_v2: % would not bypass RLS on %; run as the table owner (postgres); stop', current_user, v_bad;
  END IF;

  -- j) enrollment_items (E): RLS on; the item rule trigger (BEFORE INSERT OR UPDATE OR DELETE
  --    ROW = 31) and the audit trigger (AFTER INSERT OR UPDATE OR DELETE ROW = 29) enabled; the
  --    audit function records auth.uid(); the DELETE policies are the student's (and this
  --    file's on a re-run), nothing else.
  IF NOT (SELECT c.relrowsecurity FROM pg_catalog.pg_class c WHERE c.oid = 'public.enrollment_items'::pg_catalog.regclass)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid = 'public.enrollment_items'::pg_catalog.regclass AND NOT t.tgisinternal
                      AND t.tgname = 'require_enrollment_item_rules' AND t.tgtype = 31 AND t.tgenabled = 'O'
                      AND t.tgfoid = 'private.require_enrollment_item_rules()'::pg_catalog.regprocedure)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid = 'public.enrollment_items'::pg_catalog.regclass AND NOT t.tgisinternal
                      AND t.tgname = 'audit_log' AND t.tgtype = 29 AND t.tgenabled = 'O'
                      AND t.tgfoid = 'private.audit_log()'::pg_catalog.regprocedure)
     OR pg_catalog.strpos((SELECT p.prosrc FROM pg_catalog.pg_proc p
                            WHERE p.oid = 'private.audit_log()'::pg_catalog.regprocedure), 'auth.uid()') = 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: enrollment_items RLS, its triggers require_enrollment_item_rules / audit_log or private.audit_log() are not as enrollment_rules.sql / hardening2.sql made them; stop';
  END IF;
  SELECT string_agg(p.policyname::text, ', ' ORDER BY p.policyname) INTO v_bad
  FROM pg_catalog.pg_policies p
  WHERE p.schemaname = 'public' AND p.tablename = 'enrollment_items' AND p.cmd IN ('DELETE', 'ALL');
  IF v_bad IS DISTINCT FROM 'enrollment_items_student_remove'
     AND v_bad IS DISTINCT FROM 'enrollment_items_registrar_delete, enrollment_items_student_remove' THEN
    RAISE EXCEPTION 'queue_hold_v2: the DELETE policies on enrollment_items are [%], expected enrollment_items_student_remove only; stop and review', v_bad;
  END IF;

  -- k) No row has a status outside the known ones.
  IF EXISTS (SELECT 1 FROM public.queue_tickets t
             WHERE t.status NOT IN ('Waiting', 'Serving', 'Held', 'Done', 'No-show', 'Cancelled')) THEN
    RAISE EXCEPTION 'queue_hold_v2: queue_tickets has a status outside the known ones; stop and review';
  END IF;

  -- l) pg_cron: information only (V5); nothing here depends on it.
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_extension x WHERE x.extname = 'pg_cron') THEN
    RAISE NOTICE 'queue_hold_v2: pg_cron is installed; the optional schedule in the header may be used';
  ELSE
    RAISE NOTICE 'queue_hold_v2: pg_cron is not installed; the app calls queue_expire_holds() (header V5)';
  END IF;
END
$$;

-- ------------------------------------------
-- 2. The hold limit: 30 minutes (one place, A)
-- ------------------------------------------
CREATE OR REPLACE FUNCTION private.queue_hold_limit()
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT interval '30 minutes'
$function$;

REVOKE ALL ON FUNCTION private.queue_hold_limit() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------
-- 3. The state CHECK: a never-called No-show may have no handler (V1)
-- ------------------------------------------
ALTER TABLE public.queue_tickets DROP CONSTRAINT IF EXISTS ck_queue_tickets_state;
ALTER TABLE public.queue_tickets ADD CONSTRAINT ck_queue_tickets_state CHECK (
    (status IN ('Waiting', 'Held') AND called_at IS NULL AND finished_at IS NULL AND handled_by IS NULL)
    OR (status = 'Serving' AND called_at IS NOT NULL AND finished_at IS NULL AND handled_by IS NOT NULL)
    OR (status IN ('Done', 'No-show') AND called_at IS NOT NULL AND finished_at IS NOT NULL AND handled_by IS NOT NULL)
    OR (status = 'No-show' AND called_at IS NULL AND finished_at IS NOT NULL AND window_label IS NULL)
    OR (status = 'Cancelled' AND called_at IS NULL AND finished_at IS NOT NULL));

-- ------------------------------------------
-- 4. The status-flow trigger function (queue_hold.sql, with V2 for Held -> No-show)
-- ------------------------------------------
CREATE OR REPLACE FUNCTION private.require_queue_ticket_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $function$
-- queue_hold_v2: Held -> No-show keeps the handled_by the statement sends (NULL = closed
-- automatically after the hold ran out).
DECLARE
  v_uid     uuid := auth.uid();
  v_old     text;
  v_new     text;
  v_step    text;
  v_expired boolean;
BEGIN
  IF TG_OP <> 'UPDATE' OR TG_WHEN <> 'BEFORE' OR TG_LEVEL <> 'ROW'
     OR TG_TABLE_SCHEMA <> 'public' OR TG_TABLE_NAME <> 'queue_tickets' THEN
    RAISE EXCEPTION 'private.require_queue_ticket_rules must be a BEFORE UPDATE FOR EACH ROW trigger on public.queue_tickets';
  END IF;

  v_old := OLD.status;
  v_new := NEW.status;

  -- What the ticket is never changes.
  IF NEW.ticket_id IS DISTINCT FROM OLD.ticket_id
     OR NEW.student_id IS DISTINCT FROM OLD.student_id
     OR NEW.service_id IS DISTINCT FROM OLD.service_id
     OR NEW.queue_date IS DISTINCT FROM OLD.queue_date
     OR NEW.ticket_number IS DISTINCT FROM OLD.ticket_number
     OR NEW.ticket_code IS DISTINCT FROM OLD.ticket_code
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'bad ticket change: the student, service, date, number, code and creation time of ticket % cannot be changed', OLD.ticket_id
      USING ERRCODE = 'P0001';
  END IF;

  -- Final states: nothing changes any more.
  IF v_old IN ('Done', 'No-show', 'Cancelled') THEN
    IF pg_catalog.to_jsonb(NEW) IS DISTINCT FROM pg_catalog.to_jsonb(OLD) THEN
      RAISE EXCEPTION 'bad ticket change: ticket % is % (final) and cannot be changed', OLD.ticket_id, v_old
        USING ERRCODE = 'P0001',
              HINT = 'Done, No-show and Cancelled are final. The student gets a new ticket instead.';
    END IF;
    RETURN NEW;
  END IF;

  -- One step of the flow.
  IF v_new IS DISTINCT FROM v_old THEN
    v_step := COALESCE(v_old, 'NULL') || ' -> ' || COALESCE(v_new, 'NULL');
    IF v_step NOT IN ('Waiting -> Serving', 'Waiting -> Cancelled', 'Waiting -> Held',
                      'Held -> Waiting', 'Held -> Cancelled', 'Held -> No-show',
                      'Serving -> Done', 'Serving -> No-show') THEN
      RAISE EXCEPTION 'bad ticket change: % is not allowed (ticket %)', v_step, OLD.ticket_id
        USING ERRCODE = 'P0001',
              HINT = 'Allowed: Waiting -> Serving, Held or Cancelled; Held -> Waiting, Cancelled or No-show; Serving -> Done or No-show.';
    END IF;
  END IF;

  IF v_old = 'Waiting' AND v_new = 'Serving' THEN
    -- The call: who calls it and at which window; the time is the database's.
    IF v_uid IS NOT NULL THEN
      NEW.handled_by := v_uid;
    END IF;
    NEW.window_label := NULLIF(pg_catalog.btrim(NEW.window_label), '');
    NEW.called_at := pg_catalog.now();
    NEW.finished_at := NULL;
  ELSIF v_old = 'Held' AND v_new = 'No-show' THEN
    -- A held ticket closed as No-show (V2): never called, no window. Expired = the same
    -- comparison as queue_unhold_my_ticket. handled_by is the statement's: queue_finish sends
    -- the Registrar, queue_expire_holds sends NULL.
    v_expired := pg_catalog.now() > OLD.held_at + private.queue_hold_limit();
    IF NOT v_expired AND v_uid IS NOT NULL THEN
      RAISE EXCEPTION 'hold active: ticket % is still on hold; it can be marked No-show only after the hold runs out', '#' || OLD.ticket_code::text
        USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_expired AND NEW.handled_by IS NULL THEN
      RAISE EXCEPTION 'bad ticket change: ticket % is still on hold; only an expired hold is closed without a handler', OLD.ticket_id
        USING ERRCODE = 'P0001';
    END IF;
    IF v_uid IS NOT NULL AND NEW.handled_by IS NOT NULL AND NEW.handled_by IS DISTINCT FROM v_uid THEN
      RAISE EXCEPTION 'bad ticket change: handled_by of ticket % must be the signed-in caller or empty', OLD.ticket_id
        USING ERRCODE = 'P0001';
    END IF;
    IF NEW.window_label IS DISTINCT FROM OLD.window_label THEN
      RAISE EXCEPTION 'bad ticket change: window_label of ticket % is set only when it is called', OLD.ticket_id
        USING ERRCODE = 'P0001';
    END IF;
    NEW.called_at := OLD.called_at;
    NEW.finished_at := pg_catalog.now();
  ELSE
    IF NEW.handled_by IS DISTINCT FROM OLD.handled_by
       OR NEW.window_label IS DISTINCT FROM OLD.window_label THEN
      RAISE EXCEPTION 'bad ticket change: handled_by and window_label of ticket % are set only when it is called', OLD.ticket_id
        USING ERRCODE = 'P0001';
    END IF;
    NEW.called_at := OLD.called_at;
    IF v_new IS DISTINCT FROM v_old AND v_new IN ('Done', 'No-show', 'Cancelled') THEN
      NEW.finished_at := pg_catalog.now();
    ELSE
      NEW.finished_at := OLD.finished_at;   -- Waiting <-> Held, or no status change
    END IF;
  END IF;

  -- held_at belongs to the database (queue_hold.sql H3).
  IF v_new = 'Held' THEN
    IF v_old = 'Held' THEN
      NEW.held_at := OLD.held_at;
    ELSE
      NEW.held_at := pg_catalog.now();
    END IF;
  ELSE
    NEW.held_at := NULL;
  END IF;

  RETURN NEW;
END
$function$;

-- Same grant style as the other trigger functions (hardening2.sql section C).
REVOKE EXECUTE ON FUNCTION private.require_queue_ticket_rules() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.require_queue_ticket_rules() TO authenticated;

-- ------------------------------------------
-- 5. queue_finish (B) and queue_expire_holds (C)
-- ------------------------------------------

-- Registrar: finish a Serving ticket as Done or No-show, or mark a Held ticket No-show once
-- its hold ran out (queue_hold_v2 B).
CREATE OR REPLACE FUNCTION public.queue_finish(p_ticket_id bigint, p_outcome text)
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid    uuid;
  v_status text;
  v_held   timestamp with time zone;
  v_code   integer;
BEGIN
  v_uid := private.queue_require_role('Registrar');

  IF p_outcome IS NULL OR p_outcome NOT IN ('Done', 'No-show') THEN
    RAISE EXCEPTION 'invalid ticket request: the outcome must be Done or No-show, not [%]', COALESCE(pg_catalog.left(p_outcome, 40), 'NULL')
      USING ERRCODE = '22023';
  END IF;

  SELECT t.status, t.held_at, t.ticket_code INTO v_status, v_held, v_code
  FROM public.queue_tickets t
  WHERE t.ticket_id = p_ticket_id
  FOR UPDATE OF t;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'bad ticket change: ticket % does not exist', COALESCE(p_ticket_id::text, 'NULL')
      USING ERRCODE = 'P0001';
  END IF;

  IF v_status = 'Held' THEN
    IF p_outcome <> 'No-show' THEN
      RAISE EXCEPTION 'bad ticket change: ticket % is on hold; it can only be marked No-show', p_ticket_id
        USING ERRCODE = 'P0001';
    END IF;
    IF pg_catalog.now() <= v_held + private.queue_hold_limit() THEN
      RAISE EXCEPTION 'hold active: ticket % is on hold until % (Manila time); it can be marked No-show only after the hold runs out',
                      private.queue_label(v_code),
                      pg_catalog.to_char((v_held + private.queue_hold_limit()) AT TIME ZONE 'Asia/Manila', 'HH24:MI')
        USING ERRCODE = 'P0001',
              HINT = 'Wait until the hold runs out; the ticket is then closed automatically.';
    END IF;
    -- The handler is the Registrar (V2); finished_at is set and held_at cleared by the trigger.
    UPDATE public.queue_tickets AS t SET status = 'No-show', handled_by = v_uid WHERE t.ticket_id = p_ticket_id;
    RETURN;
  ELSIF v_status <> 'Serving' THEN
    RAISE EXCEPTION 'bad ticket change: ticket % is %; only a Serving ticket can be finished', p_ticket_id, v_status
      USING ERRCODE = 'P0001';
  END IF;

  -- finished_at is set by the trigger.
  UPDATE public.queue_tickets AS t SET status = p_outcome WHERE t.ticket_id = p_ticket_id;
END
$function$;

-- Anyone signed in (and the server role, and the owner): close every hold that ran out
-- (Held -> No-show, no handler). Returns how many were closed now (V3).
CREATE OR REPLACE FUNCTION public.queue_expire_holds()
 RETURNS integer
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_n integer;
BEGIN
  -- Rows another transaction holds (unhold, cancel, finish, a parallel call) are skipped; a
  -- later call closes them if they are still expired holds then.
  WITH due AS (
    SELECT t.ticket_id
    FROM public.queue_tickets t
    WHERE t.status = 'Held' AND pg_catalog.now() > t.held_at + private.queue_hold_limit()
    ORDER BY t.ticket_id
    FOR UPDATE OF t SKIP LOCKED
  )
  UPDATE public.queue_tickets AS t
  SET status = 'No-show', handled_by = NULL
  FROM due
  WHERE t.ticket_id = due.ticket_id AND t.status = 'Held';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$function$;

REVOKE ALL ON FUNCTION public.queue_finish(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_finish(bigint, text) TO authenticated;
REVOKE ALL ON FUNCTION public.queue_expire_holds() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_expire_holds() TO authenticated;
DO $$
BEGIN
  EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION public.queue_expire_holds() TO %I', 'service' || '_role');
END
$$;

-- ------------------------------------------
-- 6. The queue notifications: plus queue_hold_expired (D, V4)
-- ------------------------------------------
-- queue_tickets: queue_ticket, queue_turn, queue_skipped (notifications_rules.sql decision 6),
-- queue_hold_expired (queue_hold_v2).
CREATE OR REPLACE FUNCTION private.notify_on_queue_tickets()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- queue_hold_v2: Held -> No-show after the hold ran out sends queue_hold_expired.
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
              OR (OLD.status = 'Serving' AND NEW.status = 'No-show')
              OR (OLD.status = 'Held' AND NEW.status = 'No-show'
                  AND pg_catalog.now() > OLD.held_at + private.queue_hold_limit())) THEN
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
    ELSIF OLD.status = 'Held' THEN
      PERFORM private.notify(NEW.student_id, 'queue_hold_expired', 'Your hold ran out',
        'Ticket ' || v_label || ' was closed because your hold lasted over '
          || ((EXTRACT(EPOCH FROM private.queue_hold_limit()) / 60)::integer)::text
          || ' minutes. Show your QR code again at the Registrar to get a new number.',
        v_link);
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

-- Same grant style as the other trigger functions (hardening2.sql section C).
REVOKE EXECUTE ON FUNCTION private.notify_on_queue_tickets() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.notify_on_queue_tickets() TO authenticated;

-- ------------------------------------------
-- 7. enrollment_items: the Registrar's own DELETE (E, V6)
-- ------------------------------------------
DROP POLICY IF EXISTS enrollment_items_registrar_delete ON public.enrollment_items;
CREATE POLICY enrollment_items_registrar_delete ON public.enrollment_items
  AS PERMISSIVE
  FOR DELETE TO authenticated
  USING ((( SELECT private.current_role_name() AS current_role_name) = 'Registrar'::text));

-- Already granted by enrollment_rules.sql section 6 (a no-op then); DELETE needs no column list.
GRANT DELETE ON public.enrollment_items TO authenticated;

-- ------------------------------------------
-- 8. Checks after the change (any failure rolls back the whole file)
-- ------------------------------------------
DO $$
DECLARE
  v_bad text;
  v_srv text := 'service' || '_role';
  v_fn  regprocedure := pg_catalog.to_regprocedure('public.queue_expire_holds()');
BEGIN
  -- a) The limit is 30 minutes and the helper is still locked down.
  IF private.queue_hold_limit() <> interval '30 minutes'
     OR pg_catalog.has_function_privilege('authenticated', 'private.queue_hold_limit()', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'private.queue_hold_limit()', 'EXECUTE') THEN
    RAISE EXCEPTION 'queue_hold_v2: private.queue_hold_limit() not as intended; rolled back';
  END IF;

  -- b) queue_finish and queue_expire_holds: SECURITY DEFINER, empty search_path, owned by the
  --    running role, no PUBLIC, anon cannot execute, authenticated can; the expiry function
  --    also for the server role, no arguments, returns integer.
  SELECT string_agg(p.oid::pg_catalog.regprocedure::text, ', ') INTO v_bad
  FROM pg_catalog.pg_proc p
  WHERE p.oid IN (pg_catalog.to_regprocedure('public.queue_finish(bigint, text)'), v_fn)
    AND NOT (p.prosecdef
             AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
             AND p.proowner = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
             AND p.proacl IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.grantee = 0)
             AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
             AND pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  IF v_bad IS NOT NULL OR v_fn IS NULL
     OR NOT pg_catalog.has_function_privilege(v_srv, v_fn, 'EXECUTE')
     OR (SELECT p.prorettype FROM pg_catalog.pg_proc p WHERE p.oid = v_fn) <> 'integer'::pg_catalog.regtype
     OR (SELECT p.pronargs FROM pg_catalog.pg_proc p WHERE p.oid = v_fn) <> 0 THEN
    RAISE EXCEPTION 'queue_hold_v2: queue_finish / queue_expire_holds properties or grants not as intended (%); rolled back', COALESCE(v_bad, 'queue_expire_holds');
  END IF;

  -- c) The trigger functions: the status rule is SECURITY INVOKER, the notification one
  --    SECURITY DEFINER with the new kind; neither executable by anon.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                 WHERE p.oid = 'private.require_queue_ticket_rules()'::pg_catalog.regprocedure
                   AND NOT p.prosecdef AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
                   AND pg_catalog.strpos(p.prosrc, 'queue_hold_v2') > 0
                   AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE'))
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                    WHERE p.oid = 'private.notify_on_queue_tickets()'::pg_catalog.regprocedure
                      AND p.prosecdef AND p.proconfig && ARRAY['search_path=""', 'search_path=''''']
                      AND pg_catalog.strpos(p.prosrc, '''queue_hold_expired''') > 0
                      AND NOT pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')) THEN
    RAISE EXCEPTION 'queue_hold_v2: the trigger functions are not as intended; rolled back';
  END IF;

  -- d) Triggers on queue_tickets unchanged.
  SELECT string_agg(t.tgname || ' ' || t.tgtype || ' ' || t.tgenabled::text, ', ' ORDER BY t.tgname) INTO v_bad
  FROM pg_catalog.pg_trigger t
  WHERE t.tgrelid = 'public.queue_tickets'::pg_catalog.regclass AND NOT t.tgisinternal;
  IF v_bad IS DISTINCT FROM 'audit_log 29 O, require_queue_ticket_rules 19 O, trg_notify_queue_tickets 21 O' THEN
    RAISE EXCEPTION 'queue_hold_v2: triggers on queue_tickets not as intended ([%]); rolled back', v_bad;
  END IF;

  -- e) The CHECKs are there and validated.
  IF (SELECT pg_catalog.count(*) FROM pg_catalog.pg_constraint k
       WHERE k.conrelid = 'public.queue_tickets'::pg_catalog.regclass AND k.contype = 'c' AND k.convalidated
         AND k.conname IN ('ck_queue_tickets_status', 'ck_queue_tickets_state', 'ck_queue_tickets_held')) <> 3 THEN
    RAISE EXCEPTION 'queue_hold_v2: the CHECK constraints on queue_tickets are not as intended; rolled back';
  END IF;

  -- f) Table privileges on queue_tickets unchanged: anon nothing; authenticated SELECT only.
  IF pg_catalog.has_table_privilege('anon', 'public.queue_tickets', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR NOT pg_catalog.has_table_privilege('authenticated', 'public.queue_tickets', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.queue_tickets', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
     OR pg_catalog.has_any_column_privilege('authenticated', 'public.queue_tickets', 'INSERT, UPDATE, REFERENCES') THEN
    RAISE EXCEPTION 'queue_hold_v2: privileges on public.queue_tickets not as intended; rolled back';
  END IF;

  -- g) enrollment_items: the new policy as intended, the student's still there, DELETE
  --    granted to authenticated, nothing for anon.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
                 WHERE p.schemaname = 'public' AND p.tablename = 'enrollment_items'
                   AND p.policyname = 'enrollment_items_registrar_delete' AND p.cmd = 'DELETE'
                   AND p.permissive = 'PERMISSIVE' AND p.roles = ARRAY['authenticated']::name[]
                   AND p.with_check IS NULL
                   AND pg_catalog.strpos(COALESCE(p.qual, ''), 'current_role_name') > 0
                   AND pg_catalog.strpos(COALESCE(p.qual, ''), '''Registrar''') > 0)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
                    WHERE p.schemaname = 'public' AND p.tablename = 'enrollment_items'
                      AND p.policyname = 'enrollment_items_student_remove' AND p.cmd = 'DELETE')
     OR NOT pg_catalog.has_table_privilege('authenticated', 'public.enrollment_items', 'DELETE')
     OR pg_catalog.has_table_privilege('anon', 'public.enrollment_items', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN') THEN
    RAISE EXCEPTION 'queue_hold_v2: enrollment_items policy or grants not as intended; rolled back';
  END IF;
END
$$;

-- One result row (all true). The DO block above already stopped on any failure.
SELECT
  (private.queue_hold_limit() = interval '30 minutes') AS limit_30,
  pg_catalog.has_function_privilege('authenticated', 'public.queue_expire_holds()', 'EXECUTE') AS expire_authenticated,
  NOT pg_catalog.has_function_privilege('anon', 'public.queue_expire_holds()', 'EXECUTE') AS expire_not_anon,
  pg_catalog.has_function_privilege('service' || '_role', 'public.queue_expire_holds()', 'EXECUTE') AS expire_server,
  EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = 'enrollment_items'
             AND p.policyname = 'enrollment_items_registrar_delete') AS registrar_delete_policy;

-- Ask PostgREST to reload its schema cache (sent when the transaction commits).
NOTIFY pgrst, 'reload schema';

COMMIT;
