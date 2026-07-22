-- =============================================================================
-- REPORT CARD ENTERPRISE v6.8.1
-- CLASS-TEACHER REPORT CONTROL AND CLASS-LEVEL BULK WORKFLOW
-- Run after 06_schema.sql.
-- =============================================================================

begin;

-- Only the officially assigned class teacher may submit a report for Principal
-- approval. Subject teachers retain score-entry access only.
create or replace function public.can_submit_report(target_report_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.is_assigned_class_teacher(public.report_class_id(target_report_id))
    and exists(
      select 1 from public.student_reports r
      where r.id=target_report_id
        and r.deleted_at is null
        and r.status in ('draft','returned')
    )
$$;

-- Publication is restricted to the System Administrator or the officially
-- assigned class teacher for the report's class.
create or replace function public.can_publish_report(target_report_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.is_system_admin()
    or public.is_assigned_class_teacher(public.report_class_id(target_report_id))
$$;

-- Central workflow authorization used by both individual and bulk actions.
create or replace function public.allowed_report_transitions(target_report_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  current_status public.report_status;
  result text[] := '{}'::text[];
begin
  select r.status into current_status
  from public.student_reports r
  where r.id=target_report_id and r.deleted_at is null;

  if current_status is null then return result; end if;

  if current_status in ('draft','returned') and public.can_submit_report(target_report_id) then
    result := array_append(result,'submitted');
  end if;

  if current_status in ('submitted','class_reviewed') and public.current_app_role()='principal' then
    result := array_append(result,'approved');
  end if;

  if current_status in ('submitted','class_reviewed','approved','published')
     and public.current_app_role()='principal' then
    result := array_append(result,'returned');
  end if;

  if current_status='approved' and public.can_publish_report(target_report_id) then
    result := array_append(result,'published');
  end if;

  if current_status='published' and public.is_system_admin() then
    result := array_append(result,'withdrawn');
  end if;

  return result;
end $$;

-- Apply one permitted workflow transition to every eligible report in a
-- selected class and term. Each report is validated by transition_report_status,
-- including subject and required-score completeness checks.
create or replace function public.bulk_transition_class_reports(
  target_term_id uuid,
  target_class_id uuid,
  target_status public.report_status,
  comment_text text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  source_statuses public.report_status[];
  report_row record;
  class_name_text text;
  term_name_text text;
  target_year_id uuid;
  total_reports integer := 0;
  candidate_reports integer := 0;
  transitioned_reports integer := 0;
  failed_reports integer := 0;
  already_target_status integer := 0;
  other_status_reports integer := 0;
  missing_reports integer := 0;
  transitioned_ids jsonb := '[]'::jsonb;
  failures jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if target_term_id is null or target_class_id is null then raise exception 'A term and class must be selected'; end if;

  select c.name into class_name_text
  from public.classes c
  where c.id=target_class_id and c.active and c.deleted_at is null;
  if class_name_text is null then raise exception 'The selected class is unavailable'; end if;

  select t.name,t.academic_year_id into term_name_text,target_year_id
  from public.terms t
  where t.id=target_term_id and t.deleted_at is null;
  if term_name_text is null then raise exception 'The selected term is unavailable'; end if;

  case target_status
    when 'submitted' then
      if not public.is_assigned_class_teacher(target_class_id) then
        raise exception 'Only the assigned class teacher can submit reports for this class' using errcode='42501';
      end if;
      source_statuses := array['draft','returned']::public.report_status[];
    when 'approved' then
      if public.current_app_role()<>'principal' then
        raise exception 'Only the Principal can approve reports' using errcode='42501';
      end if;
      perform public.require_sensitive_access();
      source_statuses := array['submitted','class_reviewed']::public.report_status[];
    when 'published' then
      if not (public.is_system_admin() or public.is_assigned_class_teacher(target_class_id)) then
        raise exception 'Only the assigned class teacher or System Administrator can publish reports for this class' using errcode='42501';
      end if;
      perform public.require_sensitive_access();
      source_statuses := array['approved']::public.report_status[];
    else
      raise exception 'Bulk workflow supports submit, approve, or publish only';
  end case;

  select count(*) into total_reports
  from public.student_reports r
  join public.enrollments e on e.id=r.enrollment_id
  where r.term_id=target_term_id
    and e.class_id=target_class_id
    and r.deleted_at is null
    and e.deleted_at is null;

  select count(*) into already_target_status
  from public.student_reports r
  join public.enrollments e on e.id=r.enrollment_id
  where r.term_id=target_term_id
    and e.class_id=target_class_id
    and r.deleted_at is null
    and e.deleted_at is null
    and r.status=target_status;

  select count(*) into missing_reports
  from public.enrollments e
  join public.students s on s.id=e.student_id and s.deleted_at is null
  where e.academic_year_id=target_year_id
    and e.class_id=target_class_id
    and e.deleted_at is null
    and not exists(
      select 1 from public.student_reports r
      where r.enrollment_id=e.id
        and r.term_id=target_term_id
        and r.deleted_at is null
    );

  for report_row in
    select r.id,r.version,r.report_number,r.status,
      concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name) student_name
    from public.student_reports r
    join public.enrollments e on e.id=r.enrollment_id
    join public.students s on s.id=e.student_id
    where r.term_id=target_term_id
      and e.class_id=target_class_id
      and r.deleted_at is null
      and e.deleted_at is null
      and r.status=any(source_statuses)
    order by lower(concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name)),s.admission_no::text
  loop
    candidate_reports := candidate_reports+1;
    begin
      perform public.transition_report_status(
        report_row.id,
        target_status,
        coalesce(nullif(btrim(comment_text),''),'Bulk class workflow transition'),
        report_row.version
      );
      transitioned_reports := transitioned_reports+1;
      transitioned_ids := transitioned_ids || jsonb_build_array(report_row.id);
    exception when others then
      failed_reports := failed_reports+1;
      failures := failures || jsonb_build_array(jsonb_build_object(
        'report_id',report_row.id,
        'report_number',report_row.report_number,
        'student_name',report_row.student_name,
        'from_status',report_row.status,
        'error',sqlerrm
      ));
    end;
  end loop;

  other_status_reports := greatest(total_reports-candidate_reports-already_target_status,0);

  return jsonb_build_object(
    'class_id',target_class_id,
    'class_name',class_name_text,
    'term_id',target_term_id,
    'term_name',term_name_text,
    'target_status',target_status,
    'total_reports',total_reports,
    'candidate_reports',candidate_reports,
    'transitioned_reports',transitioned_reports,
    'failed_reports',failed_reports,
    'already_target_status',already_target_status,
    'other_status_reports',other_status_reports,
    'missing_reports',missing_reports,
    'transitioned_report_ids',transitioned_ids,
    'failures',failures
  );
end $$;

-- Publish capability is no longer exposed to subject teachers. Dedicated bulk
-- flags allow the frontend to show only the actions permitted for each role.
create or replace function public.get_bootstrap_data()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare p jsonb;v_current_role text;current_year uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  current_year:=public.sync_current_academic_year_status();
  update public.profiles set last_seen_at=now() where id=auth.uid();
  v_current_role:=public.current_app_role()::text;
  if v_current_role is null or v_current_role not in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian') then raise exception 'Active supported profile not found' using errcode='42501'; end if;
  select jsonb_build_object('id',pr.id,'full_name',pr.full_name,'role',v_current_role,'active',pr.active,'mfa_required',pr.mfa_required,'must_change_password',pr.must_change_password,'phone',pr.phone)
  into p from public.profiles pr where pr.id=auth.uid() and pr.active;
  return jsonb_build_object(
    'profile',p,
    'school',(select to_jsonb(s) from public.school_settings s limit 1),
    'academic_years',coalesce((select jsonb_agg(to_jsonb(y) order by y.start_date desc nulls last,y.name) from public.academic_years y where y.deleted_at is null),'[]'::jsonb),
    'terms',coalesce((select jsonb_agg(to_jsonb(t) order by t.sequence) from public.terms t where t.deleted_at is null),'[]'::jsonb),
    'classes',case when v_current_role='parent_guardian' then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null and (v_current_role in ('system_admin','principal') or public.can_access_class(c.id,false))),'[]'::jsonb) end,
    'subjects',case when v_current_role='parent_guardian' then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(s) order by s.display_order,s.name) from public.subjects s where s.deleted_at is null and s.active),'[]'::jsonb) end,
    'permissions',jsonb_build_object(
      'manage_users',v_current_role='system_admin',
      'manage_teachers',v_current_role='system_admin',
      'manage_headteachers',v_current_role='system_admin',
      'manage_academics',v_current_role='system_admin',
      'manage_students',v_current_role='system_admin',
      'remove_students',v_current_role='system_admin',
      'create_reports',v_current_role in ('class_teacher','subject_teacher'),
      'import_scores',v_current_role in ('class_teacher','subject_teacher'),
      'approve_reports',v_current_role='principal',
      'publish_reports',v_current_role in ('system_admin','class_teacher'),
      'bulk_submit_reports',v_current_role='class_teacher',
      'bulk_approve_reports',v_current_role='principal',
      'bulk_publish_reports',v_current_role in ('system_admin','class_teacher'),
      'remove_reports',v_current_role in ('system_admin','class_teacher','subject_teacher'),
      'restore_reports',v_current_role='system_admin',
      'view_audit',v_current_role='system_admin',
      'run_backup',v_current_role='system_admin',
      'parent_portal',v_current_role='parent_guardian'
    ),
    'topics',to_jsonb(public.my_realtime_topics())
  );
