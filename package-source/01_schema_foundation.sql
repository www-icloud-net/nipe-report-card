-- NIPE INTERNATIONAL SCHOOL REPORT CARD SYSTEM
-- Enterprise v6.1.1 Dashboard Editor Edition
-- DATABASE PART 1 OF 3: FOUNDATION AND CORE DATABASE STRUCTURE
-- Run this file first in the Supabase SQL Editor.

-- Nipe International School Report Card System
-- Enterprise release 6.1.1, single-file consolidated and migration-safe Supabase schema

begin;

create schema if not exists extensions;
create extension if not exists pgcrypto;
create extension if not exists citext;
create extension if not exists btree_gist;
create extension if not exists pgtap with schema extensions;

do $$
begin
  if not exists (select 1 from pg_type where typnamespace = 'public'::regnamespace and typname = 'app_role') then
    create type public.app_role as enum (
      'admin','teacher','viewer','system_admin','headteacher','academic_admin',
      'class_teacher','subject_teacher','records_officer','parent_guardian','principal'
    );
  end if;
end $$;

do $$
declare v text;
begin
  foreach v in array array[
    'admin','teacher','viewer','system_admin','headteacher','academic_admin',
    'class_teacher','subject_teacher','records_officer','parent_guardian','principal'
  ] loop
    if not exists (
      select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid
      where t.typnamespace='public'::regnamespace and t.typname='app_role' and e.enumlabel=v
    ) then execute format('alter type public.app_role add value %L',v); end if;
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typnamespace='public'::regnamespace and typname='student_status') then
    create type public.student_status as enum ('active','graduated','withdrawn','suspended');
  end if;
end $$;

do $$
declare v text;
begin
  foreach v in array array['active','graduated','withdrawn','suspended'] loop
    if not exists (
      select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid
      where t.typnamespace='public'::regnamespace and t.typname='student_status' and e.enumlabel=v
    ) then execute format('alter type public.student_status add value %L',v); end if;
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typnamespace='public'::regnamespace and typname='report_status') then
    create type public.report_status as enum (
      'draft','submitted','class_reviewed','approved','published','returned','withdrawn'
    );
  end if;
end $$;

do $$
declare v text;
begin
  foreach v in array array[
    'draft','submitted','class_reviewed','approved','published','returned','withdrawn'
  ] loop
    if not exists (
      select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid
      where t.typnamespace='public'::regnamespace and t.typname='report_status' and e.enumlabel=v
    ) then execute format('alter type public.report_status add value %L',v); end if;
  end loop;
end $$;

commit;
begin;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  role public.app_role not null default 'viewer',
  active boolean not null default true,
  mfa_required boolean not null default false,
  phone text not null default '',
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles add column if not exists mfa_required boolean not null default false;
alter table public.profiles add column if not exists phone text not null default '';
alter table public.profiles add column if not exists last_seen_at timestamptz;
alter table public.profiles alter column role set default 'viewer';

