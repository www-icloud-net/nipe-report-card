-- =============================================================================
-- NIPE INTERNATIONAL SCHOOL REPORT CARD ENTERPRISE
-- 05_schema.sql
-- Final-build operational hardening: complete encrypted backups, retention,
-- verification, off-site copy tracking, and approval-gated promotion governance.
-- Release: 6.7.0 Final Build
-- Run after 04_schema.sql.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- BACKUP POLICY AND COMPLETE BACKUP METADATA
-- -----------------------------------------------------------------------------

alter table public.school_settings
  add column if not exists backup_retention_days integer not null default 30,
  add column if not exists backup_minimum_copies integer not null default 7;

update public.school_settings
set backup_retention_days=greatest(7,least(365,coalesce(backup_retention_days,30))),
    backup_minimum_copies=greatest(2,least(90,coalesce(backup_minimum_copies,7)));

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conrelid='public.school_settings'::regclass
      and conname='school_settings_backup_retention_chk'
  ) then
    alter table public.school_settings
      add constraint school_settings_backup_retention_chk
      check(backup_retention_days between 7 and 365);
  end if;

  if not exists(
    select 1 from pg_constraint
    where conrelid='public.school_settings'::regclass
      and conname='school_settings_backup_minimum_copies_chk'
  ) then
    alter table public.school_settings
      add constraint school_settings_backup_minimum_copies_chk
      check(backup_minimum_copies between 2 and 90);
  end if;
end $$;

alter table public.backup_exports
  add column if not exists backup_key text not null default '',
  add column if not exists schema_version text not null default '6.7.0',
  add column if not exists backup_type text not null default 'full',
  add column if not exists manifest_path text not null default '',
  add column if not exists database_path text not null default '',
  add column if not exists storage_object_counts jsonb not null default '{}'::jsonb,
  add column if not exists storage_bytes bigint not null default 0,
  add column if not exists encrypted boolean not null default true,
  add column if not exists encryption_key_hint text not null default '',
  add column if not exists started_at timestamptz not null default now(),
  add column if not exists completed_at timestamptz,
  add column if not exists expires_at timestamptz,
  add column if not exists error_message text not null default '',
  add column if not exists verification_status text not null default 'not_tested',
  add column if not exists verification_checked_at timestamptz,
  add column if not exists verification_notes text not null default '',
  add column if not exists offsite_copied_at timestamptz,
  add column if not exists offsite_copy_note text not null default '';

update public.backup_exports
set backup_key=case when backup_key='' then id::text else backup_key end,
    schema_version=case when manifest_path='' then 'legacy' when schema_version='' then 'legacy' else schema_version end,
    backup_type=case when manifest_path='' then 'database' when backup_type='' then 'database' else backup_type end,
    manifest_path=case when manifest_path='' then storage_path else manifest_path end,
    database_path=case when database_path='' then storage_path else database_path end,
    started_at=coalesce(started_at,created_at),
    completed_at=case when status='completed' then coalesce(completed_at,created_at) else completed_at end,
    expires_at=case when status='completed' then coalesce(expires_at,created_at+interval '30 days') else expires_at end,
    encrypted=case when manifest_path='' then false else encrypted end;

create unique index if not exists backup_exports_backup_key_uidx
  on public.backup_exports(backup_key)
  where backup_key<>'';
create index if not exists backup_exports_status_created_idx
  on public.backup_exports(status,created_at desc);
create index if not exists backup_exports_expiry_idx
  on public.backup_exports(expires_at)
  where status='completed';

-- Resolve any legacy duplicate processing rows before enforcing a single active
-- full backup. The Edge Function also closes processing rows older than two hours.
with ranked_processing as (
  select id,row_number() over(order by started_at desc,created_at desc,id) as row_number
  from public.backup_exports
  where status='processing' and backup_type='full'
)
update public.backup_exports b
set status='failed',
    completed_at=coalesce(b.completed_at,now()),
    error_message=case
      when b.error_message='' then 'Superseded duplicate processing backup during v6.7.0 final-build migration'
      else b.error_message
    end
from ranked_processing r
where b.id=r.id and r.row_number>1;

create unique index if not exists backup_exports_single_processing_full_uidx
  on public.backup_exports((1))
  where status='processing' and backup_type='full';

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conrelid='public.backup_exports'::regclass
      and conname='backup_exports_type_chk'
  ) then
    alter table public.backup_exports
      add constraint backup_exports_type_chk
      check(backup_type in ('database','full'));
  end if;

  if not exists(
    select 1 from pg_constraint
    where conrelid='public.backup_exports'::regclass
      and conname='backup_exports_verification_chk'
  ) then
    alter table public.backup_exports
      add constraint backup_exports_verification_chk
      check(verification_status in ('not_tested','passed','failed'));
  end if;
end $$;

create table if not exists public.backup_storage_objects (
  id uuid primary key default gen_random_uuid(),
  backup_export_id uuid not null references public.backup_exports(id) on delete cascade,
  source_bucket text not null,
  source_path text not null,
  backup_path text not null,
  content_type text not null default 'application/octet-stream',
  original_size bigint not null default 0 check(original_size>=0),
  encrypted_size bigint not null default 0 check(encrypted_size>=0),
  checksum text not null default '',
  status text not null default 'completed' check(status in ('processing','completed','failed')),
  error_message text not null default '',
  created_at timestamptz not null default now(),
  unique(backup_export_id,source_bucket,source_path)
);