end $$;

revoke all on function public.can_submit_report(uuid) from public,anon,authenticated;
revoke all on function public.can_publish_report(uuid) from public,anon,authenticated;
revoke all on function public.bulk_transition_class_reports(uuid,uuid,public.report_status,text) from public,anon;
grant execute on function public.bulk_transition_class_reports(uuid,uuid,public.report_status,text) to authenticated;

-- Verification marker.
do $$
begin
  if to_regprocedure('public.can_submit_report(uuid)') is null
     or to_regprocedure('public.bulk_transition_class_reports(uuid,uuid,public.report_status,text)') is null then
    raise exception 'v6.8.1 report workflow upgrade verification failed';
  end if;
end $$;

commit;

select '07 SCHEMA: PASS' as status;

-- =============================================================================
-- REPORT CARD ENTERPRISE v6.8.2
-- REPORT PDF AND TEMPLATE STORAGE AUTHORIZATION HOTFIX
-- Continue in 07_schema.sql. Run after the v6.8.1 section above.
-- =============================================================================

begin;

-- v6.8.1 correctly restricted publication decisions inside this function, but
-- also removed EXECUTE from authenticated users. Supabase Storage RLS policies
-- invoke the function while evaluating report-pdf object writes, so the missing
-- privilege caused "permission denied for function can_publish_report". Because
-- PostgreSQL does not guarantee boolean-expression evaluation order, the same
-- report-pdf policy could also be considered during template uploads.
revoke all on function public.can_publish_report(uuid) from public,anon;
grant execute on function public.can_publish_report(uuid) to authenticated;
grant execute on function public.can_publish_report(uuid) to service_role;

-- Recreate report PDF policies with bucket-gated CASE expressions. CASE ensures
-- report-specific authorization functions are evaluated only for report-pdfs.
drop policy if exists report_pdfs_read on storage.objects;
create policy report_pdfs_read on storage.objects for select to authenticated
using(
  case when bucket_id='report-pdfs'
    then public.can_view_report(public.safe_uuid((storage.foldername(name))[1]))
    else false
  end
);

drop policy if exists report_pdfs_write on storage.objects;
create policy report_pdfs_write on storage.objects for insert to authenticated
with check(
  case when bucket_id='report-pdfs'
    then public.can_publish_report(public.safe_uuid((storage.foldername(name))[1]))
    else false
  end
);

drop policy if exists report_pdfs_update on storage.objects;
create policy report_pdfs_update on storage.objects for update to authenticated
using(
  case when bucket_id='report-pdfs'
    then public.can_publish_report(public.safe_uuid((storage.foldername(name))[1]))
    else false
  end
)
with check(
  case when bucket_id='report-pdfs'
    then public.can_publish_report(public.safe_uuid((storage.foldername(name))[1]))
    else false
  end
);

drop policy if exists report_pdfs_delete on storage.objects;
create policy report_pdfs_delete on storage.objects for delete to authenticated
using(
  case when bucket_id='report-pdfs'
    then public.can_delete_report(public.safe_uuid((storage.foldername(name))[1]))
    else false
  end
);

-- Apply the same deterministic bucket gating to administrator template writes.
-- This isolates template uploads from every unrelated Storage policy.
drop policy if exists report_card_templates_storage_read on storage.objects;
create policy report_card_templates_storage_read on storage.objects for select to authenticated
using(bucket_id='report-card-templates');

drop policy if exists report_card_templates_storage_insert on storage.objects;
create policy report_card_templates_storage_insert on storage.objects for insert to authenticated
with check(
  case when bucket_id='report-card-templates' then
    public.is_system_admin()
    and (storage.foldername(name))[1] in ('early_years','basic_1_6','basic_7_9')
  else false end
);

drop policy if exists report_card_templates_storage_update on storage.objects;
create policy report_card_templates_storage_update on storage.objects for update to authenticated
using(
  case when bucket_id='report-card-templates'
    then public.is_system_admin()
    else false
  end
)
with check(
  case when bucket_id='report-card-templates' then
    public.is_system_admin()
    and (storage.foldername(name))[1] in ('early_years','basic_1_6','basic_7_9')
  else false end
);

drop policy if exists report_card_templates_storage_delete on storage.objects;
create policy report_card_templates_storage_delete on storage.objects for delete to authenticated
using(
  case when bucket_id='report-card-templates'
    then public.is_system_admin()
    else false
  end
);

-- Deployment verification. This deliberately checks the privilege that caused
-- the production failure and the Storage policies required by both workflows.
do $$
begin
  if not has_function_privilege('authenticated','public.can_publish_report(uuid)','EXECUTE') then
    raise exception 'v6.8.2 verification failed: authenticated cannot execute can_publish_report';
  end if;

  if not exists(
    select 1 from pg_policies
    where schemaname='storage' and tablename='objects'
      and policyname='report_pdfs_write' and cmd='INSERT'
  ) then
    raise exception 'v6.8.2 verification failed: report PDF insert policy is missing';
  end if;

  if not exists(
    select 1 from pg_policies
    where schemaname='storage' and tablename='objects'
      and policyname='report_card_templates_storage_insert' and cmd='INSERT'
  ) then
    raise exception 'v6.8.2 verification failed: template insert policy is missing';
  end if;
end $$;

commit;

select '07 SCHEMA v6.8.2 PDF/TEMPLATE STORAGE FIX: PASS' as status;


-- =============================================================================
-- REPORT CARD ENTERPRISE v6.9.0
-- PLATFORM SUPER ADMINISTRATOR AND LICENSING CONTROL PLANE
-- Continue in 07_schema.sql. Run after the v6.8.2 section above.
-- =============================================================================