create table if not exists public.school_settings (
  id uuid primary key default gen_random_uuid(),
  school_name text not null default 'Nipe International School',
  motto text not null default 'Discipline, Commitment, Excellence',
  address text not null default 'Santeo, Ghana',
  phone text not null default '',
  email text not null default '',
  website text not null default '',
  logo_url text not null default 'assets/nipe-school-logo.png',
  report_title text not null default 'Student Terminal Report',
  report_footer text not null default 'This report is issued by Nipe International School.',
  head_name text not null default '',
  timezone text not null default 'Africa/Accra',
  locale text not null default 'en-GH',
  report_number_prefix text not null default 'NIS',
  primary_colour text not null default '#0a2f73',
  accent_colour text not null default '#f1b51c',
  verification_base_url text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.school_settings add column if not exists timezone text not null default 'Africa/Accra';
alter table public.school_settings add column if not exists locale text not null default 'en-GH';
alter table public.school_settings add column if not exists report_number_prefix text not null default 'NIS';
alter table public.school_settings add column if not exists primary_colour text not null default '#0a2f73';
alter table public.school_settings add column if not exists accent_colour text not null default '#f1b51c';
alter table public.school_settings add column if not exists verification_base_url text not null default '';
create unique index if not exists school_settings_singleton_idx on public.school_settings ((true));

create table if not exists public.academic_years (
  id uuid primary key default gen_random_uuid(),
  name citext not null unique,
  start_date date,
  end_date date,
  is_active boolean not null default false,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint academic_year_dates_chk check (start_date is null or end_date is null or start_date<=end_date)
);
alter table public.academic_years add column if not exists deleted_at timestamptz;
with ranked as (
  select id,row_number() over(order by start_date desc nulls last,created_at desc) rn
  from public.academic_years where is_active and deleted_at is null
)
update public.academic_years y set is_active=false from ranked r where y.id=r.id and r.rn>1;
create unique index if not exists one_active_academic_year_idx
  on public.academic_years ((is_active)) where is_active and deleted_at is null;

create table if not exists public.terms (
  id uuid primary key default gen_random_uuid(),
  academic_year_id uuid not null references public.academic_years(id) on delete cascade,
  name citext not null,
  sequence smallint not null default 1 check (sequence between 1 and 6),
  start_date date,
  end_date date,
  next_term_begins date,
  is_active boolean not null default false,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (academic_year_id,name),
  unique (academic_year_id,sequence),
  constraint term_dates_chk check (start_date is null or end_date is null or start_date<=end_date)
);
alter table public.terms add column if not exists deleted_at timestamptz;
with ranked as (
  select id,row_number() over(order by start_date desc nulls last,created_at desc) rn
  from public.terms where is_active and deleted_at is null
)
update public.terms t set is_active=false from ranked r where t.id=r.id and r.rn>1;
create unique index if not exists one_active_term_idx
  on public.terms ((is_active)) where is_active and deleted_at is null;

create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
  name citext not null unique,
  level_order integer not null default 0,
  class_teacher_id uuid references public.profiles(id) on delete set null,
  active boolean not null default true,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.classes add column if not exists deleted_at timestamptz;

create table if not exists public.subjects (
  id uuid primary key default gen_random_uuid(),
  code citext not null unique,
  name citext not null unique,
  max_class_score numeric(6,2) not null default 30,
  max_exam_score numeric(6,2) not null default 70,
  display_order integer not null default 0,
  active boolean not null default true,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.subjects add column if not exists deleted_at timestamptz;
do $$ begin
  alter table public.subjects drop constraint if exists subject_total_score_chk;
exception when undefined_object then null; end $$;
do $$ begin
  alter table public.subjects add constraint subject_legacy_score_bounds_chk
    check (max_class_score>0 and max_exam_score>0 and max_class_score+max_exam_score<=100);
exception when duplicate_object then null; end $$;

create table if not exists public.class_subjects (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  subject_id uuid not null references public.subjects(id) on delete cascade,
  teacher_id uuid references public.profiles(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(class_id,subject_id)
);
alter table public.class_subjects add column if not exists active boolean not null default true;

create table if not exists public.user_class_access (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete cascade,
  subject_id uuid references public.subjects(id) on delete cascade,
  access_level text not null default 'view' check(access_level in ('view','edit','score','review')),
  created_at timestamptz not null default now(),
  unique(user_id,class_id,subject_id,access_level)
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  admission_no citext not null unique,
  first_name text not null,
  middle_name text not null default '',
  last_name text not null,
  gender text not null check(gender in ('Male','Female','Other')),
  date_of_birth date,
  guardian_name text not null default '',
  guardian_phone text not null default '',
  guardian_email text not null default '',
  photo_url text not null default '',
  status public.student_status not null default 'active',
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.students add column if not exists deleted_at timestamptz;
do $$ begin
  alter table public.students drop constraint if exists students_gender_check;
  alter table public.students add constraint students_gender_check check(gender in ('Male','Female','Other'));
exception when duplicate_object then null; end $$;

create table if not exists public.student_guardians (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  relationship text not null default 'Guardian',
  phone text not null default '',
  email citext,
  address text not null default '',
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.guardian_links (
  id uuid primary key default gen_random_uuid(),
  guardian_id uuid not null references public.student_guardians(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  auth_user_id uuid references auth.users(id) on delete set null,
  can_view_reports boolean not null default true,
  can_receive_notifications boolean not null default true,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  unique(guardian_id,student_id)
);
create unique index if not exists guardian_auth_student_unique
  on public.guardian_links(auth_user_id,student_id) where auth_user_id is not null;

create table if not exists public.enrollments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  academic_year_id uuid not null references public.academic_years(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete restrict,
  roll_number integer,
  active boolean not null default true,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(student_id,academic_year_id),
  unique(academic_year_id,class_id,roll_number)
);
alter table public.enrollments add column if not exists deleted_at timestamptz;

create table if not exists public.grading_scales (
  id uuid primary key default gen_random_uuid(),
  academic_year_id uuid references public.academic_years(id) on delete cascade,
  class_id uuid references public.classes(id) on delete cascade,
  subject_id uuid references public.subjects(id) on delete cascade,
  min_mark numeric(6,2) not null check(min_mark>=0 and min_mark<=100),
  max_mark numeric(6,2) not null check(max_mark>=0 and max_mark<=100),
  grade text not null,
  remark text not null,
  grade_point numeric(5,2) not null default 0,
  display_order integer not null default 0,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint grading_scale_range_chk check(min_mark<=max_mark)
);
alter table public.grading_scales add column if not exists academic_year_id uuid references public.academic_years(id) on delete cascade;
alter table public.grading_scales add column if not exists class_id uuid references public.classes(id) on delete cascade;
alter table public.grading_scales add column if not exists subject_id uuid references public.subjects(id) on delete cascade;
alter table public.grading_scales add column if not exists deleted_at timestamptz;
do $$ begin alter table public.grading_scales drop constraint if exists grading_scales_grade_key; exception when undefined_object then null; end $$;
create unique index if not exists grading_scale_scope_grade_idx
  on public.grading_scales(
    coalesce(academic_year_id,'00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(class_id,'00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(subject_id,'00000000-0000-0000-0000-000000000000'::uuid),
    lower(grade)
  ) where deleted_at is null;
create index if not exists grading_scale_range_idx on public.grading_scales(min_mark,max_mark);

create table if not exists public.assessment_schemes (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  academic_year_id uuid references public.academic_years(id) on delete cascade,
  term_id uuid references public.terms(id) on delete cascade,
  class_id uuid references public.classes(id) on delete cascade,
  subject_id uuid references public.subjects(id) on delete cascade,
  active boolean not null default true,
  deleted_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists assessment_scheme_scope_idx
  on public.assessment_schemes(
    lower(name),
    coalesce(academic_year_id,'00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(term_id,'00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(class_id,'00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(subject_id,'00000000-0000-0000-0000-000000000000'::uuid)
  ) where deleted_at is null;

create table if not exists public.assessment_components (
  id uuid primary key default gen_random_uuid(),
  scheme_id uuid not null references public.assessment_schemes(id) on delete cascade,
  name text not null,
  code citext not null,
  maximum_score numeric(7,2) not null check(maximum_score>0),
  weight numeric(6,3) not null check(weight>0 and weight<=100),
  display_order integer not null default 0,
  required boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(scheme_id,code)
);

create table if not exists public.student_reports (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  term_id uuid not null references public.terms(id) on delete cascade,
  report_number citext,
  days_school_opened integer not null default 0 check(days_school_opened>=0),
  days_present integer not null default 0 check(days_present>=0),
  attitude text not null default '',
  conduct text not null default '',
  interest text not null default '',
  teacher_comment text not null default '',
  head_comment text not null default '',
  promoted_to_class_id uuid references public.classes(id) on delete set null,
  status public.report_status not null default 'draft',
  version integer not null default 1 check(version>0),
  submitted_at timestamptz,
  reviewed_at timestamptz,
  approved_at timestamptz,
  published_at timestamptz,
  withdrawn_at timestamptz,
  submitted_by uuid references public.profiles(id) on delete set null,
  reviewed_by uuid references public.profiles(id) on delete set null,
  approved_by uuid references public.profiles(id) on delete set null,
  published_by uuid references public.profiles(id) on delete set null,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(report_number),
  constraint report_attendance_chk check(days_present<=days_school_opened)
);
alter table public.student_reports add column if not exists report_number citext;
alter table public.student_reports add column if not exists version integer not null default 1;
alter table public.student_reports add column if not exists submitted_at timestamptz;
alter table public.student_reports add column if not exists reviewed_at timestamptz;
alter table public.student_reports add column if not exists approved_at timestamptz;
alter table public.student_reports add column if not exists withdrawn_at timestamptz;
alter table public.student_reports add column if not exists submitted_by uuid references public.profiles(id) on delete set null;
alter table public.student_reports add column if not exists reviewed_by uuid references public.profiles(id) on delete set null;
alter table public.student_reports add column if not exists approved_by uuid references public.profiles(id) on delete set null;
alter table public.student_reports add column if not exists published_by uuid references public.profiles(id) on delete set null;
alter table public.student_reports add column if not exists deleted_at timestamptz;
create unique index if not exists report_number_unique_idx on public.student_reports(report_number) where report_number is not null;
create unique index if not exists student_reports_active_enrollment_term_uidx on public.student_reports(enrollment_id,term_id) where deleted_at is null;

create table if not exists public.subject_scores (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.student_reports(id) on delete cascade,
  subject_id uuid not null references public.subjects(id) on delete restrict,
  class_score numeric(7,2) not null default 0 check(class_score>=0),
  exam_score numeric(7,2) not null default 0 check(exam_score>=0),
  total numeric(7,2) generated always as (class_score+exam_score) stored,
  grade text not null default '',
  remark text not null default '',
  grade_point numeric(5,2) not null default 0,
  teacher_initials text not null default '',
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(report_id,subject_id)
);

create table if not exists public.subject_results (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.student_reports(id) on delete cascade,
  subject_id uuid not null references public.subjects(id) on delete restrict,
  scheme_id uuid references public.assessment_schemes(id) on delete restrict,
  total_score numeric(7,2) not null default 0 check(total_score>=0 and total_score<=100),
  grade text not null default '',
  remark text not null default '',
  grade_point numeric(5,2) not null default 0,
  teacher_initials text not null default '',
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(report_id,subject_id)
);

create table if not exists public.assessment_score_entries (
  id uuid primary key default gen_random_uuid(),
  subject_result_id uuid not null references public.subject_results(id) on delete cascade,
  component_id uuid not null references public.assessment_components(id) on delete restrict,
  raw_score numeric(7,2) not null default 0 check(raw_score>=0),
  weighted_score numeric(7,2) not null default 0 check(weighted_score>=0 and weighted_score<=100),
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(subject_result_id,component_id)
);


create table if not exists public.report_workflow_events (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.student_reports(id) on delete cascade,
  from_status public.report_status,
  to_status public.report_status not null,
  comment text not null default '',
  actor_id uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.report_revisions (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.student_reports(id) on delete cascade,
  version integer not null,
  snapshot jsonb not null,
  reason text not null default '',
  actor_id uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(report_id,version)
);

create table if not exists public.report_publications (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.student_reports(id) on delete cascade,
  revision_id uuid references public.report_revisions(id) on delete set null,
  verification_token uuid not null default gen_random_uuid() unique,
  storage_path text not null default '',
  checksum text not null default '',
  page_count integer not null default 1 check(page_count>0),
  revoked_at timestamptz,
  revoked_by uuid references public.profiles(id) on delete set null,
  published_by uuid references public.profiles(id) on delete set null default auth.uid(),
  published_at timestamptz not null default now()
);
create unique index if not exists one_live_publication_per_report_idx
  on public.report_publications(report_id) where revoked_at is null;

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  body text not null default '',
  category text not null default 'system',
  entity_type text not null default '',
  entity_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid references public.profiles(id) on delete cascade,
  recipient_email citext,
  channel text not null default 'email' check(channel in ('email','sms','push')),
  template_key text not null,
  payload jsonb not null default '{}'::jsonb,
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  processed_at timestamptz,
  locked_at timestamptz,
  locked_by text,
  last_error text not null default '',
  created_at timestamptz not null default now()
);
alter table public.notification_outbox add column if not exists locked_at timestamptz;
alter table public.notification_outbox add column if not exists locked_by text;

create table if not exists public.import_batches (
  id uuid primary key default gen_random_uuid(),
  import_type text not null,
  filename text not null default '',
  status text not null default 'processing' check(status in ('processing','completed','completed_with_errors','failed')),
  total_rows integer not null default 0,
  successful_rows integer not null default 0,
  failed_rows integer not null default 0,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.import_errors (
  id bigint generated always as identity primary key,
  batch_id uuid not null references public.import_batches(id) on delete cascade,
  row_number integer not null,
  payload jsonb not null default '{}'::jsonb,
  error_message text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id) on delete set null,
  table_name text not null,
  record_id uuid,
  action text not null,
  old_data jsonb,
  new_data jsonb,
  reason text not null default '',
  created_at timestamptz not null default now()
);
alter table public.audit_log add column if not exists reason text not null default '';

create table if not exists public.client_error_events (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id) on delete set null,
  message text not null,
  stack text not null default '',
  context jsonb not null default '{}'::jsonb,
  user_agent text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.backup_exports (
  id uuid primary key default gen_random_uuid(),
  storage_path text not null,
  checksum text not null default '',
  status text not null default 'completed' check(status in ('processing','completed','failed')),
  row_counts jsonb not null default '{}'::jsonb,
  initiated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

insert into public.school_settings(
  school_name,motto,address,logo_url,report_title,report_footer,timezone,locale,report_number_prefix
)
select
  'Nipe International School','Discipline, Commitment, Excellence','Santeo, Ghana',
  'assets/nipe-school-logo.png','Student Terminal Report',
  'This report is issued by Nipe International School.','Africa/Accra','en-GH','NIS'
where not exists(select 1 from public.school_settings);

update public.school_settings
set logo_url='assets/nipe-school-logo.png',updated_at=now()
where logo_url is null or btrim(logo_url)='' or logo_url='assets/school-logo.png';

insert into public.grading_scales(min_mark,max_mark,grade,remark,grade_point,display_order)
select * from (values
  (80::numeric,100::numeric,'A','Excellent',4.00::numeric,1),
  (70,79.99,'B','Very Good',3.00,2),
  (60,69.99,'C','Good',2.00,3),
  (50,59.99,'D','Credit',1.00,4),
  (40,49.99,'E','Pass',0.50,5),
  (0,39.99,'F','Needs Improvement',0.00,6)
) v(min_mark,max_mark,grade,remark,grade_point,display_order)
where not exists(select 1 from public.grading_scales where academic_year_id is null and class_id is null and subject_id is null);

insert into public.assessment_schemes(name,active)
select 'Standard 30/70',true
where not exists(
  select 1 from public.assessment_schemes where lower(name)='standard 30/70'
    and academic_year_id is null and term_id is null and class_id is null and subject_id is null
);

insert into public.assessment_components(scheme_id,name,code,maximum_score,weight,display_order,required)
select s.id,v.name,v.code,v.maximum_score,v.weight,v.display_order,true
from public.assessment_schemes s
cross join (values
  ('Continuous Assessment','CA',30::numeric,30::numeric,1),
  ('End of Term Examination','EXAM',70::numeric,70::numeric,2)
) v(name,code,maximum_score,weight,display_order)
where lower(s.name)='standard 30/70'
  and s.academic_year_id is null and s.term_id is null and s.class_id is null and s.subject_id is null
on conflict(scheme_id,code) do nothing;

create index if not exists profiles_role_idx on public.profiles(role) where active;
create index if not exists terms_year_idx on public.terms(academic_year_id) where deleted_at is null;
create index if not exists classes_active_idx on public.classes(level_order,name) where active and deleted_at is null;
create index if not exists subjects_active_idx on public.subjects(display_order,name) where active and deleted_at is null;
create index if not exists class_subjects_class_idx on public.class_subjects(class_id) where active;
create index if not exists class_subjects_teacher_idx on public.class_subjects(teacher_id) where teacher_id is not null and active;
create index if not exists user_class_access_user_idx on public.user_class_access(user_id,class_id);
create index if not exists students_search_idx on public.students(lower(last_name),lower(first_name),admission_no) where deleted_at is null;
do $$
begin
  if not exists(
    select 1 from public.students where deleted_at is null
    group by lower(admission_no::text) having count(*)>1
  ) then
    execute 'create unique index if not exists students_admission_no_ci_idx on public.students(lower(admission_no::text)) where deleted_at is null';
  end if;
end $$;
create index if not exists enrollments_class_year_idx on public.enrollments(class_id,academic_year_id) where deleted_at is null;
create index if not exists enrollments_student_idx on public.enrollments(student_id) where deleted_at is null;
create index if not exists reports_term_status_idx on public.student_reports(term_id,status) where deleted_at is null;
create index if not exists reports_enrollment_idx on public.student_reports(enrollment_id) where deleted_at is null;
create index if not exists subject_results_report_idx on public.subject_results(report_id);
create index if not exists score_entries_result_idx on public.assessment_score_entries(subject_result_id);
create index if not exists workflow_report_idx on public.report_workflow_events(report_id,created_at desc);
create index if not exists revisions_report_idx on public.report_revisions(report_id,version desc);
create index if not exists notifications_recipient_idx on public.notifications(recipient_id,read_at,created_at desc);
create index if not exists outbox_pending_idx on public.notification_outbox(next_attempt_at,locked_at) where processed_at is null;
create index if not exists outbox_lock_idx on public.notification_outbox(locked_by,locked_at) where processed_at is null;
create index if not exists audit_record_idx on public.audit_log(table_name,record_id,created_at desc);
create index if not exists audit_actor_idx on public.audit_log(actor_id,created_at desc);

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at=now(); return new; end $$;

-- Remove policies from earlier releases before installing the current least-privilege model.
do $$
declare t text; p record;
begin
  foreach t in array array[
    'profiles','school_settings','academic_years','terms','classes','subjects','class_subjects',
    'user_class_access','students','student_guardians','guardian_links','enrollments','grading_scales',
    'assessment_schemes','assessment_components','student_reports','subject_scores','subject_results',
    'assessment_score_entries','report_workflow_events','report_revisions','report_publications',
    'notifications','notification_outbox','import_batches','import_errors','audit_log','client_error_events','backup_exports'
  ] loop
    for p in select policyname from pg_policies where schemaname='public' and tablename=t loop
      execute format('drop policy if exists %I on public.%I',p.policyname,t);
    end loop;
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','school_settings','academic_years','terms','classes','subjects','class_subjects',
    'students','student_guardians','enrollments','grading_scales','assessment_schemes',
    'assessment_components','student_reports','subject_scores','subject_results','assessment_score_entries'
  ] loop
    execute format('drop trigger if exists %I_set_updated_at on public.%I',t,t);
    execute format('create trigger %I_set_updated_at before update on public.%I for each row execute function public.set_updated_at()',t,t);
  end loop;
end $$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path=public,auth
as $$
declare initial_role public.app_role;
begin
  if not exists(select 1 from public.profiles) then
    initial_role:='system_admin'::public.app_role;
  elsif lower(coalesce(new.raw_user_meta_data->>'role',''))='parent_guardian' then
    initial_role:='parent_guardian'::public.app_role;
  else
    initial_role:='viewer'::public.app_role;
  end if;
  insert into public.profiles(id,full_name,role,mfa_required)
  values(
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name',split_part(new.email,'@',1)),
    initial_role,
    initial_role=any(array['system_admin','headteacher','academic_admin']::public.app_role[])
  )
  on conflict(id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.audit_row_change()
returns trigger
language plpgsql security definer set search_path=public
as $$
declare rid uuid; oldj jsonb; newj jsonb;
begin
  oldj:=case when tg_op='INSERT' then null else to_jsonb(old) end;
  newj:=case when tg_op='DELETE' then null else to_jsonb(new) end;
  begin rid:=coalesce((newj->>'id')::uuid,(oldj->>'id')::uuid); exception when others then rid:=null; end;
  insert into public.audit_log(actor_id,table_name,record_id,action,old_data,new_data,reason)
  values(auth.uid(),tg_table_name,rid,tg_op,oldj,newj,coalesce(current_setting('app.change_reason',true),''));
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','school_settings','academic_years','terms','classes','subjects','class_subjects',
    'user_class_access','students','student_guardians','guardian_links','enrollments','grading_scales',
    'assessment_schemes','assessment_components','student_reports','subject_results',
    'assessment_score_entries','report_publications'
  ] loop
    execute format('drop trigger if exists %I_audit on public.%I',t,t);
    execute format('create trigger %I_audit after insert or update or delete on public.%I for each row execute function public.audit_row_change()',t,t);
  end loop;
end $$;


create or replace function public.current_app_role()
returns public.app_role
language sql stable security definer set search_path=public
as $$
  select case
    when p.role='admin' then 'system_admin'::public.app_role
    when p.role='teacher' then 'class_teacher'::public.app_role
    else p.role
  end
  from public.profiles p
  where p.id=auth.uid() and p.active
$$;

create or replace function public.has_role(allowed text[])
returns boolean
language sql stable security definer set search_path=public
as $$
  select coalesce(public.current_app_role()::text=any(allowed),false)
$$;

create or replace function public.is_records_manager()
returns boolean
language sql stable security definer set search_path=public
as $$ select public.has_role(array['system_admin','headteacher','academic_admin','records_officer']) $$;

create or replace function public.is_academic_manager()
returns boolean
language sql stable security definer set search_path=public
as $$ select public.has_role(array['system_admin','headteacher','academic_admin']) $$;

create or replace function public.is_system_admin()
returns boolean
language sql stable security definer set search_path=public
as $$ select public.has_role(array['system_admin']) $$;

create or replace function public.current_aal()
returns text language sql stable
as $$ select coalesce(auth.jwt()->>'aal','aal1') $$;

create or replace function public.require_sensitive_access()
returns void
language plpgsql stable security definer set search_path=public
as $$
declare required boolean;
begin
  select coalesce(mfa_required,false) into required from public.profiles where id=auth.uid();
  if required and public.current_aal()<>'aal2' then
    raise exception 'Multi-factor authentication is required' using errcode='42501';
  end if;
end $$;

create or replace function public.can_access_class(target_class_id uuid,require_write boolean default false)
returns boolean
language sql stable security definer set search_path=public
as $$
  select
    public.is_academic_manager()
    or public.has_role(array['records_officer']) and not require_write
    or exists(
      select 1 from public.classes c
      where c.id=target_class_id and c.class_teacher_id=auth.uid() and c.active and c.deleted_at is null
    )
    or exists(
      select 1 from public.class_subjects cs
      where cs.class_id=target_class_id and cs.teacher_id=auth.uid() and cs.active
    )
    or exists(
      select 1 from public.user_class_access a
      where a.user_id=auth.uid() and a.class_id=target_class_id
        and (not require_write or a.access_level in ('edit','score','review'))
    )
$$;

create or replace function public.can_view_student(target_student_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select
    public.is_records_manager()
    or exists(
      select 1 from public.enrollments e
      where e.student_id=target_student_id and e.deleted_at is null and public.can_access_class(e.class_id,false)
    )
    or exists(
      select 1 from public.guardian_links gl
      where gl.student_id=target_student_id and gl.auth_user_id=auth.uid() and gl.can_view_reports
    )
$$;

create or replace function public.can_manage_student(target_student_id uuid default null)
returns boolean
language plpgsql stable security definer set search_path=public
as $$
begin
  if public.is_records_manager() then return true; end if;
  if target_student_id is null then return false; end if;
  return exists(
    select 1 from public.enrollments e
    where e.student_id=target_student_id and e.deleted_at is null and public.can_access_class(e.class_id,true)
  ) and public.has_role(array['class_teacher']);
end $$;

create or replace function public.report_class_id(target_report_id uuid)
returns uuid
language sql stable security definer set search_path=public
as $$
  select e.class_id
  from public.student_reports r join public.enrollments e on e.id=r.enrollment_id
  where r.id=target_report_id
$$;

create or replace function public.report_student_id(target_report_id uuid)
returns uuid
language sql stable security definer set search_path=public
as $$
  select e.student_id
  from public.student_reports r join public.enrollments e on e.id=r.enrollment_id
  where r.id=target_report_id
$$;

create or replace function public.can_view_report(target_report_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select
    public.is_records_manager()
    or public.can_access_class(public.report_class_id(target_report_id),false)
    or exists(
      select 1 from public.student_reports r
      join public.enrollments e on e.id=r.enrollment_id
      join public.guardian_links gl on gl.student_id=e.student_id
      where r.id=target_report_id and r.status in ('published','withdrawn')
        and gl.auth_user_id=auth.uid() and gl.can_view_reports
    )
$$;

create or replace function public.can_edit_report(target_report_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists(
    select 1 from public.student_reports r
    where r.id=target_report_id and r.deleted_at is null
      and r.status in ('draft','returned')
      and (
        public.is_academic_manager()
        or public.can_access_class(public.report_class_id(r.id),true)
      )
  )
$$;

create or replace function public.can_score_subject(target_report_id uuid,target_subject_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.is_academic_manager()
    or exists(
      select 1 from public.student_reports r
      join public.enrollments e on e.id=r.enrollment_id
      join public.class_subjects cs on cs.class_id=e.class_id and cs.subject_id=target_subject_id
      where r.id=target_report_id and r.status in ('draft','returned')
        and cs.active and (cs.teacher_id=auth.uid() or exists(
          select 1 from public.user_class_access a
          where a.user_id=auth.uid() and a.class_id=e.class_id
            and (a.subject_id is null or a.subject_id=target_subject_id)
            and a.access_level in ('score','edit','review')
        ))
    )
    or exists(
      select 1 from public.student_reports r
      join public.enrollments e on e.id=r.enrollment_id
      join public.classes c on c.id=e.class_id
      where r.id=target_report_id and r.status in ('draft','returned') and c.class_teacher_id=auth.uid()
    )
$$;

create or replace function public.my_realtime_topics()
returns text[]
language sql stable security definer set search_path=public
as $$
  select array(
    select distinct topic from (
      select 'school:global'::text topic
      where public.has_role(array['system_admin','headteacher','academic_admin','records_officer','viewer'])
      union all select 'user:'||auth.uid()::text
      union all
      select 'class:'||c.id::text
      from public.classes c where public.can_access_class(c.id,false)
      union all
      select 'report:'||r.id::text
      from public.student_reports r where public.can_view_report(r.id)
      union all
      select 'student:'||gl.student_id::text
      from public.guardian_links gl where gl.auth_user_id=auth.uid()
    ) q
  )
$$;

create or replace function public.resolve_assessment_scheme(
  target_class_id uuid,target_subject_id uuid,target_academic_year_id uuid,target_term_id uuid
)
returns uuid
language sql stable security definer set search_path=public
as $$
  select s.id from public.assessment_schemes s
  where s.active and s.deleted_at is null
    and (s.class_id is null or s.class_id=target_class_id)
    and (s.subject_id is null or s.subject_id=target_subject_id)
    and (s.academic_year_id is null or s.academic_year_id=target_academic_year_id)
    and (s.term_id is null or s.term_id=target_term_id)
  order by
    (s.term_id is not null)::int desc,
    (s.subject_id is not null)::int desc,
    (s.class_id is not null)::int desc,
    (s.academic_year_id is not null)::int desc,
    s.created_at desc
  limit 1
$$;

create or replace function public.grade_for_mark(
  mark numeric,target_academic_year_id uuid,target_class_id uuid,target_subject_id uuid
)
returns table(grade text,remark text,grade_point numeric)
language sql stable security definer set search_path=public
as $$
  select g.grade,g.remark,g.grade_point
  from public.grading_scales g
  where g.deleted_at is null and mark between g.min_mark and g.max_mark
    and (g.academic_year_id is null or g.academic_year_id=target_academic_year_id)
    and (g.class_id is null or g.class_id=target_class_id)
    and (g.subject_id is null or g.subject_id=target_subject_id)
  order by
    (g.subject_id is not null)::int desc,
    (g.class_id is not null)::int desc,
    (g.academic_year_id is not null)::int desc,
    g.display_order
  limit 1
$$;

create or replace function public.validate_assessment_scheme_weights()
returns trigger language plpgsql set search_path=public
as $$
declare sid uuid; total numeric;
begin
  sid:=case when tg_op='DELETE' then old.scheme_id else new.scheme_id end;
  select coalesce(sum(weight),0) into total from public.assessment_components where scheme_id=sid
    and id<>coalesce(case when tg_op='DELETE' then old.id else new.id end,'00000000-0000-0000-0000-000000000000'::uuid);
  if tg_op<>'DELETE' then total:=total+new.weight; end if;
  if total>100.001 then raise exception 'Assessment component weights cannot exceed 100'; end if;
  return case when tg_op='DELETE' then old else new end;
end $$;

drop trigger if exists assessment_components_weight_guard on public.assessment_components;
create trigger assessment_components_weight_guard
before insert or update or delete on public.assessment_components
for each row execute function public.validate_assessment_scheme_weights();

create or replace function public.prepare_score_entry()
returns trigger
language plpgsql security definer set search_path=public
as $$
declare maximum numeric; component_weight numeric; rid uuid; reportid uuid; subjectid uuid;
begin
  select c.maximum_score,c.weight,sr.id,sr.report_id,sr.subject_id
  into maximum,component_weight,rid,reportid,subjectid
  from public.assessment_components c
  join public.subject_results sr on sr.id=new.subject_result_id
  where c.id=new.component_id and c.scheme_id=sr.scheme_id;
  if maximum is null then raise exception 'Assessment component does not belong to the selected scheme'; end if;
  if new.raw_score>maximum then raise exception 'Score exceeds the configured maximum'; end if;
  if auth.uid() is not null and not public.can_score_subject(reportid,subjectid) then
    raise exception 'You are not authorised to score this subject' using errcode='42501';
  end if;
  new.weighted_score:=round((new.raw_score/maximum)*component_weight,2);
  return new;
end $$;

drop trigger if exists assessment_score_entries_prepare on public.assessment_score_entries;
create trigger assessment_score_entries_prepare
before insert or update on public.assessment_score_entries
for each row execute function public.prepare_score_entry();

create or replace function public.refresh_subject_result(target_result_id uuid)
returns void
language plpgsql security definer set search_path=public
as $$
declare total_value numeric; ay uuid; cid uuid; sid uuid; g record;
begin
  select coalesce(sum(e.weighted_score),0) into total_value
  from public.assessment_score_entries e where e.subject_result_id=target_result_id;
  select en.academic_year_id,en.class_id,sr.subject_id into ay,cid,sid
  from public.subject_results sr
  join public.student_reports r on r.id=sr.report_id
  join public.enrollments en on en.id=r.enrollment_id
  where sr.id=target_result_id;
  select * into g from public.grade_for_mark(total_value,ay,cid,sid);
  update public.subject_results
  set total_score=round(total_value,2),grade=coalesce(g.grade,''),
      remark=coalesce(g.remark,''),grade_point=coalesce(g.grade_point,0),updated_at=now()
  where id=target_result_id;
end $$;

create or replace function public.after_score_entry_change()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  perform public.refresh_subject_result(coalesce(new.subject_result_id,old.subject_result_id));
  return coalesce(new,old);
end $$;

drop trigger if exists assessment_score_entries_refresh on public.assessment_score_entries;
create trigger assessment_score_entries_refresh
after insert or update or delete on public.assessment_score_entries
for each row execute function public.after_score_entry_change();

create or replace function public.protect_report_mutation()
returns trigger language plpgsql set search_path=public
as $$
begin
  if current_setting('app.report_write',true)<>'on' and auth.uid() is not null then
    raise exception 'Report records must be changed through the report workflow' using errcode='42501';
  end if;
  return coalesce(new,old);
end $$;

drop trigger if exists protect_student_reports_mutation on public.student_reports;
create trigger protect_student_reports_mutation
before insert or update or delete on public.student_reports
for each row execute function public.protect_report_mutation();

drop trigger if exists protect_subject_results_mutation on public.subject_results;
create trigger protect_subject_results_mutation
before insert or update or delete on public.subject_results
for each row execute function public.protect_report_mutation();


create or replace function public.create_notification(
  target_recipient uuid,target_title text,target_body text default '',
  target_category text default 'system',target_entity_type text default '',target_entity_id uuid default null,
  queue_email boolean default false
)
returns uuid
language plpgsql security definer set search_path=public,auth
as $$
declare nid uuid; email_address citext;
begin
  insert into public.notifications(recipient_id,title,body,category,entity_type,entity_id)
  values(target_recipient,target_title,target_body,target_category,target_entity_type,target_entity_id)
  returning id into nid;
  if queue_email then
    select email::citext into email_address from auth.users where id=target_recipient;
    if email_address is not null then
      insert into public.notification_outbox(recipient_id,recipient_email,channel,template_key,payload)
      values(target_recipient,email_address,'email',target_category,
        jsonb_build_object('title',target_title,'body',target_body,'entity_type',target_entity_type,'entity_id',target_entity_id));
    end if;
  end if;
  return nid;
end $$;

create or replace function public.create_workflow_notifications(target_report_id uuid,target_status public.report_status)
returns void
language plpgsql security definer set search_path=public
as $$
declare classid uuid; studentname text; reportno text; recipient uuid;
begin
  select e.class_id,concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name),coalesce(r.report_number,'')
  into classid,studentname,reportno
  from public.student_reports r
  join public.enrollments e on e.id=r.enrollment_id
  join public.students s on s.id=e.student_id where r.id=target_report_id;

  if target_status in ('submitted','class_reviewed') then
    for recipient in
      select p.id from public.profiles p
      where p.active and (p.role in ('admin','system_admin','headteacher','academic_admin')
        or exists(select 1 from public.classes c where c.id=classid and c.class_teacher_id=p.id))
    loop
      if recipient<>auth.uid() then
        perform public.create_notification(recipient,'Report awaiting review',
          studentname||' • '||replace(target_status::text,'_',' '),'report_workflow','report',target_report_id,true);
      end if;
    end loop;
  elsif target_status='returned' then
    for recipient in
      select distinct x.user_id from (
        select cs.teacher_id user_id from public.class_subjects cs where cs.class_id=classid and cs.teacher_id is not null
        union all select c.class_teacher_id from public.classes c where c.id=classid and c.class_teacher_id is not null
      ) x
    loop
      perform public.create_notification(recipient,'Report returned for correction',
        studentname||case when reportno<>'' then ' • '||reportno else '' end,'report_workflow','report',target_report_id,true);
    end loop;
  elsif target_status='published' then
    for recipient in
      select gl.auth_user_id from public.guardian_links gl
      join public.enrollments e on e.student_id=gl.student_id
      join public.student_reports r on r.enrollment_id=e.id
      where r.id=target_report_id and gl.auth_user_id is not null and gl.can_receive_notifications
    loop
      perform public.create_notification(recipient,'Report card published',
        studentname||case when reportno<>'' then ' • '||reportno else '' end,'report_published','report',target_report_id,true);
    end loop;
  end if;
end $$;

create or replace function public.get_bootstrap_data()
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare result jsonb; p jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  update public.profiles set last_seen_at=now() where id=auth.uid();
  select to_jsonb(x) into p from (
    select id,full_name,public.current_app_role() role,active,mfa_required,phone
    from public.profiles where id=auth.uid()
  ) x;
  if p is null then raise exception 'Active profile not found' using errcode='42501'; end if;
  select jsonb_build_object(
    'profile',p,
    'school',(select to_jsonb(s) from public.school_settings s limit 1),
    'academic_years',coalesce((select jsonb_agg(to_jsonb(y) order by y.start_date desc nulls last,y.name)
      from public.academic_years y where y.deleted_at is null),'[]'::jsonb),
    'terms',coalesce((select jsonb_agg(to_jsonb(t) order by t.sequence)
      from public.terms t where t.deleted_at is null),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name)
      from public.classes c where c.deleted_at is null and (public.is_records_manager() or public.can_access_class(c.id,false))),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(s) order by s.display_order,s.name)
      from public.subjects s where s.deleted_at is null and s.active),'[]'::jsonb),
    'permissions',jsonb_build_object(
      'manage_users',public.is_system_admin(),
      'manage_academics',public.is_academic_manager(),
      'manage_students',public.is_records_manager() or public.has_role(array['class_teacher']),
      'approve_reports',public.has_role(array['system_admin','headteacher']),
      'publish_reports',public.has_role(array['system_admin','headteacher']),
      'view_audit',public.has_role(array['system_admin','headteacher','academic_admin']),
      'run_backup',public.is_system_admin(),
      'parent_portal',public.has_role(array['parent_guardian'])
    ),
    'topics',to_jsonb(public.my_realtime_topics())
  ) into result;
  return result;
end $$;

create or replace function public.get_dashboard_metrics(target_term_id uuid default null)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare termid uuid;
begin
  termid:=target_term_id;
  if termid is null then select id into termid from public.terms where is_active and deleted_at is null limit 1; end if;
  return jsonb_build_object(
    'active_students',(select count(*) from public.students s where s.status='active' and s.deleted_at is null and public.can_view_student(s.id)),
    'active_classes',(select count(*) from public.classes c where c.active and c.deleted_at is null and (public.is_records_manager() or public.can_access_class(c.id,false))),
    'reports',(select count(*) from public.student_reports r where r.term_id=termid and r.deleted_at is null and public.can_view_report(r.id)),
    'published',(select count(*) from public.student_reports r where r.term_id=termid and r.status='published' and r.deleted_at is null and public.can_view_report(r.id)),
    'by_status',coalesce((select jsonb_object_agg(status,count_value) from (
      select r.status::text status,count(*) count_value from public.student_reports r
      where r.term_id=termid and r.deleted_at is null and public.can_view_report(r.id) group by r.status
    ) q),'{}'::jsonb),
    'class_performance',coalesce((select jsonb_agg(to_jsonb(q) order by q.class_name) from (
      select c.id class_id,c.name class_name,round(avg(sr.total_score),2) average
      from public.subject_results sr
      join public.student_reports r on r.id=sr.report_id
      join public.enrollments e on e.id=r.enrollment_id
      join public.classes c on c.id=e.class_id
      where r.term_id=termid and r.status='published' and r.deleted_at is null and public.can_view_report(r.id)
      group by c.id,c.name
    ) q),'[]'::jsonb),
    'recent',coalesce((select jsonb_agg(to_jsonb(q) order by q.updated_at desc) from (
      select r.id,r.report_number,r.status,r.version,r.updated_at,
        concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name) student_name,
        c.name class_name,t.name term_name,
        round(coalesce(avg(sr.total_score),0),2) average
      from public.student_reports r
      join public.enrollments e on e.id=r.enrollment_id
      join public.students s on s.id=e.student_id
      join public.classes c on c.id=e.class_id
      join public.terms t on t.id=r.term_id
      left join public.subject_results sr on sr.report_id=r.id
      where r.deleted_at is null and public.can_view_report(r.id)
      group by r.id,s.id,c.id,t.id order by r.updated_at desc limit 8
    ) q),'[]'::jsonb)
  );
end $$;

create or replace function public.search_students(
  search_text text default '',target_class_id uuid default null,target_status public.student_status default null,
  page_number integer default 1,page_size integer default 20
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare offset_value integer:=greatest(page_number-1,0)*least(greatest(page_size,1),100);
declare limit_value integer:=least(greatest(page_size,1),100);
begin
  return (
    with matching as (
      select s.id,s.admission_no,s.first_name,s.middle_name,s.last_name,s.gender,s.date_of_birth,
        s.photo_url,s.status,s.updated_at,e.id enrollment_id,e.class_id,e.academic_year_id,e.roll_number,
        c.name class_name,y.name academic_year_name
      from public.students s
      left join lateral (
        select en.* from public.enrollments en
        join public.academic_years ay on ay.id=en.academic_year_id
        where en.student_id=s.id and en.deleted_at is null
        order by ay.is_active desc,ay.start_date desc nulls last,en.created_at desc limit 1
      ) e on true
      left join public.classes c on c.id=e.class_id
      left join public.academic_years y on y.id=e.academic_year_id
      where s.deleted_at is null and public.can_view_student(s.id)
        and (target_class_id is null or e.class_id=target_class_id)
        and (target_status is null or s.status=target_status)
        and (coalesce(search_text,'')='' or s.admission_no::text ilike '%'||search_text||'%'
          or concat_ws(' ',s.first_name,s.middle_name,s.last_name) ilike '%'||search_text||'%')
    )
    select jsonb_build_object(
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by x.last_name,x.first_name) from (
        select * from matching order by last_name,first_name limit limit_value offset offset_value
      ) x),'[]'::jsonb),
      'total',(select count(*) from matching),
      'page',greatest(page_number,1),'page_size',limit_value
    )
  );
end $$;

create or replace function public.get_student_record(target_student_id uuid)
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.can_view_student(target_student_id) then raise exception 'Access denied' using errcode='42501'; end if;
  return jsonb_build_object(
    'student',(select to_jsonb(s) from public.students s where s.id=target_student_id and s.deleted_at is null),
    'enrollments',coalesce((select jsonb_agg(to_jsonb(q) order by q.start_date desc nulls last) from (
      select e.*,c.name class_name,y.name academic_year_name,y.start_date
      from public.enrollments e join public.classes c on c.id=e.class_id
      join public.academic_years y on y.id=e.academic_year_id
      where e.student_id=target_student_id and e.deleted_at is null
    ) q),'[]'::jsonb),
    'guardians',coalesce((select jsonb_agg(to_jsonb(q) order by q.is_primary desc,q.full_name) from (
      select g.*,gl.auth_user_id,gl.can_view_reports,gl.can_receive_notifications,gl.verified_at
      from public.student_guardians g join public.guardian_links gl on gl.guardian_id=g.id
      where gl.student_id=target_student_id
    ) q),'[]'::jsonb),
    'reports',coalesce((select jsonb_agg(to_jsonb(q) order by q.start_date desc,q.sequence desc) from (
      select r.id,r.report_number,r.status,r.version,r.updated_at,t.name term_name,t.sequence,
        y.name academic_year_name,y.start_date,c.name class_name,
        round(coalesce(avg(sr.total_score),0),2) average
      from public.student_reports r join public.enrollments e on e.id=r.enrollment_id
      join public.terms t on t.id=r.term_id join public.academic_years y on y.id=t.academic_year_id
      join public.classes c on c.id=e.class_id left join public.subject_results sr on sr.report_id=r.id
      where e.student_id=target_student_id and r.deleted_at is null and public.can_view_report(r.id)
      group by r.id,t.id,y.id,c.id
    ) q),'[]'::jsonb)
  );
end $$;

create or replace function public.save_student(payload jsonb)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare sid uuid; eid uuid; gid uuid; student_data jsonb:=coalesce(payload->'student','{}'::jsonb);
declare enrollment_data jsonb:=coalesce(payload->'enrollment','{}'::jsonb);
declare guardian_data jsonb:=coalesce(payload->'guardian','{}'::jsonb);
begin
  sid:=nullif(student_data->>'id','')::uuid;
  if not public.can_manage_student(sid) then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(student_data->>'admission_no',''))='' or btrim(coalesce(student_data->>'first_name',''))=''
    or btrim(coalesce(student_data->>'last_name',''))='' then raise exception 'Admission number and student name are required'; end if;
  if exists(
    select 1 from public.students s
    where s.deleted_at is null
      and lower(s.admission_no::text)=lower(btrim(student_data->>'admission_no'))
      and (sid is null or s.id<>sid)
  ) then raise exception 'Admission number already exists'; end if;
  perform set_config('app.change_reason',coalesce(payload->>'reason','Student record update'),true);
  if sid is null then
    insert into public.students(admission_no,first_name,middle_name,last_name,gender,date_of_birth,photo_url,status)
    values(student_data->>'admission_no',student_data->>'first_name',coalesce(student_data->>'middle_name',''),
      student_data->>'last_name',coalesce(student_data->>'gender','Other'),
      nullif(student_data->>'date_of_birth','')::date,coalesce(student_data->>'photo_url',''),
      coalesce(nullif(student_data->>'status',''),'active')::public.student_status)
    returning id into sid;
  else
    update public.students set admission_no=student_data->>'admission_no',first_name=student_data->>'first_name',
      middle_name=coalesce(student_data->>'middle_name',''),last_name=student_data->>'last_name',
      gender=coalesce(student_data->>'gender','Other'),date_of_birth=nullif(student_data->>'date_of_birth','')::date,
      photo_url=coalesce(student_data->>'photo_url',''),status=coalesce(nullif(student_data->>'status',''),'active')::public.student_status
    where id=sid and deleted_at is null;
  end if;

  if enrollment_data ? 'academic_year_id' and enrollment_data ? 'class_id' then
    insert into public.enrollments(student_id,academic_year_id,class_id,roll_number,active)
    values(sid,(enrollment_data->>'academic_year_id')::uuid,(enrollment_data->>'class_id')::uuid,
      nullif(enrollment_data->>'roll_number','')::integer,coalesce((enrollment_data->>'active')::boolean,true))
    on conflict(student_id,academic_year_id) do update set class_id=excluded.class_id,roll_number=excluded.roll_number,
      active=excluded.active,deleted_at=null,updated_at=now() returning id into eid;
  end if;

  if btrim(coalesce(guardian_data->>'full_name',''))<>'' then
    gid:=nullif(guardian_data->>'id','')::uuid;
    if gid is null then
      insert into public.student_guardians(full_name,relationship,phone,email,address,is_primary)
      values(guardian_data->>'full_name',coalesce(guardian_data->>'relationship','Guardian'),
        coalesce(guardian_data->>'phone',''),nullif(guardian_data->>'email','')::citext,
        coalesce(guardian_data->>'address',''),coalesce((guardian_data->>'is_primary')::boolean,true))
      returning id into gid;
    else
      update public.student_guardians set full_name=guardian_data->>'full_name',
        relationship=coalesce(guardian_data->>'relationship','Guardian'),phone=coalesce(guardian_data->>'phone',''),
        email=nullif(guardian_data->>'email','')::citext,address=coalesce(guardian_data->>'address',''),
        is_primary=coalesce((guardian_data->>'is_primary')::boolean,false) where id=gid;
    end if;
    insert into public.guardian_links(guardian_id,student_id,auth_user_id,can_view_reports,can_receive_notifications)
    values(gid,sid,nullif(guardian_data->>'auth_user_id','')::uuid,
      coalesce((guardian_data->>'can_view_reports')::boolean,true),
      coalesce((guardian_data->>'can_receive_notifications')::boolean,true))
    on conflict(guardian_id,student_id) do update set auth_user_id=excluded.auth_user_id,
      can_view_reports=excluded.can_view_reports,can_receive_notifications=excluded.can_receive_notifications;
  end if;
  return public.get_student_record(sid);
end $$;

create or replace function public.list_report_cards(
  target_term_id uuid default null,target_class_id uuid default null,target_status public.report_status default null,
  search_text text default '',page_number integer default 1,page_size integer default 20
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare offset_value integer:=greatest(page_number-1,0)*least(greatest(page_size,1),100);
declare limit_value integer:=least(greatest(page_size,1),100);
begin
  return (
    with matching as (
      select r.id,r.report_number,r.status,r.version,r.updated_at,r.published_at,
        e.student_id,e.class_id,r.term_id,s.admission_no,
        concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name) student_name,
        s.photo_url,c.name class_name,t.name term_name,y.name academic_year_name,
        round(coalesce(avg(sr.total_score),0),2) average,
        count(sr.id) subject_count
      from public.student_reports r join public.enrollments e on e.id=r.enrollment_id
      join public.students s on s.id=e.student_id join public.classes c on c.id=e.class_id
      join public.terms t on t.id=r.term_id join public.academic_years y on y.id=t.academic_year_id
      left join public.subject_results sr on sr.report_id=r.id
      where r.deleted_at is null and public.can_view_report(r.id)
        and (target_term_id is null or r.term_id=target_term_id)
        and (target_class_id is null or e.class_id=target_class_id)
        and (target_status is null or r.status=target_status)
        and (coalesce(search_text,'')='' or s.admission_no::text ilike '%'||search_text||'%'
          or concat_ws(' ',s.first_name,s.middle_name,s.last_name) ilike '%'||search_text||'%')
      group by r.id,e.id,s.id,c.id,t.id,y.id
    )
    select jsonb_build_object(
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from (
        select * from matching order by updated_at desc limit limit_value offset offset_value
      ) x),'[]'::jsonb),
      'total',(select count(*) from matching),'page',greatest(page_number,1),'page_size',limit_value
    )
  );
end $$;

create or replace function public.get_report_editor(target_report_id uuid default null,target_enrollment_id uuid default null,target_term_id uuid default null)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare rid uuid:=target_report_id; enrollmentid uuid:=target_enrollment_id; termid uuid:=target_term_id;
declare classid uuid; yearid uuid; report_json jsonb; student_json jsonb; canedit boolean;
begin
  if rid is not null then
    if not public.can_view_report(rid) then raise exception 'Access denied' using errcode='42501'; end if;
    select r.enrollment_id,r.term_id,e.class_id,e.academic_year_id,to_jsonb(r)
      into enrollmentid,termid,classid,yearid,report_json
    from public.student_reports r join public.enrollments e on e.id=r.enrollment_id where r.id=rid and r.deleted_at is null;
  else
    select e.class_id,e.academic_year_id into classid,yearid from public.enrollments e
      where e.id=enrollmentid and e.deleted_at is null;
    if classid is null or not public.can_access_class(classid,true) then raise exception 'Access denied' using errcode='42501'; end if;
    if not exists(select 1 from public.terms t where t.id=termid and t.academic_year_id=yearid and t.deleted_at is null)
      then raise exception 'Term and enrolment academic year do not match'; end if;
    select to_jsonb(r) into report_json from public.student_reports r where r.enrollment_id=enrollmentid and r.term_id=termid and r.deleted_at is null;
    if report_json is not null then
      rid:=(report_json->>'id')::uuid;
    else
      report_json:=jsonb_build_object('id',null,'enrollment_id',enrollmentid,'term_id',termid,'status','draft',
        'version',0,'days_school_opened',0,'days_present',0,'attitude','','conduct','','interest','',
        'teacher_comment','','head_comment','','promoted_to_class_id',null);
    end if;
  end if;
  select jsonb_build_object(
    'id',s.id,'admission_no',s.admission_no,'first_name',s.first_name,'middle_name',s.middle_name,'last_name',s.last_name,
    'full_name',concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name),'gender',s.gender,'date_of_birth',s.date_of_birth,
    'photo_url',s.photo_url,'class_id',e.class_id,'class_name',c.name,'academic_year_id',e.academic_year_id,'academic_year_name',y.name,
    'roll_number',e.roll_number,'term_name',t.name,'term_sequence',t.sequence,'next_term_begins',t.next_term_begins
  ) into student_json
  from public.enrollments e join public.students s on s.id=e.student_id join public.classes c on c.id=e.class_id
  join public.academic_years y on y.id=e.academic_year_id join public.terms t on t.id=termid
  where e.id=enrollmentid;

  canedit:=case when rid is null then public.can_access_class(classid,true) else public.can_edit_report(rid) end;
  return jsonb_build_object(
    'report',report_json,'student',student_json,'can_edit',canedit,
    'subjects',coalesce((select jsonb_agg(to_jsonb(q) order by q.display_order,q.subject_name) from (
      select sb.id subject_id,sb.code subject_code,sb.name subject_name,sb.display_order,
        coalesce(sr.scheme_id,public.resolve_assessment_scheme(classid,sb.id,yearid,termid)) scheme_id,
        sc.name scheme_name,sr.id result_id,coalesce(sr.total_score,0) total_score,
        coalesce(sr.grade,'') grade,coalesce(sr.remark,'') remark,coalesce(sr.grade_point,0) grade_point,
        coalesce(sr.teacher_initials,'') teacher_initials,
        coalesce((select jsonb_agg(jsonb_build_object(
          'component_id',ac.id,'name',ac.name,'code',ac.code,'maximum_score',ac.maximum_score,
          'weight',ac.weight,'required',ac.required,'display_order',ac.display_order,
          'raw_score',coalesce(se.raw_score,0),'weighted_score',coalesce(se.weighted_score,0)
        ) order by ac.display_order,ac.name)
        from public.assessment_components ac
        left join public.assessment_score_entries se on se.component_id=ac.id and se.subject_result_id=sr.id
        where ac.scheme_id=coalesce(sr.scheme_id,public.resolve_assessment_scheme(classid,sb.id,yearid,termid))
        ),'[]'::jsonb) components
      from public.class_subjects cs join public.subjects sb on sb.id=cs.subject_id
      left join public.subject_results sr on sr.report_id=rid and sr.subject_id=sb.id
      left join public.assessment_schemes sc on sc.id=coalesce(sr.scheme_id,public.resolve_assessment_scheme(classid,sb.id,yearid,termid))
      where cs.class_id=classid and cs.active and sb.active and sb.deleted_at is null
    ) q),'[]'::jsonb),
    'workflow',case when rid is null then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from (
      select w.*,p.full_name actor_name from public.report_workflow_events w left join public.profiles p on p.id=w.actor_id where w.report_id=rid
    ) q),'[]'::jsonb) end,
    'publications',case when rid is null then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(p) order by p.published_at desc)
      from public.report_publications p where p.report_id=rid),'[]'::jsonb) end
  );
