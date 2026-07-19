-- =============================================================================
-- NIPE INTERNATIONAL SCHOOL REPORT CARD ENTERPRISE
-- DATABASE SCHEMA PART 04
-- Enterprise v6.6.10
--   1. Current Principal signature resolution
--   2. Class-wide dense subject positions with ties
--   3. Configurable report-body font and font size
--   4. Withdrawn report editing and republishing
--   5. Permanent report deletion with history cleanup
--   6. Latest-PDF download enforcement
--   7. Term 3 performance-based automatic promotion
--   8. One-operation promotion across all eligible classes
--   9. Safe cutoff persistence and automatic next-year resolution
-- Run after 03B2_schema_governance_workflow_and_upgrades.sql.
-- Idempotent and safe for fresh installation or upgrade from v6.6.9.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- Report appearance settings
-- -----------------------------------------------------------------------------
alter table public.school_settings
  add column if not exists report_body_font text not null default 'Times New Roman';

alter table public.school_settings
  add column if not exists report_body_font_size numeric(4,1) not null default 11.0;

update public.school_settings
set report_body_font='Times New Roman'
where report_body_font not in ('Times New Roman','Arial','Calibri','Georgia','Verdana','Tahoma');

update public.school_settings
set report_body_font_size=11.0
where report_body_font_size<8.0 or report_body_font_size>16.0;

do $$
begin
  if not exists(
    select 1
    from pg_constraint
    where conrelid='public.school_settings'::regclass
      and conname='school_settings_report_body_font_chk'
  ) then
    alter table public.school_settings
      add constraint school_settings_report_body_font_chk
      check(report_body_font in ('Times New Roman','Arial','Calibri','Georgia','Verdana','Tahoma'));
  end if;

  if not exists(
    select 1
    from pg_constraint
    where conrelid='public.school_settings'::regclass
      and conname='school_settings_report_body_font_size_chk'
  ) then
    alter table public.school_settings
      add constraint school_settings_report_body_font_size_chk
      check(report_body_font_size between 8.0 and 16.0);
  end if;
end $$;

comment on column public.school_settings.report_body_font is
  'Font family embedded into the generated report-card body. Defaults to Times New Roman.';
comment on column public.school_settings.report_body_font_size is
  'Base report-card body font size in points. Valid range: 8 to 16. Defaults to 11.';

-- -----------------------------------------------------------------------------
-- Current Principal name and signature
-- -----------------------------------------------------------------------------
create or replace function public.get_report_headteacher_signature(target_report_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  result jsonb;
begin
  if auth.uid() is null or not public.can_view_report(target_report_id) then
    raise exception 'Access denied' using errcode='42501';
  end if;

  select jsonb_build_object(
    'headteacher_id',h.id,
    'profile_id',h.profile_id,
    'full_name',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),
    'contact',h.phone,
    'signature_path',h.signature_path,
    'signature_updated_at',h.signature_updated_at
  )
  into result
  from public.headteachers h
  where h.deleted_at is null
    and h.active
    and h.employment_status='active'
  order by
    case when btrim(coalesce(h.signature_path,''))<>'' then 0 else 1 end,
    h.updated_at desc,
    h.created_at desc
  limit 1;

  return coalesce(
    result,
    jsonb_build_object(
      'full_name',coalesce((select s.head_name from public.school_settings s order by s.created_at limit 1),'Principal'),
      'signature_path',''
    )
  );
end $$;

comment on function public.get_report_headteacher_signature(uuid) is
  'Returns the currently active Principal name and signature for every newly generated or regenerated official report PDF.';

revoke all on function public.get_report_headteacher_signature(uuid) from public,anon;
grant execute on function public.get_report_headteacher_signature(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Subject positions across students in the same class and term
-- Dense ranking means tied totals share a position and the next distinct score
-- receives the next consecutive position: 70,70,60,50,50 => 1st,1st,2nd,3rd,3rd.
-- Each subject is ranked independently.
-- -----------------------------------------------------------------------------
create or replace function public.report_subject_positions(target_report_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  target_class_id uuid;
  target_term_id uuid;
  result jsonb;
begin
  if auth.uid() is null or not public.can_view_report(target_report_id) then
    raise exception 'Access denied' using errcode='42501';
  end if;

  select e.class_id,r.term_id
  into target_class_id,target_term_id
  from public.student_reports r
  join public.enrollments e on e.id=r.enrollment_id
  where r.id=target_report_id
    and r.deleted_at is null
    and e.deleted_at is null;

  if target_class_id is null or target_term_id is null then
    raise exception 'Report not found';
  end if;

  with ranked as (
    select
      sr.report_id,
      sr.subject_id,
      sr.total_score,
      dense_rank() over(
        partition by sr.subject_id
        order by sr.total_score desc
      ) as subject_position,
      count(*) over(partition by sr.subject_id) as participant_count
    from public.subject_results sr
    join public.student_reports r on r.id=sr.report_id
    join public.enrollments e on e.id=r.enrollment_id
    where r.term_id=target_term_id
      and e.class_id=target_class_id
      and r.deleted_at is null
      and e.deleted_at is null
      and r.status<>'withdrawn'
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'subject_id',ranked.subject_id,
        'total_score',ranked.total_score,
        'position',ranked.subject_position,
        'participants',ranked.participant_count
      )
      order by subjects.display_order,subjects.name
    ),
    '[]'::jsonb
  )
  into result
  from ranked
  join public.subjects subjects on subjects.id=ranked.subject_id
  where ranked.report_id=target_report_id;

  return result;
end $$;

comment on function public.report_subject_positions(uuid) is
  'Returns independent dense subject positions for a report by comparing each total score with the same subject in the same class and term.';