-- Add the platform role in its own committed transaction so PostgreSQL can use
-- the new enum value safely in the functions and policies that follow.
begin;
do $$
begin
  if not exists (
    select 1
    from pg_enum e
    join pg_type t on t.oid=e.enumtypid
    where t.typnamespace='public'::regnamespace
      and t.typname='app_role'
      and e.enumlabel='platform_super_admin'
  ) then
    alter type public.app_role add value 'platform_super_admin';
  end if;
end $$;
commit;

begin;

-- Recognize the isolated platform role without changing any school-role aliases.
create or replace function public.current_app_role()
returns public.app_role
language sql
stable
security definer
set search_path=public
as $$
  select case
    when p.role='admin' then 'system_admin'::public.app_role
    when p.role='teacher' then 'class_teacher'::public.app_role
    when p.role='headteacher' then 'principal'::public.app_role
    else p.role
  end
  from public.profiles p
  where p.id=auth.uid() and p.active
    and p.role in ('admin','teacher','headteacher','system_admin','principal','class_teacher','subject_teacher','parent_guardian','platform_super_admin')
$$;

-- -----------------------------------------------------------------------------
-- 1. Platform licensing data model
-- -----------------------------------------------------------------------------
create table if not exists public.license_plans (
  id uuid primary key default gen_random_uuid(),
  code citext not null unique,
  name text not null,
  description text not null default '',
  billing_cycle text not null default 'annual'
    check (billing_cycle in ('monthly','annual','perpetual','custom')),
  max_students integer check (max_students is null or max_students > 0),
  max_teachers integer check (max_teachers is null or max_teachers > 0),
  max_system_admins integer check (max_system_admins is null or max_system_admins > 0),
  feature_flags jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.school_licenses (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.license_plans(id) on delete restrict,
  license_reference text not null unique,
  license_key_hash text not null default '',
  license_key_hint text not null default '',
  status text not null default 'pending_activation'
    check (status in ('pending_activation','active','grace_period','expired','suspended','revoked','perpetual')),
  issued_on date not null default current_date,
  activated_at timestamptz,
  expires_at timestamptz,
  grace_ends_at timestamptz,
  compliance_reason text not null default '',
  notes text not null default '',
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint school_license_dates_chk check (
    (activated_at is null or activated_at::date >= issued_on)
    and (expires_at is null or activated_at is null or expires_at >= activated_at)
    and (grace_ends_at is null or expires_at is null or grace_ends_at >= expires_at)
  )
);
create unique index if not exists school_licenses_singleton_idx on public.school_licenses ((true));

create table if not exists public.platform_access_locks (
  id uuid primary key default gen_random_uuid(),
  lock_scope text not null check (lock_scope in ('system_admin','school','platform')),
  lock_mode text not null check (lock_mode in ('read_only','deny')),
  reason text not null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  released_by uuid references public.profiles(id) on delete set null,
  released_at timestamptz,
  release_reason text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint platform_access_lock_dates_chk check (ends_at is null or ends_at > starts_at)
);
create index if not exists platform_access_locks_active_idx
  on public.platform_access_locks(active,starts_at desc,ends_at);

create table if not exists public.license_events (
  id bigint generated always as identity primary key,
  license_id uuid references public.school_licenses(id) on delete set null,
  event_type text not null,
  actor_id uuid references public.profiles(id) on delete set null,
  event_reason text not null default '',
  old_data jsonb not null default '{}'::jsonb,
  new_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists license_events_created_idx on public.license_events(created_at desc);

create table if not exists public.license_verification_logs (
  id bigint generated always as identity primary key,
  license_id uuid references public.school_licenses(id) on delete set null,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_role text not null default '',
  computed_status text not null,
  access_mode text not null,
  verification_source text not null default 'bootstrap',
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists license_verification_created_idx
  on public.license_verification_logs(created_at desc);

-- Seed practical plans. NULL limits mean unlimited.
insert into public.license_plans(code,name,description,billing_cycle,max_students,max_teachers,max_system_admins,feature_flags)
values
  ('starter','Starter','Core report cards for a small school.','annual',300,30,2,
   '{"report_cards":true,"attendance":true,"templates":true,"backups":true,"bulk_workflow":true}'::jsonb),
  ('professional','Professional','Expanded capacity for a growing school.','annual',1000,100,5,
   '{"report_cards":true,"attendance":true,"templates":true,"backups":true,"bulk_workflow":true,"priority_support":true}'::jsonb),
  ('enterprise','Enterprise','Unlimited school capacity and the complete feature set.','custom',null,null,null,
   '{"report_cards":true,"attendance":true,"templates":true,"backups":true,"bulk_workflow":true,"priority_support":true,"custom_branding":true}'::jsonb)
on conflict(code) do update set
  name=excluded.name,
  description=excluded.description,
  billing_cycle=excluded.billing_cycle,
  max_students=excluded.max_students,
  max_teachers=excluded.max_teachers,
  max_system_admins=excluded.max_system_admins,
  feature_flags=excluded.feature_flags,
  active=true,
  updated_at=now();

-- Existing installations receive a perpetual Enterprise licence so this
-- upgrade never interrupts a confirmed production deployment.
insert into public.school_licenses(
  plan_id,license_reference,license_key_hash,license_key_hint,status,
  issued_on,activated_at,expires_at,grace_ends_at,notes
)
select p.id,
  'RCE-'||upper(substr(encode(gen_random_bytes(12),'hex'),1,20)),
  encode(digest(encode(gen_random_bytes(32),'hex'),'sha256'),'hex'),
  upper(substr(encode(gen_random_bytes(4),'hex'),1,8)),
  'perpetual',current_date,now(),null,null,
  'Automatic perpetual Enterprise licence created during the v6.9.0 upgrade to preserve existing production access.'
from public.license_plans p
where p.code='enterprise'
  and not exists(select 1 from public.school_licenses);

insert into public.license_events(license_id,event_type,event_reason,new_data)
select l.id,'license_initialized','Safe perpetual Enterprise licence created for the existing installation',to_jsonb(l)-'license_key_hash'
from public.school_licenses l
where not exists(select 1 from public.license_events e where e.license_id=l.id and e.event_type='license_initialized');

-- Standard timestamp maintenance.
drop trigger if exists license_plans_set_updated_at on public.license_plans;
create trigger license_plans_set_updated_at before update on public.license_plans
for each row execute function public.set_updated_at();

drop trigger if exists school_licenses_set_updated_at on public.school_licenses;
create trigger school_licenses_set_updated_at before update on public.school_licenses
for each row execute function public.set_updated_at();

drop trigger if exists platform_access_locks_set_updated_at on public.platform_access_locks;
create trigger platform_access_locks_set_updated_at before update on public.platform_access_locks
for each row execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- 2. Platform role, MFA, and immutable history safeguards
-- -----------------------------------------------------------------------------
create or replace function public.is_platform_super_admin()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select coalesce(public.current_app_role()::text='platform_super_admin',false)
$$;

create or replace function public.require_platform_super_admin()
returns void
language plpgsql
stable
security definer
set search_path=public
as $$
begin
  if not public.is_platform_super_admin() then
    raise exception 'Platform Super Administrator access required' using errcode='42501';
  end if;
  if public.current_aal()<>'aal2' then
    raise exception 'Multi-factor authentication is required for platform licensing actions' using errcode='42501';
  end if;
end $$;

create or replace function public.protect_profile_security_fields()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.role='platform_super_admin'::public.app_role then
    new.mfa_required:=true;
  end if;

  -- A school browser session must never create, demote, deactivate, or weaken a
  -- Platform Super Administrator. Provisioning is deliberately limited to the
  -- protected SQL setup path, where auth.role() is not an authenticated user.
  if auth.role()='authenticated'
     and (old.role='platform_super_admin'::public.app_role or new.role='platform_super_admin'::public.app_role)
     and (new.role is distinct from old.role
       or new.active is distinct from old.active
       or new.mfa_required is distinct from old.mfa_required
       or new.must_change_password is distinct from old.must_change_password) then
    raise exception 'Platform Super Administrator security fields require the protected setup path' using errcode='42501';
  end if;

  -- Browser users may update ordinary personal details only. Role, activation,
  -- MFA policy and forced-password state are controlled by trusted admin paths.
  if auth.role()='authenticated' and auth.uid()=old.id then
    if new.role is distinct from old.role
       or new.active is distinct from old.active
       or new.mfa_required is distinct from old.mfa_required
       or new.must_change_password is distinct from old.must_change_password then
      raise exception 'Profile security fields cannot be changed by the account owner' using errcode='42501';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists profiles_protect_security_fields on public.profiles;
create trigger profiles_protect_security_fields
before update on public.profiles
for each row execute function public.protect_profile_security_fields();

create or replace function public.prevent_license_history_mutation()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if auth.role() in ('service_role','supabase_admin') or auth.role() is null then
    return case when tg_op='DELETE' then old else new end;
  end if;
  raise exception 'Licensing history is append-only' using errcode='42501';
end $$;

drop trigger if exists license_events_immutable on public.license_events;
create trigger license_events_immutable before update or delete on public.license_events
for each row execute function public.prevent_license_history_mutation();

drop trigger if exists license_verification_logs_immutable on public.license_verification_logs;
create trigger license_verification_logs_immutable before update or delete on public.license_verification_logs
for each row execute function public.prevent_license_history_mutation();

-- -----------------------------------------------------------------------------
-- 3. Effective licence and access-state calculation
-- -----------------------------------------------------------------------------
create or replace function public.license_snapshot_for_role(target_role text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_role text:=coalesce(nullif(target_role,''),public.current_app_role()::text,'');
  v_license public.school_licenses%rowtype;
  v_plan public.license_plans%rowtype;
  v_lock public.platform_access_locks%rowtype;
  v_status text;
  v_access_mode text:='full';
  v_read_allowed boolean:=true;
  v_write_allowed boolean:=true;
  v_now timestamptz:=now();
  v_days_remaining integer;
  v_warning text:='';
begin
  select * into v_license from public.school_licenses order by created_at limit 1;
  if v_license.id is null then
    return jsonb_build_object(
      'configured',false,'computed_status','unlicensed','access_mode','locked',
      'read_allowed',v_role='platform_super_admin','write_allowed',false,
      'access_locked',true,'warning','No platform licence is configured.'
    );
  end if;

  select * into v_plan from public.license_plans where id=v_license.plan_id;

  select * into v_lock
  from public.platform_access_locks l
  where l.active and l.starts_at<=v_now and (l.ends_at is null or l.ends_at>v_now)
    and (l.lock_scope in ('platform','school') or (l.lock_scope='system_admin' and v_role='system_admin'))
  order by
    case l.lock_mode when 'deny' then 2 else 1 end desc,
    case l.lock_scope when 'platform' then 3 when 'school' then 2 else 1 end desc,
    l.created_at desc
  limit 1;

  v_status:=v_license.status;
  if v_status='active' then
    if v_license.activated_at is null or v_license.activated_at>v_now then
      v_status:='pending_activation';
    elsif v_license.expires_at is not null and v_license.expires_at<v_now then
      if v_license.grace_ends_at is not null and v_license.grace_ends_at>=v_now then
        v_status:='grace_period';
      else
        v_status:='expired';
      end if;
    end if;
  elsif v_status='grace_period' and v_license.grace_ends_at is not null and v_license.grace_ends_at<v_now then
    v_status:='expired';
  end if;

  if v_license.expires_at is not null then
    v_days_remaining:=floor(extract(epoch from (v_license.expires_at-v_now))/86400)::integer;
  end if;

  if v_role='platform_super_admin' then
    -- Platform administrators use only the licensing control plane, not school
    -- academic data. Their licensing RPCs remain available even during a lock.
    v_access_mode:='platform_control';
    v_read_allowed:=false;
    v_write_allowed:=false;
  elsif v_status='revoked' then
    v_access_mode:='locked';v_read_allowed:=false;v_write_allowed:=false;
    v_warning:=coalesce(nullif(v_license.compliance_reason,''),'The platform licence has been revoked.');
  elsif v_lock.id is not null
    and v_lock.lock_mode='deny'
    and (v_lock.lock_scope in ('platform','school') or (v_lock.lock_scope='system_admin' and v_role='system_admin')) then
    v_access_mode:='locked';v_read_allowed:=false;v_write_allowed:=false;
    v_warning:=v_lock.reason;
  elsif v_status in ('pending_activation','expired','suspended') then
    v_access_mode:='read_only';v_read_allowed:=true;v_write_allowed:=false;
    v_warning:=case v_status
      when 'pending_activation' then 'The licence is awaiting activation. The system is available in read-only mode.'
      when 'expired' then 'The licence has expired. Existing records and backups remain available in read-only mode.'
      else coalesce(nullif(v_license.compliance_reason,''),'The licence is suspended. The system is available in read-only mode.') end;
  elsif v_lock.id is not null
    and v_lock.lock_mode='read_only'
    and (v_lock.lock_scope in ('platform','school') or (v_lock.lock_scope='system_admin' and v_role='system_admin')) then
    v_access_mode:='read_only';v_read_allowed:=true;v_write_allowed:=false;
    v_warning:=v_lock.reason;
  elsif v_status='grace_period' then
    v_warning:='The licence is in its grace period. Renew before the grace period ends.';
  elsif v_status='active' and v_days_remaining is not null and v_days_remaining between 0 and 30 then
    v_warning:='The licence expires in '||v_days_remaining||' day'||case when v_days_remaining=1 then '' else 's' end||'.';
  end if;

  return jsonb_build_object(
    'configured',true,
    'license_id',v_license.id,
    'license_reference',v_license.license_reference,
    'stored_status',v_license.status,
    'computed_status',v_status,
    'issued_on',v_license.issued_on,
    'activated_at',v_license.activated_at,
    'expires_at',v_license.expires_at,
    'grace_ends_at',v_license.grace_ends_at,
    'compliance_reason',v_license.compliance_reason,
    'plan',jsonb_build_object(
      'id',v_plan.id,'code',v_plan.code,'name',v_plan.name,'description',v_plan.description,
      'billing_cycle',v_plan.billing_cycle,'max_students',v_plan.max_students,
      'max_teachers',v_plan.max_teachers,'max_system_admins',v_plan.max_system_admins,
      'feature_flags',v_plan.feature_flags
    ),
    'access_mode',v_access_mode,
    'read_allowed',v_read_allowed,
    'write_allowed',v_write_allowed,
    'access_locked',v_access_mode='locked',
    'access_lock_status',coalesce(v_lock.lock_scope||':'||v_lock.lock_mode,'unlocked'),
    'active_lock',case when v_lock.id is null then null else jsonb_build_object(
      'id',v_lock.id,'scope',v_lock.lock_scope,'mode',v_lock.lock_mode,
      'reason',v_lock.reason,'starts_at',v_lock.starts_at,'ends_at',v_lock.ends_at
    ) end,
    'days_remaining',v_days_remaining,
    'warning',v_warning
  );
end $$;

create or replace function public.license_read_allowed()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select case
    when auth.role() in ('service_role','supabase_admin') or auth.role() is null then true
    else coalesce((public.license_snapshot_for_role(public.current_app_role()::text)->>'read_allowed')::boolean,false)
  end
$$;

create or replace function public.license_write_allowed()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select case
    when auth.role() in ('service_role','supabase_admin') or auth.role() is null then true
    else coalesce((public.license_snapshot_for_role(public.current_app_role()::text)->>'write_allowed')::boolean,false)
  end
$$;

create or replace function public.license_access_for_actor(actor_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare actor_role text;
begin
  select public.current_app_role_for(p.role) into actor_role
  from public.profiles p where p.id=actor_id and p.active;
  if actor_role is null then
    return jsonb_build_object('read_allowed',false,'write_allowed',false,'access_mode','locked');
  end if;
  return public.license_snapshot_for_role(actor_role);
end $$;

create or replace function public.enforce_licensed_write()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_snapshot jsonb;
  v_limit integer;
  v_count integer;
  v_becoming_active boolean:=false;
begin
  if auth.role() in ('service_role','supabase_admin') or auth.role() is null then
    if tg_op='DELETE' then return old; else return new; end if;
  end if;

  v_snapshot:=public.license_snapshot_for_role(public.current_app_role()::text);
  if not coalesce((v_snapshot->>'write_allowed')::boolean,false) then
    raise exception 'LICENSE_WRITE_RESTRICTED: %',coalesce(nullif(v_snapshot->>'warning',''),'The current licence or access lock does not permit changes.') using errcode='42501';
  end if;

  -- Capacity controls apply only when a record is inserted as active or changes
  -- from inactive/archived to active. Nested branches avoid reading OLD during
  -- INSERT or NEW during DELETE.
  if tg_op<>'DELETE' and tg_table_name='students' then
    if new.status='active' and new.deleted_at is null then
      if tg_op='INSERT' then
        v_becoming_active:=true;
      else
        v_becoming_active:=old.status is distinct from new.status or old.deleted_at is distinct from new.deleted_at;
      end if;
    end if;
    if v_becoming_active then
      v_limit:=nullif(v_snapshot#>>'{plan,max_students}','')::integer;
      if v_limit is not null then
        select count(*) into v_count from public.students s
        where s.status='active' and s.deleted_at is null
          and (tg_op='INSERT' or s.id<>new.id);
        if v_count>=v_limit then
          raise exception 'LICENSE_CAPACITY_REACHED: The plan permits a maximum of % active students',v_limit using errcode='23514';
        end if;
      end if;
    end if;
  elsif tg_op<>'DELETE' and tg_table_name='teachers' then
    if new.active and new.deleted_at is null then
      if tg_op='INSERT' then
        v_becoming_active:=true;
      else
        v_becoming_active:=old.active is distinct from new.active or old.deleted_at is distinct from new.deleted_at;
      end if;
    end if;
    if v_becoming_active then
      v_limit:=nullif(v_snapshot#>>'{plan,max_teachers}','')::integer;
      if v_limit is not null then
        select count(*) into v_count from public.teachers t
        where t.active and t.deleted_at is null
          and (tg_op='INSERT' or t.id<>new.id);
        if v_count>=v_limit then
          raise exception 'LICENSE_CAPACITY_REACHED: The plan permits a maximum of % active teachers',v_limit using errcode='23514';
        end if;
      end if;
    end if;
  end if;

  if tg_op='DELETE' then return old; else return new; end if;
end $$;

-- Attach server-side enforcement to all core school records, including writes
-- performed inside SECURITY DEFINER workflow functions.
do $$
declare t text;
begin
  foreach t in array array[
    'school_settings','academic_years','terms','classes','subjects','class_subjects',
    'user_class_access','students','student_guardians','guardian_links','enrollments',
    'grading_scales','assessment_schemes','assessment_components','teachers','headteachers',
    'student_reports','subject_scores','subject_results','assessment_score_entries',
    'report_workflow_events','report_revisions','report_publications','report_card_templates',
    'class_attendance_registers','student_attendance_entries','import_batches','import_errors'
  ] loop
    execute format('drop trigger if exists %I_license_write_guard on public.%I',t,t);
    execute format('create trigger %I_license_write_guard before insert or update or delete on public.%I for each row execute function public.enforce_licensed_write()',t,t);
  end loop;
end $$;

-- Restrictive policies add mandatory licensing/compliance guards without
-- replacing the role-specific permissive policies already in the system. Each
-- command has its own guard because PostgreSQL DELETE policies do not evaluate
-- WITH CHECK; read-only mode must therefore require write permission in USING.
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','school_settings','academic_years','terms','classes','subjects','class_subjects',
    'user_class_access','students','student_guardians','guardian_links','enrollments',
    'grading_scales','assessment_schemes','assessment_components','teachers','headteachers',
    'student_reports','subject_scores','subject_results','assessment_score_entries',
    'report_workflow_events','report_revisions','report_publications','report_card_templates',
    'class_attendance_registers','student_attendance_entries','notifications','notification_outbox',
    'import_batches','import_errors','audit_log','client_error_events','system_maintenance_log',
    'backup_exports','backup_storage_objects'
  ] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists platform_license_guard on public.%I',t);
    execute format('drop policy if exists platform_license_select_guard on public.%I',t);
    execute format('drop policy if exists platform_license_insert_guard on public.%I',t);
    execute format('drop policy if exists platform_license_update_guard on public.%I',t);
    execute format('drop policy if exists platform_license_delete_guard on public.%I',t);
    execute format('create policy platform_license_select_guard on public.%I as restrictive for select to authenticated using(public.license_read_allowed())',t);
    execute format('create policy platform_license_insert_guard on public.%I as restrictive for insert to authenticated with check(public.license_write_allowed())',t);
    execute format('create policy platform_license_update_guard on public.%I as restrictive for update to authenticated using(public.license_write_allowed()) with check(public.license_write_allowed())',t);
    execute format('create policy platform_license_delete_guard on public.%I as restrictive for delete to authenticated using(public.license_write_allowed())',t);
  end loop;
end $$;

-- Licence tables are accessible only through audited platform RPC functions.
do $$
declare t text;
begin
  foreach t in array array['license_plans','school_licenses','platform_access_locks','license_events','license_verification_logs'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from anon,authenticated',t);
  end loop;
end $$;
grant all on public.license_plans,public.school_licenses,public.platform_access_locks,public.license_events,public.license_verification_logs to service_role;

-- -----------------------------------------------------------------------------
-- 4. Audited Platform Super Administrator RPCs
-- -----------------------------------------------------------------------------
create or replace function public.get_platform_license_console()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare snapshot jsonb;
begin
  perform public.require_platform_super_admin();
  snapshot:=public.license_snapshot_for_role('system_admin');
  return jsonb_build_object(
    'school',(select jsonb_build_object('id',s.id,'school_name',s.school_name,'logo_url',s.logo_url,'email',s.email,'phone',s.phone) from public.school_settings s limit 1),
    'snapshot',snapshot,
    'license',(select to_jsonb(l)-'license_key_hash' from public.school_licenses l order by l.created_at limit 1),
    'plans',coalesce((select jsonb_agg(to_jsonb(p) order by p.name) from public.license_plans p where p.active),'[]'::jsonb),
    'usage',jsonb_build_object(
      'active_students',(select count(*) from public.students s where s.status='active' and s.deleted_at is null),
      'active_teachers',(select count(*) from public.teachers t where t.active and t.deleted_at is null),
      'active_system_admins',(select count(*) from public.profiles p where p.active and public.current_app_role_for(p.role)='system_admin'),
      'published_reports',(select count(*) from public.student_reports r where r.status='published')
    ),
    'active_locks',coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc) from public.platform_access_locks l where l.active and (l.ends_at is null or l.ends_at>now())),'[]'::jsonb),
    'recent_events',coalesce((select jsonb_agg((to_jsonb(e)||jsonb_build_object('old_data',e.old_data-'license_key_hash','new_data',e.new_data-'license_key_hash')) order by e.created_at desc)
      from (select le.*,coalesce(p.full_name,'System') as actor_name from public.license_events le left join public.profiles p on p.id=le.actor_id order by le.created_at desc limit 100) e),'[]'::jsonb),
    'verification_history',coalesce((select jsonb_agg(to_jsonb(v) order by v.created_at desc) from (select * from public.license_verification_logs order by created_at desc limit 50) v),'[]'::jsonb),
    'platform_admins',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'full_name',p.full_name,'email',u.email,'active',p.active,
      'mfa_required',p.mfa_required,'last_seen_at',p.last_seen_at,'created_at',p.created_at
    ) order by lower(p.full_name),p.id) from public.profiles p left join auth.users u on u.id=p.id
      where public.current_app_role_for(p.role)='platform_super_admin'),'[]'::jsonb)
  );