end $$;


create or replace function public.build_report_snapshot(target_report_id uuid)
returns jsonb
language sql stable security definer set search_path=public
as $$
  select jsonb_build_object(
    'school',(select to_jsonb(s) from public.school_settings s limit 1),
    'report',to_jsonb(r),
    'student',jsonb_build_object(
      'id',st.id,'admission_no',st.admission_no,
      'full_name',concat_ws(' ',st.first_name,nullif(st.middle_name,''),st.last_name),
      'gender',st.gender,'date_of_birth',st.date_of_birth,'photo_url',st.photo_url,
      'class_name',c.name,'academic_year',ay.name,'term',t.name,'roll_number',e.roll_number,
      'next_term_begins',t.next_term_begins
    ),
    'results',coalesce((select jsonb_agg(jsonb_build_object(
      'subject_id',sb.id,'subject_code',sb.code,'subject_name',sb.name,'total_score',sr.total_score,
      'grade',sr.grade,'remark',sr.remark,'grade_point',sr.grade_point,'teacher_initials',sr.teacher_initials,
      'components',coalesce((select jsonb_agg(jsonb_build_object(
        'component_id',ac.id,'name',ac.name,'code',ac.code,'maximum_score',ac.maximum_score,
        'weight',ac.weight,'raw_score',se.raw_score,'weighted_score',se.weighted_score
      ) order by ac.display_order,ac.name)
      from public.assessment_score_entries se join public.assessment_components ac on ac.id=se.component_id
      where se.subject_result_id=sr.id),'[]'::jsonb)
    ) order by sb.display_order,sb.name)
    from public.subject_results sr join public.subjects sb on sb.id=sr.subject_id
    where sr.report_id=r.id),'[]'::jsonb),
    'summary',jsonb_build_object(
      'average',(select round(coalesce(avg(total_score),0),2) from public.subject_results where report_id=r.id),
      'aggregate',(select round(coalesce(sum(grade_point),0),2) from public.subject_results where report_id=r.id),
      'subjects',(select count(*) from public.subject_results where report_id=r.id)
    )
  )
  from public.student_reports r
  join public.enrollments e on e.id=r.enrollment_id
  join public.students st on st.id=e.student_id
  join public.classes c on c.id=e.class_id
  join public.terms t on t.id=r.term_id
  join public.academic_years ay on ay.id=t.academic_year_id
  where r.id=target_report_id
