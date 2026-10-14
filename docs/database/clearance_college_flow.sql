-- ==========================================
-- CLEARANCE FLOW: CASHIER -> OWN COLLEGE -> REGISTRAR, AND AUTOMATIC RECEIPT NUMBERS
-- (feature/clearance-college-flow)
-- ==========================================
-- PM decisions: (1) a student's clearance has only TWO items: the Cashier's Office (Financial) and the
-- college that owns the student's program (a BSCS or BSIT student: CCS only). The other colleges are no
-- longer asked. The Registrar's final approval stays as it is (it needs every item cleared). (2) The
-- Cashier no longer types the receipt number: the database numbers each payment, "OR-2026-000001".
-- Runs AFTER hardening2.sql, trigger_finance_autoclear.sql, trigger_final_clearance.sql and
-- grants_clearance.sql (all live). Independent of every other pending file.
--
-- WHAT IT DOES (one transaction, a single DO block)
--   1. private.create_clearance_items() (SECURITY DEFINER, search_path '') now inserts one item for each
--      Financial department plus the department of the student's program, instead of one per department.
--   2. Clean-up of clearances that already exist: items that are still PENDING (cleared_at IS NULL) and
--      belong to neither the Financial office nor the student's own college are deleted. Cleared items
--      and their history stay. Their audit rows stay too (the audit log is append-only).
--   3. public.payment_receipt_seq (USAGE for authenticated only) and a DEFAULT on payments.receipt_number:
--      'OR-' || year || '-' || lpad(nextval, 6, '0'), the same pattern as document tickets. The sequence
--      starts after the highest number already used in that format. The UNIQUE constraint stays.
--      The app stops sending receipt_number; the INSERT column grant stays (an owner can still set one).
--
-- HOW TO RUN: first clearance_college_flow_rehearsal.sql (same block with v_dry := true; it ends with
-- RAISE EXCEPTION 'REHEARSAL OK ...' which rolls everything back and shows the numbers), then this file.
-- Deploy the app change AFTER this file is live (the app then sends no receipt number).
--
-- UNDO: restore the old function body (INSERT ... SELECT NEW.clearance_id, d.department_id FROM
-- public.departments d), ALTER TABLE public.payments ALTER COLUMN receipt_number DROP DEFAULT, DROP
-- SEQUENCE public.payment_receipt_seq. Deleted pending items can be re-added by hand.
-- ==========================================

DO $x$
DECLARE
  v_dry boolean := false;
  v_max bigint;
  v_deleted bigint;
  v_def text;
  v_bad bigint;
  v_summary text;
