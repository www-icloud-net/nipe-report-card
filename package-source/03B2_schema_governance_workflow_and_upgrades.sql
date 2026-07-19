-- NIPE INTERNATIONAL SCHOOL REPORT CARD SYSTEM
-- Enterprise v6.5.9 Split Part 3B Edition
-- DATABASE PART 3B-2: PRINCIPAL GOVERNANCE, REPORT WORKFLOW AND LATER UPGRADES
-- Run only after 03B1_schema_staff_academics_and_signatures.sql succeeds.
-- This file contains the v6.5.0 through v6.5.9 upgrade layers.

-- =============================================================================
-- ENTERPRISE RELEASE 6.5.0 PRINCIPAL, GOVERNANCE AND WORKFLOW ENFORCEMENT
-- =============================================================================

-- The Principal enum label was committed at the beginning of this file.
begin;

-- -----------------------------------------------------------------------------
-- Supported-role migration and normalization
-- -----------------------------------------------------------------------------
update public.profiles set role='system_admin'::public.app_role,updated_at=now() where role='admin';
update public.profiles set role='class_teacher'::public.app_role,updated_at=now() where role='teacher';
update public.profiles set role='principal'::public.app_role,updated_at=now() where role='headteacher';
update public.profiles
set role='parent_guardian'::public.app_role,active=false,updated_at=now()
where role in ('academic_admin','records_officer','viewer');
alter table public.profiles alter column role set default 'parent_guardian';

update auth.users
set raw_app_meta_data=jsonb_set(
  coalesce(raw_app_meta_data,'{}'::jsonb),'{role}',
  to_jsonb(case
    when lower(coalesce(raw_app_meta_data->>'role',''))='headteacher' then 'principal'
    when lower(coalesce(raw_app_meta_data->>'role',''))='admin' then 'system_admin'
    when lower(coalesce(raw_app_meta_data->>'role',''))='teacher' then 'class_teacher'
    when lower(coalesce(raw_app_meta_data->>'role','')) in ('academic_admin','records_officer','viewer') then 'parent_guardian'
    else coalesce(raw_app_meta_data->>'role','') end),true)
where lower(coalesce(raw_app_meta_data->>'role','')) in ('headteacher','admin','teacher','academic_admin','records_officer','viewer');

create or replace function public.current_app_role()
returns public.app_role
language sql stable security definer set search_path=public
as $$
  select case
    when p.role='admin' then 'system_admin'::public.app_role
    when p.role='teacher' then 'class_teacher'::public.app_role
    when p.role='headteacher' then 'principal'::public.app_role
    else p.role
  end
  from public.profiles p
  where p.id=auth.uid() and p.active
    and p.role in ('admin','teacher','headteacher','system_admin','principal','class_teacher','subject_teacher','parent_guardian')
$$;

create or replace function public.current_app_role_for(input_role public.app_role)
returns text
language sql immutable
as $$
  select case
    when input_role='admin' then 'system_admin'
    when input_role='teacher' then 'class_teacher'
    when input_role='headteacher' then 'principal'
    else input_role::text
  end
$$;

create or replace function public.is_records_manager()
returns boolean language sql stable security definer set search_path=public
as $$ select public.has_role(array['system_admin']) $$;

create or replace function public.is_academic_manager()
returns boolean language sql stable security definer set search_path=public
as $$ select public.has_role(array['system_admin']) $$;

create or replace function public.can_manage_teachers()
returns boolean language sql stable security definer set search_path=public
as $$ select public.is_system_admin() $$;

create or replace function public.can_manage_headteachers()
returns boolean language sql stable security definer set search_path=public
as $$ select public.is_system_admin() $$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path=public,auth
as $$
declare
  requested_role text:=lower(coalesce(new.raw_app_meta_data->>'role',new.raw_user_meta_data->>'role',''));
  initial_role public.app_role;
  initial_active boolean:=true;
begin
  if not exists(select 1 from public.profiles) then
    initial_role:='system_admin'::public.app_role;
  elsif requested_role in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian') then
    initial_role:=requested_role::public.app_role;
  else
    initial_role:='parent_guardian'::public.app_role;
    initial_active:=false;
  end if;
  insert into public.profiles(id,full_name,role,active,mfa_required,phone)
  values(
    new.id,
    coalesce(nullif(btrim(new.raw_user_meta_data->>'full_name'),''),split_part(coalesce(new.email,''),'@',1),'User'),
    initial_role,
    initial_active,
    initial_role in ('system_admin','principal'),
    ''
  ) on conflict(id) do nothing;
  return new;
end $$;

create or replace function public.ensure_current_user_profile()
returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
declare
  target_id uuid:=auth.uid();
  target_email text;
  target_metadata jsonb;
  target_app_metadata jsonb;
  requested_role text;
  assigned_role public.app_role;
  assigned_active boolean:=true;
begin
  if target_id is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select u.email,u.raw_user_meta_data,u.raw_app_meta_data
  into target_email,target_metadata,target_app_metadata
  from auth.users u where u.id=target_id;
  if not found then raise exception 'Authentication account not found' using errcode='42501'; end if;
  requested_role:=lower(coalesce(target_app_metadata->>'role',target_metadata->>'role',''));
  if not exists(select 1 from public.profiles p where p.id=target_id) then
    if not exists(select 1 from public.profiles p where p.active and public.current_app_role_for(p.role)='system_admin')
       and target_id=(select u.id from auth.users u order by u.created_at,u.id limit 1) then
      assigned_role:='system_admin'::public.app_role;
    elsif requested_role in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian') then
      assigned_role:=requested_role::public.app_role;
    else
      assigned_role:='parent_guardian'::public.app_role;
      assigned_active:=false;
    end if;
    insert into public.profiles(id,full_name,role,active,mfa_required,phone)
    values(target_id,coalesce(nullif(btrim(target_metadata->>'full_name'),''),nullif(split_part(coalesce(target_email,''),'@',1),''),'User'),
      assigned_role,assigned_active,assigned_role in ('system_admin','principal'),'')
    on conflict(id) do nothing;
  end if;
  update public.profiles p set
    full_name=case when btrim(coalesce(p.full_name,''))='' then coalesce(nullif(btrim(target_metadata->>'full_name'),''),nullif(split_part(coalesce(target_email,''),'@',1),''),'User') else p.full_name end,
    role=case
      when p.role='headteacher' then 'principal'::public.app_role
      when p.role='admin' then 'system_admin'::public.app_role
      when p.role='teacher' then 'class_teacher'::public.app_role
      when p.role in ('academic_admin','records_officer','viewer') then 'parent_guardian'::public.app_role
      else p.role end,
    active=case when p.role in ('academic_admin','records_officer','viewer') then false else p.active end,
    mfa_required=p.mfa_required,
    updated_at=now()
  where p.id=target_id;
  return (select jsonb_build_object('id',p.id,'full_name',p.full_name,'role',public.current_app_role_for(p.role),'active',p.active,'mfa_required',p.mfa_required) from public.profiles p where p.id=target_id);
end $$;

-- -----------------------------------------------------------------------------
-- Class, student and report authorization
-- -----------------------------------------------------------------------------
create or replace function public.can_access_class(target_class_id uuid,require_write boolean default false)
returns boolean
language sql stable security definer set search_path=public
as $$
  select case
    when public.current_app_role() in ('system_admin','principal') then not require_write
    when public.current_app_role()='class_teacher' then exists(
      select 1 from public.classes c where c.id=target_class_id and c.active and c.deleted_at is null and c.class_teacher_id=auth.uid()
    ) or exists(
      select 1 from public.user_class_access a where a.user_id=auth.uid() and a.class_id=target_class_id and a.subject_id is null
        and (not require_write or a.access_level in ('edit','score','review'))
    )
    when public.current_app_role()='subject_teacher' then exists(
      select 1 from public.class_subjects cs where cs.class_id=target_class_id and cs.teacher_id=auth.uid() and cs.active
    ) or exists(
      select 1 from public.user_class_access a where a.user_id=auth.uid() and a.class_id=target_class_id
        and (not require_write or a.access_level in ('edit','score','review'))
    )
    else false end
$$;