$$;

create or replace function public.generate_report_number(target_report_id uuid)
returns text
language plpgsql security definer set search_path=public
as $$
declare prefix text; yname text; seq bigint;
begin
  select coalesce(report_number_prefix,'NIS') into prefix from public.school_settings limit 1;
  select regexp_replace(ay.name::text,'[^0-9A-Za-z]','','g')
  into yname from public.student_reports r join public.terms t on t.id=r.term_id
  join public.academic_years ay on ay.id=t.academic_year_id where r.id=target_report_id;
  select count(*)+1 into seq from public.student_reports where report_number is not null;
  return upper(prefix)||'-'||coalesce(nullif(yname,''),to_char(current_date,'YYYY'))||'-'||lpad(seq::text,6,'0');
end $$;

-- Preserve historical reports from earlier releases as immutable revisions and verifiable publications.
do $$
declare item record; revisionid uuid;
begin
  perform set_config('app.report_write','on',true);
  for item in
    select r.id from public.student_reports r
    where r.report_number is null and r.deleted_at is null
    order by r.created_at,r.id
  loop
    update public.student_reports
    set report_number=public.generate_report_number(item.id)
    where id=item.id and report_number is null;
  end loop;

  for item in
    select r.* from public.student_reports r where r.deleted_at is null order by r.created_at,r.id
  loop
    insert into public.report_revisions(report_id,version,snapshot,reason,actor_id,created_at)
    values(item.id,greatest(item.version,1),public.build_report_snapshot(item.id),'Historical record migration',
      coalesce(item.published_by,item.approved_by,item.reviewed_by,item.submitted_by,item.created_by),
      coalesce(item.updated_at,item.created_at,now()))
    on conflict(report_id,version) do nothing;

    insert into public.report_workflow_events(report_id,from_status,to_status,comment,actor_id,created_at)
    select item.id,null,item.status,'Historical record migration',
      coalesce(item.published_by,item.approved_by,item.reviewed_by,item.submitted_by,item.created_by),
      coalesce(item.published_at,item.updated_at,item.created_at,now())
    where not exists(select 1 from public.report_workflow_events w where w.report_id=item.id);

    if item.status='published' then
      select rr.id into revisionid from public.report_revisions rr
      where rr.report_id=item.id order by rr.version desc,rr.created_at desc limit 1;
      insert into public.report_publications(report_id,revision_id,storage_path,checksum,page_count,published_by,published_at)
      select item.id,revisionid,'','',1,coalesce(item.published_by,item.approved_by,item.created_by),
        coalesce(item.published_at,item.updated_at,item.created_at,now())
      where not exists(select 1 from public.report_publications p where p.report_id=item.id and p.revoked_at is null);
    end if;
  end loop;