revoke all on function public.report_subject_positions(uuid) from public,anon;
grant execute on function public.report_subject_positions(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- v6.6.6 withdrawn-report editing and republishing
-- -----------------------------------------------------------------------------
create or replace function public.can_score_subject(target_report_id uuid,target_subject_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists(
    select 1
    from public.student_reports r
    where r.id=target_report_id
      and r.deleted_at is null
      and r.status in ('draft','returned','withdrawn')
  )
  and public.current_app_role() in ('class_teacher','subject_teacher')
  and public.can_score_class_subject(public.report_class_id(target_report_id),target_subject_id)
$$;

create or replace function public.can_edit_report(target_report_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists(
    select 1
    from public.student_reports r
    where r.id=target_report_id
      and r.deleted_at is null
      and r.status in ('draft','returned','withdrawn')
  )
  and public.current_app_role() in ('class_teacher','subject_teacher')
  and public.can_create_report_for_class(public.report_class_id(target_report_id))
$$;

create or replace function public.allowed_report_transitions(target_report_id uuid)
returns text[]
language plpgsql stable security definer set search_path=public
as $$
declare
  current_status public.report_status;
  result text[]:='{}'::text[];
begin
  select r.status into current_status
  from public.student_reports r
  where r.id=target_report_id and r.deleted_at is null;

  if current_status is null then return result; end if;
  if current_status in ('draft','returned') and public.can_edit_report(target_report_id) then
    result:=array_append(result,'submitted');
  end if;
  if current_status in ('submitted','class_reviewed') and public.current_app_role()='principal' then
    result:=array_append(result,'approved');
  end if;
  if current_status in ('submitted','class_reviewed','approved','published') and public.current_app_role()='principal' then
    result:=array_append(result,'returned');
  end if;
  if current_status='approved' and public.can_publish_report(target_report_id) then
    result:=array_append(result,'published');
  end if;
  if current_status='published' and public.is_system_admin() then
    result:=array_append(result,'withdrawn');
  end if;
  if current_status='withdrawn' and public.can_publish_report(target_report_id) then
    result:=array_append(result,'published');
  end if;
  return result;
end $$;

create or replace function public.get_report_editor(target_report_id uuid default null,target_enrollment_id uuid default null,target_term_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare rid uuid:=target_report_id; enrollmentid uuid:=target_enrollment_id; termid uuid:=target_term_id; classid uuid; yearid uuid; report_json jsonb; student_json jsonb; canedit boolean; canfields boolean;
begin
  if rid is not null then
    if not public.can_view_report(rid) then raise exception 'Access denied' using errcode='42501'; end if;
    select r.enrollment_id,r.term_id,e.class_id,e.academic_year_id,to_jsonb(r) into enrollmentid,termid,classid,yearid,report_json
    from public.student_reports r join public.enrollments e on e.id=r.enrollment_id where r.id=rid and r.deleted_at is null;
    if report_json is null then raise exception 'Report not found'; end if;
  else
    select e.class_id,e.academic_year_id into classid,yearid from public.enrollments e where e.id=enrollmentid and e.deleted_at is null;
    if classid is null or not public.can_create_report_for_class(classid) then raise exception 'Access denied' using errcode='42501'; end if;
    if not exists(select 1 from public.terms t where t.id=termid and t.academic_year_id=yearid and t.deleted_at is null) then raise exception 'Term and enrolment academic year do not match'; end if;
    select to_jsonb(r) into report_json from public.student_reports r where r.enrollment_id=enrollmentid and r.term_id=termid and r.deleted_at is null;
    if report_json is not null then rid:=(report_json->>'id')::uuid;
    else report_json:=jsonb_build_object('id',null,'enrollment_id',enrollmentid,'term_id',termid,'status','draft','version',0,'days_school_opened',0,'days_present',0,'attitude','','conduct','','interest','','teacher_comment','','head_comment','','promoted_to_class_id',null); end if;
  end if;
  select jsonb_build_object('id',s.id,'admission_no',s.admission_no,'first_name',s.first_name,'middle_name',s.middle_name,'last_name',s.last_name,
    'full_name',concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name),'gender',s.gender,'date_of_birth',s.date_of_birth,'photo_url',s.photo_url,
    'class_id',e.class_id,'class_name',c.name,'academic_year_id',e.academic_year_id,'academic_year_name',y.name,'roll_number',e.roll_number,
    'term_name',t.name,'term_sequence',t.sequence,'next_term_begins',t.next_term_begins) into student_json
  from public.enrollments e join public.students s on s.id=e.student_id join public.classes c on c.id=e.class_id join public.academic_years y on y.id=e.academic_year_id join public.terms t on t.id=termid where e.id=enrollmentid;
  canedit:=case when rid is null then public.can_create_report_for_class(classid) else public.can_edit_report(rid) end;
  canfields:=public.can_manage_class_report_fields(classid) and coalesce(report_json->>'status','draft') in ('draft','returned','withdrawn');
  return jsonb_build_object('report',report_json,'student',student_json,'can_edit',canedit,'can_edit_fields',canfields,
    'allowed_transitions',case when rid is null then '[]'::jsonb else to_jsonb(public.allowed_report_transitions(rid)) end,
    'subjects',coalesce((select jsonb_agg(to_jsonb(q) order by q.display_order,q.subject_name) from (
      select sb.id subject_id,sb.code subject_code,sb.name subject_name,sb.display_order,public.can_score_class_subject(classid,sb.id) and coalesce(report_json->>'status','draft') in ('draft','returned','withdrawn') can_score,
        coalesce(sr.scheme_id,public.resolve_assessment_scheme(classid,sb.id,yearid,termid)) scheme_id,sc.name scheme_name,sr.id result_id,
        coalesce(sr.total_score,0) total_score,coalesce(sr.grade,'') grade,coalesce(sr.remark,'') remark,coalesce(sr.grade_point,0) grade_point,coalesce(sr.teacher_initials,'') teacher_initials,
        coalesce((select jsonb_agg(jsonb_build_object('component_id',ac.id,'name',ac.name,'code',ac.code,'maximum_score',ac.maximum_score,'weight',ac.weight,'required',ac.required,'display_order',ac.display_order,
          'raw_score',coalesce(se.raw_score,0),'weighted_score',coalesce(se.weighted_score,0)) order by ac.display_order,ac.name)
          from public.assessment_components ac left join public.assessment_score_entries se on se.component_id=ac.id and se.subject_result_id=sr.id
          where ac.scheme_id=coalesce(sr.scheme_id,public.resolve_assessment_scheme(classid,sb.id,yearid,termid))),'[]'::jsonb) components
      from public.class_subjects cs join public.subjects sb on sb.id=cs.subject_id left join public.subject_results sr on sr.report_id=rid and sr.subject_id=sb.id
      left join public.assessment_schemes sc on sc.id=coalesce(sr.scheme_id,public.resolve_assessment_scheme(classid,sb.id,yearid,termid))
      where cs.class_id=classid and cs.active and sb.active and sb.deleted_at is null
    ) q),'[]'::jsonb),
    'workflow',case when rid is null then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from (select w.*,p.full_name actor_name from public.report_workflow_events w left join public.profiles p on p.id=w.actor_id where w.report_id=rid) q),'[]'::jsonb) end,
    'publications',case when rid is null then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(p) order by p.published_at desc) from public.report_publications p where p.report_id=rid),'[]'::jsonb) end);
