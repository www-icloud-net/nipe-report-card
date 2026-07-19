-- =============================================================================
-- NIPE INTERNATIONAL SCHOOL REPORT CARD ENTERPRISE v6.6.3
-- DATABASE FILE 02 OF 05: OPERATIONS, SECURITY, WORKFLOWS AND SERVICES
-- SINGLE-FILE SUPABASE SQL EDITOR EDITION
-- =============================================================================
-- Run this file only after 01_schema_foundation.sql completes successfully.
-- This is one permanent SQL file. It contains internal transaction checkpoints
-- so completed sections are committed safely without requiring separate files.
--
-- Supabase compatibility correction:
-- realtime.messages is a Supabase-managed table. This file creates the required
-- private-channel policies but does not ALTER the table, avoiding SQLSTATE 42501
-- (must be owner of table messages) on hosted Supabase projects.
-- =============================================================================

set statement_timeout = 0;
set idle_in_transaction_session_timeout = 0;
set client_min_messages = warning;


-- =============================================================================
-- INTERNAL CHECKPOINT 1 OF 8: 02A_core_operational_functions.sql
-- =============================================================================
-- NIPE INTERNATIONAL SCHOOL REPORT CARD SYSTEM
-- Enterprise v6.1.1 Dashboard Editor Edition
-- DATABASE PART 2 OF 3: SECURITY, WORKFLOWS AND OPERATIONAL SERVICES
-- Run this file only after Part 1 completes successfully.

begin;



create or replace function public.bulk_promote_class(
  source_academic_year_id uuid,source_class_id uuid,target_academic_year_id uuid,target_class_id uuid
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare promoted integer;
begin
  if not public.is_records_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  perform set_config('app.change_reason','Bulk class promotion',true);
  insert into public.enrollments(student_id,academic_year_id,class_id,active)
  select e.student_id,target_academic_year_id,target_class_id,true
  from public.enrollments e join public.students s on s.id=e.student_id
  where e.academic_year_id=source_academic_year_id and e.class_id=source_class_id
    and e.active and e.deleted_at is null and s.status='active' and s.deleted_at is null
  on conflict(student_id,academic_year_id) do update set class_id=excluded.class_id,active=true,deleted_at=null,updated_at=now();
  get diagnostics promoted=row_count;
  return jsonb_build_object('promoted',promoted);
end $$;

create or replace function public.export_backup_snapshot()
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  return jsonb_build_object(
    'generated_at',now(),'schema_version','2026.07.13',
    'school_settings',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.school_settings x),
    'profiles',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.profiles x),
    'academic_years',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.academic_years x),
    'terms',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.terms x),
    'classes',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.classes x),
    'subjects',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.subjects x),
    'class_subjects',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.class_subjects x),
    'students',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.students x),
    'guardians',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.student_guardians x),
    'guardian_links',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.guardian_links x),
    'enrollments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.enrollments x),
    'grading_scales',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.grading_scales x),
    'assessment_schemes',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.assessment_schemes x),
    'assessment_components',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.assessment_components x),
    'student_reports',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.student_reports x),
    'subject_results',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.subject_results x),
    'score_entries',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.assessment_score_entries x),
    'workflow',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.report_workflow_events x),
    'revisions',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.report_revisions x),
    'publications',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.report_publications x)
  );
end $$;

create or replace function public.system_health()
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.has_role(array['system_admin','headteacher','academic_admin']) then raise exception 'Access denied' using errcode='42501'; end if;
  return jsonb_build_object(
    'database_time',now(),
    'active_users',(select count(*) from public.profiles where active),
    'active_students',(select count(*) from public.students where status='active' and deleted_at is null),
    'pending_notifications',(select count(*) from public.notification_outbox where processed_at is null),
    'client_errors_24h',(select count(*) from public.client_error_events where created_at>=now()-interval '24 hours'),
    'latest_backup',(select max(created_at) from public.backup_exports where status='completed'),
    'incomplete_schemes',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'weight',q.total_weight)) from (
      select scheme_id,sum(weight) total_weight from public.assessment_components group by scheme_id having abs(sum(weight)-100)>0.01
    ) q join public.assessment_schemes s on s.id=q.scheme_id),'[]'::jsonb),
    'published_without_pdf',(select count(*) from public.report_publications where revoked_at is null and storage_path='')
  );
end $$;

create or replace function public.claim_notification_jobs(
  target_batch_size integer default 50,
  target_worker_id text default null
)
returns setof public.notification_outbox
language plpgsql security definer set search_path=public
as $$
declare worker text:=coalesce(nullif(btrim(target_worker_id),''),gen_random_uuid()::text);
begin
  if current_user not in ('postgres','service_role','supabase_admin')
     and coalesce(current_setting('request.jwt.claim.role',true),'')<>'service_role' then
    raise exception 'Access denied' using errcode='42501';
  end if;
  return query
  with candidates as (
    select o.id
    from public.notification_outbox o
    where o.processed_at is null
      and o.attempts<6
      and o.next_attempt_at<=now()
      and (o.locked_at is null or o.locked_at<now()-interval '15 minutes')
    order by o.created_at
    for update skip locked
    limit least(greatest(coalesce(target_batch_size,50),1),200)
  )
  update public.notification_outbox o
  set locked_at=now(),locked_by=worker
  from candidates c
  where o.id=c.id
  returning o.*;
end $$;

create or replace function public.complete_notification_job(
  target_job_id uuid,
  target_worker_id text,
  target_success boolean,
  target_error text default ''
)
returns boolean
language plpgsql security definer set search_path=public
as $$
declare changed integer;
begin
  if current_user not in ('postgres','service_role','supabase_admin')
     and coalesce(current_setting('request.jwt.claim.role',true),'')<>'service_role' then
    raise exception 'Access denied' using errcode='42501';
  end if;
  if target_success then
    update public.notification_outbox
    set processed_at=now(),attempts=attempts+1,last_error='',locked_at=null,locked_by=null
    where id=target_job_id and processed_at is null and locked_by=target_worker_id;
  else
    update public.notification_outbox
    set attempts=attempts+1,
        next_attempt_at=now()+(power(2,least(attempts+1,8))::text||' minutes')::interval,
        last_error=left(coalesce(target_error,''),2000),locked_at=null,locked_by=null
    where id=target_job_id and processed_at is null and locked_by=target_worker_id;
  end if;
  get diagnostics changed=row_count;
  return changed=1;
end $$;


commit;

-- =============================================================================
-- INTERNAL CHECKPOINT 2 OF 8: 02B_legacy_score_migration.sql
-- =============================================================================
begin;

-- Migrate legacy 30/70 scores into the configurable assessment model.
do $$
declare default_scheme uuid; ca_component uuid; exam_component uuid;
begin
  select id into default_scheme from public.assessment_schemes
  where lower(name)='standard 30/70' and academic_year_id is null and term_id is null and class_id is null and subject_id is null limit 1;
  select id into ca_component from public.assessment_components where scheme_id=default_scheme and code='CA';
  select id into exam_component from public.assessment_components where scheme_id=default_scheme and code='EXAM';
  perform set_config('app.report_write','on',true);
  insert into public.subject_results(report_id,subject_id,scheme_id,total_score,grade,remark,grade_point,teacher_initials,created_by,created_at,updated_at)
  select ss.report_id,ss.subject_id,default_scheme,least(ss.total,100),ss.grade,ss.remark,ss.grade_point,ss.teacher_initials,ss.created_by,ss.created_at,ss.updated_at
  from public.subject_scores ss
  on conflict(report_id,subject_id) do nothing;
  insert into public.assessment_score_entries(subject_result_id,component_id,raw_score,weighted_score,created_by,created_at,updated_at)
  select sr.id,ca_component,
    least(greatest(round((ss.class_score/nullif(sb.max_class_score,0))*30,2),0),30),
    least(greatest(round((ss.class_score/nullif(sb.max_class_score,0))*30,2),0),30),
    ss.created_by,ss.created_at,ss.updated_at
  from public.subject_scores ss
  join public.subject_results sr on sr.report_id=ss.report_id and sr.subject_id=ss.subject_id
  join public.subjects sb on sb.id=ss.subject_id
  where ca_component is not null on conflict(subject_result_id,component_id) do nothing;
  insert into public.assessment_score_entries(subject_result_id,component_id,raw_score,weighted_score,created_by,created_at,updated_at)
  select sr.id,exam_component,
    least(greatest(round((ss.exam_score/nullif(sb.max_exam_score,0))*70,2),0),70),
    least(greatest(round((ss.exam_score/nullif(sb.max_exam_score,0))*70,2),0),70),
    ss.created_by,ss.created_at,ss.updated_at
  from public.subject_scores ss
  join public.subject_results sr on sr.report_id=ss.report_id and sr.subject_id=ss.subject_id
  join public.subjects sb on sb.id=ss.subject_id
  where exam_component is not null on conflict(subject_result_id,component_id) do nothing;
end $$;



commit;

-- =============================================================================
-- INTERNAL CHECKPOINT 3 OF 8: 02C_reporting_and_academic_functions.sql
-- =============================================================================
begin;

create or replace function public.report_position(target_report_id uuid)
returns jsonb
language sql stable security definer set search_path=public
as $$
  with target as (
    select e.class_id,r.term_id,round(coalesce(avg(sr.total_score),0),2) average
    from public.student_reports r join public.enrollments e on e.id=r.enrollment_id
    left join public.subject_results sr on sr.report_id=r.id
    where r.id=target_report_id group by e.class_id,r.term_id
  ), ranked as (
    select r.id,round(coalesce(avg(sr.total_score),0),2) average,
      dense_rank() over(order by avg(sr.total_score) desc nulls last) position
    from public.student_reports r join public.enrollments e on e.id=r.enrollment_id
    left join public.subject_results sr on sr.report_id=r.id
    join target t on t.class_id=e.class_id and t.term_id=r.term_id
    where r.deleted_at is null and r.status in ('approved','published')
    group by r.id
  )
  select jsonb_build_object('position',coalesce((select position from ranked where id=target_report_id),0),
    'class_size',(select count(*) from ranked))