end $$;

create or replace function public.save_report_card(payload jsonb,expected_version integer default null)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare rid uuid:=nullif(payload->>'report_id','')::uuid;
declare enrollmentid uuid:=(payload->>'enrollment_id')::uuid;
declare termid uuid:=(payload->>'term_id')::uuid;
declare current_version integer; current_status public.report_status; classid uuid; yearid uuid;
declare subject_item jsonb; component_item jsonb; resultid uuid; schemeid uuid; subjectid uuid;
declare report_fields jsonb:=coalesce(payload->'fields','{}'::jsonb);
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select e.class_id,e.academic_year_id into classid,yearid from public.enrollments e
    where e.id=enrollmentid and e.deleted_at is null;
  if classid is null or not public.can_access_class(classid,true) then raise exception 'Access denied' using errcode='42501'; end if;
  if not exists(select 1 from public.terms t where t.id=termid and t.academic_year_id=yearid and t.deleted_at is null)
    then raise exception 'Term and enrolment academic year do not match'; end if;
  if coalesce((report_fields->>'days_school_opened')::integer,0)<coalesce((report_fields->>'days_present')::integer,0)
    then raise exception 'Days present cannot exceed days school opened'; end if;

  perform set_config('app.report_write','on',true);
  perform set_config('app.change_reason',coalesce(payload->>'reason','Report card save'),true);
  perform pg_advisory_xact_lock(hashtext(enrollmentid::text),hashtext(termid::text));

  if rid is null then
    select id,version,status into rid,current_version,current_status
    from public.student_reports where enrollment_id=enrollmentid and term_id=termid and deleted_at is null for update;
  else
    select version,status into current_version,current_status
    from public.student_reports where id=rid and enrollment_id=enrollmentid and term_id=termid and deleted_at is null for update;
  end if;

  if rid is null then
    insert into public.student_reports(
      enrollment_id,term_id,days_school_opened,days_present,attitude,conduct,interest,
      teacher_comment,head_comment,promoted_to_class_id,status,version,created_by
    ) values(
      enrollmentid,termid,coalesce((report_fields->>'days_school_opened')::integer,0),
      coalesce((report_fields->>'days_present')::integer,0),coalesce(report_fields->>'attitude',''),
      coalesce(report_fields->>'conduct',''),coalesce(report_fields->>'interest',''),
      coalesce(report_fields->>'teacher_comment',''),coalesce(report_fields->>'head_comment',''),
      nullif(report_fields->>'promoted_to_class_id','')::uuid,'draft',1,auth.uid()
    ) returning id,version,status into rid,current_version,current_status;
  else
    if expected_version is not null and expected_version<>current_version then
      raise exception 'This report was changed by another user. Refresh before saving.'
        using errcode='40001',detail='expected='||expected_version||',actual='||current_version;
    end if;
    if current_status not in ('draft','returned') then raise exception 'This report is locked by the approval workflow'; end if;
    if not public.can_edit_report(rid) then raise exception 'Access denied' using errcode='42501'; end if;
    update public.student_reports set
      days_school_opened=coalesce((report_fields->>'days_school_opened')::integer,0),
      days_present=coalesce((report_fields->>'days_present')::integer,0),
      attitude=coalesce(report_fields->>'attitude',''),conduct=coalesce(report_fields->>'conduct',''),
      interest=coalesce(report_fields->>'interest',''),teacher_comment=coalesce(report_fields->>'teacher_comment',''),
      head_comment=case when public.has_role(array['system_admin','headteacher']) then coalesce(report_fields->>'head_comment',head_comment) else head_comment end,
      promoted_to_class_id=nullif(report_fields->>'promoted_to_class_id','')::uuid,
      version=version+1,updated_at=now()
    where id=rid returning version,status into current_version,current_status;
  end if;

  for subject_item in select value from jsonb_array_elements(coalesce(payload->'subjects','[]'::jsonb))
  loop
    subjectid:=(subject_item->>'subject_id')::uuid;
    if not public.can_score_subject(rid,subjectid) then
      if exists(select 1 from public.subject_results where report_id=rid and subject_id=subjectid) then continue; end if;
      raise exception 'You are not authorised to score one or more subjects' using errcode='42501';
    end if;
    schemeid:=nullif(subject_item->>'scheme_id','')::uuid;
    if schemeid is null then schemeid:=public.resolve_assessment_scheme(classid,subjectid,yearid,termid); end if;
    if schemeid is null then raise exception 'No assessment scheme is configured for a subject'; end if;
    if abs((select coalesce(sum(weight),0) from public.assessment_components where scheme_id=schemeid)-100)>0.01
      then raise exception 'Assessment scheme weights must total 100'; end if;

    insert into public.subject_results(report_id,subject_id,scheme_id,teacher_initials,created_by)
    values(rid,subjectid,schemeid,coalesce(subject_item->>'teacher_initials',''),auth.uid())
    on conflict(report_id,subject_id) do update set scheme_id=excluded.scheme_id,
      teacher_initials=excluded.teacher_initials,updated_at=now()
    returning id into resultid;

    delete from public.assessment_score_entries e
    where e.subject_result_id=resultid
      and not exists(
        select 1 from jsonb_array_elements(coalesce(subject_item->'components','[]'::jsonb)) x
        where (x->>'component_id')::uuid=e.component_id
      );

    for component_item in select value from jsonb_array_elements(coalesce(subject_item->'components','[]'::jsonb))
    loop
      insert into public.assessment_score_entries(subject_result_id,component_id,raw_score,created_by)
      values(resultid,(component_item->>'component_id')::uuid,coalesce((component_item->>'raw_score')::numeric,0),auth.uid())
      on conflict(subject_result_id,component_id) do update set raw_score=excluded.raw_score,updated_at=now();
    end loop;
    perform public.refresh_subject_result(resultid);
  end loop;

  update public.student_reports
  set report_number=coalesce(report_number,public.generate_report_number(rid)),updated_at=now()
  where id=rid;

  insert into public.report_revisions(report_id,version,snapshot,reason,actor_id)
  values(rid,(select version from public.student_reports where id=rid),public.build_report_snapshot(rid),
    coalesce(payload->>'reason','Saved'),auth.uid())
  on conflict(report_id,version) do update set snapshot=excluded.snapshot,reason=excluded.reason,
    actor_id=excluded.actor_id,created_at=now();

  return public.get_report_editor(rid,null,null);