end $$;

create or replace function public.platform_update_license(
  target_plan_id uuid,
  target_status text,
  issue_date date,
  activation_date timestamptz default null,
  expiry_date timestamptz default null,
  grace_end_date timestamptz default null,
  license_reference_text text default '',
  notes_text text default '',
  compliance_reason_text text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare current_row public.school_licenses%rowtype;updated_row public.school_licenses%rowtype;old_json jsonb;effective_activation timestamptz;
begin
  perform public.require_platform_super_admin();
  if target_status not in ('pending_activation','active','grace_period','expired','suspended','revoked','perpetual') then
    raise exception 'Invalid licence status' using errcode='22023';
  end if;
  if not exists(select 1 from public.license_plans p where p.id=target_plan_id and p.active) then
    raise exception 'Select an active licence plan' using errcode='22023';
  end if;
  if issue_date is null then raise exception 'Issue date is required' using errcode='22023'; end if;
  if length(trim(coalesce(license_reference_text,'')))<5 then
    raise exception 'A valid licence reference is required' using errcode='22023';
  end if;
  if target_status in ('suspended','revoked') and length(trim(coalesce(compliance_reason_text,'')))<5 then
    raise exception 'A clear compliance reason is required for a suspended or revoked licence' using errcode='22023';
  end if;
  effective_activation:=case when target_status in ('active','grace_period','perpetual') then coalesce(activation_date,now()) else activation_date end;
  if effective_activation is not null and effective_activation::date<issue_date then
    raise exception 'Activation date cannot be before the issue date' using errcode='22023';
  end if;
  if expiry_date is not null and expiry_date::date<issue_date then
    raise exception 'Expiry date cannot be before the issue date' using errcode='22023';
  end if;
  if expiry_date is not null and effective_activation is not null and expiry_date<effective_activation then
    raise exception 'Expiry date cannot be before the activation date' using errcode='22023';
  end if;
  if grace_end_date is not null and expiry_date is null then
    raise exception 'An expiry date is required before a grace-period end can be set' using errcode='22023';
  end if;
  if grace_end_date is not null and expiry_date is not null and grace_end_date<expiry_date then
    raise exception 'Grace-period end cannot be before the expiry date' using errcode='22023';
  end if;
  if target_status='perpetual' and expiry_date is not null then
    raise exception 'A perpetual licence cannot have an expiry date' using errcode='22023';
  end if;
  if target_status='grace_period' and (expiry_date is null or grace_end_date is null) then
    raise exception 'Grace-period status requires both an expiry date and a grace-period end' using errcode='22023';
  end if;

  select * into current_row from public.school_licenses order by created_at limit 1 for update;
  old_json:=to_jsonb(current_row);
  update public.school_licenses set
    plan_id=target_plan_id,
    license_reference=coalesce(nullif(trim(license_reference_text),''),license_reference),
    status=target_status,
    issued_on=issue_date,
    activated_at=effective_activation,
    expires_at=case when target_status='perpetual' then null else expiry_date end,
    grace_ends_at=case when target_status='perpetual' then null else grace_end_date end,
    notes=coalesce(notes_text,''),
    compliance_reason=coalesce(compliance_reason_text,''),
    updated_by=auth.uid(),updated_at=now()
  where id=current_row.id returning * into updated_row;

  insert into public.license_events(license_id,event_type,actor_id,event_reason,old_data,new_data)
  values(updated_row.id,'license_updated',auth.uid(),coalesce(nullif(compliance_reason_text,''),'Platform licence updated'),old_json-'license_key_hash',to_jsonb(updated_row)-'license_key_hash');

  return public.get_platform_license_console();
end $$;

create or replace function public.platform_set_access_lock(
  lock_scope_text text,
  lock_mode_text text,
  reason_text text,
  ends_at_value timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare new_lock public.platform_access_locks%rowtype;license_id_value uuid;
begin
  perform public.require_platform_super_admin();
  if lock_scope_text not in ('system_admin','school','platform') then raise exception 'Invalid lock scope' using errcode='22023'; end if;
  if lock_mode_text not in ('read_only','deny') then raise exception 'Invalid lock mode' using errcode='22023'; end if;
  if length(trim(coalesce(reason_text,'')))<5 then raise exception 'A clear lock reason is required' using errcode='22023'; end if;
  if ends_at_value is not null and ends_at_value<=now() then raise exception 'Lock end time must be in the future' using errcode='22023'; end if;

  update public.platform_access_locks set active=false,released_at=now(),released_by=auth.uid(),release_reason='Replaced by a new lock',updated_at=now()
  where active and lock_scope=lock_scope_text;

  insert into public.platform_access_locks(lock_scope,lock_mode,reason,ends_at,created_by)
  values(lock_scope_text,lock_mode_text,trim(reason_text),ends_at_value,auth.uid()) returning * into new_lock;
  select id into license_id_value from public.school_licenses order by created_at limit 1;
  insert into public.license_events(license_id,event_type,actor_id,event_reason,new_data)
  values(license_id_value,'access_lock_applied',auth.uid(),trim(reason_text),to_jsonb(new_lock));
  return public.get_platform_license_console();
end $$;

create or replace function public.platform_release_access_lock(
  target_lock_id uuid,
  reason_text text default 'Access lock released'
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare old_lock public.platform_access_locks%rowtype;license_id_value uuid;
begin
  perform public.require_platform_super_admin();
  select * into old_lock from public.platform_access_locks where id=target_lock_id and active for update;
  if old_lock.id is null then raise exception 'Active access lock not found' using errcode='P0002'; end if;
  update public.platform_access_locks set active=false,released_at=now(),released_by=auth.uid(),release_reason=coalesce(nullif(trim(reason_text),''),'Access lock released'),updated_at=now()
  where id=target_lock_id;
  select id into license_id_value from public.school_licenses order by created_at limit 1;
  insert into public.license_events(license_id,event_type,actor_id,event_reason,old_data)
  values(license_id_value,'access_lock_released',auth.uid(),coalesce(nullif(trim(reason_text),''),'Access lock released'),to_jsonb(old_lock));
  return public.get_platform_license_console();
end $$;

-- -----------------------------------------------------------------------------
-- 5. Licence-aware bootstrap and server-side portal isolation
-- -----------------------------------------------------------------------------
create or replace function public.get_bootstrap_data()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  p jsonb;
  v_current_role text;
  current_year uuid;
  v_license jsonb;
  v_write_allowed boolean:=false;
  v_read_allowed boolean:=false;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  v_current_role:=public.current_app_role()::text;
  if v_current_role is null or v_current_role not in ('platform_super_admin','system_admin','principal','class_teacher','subject_teacher','parent_guardian') then
    raise exception 'Active supported profile not found' using errcode='42501';
  end if;

  v_license:=public.license_snapshot_for_role(v_current_role);
  v_write_allowed:=coalesce((v_license->>'write_allowed')::boolean,false);
  v_read_allowed:=coalesce((v_license->>'read_allowed')::boolean,false);

  if v_current_role<>'platform_super_admin' and not v_read_allowed then
    insert into public.license_verification_logs(license_id,actor_id,actor_role,computed_status,access_mode,details)
    values(public.safe_uuid(v_license->>'license_id'),auth.uid(),v_current_role,coalesce(v_license->>'computed_status','unknown'),coalesce(v_license->>'access_mode','locked'),v_license);
    raise exception 'PLATFORM_ACCESS_LOCKED: %',coalesce(nullif(v_license->>'warning',''),'Access has been restricted by the platform licence administrator.') using errcode='42501';
  end if;

  if v_current_role<>'platform_super_admin' and v_write_allowed then
    current_year:=public.sync_current_academic_year_status();
    update public.profiles set last_seen_at=now() where id=auth.uid();
  elsif v_current_role='platform_super_admin' then
    update public.profiles set last_seen_at=now() where id=auth.uid();
  end if;

  select jsonb_build_object(
    'id',pr.id,'full_name',pr.full_name,'role',v_current_role,'active',pr.active,
    'mfa_required',case when v_current_role='platform_super_admin' then true else pr.mfa_required end,
    'must_change_password',pr.must_change_password,'phone',pr.phone
  ) into p from public.profiles pr where pr.id=auth.uid() and pr.active;

  if not exists(
    select 1 from public.license_verification_logs v
    where v.actor_id=auth.uid()
      and v.computed_status=coalesce(v_license->>'computed_status','unknown')
      and v.access_mode=coalesce(v_license->>'access_mode','unknown')
      and v.created_at>now()-interval '15 minutes'
  ) then
    insert into public.license_verification_logs(license_id,actor_id,actor_role,computed_status,access_mode,details)
    values(public.safe_uuid(v_license->>'license_id'),auth.uid(),v_current_role,coalesce(v_license->>'computed_status','unknown'),coalesce(v_license->>'access_mode','unknown'),
      jsonb_build_object('write_allowed',v_write_allowed,'read_allowed',v_read_allowed));
  end if;

  return jsonb_build_object(
    'profile',p,
    'school',case when v_current_role='platform_super_admin'
      then (select jsonb_build_object('id',s.id,'school_name',s.school_name,'logo_url',s.logo_url,'primary_colour',s.primary_colour,'accent_colour',s.accent_colour) from public.school_settings s limit 1)
      else (select to_jsonb(s) from public.school_settings s limit 1) end,
    'academic_years',case when v_current_role='platform_super_admin' then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(y) order by y.start_date desc nulls last,y.name) from public.academic_years y where y.deleted_at is null),'[]'::jsonb) end,
    'terms',case when v_current_role='platform_super_admin' then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(t) order by t.sequence) from public.terms t where t.deleted_at is null),'[]'::jsonb) end,
    'classes',case when v_current_role in ('platform_super_admin','parent_guardian') then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null and (v_current_role in ('system_admin','principal') or public.can_access_class(c.id,false))),'[]'::jsonb) end,
    'subjects',case when v_current_role in ('platform_super_admin','parent_guardian') then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(s) order by s.display_order,s.name) from public.subjects s where s.deleted_at is null and s.active),'[]'::jsonb) end,
    'license',v_license,
    'permissions',jsonb_build_object(
      'manage_licenses',v_current_role='platform_super_admin',
      'manage_users',v_current_role='system_admin' and v_write_allowed,
      'manage_teachers',v_current_role='system_admin' and v_write_allowed,
      'manage_headteachers',v_current_role='system_admin' and v_write_allowed,
      'manage_academics',v_current_role='system_admin' and v_write_allowed,
      'manage_students',v_current_role='system_admin' and v_write_allowed,
      'remove_students',v_current_role='system_admin' and v_write_allowed,
      'create_reports',v_current_role in ('class_teacher','subject_teacher') and v_write_allowed,
      'import_scores',v_current_role in ('class_teacher','subject_teacher') and v_write_allowed,
      'approve_reports',v_current_role='principal' and v_write_allowed,
      'publish_reports',v_current_role in ('system_admin','class_teacher') and v_write_allowed,
      'bulk_submit_reports',v_current_role='class_teacher' and v_write_allowed,
      'bulk_approve_reports',v_current_role='principal' and v_write_allowed,
      'bulk_publish_reports',v_current_role in ('system_admin','class_teacher') and v_write_allowed,
      'remove_reports',v_current_role in ('system_admin','class_teacher','subject_teacher') and v_write_allowed,
      'restore_reports',v_current_role='system_admin' and v_write_allowed,
      'view_audit',v_current_role='system_admin',
      'run_backup',v_current_role='system_admin',
      'parent_portal',v_current_role='parent_guardian'
    ),
    'topics',case when v_current_role='platform_super_admin' then '[]'::jsonb else to_jsonb(public.my_realtime_topics()) end
  );