$$;

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
      order by p.full_name) from public.profiles p where p.active),'[]'::jsonb)
  );
end $$;

create or replace function public.set_active_period(target_academic_year_id uuid,target_term_id uuid)
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  if not exists(select 1 from public.terms where id=target_term_id and academic_year_id=target_academic_year_id and deleted_at is null)
    then raise exception 'The selected term does not belong to the selected academic year'; end if;
  perform set_config('app.change_reason','Active academic period update',true);
  update public.terms set is_active=false where is_active;
  update public.academic_years set is_active=false where is_active;
  update public.academic_years set is_active=true where id=target_academic_year_id and deleted_at is null;
  update public.terms set is_active=true where id=target_term_id and deleted_at is null;
  return public.get_bootstrap_data();
end $$;

create or replace function public.save_assessment_scheme(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  sid uuid:=public.safe_uuid(payload->>'id'); item jsonb; staged_item jsonb; staged jsonb:='[]'::jsonb;
  yearid uuid:=public.safe_uuid(payload->>'academic_year_id'); termid uuid:=public.safe_uuid(payload->>'term_id');
  classid uuid:=public.safe_uuid(payload->>'class_id'); subjectid uuid:=public.safe_uuid(payload->>'subject_id');
  componentid uuid; existing_component public.assessment_components%rowtype;
  weight_total numeric:=0; maxscore numeric; weightvalue numeric; orderno integer; requiredvalue boolean;
  component_code text; component_name text; seen_codes text[]:='{}'::text[]; seen_ids uuid[]:='{}'::uuid[];
  kept_ids uuid[]:='{}'::uuid[]; affected integer; scheme_in_use boolean:=false;
  old_yearid uuid; old_termid uuid; old_classid uuid; old_subjectid uuid; current_count integer; staged_count integer;
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(payload->>'id',''))<>'' and sid is null then raise exception 'Assessment scheme identifier is invalid'; end if;
  if btrim(coalesce(payload->>'academic_year_id',''))<>'' and yearid is null then raise exception 'Academic year identifier is invalid'; end if;
  if btrim(coalesce(payload->>'term_id',''))<>'' and termid is null then raise exception 'Term identifier is invalid'; end if;
  if btrim(coalesce(payload->>'class_id',''))<>'' and classid is null then raise exception 'Class identifier is invalid'; end if;
  if btrim(coalesce(payload->>'subject_id',''))<>'' and subjectid is null then raise exception 'Subject identifier is invalid'; end if;
  if btrim(coalesce(payload->>'name',''))='' then raise exception 'Assessment scheme name is required'; end if;
  if jsonb_typeof(coalesce(payload->'components','[]'::jsonb))<>'array' or jsonb_array_length(coalesce(payload->'components','[]'::jsonb))=0 then raise exception 'At least one assessment component is required'; end if;
  if yearid is not null and not exists(select 1 from public.academic_years y where y.id=yearid and y.deleted_at is null) then raise exception 'Academic year is invalid'; end if;
  if termid is not null and not exists(select 1 from public.terms t where t.id=termid and t.deleted_at is null and (yearid is null or t.academic_year_id=yearid)) then raise exception 'Term is invalid or does not belong to the selected academic year'; end if;
  if classid is not null and not exists(select 1 from public.classes c where c.id=classid and c.deleted_at is null and c.active) then raise exception 'Class is invalid or inactive'; end if;
  if subjectid is not null and not exists(select 1 from public.subjects sb where sb.id=subjectid and sb.deleted_at is null and sb.active) then raise exception 'Subject is invalid or inactive'; end if;

  if sid is not null then
    select academic_year_id,term_id,class_id,subject_id into old_yearid,old_termid,old_classid,old_subjectid
    from public.assessment_schemes where id=sid and deleted_at is null for update;
    if not found then raise exception 'Assessment scheme not found'; end if;
    scheme_in_use:=exists(select 1 from public.subject_results sr where sr.scheme_id=sid);
    if scheme_in_use and (old_yearid is distinct from yearid or old_termid is distinct from termid or old_classid is distinct from classid or old_subjectid is distinct from subjectid) then
      raise exception 'An assessment scheme already used in reports cannot change its academic scope';
    end if;
  end if;

  for item in select value from jsonb_array_elements(payload->'components') loop
    component_name:=btrim(coalesce(item->>'name','')); component_code:=upper(btrim(coalesce(item->>'code','')));
    maxscore:=public.safe_numeric(item->>'maximum_score'); weightvalue:=public.safe_numeric(item->>'weight');
    orderno:=coalesce(public.safe_integer(item->>'display_order'),0); requiredvalue:=public.safe_boolean(item->>'required',true);
    componentid:=public.safe_uuid(item->>'id');
    if btrim(coalesce(item->>'id',''))<>'' and componentid is null then raise exception 'Assessment component identifier is invalid'; end if;
    if component_name='' or component_code='' then raise exception 'Every assessment component requires a name and code'; end if;
    if maxscore is null or maxscore<=0 then raise exception 'Assessment component maximum score must be greater than zero'; end if;
    if weightvalue is null or weightvalue<=0 or weightvalue>100 then raise exception 'Assessment component weight is invalid'; end if;
    if component_code=any(seen_codes) then raise exception 'Assessment component codes must be unique within a scheme'; end if;

    if componentid is not null then
      if sid is null then raise exception 'A new assessment scheme cannot contain an existing component identifier'; end if;
      select * into existing_component from public.assessment_components c where c.id=componentid and c.scheme_id=sid;
      if not found then raise exception 'Assessment component does not belong to the selected scheme'; end if;
    elsif sid is not null then
      select c.id into componentid from public.assessment_components c where c.scheme_id=sid and lower(c.code::text)=lower(component_code) limit 1;
    end if;
    if componentid is not null and componentid=any(seen_ids) then raise exception 'The same assessment component was entered more than once'; end if;
    if componentid is not null then
      seen_ids:=array_append(seen_ids,componentid); kept_ids:=array_append(kept_ids,componentid);
      select * into existing_component from public.assessment_components c where c.id=componentid;
      if exists(select 1 from public.assessment_score_entries se where se.component_id=componentid and se.raw_score>maxscore) then
        raise exception 'Maximum score cannot be lower than an existing student score for component %',existing_component.name;
      end if;
      if scheme_in_use and (
        lower(existing_component.code::text)<>lower(component_code) or existing_component.maximum_score is distinct from maxscore
        or existing_component.weight is distinct from weightvalue or existing_component.required is distinct from requiredvalue
      ) then raise exception 'A component already used in reports cannot change its code, maximum score, weight, or required status'; end if;
    elsif scheme_in_use then
      raise exception 'New components cannot be added to an assessment scheme already used in reports';
    end if;

    seen_codes:=array_append(seen_codes,component_code); weight_total:=weight_total+weightvalue;
    staged:=staged||jsonb_build_array(item||jsonb_build_object(
      '_resolved_id',case when componentid is null then null else componentid::text end,
      '_name',component_name,'_code',component_code,'_maximum_score',maxscore,'_weight',weightvalue,
      '_display_order',orderno,'_required',requiredvalue
    ));
  end loop;
  if abs(weight_total-100)>0.01 then raise exception 'Assessment component weights must total 100'; end if;

  if sid is not null and scheme_in_use then
    select count(*) into current_count from public.assessment_components where scheme_id=sid;
    staged_count:=jsonb_array_length(staged);
    if current_count<>staged_count or exists(select 1 from public.assessment_components c where c.scheme_id=sid and not(c.id=any(kept_ids))) then
      raise exception 'Components already used in reports cannot be removed';
    end if;
  end if;

  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Assessment scheme update'),true);
  if sid is null then
    insert into public.assessment_schemes(name,academic_year_id,term_id,class_id,subject_id,active,created_by,deleted_at,updated_at)
    values(btrim(payload->>'name'),yearid,termid,classid,subjectid,public.safe_boolean(payload->>'active',true),auth.uid(),null,now()) returning id into sid;
  else
    update public.assessment_schemes set name=btrim(payload->>'name'),academic_year_id=yearid,term_id=termid,class_id=classid,
      subject_id=subjectid,active=public.safe_boolean(payload->>'active',true),deleted_at=null,updated_at=now() where id=sid;
    get diagnostics affected=row_count; if affected<>1 then raise exception 'Assessment scheme not found'; end if;
  end if;

  if exists(
    select 1 from public.assessment_components c where c.scheme_id=sid and not(c.id=any(kept_ids))
      and exists(select 1 from public.assessment_score_entries se where se.component_id=c.id)
  ) then raise exception 'A component with saved student scores cannot be removed'; end if;

  delete from public.assessment_components c where c.scheme_id=sid and not(c.id=any(kept_ids));

  -- Free existing component codes inside the transaction so code renames and swaps remain atomic.
  update public.assessment_components c
  set code=('__NIS_TMP_'||replace(c.id::text,'-',''))::citext,updated_at=now()
  where c.scheme_id=sid and c.id=any(kept_ids);

  -- Apply decreases first so the weight guard never sees an intermediate total above 100.
  for staged_item in select value from jsonb_array_elements(staged) loop
    componentid:=public.safe_uuid(staged_item->>'_resolved_id');
    if componentid is not null then
      weightvalue:=public.safe_numeric(staged_item->>'_weight');
      update public.assessment_components set weight=weightvalue,updated_at=now()
      where id=componentid and weight>weightvalue;
    end if;
  end loop;

  -- Insert new components while the total is below or equal to its final validated value.
  for staged_item in select value from jsonb_array_elements(staged) loop
    componentid:=public.safe_uuid(staged_item->>'_resolved_id');
    if componentid is null then
      insert into public.assessment_components(scheme_id,name,code,maximum_score,weight,display_order,required,updated_at)
      values(sid,staged_item->>'_name',(staged_item->>'_code')::citext,public.safe_numeric(staged_item->>'_maximum_score'),
        public.safe_numeric(staged_item->>'_weight'),coalesce(public.safe_integer(staged_item->>'_display_order'),0),
        public.safe_boolean(staged_item->>'_required',true),now());
    end if;
  end loop;

  -- Finish existing component updates, including increases, after all reductions and removals.
  for staged_item in select value from jsonb_array_elements(staged) loop
    componentid:=public.safe_uuid(staged_item->>'_resolved_id');
    if componentid is not null then
      update public.assessment_components set name=staged_item->>'_name',code=(staged_item->>'_code')::citext,
        maximum_score=public.safe_numeric(staged_item->>'_maximum_score'),weight=public.safe_numeric(staged_item->>'_weight'),
        display_order=coalesce(public.safe_integer(staged_item->>'_display_order'),0),
        required=public.safe_boolean(staged_item->>'_required',true),updated_at=now()
      where id=componentid and scheme_id=sid;
      get diagnostics affected=row_count; if affected<>1 then raise exception 'Assessment component was not updated'; end if;
    end if;
  end loop;

  if abs((select coalesce(sum(c.weight),0) from public.assessment_components c where c.scheme_id=sid)-100)>0.01 then
    raise exception 'Assessment component weights must total 100';
  end if;
  return public.get_academic_configuration();