create or replace function public.can_view_student(target_student_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.current_app_role() in ('system_admin','principal') or exists(
    select 1 from public.enrollments e
    where e.student_id=target_student_id and e.deleted_at is null and public.can_access_class(e.class_id,false)
  )
$$;

create or replace function public.can_manage_student(target_student_id uuid default null)
returns boolean
language sql stable security definer set search_path=public
as $$ select public.is_system_admin() $$;

create or replace function public.generate_school_identifier(identifier_kind text)
returns text
language plpgsql security definer set search_path=public
as $$
declare kind text:=lower(btrim(coalesce(identifier_kind,'')));candidate text;attempt integer:=0;
begin
  if auth.uid() is null or not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  if kind not in ('student','teacher','principal','headteacher') then raise exception 'Identifier type is invalid'; end if;
  loop
    attempt:=attempt+1;
    candidate:='NIS'||lpad((floor(random()*100000000))::bigint::text,8,'0');
    if not exists(select 1 from public.students s where lower(s.admission_no::text)=lower(candidate))
       and not exists(select 1 from public.teachers t where lower(t.staff_no::text)=lower(candidate))
       and not exists(select 1 from public.headteachers h where lower(h.staff_no::text)=lower(candidate)) then
      return candidate;
    end if;
    if attempt>=250 then raise exception 'Unable to generate a unique school identifier'; end if;
  end loop;
end $$;

create or replace function public.can_manage_class_report_fields(target_class_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.current_app_role()='class_teacher' and (
    exists(select 1 from public.classes c where c.id=target_class_id and c.active and c.deleted_at is null and c.class_teacher_id=auth.uid())
    or exists(select 1 from public.user_class_access a where a.user_id=auth.uid() and a.class_id=target_class_id and a.subject_id is null and a.access_level in ('edit','score','review'))
  )
$$;

create or replace function public.can_score_class_subject(target_class_id uuid,target_subject_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select (public.current_app_role()='class_teacher' and public.can_manage_class_report_fields(target_class_id))
    or (public.current_app_role()='subject_teacher' and (
      exists(select 1 from public.class_subjects cs where cs.class_id=target_class_id and cs.subject_id=target_subject_id and cs.active and cs.teacher_id=auth.uid())
      or exists(select 1 from public.user_class_access a where a.user_id=auth.uid() and a.class_id=target_class_id and a.subject_id=target_subject_id and a.access_level in ('score','edit','review'))
    ))
$$;

create or replace function public.can_create_report_for_class(target_class_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.current_app_role() in ('class_teacher','subject_teacher') and (
    public.can_manage_class_report_fields(target_class_id)
    or exists(select 1 from public.class_subjects cs where cs.class_id=target_class_id and cs.active and public.can_score_class_subject(target_class_id,cs.subject_id))
  )
$$;

create or replace function public.can_edit_report(target_report_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists(select 1 from public.student_reports r where r.id=target_report_id and r.deleted_at is null and r.status in ('draft','returned'))
    and public.can_create_report_for_class(public.report_class_id(target_report_id))
$$;

create or replace function public.can_publish_report(target_report_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.is_system_admin() or (
    public.current_app_role() in ('class_teacher','subject_teacher')
    and public.can_create_report_for_class(public.report_class_id(target_report_id))
  )
$$;

create or replace function public.can_view_report(target_report_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.current_app_role() in ('system_admin','principal')
    or public.can_access_class(public.report_class_id(target_report_id),false)
    or exists(
      select 1 from public.student_reports r
      join public.enrollments e on e.id=r.enrollment_id
      join public.guardian_links gl on gl.student_id=e.student_id
      where r.id=target_report_id and r.status='published' and r.deleted_at is null
        and gl.auth_user_id=auth.uid() and gl.can_view_reports
    )
$$;

create or replace function public.allowed_report_transitions(target_report_id uuid)
returns text[]
language plpgsql stable security definer set search_path=public
as $$
declare current_status public.report_status; result text[]:='{}'::text[];
begin
  select r.status into current_status from public.student_reports r where r.id=target_report_id and r.deleted_at is null;
  if current_status is null then return result; end if;
  if current_status in ('draft','returned') and public.can_edit_report(target_report_id) then result:=array_append(result,'submitted'); end if;
  if current_status in ('submitted','class_reviewed') and public.current_app_role()='principal' then result:=array_append(result,'approved'); end if;
  if current_status in ('submitted','class_reviewed','approved','published') and public.current_app_role()='principal' then result:=array_append(result,'returned'); end if;
  if current_status='approved' and public.can_publish_report(target_report_id) then result:=array_append(result,'published'); end if;
  if current_status='published' and public.is_system_admin() then result:=array_append(result,'withdrawn'); end if;
  return result;
end $$;

create or replace function public.save_report_comments(
  target_report_id uuid,teacher_comment_text text default null,head_comment_text text default null,
  expected_version integer default null
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare current_version integer;current_status public.report_status;can_teacher boolean;can_principal boolean;
begin
  select version,status into current_version,current_status from public.student_reports where id=target_report_id and deleted_at is null for update;
  if current_status is null then raise exception 'Report not found'; end if;
  if expected_version is not null and expected_version<>current_version then raise exception 'This report was changed by another user. Refresh before saving comments.' using errcode='40001'; end if;
  if current_status in ('published','withdrawn') then raise exception 'Published report comments are locked'; end if;
  can_teacher:=current_status in ('draft','returned') and public.can_manage_class_report_fields(public.report_class_id(target_report_id));
  can_principal:=current_status in ('submitted','class_reviewed','approved') and public.current_app_role()='principal';
  if teacher_comment_text is not null and not can_teacher then raise exception 'Only the assigned Class Teacher can save the class teacher comment' using errcode='42501'; end if;
  if head_comment_text is not null and not can_principal then raise exception 'Only the Principal can save the Principal comment' using errcode='42501'; end if;
  if teacher_comment_text is null and head_comment_text is null then raise exception 'No comment change supplied'; end if;
  if can_principal then perform public.require_sensitive_access(); end if;
  perform set_config('app.report_write','on',true);
  perform set_config('app.change_reason','Report comments updated',true);
  update public.student_reports set
    teacher_comment=case when teacher_comment_text is not null then teacher_comment_text else teacher_comment end,
    head_comment=case when head_comment_text is not null then head_comment_text else head_comment end,
    version=version+1,updated_at=now()
  where id=target_report_id;
  insert into public.report_revisions(report_id,version,snapshot,reason,actor_id)
  values(target_report_id,(select version from public.student_reports where id=target_report_id),public.build_report_snapshot(target_report_id),'Report comments updated',auth.uid())
  on conflict(report_id,version) do update set snapshot=excluded.snapshot,reason=excluded.reason,actor_id=excluded.actor_id,created_at=now();
  return public.get_report_editor(target_report_id,null,null);
end $$;

create or replace function public.begin_report_correction(target_report_id uuid,reason_text text)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare current_status public.report_status;
begin
  if public.current_app_role()<>'principal' then raise exception 'Only the Principal can return an approved or published report' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  select status into current_status from public.student_reports where id=target_report_id and deleted_at is null for update;
  if current_status not in ('published','approved','class_reviewed','submitted') then raise exception 'A correction cannot be opened from this status'; end if;
  perform set_config('app.report_write','on',true);
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Report returned for correction'),true);
  if current_status='published' then
    update public.report_publications set revoked_at=now(),revoked_by=auth.uid() where report_id=target_report_id and revoked_at is null;
  end if;
  update public.student_reports set status='returned',version=version+1,updated_at=now() where id=target_report_id;
  insert into public.report_workflow_events(report_id,from_status,to_status,comment,actor_id)
  values(target_report_id,current_status,'returned',coalesce(reason_text,''),auth.uid());
  insert into public.report_revisions(report_id,version,snapshot,reason,actor_id)
  select id,version,public.build_report_snapshot(id),coalesce(nullif(reason_text,''),'Report returned for correction'),auth.uid() from public.student_reports where id=target_report_id
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
  if not public.can_publish_report(target_report_id) then raise exception 'Only an assigned teacher or the System Administrator can create the official PDF' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  if not exists(select 1 from public.student_reports where id=target_report_id and status='published' and deleted_at is null) then raise exception 'Only a Principal-approved published report can receive an official PDF'; end if;
  update public.report_publications set storage_path=target_storage_path,checksum=coalesce(target_checksum,''),page_count=greatest(target_page_count,1)
  where report_id=target_report_id and revoked_at is null returning id into publicationid;
  if publicationid is null then raise exception 'Active publication not found'; end if;
  return (select to_jsonb(p) from public.report_publications p where p.id=publicationid);
end $$;

-- -----------------------------------------------------------------------------
-- Workflow notifications
-- -----------------------------------------------------------------------------
create or replace function public.create_workflow_notifications(target_report_id uuid,target_status public.report_status)
returns void
language plpgsql security definer set search_path=public
as $$
declare classid uuid;studentname text;reportno text;recipient uuid;
begin
  select e.class_id,concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name),coalesce(r.report_number,'')
  into classid,studentname,reportno
  from public.student_reports r join public.enrollments e on e.id=r.enrollment_id join public.students s on s.id=e.student_id
  where r.id=target_report_id;
  if target_status='submitted' then
    for recipient in select p.id from public.profiles p where p.active and public.current_app_role_for(p.role)='principal' loop
      if recipient<>auth.uid() then perform public.create_notification(recipient,'Report awaiting Principal approval',studentname||case when reportno<>'' then ' • '||reportno else '' end,'report_workflow','report',target_report_id,true); end if;
    end loop;
  elsif target_status='returned' then
    for recipient in select distinct user_id from (
      select c.class_teacher_id user_id from public.classes c where c.id=classid and c.class_teacher_id is not null
      union all select cs.teacher_id from public.class_subjects cs where cs.class_id=classid and cs.active and cs.teacher_id is not null
      union all select a.user_id from public.user_class_access a where a.class_id=classid and a.user_id is not null
    ) q loop
      if recipient<>auth.uid() then perform public.create_notification(recipient,'Report returned for correction',studentname||case when reportno<>'' then ' • '||reportno else '' end,'report_workflow','report',target_report_id,true); end if;
    end loop;
  elsif target_status='approved' then
    for recipient in select distinct user_id from (
      select p.id user_id from public.profiles p where p.active and public.current_app_role_for(p.role)='system_admin'
      union all select c.class_teacher_id from public.classes c where c.id=classid and c.class_teacher_id is not null
      union all select cs.teacher_id from public.class_subjects cs where cs.class_id=classid and cs.active and cs.teacher_id is not null
      union all select a.user_id from public.user_class_access a where a.class_id=classid and a.user_id is not null
    ) q loop
      if recipient<>auth.uid() then perform public.create_notification(recipient,'Report approved by Principal',studentname||case when reportno<>'' then ' • '||reportno else '' end,'report_workflow','report',target_report_id,true); end if;
    end loop;
  elsif target_status='published' then
    for recipient in select gl.auth_user_id from public.guardian_links gl join public.enrollments e on e.student_id=gl.student_id join public.student_reports r on r.enrollment_id=e.id
      where r.id=target_report_id and gl.auth_user_id is not null and gl.can_receive_notifications loop
      perform public.create_notification(recipient,'Report card published',studentname||case when reportno<>'' then ' • '||reportno else '' end,'report_published','report',target_report_id,true);
    end loop;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Parent and Guardian report-only portal
-- -----------------------------------------------------------------------------
create or replace function public.list_my_children_reports()
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if public.current_app_role()<>'parent_guardian' then raise exception 'Access denied' using errcode='42501'; end if;
  return jsonb_build_object('children',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',s.id,
      'full_name',concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name),
      'admission_no',s.admission_no,
      'class_name',coalesce(c.name,''),
      'reports',coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',r.id,'report_number',r.report_number,'status',r.status,'term_name',t.name,'academic_year_name',y.name,
          'average',coalesce((select round(avg(sr.total_score),2) from public.subject_results sr where sr.report_id=r.id),0),
          'published_at',r.published_at,
          'publication',jsonb_build_object('id',rp.id,'storage_path',rp.storage_path,'checksum',rp.checksum,'page_count',rp.page_count,'published_at',rp.published_at)
        ) order by y.start_date desc nulls last,t.sequence desc)
        from public.enrollments er
        join public.student_reports r on r.enrollment_id=er.id and r.status='published' and r.deleted_at is null
        join public.terms t on t.id=r.term_id
        join public.academic_years y on y.id=t.academic_year_id
        join public.report_publications rp on rp.report_id=r.id and rp.revoked_at is null
        where er.student_id=s.id and er.deleted_at is null
      ),'[]'::jsonb)
    ) order by s.last_name,s.first_name)
    from public.guardian_links gl
    join public.students s on s.id=gl.student_id and s.deleted_at is null
    left join lateral (
      select e.class_id from public.enrollments e where e.student_id=s.id and e.active and e.deleted_at is null order by e.updated_at desc limit 1
    ) ce on true
    left join public.classes c on c.id=ce.class_id
    where gl.auth_user_id=auth.uid() and gl.can_view_reports
  ),'[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- Notification cleanup and System Administrator audit maintenance
-- -----------------------------------------------------------------------------
create or replace function public.delete_notifications(notification_ids uuid[] default null)
returns integer
language plpgsql security definer set search_path=public
as $$
declare changed integer;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  delete from public.notifications where recipient_id=auth.uid() and (notification_ids is null or id=any(notification_ids));
  get diagnostics changed=row_count;
  return changed;
end $$;

create table if not exists public.system_maintenance_log(
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id) on delete set null,
  operation text not null,
  affected_rows integer not null default 0,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.system_maintenance_log enable row level security;
revoke all on table public.system_maintenance_log from anon,authenticated;

create or replace function public.delete_audit_events(event_ids bigint[])
returns integer
language plpgsql security definer set search_path=public
as $$
declare changed integer;
begin
  if not public.is_system_admin() then raise exception 'Only the System Administrator can delete audit events' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  if event_ids is null or cardinality(event_ids)=0 then raise exception 'Select at least one audit event'; end if;
  delete from public.audit_log where id=any(event_ids);
  get diagnostics changed=row_count;
  insert into public.system_maintenance_log(actor_id,operation,affected_rows,details)
  values(auth.uid(),'DELETE_AUDIT_EVENTS',changed,jsonb_build_object('event_ids',event_ids));
  return changed;
end $$;

create or replace function public.reset_audit_log(confirmation_text text)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare changed integer;
begin
  if not public.is_system_admin() then raise exception 'Only the System Administrator can reset the audit trail' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  if upper(btrim(coalesce(confirmation_text,'')))<>'RESET AUDIT LOG' then raise exception 'Type RESET AUDIT LOG to confirm'; end if;
  select count(*) into changed from public.audit_log;
  truncate table public.audit_log restart identity;
  insert into public.system_maintenance_log(actor_id,operation,affected_rows,details)
  values(auth.uid(),'RESET_AUDIT_LOG',changed,jsonb_build_object('confirmation','RESET AUDIT LOG'));
  return jsonb_build_object('deleted',changed,'reset_at',now());
end $$;

create or replace function public.list_audit_events(
  target_table text default null,target_record_id uuid default null,page_number integer default 1,page_size integer default 50
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  return (
    with matching as (
      select a.*,p.full_name actor_name from public.audit_log a left join public.profiles p on p.id=a.actor_id
      where (target_table is null or a.table_name=target_table) and (target_record_id is null or a.record_id=target_record_id)
    )
    select jsonb_build_object(
      'rows',coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from (
        select * from matching order by created_at desc limit least(greatest(page_size,1),100) offset greatest(page_number-1,0)*least(greatest(page_size,1),100)
      ) q),'[]'::jsonb),
      'total',(select count(*) from matching)
    )
  );
end $$;

-- -----------------------------------------------------------------------------
-- Academic-year automatic active status
-- -----------------------------------------------------------------------------
create or replace function public.sync_current_academic_year_status()
returns uuid
language plpgsql security definer set search_path=public
as $$
declare current_year_id uuid;
begin
  select y.id into current_year_id
  from public.academic_years y
  where y.deleted_at is null
    and y.start_date is not null
    and y.start_date<=current_date
    and (y.end_date is null or y.end_date>=current_date)
  order by y.start_date desc,y.created_at desc
  limit 1;

  -- Deactivate the previous year first so the one-active-year unique index
  -- cannot conflict while the current year is activated.
  update public.academic_years y
  set is_active=false,updated_at=now()
  where y.deleted_at is null
    and y.is_active
    and y.id is distinct from current_year_id;

  if current_year_id is not null then
    update public.academic_years y
    set is_active=true,updated_at=now()
    where y.id=current_year_id
      and y.deleted_at is null
      and not y.is_active;
  end if;

  return current_year_id;
end $$;

create or replace function public.academic_year_auto_status_trigger()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if pg_trigger_depth()>1 then return null; end if;
  perform public.sync_current_academic_year_status();
  return null;
end $$;

drop trigger if exists academic_year_auto_status on public.academic_years;
create trigger academic_year_auto_status after insert or update of start_date,end_date,deleted_at on public.academic_years
for each statement execute function public.academic_year_auto_status_trigger();
select public.sync_current_academic_year_status();

-- -----------------------------------------------------------------------------
-- Principal signature authorization and official PDF Storage policies
-- -----------------------------------------------------------------------------
create or replace function public.get_my_headteacher_signature()
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare result jsonb;
begin
  if auth.uid() is null or public.current_app_role()<>'principal' then raise exception 'Access denied' using errcode='42501'; end if;
  select jsonb_build_object('linked',true,'headteacher_id',h.id,'full_name',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),'contact',h.phone,'signature_path',h.signature_path,'signature_updated_at',h.signature_updated_at,'updated_at',h.updated_at)
  into result from public.headteachers h where h.profile_id=auth.uid() and h.deleted_at is null and h.active order by h.updated_at desc limit 1;
  return coalesce(result,jsonb_build_object('linked',false,'full_name',(select p.full_name from public.profiles p where p.id=auth.uid()),'signature_path',''));