end $$;

-- Storage writes follow the same server-side licence gate. Reads remain
-- available in read-only mode and are denied during a full platform lock.
drop policy if exists student_photos_read on storage.objects;
create policy student_photos_read on storage.objects for select to authenticated
using(case when bucket_id='student-photos' then public.license_read_allowed() and public.can_view_student(public.safe_uuid((storage.foldername(name))[1])) else false end);

drop policy if exists student_photos_insert on storage.objects;
create policy student_photos_insert on storage.objects for insert to authenticated
with check(case when bucket_id='student-photos' then public.license_write_allowed() and public.can_manage_student(public.safe_uuid((storage.foldername(name))[1])) else false end);

drop policy if exists student_photos_update on storage.objects;
create policy student_photos_update on storage.objects for update to authenticated
using(case when bucket_id='student-photos' then public.license_write_allowed() and public.can_manage_student(public.safe_uuid((storage.foldername(name))[1])) else false end)
with check(case when bucket_id='student-photos' then public.license_write_allowed() and public.can_manage_student(public.safe_uuid((storage.foldername(name))[1])) else false end);

drop policy if exists student_photos_delete on storage.objects;
create policy student_photos_delete on storage.objects for delete to authenticated
using(case when bucket_id='student-photos' then public.license_write_allowed() and public.can_manage_student(public.safe_uuid((storage.foldername(name))[1])) else false end);