end $$;

create or replace function public.transition_report_status(
  target_report_id uuid,target_status public.report_status,comment_text text default '',expected_version integer default null
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare current_status public.report_status; current_version integer; permitted boolean:=false;
declare ts timestamptz:=now(); revisionid uuid;
begin
  select status,version into current_status,current_version from public.student_reports
    where id=target_report_id and deleted_at is null for update;
  if current_status is null then raise exception 'Report not found'; end if;
  if expected_version is not null and expected_version<>current_version then
    raise exception 'This report was changed by another user. Refresh before continuing.' using errcode='40001';
  end if;

  permitted:=case
    when target_status='submitted' and current_status in ('draft','returned')
      then public.can_edit_report(target_report_id)
    when target_status='class_reviewed' and current_status='submitted'
      then public.has_role(array['system_admin','headteacher','academic_admin','class_teacher'])
        and public.can_access_class(public.report_class_id(target_report_id),true)
    when target_status='returned' and current_status in ('submitted','class_reviewed','approved')
      then public.has_role(array['system_admin','headteacher','academic_admin'])
    when target_status='approved' and current_status='class_reviewed'
      then public.has_role(array['system_admin','headteacher'])
    when target_status='published' and current_status='approved'
      then public.has_role(array['system_admin','headteacher'])
    when target_status='withdrawn' and current_status='published'
      then public.has_role(array['system_admin','headteacher'])
    else false end;
  if not permitted then raise exception 'This workflow transition is not permitted' using errcode='42501'; end if;

  if target_status in ('approved','published','withdrawn') then perform public.require_sensitive_access(); end if;
  if target_status in ('submitted','class_reviewed','approved','published') and
     exists(
       select 1 from public.class_subjects cs
       join public.enrollments e on e.class_id=cs.class_id
       join public.student_reports r on r.enrollment_id=e.id
       left join public.subject_results sr on sr.report_id=r.id and sr.subject_id=cs.subject_id
       where r.id=target_report_id and cs.active and sr.id is null
     ) then raise exception 'All assigned subjects must have results before this transition'; end if;

  perform set_config('app.report_write','on',true);
  perform set_config('app.change_reason',coalesce(nullif(comment_text,''),'Report workflow transition'),true);
  update public.student_reports set
    status=target_status,version=version+1,
    submitted_at=case when target_status='submitted' then ts else submitted_at end,
    submitted_by=case when target_status='submitted' then auth.uid() else submitted_by end,
    reviewed_at=case when target_status='class_reviewed' then ts else reviewed_at end,
    reviewed_by=case when target_status='class_reviewed' then auth.uid() else reviewed_by end,
    approved_at=case when target_status='approved' then ts else approved_at end,
    approved_by=case when target_status='approved' then auth.uid() else approved_by end,
    published_at=case when target_status='published' then ts else published_at end,
    published_by=case when target_status='published' then auth.uid() else published_by end,
    withdrawn_at=case when target_status='withdrawn' then ts else withdrawn_at end,
    updated_at=ts
  where id=target_report_id returning version into current_version;

  insert into public.report_workflow_events(report_id,from_status,to_status,comment,actor_id)
  values(target_report_id,current_status,target_status,coalesce(comment_text,''),auth.uid());

  insert into public.report_revisions(report_id,version,snapshot,reason,actor_id)
  values(target_report_id,current_version,public.build_report_snapshot(target_report_id),
    coalesce(nullif(comment_text,''),replace(target_status::text,'_',' ')),auth.uid())
  on conflict(report_id,version) do update set snapshot=excluded.snapshot,reason=excluded.reason,
    actor_id=excluded.actor_id,created_at=now()
  returning id into revisionid;

  if target_status='published' then
    insert into public.report_publications(report_id,revision_id,published_by)
    values(target_report_id,revisionid,auth.uid())
    on conflict(report_id) where revoked_at is null do update
      set revision_id=excluded.revision_id,published_by=excluded.published_by,published_at=now();
  elsif target_status='withdrawn' then
    update public.report_publications set revoked_at=ts,revoked_by=auth.uid()
    where report_id=target_report_id and revoked_at is null;
  end if;
  perform public.create_workflow_notifications(target_report_id,target_status);
  return public.get_report_editor(target_report_id,null,null);
end $$;

create or replace function public.begin_report_correction(target_report_id uuid,reason_text text)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare current_status public.report_status;
begin
  perform public.require_sensitive_access();
  if not public.has_role(array['system_admin','headteacher','academic_admin']) then raise exception 'Access denied' using errcode='42501'; end if;
  select status into current_status from public.student_reports where id=target_report_id for update;
  if current_status not in ('published','approved','class_reviewed','submitted') then raise exception 'A correction cannot be opened from this status'; end if;
  perform set_config('app.report_write','on',true);
  perform set_config('app.change_reason',reason_text,true);
  update public.student_reports set status='returned',version=version+1,updated_at=now() where id=target_report_id;
  insert into public.report_workflow_events(report_id,from_status,to_status,comment,actor_id)
  values(target_report_id,current_status,'returned',reason_text,auth.uid());
  insert into public.report_revisions(report_id,version,snapshot,reason,actor_id)
  select id,version,public.build_report_snapshot(id),reason_text,auth.uid() from public.student_reports where id=target_report_id
  on conflict(report_id,version) do nothing;
  perform public.create_workflow_notifications(target_report_id,'returned');
  return public.get_report_editor(target_report_id,null,null);
end $$;

create or replace function public.register_report_pdf(
  target_report_id uuid,target_storage_path text,target_checksum text default '',target_page_count integer default 1
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare publicationid uuid;
begin
  perform public.require_sensitive_access();
  if not public.has_role(array['system_admin','headteacher']) then raise exception 'Access denied' using errcode='42501'; end if;
  if not exists(select 1 from public.student_reports where id=target_report_id and status='published')
    then raise exception 'Only a published report can receive an official PDF'; end if;
  update public.report_publications set storage_path=target_storage_path,checksum=coalesce(target_checksum,''),
    page_count=greatest(target_page_count,1)
  where report_id=target_report_id and revoked_at is null returning id into publicationid;
  if publicationid is null then raise exception 'Active publication not found'; end if;
  return (select to_jsonb(p) from public.report_publications p where p.id=publicationid);
end $$;

create or replace function public.verify_report(token uuid)
returns jsonb
language sql stable security definer set search_path=public
as $$
  select case when p.id is null then jsonb_build_object('valid',false)
  else jsonb_build_object(
    'valid',p.revoked_at is null,
    'revoked',p.revoked_at is not null,
    'published_at',p.published_at,'report_number',r.report_number,
    'student_name',concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name),
    'admission_no',s.admission_no,'class_name',c.name,'term_name',t.name,'academic_year',y.name,
    'average',(p2.snapshot->'summary'->>'average')::numeric,
    'school_name',p2.snapshot->'school'->>'school_name',
    'revision',p2.version
  ) end
  from (select token verification_token) input
  left join public.report_publications p on p.verification_token=input.verification_token
  left join public.student_reports r on r.id=p.report_id
  left join public.enrollments e on e.id=r.enrollment_id
  left join public.students s on s.id=e.student_id
  left join public.classes c on c.id=e.class_id
  left join public.terms t on t.id=r.term_id
  left join public.academic_years y on y.id=t.academic_year_id
  left join public.report_revisions p2 on p2.id=p.revision_id
$$;

create or replace function public.get_report_revisions(target_report_id uuid)
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.can_view_report(target_report_id) then raise exception 'Access denied' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',rr.id,'version',rr.version,'reason',rr.reason,'actor_id',rr.actor_id,
    'actor_name',p.full_name,'created_at',rr.created_at,'snapshot',rr.snapshot
  ) order by rr.version desc)
  from public.report_revisions rr left join public.profiles p on p.id=rr.actor_id
  where rr.report_id=target_report_id),'[]'::jsonb);