end $$;

create or replace function public.set_my_headteacher_signature(target_signature_path text,expected_updated_at timestamptz default null)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare hid uuid;current_updated timestamptz;clean_path text:=btrim(coalesce(target_signature_path,''));
begin
  if auth.uid() is null or public.current_app_role()<>'principal' then raise exception 'Access denied' using errcode='42501'; end if;
  select h.id,h.updated_at into hid,current_updated from public.headteachers h where h.profile_id=auth.uid() and h.deleted_at is null and h.active order by h.updated_at desc limit 1 for update;
  if hid is null then raise exception 'No active Principal record is linked to this account'; end if;
  if expected_updated_at is not null and current_updated is distinct from expected_updated_at then raise exception 'Principal record changed. Reload and try again.' using errcode='40001'; end if;
  if clean_path<>'' and clean_path not like auth.uid()::text||'/%' then raise exception 'Signature storage path is invalid'; end if;
  perform set_config('app.change_reason',case when clean_path='' then 'Principal signature removed' else 'Principal signature updated' end,true);
  update public.headteachers set signature_path=clean_path,signature_updated_at=case when clean_path='' then null else now() end,updated_at=now() where id=hid;
  return public.get_my_headteacher_signature();
end $$;

-- -----------------------------------------------------------------------------
-- Role-specific bootstrap, workspace, realtime and user directory
-- -----------------------------------------------------------------------------
create or replace function public.my_realtime_topics()
returns text[]
language sql stable security definer set search_path=public
as $$
  select array(select distinct topic from (
    select 'school:global'::text topic where public.current_app_role() in ('system_admin','principal')
    union all select 'user:'||auth.uid()::text
    union all select 'class:'||c.id::text from public.classes c where public.can_access_class(c.id,false)
    union all select 'report:'||r.id::text from public.student_reports r where public.can_view_report(r.id)
  ) q where topic is not null)
$$;

create or replace function public.get_bootstrap_data()
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare p jsonb;v_current_role text;current_year uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  current_year:=public.sync_current_academic_year_status();
  update public.profiles set last_seen_at=now() where id=auth.uid();
  v_current_role:=public.current_app_role()::text;
  if v_current_role is null or v_current_role not in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian') then raise exception 'Active supported profile not found' using errcode='42501'; end if;
  select jsonb_build_object('id',pr.id,'full_name',pr.full_name,'role',v_current_role,'active',pr.active,'mfa_required',pr.mfa_required,'phone',pr.phone)
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
      'publish_reports',v_current_role in ('system_admin','class_teacher','subject_teacher'),
      'remove_reports',v_current_role in ('system_admin','class_teacher','subject_teacher'),
      'restore_reports',v_current_role='system_admin',
      'view_audit',v_current_role='system_admin',
      'run_backup',v_current_role='system_admin',
      'parent_portal',v_current_role='parent_guardian'
    ),
    'topics',to_jsonb(public.my_realtime_topics())
  );
end $$;

create or replace function public.get_role_workspace()
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare termid uuid;v_current_role text:=public.current_app_role()::text;
begin
  if v_current_role not in ('class_teacher','subject_teacher') then return jsonb_build_object('classes','[]'::jsonb,'subjects','[]'::jsonb); end if;
  select id into termid from public.terms where is_active and deleted_at is null limit 1;
  return jsonb_build_object(
    'classes',coalesce((select jsonb_agg(to_jsonb(q) order by q.level_order,q.class_name) from (
      select c.id class_id,c.name class_name,c.level_order,
        (select count(*) from public.enrollments e join public.students s on s.id=e.student_id where e.class_id=c.id and e.active and e.deleted_at is null and s.deleted_at is null) student_count,
        (select count(*) from public.class_subjects cs where cs.class_id=c.id and cs.active) subject_count,
        (select count(*) from public.enrollments e join public.students s on s.id=e.student_id where e.class_id=c.id and e.active and e.deleted_at is null and s.deleted_at is null) expected_reports,
        (select count(*) from public.student_reports r join public.enrollments e on e.id=r.enrollment_id where e.class_id=c.id and r.term_id=termid and r.deleted_at is null and r.status in ('published','approved')) completed_reports,
        (select count(*) from public.student_reports r join public.enrollments e on e.id=r.enrollment_id where e.class_id=c.id and r.term_id=termid and r.deleted_at is null and r.status in ('draft','returned')) open_reports,
        (select count(*) from public.student_reports r join public.enrollments e on e.id=r.enrollment_id where e.class_id=c.id and r.term_id=termid and r.deleted_at is null and r.status in ('submitted','class_reviewed','approved')) review_reports,
        (select count(*) from public.student_reports r join public.enrollments e on e.id=r.enrollment_id where e.class_id=c.id and r.term_id=termid and r.deleted_at is null and r.status='published') published_reports
      from public.classes c where c.active and c.deleted_at is null and public.can_manage_class_report_fields(c.id)
    ) q),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(q) order by q.class_name,q.subject_name) from (
      select c.id class_id,c.name class_name,s.id subject_id,s.code subject_code,s.name subject_name,
        (select count(*) from public.enrollments e join public.students st on st.id=e.student_id where e.class_id=c.id and e.active and e.deleted_at is null and st.deleted_at is null) student_count,
        (select count(*) from public.student_reports r join public.enrollments e on e.id=r.enrollment_id where e.class_id=c.id and r.term_id=termid and r.deleted_at is null and r.status in ('draft','returned')) open_reports,
        (select count(*) from public.subject_results sr join public.student_reports r on r.id=sr.report_id join public.enrollments e on e.id=r.enrollment_id where e.class_id=c.id and sr.subject_id=s.id and r.term_id=termid and r.deleted_at is null) scored_reports,
        (select count(*) from public.enrollments e join public.students st on st.id=e.student_id where e.class_id=c.id and e.active and e.deleted_at is null and st.deleted_at is null) expected_reports
      from public.class_subjects cs join public.classes c on c.id=cs.class_id join public.subjects s on s.id=cs.subject_id
      where cs.active and c.active and c.deleted_at is null and s.active and s.deleted_at is null and public.can_score_class_subject(c.id,s.id)
    ) q),'[]'::jsonb)
  );
end $$;

create or replace function public.list_profiles_with_access()
returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  return jsonb_build_object(
    'profiles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'full_name',p.full_name,'email',au.email,'role',public.current_app_role_for(p.role),
      'active',p.active,'mfa_required',p.mfa_required,'phone',p.phone,'last_seen_at',p.last_seen_at,
      'account_created_at',au.created_at,'email_confirmed_at',au.email_confirmed_at,'last_sign_in_at',au.last_sign_in_at,
      'teacher_id',t.id,'headteacher_id',h.id,'staff_record_id',coalesce(h.id,t.id),'staff_no',coalesce(h.staff_no,t.staff_no),
      'access',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'class_id',a.class_id,'class_name',c.name,'subject_id',a.subject_id,'subject_name',sub.name,'access_level',a.access_level) order by c.name,sub.name nulls first)
        from public.user_class_access a join public.classes c on c.id=a.class_id left join public.subjects sub on sub.id=a.subject_id where a.user_id=p.id),'[]'::jsonb)
      ) order by p.full_name)
      from public.profiles p left join auth.users au on au.id=p.id
      left join public.teachers t on t.profile_id=p.id and t.deleted_at is null
      left join public.headteachers h on h.profile_id=p.id and h.deleted_at is null
      where public.current_app_role_for(p.role) in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian')),'[]'::jsonb),
    'teacher_records',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'profile_id',t.profile_id,'staff_no',t.staff_no,'first_name',t.first_name,'middle_name',t.middle_name,'last_name',t.last_name,'full_name',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name),'label',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name)||' • '||t.staff_no::text,'phone',t.phone,'email',t.email,'active',t.active) order by t.last_name,t.first_name) from public.teachers t where t.deleted_at is null and t.active),'[]'::jsonb),
    'headteacher_records',coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'profile_id',h.profile_id,'staff_no',h.staff_no,'first_name',h.first_name,'middle_name',h.middle_name,'last_name',h.last_name,'full_name',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),'label',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name)||' • '||h.staff_no::text,'phone',h.phone,'email',h.email,'active',h.active) order by h.last_name,h.first_name) from public.headteachers h where h.deleted_at is null and h.active),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(sub) order by sub.display_order,sub.name) from public.subjects sub where sub.deleted_at is null),'[]'::jsonb),
    'class_subjects',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'class_id',cs.class_id,'subject_id',cs.subject_id,'active',cs.active)) from public.class_subjects cs),'[]'::jsonb)
  );
end $$;

-- Storage policies for teacher/admin publication and Principal signatures.
drop policy if exists report_pdfs_write on storage.objects;
create policy report_pdfs_write on storage.objects for insert to authenticated
with check(bucket_id='report-pdfs' and public.can_publish_report(public.safe_uuid((storage.foldername(name))[1])));
drop policy if exists report_pdfs_update on storage.objects;
create policy report_pdfs_update on storage.objects for update to authenticated
using(bucket_id='report-pdfs' and public.can_publish_report(public.safe_uuid((storage.foldername(name))[1])))
with check(bucket_id='report-pdfs' and public.can_publish_report(public.safe_uuid((storage.foldername(name))[1])));

drop policy if exists headteacher_signatures_read on storage.objects;
create policy headteacher_signatures_read on storage.objects for select to authenticated
using(bucket_id='headteacher-signatures' and public.current_app_role() in ('system_admin','principal','class_teacher','subject_teacher'));
drop policy if exists headteacher_signatures_insert on storage.objects;
create policy headteacher_signatures_insert on storage.objects for insert to authenticated
with check(bucket_id='headteacher-signatures' and public.current_app_role()='principal' and public.safe_uuid((storage.foldername(name))[1])=auth.uid() and exists(select 1 from public.headteachers h where h.profile_id=auth.uid() and h.deleted_at is null and h.active));
drop policy if exists headteacher_signatures_update on storage.objects;
create policy headteacher_signatures_update on storage.objects for update to authenticated
using(bucket_id='headteacher-signatures' and public.current_app_role()='principal' and public.safe_uuid((storage.foldername(name))[1])=auth.uid())
with check(bucket_id='headteacher-signatures' and public.current_app_role()='principal' and public.safe_uuid((storage.foldername(name))[1])=auth.uid());
drop policy if exists headteacher_signatures_delete on storage.objects;
create policy headteacher_signatures_delete on storage.objects for delete to authenticated
using(bucket_id='headteacher-signatures' and public.current_app_role()='principal' and public.safe_uuid((storage.foldername(name))[1])=auth.uid());

-- Own notification deletion policy and least-privilege audit policy.
drop policy if exists notifications_delete_own on public.notifications;
create policy notifications_delete_own on public.notifications for delete to authenticated using(recipient_id=auth.uid());
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select to authenticated using(public.is_system_admin());

-- Function privileges.
revoke all on function public.can_publish_report(uuid) from public,anon;
revoke all on function public.list_my_children_reports() from public,anon;
revoke all on function public.delete_notifications(uuid[]) from public,anon;
revoke all on function public.delete_audit_events(bigint[]) from public,anon;
revoke all on function public.reset_audit_log(text) from public,anon;
revoke all on function public.sync_current_academic_year_status() from public,anon;
grant execute on function public.can_publish_report(uuid) to authenticated;
grant execute on function public.list_my_children_reports() to authenticated;
grant execute on function public.delete_notifications(uuid[]) to authenticated;
grant execute on function public.delete_audit_events(bigint[]) to authenticated;
grant execute on function public.reset_audit_log(text) to authenticated;
grant execute on function public.sync_current_academic_year_status() to authenticated;

commit;

-- =============================================================================
-- ENTERPRISE RELEASE 6.5.4 AUTOMATIC ACCOUNT EMAILS AND ASSIGNMENT DELETION
-- =============================================================================
begin;

-- Generate a unique account email under the required @nip.com domain.
-- New accounts use the first personal-name token supplied by the frontend.
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
  candidate text;
  suffix integer:=1;
begin
  if actor_id is null or not exists(
    select 1 from public.profiles p
    where p.id=actor_id and p.active and public.current_app_role_for(p.role)='system_admin'
  ) then raise exception 'Access denied' using errcode='42501'; end if;
  if auth.uid() is not null and auth.uid()<>actor_id then raise exception 'Access denied' using errcode='42501'; end if;

  base_name:=left(coalesce(nullif(base_name,''),'user'),40);
  perform pg_advisory_xact_lock(hashtextextended('nis_user_email_'||base_name,0));
  candidate:=base_name||'@nip.com';

  while exists(
    select 1 from auth.users u
    where lower(coalesce(u.email,''))=lower(candidate)
      and (target_user_id is null or u.id<>target_user_id)
  ) loop
    suffix:=suffix+1;
    if suffix>99999 then raise exception 'A unique @nip.com email address could not be generated'; end if;
    candidate:=left(base_name,greatest(1,40-length(suffix::text)))||suffix::text||'@nip.com';
  end loop;

  return candidate;