drop policy if exists report_pdfs_read on storage.objects;
create policy report_pdfs_read on storage.objects for select to authenticated
using(case when bucket_id='report-pdfs' then public.license_read_allowed() and public.can_view_report(public.safe_uuid((storage.foldername(name))[1])) else false end);

drop policy if exists report_pdfs_write on storage.objects;
create policy report_pdfs_write on storage.objects for insert to authenticated
with check(case when bucket_id='report-pdfs' then public.license_write_allowed() and public.can_publish_report(public.safe_uuid((storage.foldername(name))[1])) else false end);

drop policy if exists report_pdfs_update on storage.objects;
create policy report_pdfs_update on storage.objects for update to authenticated
using(case when bucket_id='report-pdfs' then public.license_write_allowed() and public.can_publish_report(public.safe_uuid((storage.foldername(name))[1])) else false end)
with check(case when bucket_id='report-pdfs' then public.license_write_allowed() and public.can_publish_report(public.safe_uuid((storage.foldername(name))[1])) else false end);

drop policy if exists report_pdfs_delete on storage.objects;
create policy report_pdfs_delete on storage.objects for delete to authenticated
using(case when bucket_id='report-pdfs' then public.license_write_allowed() and public.can_delete_report(public.safe_uuid((storage.foldername(name))[1])) else false end);