exception when unique_violation then raise exception 'An assessment scheme or component code already exists in this scope';
end $$;

create or replace function public.validate_grading_scale_overlap()
returns trigger
language plpgsql set search_path=public
as $$
begin
  if exists(
    select 1 from public.grading_scales g
    where g.id<>coalesce(new.id,'00000000-0000-0000-0000-000000000000'::uuid)
      and g.deleted_at is null
      and g.academic_year_id is not distinct from new.academic_year_id
      and g.class_id is not distinct from new.class_id
      and g.subject_id is not distinct from new.subject_id
      and numrange(g.min_mark,g.max_mark,'[]') && numrange(new.min_mark,new.max_mark,'[]')
  ) then raise exception 'Grading ranges cannot overlap within the same scope'; end if;
  return new;
end $$;

drop trigger if exists grading_scale_overlap_guard on public.grading_scales;
create trigger grading_scale_overlap_guard before insert or update on public.grading_scales
for each row execute function public.validate_grading_scale_overlap();

create or replace function public.queue_incomplete_report_notifications(target_term_id uuid)
returns integer
language plpgsql security definer set search_path=public
as $$
declare queued integer:=0; recipient uuid; item record;
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  for item in
    select c.id class_id,c.name class_name,count(e.id) enrolled,
      count(r.id) filter(where r.status in ('submitted','class_reviewed','approved','published')) completed
    from public.classes c
    join public.enrollments e on e.class_id=c.id
    join public.terms t on t.academic_year_id=e.academic_year_id and t.id=target_term_id
    left join public.student_reports r on r.enrollment_id=e.id and r.term_id=t.id and r.deleted_at is null
    where c.active and c.deleted_at is null and e.active and e.deleted_at is null
    group by c.id,c.name
    having count(e.id)>count(r.id) filter(where r.status in ('submitted','class_reviewed','approved','published'))
  loop
    for recipient in
      select distinct user_id from (
        select c.class_teacher_id user_id from public.classes c where c.id=item.class_id and c.class_teacher_id is not null
        union all select cs.teacher_id from public.class_subjects cs where cs.class_id=item.class_id and cs.teacher_id is not null and cs.active
      ) q
    loop
      perform public.create_notification(recipient,'Incomplete report cards',
        item.class_name||' • '||(item.enrolled-item.completed)||' remaining','report_deadline','term',target_term_id,true);
      queued:=queued+1;
    end loop;
  end loop;
  return queued;
end $$;


create or replace function public.safe_uuid(value text)
returns uuid
language plpgsql immutable
as $$
begin return value::uuid; exception when others then return null; end $$;

drop view if exists public.report_card_summary;
create view public.report_card_summary
with (security_invoker=true)
as
select r.id,r.report_number,r.status,r.version,r.updated_at,r.published_at,
  e.student_id,e.class_id,r.term_id,s.admission_no,
  concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name) student_name,
  c.name class_name,t.name term_name,y.name academic_year_name,
  round(coalesce(avg(sr.total_score),0),2) average,
  round(coalesce(sum(sr.grade_point),0),2) aggregate,
  count(sr.id) subject_count
from public.student_reports r
join public.enrollments e on e.id=r.enrollment_id
join public.students s on s.id=e.student_id
join public.classes c on c.id=e.class_id
join public.terms t on t.id=r.term_id
join public.academic_years y on y.id=t.academic_year_id
left join public.subject_results sr on sr.report_id=r.id
where r.deleted_at is null
group by r.id,e.id,s.id,c.id,t.id,y.id;

commit;

-- =============================================================================
-- INTERNAL CHECKPOINT 4 OF 8: 02D_row_level_security_and_storage.sql
-- =============================================================================
begin;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','school_settings','academic_years','terms','classes','subjects','class_subjects',
    'user_class_access','students','student_guardians','guardian_links','enrollments','grading_scales',
    'assessment_schemes','assessment_components','student_reports','subject_scores','subject_results',
    'assessment_score_entries','report_workflow_events','report_revisions','report_publications',
    'notifications','notification_outbox','import_batches','import_errors','audit_log','client_error_events','backup_exports'
  ] loop
    execute format('alter table public.%I enable row level security',t);
  end loop;
end $$;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
using(id=auth.uid() or public.has_role(array['system_admin','headteacher','academic_admin']));

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated
using(id=auth.uid()) with check(id=auth.uid());

drop policy if exists school_settings_select on public.school_settings;
create policy school_settings_select on public.school_settings for select to authenticated using(true);
drop policy if exists school_settings_manage on public.school_settings;
create policy school_settings_manage on public.school_settings for all to authenticated
using(public.is_system_admin()) with check(public.is_system_admin());

do $$
declare t text;
begin
  foreach t in array array[
    'academic_years','terms','classes','subjects','class_subjects','grading_scales',
    'assessment_schemes','assessment_components'
  ] loop
    execute format('drop policy if exists %I_select on public.%I',t,t);
    execute format('create policy %I_select on public.%I for select to authenticated using(true)',t,t);
    execute format('drop policy if exists %I_manage on public.%I',t,t);
    execute format('create policy %I_manage on public.%I for all to authenticated using(public.is_academic_manager()) with check(public.is_academic_manager())',t,t);
  end loop;
end $$;

drop policy if exists user_class_access_select on public.user_class_access;
create policy user_class_access_select on public.user_class_access for select to authenticated
using(user_id=auth.uid() or public.is_system_admin());
drop policy if exists user_class_access_manage on public.user_class_access;
create policy user_class_access_manage on public.user_class_access for all to authenticated
using(public.is_system_admin()) with check(public.is_system_admin());

drop policy if exists students_select on public.students;
create policy students_select on public.students for select to authenticated using(public.can_view_student(id));

drop policy if exists guardians_select on public.student_guardians;
create policy guardians_select on public.student_guardians for select to authenticated
using(exists(select 1 from public.guardian_links gl where gl.guardian_id=id and public.can_view_student(gl.student_id)));

drop policy if exists guardian_links_select on public.guardian_links;
create policy guardian_links_select on public.guardian_links for select to authenticated
using(auth_user_id=auth.uid() or public.can_view_student(student_id) or public.is_records_manager());

drop policy if exists enrollments_select on public.enrollments;
create policy enrollments_select on public.enrollments for select to authenticated
using(public.can_view_student(student_id));

drop policy if exists student_reports_select on public.student_reports;
create policy student_reports_select on public.student_reports for select to authenticated
using(public.can_view_report(id));

drop policy if exists subject_scores_select on public.subject_scores;
create policy subject_scores_select on public.subject_scores for select to authenticated
using(public.can_view_report(report_id));

drop policy if exists subject_results_select on public.subject_results;
create policy subject_results_select on public.subject_results for select to authenticated
using(public.can_view_report(report_id));

drop policy if exists assessment_entries_select on public.assessment_score_entries;
create policy assessment_entries_select on public.assessment_score_entries for select to authenticated
using(exists(select 1 from public.subject_results sr where sr.id=subject_result_id and public.can_view_report(sr.report_id)));

drop policy if exists workflow_select on public.report_workflow_events;
create policy workflow_select on public.report_workflow_events for select to authenticated
using(public.can_view_report(report_id));

drop policy if exists revisions_select on public.report_revisions;
create policy revisions_select on public.report_revisions for select to authenticated
using(public.can_view_report(report_id));

drop policy if exists publications_select on public.report_publications;
create policy publications_select on public.report_publications for select to authenticated
using(public.can_view_report(report_id));

drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications for select to authenticated using(recipient_id=auth.uid());
drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications for update to authenticated
using(recipient_id=auth.uid()) with check(recipient_id=auth.uid());

drop policy if exists outbox_admin on public.notification_outbox;
create policy outbox_admin on public.notification_outbox for select to authenticated using(public.is_system_admin());

drop policy if exists import_batches_select on public.import_batches;
create policy import_batches_select on public.import_batches for select to authenticated
using(created_by=auth.uid() or public.is_records_manager());
drop policy if exists import_errors_select on public.import_errors;
create policy import_errors_select on public.import_errors for select to authenticated
using(exists(select 1 from public.import_batches b where b.id=batch_id and (b.created_by=auth.uid() or public.is_records_manager())));

drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select to authenticated
using(public.has_role(array['system_admin','headteacher','academic_admin']));

drop policy if exists client_errors_admin on public.client_error_events;
create policy client_errors_admin on public.client_error_events for select to authenticated
using(public.has_role(array['system_admin','headteacher']));