end $$;

-- Permanently delete a previously removed class-subject assignment.
create or replace function public.delete_class_subject_assignment(
  target_id uuid,
  reason_text text default 'Class subject assignment permanently deleted'
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  target_class_id uuid;
  target_subject_id uuid;
  active_value boolean;
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();

  select cs.class_id,cs.subject_id,cs.active
  into target_class_id,target_subject_id,active_value
  from public.class_subjects cs
  where cs.id=target_id
  for update;
  if not found then raise exception 'Subject assignment not found'; end if;
  if active_value then raise exception 'Remove the active subject assignment before deleting it'; end if;

  if exists(
    select 1
    from public.subject_results sr
    join public.student_reports r on r.id=sr.report_id
    join public.enrollments e on e.id=r.enrollment_id
    where e.class_id=target_class_id
      and sr.subject_id=target_subject_id
      and r.deleted_at is null
      and r.status not in ('published','withdrawn')
  ) then raise exception 'This assignment is connected to unfinished report cards'; end if;

  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Class subject assignment permanently deleted'),true);
  delete from public.user_class_access a
  where a.class_id=target_class_id and a.subject_id=target_subject_id;
  delete from public.class_subjects cs where cs.id=target_id;
  if not found then raise exception 'Subject assignment was not deleted'; end if;
  return true;
end $$;

-- Restore matching archived academic records instead of failing with a duplicate error.
create or replace function public.save_academic_entity(entity_type text,payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  targetid uuid:=public.safe_uuid(payload->>'id');
  affected integer;
  startdate date:=public.safe_date(payload->>'start_date');
  enddate date:=public.safe_date(payload->>'end_date');
  nextdate date:=public.safe_date(payload->>'next_term_begins');
  yearid uuid:=public.safe_uuid(payload->>'academic_year_id');
  teacherid uuid:=public.safe_uuid(payload->>'class_teacher_id');
  seq integer:=public.safe_integer(payload->>'sequence');
  orderno integer;
  subjectcode text;
  existingcode text;
  recordname text:=regexp_replace(btrim(coalesce(payload->>'name','')),'[[:space:]]+',' ','g');
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(payload->>'id',''))<>'' and targetid is null then raise exception 'Academic record identifier is invalid'; end if;
  if btrim(coalesce(payload->>'start_date',''))<>'' and startdate is null then raise exception 'Start date is invalid'; end if;
  if btrim(coalesce(payload->>'end_date',''))<>'' and enddate is null then raise exception 'End date is invalid'; end if;
  if btrim(coalesce(payload->>'next_term_begins',''))<>'' and nextdate is null then raise exception 'Next term date is invalid'; end if;
  if btrim(coalesce(payload->>'academic_year_id',''))<>'' and yearid is null then raise exception 'Academic year identifier is invalid'; end if;
  if btrim(coalesce(payload->>'class_teacher_id',''))<>'' and teacherid is null then raise exception 'Class teacher identifier is invalid'; end if;
  if startdate is not null and enddate is not null and startdate>enddate then raise exception 'Start date cannot be after end date'; end if;
  if nextdate is not null and enddate is not null and nextdate<enddate then raise exception 'Next term date cannot be before the term end date'; end if;
  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Academic record update'),true);

  if entity_type='academic_years' then
    if recordname='' then raise exception 'Academic year name is required'; end if;
    if targetid is null then
      select y.id into targetid
      from public.academic_years y
      where lower(y.name::text)=lower(recordname) and y.deleted_at is not null
      order by y.updated_at desc,y.created_at desc limit 1 for update;
      if targetid is null then
        insert into public.academic_years(name,start_date,end_date)
        values(recordname,startdate,enddate) returning id into targetid;
      else
        update public.academic_years
        set name=recordname,start_date=startdate,end_date=enddate,is_active=false,deleted_at=null,updated_at=now()
        where id=targetid;
      end if;
    else
      update public.academic_years
      set name=recordname,start_date=startdate,end_date=enddate,updated_at=now()
      where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='terms' then
    if yearid is null or not exists(select 1 from public.academic_years y where y.id=yearid and y.deleted_at is null) then raise exception 'Academic year is invalid'; end if;
    if recordname='' then raise exception 'Term name is required'; end if;
    if seq is null or seq not between 1 and 6 then raise exception 'Term sequence must be between 1 and 6'; end if;
    if targetid is null then
      select t.id into targetid
      from public.terms t
      where t.academic_year_id=yearid and t.deleted_at is not null
        and (lower(t.name::text)=lower(recordname) or t.sequence=seq)
      order by ((lower(t.name::text)=lower(recordname)) and t.sequence=seq) desc,t.updated_at desc,t.created_at desc
      limit 1 for update;
      if targetid is null then
        insert into public.terms(academic_year_id,name,sequence,start_date,end_date,next_term_begins)
        values(yearid,recordname,seq,startdate,enddate,nextdate) returning id into targetid;
      else
        update public.terms
        set academic_year_id=yearid,name=recordname,sequence=seq,start_date=startdate,end_date=enddate,
          next_term_begins=nextdate,is_active=false,deleted_at=null,updated_at=now()
        where id=targetid;
      end if;
    else
      update public.terms
      set academic_year_id=yearid,name=recordname,sequence=seq,start_date=startdate,end_date=enddate,
        next_term_begins=nextdate,updated_at=now()
      where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='classes' then
    if recordname='' then raise exception 'Class name is required'; end if;
    orderno:=coalesce(public.safe_integer(payload->>'level_order'),0);
    if teacherid is not null and not exists(
      select 1 from public.profiles p
      where p.id=teacherid and p.active and public.current_app_role_for(p.role) in ('principal','class_teacher')
    ) then raise exception 'Selected class teacher account is invalid'; end if;
    if targetid is null then
      select c.id into targetid
      from public.classes c
      where lower(c.name::text)=lower(recordname) and c.deleted_at is not null
      order by c.updated_at desc,c.created_at desc limit 1 for update;
      if targetid is null then
        insert into public.classes(name,level_order,class_teacher_id,active)
        values(recordname,orderno,teacherid,public.safe_boolean(payload->>'active',true)) returning id into targetid;
      else
        update public.classes
        set name=recordname,level_order=orderno,class_teacher_id=teacherid,
          active=public.safe_boolean(payload->>'active',true),deleted_at=null,updated_at=now()
        where id=targetid;
      end if;
    else
      update public.classes
      set name=recordname,level_order=orderno,class_teacher_id=teacherid,
        active=public.safe_boolean(payload->>'active',true),updated_at=now()
      where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='subjects' then
    if recordname='' then raise exception 'Subject name is required'; end if;
    orderno:=coalesce(public.safe_integer(payload->>'display_order'),0);
    subjectcode:=upper(btrim(coalesce(payload->>'code','')));
    if targetid is null then
      select s.id,s.code::text into targetid,existingcode
      from public.subjects s
      where lower(s.name::text)=lower(recordname) and s.deleted_at is not null
      order by s.updated_at desc,s.created_at desc limit 1 for update;
      if targetid is null then
        if subjectcode='' or exists(select 1 from public.subjects s where lower(s.code::text)=lower(subjectcode)) then
          subjectcode:=public.generate_subject_code(recordname,null);
        end if;
        insert into public.subjects(code,name,display_order,active)
        values(subjectcode,recordname,orderno,public.safe_boolean(payload->>'active',true)) returning id into targetid;
      else
        subjectcode:=coalesce(nullif(subjectcode,''),existingcode);
        if exists(select 1 from public.subjects s where lower(s.code::text)=lower(subjectcode) and s.id<>targetid) then
          subjectcode:=public.generate_subject_code(recordname,targetid);
        end if;
        update public.subjects
        set code=subjectcode,name=recordname,display_order=orderno,
          active=public.safe_boolean(payload->>'active',true),deleted_at=null,updated_at=now()
        where id=targetid;
      end if;
    else
      select s.code::text into existingcode
      from public.subjects s where s.id=targetid and s.deleted_at is null for update;
      if not found then raise exception 'Subject not found'; end if;
      subjectcode:=coalesce(nullif(subjectcode,''),existingcode);
      if exists(select 1 from public.subjects s where lower(s.code::text)=lower(subjectcode) and s.id<>targetid) then
        subjectcode:=public.generate_subject_code(recordname,targetid);
      end if;
      update public.subjects
      set code=subjectcode,name=recordname,display_order=orderno,
        active=public.safe_boolean(payload->>'active',true),updated_at=now()
      where id=targetid and deleted_at is null;
    end if;
  else
    raise exception 'Unsupported academic record type';
  end if;

  get diagnostics affected=row_count;
  if targetid is null or affected=0 then raise exception 'Academic record was not saved'; end if;
  return public.get_academic_configuration();
exception when unique_violation then
  if entity_type='academic_years' then raise exception 'An academic year with this name already exists';
  elsif entity_type='terms' then raise exception 'A term with this name or sequence already exists in the selected academic year';
  elsif entity_type='classes' then raise exception 'A class with this name already exists';
  elsif entity_type='subjects' then raise exception 'A subject with this name or code already exists';
  else raise exception 'An academic record already uses these details';
  end if;
end $$;

revoke all on function public.generate_nip_user_email(uuid,text,uuid) from public,anon;
revoke all on function public.delete_class_subject_assignment(uuid,text) from public,anon;
grant execute on function public.generate_nip_user_email(uuid,text,uuid) to authenticated,service_role;
grant execute on function public.delete_class_subject_assignment(uuid,text) to authenticated;

commit;

-- =============================================================================
-- ENTERPRISE RELEASE 6.5.5 CHECKLIST ASSIGNMENTS AND PASSWORD GOVERNANCE
-- Permanent location: Database Part 3B
-- =============================================================================
begin;

alter table public.profiles
  add column if not exists must_change_password boolean not null default false;

create or replace function public.get_bootstrap_data()
returns jsonb
language plpgsql security definer set search_path=public
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
      'publish_reports',v_current_role in ('system_admin','class_teacher','subject_teacher'),
      'remove_reports',v_current_role in ('system_admin','class_teacher','subject_teacher'),
      'restore_reports',v_current_role='system_admin',
      'view_audit',v_current_role='system_admin',
      'run_backup',v_current_role='system_admin',
      'parent_portal',v_current_role='parent_guardian'
    ),
    'topics',to_jsonb(public.my_realtime_topics())
  );
end $$;

create or replace function public.list_profiles_with_access()
returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  return jsonb_build_object(
    'profiles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'full_name',p.full_name,'email',au.email,'role',public.current_app_role_for(p.role),
      'active',p.active,'mfa_required',p.mfa_required,'must_change_password',p.must_change_password,'phone',p.phone,'last_seen_at',p.last_seen_at,
      'account_created_at',au.created_at,'email_confirmed_at',au.email_confirmed_at,'last_sign_in_at',au.last_sign_in_at,
      'teacher_id',t.id,'headteacher_id',h.id,'staff_record_id',coalesce(h.id,t.id),'staff_no',coalesce(h.staff_no,t.staff_no),
      'access',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'class_id',a.class_id,'class_name',c.name,'subject_id',a.subject_id,'subject_name',sub.name,'access_level',a.access_level) order by c.name,sub.name nulls first)
        from public.user_class_access a join public.classes c on c.id=a.class_id left join public.subjects sub on sub.id=a.subject_id where a.user_id=p.id),'[]'::jsonb)
      ) order by p.full_name)
      from public.profiles p left join auth.users au on au.id=p.id
      left join public.teachers t on t.profile_id=p.id and t.deleted_at is null
      left join public.headteachers h on h.profile_id=p.id and h.deleted_at is null
      where public.current_app_role_for(p.role) in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian')),'[]'::jsonb),
    'teacher_records',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'profile_id',t.profile_id,'staff_no',t.staff_no,'first_name',t.first_name,'middle_name',t.middle_name,'last_name',t.last_name,'full_name',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name),'label',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name)||' • '||t.staff_no::text,'phone',t.phone,'email',t.email,'active',t.active) order by t.last_name,t.first_name) from public.teachers t where t.deleted_at is null and t.active),'[]'::jsonb),
    'headteacher_records',coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'profile_id',h.profile_id,'staff_no',h.staff_no,'first_name',h.first_name,'middle_name',h.middle_name,'last_name',h.last_name,'full_name',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),'label',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name)||' • '||h.staff_no::text,'phone',h.phone,'email',h.email,'active',h.active) order by h.last_name,h.first_name) from public.headteachers h where h.deleted_at is null and h.active),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(sub) order by sub.display_order,sub.name) from public.subjects sub where sub.deleted_at is null),'[]'::jsonb),
    'class_subjects',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'class_id',cs.class_id,'subject_id',cs.subject_id,'active',cs.active)) from public.class_subjects cs),'[]'::jsonb)
  );
end $$;