end $$;

create or replace function public.save_report_card(payload jsonb,expected_version integer default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  rid uuid:=public.safe_uuid(payload->>'report_id'); enrollmentid uuid:=public.safe_uuid(payload->>'enrollment_id'); termid uuid:=public.safe_uuid(payload->>'term_id');
  current_version integer; current_status public.report_status; classid uuid; yearid uuid; subject_item jsonb; component_item jsonb;
  resultid uuid; schemeid uuid; subjectid uuid; componentid uuid; promotedid uuid; report_fields jsonb:=coalesce(payload->'fields','{}'::jsonb);
  report_created boolean:=false; field_changed boolean:=false; subject_changed boolean:=false; opened integer; present integer;
  scorevalue numeric; maxscore numeric; seen_subjects uuid[]:='{}'::uuid[];
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if jsonb_typeof(coalesce(payload->'subjects','[]'::jsonb))<>'array' then raise exception 'Report subjects must be a list'; end if;
  if btrim(coalesce(payload->>'report_id',''))<>'' and rid is null then raise exception 'Report identifier is invalid'; end if;
  if enrollmentid is null or termid is null then raise exception 'Student enrolment and term are required'; end if;
  select e.class_id,e.academic_year_id into classid,yearid from public.enrollments e where e.id=enrollmentid and e.deleted_at is null;
  if classid is null or not public.can_create_report_for_class(classid) then raise exception 'Access denied' using errcode='42501'; end if;
  if not exists(select 1 from public.terms t where t.id=termid and t.academic_year_id=yearid and t.deleted_at is null) then raise exception 'Term and enrolment academic year do not match'; end if;
  perform set_config('app.report_write','on',true); perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Report card save'),true);
  perform pg_advisory_xact_lock(hashtext(enrollmentid::text),hashtext(termid::text));

  if rid is null then select id,version,status into rid,current_version,current_status from public.student_reports where enrollment_id=enrollmentid and term_id=termid and deleted_at is null for update;
  else select version,status into current_version,current_status from public.student_reports where id=rid and enrollment_id=enrollmentid and term_id=termid and deleted_at is null for update; end if;
  if rid is null then
    insert into public.student_reports(enrollment_id,term_id,status,version,created_by) values(enrollmentid,termid,'draft',1,auth.uid()) returning id,version,status into rid,current_version,current_status;
    report_created:=true;
  else
    if expected_version is not null and expected_version<>current_version then raise exception 'This report was changed by another user. Refresh before saving.' using errcode='40001'; end if;
    if current_status not in ('draft','returned','withdrawn') then raise exception 'This report is locked by the approval workflow'; end if;
  end if;

  if report_fields<>'{}'::jsonb then
    if not public.can_manage_class_report_fields(classid) then raise exception 'You are not authorised to edit class report details' using errcode='42501'; end if;
    opened:=public.safe_integer(report_fields->>'days_school_opened'); present:=public.safe_integer(report_fields->>'days_present');
    if btrim(coalesce(report_fields->>'days_school_opened',''))<>'' and opened is null then raise exception 'Days school opened is invalid'; end if;
    if btrim(coalesce(report_fields->>'days_present',''))<>'' and present is null then raise exception 'Days present is invalid'; end if;
    opened:=coalesce(opened,0); present:=coalesce(present,0);
    if opened<0 or present<0 or present>opened then raise exception 'Attendance values are invalid'; end if;
    promotedid:=public.safe_uuid(report_fields->>'promoted_to_class_id');
    if btrim(coalesce(report_fields->>'promoted_to_class_id',''))<>'' and promotedid is null then raise exception 'Promotion class is invalid'; end if;
    if promotedid is not null and not exists(select 1 from public.classes c where c.id=promotedid and c.active and c.deleted_at is null) then raise exception 'Promotion class is unavailable'; end if;
    update public.student_reports set days_school_opened=opened,days_present=present,attitude=coalesce(report_fields->>'attitude',''),conduct=coalesce(report_fields->>'conduct',''),
      interest=coalesce(report_fields->>'interest',''),teacher_comment=coalesce(report_fields->>'teacher_comment',''),
      head_comment=case when public.has_role(array['system_admin','principal']) then coalesce(report_fields->>'head_comment',head_comment) else head_comment end,
      promoted_to_class_id=promotedid,updated_at=now() where id=rid;
    field_changed:=true;
  end if;

  for subject_item in select value from jsonb_array_elements(coalesce(payload->'subjects','[]'::jsonb)) loop
    subjectid:=public.safe_uuid(subject_item->>'subject_id');
    if subjectid is null then raise exception 'A report subject identifier is invalid'; end if;
    if subjectid=any(seen_subjects) then raise exception 'A report subject was supplied more than once'; end if;
    seen_subjects:=array_append(seen_subjects,subjectid);
    if not exists(select 1 from public.class_subjects cs where cs.class_id=classid and cs.subject_id=subjectid and cs.active) then raise exception 'A report subject is not assigned to this class'; end if;
    if not public.can_score_class_subject(classid,subjectid) then raise exception 'You are not authorised to score one or more subjects' using errcode='42501'; end if;
    schemeid:=public.safe_uuid(subject_item->>'scheme_id');
    if btrim(coalesce(subject_item->>'scheme_id',''))<>'' and schemeid is null then raise exception 'Assessment scheme identifier is invalid'; end if;
    if schemeid is null then schemeid:=public.resolve_assessment_scheme(classid,subjectid,yearid,termid); end if;
    if schemeid is null then raise exception 'No assessment scheme is configured for a subject'; end if;
    if not exists(select 1 from public.assessment_schemes sc where sc.id=schemeid and sc.active
      and (sc.academic_year_id is null or sc.academic_year_id=yearid) and (sc.term_id is null or sc.term_id=termid)
      and (sc.class_id is null or sc.class_id=classid) and (sc.subject_id is null or sc.subject_id=subjectid)) then raise exception 'Assessment scheme does not match the report subject'; end if;
    if abs((select coalesce(sum(weight),0) from public.assessment_components where scheme_id=schemeid)-100)>0.01 then raise exception 'Assessment scheme weights must total 100'; end if;
    if jsonb_typeof(coalesce(subject_item->'components','[]'::jsonb))<>'array' then raise exception 'Assessment components must be a list'; end if;
    insert into public.subject_results(report_id,subject_id,scheme_id,teacher_initials,created_by)
    values(rid,subjectid,schemeid,btrim(coalesce(subject_item->>'teacher_initials','')),auth.uid())
    on conflict(report_id,subject_id) do update set scheme_id=excluded.scheme_id,teacher_initials=excluded.teacher_initials,updated_at=now() returning id into resultid;
    delete from public.assessment_score_entries e where e.subject_result_id=resultid and not exists(
      select 1 from jsonb_array_elements(coalesce(subject_item->'components','[]'::jsonb)) x where public.safe_uuid(x->>'component_id')=e.component_id);
    for component_item in select value from jsonb_array_elements(coalesce(subject_item->'components','[]'::jsonb)) loop
      componentid:=public.safe_uuid(component_item->>'component_id'); scorevalue:=public.safe_numeric(component_item->>'raw_score');
      if componentid is null then raise exception 'An assessment component identifier is invalid'; end if;
      select ac.maximum_score into maxscore from public.assessment_components ac where ac.id=componentid and ac.scheme_id=schemeid;
      if maxscore is null then raise exception 'An assessment component is invalid'; end if;
      if btrim(coalesce(component_item->>'raw_score',''))<>'' and scorevalue is null then raise exception 'An assessment score is invalid'; end if;
      scorevalue:=coalesce(scorevalue,0);
      if scorevalue<0 or scorevalue>maxscore then raise exception 'An assessment score is outside its allowed range'; end if;
      insert into public.assessment_score_entries(subject_result_id,component_id,raw_score,created_by)
      values(resultid,componentid,scorevalue,auth.uid())
      on conflict(subject_result_id,component_id) do update set raw_score=excluded.raw_score,updated_at=now();
    end loop;
    perform public.refresh_subject_result(resultid); subject_changed:=true;
  end loop;
  if not field_changed and not subject_changed then raise exception 'No authorised report changes were supplied'; end if;
  if not report_created then update public.student_reports set version=version+1,updated_at=now() where id=rid returning version into current_version;
  else select version into current_version from public.student_reports where id=rid; end if;
  update public.student_reports set report_number=coalesce(report_number,public.generate_report_number(rid)),updated_at=now() where id=rid;
  insert into public.report_revisions(report_id,version,snapshot,reason,actor_id) values(rid,current_version,public.build_report_snapshot(rid),coalesce(nullif(payload->>'reason',''),'Saved'),auth.uid())
    on conflict(report_id,version) do update set snapshot=excluded.snapshot,reason=excluded.reason,actor_id=excluded.actor_id,created_at=now();
  return public.get_report_editor(rid,null,null);
end $$;


-- -----------------------------------------------------------------------------
-- Permanent report deletion and audit suppression
-- -----------------------------------------------------------------------------
create or replace function public.audit_row_change()
returns trigger
language plpgsql security definer set search_path=public
as $$
declare rid uuid; oldj jsonb; newj jsonb;
begin
  if current_setting('app.audit_suppress',true)='on' then return null; end if;
  oldj:=case when tg_op='INSERT' then null else to_jsonb(old) end;
  newj:=case when tg_op='DELETE' then null else to_jsonb(new) end;
  begin rid:=coalesce((newj->>'id')::uuid,(oldj->>'id')::uuid); exception when others then rid:=null; end;
  insert into public.audit_log(actor_id,table_name,record_id,action,old_data,new_data,reason)
  values(auth.uid(),tg_table_name,rid,tg_op,oldj,newj,coalesce(current_setting('app.change_reason',true),''));
  return null;
end $$;

create or replace function public.can_delete_report(target_report_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists(
    select 1 from public.student_reports r
    where r.id=target_report_id and r.deleted_at is null
  ) and (
    public.is_system_admin()
    or (
      public.current_app_role() in ('class_teacher','subject_teacher')
      and public.can_create_report_for_class(public.report_class_id(target_report_id))
    )
  )
$$;

create or replace function public.list_report_pdf_paths(target_report_id uuid)
returns text[]
language plpgsql stable security definer set search_path=public
as $$
begin
  if not public.can_delete_report(target_report_id) then
    raise exception 'Access denied' using errcode='42501';
  end if;
  return coalesce(
    (select array_agg(distinct p.storage_path order by p.storage_path)
     from public.report_publications p
     where p.report_id=target_report_id and btrim(coalesce(p.storage_path,''))<>''),
    '{}'::text[]
  );
end $$;

create or replace function public.delete_report_card_permanently(
  target_report_id uuid,
  reason_text text default 'Report card permanently deleted'
)
returns boolean
language plpgsql security definer set search_path=public
as $$
declare
  related_ids uuid[]:=array[target_report_id];
  extra_ids uuid[];
begin
  if not public.can_delete_report(target_report_id) then
    raise exception 'Access denied' using errcode='42501';
  end if;

  perform 1 from public.student_reports
  where id=target_report_id and deleted_at is null
  for update;
  if not found then raise exception 'Report card not found'; end if;

  select coalesce(array_agg(x.id),'{}'::uuid[])
  into extra_ids
  from (
    select ss.id from public.subject_scores ss where ss.report_id=target_report_id
    union all
    select sr.id from public.subject_results sr where sr.report_id=target_report_id
    union all
    select ase.id
    from public.assessment_score_entries ase
    join public.subject_results sr on sr.id=ase.subject_result_id
    where sr.report_id=target_report_id
    union all
    select we.id from public.report_workflow_events we where we.report_id=target_report_id
    union all
    select rr.id from public.report_revisions rr where rr.report_id=target_report_id
    union all
    select rp.id from public.report_publications rp where rp.report_id=target_report_id
  ) x;
  related_ids:=array_cat(related_ids,extra_ids);

  perform set_config('app.report_write','on',true);
  perform set_config('app.audit_suppress','on',true);
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Report card permanently deleted'),true);

  delete from public.notifications
  where entity_type='report' and entity_id=target_report_id;

  delete from public.notification_outbox
  where coalesce(payload::text,'') like '%'||target_report_id::text||'%';

  delete from public.student_reports where id=target_report_id;
  if not found then raise exception 'Report card not found'; end if;

  delete from public.audit_log a
  where a.record_id=any(related_ids)
     or coalesce(a.old_data::text,'') like '%'||target_report_id::text||'%'
     or coalesce(a.new_data::text,'') like '%'||target_report_id::text||'%';

  return true;
end $$;

-- Keep the former RPC name safe for any older browser cache. It now performs
-- the same permanent deletion and no longer creates a restorable archive.
create or replace function public.archive_report_card(
  target_report_id uuid,
  reason_text text default 'Report card permanently deleted'
)
returns boolean
language plpgsql security definer set search_path=public
as $$
begin
  return public.delete_report_card_permanently(target_report_id,reason_text);
end $$;

-- Assigned teachers and the System Administrator may remove stored PDF objects
-- before the report row is permanently deleted.
drop policy if exists report_pdfs_delete on storage.objects;
create policy report_pdfs_delete on storage.objects for delete to authenticated
using(
  bucket_id='report-pdfs'
  and public.can_delete_report(public.safe_uuid((storage.foldername(name))[1]))
);

revoke all on function public.can_score_subject(uuid,uuid) from public,anon;
revoke all on function public.can_edit_report(uuid) from public,anon;
revoke all on function public.allowed_report_transitions(uuid) from public,anon;
revoke all on function public.can_delete_report(uuid) from public,anon;
revoke all on function public.list_report_pdf_paths(uuid) from public,anon;
revoke all on function public.delete_report_card_permanently(uuid,text) from public,anon;
revoke all on function public.archive_report_card(uuid,text) from public,anon;

grant execute on function public.can_score_subject(uuid,uuid) to authenticated;
grant execute on function public.can_edit_report(uuid) to authenticated;
grant execute on function public.allowed_report_transitions(uuid) to authenticated;
grant execute on function public.can_delete_report(uuid) to authenticated;
grant execute on function public.list_report_pdf_paths(uuid) to authenticated;
grant execute on function public.delete_report_card_permanently(uuid,text) to authenticated;
grant execute on function public.archive_report_card(uuid,text) to authenticated;

comment on function public.delete_report_card_permanently(uuid,text) is
  'Permanently removes an authorised report and all cascading score, workflow, revision, publication, notification, and related audit records.';
comment on function public.list_report_pdf_paths(uuid) is
  'Returns stored PDF paths so the authorised client can remove Storage objects before permanent report deletion.';

-- -----------------------------------------------------------------------------
-- Enterprise v6.6.7: Term 3 performance-based automatic promotion
-- -----------------------------------------------------------------------------
alter table public.school_settings
  add column if not exists promotion_cutoff_score smallint not null default 50;

update public.school_settings
set promotion_cutoff_score=50
where promotion_cutoff_score<40 or promotion_cutoff_score>60;

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conrelid='public.school_settings'::regclass
      and conname='school_settings_promotion_cutoff_score_chk'
  ) then
    alter table public.school_settings
      add constraint school_settings_promotion_cutoff_score_chk
      check(promotion_cutoff_score between 40 and 60);
  end if;
end $$;

comment on column public.school_settings.promotion_cutoff_score is
  'Term 3 overall-average pass mark for automatic promotion. System Administrator selectable from 40 through 60.';


-- -----------------------------------------------------------------------------
-- Enterprise v6.6.9: safe promotion settings and automatic target-year mapping
-- -----------------------------------------------------------------------------
create or replace function public.next_promotion_academic_year(source_year_id uuid)
returns uuid
language sql
stable
security definer
set search_path=public
as $$
  with ordered_years as (
    select
      y.id,
      row_number() over(
        order by
          coalesce(
            y.start_date,
            case
              when y.name::text ~ '^[0-9]{4}'
                then make_date(substring(y.name::text from 1 for 4)::integer,1,1)
              else y.created_at::date
            end
          ),
          y.created_at,
          y.id
      ) as rn
    from public.academic_years y
    where y.deleted_at is null
  ), source_year as (
    select oy.rn from ordered_years oy where oy.id=source_year_id
  )
  select next_year.id
  from ordered_years next_year
  join source_year source on next_year.rn=source.rn+1
  limit 1
$$;

create or replace function public.report_promotion_evaluation(target_report_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  report_term_sequence integer;
  source_class_id uuid;
  source_class_name text;
  source_class_level integer;
  source_year_id uuid;
  source_year_name text;
  next_class_id uuid;
  next_class_name text;
  target_year_id uuid;
  target_year_name text;
  assigned_subjects integer:=0;
  completed_subjects integer:=0;
  average_score numeric(7,2):=0;
  cutoff_score integer:=50;
  is_complete boolean:=false;
  is_term_three boolean:=false;
  has_passed boolean:=false;
begin
  if auth.uid() is not null and not public.can_view_report(target_report_id) then
    raise exception 'Access denied' using errcode='42501';
  end if;

  select
    t.sequence,
    e.class_id,
    c.name::text,
    c.level_order,
    e.academic_year_id,
    y.name::text
  into
    report_term_sequence,
    source_class_id,
    source_class_name,
    source_class_level,
    source_year_id,
    source_year_name
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
  order by s.created_at
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

  is_term_three:=report_term_sequence=3;
  is_complete:=assigned_subjects>0 and completed_subjects=assigned_subjects;
  has_passed:=is_term_three and is_complete and average_score>=cutoff_score;

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
  end if;

  return jsonb_build_object(
    'report_id',target_report_id,
    'term_sequence',report_term_sequence,
    'term3',is_term_three,
    'complete',is_complete,
    'assigned_subjects',assigned_subjects,
    'completed_subjects',completed_subjects,
    'average',average_score,
    'cutoff',cutoff_score,
    'passed',has_passed,
    'source_class_id',source_class_id,
    'source_class_name',source_class_name,
    'source_academic_year_id',source_year_id,
    'source_academic_year_name',source_year_name,
    'next_class_id',next_class_id,
    'next_class_name',next_class_name,
    'target_academic_year_id',target_year_id,
    'target_academic_year_name',target_year_name,
    'can_create_enrollment',has_passed and next_class_id is not null and target_year_id is not null
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
  should_promote boolean;
  next_class_id uuid;
  target_year_id uuid;
  student_id uuid;
  enrollment_created boolean:=false;
begin
  evaluation:=public.report_promotion_evaluation(target_report_id);
  should_promote:=coalesce((evaluation->>'passed')::boolean,false)
    and nullif(evaluation->>'next_class_id','') is not null;
  next_class_id:=public.safe_uuid(evaluation->>'next_class_id');
  target_year_id:=public.safe_uuid(evaluation->>'target_academic_year_id');

  perform set_config('app.report_write','on',true);
  update public.student_reports
  set promoted_to_class_id=case when should_promote then next_class_id else null end,
      updated_at=now()
  where id=target_report_id and deleted_at is null;

  if create_target_enrollment and should_promote and target_year_id is not null then
    select e.student_id into student_id
    from public.student_reports r
    join public.enrollments e on e.id=r.enrollment_id
    where r.id=target_report_id and r.deleted_at is null and e.deleted_at is null;

    insert into public.enrollments(student_id,academic_year_id,class_id,active,deleted_at,updated_at)
    values(student_id,target_year_id,next_class_id,true,null,now())
    on conflict(student_id,academic_year_id) do update
      set class_id=excluded.class_id,
          active=true,
          deleted_at=null,
          updated_at=now();
    enrollment_created:=true;
  end if;

  return evaluation||jsonb_build_object(
    'promoted_to_class_id',case when should_promote then next_class_id else null end,
    'enrollment_created_or_updated',enrollment_created
  );
end $$;

create or replace function public.sync_report_promotion_from_subject_result()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare target_id uuid;
begin
  if tg_op='DELETE' then target_id:=old.report_id; else target_id:=new.report_id; end if;
  if exists(select 1 from public.student_reports r where r.id=target_id and r.deleted_at is null) then
    perform public.refresh_report_promotion(target_id,false);
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

drop trigger if exists subject_result_auto_promotion_sync on public.subject_results;
create trigger subject_result_auto_promotion_sync
after insert or update of total_score or delete on public.subject_results
for each row execute function public.sync_report_promotion_from_subject_result();

create or replace function public.apply_promotion_when_report_published()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if tg_op='INSERT' then
    if new.status='published' then perform public.refresh_report_promotion(new.id,true); end if;
  elsif new.status='published' and old.status is distinct from new.status then
    perform public.refresh_report_promotion(new.id,true);
  end if;
  return new;
end $$;

drop trigger if exists student_report_publish_auto_promotion on public.student_reports;
create trigger student_report_publish_auto_promotion
after insert or update of status on public.student_reports
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
    where r.deleted_at is null and r.status='published' and t.sequence=3 and t.deleted_at is null
  loop
    perform public.refresh_report_promotion(item.id,true);
    processed:=processed+1;
  end loop;
  return processed;
end $$;

create or replace function public.sync_pending_promotions_when_year_changes()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  perform public.apply_pending_term3_promotions();
  return null;
end $$;

drop trigger if exists academic_year_pending_promotion_sync on public.academic_years;
create trigger academic_year_pending_promotion_sync
after insert or update of start_date,end_date,deleted_at on public.academic_years
for each statement execute function public.sync_pending_promotions_when_year_changes();

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
    select r.id,r.status
    from public.student_reports r
    join public.terms t on t.id=r.term_id
    where r.deleted_at is null and t.sequence=3 and t.deleted_at is null
  loop
    perform public.refresh_report_promotion(item.id,item.status='published');
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
  not_promoted integer:=0;
  incomplete integer:=0;
  cutoff integer:=50;
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
  from public.school_settings s order by s.created_at limit 1;

  perform set_config('app.change_reason','Term 3 performance-based class promotion',true);
  for item in
    select r.id,e.student_id
    from public.student_reports r
    join public.enrollments e on e.id=r.enrollment_id and e.deleted_at is null
    join public.terms t on t.id=r.term_id and t.deleted_at is null
    join public.students s on s.id=e.student_id and s.deleted_at is null and s.status='active'
    where e.academic_year_id=source_academic_year_id
      and e.class_id=source_class_id
      and r.deleted_at is null
      and r.status in ('approved','published')
      and t.sequence=3
  loop
    evaluation:=public.refresh_report_promotion(item.id,false);
    if not coalesce((evaluation->>'complete')::boolean,false) then
      incomplete:=incomplete+1;
    elsif coalesce((evaluation->>'passed')::boolean,false) then
      insert into public.enrollments(student_id,academic_year_id,class_id,active,deleted_at,updated_at)
      values(item.student_id,resolved_target_year_id,target_class_id,true,null,now())
      on conflict(student_id,academic_year_id) do update
        set class_id=excluded.class_id,active=true,deleted_at=null,updated_at=now();
      promoted:=promoted+1;
    else
      not_promoted:=not_promoted+1;
    end if;
  end loop;

  return jsonb_build_object(
    'promoted',promoted,
    'not_promoted',not_promoted,
    'incomplete',incomplete,
    'cutoff',cutoff,
    'target_class_id',target_class_id,
    'target_academic_year_id',resolved_target_year_id,
    'target_academic_year_name',target_year_name
  );
end $$;


-- -----------------------------------------------------------------------------
-- Enterprise v6.6.8: one-operation promotion across every eligible class
-- -----------------------------------------------------------------------------
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
  class_not_promoted integer:=0;
  class_incomplete integer:=0;
  promoted integer:=0;
  not_promoted integer:=0;
  incomplete integer:=0;
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
  from public.school_settings s order by s.created_at limit 1;

  perform set_config('app.change_reason','Term 3 all-class performance-based promotion',true);

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
    class_not_promoted:=coalesce((class_result->>'not_promoted')::integer,0);
    class_incomplete:=coalesce((class_result->>'incomplete')::integer,0);

    promoted:=promoted+class_promoted;
    not_promoted:=not_promoted+class_not_promoted;
    incomplete:=incomplete+class_incomplete;
    classes_processed:=classes_processed+1;
    if class_promoted+class_not_promoted+class_incomplete>0 then
      classes_with_reports:=classes_with_reports+1;
    end if;

    mappings:=mappings||jsonb_build_array(jsonb_build_object(
      'source_class_id',class_item.source_class_id,
      'source_class_name',class_item.source_class_name,
      'target_class_id',class_item.target_class_id,
      'target_class_name',class_item.target_class_name,
      'promoted',class_promoted,
      'not_promoted',class_not_promoted,
      'incomplete',class_incomplete
    ));
  end loop;

  if classes_processed=0 then
    raise exception 'No eligible class mapping is configured';
  end if;

  return jsonb_build_object(
    'classes_processed',classes_processed,
    'classes_with_reports',classes_with_reports,
    'classes_skipped',classes_skipped,
    'promoted',promoted,
    'not_promoted',not_promoted,
    'incomplete',incomplete,
    'cutoff',cutoff,
    'target_academic_year_id',resolved_target_year_id,
    'target_academic_year_name',target_year_name,
    'mappings',mappings
  );
end $$;

revoke all on function public.next_promotion_academic_year(uuid) from public,anon;
revoke all on function public.report_promotion_evaluation(uuid) from public,anon;
revoke all on function public.refresh_report_promotion(uuid,boolean) from public,anon;
revoke all on function public.apply_pending_term3_promotions() from public,anon;
revoke all on function public.save_promotion_cutoff(integer) from public,anon;
revoke all on function public.bulk_promote_all_classes(uuid,uuid) from public,anon;

grant execute on function public.next_promotion_academic_year(uuid) to authenticated;
grant execute on function public.report_promotion_evaluation(uuid) to authenticated;
grant execute on function public.save_promotion_cutoff(integer) to authenticated;
grant execute on function public.bulk_promote_class(uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.bulk_promote_all_classes(uuid,uuid) to authenticated;

comment on function public.next_promotion_academic_year(uuid) is
  'Returns the immediate next configured academic year for promotion processing.';
comment on function public.report_promotion_evaluation(uuid) is
  'Evaluates Term 3 promotion from the arithmetic mean of all assigned subject total scores, using the configured cutoff from 40 through 60.';
comment on function public.save_promotion_cutoff(integer) is
  'System Administrator-only academic setting for the Term 3 automatic-promotion pass mark.';
comment on function public.bulk_promote_class(uuid,uuid,uuid,uuid) is
  'Creates next-year enrolments only for students whose complete Term 3 average meets or exceeds the configured promotion cutoff.';
comment on function public.bulk_promote_all_classes(uuid,uuid) is
  'Processes every active source class that has a configured next class and maps each class to its respective next class in one atomic operation.';

-- Recalculate existing Term 3 reports. Published reports also receive a target
-- enrolment when both the next class and next academic year already exist.
do $$
declare item record;
begin
  for item in
    select r.id,r.status
    from public.student_reports r
    join public.terms t on t.id=r.term_id
    where r.deleted_at is null and t.sequence=3 and t.deleted_at is null
  loop
    perform public.refresh_report_promotion(item.id,item.status='published');
  end loop;
end $$;

commit;

select
  case
    when to_regprocedure('public.next_promotion_academic_year(uuid)') is not null
      and to_regprocedure('public.report_subject_positions(uuid)') is not null
      and to_regprocedure('public.delete_report_card_permanently(uuid,text)') is not null
      and to_regprocedure('public.list_report_pdf_paths(uuid)') is not null
      and to_regprocedure('public.allowed_report_transitions(uuid)') is not null
      and to_regprocedure('public.report_promotion_evaluation(uuid)') is not null
      and to_regprocedure('public.save_promotion_cutoff(integer)') is not null
      and to_regprocedure('public.bulk_promote_class(uuid,uuid,uuid,uuid)') is not null
      and to_regprocedure('public.bulk_promote_all_classes(uuid,uuid)') is not null
      and exists(
        select 1 from information_schema.columns
        where table_schema='public' and table_name='school_settings' and column_name='report_body_font'
      )
      and exists(
        select 1 from information_schema.columns
        where table_schema='public' and table_name='school_settings' and column_name='report_body_font_size'
      )
      and exists(
        select 1 from information_schema.columns
        where table_schema='public' and table_name='school_settings' and column_name='promotion_cutoff_score'
      )
      and exists(select 1 from pg_trigger where tgname='subject_result_auto_promotion_sync' and not tgisinternal)
      and exists(select 1 from pg_trigger where tgname='student_report_publish_auto_promotion' and not tgisinternal)
    then '04 SCHEMA: PASS'
    else '04 SCHEMA: CHECK REQUIRED'
  end as installation_status;

-- =============================================================================
-- Enterprise v6.6.10: reliable Term 3 recognition and applied promotion state
-- =============================================================================
begin;

create or replace function public.is_term_three(term_sequence integer,term_name text)
returns boolean
language sql
immutable
parallel safe
as $$
  select coalesce(term_sequence=3,false)
    or lower(regexp_replace(coalesce(term_name,''),'[^a-zA-Z0-9]+','','g'))
       in ('term3','termthree','thirdterm','3rdterm')
$$;

alter table public.enrollments
  add column if not exists enrollment_origin text not null default 'manual',
  add column if not exists promotion_source_report_id uuid,
  add column if not exists promotion_applied_at timestamptz;

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conrelid='public.enrollments'::regclass
      and conname='enrollments_origin_chk'
  ) then
    alter table public.enrollments
      add constraint enrollments_origin_chk
      check(enrollment_origin in ('manual','automatic_promotion'));
  end if;

  if not exists(
    select 1 from pg_constraint
    where conrelid='public.enrollments'::regclass
      and conname='enrollments_promotion_source_report_fk'
  ) then
    alter table public.enrollments
      add constraint enrollments_promotion_source_report_fk
      foreign key(promotion_source_report_id)
      references public.student_reports(id)
      on delete set null;
  end if;
end $$;

create index if not exists enrollments_promotion_source_report_idx
  on public.enrollments(promotion_source_report_id)
  where promotion_source_report_id is not null;

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
  promotion_applied boolean:=false;
begin
  if auth.uid() is not null and not public.can_view_report(target_report_id) then
    raise exception 'Access denied' using errcode='42501';
  end if;

  select
    t.sequence,
    t.name::text,
    e.class_id,
    c.name::text,
    c.level_order,
    e.academic_year_id,
    y.name::text,
    e.student_id
  into
    report_term_sequence,
    report_term_name,
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
    and target_enrollment_id is not null
    and target_enrollment_active
    and target_enrollment_class_id=next_class_id;

  return jsonb_build_object(
    'report_id',target_report_id,
    'term_sequence',report_term_sequence,
    'term_name',report_term_name,
    'term3',is_term_three,
    'complete',is_complete,
    'assigned_subjects',assigned_subjects,
    'completed_subjects',completed_subjects,
    'average',average_score,
    'cutoff',cutoff_score,
    'passed',has_passed,
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
    'can_create_enrollment',has_passed and next_class_id is not null and target_year_id is not null
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
  should_promote boolean;
  next_class_id uuid;
  target_year_id uuid;
  source_student_id uuid;
  enrollment_created boolean:=false;
  enrollment_withdrawn boolean:=false;
begin
  evaluation:=public.report_promotion_evaluation(target_report_id);
  should_promote:=coalesce((evaluation->>'passed')::boolean,false)
    and nullif(evaluation->>'next_class_id','') is not null;
  next_class_id:=public.safe_uuid(evaluation->>'next_class_id');
  target_year_id:=public.safe_uuid(evaluation->>'target_academic_year_id');

  select e.student_id into source_student_id
  from public.student_reports r
  join public.enrollments e on e.id=r.enrollment_id and e.deleted_at is null
  where r.id=target_report_id and r.deleted_at is null;

  perform set_config('app.report_write','on',true);
  update public.student_reports
  set promoted_to_class_id=case when should_promote then next_class_id else null end,
      updated_at=now()
  where id=target_report_id and deleted_at is null;

  if create_target_enrollment and source_student_id is not null and target_year_id is not null then
    if should_promote then
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
    'promoted_to_class_id',case when should_promote then next_class_id else null end,
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
  keep_target_enrollment_in_sync boolean:=false;
begin
  if tg_op='DELETE' then target_id:=old.report_id; else target_id:=new.report_id; end if;
  if exists(select 1 from public.student_reports r where r.id=target_id and r.deleted_at is null) then
    select exists(
      select 1 from public.enrollments e
      where e.promotion_source_report_id=target_id
        and e.enrollment_origin='automatic_promotion'
        and e.deleted_at is null
    ) into keep_target_enrollment_in_sync;
    perform public.refresh_report_promotion(target_id,keep_target_enrollment_in_sync);
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

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
      and r.status='published'
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
    select r.id,r.status
    from public.student_reports r
    join public.terms t on t.id=r.term_id
    where r.deleted_at is null
      and t.deleted_at is null
      and public.is_term_three(t.sequence,t.name::text)
  loop
    select item.status='published' or exists(
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

  perform set_config('app.change_reason','Term 3 performance-based class promotion',true);
  for item in
    select r.id,e.student_id,r.status
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
    elsif coalesce((evaluation->>'passed')::boolean,false) then
      promoted:=promoted+1;
    else
      not_promoted:=not_promoted+1;
    end if;
  end loop;

  return jsonb_build_object(
    'reports_found',reports_found,
    'promoted',promoted,
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
  class_not_promoted integer:=0;
  class_incomplete integer:=0;
  class_skipped_status integer:=0;
  class_reports_found integer:=0;
  promoted integer:=0;
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

  perform set_config('app.change_reason','Term 3 all-class performance-based promotion',true);

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
    class_not_promoted:=coalesce((class_result->>'not_promoted')::integer,0);
    class_incomplete:=coalesce((class_result->>'incomplete')::integer,0);
    class_skipped_status:=coalesce((class_result->>'skipped_status')::integer,0);
    class_reports_found:=coalesce((class_result->>'reports_found')::integer,0);

    promoted:=promoted+class_promoted;
    not_promoted:=not_promoted+class_not_promoted;
    incomplete:=incomplete+class_incomplete;
    skipped_status:=skipped_status+class_skipped_status;
    reports_found:=reports_found+class_reports_found;
    classes_processed:=classes_processed+1;
    if class_reports_found>0 then
      classes_with_reports:=classes_with_reports+1;
    end if;

    mappings:=mappings||jsonb_build_array(jsonb_build_object(
      'source_class_id',class_item.source_class_id,
      'source_class_name',class_item.source_class_name,
      'target_class_id',class_item.target_class_id,
      'target_class_name',class_item.target_class_name,
      'reports_found',class_reports_found,
      'promoted',class_promoted,
      'not_promoted',class_not_promoted,
      'incomplete',class_incomplete,
      'skipped_status',class_skipped_status
    ));
  end loop;

  if classes_processed=0 then
    raise exception 'No eligible class mapping is configured';
  end if;

  return jsonb_build_object(
    'classes_processed',classes_processed,
    'classes_with_reports',classes_with_reports,
    'classes_skipped',classes_skipped,
    'reports_found',reports_found,
    'promoted',promoted,
    'not_promoted',not_promoted,
    'incomplete',incomplete,
    'skipped_status',skipped_status,
    'cutoff',cutoff,
    'target_academic_year_id',resolved_target_year_id,
    'target_academic_year_name',target_year_name,
    'mappings',mappings
  );
end $$;

revoke all on function public.is_term_three(integer,text) from public,anon;
revoke all on function public.report_promotion_evaluation(uuid) from public,anon;
revoke all on function public.refresh_report_promotion(uuid,boolean) from public,anon;
revoke all on function public.apply_pending_term3_promotions() from public,anon;
revoke all on function public.save_promotion_cutoff(integer) from public,anon;

grant execute on function public.is_term_three(integer,text) to authenticated;
grant execute on function public.report_promotion_evaluation(uuid) to authenticated;
grant execute on function public.save_promotion_cutoff(integer) to authenticated;
grant execute on function public.bulk_promote_class(uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.bulk_promote_all_classes(uuid,uuid) to authenticated;

comment on function public.is_term_three(integer,text) is
  'Recognises Term 3 by configured sequence or common Term 3 naming formats.';
comment on function public.report_promotion_evaluation(uuid) is
  'Evaluates Term 3 eligibility and reports whether the immediate next-year enrolment has actually been applied.';
comment on function public.bulk_promote_class(uuid,uuid,uuid,uuid) is
  'Processes complete Term 3 assessment records in draft through published states, excluding returned and withdrawn reports, into the immediate next academic year.';

-- Re-evaluate every recognised Term 3 report. Existing automatic-promotion
-- enrolments remain synchronised; published reports may create the next-year
-- enrolment immediately.
do $$
declare
  item record;
  sync_enrollment boolean;
begin
  for item in
    select r.id,r.status
    from public.student_reports r
    join public.terms t on t.id=r.term_id
    where r.deleted_at is null
      and t.deleted_at is null
      and public.is_term_three(t.sequence,t.name::text)
  loop
    select item.status='published' or exists(
      select 1 from public.enrollments e
      where e.promotion_source_report_id=item.id
        and e.enrollment_origin='automatic_promotion'
        and e.deleted_at is null
    ) into sync_enrollment;
    perform public.refresh_report_promotion(item.id,sync_enrollment);
  end loop;
end $$;

commit;

select
  case
    when to_regprocedure('public.is_term_three(integer,text)') is not null
      and to_regprocedure('public.report_promotion_evaluation(uuid)') is not null
      and to_regprocedure('public.bulk_promote_class(uuid,uuid,uuid,uuid)') is not null
      and to_regprocedure('public.bulk_promote_all_classes(uuid,uuid)') is not null
      and exists(
        select 1 from information_schema.columns
        where table_schema='public' and table_name='enrollments' and column_name='promotion_source_report_id'
      )
      and exists(
        select 1 from information_schema.columns
        where table_schema='public' and table_name='enrollments' and column_name='enrollment_origin'
      )
      and exists(select 1 from pg_trigger where tgname='subject_result_auto_promotion_sync' and not tgisinternal)
    then '04 SCHEMA: PASS'
    else '04 SCHEMA: CHECK REQUIRED'
  end as installation_status;