drop policy if exists headteacher_signatures_read on storage.objects;
create policy headteacher_signatures_read on storage.objects for select to authenticated
using(case when bucket_id='headteacher-signatures' then public.license_read_allowed() and (public.is_system_admin() or (public.has_role(array['principal']) and public.safe_uuid((storage.foldername(name))[1])=auth.uid())) else false end);

drop policy if exists headteacher_signatures_insert on storage.objects;
create policy headteacher_signatures_insert on storage.objects for insert to authenticated
with check(case when bucket_id='headteacher-signatures' then public.license_write_allowed() and public.has_role(array['principal']) and public.safe_uuid((storage.foldername(name))[1])=auth.uid() and exists(select 1 from public.headteachers h where h.profile_id=auth.uid() and h.deleted_at is null and h.active) else false end);

drop policy if exists headteacher_signatures_update on storage.objects;
create policy headteacher_signatures_update on storage.objects for update to authenticated
using(case when bucket_id='headteacher-signatures' then public.license_write_allowed() and public.has_role(array['principal']) and public.safe_uuid((storage.foldername(name))[1])=auth.uid() else false end)
with check(case when bucket_id='headteacher-signatures' then public.license_write_allowed() and public.has_role(array['principal']) and public.safe_uuid((storage.foldername(name))[1])=auth.uid() else false end);