create or replace function public.admin_apply_user_bundle(actor_id uuid,bundle jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  targetid uuid:=public.safe_uuid(bundle->>'user_id');
  staffrecordid uuid:=public.safe_uuid(bundle->>'staff_record_id');
  role_text text:=btrim(coalesce(bundle->>'role','viewer'));
  item jsonb; classid uuid; subjectid uuid; accesslevel text; previous jsonb;
  resolved_name text:=btrim(coalesce(bundle->>'full_name',''));
  resolved_phone text:=btrim(coalesce(bundle->>'phone',''));
begin
  perform public.admin_validate_user_bundle(actor_id,bundle,true);
  if role_text in ('class_teacher','subject_teacher') then
    select concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name),coalesce(nullif(t.phone,''),resolved_phone)
      into resolved_name,resolved_phone from public.teachers t where t.id=staffrecordid and t.deleted_at is null;
  elsif role_text='principal' then
    select concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),coalesce(nullif(h.phone,''),resolved_phone)
      into resolved_name,resolved_phone from public.headteachers h where h.id=staffrecordid and h.deleted_at is null;
  end if;

  select jsonb_build_object(
    'profile',to_jsonb(p),
    'teacher',(select to_jsonb(t) from public.teachers t where t.profile_id=targetid and t.deleted_at is null limit 1),
    'principal',(select to_jsonb(h) from public.headteachers h where h.profile_id=targetid and h.deleted_at is null limit 1),
    'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb)
  ) into previous from public.profiles p where p.id=targetid;

  insert into public.profiles(id,full_name,role,active,mfa_required,must_change_password,phone,updated_at)
  values(targetid,resolved_name,role_text::public.app_role,public.safe_boolean(bundle->>'active',true),
    public.safe_boolean(bundle->>'mfa_required',false),public.safe_boolean(bundle->>'must_change_password',false),resolved_phone,now())
  on conflict(id) do update set full_name=excluded.full_name,role=excluded.role,active=excluded.active,
    mfa_required=excluded.mfa_required,must_change_password=excluded.must_change_password,
    phone=excluded.phone,updated_at=now();

  update public.teachers set profile_id=null,updated_at=now()
    where profile_id=targetid and (role_text not in ('class_teacher','subject_teacher') or id<>staffrecordid);
  update public.headteachers set profile_id=null,updated_at=now()
    where profile_id=targetid and (role_text<>'principal' or id<>staffrecordid);
  if role_text in ('class_teacher','subject_teacher') then
    update public.teachers set profile_id=targetid,updated_at=now() where id=staffrecordid and deleted_at is null;
  elsif role_text='principal' then
    update public.headteachers set profile_id=targetid,updated_at=now() where id=staffrecordid and deleted_at is null;
  end if;

  delete from public.user_class_access where user_id=targetid;
  for item in select value from jsonb_array_elements(coalesce(bundle->'access','[]'::jsonb)) loop
    classid:=public.safe_uuid(item->>'class_id'); subjectid:=public.safe_uuid(item->>'subject_id'); accesslevel:=coalesce(nullif(btrim(item->>'access_level'),''),'view');
    insert into public.user_class_access(user_id,class_id,subject_id,access_level) values(targetid,classid,subjectid,accesslevel);
  end loop;

  insert into public.audit_log(actor_id,table_name,record_id,action,old_data,new_data,reason)
  values(actor_id,'profiles',targetid,case when previous is null then 'ADMIN_CREATE_USER' else 'ADMIN_UPDATE_USER' end,
    previous,jsonb_build_object('profile',(select to_jsonb(p) from public.profiles p where p.id=targetid),
      'teacher',(select to_jsonb(t) from public.teachers t where t.profile_id=targetid and t.deleted_at is null limit 1),
      'principal',(select to_jsonb(h) from public.headteachers h where h.profile_id=targetid and h.deleted_at is null limit 1),
      'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb)),
    coalesce(nullif(bundle->>'reason',''),'User account management'));
  return jsonb_build_object('profile',(select to_jsonb(p) from public.profiles p where p.id=targetid),
    'teacher',(select to_jsonb(t) from public.teachers t where t.profile_id=targetid and t.deleted_at is null limit 1),
    'principal',(select to_jsonb(h) from public.headteachers h where h.profile_id=targetid and h.deleted_at is null limit 1),
    'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb));
end $$;

create or replace function public.complete_required_password_change()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare previous_value boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select must_change_password into previous_value from public.profiles where id=auth.uid() for update;
  if not found then raise exception 'Active profile not found' using errcode='42501'; end if;
  update public.profiles
  set must_change_password=false,updated_at=now()
  where id=auth.uid();
  insert into public.audit_log(actor_id,table_name,record_id,action,old_data,new_data,reason)
  values(auth.uid(),'profiles',auth.uid(),'PASSWORD_CHANGE_COMPLETED',
    jsonb_build_object('must_change_password',coalesce(previous_value,false)),
    jsonb_build_object('must_change_password',false),
    'Required password change completed');
  return jsonb_build_object('completed',true);
end $$;

create or replace function public.save_class_subject_assignments_batch(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  targetid uuid:=public.safe_uuid(payload->>'id');
  teacherid uuid:=public.safe_uuid(payload->>'teacher_id');
  activevalue boolean:=public.safe_boolean(payload->>'active',true);
  selections jsonb:=coalesce(payload->'selections','[]'::jsonb);
  item jsonb;
  classid uuid;
  subjectid uuid;
  pairkey text;
  seenpairs text[]:='{}'::text[];
  previous_teacher uuid;
  old_class uuid;
  old_subject uuid;
  old_teacher uuid;
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(payload->>'id',''))<>'' and targetid is null then raise exception 'Subject assignment identifier is invalid'; end if;
  if btrim(coalesce(payload->>'teacher_id',''))<>'' and teacherid is null then raise exception 'Teacher identifier is invalid'; end if;
  if teacherid is null or not exists(
    select 1 from public.profiles p
    where p.id=teacherid and p.active
      and public.current_app_role_for(p.role) in ('class_teacher','subject_teacher')
  ) then raise exception 'Select an active Class Teacher or Subject Teacher account'; end if;
  if jsonb_typeof(selections)<>'array' or jsonb_array_length(selections)=0 then
    raise exception 'Select at least one class and subject';
  end if;
  if jsonb_array_length(selections)>500 then raise exception 'Too many assignments were selected'; end if;

  if targetid is not null then
    select class_id,subject_id,teacher_id into old_class,old_subject,old_teacher
    from public.class_subjects where id=targetid for update;
    if not found then raise exception 'Subject assignment not found'; end if;
  end if;

  for item in select value from jsonb_array_elements(selections) loop
    classid:=public.safe_uuid(item->>'class_id');
    subjectid:=public.safe_uuid(item->>'subject_id');
    if classid is null or not exists(select 1 from public.classes c where c.id=classid and c.deleted_at is null and c.active) then
      raise exception 'A selected class is invalid or inactive';
    end if;
    if subjectid is null or not exists(select 1 from public.subjects s where s.id=subjectid and s.deleted_at is null and s.active) then
      raise exception 'A selected subject is invalid or inactive';
    end if;
    pairkey:=classid::text||'|'||subjectid::text;
    if pairkey=any(seenpairs) then raise exception 'The same class and subject were selected more than once'; end if;
    seenpairs:=array_append(seenpairs,pairkey);
  end loop;

  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Class-subject assignment batch update'),true);

  if targetid is not null then
    delete from public.class_subjects where id=targetid;
  end if;

  for item in select value from jsonb_array_elements(selections) loop
    classid:=public.safe_uuid(item->>'class_id');
    subjectid:=public.safe_uuid(item->>'subject_id');

    select cs.teacher_id into previous_teacher
    from public.class_subjects cs
    where cs.class_id=classid and cs.subject_id=subjectid
    for update;

    insert into public.class_subjects(class_id,subject_id,teacher_id,active,updated_at)
    values(classid,subjectid,teacherid,activevalue,now())
    on conflict(class_id,subject_id) do update set
      teacher_id=excluded.teacher_id,
      active=excluded.active,
      updated_at=now();

    if previous_teacher is not null and previous_teacher is distinct from teacherid then
      delete from public.user_class_access
      where user_id=previous_teacher and class_id=classid and subject_id=subjectid;
    end if;

    if activevalue then
      insert into public.user_class_access(user_id,class_id,subject_id,access_level)
      values(teacherid,classid,subjectid,'score')
      on conflict do nothing;
    else
      delete from public.user_class_access
      where user_id=teacherid and class_id=classid and subject_id=subjectid;
    end if;
  end loop;

  if old_teacher is not null and old_class is not null and old_subject is not null
     and not exists(
       select 1 from public.class_subjects cs
       where cs.class_id=old_class and cs.subject_id=old_subject
         and cs.teacher_id=old_teacher and cs.active
     ) then
    delete from public.user_class_access
    where user_id=old_teacher and class_id=old_class and subject_id=old_subject;
  end if;

  return public.get_academic_configuration();
end $$;

revoke all on function public.complete_required_password_change() from public,anon;
grant execute on function public.complete_required_password_change() to authenticated;
revoke all on function public.save_class_subject_assignments_batch(jsonb) from public,anon;
grant execute on function public.save_class_subject_assignments_batch(jsonb) to authenticated;

commit;

-- =============================================================================
-- ENTERPRISE RELEASE 6.5.8 HYBRID CLASS-AND-SUBJECT TEACHER RESPONSIBILITIES
-- Permanent location: Database Part 3B
-- =============================================================================
begin;

create or replace function public.sync_teacher_responsibility_access(target_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  class_scope_count integer:=0;
  subject_scope_count integer:=0;
  target_role text;
begin
  if target_user_id is null then
    return jsonb_build_object('user_id',null,'class_scopes',0,'subject_scopes',0);
  end if;

  select public.current_app_role_for(p.role)
  into target_role
  from public.profiles p
  where p.id=target_user_id and p.active;

  delete from public.user_class_access
  where user_id=target_user_id;

  if target_role not in ('class_teacher','subject_teacher') then
    return jsonb_build_object('user_id',target_user_id,'class_scopes',0,'subject_scopes',0);
  end if;

  insert into public.user_class_access(user_id,class_id,subject_id,access_level)
  select target_user_id,c.id,null,'edit'
  from public.classes c
  where c.class_teacher_id=target_user_id
    and c.active
    and c.deleted_at is null;
  get diagnostics class_scope_count=row_count;

  insert into public.user_class_access(user_id,class_id,subject_id,access_level)
  select target_user_id,cs.class_id,cs.subject_id,'score'
  from public.class_subjects cs
  join public.classes c on c.id=cs.class_id
  join public.subjects s on s.id=cs.subject_id
  where cs.teacher_id=target_user_id
    and cs.active
    and c.active and c.deleted_at is null
    and s.active and s.deleted_at is null
  on conflict do nothing;
  get diagnostics subject_scope_count=row_count;

  return jsonb_build_object(
    'user_id',target_user_id,
    'class_scopes',class_scope_count,
    'subject_scopes',subject_scope_count
  );
end $$;

create or replace function public.sync_class_teacher_responsibility_trigger()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if tg_op in ('UPDATE','DELETE') and old.class_teacher_id is not null then
    perform public.sync_teacher_responsibility_access(old.class_teacher_id);
  end if;
  if tg_op in ('INSERT','UPDATE') and new.class_teacher_id is not null
     and (tg_op='INSERT' or new.class_teacher_id is distinct from old.class_teacher_id
          or new.active is distinct from old.active
          or new.deleted_at is distinct from old.deleted_at) then
    perform public.sync_teacher_responsibility_access(new.class_teacher_id);
  end if;
  return case when tg_op='DELETE' then old else new end;
end $$;

create or replace function public.sync_subject_teacher_responsibility_trigger()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if tg_op in ('UPDATE','DELETE') and old.teacher_id is not null then
    perform public.sync_teacher_responsibility_access(old.teacher_id);
  end if;
  if tg_op in ('INSERT','UPDATE') and new.teacher_id is not null
     and (tg_op='INSERT' or new.teacher_id is distinct from old.teacher_id
          or new.class_id is distinct from old.class_id
          or new.subject_id is distinct from old.subject_id
          or new.active is distinct from old.active) then
    perform public.sync_teacher_responsibility_access(new.teacher_id);
  end if;
  return case when tg_op='DELETE' then old else new end;
end $$;

drop trigger if exists sync_class_teacher_responsibility on public.classes;
create trigger sync_class_teacher_responsibility
after insert or delete or update of class_teacher_id,active,deleted_at
on public.classes
for each row execute function public.sync_class_teacher_responsibility_trigger();

drop trigger if exists sync_subject_teacher_responsibility on public.class_subjects;
create trigger sync_subject_teacher_responsibility
after insert or delete or update of teacher_id,class_id,subject_id,active
on public.class_subjects
for each row execute function public.sync_subject_teacher_responsibility_trigger();

create or replace function public.admin_validate_user_bundle(actor_id uuid,bundle jsonb,require_existing_user boolean default false)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  targetid uuid:=public.safe_uuid(bundle->>'user_id');
  staffrecordid uuid:=public.safe_uuid(bundle->>'staff_record_id');
  role_text text:=btrim(coalesce(bundle->>'role','viewer'));
  item jsonb; classid uuid; subjectid uuid; accesslevel text; scopekey text;
  seen_scopes text[]:='{}'::text[]; has_class_scope boolean:=false;
begin
  if actor_id is null or not exists(select 1 from public.profiles p where p.id=actor_id and p.active and public.current_app_role_for(p.role)='system_admin') then raise exception 'Access denied' using errcode='42501'; end if;
  if require_existing_user and (targetid is null or not exists(select 1 from auth.users u where u.id=targetid)) then raise exception 'Authentication account was not found'; end if;
  if btrim(coalesce(bundle->>'staff_record_id',''))<>'' and staffrecordid is null then raise exception 'Selected staff record is invalid'; end if;
  if btrim(coalesce(bundle->>'full_name',''))='' then raise exception 'Full name is required'; end if;
  if btrim(coalesce(bundle->>'email',''))='' then raise exception 'Email address is required'; end if;
  if bundle->>'email' !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Email address is invalid'; end if;
  if role_text not in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian') then raise exception 'User role is invalid'; end if;

  if role_text in ('class_teacher','subject_teacher') then
    if staffrecordid is null then raise exception 'Select the corresponding teacher record'; end if;
    if not exists(select 1 from public.teachers t where t.id=staffrecordid and t.deleted_at is null and t.active and (t.profile_id is null or t.profile_id=targetid)) then raise exception 'Selected teacher record is unavailable or already linked'; end if;
  elsif role_text='principal' then
    if staffrecordid is null then raise exception 'Select the corresponding Principal record'; end if;
    if not exists(select 1 from public.headteachers h where h.id=staffrecordid and h.deleted_at is null and h.active and (h.profile_id is null or h.profile_id=targetid)) then raise exception 'Selected Principal record is unavailable or already linked'; end if;
  elsif staffrecordid is not null then
    raise exception 'The selected role does not use a staff record';
  end if;

  if jsonb_typeof(coalesce(bundle->'access','[]'::jsonb))<>'array' then raise exception 'Delegated access must be a list'; end if;
  for item in select value from jsonb_array_elements(coalesce(bundle->'access','[]'::jsonb)) loop
    classid:=public.safe_uuid(item->>'class_id'); subjectid:=public.safe_uuid(item->>'subject_id'); accesslevel:=coalesce(nullif(btrim(item->>'access_level'),''),'view');
    if btrim(coalesce(item->>'class_id',''))<>'' and classid is null then raise exception 'A delegated class identifier is invalid'; end if;
    if btrim(coalesce(item->>'subject_id',''))<>'' and subjectid is null then raise exception 'A delegated subject identifier is invalid'; end if;
    if classid is null or not exists(select 1 from public.classes c where c.id=classid and c.deleted_at is null and c.active) then raise exception 'A delegated class is invalid or inactive'; end if;
    if subjectid is not null and not exists(select 1 from public.class_subjects cs join public.subjects s on s.id=cs.subject_id where cs.class_id=classid and cs.subject_id=subjectid and cs.active and s.active and s.deleted_at is null) then raise exception 'A delegated subject is not actively assigned to the selected class'; end if;
    if accesslevel not in ('view','edit','score','review') then raise exception 'Delegated access level is invalid'; end if;
    if role_text='subject_teacher' and subjectid is null then raise exception 'Subject teacher access must identify a subject'; end if;
    if role_text='subject_teacher' and accesslevel not in ('score','edit','review') then raise exception 'Subject teacher access must permit scoring'; end if;
    if role_text='class_teacher' and subjectid is null and accesslevel not in ('edit','review') then raise exception 'Class teacher access must permit class report editing'; end if;
    if role_text='class_teacher' and subjectid is null and accesslevel in ('edit','review') then has_class_scope:=true; end if;
    scopekey:=classid::text||'|'||coalesce(subjectid::text,'*');
    if scopekey=any(seen_scopes) then raise exception 'The same delegated class or subject access was entered more than once'; end if;
    seen_scopes:=array_append(seen_scopes,scopekey);
  end loop;
  return jsonb_build_object('valid',true,'role',role_text,'staff_record_id',staffrecordid,'access_count',coalesce(jsonb_array_length(bundle->'access'),0));
end $$;

create or replace function public.admin_apply_user_bundle(actor_id uuid,bundle jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  targetid uuid:=public.safe_uuid(bundle->>'user_id');
  staffrecordid uuid:=public.safe_uuid(bundle->>'staff_record_id');
  role_text text:=btrim(coalesce(bundle->>'role','viewer'));
  item jsonb; classid uuid; subjectid uuid; accesslevel text; previous jsonb;
  resolved_name text:=btrim(coalesce(bundle->>'full_name',''));
  resolved_phone text:=btrim(coalesce(bundle->>'phone',''));
begin
  perform public.admin_validate_user_bundle(actor_id,bundle,true);
  if role_text in ('class_teacher','subject_teacher') then
    select concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name),coalesce(nullif(t.phone,''),resolved_phone)
      into resolved_name,resolved_phone from public.teachers t where t.id=staffrecordid and t.deleted_at is null;
  elsif role_text='principal' then
    select concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),coalesce(nullif(h.phone,''),resolved_phone)
      into resolved_name,resolved_phone from public.headteachers h where h.id=staffrecordid and h.deleted_at is null;
  end if;

  select jsonb_build_object(
    'profile',to_jsonb(p),
    'teacher',(select to_jsonb(t) from public.teachers t where t.profile_id=targetid and t.deleted_at is null limit 1),
    'principal',(select to_jsonb(h) from public.headteachers h where h.profile_id=targetid and h.deleted_at is null limit 1),
    'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb)
  ) into previous from public.profiles p where p.id=targetid;

  insert into public.profiles(id,full_name,role,active,mfa_required,must_change_password,phone,updated_at)
  values(targetid,resolved_name,role_text::public.app_role,public.safe_boolean(bundle->>'active',true),
    public.safe_boolean(bundle->>'mfa_required',false),public.safe_boolean(bundle->>'must_change_password',false),resolved_phone,now())
  on conflict(id) do update set full_name=excluded.full_name,role=excluded.role,active=excluded.active,
    mfa_required=excluded.mfa_required,must_change_password=excluded.must_change_password,
    phone=excluded.phone,updated_at=now();

  update public.teachers set profile_id=null,updated_at=now()
    where profile_id=targetid and (role_text not in ('class_teacher','subject_teacher') or id<>staffrecordid);
  update public.headteachers set profile_id=null,updated_at=now()
    where profile_id=targetid and (role_text<>'principal' or id<>staffrecordid);
  if role_text in ('class_teacher','subject_teacher') then
    update public.teachers set profile_id=targetid,updated_at=now() where id=staffrecordid and deleted_at is null;
  elsif role_text='principal' then
    update public.headteachers set profile_id=targetid,updated_at=now() where id=staffrecordid and deleted_at is null;
  end if;

  delete from public.user_class_access where user_id=targetid;
  for item in select value from jsonb_array_elements(coalesce(bundle->'access','[]'::jsonb)) loop
    classid:=public.safe_uuid(item->>'class_id'); subjectid:=public.safe_uuid(item->>'subject_id'); accesslevel:=coalesce(nullif(btrim(item->>'access_level'),''),'view');
    insert into public.user_class_access(user_id,class_id,subject_id,access_level) values(targetid,classid,subjectid,accesslevel);
  end loop;

  if role_text in ('class_teacher','subject_teacher') then
    perform public.sync_teacher_responsibility_access(targetid);
  end if;

  insert into public.audit_log(actor_id,table_name,record_id,action,old_data,new_data,reason)
  values(actor_id,'profiles',targetid,case when previous is null then 'ADMIN_CREATE_USER' else 'ADMIN_UPDATE_USER' end,
    previous,jsonb_build_object('profile',(select to_jsonb(p) from public.profiles p where p.id=targetid),
      'teacher',(select to_jsonb(t) from public.teachers t where t.profile_id=targetid and t.deleted_at is null limit 1),
      'principal',(select to_jsonb(h) from public.headteachers h where h.profile_id=targetid and h.deleted_at is null limit 1),
      'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb)),
    coalesce(nullif(bundle->>'reason',''),'User account management'));
  return jsonb_build_object('profile',(select to_jsonb(p) from public.profiles p where p.id=targetid),
    'teacher',(select to_jsonb(t) from public.teachers t where t.profile_id=targetid and t.deleted_at is null limit 1),
    'principal',(select to_jsonb(h) from public.headteachers h where h.profile_id=targetid and h.deleted_at is null limit 1),
    'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb));
end $$;

create or replace function public.list_profiles_with_access()
returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  return jsonb_build_object(
    'profiles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'full_name',p.full_name,'email',au.email,'role',public.current_app_role_for(p.role),
      'active',p.active,'mfa_required',p.mfa_required,'must_change_password',p.must_change_password,'phone',p.phone,'last_seen_at',p.last_seen_at,
      'account_created_at',au.created_at,'email_confirmed_at',au.email_confirmed_at,'last_sign_in_at',au.last_sign_in_at,
      'teacher_id',t.id,'headteacher_id',h.id,'staff_record_id',coalesce(h.id,t.id),'staff_no',coalesce(h.staff_no,t.staff_no),
      'access',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'class_id',a.class_id,'class_name',c.name,'subject_id',a.subject_id,'subject_name',sub.name,'access_level',a.access_level) order by c.name,sub.name nulls first)
        from public.user_class_access a join public.classes c on c.id=a.class_id left join public.subjects sub on sub.id=a.subject_id where a.user_id=p.id),'[]'::jsonb)
      ) order by p.full_name)
      from public.profiles p left join auth.users au on au.id=p.id
      left join public.teachers t on t.profile_id=p.id and t.deleted_at is null
      left join public.headteachers h on h.profile_id=p.id and h.deleted_at is null
      where public.current_app_role_for(p.role) in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian')),'[]'::jsonb),
    'teacher_records',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'profile_id',t.profile_id,'staff_no',t.staff_no,'first_name',t.first_name,'middle_name',t.middle_name,'last_name',t.last_name,'full_name',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name),'label',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name)||' • '||t.staff_no::text,'phone',t.phone,'email',t.email,'active',t.active) order by t.last_name,t.first_name) from public.teachers t where t.deleted_at is null and t.active),'[]'::jsonb),
    'headteacher_records',coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'profile_id',h.profile_id,'staff_no',h.staff_no,'first_name',h.first_name,'middle_name',h.middle_name,'last_name',h.last_name,'full_name',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),'label',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name)||' • '||h.staff_no::text,'phone',h.phone,'email',h.email,'active',h.active) order by h.last_name,h.first_name) from public.headteachers h where h.deleted_at is null and h.active),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(sub) order by sub.display_order,sub.name) from public.subjects sub where sub.deleted_at is null),'[]'::jsonb),
    'class_subjects',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'class_id',cs.class_id,'subject_id',cs.subject_id,'teacher_id',cs.teacher_id,'active',cs.active)) from public.class_subjects cs),'[]'::jsonb)
  );