end $$;


create or replace function public.current_app_role_for(input_role public.app_role)
returns text
language sql immutable
as $$ select case when input_role='admin' then 'system_admin' when input_role='teacher' then 'class_teacher' else input_role::text end $$;

-- Recreate the profile listing now that the role normalizer exists.
create or replace function public.list_profiles_with_access()
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  return jsonb_build_object(
    'profiles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'full_name',p.full_name,'role',public.current_app_role_for(p.role),
      'active',p.active,'mfa_required',p.mfa_required,'phone',p.phone,'last_seen_at',p.last_seen_at,
      'access',coalesce((select jsonb_agg(jsonb_build_object(
        'id',a.id,'class_id',a.class_id,'class_name',c.name,'subject_id',a.subject_id,
        'subject_name',s.name,'access_level',a.access_level
      ) order by c.name,s.name nulls first)
        from public.user_class_access a join public.classes c on c.id=a.class_id
        left join public.subjects s on s.id=a.subject_id where a.user_id=p.id),'[]'::jsonb)
    ) order by p.full_name) from public.profiles p),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(s) order by s.display_order,s.name) from public.subjects s where s.deleted_at is null),'[]'::jsonb)
  );
end $$;

create or replace function public.save_profile_access(payload jsonb)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare userid uuid:=(payload->>'user_id')::uuid; accessitem jsonb;
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  if userid=auth.uid() and coalesce((payload->>'active')::boolean,true)=false then
    raise exception 'You cannot deactivate your own account';
  end if;
  perform set_config('app.change_reason',coalesce(payload->>'reason','User access update'),true);
  update public.profiles set full_name=coalesce(payload->>'full_name',full_name),
    role=coalesce(nullif(payload->>'role','')::public.app_role,role),
    active=coalesce((payload->>'active')::boolean,active),
    mfa_required=coalesce((payload->>'mfa_required')::boolean,mfa_required),
    phone=coalesce(payload->>'phone',phone)
  where id=userid;
  if payload ? 'access' then
    delete from public.user_class_access where user_id=userid;
    for accessitem in select value from jsonb_array_elements(coalesce(payload->'access','[]'::jsonb))
    loop
      insert into public.user_class_access(user_id,class_id,subject_id,access_level)
      values(userid,(accessitem->>'class_id')::uuid,nullif(accessitem->>'subject_id','')::uuid,
        coalesce(accessitem->>'access_level','view'))
      on conflict do nothing;
    end loop;
  end if;
  return public.list_profiles_with_access();