create index if not exists backup_storage_objects_export_idx
  on public.backup_storage_objects(backup_export_id,source_bucket,source_path);

alter table public.backup_storage_objects enable row level security;

drop policy if exists backup_storage_objects_admin on public.backup_storage_objects;
create policy backup_storage_objects_admin
on public.backup_storage_objects for select to authenticated
using(public.is_system_admin());

revoke all on public.backup_storage_objects from public,anon,authenticated;
grant select on public.backup_storage_objects to authenticated;

-- Keep the backup bucket private and allow larger encrypted full-system backups.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values(
  'system-backups','system-backups',false,524288000,
  array['application/json','application/gzip','application/octet-stream','application/zip','text/plain']
)
on conflict(id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- -----------------------------------------------------------------------------
-- BACKUP ADMINISTRATION RPCS
-- -----------------------------------------------------------------------------

create or replace function public.save_backup_policy(
  target_retention_days integer,
  target_minimum_copies integer
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare settings_id uuid;
begin
  if not public.is_system_admin() then
    raise exception 'Only the System Administrator can change backup policy' using errcode='42501';
  end if;
  perform public.require_sensitive_access();

  if target_retention_days is null or target_retention_days<7 or target_retention_days>365 then
    raise exception 'Backup retention must be between 7 and 365 days';
  end if;
  if target_minimum_copies is null or target_minimum_copies<2 or target_minimum_copies>90 then
    raise exception 'Minimum retained backups must be between 2 and 90';
  end if;

  select id into settings_id
  from public.school_settings
  order by created_at,id
  limit 1
  for update;

  if settings_id is null then
    insert into public.school_settings(backup_retention_days,backup_minimum_copies,updated_at)
    values(target_retention_days,target_minimum_copies,now())
    returning id into settings_id;
  else
    update public.school_settings
    set backup_retention_days=target_retention_days,
        backup_minimum_copies=target_minimum_copies,
        updated_at=now()
    where id=settings_id;
  end if;

  return jsonb_build_object(
    'backup_retention_days',target_retention_days,
    'backup_minimum_copies',target_minimum_copies,
    'settings_id',settings_id
  );
end $$;

create or replace function public.mark_backup_offsite_copy(
  target_backup_id uuid,
  target_note text default 'Encrypted backup package copied off-site'
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare result_row public.backup_exports;
begin
  if not public.is_system_admin() then
    raise exception 'Access denied' using errcode='42501';
  end if;
  perform public.require_sensitive_access();

  update public.backup_exports
  set offsite_copied_at=now(),
      offsite_copy_note=left(coalesce(nullif(btrim(target_note),''),'Encrypted backup package copied off-site'),500)
  where id=target_backup_id and status='completed'
  returning * into result_row;

  if result_row.id is null then raise exception 'Completed backup not found'; end if;
  return to_jsonb(result_row);
end $$;

create or replace function public.backup_dashboard()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare policy_row record;
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();

  select backup_retention_days,backup_minimum_copies
  into policy_row
  from public.school_settings
  order by created_at,id
  limit 1;

  return jsonb_build_object(
    'retention_days',coalesce(policy_row.backup_retention_days,30),
    'minimum_copies',coalesce(policy_row.backup_minimum_copies,7),
    'backups',coalesce((
      select jsonb_agg(to_jsonb(b) order by b.created_at desc)
      from (
        select * from public.backup_exports
        order by created_at desc
        limit 20
      ) b
    ),'[]'::jsonb)
  );
end $$;

revoke all on function public.save_backup_policy(integer,integer) from public,anon;
revoke all on function public.mark_backup_offsite_copy(uuid,text) from public,anon;
revoke all on function public.backup_dashboard() from public,anon;
grant execute on function public.save_backup_policy(integer,integer) to authenticated;
grant execute on function public.mark_backup_offsite_copy(uuid,text) to authenticated;
grant execute on function public.backup_dashboard() to authenticated;

-- Complete database snapshot fallback for browser-side emergency export.
create or replace function public.export_backup_snapshot()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  return jsonb_build_object(
    'schema_version','6.7.0',
    'generated_at',now(),
    'school_settings',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.school_settings x),
    'profiles',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.profiles x),
    'teachers',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.teachers x),
    'headteachers',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.headteachers x),
    'academic_years',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.academic_years x),
    'terms',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.terms x),
    'classes',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.classes x),
    'subjects',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.subjects x),
    'class_subjects',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.class_subjects x),
    'user_class_access',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.user_class_access x),
    'students',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.students x),
    'student_guardians',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.student_guardians x),
    'guardian_links',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.guardian_links x),
    'enrollments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.enrollments x),
    'grading_scales',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.grading_scales x),
    'assessment_schemes',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.assessment_schemes x),
    'assessment_components',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.assessment_components x),
    'student_reports',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.student_reports x),
    'subject_scores',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.subject_scores x),
    'subject_results',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.subject_results x),
    'assessment_score_entries',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.assessment_score_entries x),
    'report_workflow_events',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.report_workflow_events x),
    'report_revisions',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.report_revisions x),
    'report_publications',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.report_publications x),
    'report_card_templates',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.report_card_templates x),
    'notifications',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.notifications x),
    'notification_outbox',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.notification_outbox x),
    'import_batches',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.import_batches x),
    'import_errors',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.import_errors x),
    'audit_log',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.audit_log x),
    'client_error_events',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.client_error_events x),
    'system_maintenance_log',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.system_maintenance_log x),
    'backup_exports',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.backup_exports x),
    'backup_storage_objects',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.backup_storage_objects x)
  );