end $$;

create or replace function public.can_access_class(target_class_id uuid,require_write boolean default false)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select case
    when public.current_app_role() in ('system_admin','principal') then not require_write
    when public.current_app_role() in ('class_teacher','subject_teacher') then
      exists(
        select 1
        from public.classes c
        where c.id=target_class_id
          and c.active
          and c.deleted_at is null
          and c.class_teacher_id=auth.uid()
      )
      or exists(
        select 1
        from public.class_subjects cs
        join public.classes c on c.id=cs.class_id
        join public.subjects s on s.id=cs.subject_id
        where cs.class_id=target_class_id
          and cs.teacher_id=auth.uid()
          and cs.active
          and c.active and c.deleted_at is null
          and s.active and s.deleted_at is null
      )
      or exists(
        select 1
        from public.user_class_access a
        where a.user_id=auth.uid()
          and a.class_id=target_class_id
          and (not require_write or a.access_level in ('edit','score','review'))
      )
    else false
  end
$$;

create or replace function public.can_score_class_subject(target_class_id uuid,target_subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.current_app_role() in ('class_teacher','subject_teacher')
    and (
      exists(
        select 1
        from public.class_subjects cs
        join public.classes c on c.id=cs.class_id
        join public.subjects s on s.id=cs.subject_id
        where cs.class_id=target_class_id
          and cs.subject_id=target_subject_id
          and cs.teacher_id=auth.uid()
          and cs.active
          and c.active and c.deleted_at is null
          and s.active and s.deleted_at is null
      )
      or exists(
        select 1
        from public.user_class_access a
        where a.user_id=auth.uid()
          and a.class_id=target_class_id
          and a.subject_id=target_subject_id
          and a.access_level in ('score','edit','review')
      )
    )
$$;

do $$
declare teacher_row record;
begin
  for teacher_row in
    select p.id
    from public.profiles p
    where p.active
      and public.current_app_role_for(p.role) in ('class_teacher','subject_teacher')
  loop
    perform public.sync_teacher_responsibility_access(teacher_row.id);
  end loop;
end $$;

revoke all on function public.sync_teacher_responsibility_access(uuid) from public,anon,authenticated;
revoke all on function public.sync_class_teacher_responsibility_trigger() from public,anon,authenticated;
revoke all on function public.sync_subject_teacher_responsibility_trigger() from public,anon,authenticated;
grant execute on function public.sync_teacher_responsibility_access(uuid) to service_role;

commit;

-- =============================================================================
-- ENTERPRISE RELEASE 6.5.9 CLASS TEACHER STAFF-RECORD SELECTION
-- Permanent location: Database Part 3B
-- =============================================================================
begin;

alter table public.classes
  add column if not exists class_teacher_record_id uuid
  references public.teachers(id) on delete set null;

create index if not exists classes_class_teacher_record_idx
  on public.classes(class_teacher_record_id)
  where deleted_at is null and class_teacher_record_id is not null;

update public.classes c
set class_teacher_record_id=t.id
from public.teachers t
where c.class_teacher_record_id is null
  and c.class_teacher_id is not null
  and t.profile_id=c.class_teacher_id
  and t.deleted_at is null;

create or replace function public.sync_teacher_record_class_links()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  old_profile_id uuid;
  new_profile_id uuid;
begin
  old_profile_id:=case when tg_op='INSERT' then null else old.profile_id end;
  new_profile_id:=case
    when tg_op='DELETE' then null
    when new.active and new.deleted_at is null and new.employment_status='active' then new.profile_id
    else null
  end;

  if tg_op='DELETE'
     or not new.active
     or new.deleted_at is not null
     or new.employment_status<>'active' then
    update public.classes
    set class_teacher_record_id=null,
        class_teacher_id=null,
        updated_at=now()
    where class_teacher_record_id=case when tg_op='DELETE' then old.id else new.id end;
  else
    update public.classes
    set class_teacher_id=new_profile_id,
        updated_at=now()
    where class_teacher_record_id=new.id
      and class_teacher_id is distinct from new_profile_id;
  end if;

  if old_profile_id is not null then
    perform public.sync_teacher_responsibility_access(old_profile_id);
  end if;
  if new_profile_id is not null and new_profile_id is distinct from old_profile_id then
    perform public.sync_teacher_responsibility_access(new_profile_id);
  end if;

  return case when tg_op='DELETE' then old else new end;
end $$;

drop trigger if exists sync_teacher_record_class_links_trigger on public.teachers;
create trigger sync_teacher_record_class_links_trigger
after insert or delete or update of profile_id,active,deleted_at,employment_status
on public.teachers
for each row execute function public.sync_teacher_record_class_links();

create or replace function public.get_academic_configuration()
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  return jsonb_build_object(
    'academic_years',coalesce((select jsonb_agg(to_jsonb(x) order by x.start_date desc nulls last) from public.academic_years x where x.deleted_at is null),'[]'::jsonb),
    'terms',coalesce((select jsonb_agg(to_jsonb(x) order by x.academic_year_id,x.sequence) from public.terms x where x.deleted_at is null),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(x) order by x.level_order,x.name) from public.classes x where x.deleted_at is null),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(x) order by x.display_order,x.name) from public.subjects x where x.deleted_at is null),'[]'::jsonb),
    'class_subjects',coalesce((select jsonb_agg(jsonb_build_object(
      'id',cs.id,'class_id',cs.class_id,'class_name',c.name,'subject_id',cs.subject_id,'subject_name',s.name,
      'teacher_id',cs.teacher_id,'teacher_name',p.full_name,'active',cs.active
    ) order by c.level_order,c.name,s.display_order,s.name)
      from public.class_subjects cs join public.classes c on c.id=cs.class_id join public.subjects s on s.id=cs.subject_id
      left join public.profiles p on p.id=cs.teacher_id),'[]'::jsonb),
    'grading_scales',coalesce((select jsonb_agg(to_jsonb(x) order by x.display_order,x.min_mark desc) from public.grading_scales x where x.deleted_at is null),'[]'::jsonb),
    'assessment_schemes',coalesce((select jsonb_agg(jsonb_build_object(
      'id',s.id,'name',s.name,'academic_year_id',s.academic_year_id,'term_id',s.term_id,
      'class_id',s.class_id,'subject_id',s.subject_id,'active',s.active,
      'components',coalesce((select jsonb_agg(to_jsonb(c) order by c.display_order,c.name)
        from public.assessment_components c where c.scheme_id=s.id),'[]'::jsonb),
      'total_weight',(select coalesce(sum(c.weight),0) from public.assessment_components c where c.scheme_id=s.id)
    ) order by s.name) from public.assessment_schemes s where s.deleted_at is null),'[]'::jsonb),
    'profiles',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'full_name',p.full_name,'role',public.current_app_role_for(p.role))
      order by p.full_name) from public.profiles p where p.active),'[]'::jsonb),
    'teacher_records',coalesce((select jsonb_agg(jsonb_build_object(
      'id',t.id,
      'profile_id',t.profile_id,
      'staff_no',t.staff_no,
      'full_name',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name),
      'label',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name)
        ||' • '||t.staff_no::text
        ||case when t.profile_id is null then ' • No linked account' else '' end,
      'active',t.active
    ) order by t.last_name,t.first_name)
      from public.teachers t
      where t.deleted_at is null and t.active and t.employment_status='active'),'[]'::jsonb)
  );