drop policy if exists backup_exports_admin on public.backup_exports;
create policy backup_exports_admin on public.backup_exports for select to authenticated
using(public.is_system_admin());

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values
  ('student-photos','student-photos',false,5242880,array['image/jpeg','image/png','image/webp']),
  ('report-pdfs','report-pdfs',false,15728640,array['application/pdf']),
  ('system-backups','system-backups',false,104857600,array['application/json','application/gzip','application/octet-stream'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

-- Remove only policies attached to this system's private buckets, including legacy public-read policies.
do $$
declare p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname='storage' and tablename='objects'
      and (
        policyname like 'student_photos%'
        or policyname like 'report_pdfs%'
        or policyname like 'backups_%'
        or coalesce(qual,'') ~ '(student-photos|report-pdfs|system-backups)'
        or coalesce(with_check,'') ~ '(student-photos|report-pdfs|system-backups)'
      )
  loop
    execute format('drop policy if exists %I on storage.objects',p.policyname);
  end loop;
end $$;

drop policy if exists student_photos_read on storage.objects;
create policy student_photos_read on storage.objects for select to authenticated
using(bucket_id='student-photos' and public.can_view_student(public.safe_uuid((storage.foldername(name))[1])));

drop policy if exists student_photos_insert on storage.objects;
create policy student_photos_insert on storage.objects for insert to authenticated
with check(bucket_id='student-photos' and public.can_manage_student(public.safe_uuid((storage.foldername(name))[1])));

drop policy if exists student_photos_update on storage.objects;
create policy student_photos_update on storage.objects for update to authenticated
using(bucket_id='student-photos' and public.can_manage_student(public.safe_uuid((storage.foldername(name))[1])))
with check(bucket_id='student-photos' and public.can_manage_student(public.safe_uuid((storage.foldername(name))[1])));

drop policy if exists student_photos_delete on storage.objects;
create policy student_photos_delete on storage.objects for delete to authenticated
using(bucket_id='student-photos' and public.can_manage_student(public.safe_uuid((storage.foldername(name))[1])));

drop policy if exists report_pdfs_read on storage.objects;
create policy report_pdfs_read on storage.objects for select to authenticated
using(bucket_id='report-pdfs' and public.can_view_report(public.safe_uuid((storage.foldername(name))[1])));

drop policy if exists report_pdfs_write on storage.objects;
create policy report_pdfs_write on storage.objects for insert to authenticated
with check(bucket_id='report-pdfs' and public.has_role(array['system_admin','headteacher'])
  and public.can_view_report(public.safe_uuid((storage.foldername(name))[1])));

drop policy if exists report_pdfs_update on storage.objects;
create policy report_pdfs_update on storage.objects for update to authenticated
using(bucket_id='report-pdfs' and public.has_role(array['system_admin','headteacher'])
  and public.can_view_report(public.safe_uuid((storage.foldername(name))[1])))
with check(bucket_id='report-pdfs' and public.has_role(array['system_admin','headteacher'])
  and public.can_view_report(public.safe_uuid((storage.foldername(name))[1])));

drop policy if exists backups_admin on storage.objects;
create policy backups_admin on storage.objects for all to authenticated
using(bucket_id='system-backups' and public.is_system_admin())
with check(bucket_id='system-backups' and public.is_system_admin());


commit;

-- =============================================================================
-- INTERNAL CHECKPOINT 5 OF 8: 02E_realtime_permissions_and_grants.sql
-- =============================================================================
begin;

create or replace function public.broadcast_application_change()
returns trigger
language plpgsql security definer set search_path=public,realtime
as $$
declare rowj jsonb; reportid uuid; classid uuid; studentid uuid; recipientid uuid; topics text[]:=array[]::text[]; topic text;
begin
  rowj:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
  if tg_table_name='notifications' then
    recipientid:=public.safe_uuid(rowj->>'recipient_id');
    topics:=array['user:'||recipientid::text];
  elsif tg_table_name='student_reports' then
    reportid:=public.safe_uuid(rowj->>'id'); classid:=public.report_class_id(reportid);
    topics:=array['report:'||reportid::text,'class:'||classid::text,'school:global'];
  elsif tg_table_name in ('subject_results','report_workflow_events','report_revisions','report_publications') then
    reportid:=public.safe_uuid(rowj->>'report_id'); classid:=public.report_class_id(reportid);
    topics:=array['report:'||reportid::text,'class:'||classid::text];
  elsif tg_table_name='assessment_score_entries' then
    select sr.report_id into reportid from public.subject_results sr where sr.id=public.safe_uuid(rowj->>'subject_result_id');
    classid:=public.report_class_id(reportid); topics:=array['report:'||reportid::text,'class:'||classid::text];
  elsif tg_table_name='students' then
    studentid:=public.safe_uuid(rowj->>'id'); topics:=array['student:'||studentid::text,'school:global'];
  elsif tg_table_name='enrollments' then
    studentid:=public.safe_uuid(rowj->>'student_id'); classid:=public.safe_uuid(rowj->>'class_id');
    topics:=array['student:'||studentid::text,'class:'||classid::text,'school:global'];
  elsif tg_table_name='guardian_links' then
    studentid:=public.safe_uuid(rowj->>'student_id'); recipientid:=public.safe_uuid(rowj->>'auth_user_id');
    topics:=array['student:'||studentid::text,'user:'||coalesce(recipientid::text,'')];
  else topics:=array['school:global'];
  end if;
  foreach topic in array topics loop
    if topic is not null and right(topic,1)<>':' then
      begin
        perform realtime.broadcast_changes(topic,tg_op,tg_op,tg_table_name,tg_table_schema,new,old);
      exception when undefined_function or invalid_schema_name then null;
      end;
    end if;
  end loop;
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','school_settings','academic_years','terms','classes','subjects','class_subjects',
    'students','guardian_links','enrollments','grading_scales','assessment_schemes','assessment_components',
    'student_reports','subject_results','assessment_score_entries','report_workflow_events',
    'report_revisions','report_publications','notifications'
  ] loop
    execute format('drop trigger if exists %I_broadcast on public.%I',t,t);
    execute format('create trigger %I_broadcast after insert or update or delete on public.%I for each row execute function public.broadcast_application_change()',t,t);
  end loop;
end $$;

do $$
begin
  if to_regclass('realtime.messages') is not null then
    -- RLS is managed and already enabled by Supabase. ALTER TABLE requires the
    -- internal table owner and fails in hosted projects with SQLSTATE 42501.
    execute 'drop policy if exists nis_realtime_receive on realtime.messages';
    execute $p$create policy nis_realtime_receive on realtime.messages for select to authenticated
      using((select realtime.topic())=any(public.my_realtime_topics()))$p$;
    execute 'drop policy if exists nis_realtime_send on realtime.messages';
    execute $p$create policy nis_realtime_send on realtime.messages for insert to authenticated
      with check((select realtime.topic())=any(public.my_realtime_topics()))$p$;
  end if;
end $$;

do $$
declare t text;
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    foreach t in array array[
      'profiles','school_settings','academic_years','terms','classes','subjects','class_subjects',
      'students','guardian_links','enrollments','grading_scales','assessment_schemes','assessment_components',
      'student_reports','subject_results','assessment_score_entries','report_workflow_events',
      'report_revisions','report_publications','notifications'
    ] loop
      if exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
        execute format('alter publication supabase_realtime drop table public.%I',t);
      end if;
    end loop;
  end if;
end $$;



create or replace function public.record_backup_export(
  target_storage_path text,target_checksum text default '',target_row_counts jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare bid uuid;
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  insert into public.backup_exports(storage_path,checksum,status,row_counts,initiated_by)
  values(target_storage_path,coalesce(target_checksum,''),'completed',coalesce(target_row_counts,'{}'::jsonb),auth.uid())
  returning id into bid;
  return (select to_jsonb(b) from public.backup_exports b where b.id=bid);
end $$;


revoke all on public.students,public.student_guardians,public.guardian_links,public.enrollments,
  public.student_reports,public.subject_scores,public.subject_results,public.assessment_score_entries,
  public.report_workflow_events,public.report_revisions,public.report_publications,
  public.notifications,public.notification_outbox,public.import_batches,public.import_errors,
  public.audit_log,public.client_error_events,public.backup_exports
from anon,authenticated;

grant usage on schema public to anon,authenticated;
grant select on public.profiles,public.school_settings,public.academic_years,public.terms,public.classes,
  public.subjects,public.class_subjects,public.user_class_access,public.students,public.student_guardians,
  public.guardian_links,public.enrollments,public.grading_scales,public.assessment_schemes,
  public.assessment_components,public.student_reports,public.subject_scores,public.subject_results,
  public.assessment_score_entries,public.report_workflow_events,public.report_revisions,
  public.report_publications,public.notifications,public.import_batches,public.import_errors,
  public.audit_log,public.client_error_events,public.backup_exports,public.report_card_summary
to authenticated;

grant update(full_name,phone,last_seen_at) on public.profiles to authenticated;
grant update on public.school_settings to authenticated;
grant insert,update,delete on public.academic_years,public.terms,public.classes,public.subjects,
  public.class_subjects,public.grading_scales,public.assessment_schemes,public.assessment_components
to authenticated;
grant update(read_at) on public.notifications to authenticated;

revoke execute on all functions in schema public from public,anon,authenticated;

grant execute on function public.current_app_role() to authenticated;
grant execute on function public.has_role(text[]) to authenticated;
grant execute on function public.is_records_manager() to authenticated;
grant execute on function public.is_academic_manager() to authenticated;
grant execute on function public.is_system_admin() to authenticated;
grant execute on function public.current_aal() to authenticated;
grant execute on function public.can_access_class(uuid,boolean) to authenticated;
grant execute on function public.can_view_student(uuid) to authenticated;
grant execute on function public.can_manage_student(uuid) to authenticated;
grant execute on function public.report_class_id(uuid) to authenticated;
grant execute on function public.report_student_id(uuid) to authenticated;
grant execute on function public.can_view_report(uuid) to authenticated;
grant execute on function public.can_edit_report(uuid) to authenticated;
grant execute on function public.can_score_subject(uuid,uuid) to authenticated;
grant execute on function public.my_realtime_topics() to authenticated;
grant execute on function public.safe_uuid(text) to authenticated;

grant execute on function public.get_bootstrap_data() to authenticated;
grant execute on function public.get_dashboard_metrics(uuid) to authenticated;
grant execute on function public.search_students(text,uuid,public.student_status,integer,integer) to authenticated;
grant execute on function public.get_student_record(uuid) to authenticated;
grant execute on function public.save_student(jsonb) to authenticated;
grant execute on function public.list_report_cards(uuid,uuid,public.report_status,text,integer,integer) to authenticated;
grant execute on function public.get_report_editor(uuid,uuid,uuid) to authenticated;
grant execute on function public.save_report_card(jsonb,integer) to authenticated;
grant execute on function public.transition_report_status(uuid,public.report_status,text,integer) to authenticated;
grant execute on function public.begin_report_correction(uuid,text) to authenticated;
grant execute on function public.register_report_pdf(uuid,text,text,integer) to authenticated;
grant execute on function public.get_report_revisions(uuid) to authenticated;
grant execute on function public.report_position(uuid) to authenticated;
grant execute on function public.list_profiles_with_access() to authenticated;
grant execute on function public.save_profile_access(jsonb) to authenticated;
grant execute on function public.list_notifications(integer,integer) to authenticated;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;
grant execute on function public.list_audit_events(text,uuid,integer,integer) to authenticated;
grant execute on function public.log_client_error(text,text,jsonb,text) to authenticated;
grant execute on function public.bulk_import_students(jsonb,text) to authenticated;
grant execute on function public.bulk_import_scores(uuid,uuid,jsonb,text) to authenticated;
grant execute on function public.bulk_promote_class(uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.export_backup_snapshot() to authenticated;
grant execute on function public.system_health() to authenticated;
grant execute on function public.record_backup_export(text,text,jsonb) to authenticated;
grant execute on function public.get_academic_configuration() to authenticated;
grant execute on function public.set_active_period(uuid,uuid) to authenticated;
grant execute on function public.save_assessment_scheme(jsonb) to authenticated;
grant execute on function public.queue_incomplete_report_notifications(uuid) to authenticated;

grant execute on function public.verify_report(uuid) to anon,authenticated;

grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant execute on functions to service_role;

commit;

-- =============================================================================
-- INTERNAL CHECKPOINT 6 OF 8: 02F_teacher_management_and_comments.sql
-- =============================================================================
-- =============================================================================
-- ENTERPRISE RELEASE 5.0 ADDITIONS
-- =============================================================================

-- Nipe International School Report Card System
-- Enterprise release 5.0 upgrade for an existing release 4.0 database

begin;

create table if not exists public.teachers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete set null,
  staff_no citext not null,
  first_name text not null,
  middle_name text not null default '',
  last_name text not null,
  gender text not null default 'Other' check (gender in ('Male','Female','Other')),
  phone text not null default '',
  email citext,
  address text not null default '',
  qualification text not null default '',
  specialization text not null default '',
  date_joined date,
  employment_status text not null default 'active'
    check (employment_status in ('active','leave','suspended','resigned','retired')),
  notes text not null default '',
  active boolean not null default true,
  deleted_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.teachers add column if not exists profile_id uuid references public.profiles(id) on delete set null;
alter table public.teachers add column if not exists staff_no citext;
alter table public.teachers add column if not exists first_name text not null default '';
alter table public.teachers add column if not exists middle_name text not null default '';
alter table public.teachers add column if not exists last_name text not null default '';
alter table public.teachers add column if not exists gender text not null default 'Other';
alter table public.teachers add column if not exists phone text not null default '';
alter table public.teachers add column if not exists email citext;
alter table public.teachers add column if not exists address text not null default '';
alter table public.teachers add column if not exists qualification text not null default '';
alter table public.teachers add column if not exists specialization text not null default '';
alter table public.teachers add column if not exists date_joined date;
alter table public.teachers add column if not exists employment_status text not null default 'active';
alter table public.teachers add column if not exists notes text not null default '';
alter table public.teachers add column if not exists active boolean not null default true;
alter table public.teachers add column if not exists deleted_at timestamptz;
alter table public.teachers add column if not exists created_by uuid references public.profiles(id) on delete set null default auth.uid();
alter table public.teachers add column if not exists created_at timestamptz not null default now();
alter table public.teachers add column if not exists updated_at timestamptz not null default now();
alter table public.teachers drop constraint if exists teachers_profile_id_key;
alter table public.teachers drop constraint if exists teachers_staff_no_key;

create unique index if not exists teachers_staff_no_ci_idx
  on public.teachers(lower(staff_no::text)) where deleted_at is null;
create unique index if not exists teachers_profile_active_idx
  on public.teachers(profile_id) where profile_id is not null and deleted_at is null;
create index if not exists teachers_name_search_idx
  on public.teachers(lower(last_name),lower(first_name)) where deleted_at is null;
create index if not exists teachers_status_idx
  on public.teachers(employment_status,active) where deleted_at is null;

create or replace function public.can_manage_teachers()
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.has_role(array['system_admin','headteacher','academic_admin','records_officer'])
$$;

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
          from public.classes c where c.class_teacher_id=t.profile_id and c.deleted_at is null),'[]'::jsonb) class_assignments,
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
        from public.classes c where c.class_teacher_id=t.profile_id and c.deleted_at is null),'[]'::jsonb),
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