drop policy if exists headteacher_signatures_delete on storage.objects;
create policy headteacher_signatures_delete on storage.objects for delete to authenticated
using(case when bucket_id='headteacher-signatures' then public.license_write_allowed() and public.has_role(array['principal']) and public.safe_uuid((storage.foldername(name))[1])=auth.uid() else false end);

drop policy if exists report_card_templates_storage_read on storage.objects;
create policy report_card_templates_storage_read on storage.objects for select to authenticated
using(bucket_id='report-card-templates' and public.license_read_allowed());

drop policy if exists report_card_templates_storage_insert on storage.objects;
create policy report_card_templates_storage_insert on storage.objects for insert to authenticated
with check(case when bucket_id='report-card-templates' then public.license_write_allowed() and public.is_system_admin() and (storage.foldername(name))[1] in ('early_years','basic_1_6','basic_7_9') else false end);

drop policy if exists report_card_templates_storage_update on storage.objects;
create policy report_card_templates_storage_update on storage.objects for update to authenticated
using(case when bucket_id='report-card-templates' then public.license_write_allowed() and public.is_system_admin() else false end)
with check(case when bucket_id='report-card-templates' then public.license_write_allowed() and public.is_system_admin() and (storage.foldername(name))[1] in ('early_years','basic_1_6','basic_7_9') else false end);

drop policy if exists report_card_templates_storage_delete on storage.objects;
create policy report_card_templates_storage_delete on storage.objects for delete to authenticated
using(case when bucket_id='report-card-templates' then public.license_write_allowed() and public.is_system_admin() else false end);

-- Function privileges required by RLS, Edge Functions, and the dedicated portal.
revoke all on function public.is_platform_super_admin() from public,anon;
revoke all on function public.require_platform_super_admin() from public,anon,authenticated;
revoke all on function public.license_snapshot_for_role(text) from public,anon;
revoke all on function public.license_read_allowed() from public,anon;
revoke all on function public.license_write_allowed() from public,anon;
revoke all on function public.license_access_for_actor(uuid) from public,anon,authenticated;
revoke all on function public.get_platform_license_console() from public,anon;
revoke all on function public.platform_update_license(uuid,text,date,timestamptz,timestamptz,timestamptz,text,text,text) from public,anon;
revoke all on function public.platform_set_access_lock(text,text,text,timestamptz) from public,anon;
revoke all on function public.platform_release_access_lock(uuid,text) from public,anon;

grant execute on function public.is_platform_super_admin() to authenticated,service_role;
grant execute on function public.license_snapshot_for_role(text) to authenticated,service_role;
grant execute on function public.license_read_allowed() to authenticated,service_role;
grant execute on function public.license_write_allowed() to authenticated,service_role;
grant execute on function public.license_access_for_actor(uuid) to service_role;
grant execute on function public.get_platform_license_console() to authenticated;
grant execute on function public.platform_update_license(uuid,text,date,timestamptz,timestamptz,timestamptz,text,text,text) to authenticated;
grant execute on function public.platform_set_access_lock(text,text,text,timestamptz) to authenticated;
grant execute on function public.platform_release_access_lock(uuid,text) to authenticated;

-- The v6.9.0 frontend uses the hardened admin-user-management Edge Function.
-- Retire the obsolete direct browser mutation path so it cannot bypass plan
-- capacity checks or Platform Super Administrator account isolation.
revoke all on function public.save_profile_access(jsonb) from public,anon,authenticated;

-- Deployment verification.
do $$
begin
  if not exists(select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid where t.typnamespace='public'::regnamespace and t.typname='app_role' and e.enumlabel='platform_super_admin') then
    raise exception 'v6.9.0 verification failed: platform_super_admin role is missing';
  end if;
  if to_regprocedure('public.get_platform_license_console()') is null
     or to_regprocedure('public.platform_update_license(uuid,text,date,timestamp with time zone,timestamp with time zone,timestamp with time zone,text,text,text)') is null
     or to_regprocedure('public.license_write_allowed()') is null then
    raise exception 'v6.9.0 verification failed: licensing RPC functions are missing';
  end if;
  if not exists(select 1 from public.school_licenses) then
    raise exception 'v6.9.0 verification failed: default licence was not created';
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='students' and policyname='platform_license_delete_guard' and permissive='RESTRICTIVE')
     or not exists(select 1 from pg_policies where schemaname='public' and tablename='students' and policyname='platform_license_select_guard' and permissive='RESTRICTIVE') then
    raise exception 'v6.9.0 verification failed: restrictive licence guards are missing';
  end if;
  if position('platform_super_admin' in pg_get_functiondef('public.current_app_role()'::regprocedure))=0 then
    raise exception 'v6.9.0 verification failed: current_app_role does not recognize the platform role';
  end if;
  if not exists(select 1 from pg_trigger where tgrelid='public.profiles'::regclass and tgname='profiles_protect_security_fields' and not tgisinternal) then
    raise exception 'v6.9.0 verification failed: platform profile protection trigger is missing';
  end if;
  if not has_function_privilege('authenticated','public.get_platform_license_console()','EXECUTE') then
    raise exception 'v6.9.0 verification failed: platform console RPC privilege is missing';
  end if;
  if has_function_privilege('authenticated','public.save_profile_access(jsonb)','EXECUTE') then
    raise exception 'v6.9.0 verification failed: obsolete browser profile mutation remains executable';
  end if;
end $$;

commit;

select '07 SCHEMA v6.9.0 PLATFORM LICENSING CONTROL: PASS' as status;