end $$;

create or replace function public.save_academic_entity(entity_type text,payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  targetid uuid:=public.safe_uuid(payload->>'id');
  affected integer;
  startdate date:=public.safe_date(payload->>'start_date');
  enddate date:=public.safe_date(payload->>'end_date');
  nextdate date:=public.safe_date(payload->>'next_term_begins');
  yearid uuid:=public.safe_uuid(payload->>'academic_year_id');
  teacherid uuid:=public.safe_uuid(payload->>'class_teacher_id');
  teacherrecordid uuid:=public.safe_uuid(payload->>'class_teacher_record_id');
  seq integer:=public.safe_integer(payload->>'sequence');
  orderno integer;
  subjectcode text;
  existingcode text;
  recordname text:=regexp_replace(btrim(coalesce(payload->>'name','')),'[[:space:]]+',' ','g');
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(payload->>'id',''))<>'' and targetid is null then raise exception 'Academic record identifier is invalid'; end if;
  if btrim(coalesce(payload->>'start_date',''))<>'' and startdate is null then raise exception 'Start date is invalid'; end if;
  if btrim(coalesce(payload->>'end_date',''))<>'' and enddate is null then raise exception 'End date is invalid'; end if;
  if btrim(coalesce(payload->>'next_term_begins',''))<>'' and nextdate is null then raise exception 'Next term date is invalid'; end if;
  if btrim(coalesce(payload->>'academic_year_id',''))<>'' and yearid is null then raise exception 'Academic year identifier is invalid'; end if;
  if btrim(coalesce(payload->>'class_teacher_id',''))<>'' and teacherid is null then raise exception 'Class teacher account identifier is invalid'; end if;
  if btrim(coalesce(payload->>'class_teacher_record_id',''))<>'' and teacherrecordid is null then raise exception 'Class teacher record identifier is invalid'; end if;
  if startdate is not null and enddate is not null and startdate>enddate then raise exception 'Start date cannot be after end date'; end if;
  if nextdate is not null and enddate is not null and nextdate<enddate then raise exception 'Next term date cannot be before the term end date'; end if;
  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Academic record update'),true);

  if entity_type='academic_years' then
    if recordname='' then raise exception 'Academic year name is required'; end if;
    if targetid is null then
      select y.id into targetid
      from public.academic_years y
      where lower(y.name::text)=lower(recordname) and y.deleted_at is not null
      order by y.updated_at desc,y.created_at desc limit 1 for update;
      if targetid is null then
        insert into public.academic_years(name,start_date,end_date)
        values(recordname,startdate,enddate) returning id into targetid;
      else
        update public.academic_years
        set name=recordname,start_date=startdate,end_date=enddate,is_active=false,deleted_at=null,updated_at=now()
        where id=targetid;
      end if;
    else
      update public.academic_years
      set name=recordname,start_date=startdate,end_date=enddate,updated_at=now()
      where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='terms' then
    if yearid is null or not exists(select 1 from public.academic_years y where y.id=yearid and y.deleted_at is null) then raise exception 'Academic year is invalid'; end if;
    if recordname='' then raise exception 'Term name is required'; end if;
    if seq is null or seq not between 1 and 6 then raise exception 'Term sequence must be between 1 and 6'; end if;
    if targetid is null then
      select t.id into targetid
      from public.terms t
      where t.academic_year_id=yearid and t.deleted_at is not null
        and (lower(t.name::text)=lower(recordname) or t.sequence=seq)
      order by ((lower(t.name::text)=lower(recordname)) and t.sequence=seq) desc,t.updated_at desc,t.created_at desc
      limit 1 for update;
      if targetid is null then
        insert into public.terms(academic_year_id,name,sequence,start_date,end_date,next_term_begins)
        values(yearid,recordname,seq,startdate,enddate,nextdate) returning id into targetid;
      else
        update public.terms
        set academic_year_id=yearid,name=recordname,sequence=seq,start_date=startdate,end_date=enddate,
          next_term_begins=nextdate,is_active=false,deleted_at=null,updated_at=now()
        where id=targetid;
      end if;
    else
      update public.terms
      set academic_year_id=yearid,name=recordname,sequence=seq,start_date=startdate,end_date=enddate,
        next_term_begins=nextdate,updated_at=now()
      where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='classes' then
    if recordname='' then raise exception 'Class name is required'; end if;
    orderno:=coalesce(public.safe_integer(payload->>'level_order'),0);

    if teacherrecordid is not null then
      select t.profile_id
      into teacherid
      from public.teachers t
      where t.id=teacherrecordid
        and t.deleted_at is null
        and t.active
        and t.employment_status='active';
      if not found then raise exception 'Selected class teacher record is inactive or unavailable'; end if;
    elsif teacherid is not null then
      select t.id
      into teacherrecordid
      from public.teachers t
      where t.profile_id=teacherid
        and t.deleted_at is null
        and t.active
        and t.employment_status='active'
      order by t.updated_at desc
      limit 1;
    end if;

    if teacherid is not null and not exists(
      select 1 from public.profiles p
      where p.id=teacherid
        and p.active
        and public.current_app_role_for(p.role) in ('class_teacher','subject_teacher')
    ) then
      teacherid:=null;
    end if;

    if targetid is null then
      select c.id into targetid
      from public.classes c
      where lower(c.name::text)=lower(recordname) and c.deleted_at is not null
      order by c.updated_at desc,c.created_at desc limit 1 for update;
      if targetid is null then
        insert into public.classes(name,level_order,class_teacher_record_id,class_teacher_id,active)
        values(recordname,orderno,teacherrecordid,teacherid,public.safe_boolean(payload->>'active',true))
        returning id into targetid;
      else
        update public.classes
        set name=recordname,
            level_order=orderno,
            class_teacher_record_id=teacherrecordid,
            class_teacher_id=teacherid,
            active=public.safe_boolean(payload->>'active',true),
            deleted_at=null,
            updated_at=now()
        where id=targetid;
      end if;
    else
      update public.classes
      set name=recordname,
          level_order=orderno,
          class_teacher_record_id=teacherrecordid,
          class_teacher_id=teacherid,
          active=public.safe_boolean(payload->>'active',true),
          updated_at=now()
      where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='subjects' then
    if recordname='' then raise exception 'Subject name is required'; end if;
    orderno:=coalesce(public.safe_integer(payload->>'display_order'),0);
    subjectcode:=upper(btrim(coalesce(payload->>'code','')));
    if targetid is null then
      select s.id,s.code::text into targetid,existingcode
      from public.subjects s
      where lower(s.name::text)=lower(recordname) and s.deleted_at is not null
      order by s.updated_at desc,s.created_at desc limit 1 for update;
      if targetid is null then
        if subjectcode='' or exists(select 1 from public.subjects s where lower(s.code::text)=lower(subjectcode)) then
          subjectcode:=public.generate_subject_code(recordname,null);
        end if;
        insert into public.subjects(code,name,display_order,active)
        values(subjectcode,recordname,orderno,public.safe_boolean(payload->>'active',true)) returning id into targetid;
      else
        subjectcode:=coalesce(nullif(subjectcode,''),existingcode);
        if exists(select 1 from public.subjects s where lower(s.code::text)=lower(subjectcode) and s.id<>targetid) then
          subjectcode:=public.generate_subject_code(recordname,targetid);
        end if;
        update public.subjects
        set code=subjectcode,name=recordname,display_order=orderno,
          active=public.safe_boolean(payload->>'active',true),deleted_at=null,updated_at=now()
        where id=targetid;
      end if;
    else
      select s.code::text into existingcode
      from public.subjects s where s.id=targetid and s.deleted_at is null for update;
      if not found then raise exception 'Subject not found'; end if;
      subjectcode:=coalesce(nullif(subjectcode,''),existingcode);
      if exists(select 1 from public.subjects s where lower(s.code::text)=lower(subjectcode) and s.id<>targetid) then
        subjectcode:=public.generate_subject_code(recordname,targetid);
      end if;
      update public.subjects
      set code=subjectcode,name=recordname,display_order=orderno,
        active=public.safe_boolean(payload->>'active',true),updated_at=now()
      where id=targetid and deleted_at is null;
    end if;
  else
    raise exception 'Unsupported academic record type';
  end if;

  get diagnostics affected=row_count;
  if targetid is null or affected=0 then raise exception 'Academic record was not saved'; end if;
  return public.get_academic_configuration();