create or replace function public.save_teacher(payload jsonb)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare tid uuid:=nullif(payload->>'id','')::uuid;
declare profileid uuid:=nullif(payload->>'profile_id','')::uuid;
declare staff text:=upper(btrim(coalesce(payload->>'staff_no','')));
begin
  if not public.can_manage_teachers() then raise exception 'Access denied' using errcode='42501'; end if;
  if staff='' or btrim(coalesce(payload->>'first_name',''))='' or btrim(coalesce(payload->>'last_name',''))=''
    then raise exception 'Staff number and teacher name are required'; end if;
  if profileid is not null and not exists(select 1 from public.profiles where id=profileid and active)
    then raise exception 'The linked user account is not active'; end if;
  if exists(select 1 from public.teachers t where t.deleted_at is null and lower(t.staff_no::text)=lower(staff)
    and (tid is null or t.id<>tid)) then raise exception 'Staff number already exists'; end if;
  if profileid is not null and exists(select 1 from public.teachers t where t.deleted_at is null and t.profile_id=profileid
    and (tid is null or t.id<>tid)) then raise exception 'This user account is already linked to another teacher'; end if;

  perform set_config('app.change_reason',coalesce(payload->>'reason','Teacher record update'),true);
  if tid is null then
    insert into public.teachers(profile_id,staff_no,first_name,middle_name,last_name,gender,phone,email,address,
      qualification,specialization,date_joined,employment_status,notes,active,created_by)
    values(profileid,staff,payload->>'first_name',coalesce(payload->>'middle_name',''),payload->>'last_name',
      coalesce(nullif(payload->>'gender',''),'Other'),coalesce(payload->>'phone',''),nullif(payload->>'email','')::citext,
      coalesce(payload->>'address',''),coalesce(payload->>'qualification',''),coalesce(payload->>'specialization',''),
      nullif(payload->>'date_joined','')::date,coalesce(nullif(payload->>'employment_status',''),'active'),
      coalesce(payload->>'notes',''),coalesce((payload->>'active')::boolean,true),auth.uid())
    returning id into tid;
  else
    update public.teachers set profile_id=profileid,staff_no=staff,first_name=payload->>'first_name',
      middle_name=coalesce(payload->>'middle_name',''),last_name=payload->>'last_name',
      gender=coalesce(nullif(payload->>'gender',''),'Other'),phone=coalesce(payload->>'phone',''),
      email=nullif(payload->>'email','')::citext,address=coalesce(payload->>'address',''),
      qualification=coalesce(payload->>'qualification',''),specialization=coalesce(payload->>'specialization',''),
      date_joined=nullif(payload->>'date_joined','')::date,
      employment_status=coalesce(nullif(payload->>'employment_status',''),'active'),
      notes=coalesce(payload->>'notes',''),active=coalesce((payload->>'active')::boolean,true),updated_at=now()
    where id=tid and deleted_at is null;
    if not found then raise exception 'Teacher record not found'; end if;
  end if;
  return public.get_teacher_record(tid);
end $$;

create or replace function public.archive_teacher(target_teacher_id uuid,reason_text text default 'Teacher archived')
returns boolean
language plpgsql security definer set search_path=public
as $$
declare profileid uuid;
begin
  if not public.can_manage_teachers() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  select profile_id into profileid from public.teachers where id=target_teacher_id and deleted_at is null for update;
  if not found then raise exception 'Teacher record not found'; end if;
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Teacher archived'),true);
  update public.teachers set active=false,employment_status=case when employment_status='active' then 'resigned' else employment_status end,
    deleted_at=now(),updated_at=now() where id=target_teacher_id;
  if profileid is not null then
    update public.classes set class_teacher_id=null where class_teacher_id=profileid;
    update public.class_subjects set teacher_id=null where teacher_id=profileid;
  end if;
  return true;
end $$;

create or replace function public.restore_teacher(target_teacher_id uuid,reason_text text default 'Teacher restored')
returns boolean
language plpgsql security definer set search_path=public
as $$
begin
  if not public.can_manage_teachers() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  if not exists(select 1 from public.teachers where id=target_teacher_id and deleted_at is not null) then
    raise exception 'Archived teacher record not found';
  end if;
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Teacher restored'),true);
  update public.teachers set active=true,employment_status='active',deleted_at=null,updated_at=now()
  where id=target_teacher_id;
  return true;
end $$;