end $$;

revoke all on function public.export_backup_snapshot() from public,anon;
grant execute on function public.export_backup_snapshot() to authenticated;


-- Compatibility path for older browser clients: records a database-only,
-- unencrypted legacy export accurately rather than labelling it as a full backup.
create or replace function public.record_backup_export(
  target_storage_path text,
  target_checksum text default '',
  target_row_counts jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare bid uuid;
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  insert into public.backup_exports(
    storage_path,checksum,status,row_counts,initiated_by,backup_key,schema_version,
    backup_type,manifest_path,database_path,encrypted,started_at,completed_at,error_message
  )
  values(
    target_storage_path,coalesce(target_checksum,''),'completed',coalesce(target_row_counts,'{}'::jsonb),auth.uid(),
    gen_random_uuid()::text,'legacy','database',target_storage_path,target_storage_path,false,now(),now(),''
  )
  returning id into bid;
  return (select to_jsonb(b) from public.backup_exports b where b.id=bid);
end $$;

revoke all on function public.record_backup_export(text,text,jsonb) from public,anon;
grant execute on function public.record_backup_export(text,text,jsonb) to authenticated;

-- -----------------------------------------------------------------------------
-- SYSTEM HEALTH: BACKUP COMPLETENESS AND VERIFICATION VISIBILITY
-- -----------------------------------------------------------------------------

create or replace function public.system_health()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.has_role(array['system_admin','headteacher','academic_admin']) then
    raise exception 'Access denied' using errcode='42501';
  end if;
  return jsonb_build_object(
    'database_time',now(),
    'active_users',(select count(*) from public.profiles where active),
    'active_teachers',(select count(*) from public.teachers where active and deleted_at is null),
    'active_students',(select count(*) from public.students where status='active' and deleted_at is null),
    'pending_notifications',(select count(*) from public.notification_outbox where processed_at is null),
    'client_errors_24h',(select count(*) from public.client_error_events where created_at>=now()-interval '24 hours'),
    'latest_backup',(select max(coalesce(completed_at,created_at)) from public.backup_exports where status='completed' and backup_type='full'),
    'latest_verified_backup',(select max(verification_checked_at) from public.backup_exports where verification_status='passed'),
    'failed_backups_30d',(select count(*) from public.backup_exports where status='failed' and created_at>=now()-interval '30 days'),
    'unverified_completed_backups',(select count(*) from public.backup_exports where status='completed' and verification_status<>'passed'),
    'latest_offsite_copy',(select max(offsite_copied_at) from public.backup_exports),
    'incomplete_schemes',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'weight',q.total_weight)) from (
      select scheme_id,sum(weight) total_weight from public.assessment_components group by scheme_id having abs(sum(weight)-100)>0.01
    ) q join public.assessment_schemes s on s.id=q.scheme_id),'[]'::jsonb),
    'published_without_pdf',(select count(*) from public.report_publications where revoked_at is null and storage_path='')
  );
end $$;

-- -----------------------------------------------------------------------------
-- APPROVAL-GATED TERM 3 PROMOTION GOVERNANCE
-- -----------------------------------------------------------------------------