end $$;

create or replace function public.list_notifications(page_number integer default 1,page_size integer default 30)
returns jsonb
language sql stable security definer set search_path=public
as $$
  with matching as (
    select n.* from public.notifications n where n.recipient_id=auth.uid()
  )
  select jsonb_build_object(
    'rows',coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from (
      select * from matching order by created_at desc
      limit least(greatest(page_size,1),100)
      offset greatest(page_number-1,0)*least(greatest(page_size,1),100)
    ) q),'[]'::jsonb),
    'total',(select count(*) from matching),
    'unread',(select count(*) from matching where read_at is null)
  )
$$;

create or replace function public.mark_notifications_read(notification_ids uuid[] default null)
returns integer
language plpgsql security definer set search_path=public
as $$
declare changed integer;
begin
  update public.notifications set read_at=coalesce(read_at,now())
  where recipient_id=auth.uid() and (notification_ids is null or id=any(notification_ids));
  get diagnostics changed=row_count;
  return changed;
end $$;

create or replace function public.list_audit_events(
  target_table text default null,target_record_id uuid default null,page_number integer default 1,page_size integer default 50
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.has_role(array['system_admin','headteacher','academic_admin']) then raise exception 'Access denied' using errcode='42501'; end if;
  return (
    with matching as (
      select a.*,p.full_name actor_name from public.audit_log a
      left join public.profiles p on p.id=a.actor_id
      where (target_table is null or a.table_name=target_table)
        and (target_record_id is null or a.record_id=target_record_id)
    )
    select jsonb_build_object(
      'rows',coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from (
        select * from matching order by created_at desc
        limit least(greatest(page_size,1),100)
        offset greatest(page_number-1,0)*least(greatest(page_size,1),100)
      ) q),'[]'::jsonb),
      'total',(select count(*) from matching)
    )
  );
end $$;

create or replace function public.log_client_error(message_text text,stack_text text default '',context_data jsonb default '{}'::jsonb,user_agent_text text default '')
returns bigint
language plpgsql security definer set search_path=public
as $$
declare eventid bigint;
begin
  insert into public.client_error_events(actor_id,message,stack,context,user_agent)
  values(auth.uid(),left(message_text,4000),left(coalesce(stack_text,''),12000),coalesce(context_data,'{}'::jsonb),left(coalesce(user_agent_text,''),1000))
  returning id into eventid;
  return eventid;
end $$;

create or replace function public.bulk_import_students(rows jsonb,filename text default '')
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare batchid uuid; rowitem jsonb; rowno integer:=0; ok integer:=0; failed integer:=0;
begin
  if not public.is_records_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  insert into public.import_batches(import_type,filename,total_rows,created_by)
  values('students',filename,jsonb_array_length(coalesce(rows,'[]'::jsonb)),auth.uid()) returning id into batchid;
  for rowitem in select value from jsonb_array_elements(coalesce(rows,'[]'::jsonb))
  loop
    rowno:=rowno+1;
    begin
      perform public.save_student(jsonb_build_object(
        'student',jsonb_build_object(
          'admission_no',rowitem->>'admission_no','first_name',rowitem->>'first_name',
          'middle_name',coalesce(rowitem->>'middle_name',''),'last_name',rowitem->>'last_name',
          'gender',coalesce(rowitem->>'gender','Other'),'date_of_birth',coalesce(rowitem->>'date_of_birth',''),
          'status',coalesce(rowitem->>'status','active'),'photo_url',''
        ),
        'enrollment',jsonb_build_object(
          'academic_year_id',rowitem->>'academic_year_id','class_id',rowitem->>'class_id',
          'roll_number',coalesce(rowitem->>'roll_number',''),'active',true
        ),
        'guardian',jsonb_build_object(
          'full_name',coalesce(rowitem->>'guardian_name',''),'relationship',coalesce(rowitem->>'relationship','Guardian'),
          'phone',coalesce(rowitem->>'guardian_phone',''),'email',coalesce(rowitem->>'guardian_email',''),
          'is_primary',true
        ),
        'reason','Bulk student import'
      ));
      ok:=ok+1;
    exception when others then
      failed:=failed+1;
      insert into public.import_errors(batch_id,row_number,payload,error_message)
      values(batchid,rowno,rowitem,sqlerrm);
    end;
  end loop;
  update public.import_batches set successful_rows=ok,failed_rows=failed,
    status=case when failed=0 then 'completed' else 'completed_with_errors' end,completed_at=now()
  where id=batchid;
  return jsonb_build_object('batch_id',batchid,'successful',ok,'failed',failed);
end $$;

create or replace function public.bulk_import_scores(
  target_term_id uuid,target_class_id uuid,rows jsonb,filename text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare batchid uuid; rowitem jsonb; rowno integer:=0; ok integer:=0; failed integer:=0;
declare enrollmentid uuid; reportid uuid; subjectid uuid; schemeid uuid; resultid uuid; yearid uuid;
declare componentid uuid; raw numeric; maxscore numeric; current_version integer;
begin
  if jsonb_typeof(coalesce(rows,'[]'::jsonb))<>'array' then raise exception 'Score import rows must be a list'; end if;
  select academic_year_id into yearid from public.terms where id=target_term_id and deleted_at is null;
  if yearid is null then raise exception 'Selected term is invalid'; end if;
  if not exists(select 1 from public.classes c where c.id=target_class_id and c.active and c.deleted_at is null) then raise exception 'Selected class is invalid or inactive'; end if;
  if not public.can_access_class(target_class_id,true) then raise exception 'Access denied' using errcode='42501'; end if;
  insert into public.import_batches(import_type,filename,total_rows,created_by)
  values('scores',filename,jsonb_array_length(rows),auth.uid()) returning id into batchid;
  perform set_config('app.report_write','on',true);
  perform set_config('app.change_reason','Bulk score import',true);
  for rowitem in select value from jsonb_array_elements(rows) loop
    rowno:=rowno+1;
    begin
      if btrim(coalesce(rowitem->>'admission_no',''))='' or btrim(coalesce(rowitem->>'subject_code',''))='' or btrim(coalesce(rowitem->>'component_code',''))='' then
        raise exception 'Admission number, subject code, and component code are required';
      end if;
      select e.id into strict enrollmentid from public.enrollments e join public.students s on s.id=e.student_id
      where e.class_id=target_class_id and e.academic_year_id=yearid and e.deleted_at is null and s.deleted_at is null
        and lower(s.admission_no::text)=lower(btrim(rowitem->>'admission_no'));
      select sb.id into subjectid from public.subjects sb join public.class_subjects cs on cs.subject_id=sb.id and cs.class_id=target_class_id and cs.active
      where lower(sb.code::text)=lower(btrim(rowitem->>'subject_code')) and sb.active and sb.deleted_at is null;
      if subjectid is null then raise exception 'Subject code is not assigned to the selected class'; end if;
      insert into public.student_reports(enrollment_id,term_id,status,created_by,deleted_at)
      values(enrollmentid,target_term_id,'draft',auth.uid(),null)
      on conflict(enrollment_id,term_id) do update set deleted_at=null
      returning id,version into reportid,current_version;
      if not public.can_score_subject(reportid,subjectid) then raise exception 'Not authorised for subject or report is locked'; end if;
      schemeid:=public.resolve_assessment_scheme(target_class_id,subjectid,yearid,target_term_id);
      if schemeid is null then raise exception 'Assessment scheme not configured'; end if;
      insert into public.subject_results(report_id,subject_id,scheme_id,teacher_initials,created_by)
      values(reportid,subjectid,schemeid,btrim(coalesce(rowitem->>'teacher_initials','')),auth.uid())
      on conflict(report_id,subject_id) do update set scheme_id=excluded.scheme_id,teacher_initials=excluded.teacher_initials,updated_at=now() returning id into resultid;
      select ac.id,ac.maximum_score into componentid,maxscore from public.assessment_components ac
      where ac.scheme_id=schemeid and lower(ac.code::text)=lower(btrim(rowitem->>'component_code'));
      if componentid is null then raise exception 'Assessment component code not found'; end if;
      raw:=public.safe_numeric(rowitem->>'raw_score');
      if raw is null then raise exception 'Raw score is invalid'; end if;
      if raw<0 or raw>maxscore then raise exception 'Raw score is outside the component maximum'; end if;
      insert into public.assessment_score_entries(subject_result_id,component_id,raw_score,created_by)
      values(resultid,componentid,raw,auth.uid())
      on conflict(subject_result_id,component_id) do update set raw_score=excluded.raw_score,updated_at=now();
      perform public.refresh_subject_result(resultid);
      update public.student_reports set report_number=coalesce(report_number,public.generate_report_number(reportid)),version=version+1,updated_at=now()
      where id=reportid returning version into current_version;
      insert into public.report_revisions(report_id,version,snapshot,reason,actor_id)
      values(reportid,current_version,public.build_report_snapshot(reportid),'Bulk score import',auth.uid())
      on conflict(report_id,version) do update set snapshot=excluded.snapshot,reason=excluded.reason,actor_id=excluded.actor_id,created_at=now();
      ok:=ok+1;
    exception when others then
      failed:=failed+1;
      insert into public.import_errors(batch_id,row_number,payload,error_message) values(batchid,rowno,rowitem,sqlerrm);
    end;
  end loop;
  update public.import_batches set successful_rows=ok,failed_rows=failed,status=case when failed=0 then 'completed' else 'completed_with_errors' end,completed_at=now() where id=batchid;
  return jsonb_build_object('batch_id',batchid,'successful',ok,'failed',failed);
end $$;

commit;