BEGIN
  -- Safety checks
  IF to_regclass('public.clearance_items') IS NULL OR to_regclass('public.payments') IS NULL
     OR to_regprocedure('private.create_clearance_items()') IS NULL THEN
    RAISE EXCEPTION 'clearance_college_flow: expected objects are missing; stop';
  END IF;
  IF to_regclass('public.payment_receipt_seq') IS NOT NULL THEN
    RAISE EXCEPTION 'clearance_college_flow: payment_receipt_seq already exists; this file was run before; stop';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.departments WHERE department_type = 'Financial') THEN
    RAISE EXCEPTION 'clearance_college_flow: there is no Financial department; stop';
  END IF;

  -- 1. The new item creation
  CREATE OR REPLACE FUNCTION private.create_clearance_items()
   RETURNS trigger
   LANGUAGE plpgsql
   SECURITY DEFINER
   SET search_path TO ''
  AS $function$
  BEGIN
    INSERT INTO public.clearance_items (clearance_id, department_id)
    SELECT NEW.clearance_id, d.department_id
    FROM public.departments d
    WHERE d.department_type = 'Financial'
       OR d.department_id = (SELECT p.department_id
                             FROM public.students s
                             JOIN public.programs p ON p.program_id = s.program_id
                             WHERE s.student_id = NEW.student_id);
    RETURN NEW;
  END $function$;

  -- 2. Clean-up of pending items that no longer apply
  DELETE FROM public.clearance_items ci
  USING public.clearances c, public.departments d
  WHERE c.clearance_id = ci.clearance_id
    AND d.department_id = ci.department_id
    AND ci.cleared_at IS NULL
    AND d.department_type <> 'Financial'
    AND d.department_id IS DISTINCT FROM (SELECT p.department_id
                                          FROM public.students s
                                          JOIN public.programs p ON p.program_id = s.program_id
                                          WHERE s.student_id = c.student_id);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  -- 3. Automatic receipt numbers
  SELECT COALESCE(MAX(substring(receipt_number FROM 9)::bigint), 0) INTO v_max
  FROM public.payments WHERE receipt_number ~ '^OR-[0-9]{4}-[0-9]{6}$';
  CREATE SEQUENCE public.payment_receipt_seq;
  PERFORM pg_catalog.setval('public.payment_receipt_seq', v_max + 1, false);
  REVOKE ALL ON SEQUENCE public.payment_receipt_seq FROM PUBLIC, anon, authenticated;
  GRANT USAGE ON SEQUENCE public.payment_receipt_seq TO authenticated;
  ALTER TABLE public.payments ALTER COLUMN receipt_number SET DEFAULT
    ((('OR-'::text || to_char(now(), 'YYYY'::text)) || '-'::text)
     || lpad((nextval('public.payment_receipt_seq'::regclass))::text, 6, '0'::text));

  -- Checks
  SELECT pg_catalog.pg_get_functiondef('private.create_clearance_items()'::regprocedure) INTO v_def;
  IF position('Financial' IN v_def) = 0 OR position('program_id' IN v_def) = 0 THEN
    RAISE EXCEPTION 'clearance_college_flow: function body not as expected; rolled back';
  END IF;
  IF NOT pg_catalog.has_sequence_privilege('authenticated', 'public.payment_receipt_seq', 'USAGE')
     OR pg_catalog.has_sequence_privilege('authenticated', 'public.payment_receipt_seq', 'SELECT, UPDATE')
     OR pg_catalog.has_sequence_privilege('anon', 'public.payment_receipt_seq', 'USAGE, SELECT, UPDATE') THEN
    RAISE EXCEPTION 'clearance_college_flow: sequence privileges wrong; rolled back';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attrdef ad
                 WHERE ad.adrelid = 'public.payments'::regclass
                   AND ad.adnum = (SELECT attnum FROM pg_catalog.pg_attribute
                                   WHERE attrelid = 'public.payments'::regclass AND attname = 'receipt_number')) THEN
    RAISE EXCEPTION 'clearance_college_flow: receipt default missing; rolled back';
  END IF;
  SELECT count(*) INTO v_bad FROM public.clearance_items ci
  JOIN public.clearances c ON c.clearance_id = ci.clearance_id
  JOIN public.departments d ON d.department_id = ci.department_id
  WHERE ci.cleared_at IS NULL AND d.department_type <> 'Financial'
    AND d.department_id IS DISTINCT FROM (SELECT p.department_id FROM public.students s
                                          JOIN public.programs p ON p.program_id = s.program_id
                                          WHERE s.student_id = c.student_id);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'clearance_college_flow: % stray pending items remain; rolled back', v_bad;
  END IF;

  SELECT format('pending items deleted=%s, clearances=%s, items now=%s, receipts so far=%s, next receipt number starts at %s',
                v_deleted,
                (SELECT count(*) FROM public.clearances),
                (SELECT count(*) FROM public.clearance_items),
                (SELECT count(*) FROM public.payments),
                v_max + 1)
    INTO v_summary;

  IF v_dry THEN
    RAISE EXCEPTION 'REHEARSAL OK (rolled back): %', v_summary;
  END IF;
  RAISE NOTICE 'clearance_college_flow applied: %', v_summary;
END $x$;

SELECT 'live' AS mode,
       (SELECT count(*) FROM public.clearance_items) AS items,
       (SELECT count(*) FROM public.clearances) AS clearances,
       (SELECT last_value FROM public.payment_receipt_seq) AS receipt_seq_at;