exception when unique_violation then
  if entity_type='academic_years' then raise exception 'An academic year with this name already exists';
  elsif entity_type='terms' then raise exception 'A term with this name or sequence already exists in the selected academic year';
  elsif entity_type='classes' then raise exception 'A class with this name already exists';
  elsif entity_type='subjects' then raise exception 'A subject with this name or code already exists';
  else raise exception 'An academic record already uses these details';
  end if;
end $$;

create or replace function public.list_teachers(
  search_text text default '',status_filter text default '',archive_filter text default 'active',
  page_number integer default 1,page_size integer default 20
)
returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
declare offset_value integer:=greatest(page_number-1,0)*least(greatest(page_size,1),100);
declare limit_value integer:=least(greatest(page_size,1),100);
begin
  if not public.can_manage_teachers() then raise exception 'Access denied' using errcode='42501'; end if;
  if archive_filter not in ('active','archived','all') then archive_filter:='active'; end if;
  return (
    with matching as (
      select t.id,t.profile_id,t.staff_no,t.first_name,t.middle_name,t.last_name,t.gender,t.phone,
        t.email,t.address,t.qualification,t.specialization,t.date_joined,t.employment_status,t.notes,
        t.active,t.deleted_at,t.created_at,t.updated_at,
        concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name) full_name,
        p.role profile_role,p.active profile_active,au.email profile_email,
        coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.level_order,c.name)
          from public.classes c
          where c.deleted_at is null
            and (c.class_teacher_record_id=t.id
              or (c.class_teacher_record_id is null and t.profile_id is not null and c.class_teacher_id=t.profile_id))
        ),'[]'::jsonb) class_assignments,
        coalesce((select jsonb_agg(jsonb_build_object('class_id',c.id,'class_name',c.name,'subject_id',s.id,'subject_name',s.name)
          order by c.level_order,c.name,s.display_order,s.name)
          from public.class_subjects cs join public.classes c on c.id=cs.class_id
          join public.subjects s on s.id=cs.subject_id
          where cs.teacher_id=t.profile_id and cs.active and c.deleted_at is null and s.deleted_at is null),'[]'::jsonb) subject_assignments
      from public.teachers t
      left join public.profiles p on p.id=t.profile_id
      left join auth.users au on au.id=t.profile_id
      where (archive_filter='all'
        or (archive_filter='active' and t.deleted_at is null)
        or (archive_filter='archived' and t.deleted_at is not null))
        and (coalesce(status_filter,'')='' or t.employment_status=status_filter)
        and (coalesce(search_text,'')='' or t.staff_no::text ilike '%'||search_text||'%'
          or concat_ws(' ',t.first_name,t.middle_name,t.last_name) ilike '%'||search_text||'%'
          or coalesce(t.email::text,'') ilike '%'||search_text||'%'
          or coalesce(t.phone,'') ilike '%'||search_text||'%')
    )
    select jsonb_build_object(
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by x.last_name,x.first_name) from (
        select * from matching order by last_name,first_name limit limit_value offset offset_value
      ) x),'[]'::jsonb),
      'total',(select count(*) from matching),
      'page',greatest(page_number,1),'page_size',limit_value,
      'profiles',coalesce((select jsonb_agg(jsonb_build_object(
        'id',p.id,'full_name',p.full_name,'role',public.current_app_role_for(p.role),'email',au.email
      ) order by p.full_name)
        from public.profiles p left join auth.users au on au.id=p.id
        where p.active and public.current_app_role_for(p.role) in ('system_admin','headteacher','academic_admin','class_teacher','subject_teacher')),'[]'::jsonb)
    )
  );
end $$;

create or replace function public.get_teacher_record(target_teacher_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
begin
  if not public.can_manage_teachers() and not exists(
    select 1 from public.teachers t where t.id=target_teacher_id and t.profile_id=auth.uid()
  ) then raise exception 'Access denied' using errcode='42501'; end if;
  return (
    select jsonb_build_object(
      'teacher',to_jsonb(t)||jsonb_build_object(
        'full_name',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name),
        'profile_email',au.email,
        'profile_name',p.full_name,
        'profile_role',case when p.id is null then null else public.current_app_role_for(p.role) end
      ),
      'classes',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.level_order,c.name)
        from public.classes c
        where c.deleted_at is null
          and (c.class_teacher_record_id=t.id
            or (c.class_teacher_record_id is null and t.profile_id is not null and c.class_teacher_id=t.profile_id))
      ),'[]'::jsonb),
      'subjects',coalesce((select jsonb_agg(jsonb_build_object('class_id',c.id,'class_name',c.name,'subject_id',s.id,'subject_name',s.name)
        order by c.level_order,c.name,s.display_order,s.name)
        from public.class_subjects cs join public.classes c on c.id=cs.class_id
        join public.subjects s on s.id=cs.subject_id
        where cs.teacher_id=t.profile_id and cs.active and c.deleted_at is null and s.deleted_at is null),'[]'::jsonb)
    )
    from public.teachers t left join public.profiles p on p.id=t.profile_id
    left join auth.users au on au.id=t.profile_id where t.id=target_teacher_id
  );
end $$;

do $$
declare teacher_row record;
begin
  for teacher_row in
    select t.id,t.profile_id
    from public.teachers t
    where t.deleted_at is null
      and t.active
      and t.employment_status='active'
  loop
    update public.classes
    set class_teacher_id=teacher_row.profile_id,
        updated_at=now()
    where class_teacher_record_id=teacher_row.id
      and class_teacher_id is distinct from teacher_row.profile_id;
    if teacher_row.profile_id is not null then
      perform public.sync_teacher_responsibility_access(teacher_row.profile_id);
    end if;
  end loop;
end $$;

revoke all on function public.sync_teacher_record_class_links() from public,anon,authenticated;

-- v6.6.3: class-range report-card template management
create table if not exists public.report_card_templates (
  range_key text primary key,
  storage_path text not null unique,
  original_name text not null,
  mime_type text not null,
  file_size bigint not null,
  checksum text not null default '',
  version integer not null default 1,
  active boolean not null default true,
  uploaded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint report_card_templates_range_chk check (range_key in ('early_years','basic_1_6','basic_7_9')),
  constraint report_card_templates_mime_chk check (mime_type in ('application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document')),
  constraint report_card_templates_size_chk check (file_size > 0 and file_size <= 20971520),
  constraint report_card_templates_version_chk check (version > 0),
  constraint report_card_templates_path_chk check (storage_path like range_key || '/%')
);
alter table public.report_card_templates add column if not exists range_key text;
alter table public.report_card_templates add column if not exists storage_path text;
alter table public.report_card_templates add column if not exists original_name text;
alter table public.report_card_templates add column if not exists mime_type text;
alter table public.report_card_templates add column if not exists file_size bigint;
alter table public.report_card_templates add column if not exists checksum text not null default '';
alter table public.report_card_templates add column if not exists version integer not null default 1;
alter table public.report_card_templates add column if not exists active boolean not null default true;
alter table public.report_card_templates add column if not exists uploaded_by uuid references public.profiles(id) on delete set null;
alter table public.report_card_templates add column if not exists created_at timestamptz not null default now();
alter table public.report_card_templates add column if not exists updated_at timestamptz not null default now();

create unique index if not exists report_card_templates_storage_path_uidx on public.report_card_templates(storage_path);

drop trigger if exists report_card_templates_set_updated_at on public.report_card_templates;
create trigger report_card_templates_set_updated_at before update on public.report_card_templates
for each row execute function public.set_updated_at();

drop trigger if exists report_card_templates_audit on public.report_card_templates;
create trigger report_card_templates_audit after insert or update or delete on public.report_card_templates
for each row execute function public.audit_row_change();

drop trigger if exists report_card_templates_broadcast on public.report_card_templates;
create trigger report_card_templates_broadcast after insert or update or delete on public.report_card_templates
for each row execute function public.broadcast_application_change();

alter table public.report_card_templates enable row level security;
drop policy if exists report_card_templates_read on public.report_card_templates;
create policy report_card_templates_read on public.report_card_templates for select to authenticated using(true);
drop policy if exists report_card_templates_admin on public.report_card_templates;
create policy report_card_templates_admin on public.report_card_templates for all to authenticated
using(public.is_system_admin()) with check(public.is_system_admin());

grant select,insert,update,delete on public.report_card_templates to authenticated;
grant all on public.report_card_templates to service_role;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('report-card-templates','report-card-templates',false,20971520,array['application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists report_card_templates_storage_read on storage.objects;
create policy report_card_templates_storage_read on storage.objects for select to authenticated
using(bucket_id='report-card-templates');

drop policy if exists report_card_templates_storage_insert on storage.objects;
create policy report_card_templates_storage_insert on storage.objects for insert to authenticated
with check(
  bucket_id='report-card-templates'
  and public.is_system_admin()
  and (storage.foldername(name))[1] in ('early_years','basic_1_6','basic_7_9')
);

drop policy if exists report_card_templates_storage_update on storage.objects;
create policy report_card_templates_storage_update on storage.objects for update to authenticated
using(bucket_id='report-card-templates' and public.is_system_admin())
with check(
  bucket_id='report-card-templates'
  and public.is_system_admin()
  and (storage.foldername(name))[1] in ('early_years','basic_1_6','basic_7_9')
);

drop policy if exists report_card_templates_storage_delete on storage.objects;
create policy report_card_templates_storage_delete on storage.objects for delete to authenticated
using(bucket_id='report-card-templates' and public.is_system_admin());

create or replace function public.list_report_card_templates()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(t) order by
      case t.range_key when 'early_years' then 1 when 'basic_1_6' then 2 else 3 end
    )
    from public.report_card_templates t
    where t.active
  ),'[]'::jsonb);
end $$;

create or replace function public.save_report_card_template(
  target_range_key text,
  target_storage_path text,
  target_original_name text,
  target_mime_type text,
  target_file_size bigint,
  target_checksum text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare result public.report_card_templates;
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  if target_range_key not in ('early_years','basic_1_6','basic_7_9') then raise exception 'Invalid report-card class range'; end if;
  if coalesce(btrim(target_storage_path),'')='' or target_storage_path not like target_range_key||'/%' then raise exception 'Invalid template storage path'; end if;
  if coalesce(btrim(target_original_name),'')='' or length(target_original_name)>255 then raise exception 'Invalid template file name'; end if;
  if target_mime_type not in ('application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document') then raise exception 'Unsupported template file type'; end if;
  if coalesce(target_file_size,0)<=0 or target_file_size>20971520 then raise exception 'Template file must be between 1 byte and 20 MB'; end if;
  if coalesce(length(target_checksum),0)>128 then raise exception 'Invalid template checksum'; end if;

  insert into public.report_card_templates(
    range_key,storage_path,original_name,mime_type,file_size,checksum,version,active,uploaded_by
  ) values(
    target_range_key,btrim(target_storage_path),btrim(target_original_name),target_mime_type,target_file_size,coalesce(target_checksum,''),1,true,auth.uid()
  )
  on conflict(range_key) do update set
    storage_path=excluded.storage_path,
    original_name=excluded.original_name,
    mime_type=excluded.mime_type,
    file_size=excluded.file_size,
    checksum=excluded.checksum,
    version=public.report_card_templates.version+1,
    active=true,
    uploaded_by=auth.uid(),
    updated_at=now()
  returning * into result;
  return to_jsonb(result);
end $$;

create or replace function public.remove_report_card_template(target_range_key text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare result public.report_card_templates;
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  if target_range_key not in ('early_years','basic_1_6','basic_7_9') then raise exception 'Invalid report-card class range'; end if;
  delete from public.report_card_templates where range_key=target_range_key returning * into result;
  return case when result.range_key is null then '{}'::jsonb else to_jsonb(result) end;
end $$;

revoke all on function public.list_report_card_templates() from public,anon;
revoke all on function public.save_report_card_template(text,text,text,text,bigint,text) from public,anon;
revoke all on function public.remove_report_card_template(text) from public,anon;
grant execute on function public.list_report_card_templates() to authenticated;
grant execute on function public.save_report_card_template(text,text,text,text,bigint,text) to authenticated;
grant execute on function public.remove_report_card_template(text) to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.report_card_templates;
exception when duplicate_object or undefined_object then null;
end $$;


commit;

-- END OF DATABASE PART 3B-2
