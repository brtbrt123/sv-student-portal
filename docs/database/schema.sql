-- ==========================================
-- SCHEMA (PostgreSQL / Supabase) - the first 23 tables, 3NF (6 more come from the rule files, see README.md)
-- ==========================================
-- Tables are listed in dependency order, so this file can be run as is in the
-- Supabase SQL Editor. profiles.profile_id references auth.users(id), which
-- Supabase Auth provides.
-- NOTE: the 4 views (v_active_holds, v_clearance_items, v_clearances, v_grades)
-- are in views.sql (run after this file). See docs/database/README.md.

CREATE SEQUENCE IF NOT EXISTS public.document_ticket_seq;

CREATE TABLE public.departments (
  department_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  code character varying NOT NULL UNIQUE,
  name character varying NOT NULL UNIQUE,
  department_type character varying NOT NULL DEFAULT 'Academic'::character varying CHECK (department_type::text = ANY (ARRAY['Academic'::character varying, 'Financial'::character varying]::text[])),
  CONSTRAINT departments_pkey PRIMARY KEY (department_id)
);
CREATE TABLE public.document_types (
  document_type_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  name character varying NOT NULL UNIQUE,
  CONSTRAINT document_types_pkey PRIMARY KEY (document_type_id)
);
CREATE TABLE public.fee_types (
  fee_type_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  name character varying NOT NULL UNIQUE,
  CONSTRAINT fee_types_pkey PRIMARY KEY (fee_type_id)
);
CREATE TABLE public.grade_scale (
  grade_code character varying NOT NULL,
  numeric_value numeric,
  is_passing boolean NOT NULL,
  description character varying NOT NULL,
  CONSTRAINT grade_scale_pkey PRIMARY KEY (grade_code)
);
CREATE TABLE public.login_attempts (
  attempt_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  email character varying NOT NULL,
  ip_address inet,
  was_successful boolean NOT NULL,
  attempted_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT login_attempts_pkey PRIMARY KEY (attempt_id)
);
CREATE TABLE public.roles (
  role_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  role_name character varying NOT NULL UNIQUE,
  CONSTRAINT roles_pkey PRIMARY KEY (role_id)
);
CREATE TABLE public.terms (
  term_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  school_year character varying NOT NULL CHECK (school_year::text ~ '^[0-9]{4}-[0-9]{4}$'::text),
  semester character varying NOT NULL CHECK (semester::text = ANY (ARRAY['1st'::character varying, '2nd'::character varying, 'Summer'::character varying]::text[])),
  start_date date NOT NULL,
  end_date date NOT NULL,
  is_current boolean NOT NULL DEFAULT false,
  CONSTRAINT terms_pkey PRIMARY KEY (term_id)
);
CREATE TABLE public.profiles (
  profile_id uuid NOT NULL,
  role_id smallint NOT NULL,
  first_name character varying NOT NULL,
  last_name character varying NOT NULL,
  email character varying NOT NULL UNIQUE,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT profiles_pkey PRIMARY KEY (profile_id),
  CONSTRAINT fk_profiles_profile_id FOREIGN KEY (profile_id) REFERENCES auth.users(id),
  CONSTRAINT fk_profiles_role_id FOREIGN KEY (role_id) REFERENCES public.roles(role_id)
);
CREATE TABLE public.programs (
  program_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  department_id bigint NOT NULL,
  code character varying NOT NULL UNIQUE,
  name character varying NOT NULL,
  CONSTRAINT programs_pkey PRIMARY KEY (program_id),
  CONSTRAINT fk_programs_department_id FOREIGN KEY (department_id) REFERENCES public.departments(department_id)
);
CREATE TABLE public.subjects (
  subject_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  department_id bigint NOT NULL,
  code character varying NOT NULL UNIQUE,
  title character varying NOT NULL,
  units smallint NOT NULL CHECK (units >= 0 AND units <= 6),
  CONSTRAINT subjects_pkey PRIMARY KEY (subject_id),
  CONSTRAINT fk_subjects_department_id FOREIGN KEY (department_id) REFERENCES public.departments(department_id)
);
CREATE TABLE public.audit_logs (
  log_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  actor_id uuid,
  action character varying NOT NULL CHECK (action::text = ANY (ARRAY['INSERT'::character varying, 'UPDATE'::character varying, 'DELETE'::character varying]::text[])),
  table_name character varying NOT NULL,
  record_id character varying NOT NULL,
  old_data jsonb,
  new_data jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT audit_logs_pkey PRIMARY KEY (log_id),
  CONSTRAINT fk_audit_logs_actor_id FOREIGN KEY (actor_id) REFERENCES public.profiles(profile_id)
);
CREATE TABLE public.department_staff (
  profile_id uuid NOT NULL,
  department_id bigint NOT NULL,
  CONSTRAINT department_staff_pkey PRIMARY KEY (profile_id),
  CONSTRAINT fk_department_staff_profile_id FOREIGN KEY (profile_id) REFERENCES public.profiles(profile_id),
  CONSTRAINT fk_department_staff_department_id FOREIGN KEY (department_id) REFERENCES public.departments(department_id)
);
CREATE TABLE public.sections (
  section_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  subject_id bigint NOT NULL,
  term_id bigint NOT NULL,
  section_code character varying NOT NULL,
  schedule character varying,
  capacity smallint NOT NULL CHECK (capacity > 0),
  CONSTRAINT sections_pkey PRIMARY KEY (section_id),
  CONSTRAINT fk_sections_subject_id FOREIGN KEY (subject_id) REFERENCES public.subjects(subject_id),
  CONSTRAINT fk_sections_term_id FOREIGN KEY (term_id) REFERENCES public.terms(term_id)
);
CREATE TABLE public.students (
  student_id uuid NOT NULL,
  student_number character varying NOT NULL UNIQUE,
  program_id bigint NOT NULL,
  CONSTRAINT students_pkey PRIMARY KEY (student_id),
  CONSTRAINT fk_students_student_id FOREIGN KEY (student_id) REFERENCES public.profiles(profile_id),
  CONSTRAINT fk_students_program_id FOREIGN KEY (program_id) REFERENCES public.programs(program_id)
);
CREATE TABLE public.academic_holds (
  hold_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  student_id uuid NOT NULL,
  department_id bigint NOT NULL,
  reason character varying NOT NULL,
  placed_by uuid NOT NULL,
  placed_at timestamp with time zone NOT NULL DEFAULT now(),
  lifted_by uuid,
  lifted_at timestamp with time zone,
  CONSTRAINT academic_holds_pkey PRIMARY KEY (hold_id),
  CONSTRAINT fk_academic_holds_student_id FOREIGN KEY (student_id) REFERENCES public.students(student_id),
  CONSTRAINT fk_academic_holds_department_id FOREIGN KEY (department_id) REFERENCES public.departments(department_id),
  CONSTRAINT fk_academic_holds_placed_by FOREIGN KEY (placed_by) REFERENCES public.profiles(profile_id),
  CONSTRAINT fk_academic_holds_lifted_by FOREIGN KEY (lifted_by) REFERENCES public.profiles(profile_id)
);
CREATE TABLE public.charges (
  charge_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  student_id uuid NOT NULL,
  term_id bigint NOT NULL,
  fee_type_id bigint NOT NULL,
  amount numeric NOT NULL CHECK (amount > 0::numeric),
  due_date date,
  status character varying NOT NULL DEFAULT 'Unpaid'::character varying CHECK (status::text = ANY (ARRAY['Unpaid'::character varying, 'Cleared'::character varying, 'Waived'::character varying]::text[])),
  CONSTRAINT charges_pkey PRIMARY KEY (charge_id),
  CONSTRAINT fk_charges_student_id FOREIGN KEY (student_id) REFERENCES public.students(student_id),
  CONSTRAINT fk_charges_term_id FOREIGN KEY (term_id) REFERENCES public.terms(term_id),
  CONSTRAINT fk_charges_fee_type_id FOREIGN KEY (fee_type_id) REFERENCES public.fee_types(fee_type_id)
);
CREATE TABLE public.clearances (
  clearance_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  student_id uuid NOT NULL,
  term_id bigint NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  approved_by uuid,
  approved_at timestamp with time zone,
  CONSTRAINT clearances_pkey PRIMARY KEY (clearance_id),
  CONSTRAINT fk_clearances_student_id FOREIGN KEY (student_id) REFERENCES public.students(student_id),
  CONSTRAINT fk_clearances_term_id FOREIGN KEY (term_id) REFERENCES public.terms(term_id),
  CONSTRAINT fk_clearances_approved_by FOREIGN KEY (approved_by) REFERENCES public.profiles(profile_id)
);
CREATE TABLE public.document_requests (
  request_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  ticket_number character varying NOT NULL DEFAULT ((('DR-'::text || to_char(now(), 'YYYY'::text)) || '-'::text) || lpad((nextval('document_ticket_seq'::regclass))::text, 6, '0'::text)) UNIQUE,
  student_id uuid NOT NULL,
  document_type_id bigint NOT NULL,
  purpose character varying NOT NULL,
  copies smallint NOT NULL DEFAULT 1 CHECK (copies >= 1 AND copies <= 10),
  status character varying NOT NULL DEFAULT 'Pending'::character varying CHECK (status::text = ANY (ARRAY['Pending'::character varying, 'Processing'::character varying, 'Ready'::character varying, 'Released'::character varying, 'Rejected'::character varying]::text[])),
  requested_at timestamp with time zone NOT NULL DEFAULT now(),
  processed_by uuid,
  processed_at timestamp with time zone,
  remarks character varying,
  CONSTRAINT document_requests_pkey PRIMARY KEY (request_id),
  CONSTRAINT fk_document_requests_student_id FOREIGN KEY (student_id) REFERENCES public.students(student_id),
  CONSTRAINT fk_document_requests_document_type_id FOREIGN KEY (document_type_id) REFERENCES public.document_types(document_type_id),
  CONSTRAINT fk_document_requests_processed_by FOREIGN KEY (processed_by) REFERENCES public.profiles(profile_id)
);
CREATE TABLE public.enrollments (
  enrollment_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  student_id uuid NOT NULL,
  term_id bigint NOT NULL,
  year_level smallint NOT NULL CHECK (year_level >= 1 AND year_level <= 6),
  status character varying NOT NULL DEFAULT 'Pending'::character varying CHECK (status::text = ANY (ARRAY['Pending'::character varying, 'Approved'::character varying, 'Rejected'::character varying]::text[])),
  submitted_at timestamp with time zone NOT NULL DEFAULT now(),
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  remarks character varying,
  CONSTRAINT enrollments_pkey PRIMARY KEY (enrollment_id),
  CONSTRAINT fk_enrollments_student_id FOREIGN KEY (student_id) REFERENCES public.students(student_id),
  CONSTRAINT fk_enrollments_term_id FOREIGN KEY (term_id) REFERENCES public.terms(term_id),
  CONSTRAINT fk_enrollments_reviewed_by FOREIGN KEY (reviewed_by) REFERENCES public.profiles(profile_id)
);
CREATE TABLE public.clearance_items (
  clearance_item_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  clearance_id bigint NOT NULL,
  department_id bigint NOT NULL,
  cleared_at timestamp with time zone,
  cleared_by uuid,
  remarks character varying,
  CONSTRAINT clearance_items_pkey PRIMARY KEY (clearance_item_id),
  CONSTRAINT fk_clearance_items_clearance_id FOREIGN KEY (clearance_id) REFERENCES public.clearances(clearance_id),
  CONSTRAINT fk_clearance_items_department_id FOREIGN KEY (department_id) REFERENCES public.departments(department_id),
  CONSTRAINT fk_clearance_items_cleared_by FOREIGN KEY (cleared_by) REFERENCES public.profiles(profile_id)
);
CREATE TABLE public.enrollment_items (
  enrollment_item_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  enrollment_id bigint NOT NULL,
  section_id bigint NOT NULL,
  CONSTRAINT enrollment_items_pkey PRIMARY KEY (enrollment_item_id),
  CONSTRAINT fk_enrollment_items_enrollment_id FOREIGN KEY (enrollment_id) REFERENCES public.enrollments(enrollment_id),
  CONSTRAINT fk_enrollment_items_section_id FOREIGN KEY (section_id) REFERENCES public.sections(section_id)
);
CREATE TABLE public.payments (
  payment_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  charge_id bigint NOT NULL,
  amount_paid numeric NOT NULL CHECK (amount_paid > 0::numeric),
  paid_at timestamp with time zone NOT NULL DEFAULT now(),
  receipt_number character varying NOT NULL UNIQUE,
  recorded_by uuid NOT NULL,
  CONSTRAINT payments_pkey PRIMARY KEY (payment_id),
  CONSTRAINT fk_payments_charge_id FOREIGN KEY (charge_id) REFERENCES public.charges(charge_id),
  CONSTRAINT fk_payments_recorded_by FOREIGN KEY (recorded_by) REFERENCES public.profiles(profile_id)
);
CREATE TABLE public.grades (
  grade_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  enrollment_item_id bigint NOT NULL UNIQUE,
  grade_code character varying NOT NULL,
  encoded_by uuid NOT NULL,
  encoded_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT grades_pkey PRIMARY KEY (grade_id),
  CONSTRAINT fk_grades_enrollment_item_id FOREIGN KEY (enrollment_item_id) REFERENCES public.enrollment_items(enrollment_item_id),
  CONSTRAINT fk_grades_grade_code FOREIGN KEY (grade_code) REFERENCES public.grade_scale(grade_code),
  CONSTRAINT fk_grades_encoded_by FOREIGN KEY (encoded_by) REFERENCES public.profiles(profile_id)
);