create or replace function public.search_students_v5(
  search_text text default '',target_class_id uuid default null,target_status public.student_status default null,
  archive_filter text default 'active',page_number integer default 1,page_size integer default 20
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare offset_value integer:=greatest(page_number-1,0)*least(greatest(page_size,1),100);
declare limit_value integer:=least(greatest(page_size,1),100);
begin
  if archive_filter not in ('active','archived','all') then archive_filter:='active'; end if;
  if archive_filter<>'active' and not public.is_records_manager() then
    raise exception 'Access denied' using errcode='42501';
  end if;
  return (
    with matching as (
      select s.id,s.admission_no,s.first_name,s.middle_name,s.last_name,s.gender,s.date_of_birth,
        s.photo_url,s.status,s.updated_at,s.deleted_at,(s.deleted_at is not null) archived,
        e.id enrollment_id,e.class_id,e.academic_year_id,e.roll_number,
        c.name class_name,y.name academic_year_name
      from public.students s
      left join lateral (
        select en.* from public.enrollments en
        join public.academic_years ay on ay.id=en.academic_year_id
        where en.student_id=s.id and en.deleted_at is null
        order by ay.is_active desc,en.active desc,ay.start_date desc nulls last,en.created_at desc limit 1
      ) e on true
      left join public.classes c on c.id=e.class_id
      left join public.academic_years y on y.id=e.academic_year_id
      where public.can_view_student(s.id)
        and (archive_filter='all'
          or (archive_filter='active' and s.deleted_at is null)
          or (archive_filter='archived' and s.deleted_at is not null))
        and (target_class_id is null or e.class_id=target_class_id)
        and (target_status is null or s.status=target_status)
        and (coalesce(search_text,'')='' or s.admission_no::text ilike '%'||search_text||'%'
          or concat_ws(' ',s.first_name,s.middle_name,s.last_name) ilike '%'||search_text||'%')
    )
    select jsonb_build_object(
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by x.last_name,x.first_name) from (
        select * from matching order by last_name,first_name limit limit_value offset offset_value
      ) x),'[]'::jsonb),
      'total',(select count(*) from matching),'page',greatest(page_number,1),'page_size',limit_value
    )
  );
end $$;