create or replace function public.report_promotion_evaluation(target_report_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  report_term_sequence integer;
  report_term_name text;
  report_status text;
  source_class_id uuid;
  source_class_name text;
  source_class_level integer;
  source_year_id uuid;
  source_year_name text;
  source_student_id uuid;
  next_class_id uuid;
  next_class_name text;
  target_year_id uuid;
  target_year_name text;
  target_enrollment_id uuid;
  target_enrollment_class_id uuid;
  target_enrollment_active boolean:=false;
  assigned_subjects integer:=0;
  completed_subjects integer:=0;
  average_score numeric(7,2):=0;
  cutoff_score integer:=50;
  is_complete boolean:=false;
  is_term_three boolean:=false;
  has_passed boolean:=false;
  governance_approved boolean:=false;
  promotion_applied boolean:=false;
begin
  if auth.uid() is not null and not public.can_view_report(target_report_id) then
    raise exception 'Access denied' using errcode='42501';
  end if;

  select
    t.sequence,
    t.name::text,
    r.status::text,
    e.class_id,
    c.name::text,
    c.level_order,
    e.academic_year_id,
    y.name::text,
    e.student_id
  into
    report_term_sequence,
    report_term_name,
    report_status,
    source_class_id,
    source_class_name,
    source_class_level,
    source_year_id,
    source_year_name,
    source_student_id
  from public.student_reports r
  join public.enrollments e on e.id=r.enrollment_id and e.deleted_at is null
  join public.classes c on c.id=e.class_id and c.deleted_at is null
  join public.academic_years y on y.id=e.academic_year_id and y.deleted_at is null
  join public.terms t on t.id=r.term_id and t.deleted_at is null
  where r.id=target_report_id and r.deleted_at is null;

  if source_class_id is null then raise exception 'Report not found'; end if;

  select coalesce(s.promotion_cutoff_score,50)
  into cutoff_score
  from public.school_settings s
  order by s.created_at,s.id
  limit 1;

  select
    count(*)::integer,
    count(sr.id)::integer,
    coalesce(round(avg(sr.total_score) filter(where sr.id is not null),2),0)
  into assigned_subjects,completed_subjects,average_score
  from public.class_subjects cs
  join public.subjects sb on sb.id=cs.subject_id and sb.active and sb.deleted_at is null
  left join public.subject_results sr
    on sr.report_id=target_report_id and sr.subject_id=cs.subject_id
  where cs.class_id=source_class_id and cs.active;

  is_term_three:=public.is_term_three(report_term_sequence,report_term_name);
  is_complete:=assigned_subjects>0 and completed_subjects=assigned_subjects;
  has_passed:=is_term_three and is_complete and average_score>=cutoff_score;
  governance_approved:=report_status in ('approved','published');

  select c.id,c.name::text
  into next_class_id,next_class_name
  from public.classes c
  where c.active and c.deleted_at is null and c.level_order>source_class_level
  order by c.level_order,c.name
  limit 1;

  target_year_id:=public.next_promotion_academic_year(source_year_id);
  if target_year_id is not null then
    select y.name::text into target_year_name
    from public.academic_years y
    where y.id=target_year_id and y.deleted_at is null;

    select e.id,e.class_id,e.active
    into target_enrollment_id,target_enrollment_class_id,target_enrollment_active
    from public.enrollments e
    where e.student_id=source_student_id
      and e.academic_year_id=target_year_id
      and e.deleted_at is null
    limit 1;
  end if;

  promotion_applied:=has_passed
    and governance_approved
    and target_enrollment_id is not null
    and target_enrollment_active
    and target_enrollment_class_id=next_class_id;

  return jsonb_build_object(
    'report_id',target_report_id,
    'report_status',report_status,
    'term_sequence',report_term_sequence,
    'term_name',report_term_name,
    'term3',is_term_three,
    'complete',is_complete,
    'assigned_subjects',assigned_subjects,
    'completed_subjects',completed_subjects,
    'average',average_score,
    'cutoff',cutoff_score,
    'passed',has_passed,
    'eligible',has_passed and next_class_id is not null,
    'governance_approved',governance_approved,
    'approval_required',has_passed and not governance_approved,
    'source_class_id',source_class_id,
    'source_class_name',source_class_name,
    'source_academic_year_id',source_year_id,
    'source_academic_year_name',source_year_name,
    'next_class_id',next_class_id,
    'next_class_name',next_class_name,
    'target_academic_year_id',target_year_id,
    'target_academic_year_name',target_year_name,
    'target_enrollment_id',target_enrollment_id,
    'target_enrollment_class_id',target_enrollment_class_id,
    'promotion_applied',promotion_applied,
    'can_create_enrollment',has_passed and governance_approved and next_class_id is not null and target_year_id is not null
  );
end $$;

create or replace function public.refresh_report_promotion(
  target_report_id uuid,
  create_target_enrollment boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  evaluation jsonb;
  eligible_for_promotion boolean;
  should_apply_enrollment boolean;
  next_class_id uuid;
  target_year_id uuid;
  source_student_id uuid;
  enrollment_created boolean:=false;
  enrollment_withdrawn boolean:=false;
begin
  evaluation:=public.report_promotion_evaluation(target_report_id);
  eligible_for_promotion:=coalesce((evaluation->>'eligible')::boolean,false);
  should_apply_enrollment:=coalesce((evaluation->>'can_create_enrollment')::boolean,false);
  next_class_id:=public.safe_uuid(evaluation->>'next_class_id');
  target_year_id:=public.safe_uuid(evaluation->>'target_academic_year_id');

  select e.student_id into source_student_id
  from public.student_reports r
  join public.enrollments e on e.id=r.enrollment_id and e.deleted_at is null
  where r.id=target_report_id and r.deleted_at is null;

  perform set_config('app.report_write','on',true);
  update public.student_reports
  set promoted_to_class_id=case when should_apply_enrollment then next_class_id else null end,
      updated_at=now()
  where id=target_report_id and deleted_at is null;

  if create_target_enrollment and source_student_id is not null and target_year_id is not null then
    if should_apply_enrollment then
      insert into public.enrollments(
        student_id,academic_year_id,class_id,active,deleted_at,updated_at,
        enrollment_origin,promotion_source_report_id,promotion_applied_at
      )
      values(
        source_student_id,target_year_id,next_class_id,true,null,now(),
        'automatic_promotion',target_report_id,now()
      )
      on conflict(student_id,academic_year_id) do update
        set class_id=excluded.class_id,
            active=true,
            deleted_at=null,
            updated_at=now(),
            enrollment_origin='automatic_promotion',
            promotion_source_report_id=target_report_id,
            promotion_applied_at=now();
      enrollment_created:=true;
    else
      update public.enrollments as target_enrollment
      set active=false,
          deleted_at=now(),
          updated_at=now(),
          promotion_applied_at=null
      where target_enrollment.student_id=source_student_id
        and target_enrollment.academic_year_id=target_year_id
        and target_enrollment.enrollment_origin='automatic_promotion'
        and target_enrollment.promotion_source_report_id=target_report_id
        and target_enrollment.deleted_at is null;
      enrollment_withdrawn:=found;
    end if;
  end if;

  return evaluation||jsonb_build_object(
    'eligible',eligible_for_promotion,
    'promoted_to_class_id',case when should_apply_enrollment then next_class_id else null end,
    'enrollment_created_or_updated',enrollment_created,
    'enrollment_withdrawn',enrollment_withdrawn,
    'promotion_applied',case
      when enrollment_created then true
      when enrollment_withdrawn then false
      else coalesce((evaluation->>'promotion_applied')::boolean,false)
    end
  );
end $$;

create or replace function public.sync_report_promotion_from_subject_result()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  target_id uuid;
  target_status text;
  sync_target_enrollment boolean:=false;
begin
  if tg_op='DELETE' then target_id:=old.report_id; else target_id:=new.report_id; end if;

  select r.status::text into target_status
  from public.student_reports r
  where r.id=target_id and r.deleted_at is null;

  if target_status is not null then
    select target_status in ('approved','published') or exists(
      select 1 from public.enrollments e
      where e.promotion_source_report_id=target_id
        and e.enrollment_origin='automatic_promotion'
        and e.deleted_at is null
    ) into sync_target_enrollment;
    perform public.refresh_report_promotion(target_id,sync_target_enrollment);
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create or replace function public.apply_promotion_when_report_published()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.deleted_at is not null then
    update public.enrollments
    set active=false,deleted_at=now(),updated_at=now(),promotion_applied_at=null
    where promotion_source_report_id=new.id
      and enrollment_origin='automatic_promotion'
      and deleted_at is null;
    return new;
  end if;

  if tg_op='INSERT' or old.status is distinct from new.status or old.deleted_at is distinct from new.deleted_at then
    perform public.refresh_report_promotion(new.id,true);
  end if;
  return new;
end $$;

drop trigger if exists student_report_publish_auto_promotion on public.student_reports;
create trigger student_report_publish_auto_promotion
after insert or update of status,deleted_at on public.student_reports
for each row execute function public.apply_promotion_when_report_published();

create or replace function public.apply_pending_term3_promotions()
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare item record; processed integer:=0;
begin
  for item in
    select r.id
    from public.student_reports r
    join public.terms t on t.id=r.term_id
    where r.deleted_at is null
      and r.status in ('approved','published')
      and public.is_term_three(t.sequence,t.name::text)
      and t.deleted_at is null
  loop
    perform public.refresh_report_promotion(item.id,true);
    processed:=processed+1;
  end loop;
  return processed;
end $$;

create or replace function public.save_promotion_cutoff(target_score integer)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  item record;
  processed integer:=0;
  settings_id uuid;
  sync_enrollment boolean;
begin
  if not public.is_system_admin() then
    raise exception 'Only the System Administrator can change the promotion cutoff score' using errcode='42501';
  end if;
  if target_score is null or target_score<40 or target_score>60 then
    raise exception 'Promotion cutoff score must be between 40 and 60';
  end if;

  perform set_config('app.change_reason','Term 3 automatic-promotion cutoff updated',true);

  select s.id into settings_id
  from public.school_settings s
  order by s.created_at,s.id
  limit 1
  for update;

  if settings_id is null then
    insert into public.school_settings(promotion_cutoff_score,updated_at)
    values(target_score,now())
    returning id into settings_id;
  else
    update public.school_settings
    set promotion_cutoff_score=target_score,
        updated_at=now()
    where id=settings_id;
  end if;

  for item in
    select r.id,r.status::text as status
    from public.student_reports r
    join public.terms t on t.id=r.term_id
    where r.deleted_at is null
      and t.deleted_at is null
      and public.is_term_three(t.sequence,t.name::text)
  loop
    select item.status in ('approved','published') or exists(
      select 1 from public.enrollments e
      where e.promotion_source_report_id=item.id
        and e.enrollment_origin='automatic_promotion'
        and e.deleted_at is null
    ) into sync_enrollment;
    perform public.refresh_report_promotion(item.id,sync_enrollment);
    processed:=processed+1;
  end loop;

  return jsonb_build_object(
    'promotion_cutoff_score',target_score,
    'reports_recalculated',processed,
    'settings_id',settings_id
  );
end $$;

create or replace function public.bulk_promote_class(
  source_academic_year_id uuid,
  source_class_id uuid,
  target_academic_year_id uuid,
  target_class_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  next_class_id uuid;
  expected_target_year_id uuid;
  resolved_target_year_id uuid;
  target_year_name text;
  item record;
  evaluation jsonb;
  promoted integer:=0;
  eligible_pending_approval integer:=0;
  not_promoted integer:=0;
  incomplete integer:=0;
  skipped_status integer:=0;
  cutoff integer:=50;
  reports_found integer:=0;
begin
  if not public.is_records_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  if source_academic_year_id is null or source_class_id is null then
    raise exception 'Source academic year and source class are required';
  end if;
  if not exists(
    select 1 from public.academic_years y
    where y.id=source_academic_year_id and y.deleted_at is null
  ) then
    raise exception 'Source academic year is unavailable';
  end if;

  expected_target_year_id:=public.next_promotion_academic_year(source_academic_year_id);
  if expected_target_year_id is null then
    raise exception 'No next academic year is configured. Create the next academic year before running promotion.';
  end if;

  if target_academic_year_id is null or target_academic_year_id=source_academic_year_id then
    resolved_target_year_id:=expected_target_year_id;
  elsif target_academic_year_id<>expected_target_year_id then
    raise exception 'Target academic year must be the immediate next configured academic year';
  else
    resolved_target_year_id:=target_academic_year_id;
  end if;

  select y.name::text into target_year_name
  from public.academic_years y
  where y.id=resolved_target_year_id and y.deleted_at is null;

  select c2.id into next_class_id
  from public.classes c1
  join public.classes c2 on c2.level_order>c1.level_order and c2.active and c2.deleted_at is null
  where c1.id=source_class_id and c1.active and c1.deleted_at is null
  order by c2.level_order,c2.name
  limit 1;
  if next_class_id is null then raise exception 'No next class is configured for the selected source class'; end if;
  if target_class_id is null then target_class_id:=next_class_id; end if;
  if target_class_id<>next_class_id then raise exception 'The target class must be the next class in the configured academic order'; end if;

  select coalesce(s.promotion_cutoff_score,50) into cutoff
  from public.school_settings s order by s.created_at,s.id limit 1;

  select count(*)::integer into skipped_status
  from public.student_reports r
  join public.enrollments e on e.id=r.enrollment_id and e.deleted_at is null
  join public.terms t on t.id=r.term_id and t.deleted_at is null
  where e.academic_year_id=source_academic_year_id
    and e.class_id=source_class_id
    and r.deleted_at is null
    and public.is_term_three(t.sequence,t.name::text)
    and r.status in ('returned','withdrawn');

  perform set_config('app.change_reason','Approval-gated Term 3 performance-based class promotion',true);
  for item in
    select r.id,e.student_id,r.status::text as status
    from public.student_reports r
    join public.enrollments e on e.id=r.enrollment_id and e.deleted_at is null
    join public.terms t on t.id=r.term_id and t.deleted_at is null
    join public.students s on s.id=e.student_id and s.deleted_at is null and s.status='active'
    where e.academic_year_id=source_academic_year_id
      and e.class_id=source_class_id
      and r.deleted_at is null
      and r.status in ('draft','submitted','class_reviewed','approved','published')
      and public.is_term_three(t.sequence,t.name::text)
  loop
    reports_found:=reports_found+1;
    evaluation:=public.refresh_report_promotion(item.id,true);
    if not coalesce((evaluation->>'complete')::boolean,false) then
      incomplete:=incomplete+1;
    elsif not coalesce((evaluation->>'passed')::boolean,false) then
      not_promoted:=not_promoted+1;
    elsif coalesce((evaluation->>'promotion_applied')::boolean,false) then
      promoted:=promoted+1;
    else
      eligible_pending_approval:=eligible_pending_approval+1;
    end if;
  end loop;

  return jsonb_build_object(
    'reports_found',reports_found,
    'promoted',promoted,
    'eligible_pending_approval',eligible_pending_approval,
    'not_promoted',not_promoted,
    'incomplete',incomplete,
    'skipped_status',skipped_status,
    'cutoff',cutoff,
    'target_class_id',target_class_id,
    'target_academic_year_id',resolved_target_year_id,
    'target_academic_year_name',target_year_name
  );
end $$;

create or replace function public.bulk_promote_all_classes(
  source_academic_year_id uuid,
  target_academic_year_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  expected_target_year_id uuid;
  resolved_target_year_id uuid;
  target_year_name text;
  class_item record;
  class_result jsonb;
  class_promoted integer:=0;
  class_eligible_pending integer:=0;
  class_not_promoted integer:=0;
  class_incomplete integer:=0;
  class_skipped_status integer:=0;
  class_reports_found integer:=0;
  promoted integer:=0;
  eligible_pending_approval integer:=0;
  not_promoted integer:=0;
  incomplete integer:=0;
  skipped_status integer:=0;
  reports_found integer:=0;
  classes_processed integer:=0;
  classes_with_reports integer:=0;
  classes_skipped integer:=0;
  cutoff integer:=50;
  mappings jsonb:='[]'::jsonb;
begin
  if not public.is_records_manager() then
    raise exception 'Access denied' using errcode='42501';
  end if;
  if source_academic_year_id is null then
    raise exception 'Source academic year is required';
  end if;
  if not exists(
    select 1 from public.academic_years y
    where y.id=source_academic_year_id and y.deleted_at is null
  ) then
    raise exception 'Source academic year is unavailable';
  end if;

  expected_target_year_id:=public.next_promotion_academic_year(source_academic_year_id);
  if expected_target_year_id is null then
    raise exception 'No next academic year is configured. Create the next academic year before running promotion.';
  end if;

  if target_academic_year_id is null or target_academic_year_id=source_academic_year_id then
    resolved_target_year_id:=expected_target_year_id;
  elsif target_academic_year_id<>expected_target_year_id then
    raise exception 'Target academic year must be the immediate next configured academic year';
  else
    resolved_target_year_id:=target_academic_year_id;
  end if;

  select y.name::text into target_year_name
  from public.academic_years y
  where y.id=resolved_target_year_id and y.deleted_at is null;

  select coalesce(s.promotion_cutoff_score,50) into cutoff
  from public.school_settings s order by s.created_at,s.id limit 1;

  perform set_config('app.change_reason','Approval-gated Term 3 all-class promotion',true);

  for class_item in
    select
      source_class.id as source_class_id,
      source_class.name as source_class_name,
      next_class.id as target_class_id,
      next_class.name as target_class_name
    from public.classes source_class
    left join lateral(
      select candidate.id,candidate.name
      from public.classes candidate
      where candidate.active
        and candidate.deleted_at is null
        and candidate.level_order>source_class.level_order
      order by candidate.level_order,candidate.name
      limit 1
    ) next_class on true
    where source_class.active
      and source_class.deleted_at is null
    order by source_class.level_order,source_class.name
  loop
    if class_item.target_class_id is null then
      classes_skipped:=classes_skipped+1;
      continue;
    end if;

    class_result:=public.bulk_promote_class(
      source_academic_year_id,
      class_item.source_class_id,
      resolved_target_year_id,
      class_item.target_class_id
    );

    class_promoted:=coalesce((class_result->>'promoted')::integer,0);
    class_eligible_pending:=coalesce((class_result->>'eligible_pending_approval')::integer,0);
    class_not_promoted:=coalesce((class_result->>'not_promoted')::integer,0);
    class_incomplete:=coalesce((class_result->>'incomplete')::integer,0);
    class_skipped_status:=coalesce((class_result->>'skipped_status')::integer,0);
    class_reports_found:=coalesce((class_result->>'reports_found')::integer,0);

    promoted:=promoted+class_promoted;
    eligible_pending_approval:=eligible_pending_approval+class_eligible_pending;
    not_promoted:=not_promoted+class_not_promoted;
    incomplete:=incomplete+class_incomplete;
    skipped_status:=skipped_status+class_skipped_status;
    reports_found:=reports_found+class_reports_found;
    classes_processed:=classes_processed+1;
    if class_reports_found>0 then classes_with_reports:=classes_with_reports+1; end if;

    mappings:=mappings||jsonb_build_array(jsonb_build_object(
      'source_class_id',class_item.source_class_id,
      'source_class_name',class_item.source_class_name,
      'target_class_id',class_item.target_class_id,
      'target_class_name',class_item.target_class_name,
      'reports_found',class_reports_found,
      'promoted',class_promoted,
      'eligible_pending_approval',class_eligible_pending,
      'not_promoted',class_not_promoted,
      'incomplete',class_incomplete,
      'skipped_status',class_skipped_status
    ));
  end loop;

  if classes_processed=0 then raise exception 'No eligible class mapping is configured'; end if;

  return jsonb_build_object(
    'classes_processed',classes_processed,
    'classes_with_reports',classes_with_reports,
    'classes_skipped',classes_skipped,
    'reports_found',reports_found,
    'promoted',promoted,
    'eligible_pending_approval',eligible_pending_approval,
    'not_promoted',not_promoted,
    'incomplete',incomplete,
    'skipped_status',skipped_status,
    'cutoff',cutoff,
    'target_academic_year_id',resolved_target_year_id,
    'target_academic_year_name',target_year_name,
    'mappings',mappings
  );
end $$;

revoke all on function public.report_promotion_evaluation(uuid) from public,anon;
revoke all on function public.refresh_report_promotion(uuid,boolean) from public,anon;
revoke all on function public.apply_pending_term3_promotions() from public,anon;
revoke all on function public.save_promotion_cutoff(integer) from public,anon;
grant execute on function public.report_promotion_evaluation(uuid) to authenticated;
grant execute on function public.save_promotion_cutoff(integer) to authenticated;
grant execute on function public.bulk_promote_class(uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.bulk_promote_all_classes(uuid,uuid) to authenticated;

comment on function public.bulk_promote_class(uuid,uuid,uuid,uuid) is
  'Evaluates all complete Term 3 records but creates next-year enrolments only for approved or published reports.';

-- Bring existing Term 3 records into the approval-gated governance model.
do $$
declare item record; sync_enrollment boolean;
begin
  for item in
    select r.id,r.status::text as status
    from public.student_reports r
    join public.terms t on t.id=r.term_id
    where r.deleted_at is null
      and t.deleted_at is null
      and public.is_term_three(t.sequence,t.name::text)
  loop
    select item.status in ('approved','published') or exists(
      select 1 from public.enrollments e
      where e.promotion_source_report_id=item.id
        and e.enrollment_origin='automatic_promotion'
        and e.deleted_at is null
    ) into sync_enrollment;
    perform public.refresh_report_promotion(item.id,sync_enrollment);
  end loop;
end $$;

commit;

-- -----------------------------------------------------------------------------
-- REUSABLE SCHOOLS EDITION: CONFIGURABLE USER EMAIL DOMAIN
-- Keeps the protected function signature for upgrade compatibility.
-- -----------------------------------------------------------------------------
begin;

alter table public.school_settings
  add column if not exists user_email_domain text not null default 'nip.com';

update public.school_settings
set user_email_domain=lower(btrim(coalesce(nullif(user_email_domain,''),'nip.com'))),
    updated_at=now()
where user_email_domain is null
   or btrim(user_email_domain)=''
   or user_email_domain<>lower(btrim(user_email_domain));

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conrelid='public.school_settings'::regclass
      and conname='school_settings_user_email_domain_chk'
  ) then
    alter table public.school_settings
      add constraint school_settings_user_email_domain_chk
      check(user_email_domain ~ '^(?:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\.)+[a-z]{2,63}$');
  end if;
end $$;

create or replace function public.generate_nip_user_email(
  actor_id uuid,
  requested_base text,
  target_user_id uuid default null
)
returns text
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  base_name text:=lower(regexp_replace(coalesce(requested_base,''),'[^a-z0-9]','','g'));
  email_domain text;
  candidate text;
  suffix integer:=1;
begin
  if actor_id is null or not exists(
    select 1 from public.profiles p
    where p.id=actor_id and p.active and public.current_app_role_for(p.role)='system_admin'
  ) then raise exception 'Access denied' using errcode='42501'; end if;
  if auth.uid() is not null and auth.uid()<>actor_id then raise exception 'Access denied' using errcode='42501'; end if;

  select lower(btrim(coalesce(nullif(s.user_email_domain,''),'nip.com')))
  into email_domain
  from public.school_settings s
  order by s.created_at,s.id
  limit 1;
  email_domain:=coalesce(nullif(email_domain,''),'nip.com');
  if email_domain !~ '^(?:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\.)+[a-z]{2,63}$' then
    raise exception 'The configured user email domain is invalid';
  end if;

  base_name:=left(coalesce(nullif(base_name,''),'user'),40);
  perform pg_advisory_xact_lock(hashtextextended('school_user_email_'||email_domain||'_'||base_name,0));
  candidate:=base_name||'@'||email_domain;

  while exists(
    select 1 from auth.users u
    where lower(coalesce(u.email,''))=lower(candidate)
      and (target_user_id is null or u.id<>target_user_id)
  ) loop
    suffix:=suffix+1;
    if suffix>99999 then raise exception 'A unique school user email address could not be generated'; end if;
    candidate:=left(base_name,greatest(1,40-length(suffix::text)))||suffix::text||'@'||email_domain;
  end loop;

  return candidate;
end $$;

comment on column public.school_settings.user_email_domain is
  'Domain used when the system automatically generates user account email addresses.';
comment on function public.generate_nip_user_email(uuid,text,uuid) is
  'Generates a unique user email using the configurable school_settings.user_email_domain. The legacy function name is retained for API compatibility.';

grant execute on function public.generate_nip_user_email(uuid,text,uuid) to authenticated,service_role;

commit;

-- -----------------------------------------------------------------------------
-- SCHEDULE COMPLETE BACKUPS AND WEEKLY VERIFICATION
-- Safe to rerun. Requires nis_project_url and nis_cron_secret in Vault.
-- -----------------------------------------------------------------------------

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

do $$
declare project_url text; cron_secret text;
begin
  if to_regclass('vault.decrypted_secrets') is null then return; end if;
  select decrypted_secret into project_url from vault.decrypted_secrets where name='nis_project_url' limit 1;
  select decrypted_secret into cron_secret from vault.decrypted_secrets where name='nis_cron_secret' limit 1;
  if project_url is null or cron_secret is null then return; end if;

  perform cron.unschedule(jobid)
  from cron.job
  where jobname in ('nis-scheduled-backup','nis-backup-verification');

  perform cron.schedule(
    'nis-scheduled-backup',
    '15 2 * * *',
    format($job$
      select net.http_post(
        url := %L || '/functions/v1/scheduled-backup',
        headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',%L),
        body := '{"action":"create","mode":"scheduled"}'::jsonb,
        timeout_milliseconds := 120000
      );
    $job$,project_url,cron_secret)
  );

  perform cron.schedule(
    'nis-backup-verification',
    '15 3 * * 0',
    format($job$
      select net.http_post(
        url := %L || '/functions/v1/scheduled-backup',
        headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',%L),
        body := '{"action":"verify_latest","mode":"scheduled"}'::jsonb,
        timeout_milliseconds := 120000
      );
    $job$,project_url,cron_secret)
  );
end $$;

select case
  when to_regclass('public.backup_storage_objects') is not null
    and to_regprocedure('public.save_backup_policy(integer,integer)') is not null
    and to_regprocedure('public.backup_dashboard()') is not null
    and to_regprocedure('public.report_promotion_evaluation(uuid)') is not null
    and exists(
      select 1 from information_schema.columns
      where table_schema='public' and table_name='backup_exports' and column_name='verification_status'
    )
    and exists(
      select 1 from information_schema.columns
      where table_schema='public' and table_name='school_settings' and column_name='backup_retention_days'
    )
    and exists(
      select 1 from information_schema.columns
      where table_schema='public' and table_name='school_settings' and column_name='user_email_domain'
    )
    and to_regprocedure('public.generate_nip_user_email(uuid,text,uuid)') is not null
    and exists(select 1 from pg_trigger where tgname='student_report_publish_auto_promotion' and not tgisinternal)
    and to_regclass('public.backup_exports_single_processing_full_uidx') is not null
  then '05 SCHEMA: PASS'
  else '05 SCHEMA: CHECK REQUIRED'
end as installation_status;