create or replace function public.get_student_record_v5(target_student_id uuid)
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.can_view_student(target_student_id) then raise exception 'Access denied' using errcode='42501'; end if;
  return jsonb_build_object(
    'student',(select to_jsonb(s)||(jsonb_build_object('archived',s.deleted_at is not null)) from public.students s where s.id=target_student_id),
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

create or replace function public.archive_student(target_student_id uuid,reason_text text default 'Student archived')
returns boolean
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_records_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  perform 1 from public.students where id=target_student_id and deleted_at is null for update;
  if not found then raise exception 'Student record not found'; end if;
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Student archived'),true);
  update public.students set status='withdrawn',deleted_at=now(),updated_at=now() where id=target_student_id;
  update public.enrollments set active=false,updated_at=now() where student_id=target_student_id and deleted_at is null;
  return true;
end $$;

create or replace function public.restore_student(target_student_id uuid,reason_text text default 'Student restored')
returns boolean
language plpgsql security definer set search_path=public
as $$
declare latest_enrollment uuid;
begin
  if not public.is_records_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  perform 1 from public.students where id=target_student_id and deleted_at is not null for update;
  if not found then raise exception 'Archived student record not found'; end if;
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Student restored'),true);
  update public.students set status='active',deleted_at=null,updated_at=now() where id=target_student_id;
  select e.id into latest_enrollment from public.enrollments e join public.academic_years y on y.id=e.academic_year_id
  where e.student_id=target_student_id and e.deleted_at is null
  order by y.is_active desc,y.start_date desc nulls last,e.created_at desc limit 1;
  if latest_enrollment is not null then
    update public.enrollments set active=(id=latest_enrollment),updated_at=now()
    where student_id=target_student_id and deleted_at is null;
  end if;
  return true;
end $$;

create or replace function public.archive_academic_entity(
  entity_type text,target_id uuid,reason_text text default 'Academic record archived'
)
returns boolean
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Academic record archived'),true);

  if entity_type='class' then
    if exists(
      select 1 from public.enrollments e join public.students s on s.id=e.student_id
      where e.class_id=target_id and e.active and e.deleted_at is null and s.deleted_at is null
    ) then raise exception 'This class has active student enrolments'; end if;
    update public.classes set active=false,deleted_at=now(),updated_at=now()
    where id=target_id and deleted_at is null;
    if not found then raise exception 'Class not found'; end if;
    update public.class_subjects set active=false,updated_at=now() where class_id=target_id;
  elsif entity_type='subject' then
    if exists(
      select 1 from public.subject_results sr join public.student_reports r on r.id=sr.report_id
      where sr.subject_id=target_id and r.deleted_at is null
        and r.status in ('draft','returned','submitted','class_reviewed','approved')
    ) then raise exception 'This subject is used by an unfinished report card'; end if;
    update public.subjects set active=false,deleted_at=now(),updated_at=now()
    where id=target_id and deleted_at is null;
    if not found then raise exception 'Subject not found'; end if;
    update public.class_subjects set active=false,updated_at=now() where subject_id=target_id;
  elsif entity_type='assignment' then
    update public.class_subjects set active=false,updated_at=now() where id=target_id;
    if not found then raise exception 'Subject assignment not found'; end if;
  else
    raise exception 'Unsupported academic record type';
  end if;
  return true;
end $$;

create or replace function public.performance_comment_suggestions(target_report_id uuid)
returns jsonb
language plpgsql stable security definer set search_path=public
as $$
declare avg_mark numeric:=0; result_count integer:=0; strongest text:=''; weakest text:='';
declare student_name text:='The student'; first_name text:='The student'; gender_value text:='Other';
declare opened integer:=0; present integer:=0; attendance numeric:=0; promoted_name text:='';
declare teacher_text text; head_text text; pronoun text:='They'; possessive text:='their'; average_text text;
begin
  if not public.can_view_report(target_report_id) then raise exception 'Access denied' using errcode='42501'; end if;
  select concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name),s.first_name,s.gender,
    r.days_school_opened,r.days_present,coalesce(pc.name,'')
  into student_name,first_name,gender_value,opened,present,promoted_name
  from public.student_reports r join public.enrollments e on e.id=r.enrollment_id
  join public.students s on s.id=e.student_id left join public.classes pc on pc.id=r.promoted_to_class_id
  where r.id=target_report_id;

  select count(*),coalesce(round(avg(sr.total_score),2),0) into result_count,avg_mark
  from public.subject_results sr where sr.report_id=target_report_id;
  select s.name into strongest from public.subject_results sr join public.subjects s on s.id=sr.subject_id
  where sr.report_id=target_report_id order by sr.total_score desc,s.display_order,s.name limit 1;
  select s.name into weakest from public.subject_results sr join public.subjects s on s.id=sr.subject_id
  where sr.report_id=target_report_id order by sr.total_score asc,s.display_order,s.name limit 1;

  if gender_value='Male' then pronoun:='He';possessive:='his';
  elsif gender_value='Female' then pronoun:='She';possessive:='her'; end if;
  average_text:=to_char(avg_mark,'FM990D0');
  attendance:=case when opened>0 then round(present::numeric/opened*100,1) else 0 end;

  if result_count=0 then
    teacher_text:=first_name||'''s assessment record is incomplete and requires all subject results.';
    head_text:='Complete the outstanding assessment records before final approval.';
  elsif avg_mark>=85 then
    teacher_text:=first_name||' has demonstrated outstanding academic performance with an average of '||average_text||'%. '||pronoun||' showed exceptional strength in '||coalesce(strongest,'the assessed subjects')||'. Maintain this excellent standard.';
    head_text:='Excellent performance. Continue to pursue excellence and remain a positive example to others.';
  elsif avg_mark>=75 then
    teacher_text:=first_name||' has achieved a very good academic performance with an average of '||average_text||'%. '||pronoun||' performed especially well in '||coalesce(strongest,'the assessed subjects')||' and should continue working consistently.';
    head_text:='Very good performance. Keep working diligently and aim for an even higher standard next term.';
  elsif avg_mark>=65 then
    teacher_text:=first_name||' has made good academic progress with an average of '||average_text||'%. '||pronoun||' showed strength in '||coalesce(strongest,'several subjects')||' and should give additional attention to '||coalesce(weakest,'weaker areas')||'.';
    head_text:='Good progress. Maintain steady effort and improve the areas that require greater attention.';
  elsif avg_mark>=50 then
    teacher_text:=first_name||' has produced a satisfactory performance with an average of '||average_text||'%. More regular revision, active class participation, and focused practice in '||coalesce(weakest,'the weaker subjects')||' will improve future results.';
    head_text:='Satisfactory performance. Greater consistency and focused study are required for stronger achievement.';
  elsif avg_mark>=40 then
    teacher_text:=first_name||' has shown a fair performance with an average of '||average_text||'%. '||pronoun||' needs sustained support, regular practice, and closer attention to '||coalesce(weakest,'the weaker subjects')||'.';
    head_text:='There is potential for improvement. Work closely with teachers and maintain a disciplined study routine.';
  else
    teacher_text:=first_name||' needs substantial academic improvement. The current average is '||average_text||'%, and immediate support is required, particularly in '||coalesce(weakest,'the weaker subjects')||'.';
    head_text:='Considerable improvement is required. Consistent effort, supervision, and remedial support should begin immediately.';
  end if;

  if opened>0 and attendance<85 then
    teacher_text:=teacher_text||' Attendance also requires improvement ('||present||' of '||opened||' days present).';
  elsif opened>0 and attendance>=95 then
    teacher_text:=teacher_text||' '||pronoun||' maintained excellent attendance.';
  end if;
  if promoted_name<>'' then head_text:=head_text||' Promotion: '||promoted_name||'.'; end if;

  return jsonb_build_object('average',avg_mark,'teacher_comment',teacher_text,'head_comment',head_text,
    'strongest_subject',strongest,'weakest_subject',weakest,'attendance_rate',attendance,'student_name',student_name);
end $$;

create or replace function public.save_report_comments(
  target_report_id uuid,teacher_comment_text text default null,head_comment_text text default null,
  expected_version integer default null
)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare current_version integer; current_status public.report_status; can_teacher boolean; can_head boolean;
begin
  select version,status into current_version,current_status from public.student_reports
  where id=target_report_id and deleted_at is null for update;
  if current_status is null then raise exception 'Report not found'; end if;
  if expected_version is not null and expected_version<>current_version then
    raise exception 'This report was changed by another user. Refresh before saving comments.' using errcode='40001';
  end if;
  if current_status in ('published','withdrawn') then raise exception 'Published report comments are locked'; end if;
  can_teacher:=public.can_edit_report(target_report_id);
  can_head:=public.has_role(array['system_admin','headteacher']);
  if teacher_comment_text is not null and not can_teacher then raise exception 'Access denied' using errcode='42501'; end if;
  if head_comment_text is not null and not can_head then raise exception 'Access denied' using errcode='42501'; end if;
  if teacher_comment_text is null and head_comment_text is null then raise exception 'No comment change supplied'; end if;
  if can_head then perform public.require_sensitive_access(); end if;

  perform set_config('app.report_write','on',true);
  perform set_config('app.change_reason','Report comments updated',true);
  update public.student_reports set
    teacher_comment=case when teacher_comment_text is not null then teacher_comment_text else teacher_comment end,
    head_comment=case when head_comment_text is not null then head_comment_text else head_comment end,
    version=version+1,updated_at=now()
  where id=target_report_id;

  insert into public.report_revisions(report_id,version,snapshot,reason,actor_id)
  values(target_report_id,(select version from public.student_reports where id=target_report_id),
    public.build_report_snapshot(target_report_id),'Report comments updated',auth.uid())
  on conflict(report_id,version) do update set snapshot=excluded.snapshot,reason=excluded.reason,
    actor_id=excluded.actor_id,created_at=now();
  return public.get_report_editor(target_report_id,null,null);
end $$;

create or replace function public.apply_automatic_report_comments()
returns trigger
language plpgsql security definer set search_path=public
as $$
declare suggestions jsonb;
begin
  if new.status<>old.status and new.status in ('submitted','class_reviewed','approved','published') then
    suggestions:=public.performance_comment_suggestions(new.id);
    if btrim(coalesce(new.teacher_comment,''))='' then
      new.teacher_comment:=coalesce(suggestions->>'teacher_comment','');
    end if;
    if new.status in ('approved','published') and btrim(coalesce(new.head_comment,''))='' then
      new.head_comment:=coalesce(suggestions->>'head_comment','');
    end if;
  end if;
  return new;
end $$;

drop trigger if exists student_reports_auto_comments on public.student_reports;
create trigger student_reports_auto_comments
before update of status on public.student_reports
for each row execute function public.apply_automatic_report_comments();

-- Include release 5 permissions in the standard authenticated bootstrap payload.
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
      'manage_teachers',public.can_manage_teachers(),
      'manage_academics',public.is_academic_manager(),
      'manage_students',public.is_records_manager() or public.has_role(array['class_teacher']),
      'remove_students',public.is_records_manager(),
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
      'teacher_id',t.id,'staff_no',t.staff_no,
      'access',coalesce((select jsonb_agg(jsonb_build_object(
        'id',a.id,'class_id',a.class_id,'class_name',c.name,'subject_id',a.subject_id,
        'subject_name',s.name,'access_level',a.access_level
      ) order by c.name,s.name nulls first)
        from public.user_class_access a join public.classes c on c.id=a.class_id
        left join public.subjects s on s.id=a.subject_id where a.user_id=p.id),'[]'::jsonb)
    ) order by p.full_name) from public.profiles p
      left join auth.users au on au.id=p.id
      left join public.teachers t on t.profile_id=p.id and t.deleted_at is null),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(s) order by s.display_order,s.name) from public.subjects s where s.deleted_at is null),'[]'::jsonb)
  );
end $$;


commit;

-- =============================================================================
-- INTERNAL CHECKPOINT 7 OF 8: 02G_teacher_security_and_system_health.sql
-- =============================================================================
begin;

-- Trigger and audit integration.
drop trigger if exists teachers_set_updated_at on public.teachers;
create trigger teachers_set_updated_at before update on public.teachers
for each row execute function public.set_updated_at();

drop trigger if exists teachers_audit on public.teachers;
create trigger teachers_audit after insert or update or delete on public.teachers
for each row execute function public.audit_row_change();

drop trigger if exists teachers_broadcast on public.teachers;
create trigger teachers_broadcast after insert or update or delete on public.teachers
for each row execute function public.broadcast_application_change();

alter table public.teachers enable row level security;
drop policy if exists teachers_select on public.teachers;
create policy teachers_select on public.teachers for select to authenticated
using(public.can_manage_teachers() or profile_id=auth.uid());

revoke all on public.teachers from anon,authenticated;
grant select on public.teachers to authenticated;
revoke delete on public.classes,public.subjects,public.class_subjects from authenticated;

revoke execute on function public.can_manage_teachers() from public,anon;
revoke execute on function public.list_teachers(text,text,text,integer,integer) from public,anon;
revoke execute on function public.get_teacher_record(uuid) from public,anon;
revoke execute on function public.save_teacher(jsonb) from public,anon;
revoke execute on function public.archive_teacher(uuid,text) from public,anon;
revoke execute on function public.restore_teacher(uuid,text) from public,anon;
revoke execute on function public.search_students_v5(text,uuid,public.student_status,text,integer,integer) from public,anon;
revoke execute on function public.get_student_record_v5(uuid) from public,anon;
revoke execute on function public.archive_student(uuid,text) from public,anon;
revoke execute on function public.restore_student(uuid,text) from public,anon;
revoke execute on function public.archive_academic_entity(text,uuid,text) from public,anon;
revoke execute on function public.performance_comment_suggestions(uuid) from public,anon;
revoke execute on function public.save_report_comments(uuid,text,text,integer) from public,anon;

grant execute on function public.can_manage_teachers() to authenticated;
grant execute on function public.list_teachers(text,text,text,integer,integer) to authenticated;
grant execute on function public.get_teacher_record(uuid) to authenticated;
grant execute on function public.save_teacher(jsonb) to authenticated;
grant execute on function public.archive_teacher(uuid,text) to authenticated;
grant execute on function public.restore_teacher(uuid,text) to authenticated;
grant execute on function public.search_students_v5(text,uuid,public.student_status,text,integer,integer) to authenticated;
grant execute on function public.get_student_record_v5(uuid) to authenticated;
grant execute on function public.archive_student(uuid,text) to authenticated;
grant execute on function public.restore_student(uuid,text) to authenticated;
grant execute on function public.archive_academic_entity(text,uuid,text) to authenticated;
grant execute on function public.performance_comment_suggestions(uuid) to authenticated;
grant execute on function public.save_report_comments(uuid,text,text,integer) to authenticated;

grant all on public.teachers to service_role;
grant execute on all functions in schema public to service_role;


create or replace function public.export_backup_snapshot()
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  return jsonb_build_object(
    'generated_at',now(),'schema_version','5.0.0',
    'school_settings',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.school_settings x),
    'profiles',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.profiles x),
    'teachers',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.teachers x),
    'academic_years',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.academic_years x),
    'terms',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.terms x),
    'classes',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.classes x),
    'subjects',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.subjects x),
    'class_subjects',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.class_subjects x),
    'students',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.students x),
    'guardians',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.student_guardians x),
    'guardian_links',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.guardian_links x),
    'enrollments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.enrollments x),
    'grading_scales',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.grading_scales x),
    'assessment_schemes',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.assessment_schemes x),
    'assessment_components',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.assessment_components x),
    'student_reports',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.student_reports x),
    'subject_results',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.subject_results x),
    'score_entries',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.assessment_score_entries x),
    'workflow',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.report_workflow_events x),
    'revisions',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.report_revisions x),
    'publications',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.report_publications x)
  );
end $$;

create or replace function public.system_health()
returns jsonb
language plpgsql security definer set search_path=public
as $$
begin
  if not public.has_role(array['system_admin','headteacher','academic_admin']) then raise exception 'Access denied' using errcode='42501'; end if;
  return jsonb_build_object(
    'database_time',now(),
    'active_users',(select count(*) from public.profiles where active),
    'active_teachers',(select count(*) from public.teachers where active and deleted_at is null),
    'active_students',(select count(*) from public.students where status='active' and deleted_at is null),
    'pending_notifications',(select count(*) from public.notification_outbox where processed_at is null),
    'client_errors_24h',(select count(*) from public.client_error_events where created_at>=now()-interval '24 hours'),
    'latest_backup',(select max(created_at) from public.backup_exports where status='completed'),
    'incomplete_schemes',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'weight',q.total_weight)) from (
      select scheme_id,sum(weight) total_weight from public.assessment_components group by scheme_id having abs(sum(weight)-100)>0.01
    ) q join public.assessment_schemes s on s.id=q.scheme_id),'[]'::jsonb),
    'published_without_pdf',(select count(*) from public.report_publications where revoked_at is null and storage_path='')
  );
end $$;

commit;

-- =============================================================================
-- INTERNAL CHECKPOINT 8 OF 8: 02H_v6_reliability_and_guardian_operations.sql
-- =============================================================================
-- Nipe International School Report Card Enterprise v6
-- Reliability, report removal, and role-aligned operations upgrade.

begin;

create or replace function public.safe_uuid(value text)
returns uuid
language plpgsql
immutable
as $$
begin
  if value is null or btrim(value) = '' then return null; end if;
  return btrim(value)::uuid;
exception when invalid_text_representation then
  return null;
end $$;

-- -----------------------------------------------------------------------------
-- Reliable student record persistence
-- -----------------------------------------------------------------------------
create or replace function public.save_student(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  sid uuid;
  eid uuid;
  gid uuid;
  classid uuid;
  yearid uuid;
  guardian_auth_id uuid;
  student_data jsonb := coalesce(payload->'student','{}'::jsonb);
  enrollment_data jsonb := coalesce(payload->'enrollment','{}'::jsonb);
  guardian_data jsonb := coalesce(payload->'guardian','{}'::jsonb);
  current_updated timestamptz;
  expected_updated timestamptz;
  rollno integer;
  requested_active boolean := coalesce((enrollment_data->>'active')::boolean,true);
  gender_value text := coalesce(nullif(btrim(student_data->>'gender'),''),'Other');
  status_value text := coalesce(nullif(btrim(student_data->>'status'),''),'active');
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;

  sid := public.safe_uuid(student_data->>'id');
  classid := public.safe_uuid(enrollment_data->>'class_id');
  yearid := public.safe_uuid(enrollment_data->>'academic_year_id');
  guardian_auth_id := public.safe_uuid(guardian_data->>'auth_user_id');
  expected_updated := nullif(student_data->>'updated_at','')::timestamptz;
  rollno := nullif(enrollment_data->>'roll_number','')::integer;

  if (enrollment_data->>'class_id') is not null and btrim(coalesce(enrollment_data->>'class_id',''))<>'' and classid is null then
    raise exception 'Selected class is invalid';
  end if;
  if (enrollment_data->>'academic_year_id') is not null and btrim(coalesce(enrollment_data->>'academic_year_id',''))<>'' and yearid is null then
    raise exception 'Selected academic year is invalid';
  end if;
  if (guardian_data->>'auth_user_id') is not null and btrim(coalesce(guardian_data->>'auth_user_id',''))<>'' and guardian_auth_id is null then
    raise exception 'Selected guardian portal account is invalid';
  end if;

  if sid is null then
    if public.is_records_manager() then
      null;
    elsif public.has_role(array['class_teacher']) and classid is not null and public.can_access_class(classid,true) then
      null;
    else
      raise exception 'Access denied' using errcode='42501';
    end if;
  else
    if not public.can_manage_student(sid) then raise exception 'Access denied' using errcode='42501'; end if;
    select updated_at into current_updated from public.students where id=sid and deleted_at is null for update;
    if not found then raise exception 'Student record not found'; end if;
    if expected_updated is not null and current_updated is distinct from expected_updated then
      raise exception 'Student record changed by another user' using errcode='40001';
    end if;
  end if;

  if btrim(coalesce(student_data->>'admission_no',''))='' or
     btrim(coalesce(student_data->>'first_name',''))='' or
     btrim(coalesce(student_data->>'last_name',''))='' then
    raise exception 'Admission number, first name, and last name are required';
  end if;
  if gender_value not in ('Male','Female','Other') then raise exception 'Gender selection is invalid'; end if;
  if status_value not in ('active','graduated','withdrawn','suspended') then raise exception 'Student status is invalid'; end if;
  if nullif(student_data->>'date_of_birth','')::date > current_date then raise exception 'Date of birth cannot be in the future'; end if;
  if rollno is not null and rollno < 1 then raise exception 'Roll number must be greater than zero'; end if;

  if exists(
    select 1 from public.students s
    where lower(s.admission_no::text)=lower(btrim(student_data->>'admission_no'))
      and (sid is null or s.id<>sid)
  ) then raise exception 'Admission number already exists'; end if;

  if (classid is null) <> (yearid is null) then
    raise exception 'Academic year and class must be selected together';
  end if;
  if classid is not null and not exists(
    select 1 from public.classes c where c.id=classid and c.deleted_at is null and c.active
  ) then raise exception 'Selected class is not active'; end if;
  if yearid is not null and not exists(
    select 1 from public.academic_years y where y.id=yearid and y.deleted_at is null
  ) then raise exception 'Selected academic year is unavailable'; end if;
  if sid is null and public.has_role(array['class_teacher']) and not public.is_records_manager()
     and not public.can_access_class(classid,true) then
    raise exception 'You can only register students in an assigned class' using errcode='42501';
  end if;
  if rollno is not null and exists(
    select 1 from public.enrollments e
    where e.academic_year_id=yearid and e.class_id=classid and e.roll_number=rollno
      and e.deleted_at is null and (sid is null or e.student_id<>sid)
  ) then raise exception 'Roll number is already assigned in the selected class'; end if;

  if guardian_auth_id is not null and not exists(
    select 1 from public.profiles p
    where p.id=guardian_auth_id and p.active and public.current_app_role_for(p.role)='parent_guardian'
  ) then raise exception 'Selected portal account is not an active parent or guardian account'; end if;

  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Student record update'),true);

  if sid is null then
    insert into public.students(
      admission_no,first_name,middle_name,last_name,gender,date_of_birth,photo_url,status,updated_at
    ) values(
      btrim(student_data->>'admission_no'),btrim(student_data->>'first_name'),
      btrim(coalesce(student_data->>'middle_name','')),btrim(student_data->>'last_name'),gender_value,
      nullif(student_data->>'date_of_birth','')::date,coalesce(student_data->>'photo_url',''),
      status_value::public.student_status,now()
    ) returning id into sid;
  else
    update public.students set
      admission_no=btrim(student_data->>'admission_no'),first_name=btrim(student_data->>'first_name'),
      middle_name=btrim(coalesce(student_data->>'middle_name','')),last_name=btrim(student_data->>'last_name'),
      gender=gender_value,date_of_birth=nullif(student_data->>'date_of_birth','')::date,
      photo_url=coalesce(student_data->>'photo_url',''),status=status_value::public.student_status,
      updated_at=now()
    where id=sid and deleted_at is null;
  end if;

  if classid is not null and yearid is not null then
    insert into public.enrollments(student_id,academic_year_id,class_id,roll_number,active,deleted_at,updated_at)
    values(sid,yearid,classid,rollno,requested_active,null,now())
    on conflict(student_id,academic_year_id) do update set
      class_id=excluded.class_id,roll_number=excluded.roll_number,active=excluded.active,
      deleted_at=null,updated_at=now()
    returning id into eid;
    if requested_active then
      update public.enrollments set active=(id=eid),updated_at=now()
      where student_id=sid and deleted_at is null;
    end if;
  end if;

  if btrim(coalesce(guardian_data->>'full_name',''))<>'' then
    gid := public.safe_uuid(guardian_data->>'id');
    if gid is null then
      insert into public.student_guardians(full_name,relationship,phone,email,address,is_primary,updated_at)
      values(
        btrim(guardian_data->>'full_name'),coalesce(nullif(btrim(guardian_data->>'relationship'),''),'Guardian'),
        btrim(coalesce(guardian_data->>'phone','')),nullif(btrim(coalesce(guardian_data->>'email','')),'')::citext,
        btrim(coalesce(guardian_data->>'address','')),coalesce((guardian_data->>'is_primary')::boolean,true),now()
      ) returning id into gid;
    else
      if not exists(
        select 1 from public.guardian_links gl where gl.guardian_id=gid and gl.student_id=sid
      ) then raise exception 'Guardian record does not belong to this student'; end if;
      update public.student_guardians set
        full_name=btrim(guardian_data->>'full_name'),
        relationship=coalesce(nullif(btrim(guardian_data->>'relationship'),''),'Guardian'),
        phone=btrim(coalesce(guardian_data->>'phone','')),
        email=nullif(btrim(coalesce(guardian_data->>'email','')),'')::citext,
        address=btrim(coalesce(guardian_data->>'address','')),
        is_primary=coalesce((guardian_data->>'is_primary')::boolean,false),updated_at=now()
      where id=gid;
    end if;

    insert into public.guardian_links(
      guardian_id,student_id,auth_user_id,can_view_reports,can_receive_notifications
    ) values(
      gid,sid,guardian_auth_id,coalesce((guardian_data->>'can_view_reports')::boolean,true),
      coalesce((guardian_data->>'can_receive_notifications')::boolean,true)
    ) on conflict(guardian_id,student_id) do update set
      auth_user_id=excluded.auth_user_id,can_view_reports=excluded.can_view_reports,
      can_receive_notifications=excluded.can_receive_notifications;
  end if;

  return public.get_student_record_v5(sid);
exception
  when unique_violation then
    raise exception 'A student, enrolment, roll number, or guardian link already uses these details';
end $$;

create or replace function public.list_guardian_portal_accounts(search_text text default '')
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
begin
  if not (public.is_records_manager() or public.has_role(array['class_teacher'])) then
    raise exception 'Access denied' using errcode='42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',p.id,'full_name',p.full_name,'email',u.email,'phone',p.phone
    ) order by p.full_name)
    from public.profiles p
    left join auth.users u on u.id=p.id
    where p.active and public.current_app_role_for(p.role)='parent_guardian'
      and (coalesce(search_text,'')='' or p.full_name ilike '%'||search_text||'%'
        or coalesce(u.email,'') ilike '%'||search_text||'%' or p.phone ilike '%'||search_text||'%')
  ),'[]'::jsonb);
end $$;

commit;

-- =============================================================================
-- FINAL INSTALLATION VERIFICATION
-- =============================================================================
do $verify$
declare
  missing_objects text[];
begin
  select array_agg(v.object_name order by v.object_name)
  into missing_objects
  from (values
    ('table public.teachers', to_regclass('public.teachers') is not null),
    ('view public.report_card_summary', to_regclass('public.report_card_summary') is not null),
    ('function public.save_student(jsonb)', to_regprocedure('public.save_student(jsonb)') is not null),
    ('function public.get_bootstrap_data()', to_regprocedure('public.get_bootstrap_data()') is not null),
    ('function public.performance_comment_suggestions(uuid)', to_regprocedure('public.performance_comment_suggestions(uuid)') is not null),
    ('function public.save_report_comments(uuid,text,text,integer)', to_regprocedure('public.save_report_comments(uuid,text,text,integer)') is not null),
    ('function public.list_guardian_portal_accounts(text)', to_regprocedure('public.list_guardian_portal_accounts(text)') is not null),
    ('function public.system_health()', to_regprocedure('public.system_health()') is not null),
    ('function public.report_position(uuid)', to_regprocedure('public.report_position(uuid)') is not null)
  ) as v(object_name, exists_ok)
  where not v.exists_ok;

  if missing_objects is not null then
    raise exception '02 schema operations incomplete. Missing: %', array_to_string(missing_objects, ', ');
  end if;
end
$verify$;

reset client_min_messages;
reset idle_in_transaction_session_timeout;
reset statement_timeout;

select '02 SCHEMA OPERATIONS: PASS' as final_status;
