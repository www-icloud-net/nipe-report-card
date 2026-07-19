-- NIPE INTERNATIONAL SCHOOL REPORT CARD SYSTEM
-- Enterprise v6.5.2 Split-Schema Dashboard Editor Edition
-- DATABASE PART 3A: CORE HARDENING, PERSISTENCE AND SCHEDULED JOBS
-- Run this file only after 02_schema_operations.sql completes successfully.
-- After this file succeeds, run 03B_schema_staff_academics_and_governance.sql.

-- Ensure the Principal role exists before any v6.5-aware function is compiled.
begin;
alter type public.app_role add value if not exists 'principal';
commit;
begin;



-- -----------------------------------------------------------------------------
-- Reliable teacher record persistence
-- -----------------------------------------------------------------------------
create or replace function public.save_teacher(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  tid uuid := public.safe_uuid(payload->>'id');
  profileid uuid := public.safe_uuid(payload->>'profile_id');
  staff text := btrim(coalesce(payload->>'staff_no',''));
  current_updated timestamptz;
  expected_updated timestamptz := nullif(payload->>'updated_at','')::timestamptz;
  employment text := coalesce(nullif(btrim(payload->>'employment_status'),''),'active');
  gender_value text := coalesce(nullif(btrim(payload->>'gender'),''),'Other');
  linked_role text;
begin
  if not public.can_manage_teachers() then raise exception 'Access denied' using errcode='42501'; end if;
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;

  if tid is not null then
    select updated_at into current_updated from public.teachers where id=tid and deleted_at is null for update;
    if not found then raise exception 'Teacher record not found'; end if;
    if expected_updated is not null and current_updated is distinct from expected_updated then
      raise exception 'Teacher record changed by another user' using errcode='40001';
    end if;
  end if;

  if staff='' or btrim(coalesce(payload->>'first_name',''))='' or btrim(coalesce(payload->>'last_name',''))='' then
    raise exception 'Staff number, first name, and last name are required';
  end if;
  if gender_value not in ('Male','Female','Other') then raise exception 'Gender selection is invalid'; end if;
  if employment not in ('active','leave','suspended','resigned','retired') then raise exception 'Employment status is invalid'; end if;
  if nullif(payload->>'date_joined','')::date > current_date then raise exception 'Date joined cannot be in the future'; end if;

  if exists(
    select 1 from public.teachers t where lower(t.staff_no::text)=lower(staff) and (tid is null or t.id<>tid)
  ) then raise exception 'Staff number already exists'; end if;

  if profileid is not null then
    select public.current_app_role_for(p.role) into linked_role from public.profiles p where p.id=profileid and p.active;
    if linked_role is null then raise exception 'Selected user account is unavailable'; end if;
    if linked_role not in ('principal','academic_admin','class_teacher','subject_teacher') then
      raise exception 'Selected user account does not have a teaching role';
    end if;
    if exists(
      select 1 from public.teachers t where t.profile_id=profileid and t.deleted_at is null and (tid is null or t.id<>tid)
    ) then raise exception 'This user account is already linked to another teacher'; end if;
  end if;

  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Teacher record update'),true);

  if tid is null then
    insert into public.teachers(
      profile_id,staff_no,first_name,middle_name,last_name,gender,phone,email,address,
      qualification,specialization,date_joined,employment_status,notes,active,created_by,updated_at
    ) values(
      profileid,staff,btrim(payload->>'first_name'),btrim(coalesce(payload->>'middle_name','')),
      btrim(payload->>'last_name'),gender_value,btrim(coalesce(payload->>'phone','')),
      nullif(btrim(coalesce(payload->>'email','')),'')::citext,btrim(coalesce(payload->>'address','')),
      btrim(coalesce(payload->>'qualification','')),btrim(coalesce(payload->>'specialization','')),
      nullif(payload->>'date_joined','')::date,employment,btrim(coalesce(payload->>'notes','')),
      coalesce((payload->>'active')::boolean,true),auth.uid(),now()
    ) returning id into tid;
  else
    update public.teachers set
      profile_id=profileid,staff_no=staff,first_name=btrim(payload->>'first_name'),
      middle_name=btrim(coalesce(payload->>'middle_name','')),last_name=btrim(payload->>'last_name'),
      gender=gender_value,phone=btrim(coalesce(payload->>'phone','')),
      email=nullif(btrim(coalesce(payload->>'email','')),'')::citext,address=btrim(coalesce(payload->>'address','')),
      qualification=btrim(coalesce(payload->>'qualification','')),
      specialization=btrim(coalesce(payload->>'specialization','')),
      date_joined=nullif(payload->>'date_joined','')::date,employment_status=employment,
      notes=btrim(coalesce(payload->>'notes','')),active=coalesce((payload->>'active')::boolean,true),updated_at=now()
    where id=tid and deleted_at is null;
  end if;

  return public.get_teacher_record(tid);
exception when unique_violation then
  raise exception 'Staff number or linked user account is already in use';
end $$;

-- -----------------------------------------------------------------------------
-- Atomic profile and delegated-access persistence for the Auth Edge Function
-- -----------------------------------------------------------------------------
create or replace function public.admin_apply_user_bundle(actor_id uuid,bundle jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  targetid uuid := public.safe_uuid(bundle->>'user_id');
  role_text text := btrim(coalesce(bundle->>'role','viewer'));
  item jsonb;
  classid uuid;
  subjectid uuid;
  accesslevel text;
  previous jsonb;
begin
  if actor_id is null or not exists(
    select 1 from public.profiles p where p.id=actor_id and p.active
      and public.current_app_role_for(p.role)='system_admin'
  ) then raise exception 'Access denied' using errcode='42501'; end if;
  if targetid is null then raise exception 'User account identifier is required'; end if;
  if role_text not in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian') then
    raise exception 'User role is invalid';
  end if;
  if btrim(coalesce(bundle->>'full_name',''))='' then raise exception 'Full name is required'; end if;
  if not exists(select 1 from auth.users where id=targetid) then raise exception 'Authentication account was not found'; end if;

  select jsonb_build_object(
    'profile',to_jsonb(p),
    'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb)
  ) into previous from public.profiles p where p.id=targetid;

  insert into public.profiles(id,full_name,role,active,mfa_required,phone,updated_at)
  values(
    targetid,btrim(bundle->>'full_name'),role_text::public.app_role,
    coalesce((bundle->>'active')::boolean,true),coalesce((bundle->>'mfa_required')::boolean,false),
    btrim(coalesce(bundle->>'phone','')),now()
  ) on conflict(id) do update set
    full_name=excluded.full_name,role=excluded.role,active=excluded.active,
    mfa_required=excluded.mfa_required,phone=excluded.phone,updated_at=now();

  delete from public.user_class_access where user_id=targetid;
  for item in select value from jsonb_array_elements(coalesce(bundle->'access','[]'::jsonb)) loop
    classid := public.safe_uuid(item->>'class_id');
    subjectid := public.safe_uuid(item->>'subject_id');
    accesslevel := coalesce(nullif(btrim(item->>'access_level'),''),'view');
    if classid is null or not exists(select 1 from public.classes c where c.id=classid and c.deleted_at is null and c.active) then
      raise exception 'A delegated class is invalid or inactive';
    end if;
    if subjectid is not null and not exists(select 1 from public.subjects s where s.id=subjectid and s.deleted_at is null and s.active) then
      raise exception 'A delegated subject is invalid or inactive';
    end if;
    if accesslevel not in ('view','edit','score','review') then raise exception 'Delegated access level is invalid'; end if;
    insert into public.user_class_access(user_id,class_id,subject_id,access_level)
    values(targetid,classid,subjectid,accesslevel)
    on conflict do nothing;
  end loop;

  insert into public.audit_log(actor_id,table_name,record_id,action,old_data,new_data,reason)
  values(
    actor_id,'profiles',targetid,
    case when previous is null then 'ADMIN_CREATE_USER' else 'ADMIN_UPDATE_USER' end,
    previous,
    jsonb_build_object(
      'profile',(select to_jsonb(p) from public.profiles p where p.id=targetid),
      'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb)
    ),
    coalesce(nullif(bundle->>'reason',''),'User account management')
  );

  return jsonb_build_object(
    'profile',(select to_jsonb(p) from public.profiles p where p.id=targetid),
    'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb)
  );
end $$;

-- -----------------------------------------------------------------------------
-- Safe report-card removal and restoration
-- -----------------------------------------------------------------------------
alter table public.student_reports add column if not exists archived_status public.report_status;
create index if not exists student_reports_deleted_idx on public.student_reports(deleted_at,term_id);

create or replace function public.can_remove_report(target_report_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1 from public.student_reports r
    where r.id=target_report_id and r.deleted_at is null and (
      public.is_academic_manager()
      or (
        public.has_role(array['class_teacher'])
        and r.status in ('draft','returned')
        and public.can_access_class(public.report_class_id(r.id),true)
      )
    )
  )
$$;

create or replace function public.archive_report_card(target_report_id uuid,reason_text text default 'Report card removed')
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare current_status public.report_status;
begin
  if not public.can_remove_report(target_report_id) then raise exception 'Access denied' using errcode='42501'; end if;
  select status into current_status from public.student_reports
  where id=target_report_id and deleted_at is null for update;
  if not found then raise exception 'Report card not found'; end if;
  if current_status in ('approved','published','withdrawn') then
    if not public.has_role(array['system_admin','principal']) then raise exception 'Only the Principal or System Administrator can remove this report'; end if;
    perform public.require_sensitive_access();
  end if;
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Report card removed'),true);
  update public.student_reports set
    archived_status=current_status,status='withdrawn',withdrawn_at=coalesce(withdrawn_at,now()),
    deleted_at=now(),version=version+1,updated_at=now()
  where id=target_report_id;
  update public.report_publications set revoked_at=coalesce(revoked_at,now()),revoked_by=auth.uid()
  where report_id=target_report_id and revoked_at is null;
  return true;
end $$;

create or replace function public.restore_report_card(target_report_id uuid,reason_text text default 'Report card restored')
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare previous_status public.report_status; target_enrollment_id uuid; target_term_id uuid;
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  select archived_status,enrollment_id,term_id into previous_status,target_enrollment_id,target_term_id from public.student_reports
  where id=target_report_id and deleted_at is not null for update;
  if not found then raise exception 'Removed report card not found'; end if;
  perform pg_advisory_xact_lock(hashtext(target_enrollment_id::text),hashtext(target_term_id::text));
  if exists(
    select 1 from public.student_reports r
    where r.enrollment_id=target_enrollment_id and r.term_id=target_term_id
      and r.deleted_at is null and r.id<>target_report_id
  ) then
    raise exception 'A current report already exists for this student and term. Remove the current report before restoring this archived report.';
  end if;
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Report card restored'),true);
  update public.student_reports set
    status=case when previous_status in ('published','withdrawn') then 'approved'::public.report_status
                else coalesce(previous_status,'draft'::public.report_status) end,
    archived_status=null,deleted_at=null,version=version+1,updated_at=now()
  where id=target_report_id;
  return true;
end $$;

create or replace function public.list_report_cards_v6(
  target_term_id uuid default null,target_class_id uuid default null,target_status public.report_status default null,
  search_text text default '',archive_filter text default 'active',page_number integer default 1,page_size integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare offset_value integer:=greatest(page_number-1,0)*least(greatest(page_size,1),100);
declare limit_value integer:=least(greatest(page_size,1),100);
begin
  if archive_filter not in ('active','archived','all') then archive_filter:='active'; end if;
  if archive_filter<>'active' and not (public.is_academic_manager() or public.has_role(array['class_teacher'])) then
    raise exception 'Access denied' using errcode='42501';
  end if;
  return (
    with matching as (
      select r.id,r.report_number,r.status,r.archived_status,r.version,r.updated_at,r.published_at,r.deleted_at,
        (r.deleted_at is not null) archived,e.student_id,e.class_id,r.term_id,s.admission_no,
        concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name) student_name,
        s.photo_url,c.name class_name,t.name term_name,y.name academic_year_name,
        round(coalesce(avg(sr.total_score),0),2) average,count(sr.id) subject_count
      from public.student_reports r
      join public.enrollments e on e.id=r.enrollment_id
      join public.students s on s.id=e.student_id
      join public.classes c on c.id=e.class_id
      join public.terms t on t.id=r.term_id
      join public.academic_years y on y.id=t.academic_year_id
      left join public.subject_results sr on sr.report_id=r.id
      where public.can_view_report(r.id)
        and (archive_filter='all' or (archive_filter='active' and r.deleted_at is null)
          or (archive_filter='archived' and r.deleted_at is not null))
        and (target_term_id is null or r.term_id=target_term_id)
        and (target_class_id is null or e.class_id=target_class_id)
        and (target_status is null or coalesce(r.archived_status,r.status)=target_status)
        and (coalesce(search_text,'')='' or s.admission_no::text ilike '%'||search_text||'%'
          or coalesce(r.report_number::text,'') ilike '%'||search_text||'%'
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

-- -----------------------------------------------------------------------------
-- Role-aligned dashboards and navigation permissions
-- -----------------------------------------------------------------------------
create or replace function public.get_role_dashboard(target_term_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare termid uuid:=target_term_id;
declare v_current_role text:=public.current_app_role()::text;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if termid is null then select id into termid from public.terms where is_active and deleted_at is null limit 1; end if;
  return jsonb_build_object(
    'role',v_current_role,
    'active_students',(select count(*) from public.students s where s.status='active' and s.deleted_at is null and public.can_view_student(s.id)),
    'active_classes',(select count(*) from public.classes c where c.active and c.deleted_at is null and (public.is_records_manager() or public.can_access_class(c.id,false))),
    'active_teachers',case when public.can_manage_teachers() or public.has_role(array['system_admin','principal','academic_admin'])
      then (select count(*) from public.teachers t where t.active and t.deleted_at is null) else 0 end,
    'active_users',case when public.is_system_admin() then (select count(*) from public.profiles p where p.active) else 0 end,
    'reports',(select count(*) from public.student_reports r where r.term_id=termid and r.deleted_at is null and public.can_view_report(r.id)),
    'published',(select count(*) from public.student_reports r where r.term_id=termid and r.status='published' and r.deleted_at is null and public.can_view_report(r.id)),
    'draft_returned',(select count(*) from public.student_reports r where r.term_id=termid and r.status in ('draft','returned') and r.deleted_at is null and public.can_view_report(r.id)),
    'pending_review',(select count(*) from public.student_reports r where r.term_id=termid and r.status in ('submitted','class_reviewed','approved') and r.deleted_at is null and public.can_view_report(r.id)),
    'assigned_classes',(select count(distinct c.id) from public.classes c where c.deleted_at is null and c.active and public.can_access_class(c.id,false)),
    'assigned_subjects',(select count(distinct cs.subject_id) from public.class_subjects cs join public.classes c on c.id=cs.class_id
      where cs.active and c.deleted_at is null and (cs.teacher_id=auth.uid() or public.is_academic_manager())),
    'missing_guardians',case when public.is_records_manager() then (
      select count(*) from public.students s where s.deleted_at is null and not exists(
        select 1 from public.guardian_links gl where gl.student_id=s.id
      )
    ) else 0 end,
    'missing_photos',case when public.is_records_manager() then (
      select count(*) from public.students s where s.deleted_at is null and btrim(coalesce(s.photo_url,''))=''
    ) else 0 end,
    'children',case when v_current_role='parent_guardian' then (
      select count(distinct gl.student_id) from public.guardian_links gl where gl.auth_user_id=auth.uid()
    ) else 0 end,
    'unread_notifications',(select count(*) from public.notifications n where n.recipient_id=auth.uid() and n.read_at is null),
    'average',coalesce((select round(avg(sr.total_score),2) from public.subject_results sr
      join public.student_reports r on r.id=sr.report_id
      where r.term_id=termid and r.status='published' and r.deleted_at is null and public.can_view_report(r.id)),0),
    'by_status',coalesce((select jsonb_object_agg(status,count_value) from (
      select r.status::text status,count(*) count_value from public.student_reports r
      where r.term_id=termid and r.deleted_at is null and public.can_view_report(r.id) group by r.status
    ) q),'{}'::jsonb),
    'class_performance',coalesce((select jsonb_agg(to_jsonb(q) order by q.class_name) from (
      select c.id class_id,c.name class_name,round(avg(sr.total_score),2) average
      from public.subject_results sr join public.student_reports r on r.id=sr.report_id
      join public.enrollments e on e.id=r.enrollment_id join public.classes c on c.id=e.class_id
      where r.term_id=termid and r.status='published' and r.deleted_at is null and public.can_view_report(r.id)
      group by c.id,c.name
    ) q),'[]'::jsonb),
    'recent',coalesce((select jsonb_agg(to_jsonb(q) order by q.updated_at desc) from (
      select r.id,r.report_number,r.status,r.version,r.updated_at,
        concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name) student_name,
        c.name class_name,t.name term_name,round(coalesce(avg(sr.total_score),0),2) average
      from public.student_reports r join public.enrollments e on e.id=r.enrollment_id
      join public.students s on s.id=e.student_id join public.classes c on c.id=e.class_id
      join public.terms t on t.id=r.term_id left join public.subject_results sr on sr.report_id=r.id
      where r.deleted_at is null and public.can_view_report(r.id)
      group by r.id,s.id,c.id,t.id order by r.updated_at desc limit 8
    ) q),'[]'::jsonb)
  );
end $$;

create or replace function public.get_bootstrap_data()
returns jsonb
language plpgsql
security definer
set search_path=public
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
      'create_reports',public.is_academic_manager() or public.has_role(array['class_teacher','subject_teacher']),
      'import_scores',public.is_academic_manager() or public.has_role(array['class_teacher','subject_teacher']),
      'remove_reports',public.is_academic_manager() or public.has_role(array['class_teacher']),
      'restore_reports',public.is_academic_manager(),
      'approve_reports',public.has_role(array['system_admin','principal']),
      'publish_reports',public.has_role(array['system_admin','principal']),
      'view_audit',public.has_role(array['system_admin','principal','academic_admin']),
      'run_backup',public.is_system_admin(),
      'parent_portal',public.has_role(array['parent_guardian'])
    ),
    'topics',to_jsonb(public.my_realtime_topics())
  ) into result;
  return result;
end $$;

-- -----------------------------------------------------------------------------
-- Versioned protected backup snapshot
-- -----------------------------------------------------------------------------
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
    'generated_at',now(),'schema_version','6.1.1',
    'school_settings',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.school_settings x),
    'profiles',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.profiles x),
    'user_class_access',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.user_class_access x),
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

-- Security and execution grants.
revoke all on function public.safe_uuid(text) from public,anon;
revoke all on function public.list_guardian_portal_accounts(text) from public,anon;
revoke all on function public.admin_apply_user_bundle(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.can_remove_report(uuid) from public,anon;
revoke all on function public.archive_report_card(uuid,text) from public,anon;
revoke all on function public.restore_report_card(uuid,text) from public,anon;
revoke all on function public.list_report_cards_v6(uuid,uuid,public.report_status,text,text,integer,integer) from public,anon;
revoke all on function public.get_role_dashboard(uuid) from public,anon;

grant execute on function public.list_guardian_portal_accounts(text) to authenticated;
grant execute on function public.admin_apply_user_bundle(uuid,jsonb) to service_role;
grant execute on function public.can_remove_report(uuid) to authenticated;
grant execute on function public.archive_report_card(uuid,text) to authenticated;
grant execute on function public.restore_report_card(uuid,text) to authenticated;
grant execute on function public.list_report_cards_v6(uuid,uuid,public.report_status,text,text,integer,integer) to authenticated;
grant execute on function public.get_role_dashboard(uuid) to authenticated;

commit;

-- =============================================================================
-- SCHEDULED EDGE FUNCTION JOBS
-- This section is safe to rerun. Jobs are created only when the required
-- Supabase Vault secrets already exist.
-- =============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
do $$
declare project_url text; cron_secret text;
begin
  if to_regclass('vault.decrypted_secrets') is null then return; end if;
  select decrypted_secret into project_url from vault.decrypted_secrets where name='nis_project_url' limit 1;
  select decrypted_secret into cron_secret from vault.decrypted_secrets where name='nis_cron_secret' limit 1;
  if project_url is null or cron_secret is null then return; end if;

  perform cron.unschedule(jobid) from cron.job where jobname in ('nis-notification-dispatcher','nis-scheduled-backup');

  perform cron.schedule(
    'nis-notification-dispatcher',
    '*/5 * * * *',
    format($job$
      select net.http_post(
        url := %L || '/functions/v1/notification-dispatcher',
        headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',%L),
        body := '{}'::jsonb
      );
    $job$,project_url,cron_secret)
  );

  perform cron.schedule(
    'nis-scheduled-backup',
    '15 2 * * *',
    format($job$
      select net.http_post(
        url := %L || '/functions/v1/scheduled-backup',
        headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',%L),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
      );
    $job$,project_url,cron_secret)
  );
end $$;
-- =============================================================================
-- ENTERPRISE RELEASE 6.1.1 PERSISTENCE AND ROLE WORKSPACE HARDENING
-- =============================================================================
begin;

create or replace function public.safe_date(value text)
returns date
language plpgsql
immutable
as $$
begin
  if value is null or btrim(value)='' then return null; end if;
  return btrim(value)::date;
exception when invalid_datetime_format or datetime_field_overflow then
  return null;
end $$;

create or replace function public.safe_timestamptz(value text)
returns timestamptz
language plpgsql
immutable
as $$
begin
  if value is null or btrim(value)='' then return null; end if;
  return btrim(value)::timestamptz;
exception when invalid_datetime_format or datetime_field_overflow then
  return null;
end $$;

create or replace function public.safe_integer(value text)
returns integer
language plpgsql
immutable
as $$
begin
  if value is null or btrim(value)='' then return null; end if;
  return btrim(value)::integer;
exception when invalid_text_representation or numeric_value_out_of_range then
  return null;
end $$;

create or replace function public.safe_numeric(value text)
returns numeric
language plpgsql
immutable
as $$
begin
  if value is null or btrim(value)='' then return null; end if;
  return btrim(value)::numeric;
exception when invalid_text_representation or numeric_value_out_of_range then
  return null;
end $$;

create or replace function public.safe_boolean(value text,default_value boolean default false)
returns boolean
language plpgsql
immutable
as $$
begin
  if value is null or btrim(value)='' then return default_value; end if;
  if lower(btrim(value)) in ('true','t','1','yes','y','on') then return true; end if;
  if lower(btrim(value)) in ('false','f','0','no','n','off') then return false; end if;
  return default_value;
end $$;

-- One delegated access row per class scope or class-subject scope.
with ranked as (
  select id,row_number() over(
    partition by user_id,class_id,coalesce(subject_id,'00000000-0000-0000-0000-000000000000'::uuid)
    order by case access_level when 'review' then 4 when 'edit' then 3 when 'score' then 2 else 1 end desc,created_at desc,id
  ) rn
  from public.user_class_access
)
delete from public.user_class_access a using ranked r where a.id=r.id and r.rn>1;

drop index if exists public.user_class_access_class_scope_idx;
drop index if exists public.user_class_access_subject_scope_idx;
create unique index user_class_access_class_scope_idx
  on public.user_class_access(user_id,class_id) where subject_id is null;
create unique index user_class_access_subject_scope_idx
  on public.user_class_access(user_id,class_id,subject_id) where subject_id is not null;

-- Validate the complete application profile/access bundle before Supabase Auth is changed.
create or replace function public.admin_validate_user_bundle(actor_id uuid,bundle jsonb,require_existing_user boolean default false)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  targetid uuid:=public.safe_uuid(bundle->>'user_id');
  role_text text:=btrim(coalesce(bundle->>'role','viewer'));
  item jsonb; classid uuid; subjectid uuid; accesslevel text; scopekey text;
  seen_scopes text[]:='{}'::text[]; has_class_scope boolean:=false;
begin
  if actor_id is null or not exists(
    select 1 from public.profiles p where p.id=actor_id and p.active
      and public.current_app_role_for(p.role)='system_admin'
  ) then raise exception 'Access denied' using errcode='42501'; end if;
  if require_existing_user and (targetid is null or not exists(select 1 from auth.users u where u.id=targetid)) then
    raise exception 'Authentication account was not found';
  end if;
  if btrim(coalesce(bundle->>'full_name',''))='' then raise exception 'Full name is required'; end if;
  if btrim(coalesce(bundle->>'email',''))='' then raise exception 'Email address is required'; end if;
  if bundle->>'email' !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Email address is invalid';
  end if;
  if role_text not in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian') then
    raise exception 'User role is invalid';
  end if;
  if jsonb_typeof(coalesce(bundle->'access','[]'::jsonb))<>'array' then raise exception 'Delegated access must be a list'; end if;
  for item in select value from jsonb_array_elements(coalesce(bundle->'access','[]'::jsonb)) loop
    classid:=public.safe_uuid(item->>'class_id');
    subjectid:=public.safe_uuid(item->>'subject_id');
    accesslevel:=coalesce(nullif(btrim(item->>'access_level'),''),'view');
    if btrim(coalesce(item->>'class_id',''))<>'' and classid is null then raise exception 'A delegated class identifier is invalid'; end if;
    if btrim(coalesce(item->>'subject_id',''))<>'' and subjectid is null then raise exception 'A delegated subject identifier is invalid'; end if;
    if classid is null or not exists(select 1 from public.classes c where c.id=classid and c.deleted_at is null and c.active) then
      raise exception 'A delegated class is invalid or inactive';
    end if;
    if subjectid is not null and not exists(
      select 1 from public.class_subjects cs join public.subjects s on s.id=cs.subject_id
      where cs.class_id=classid and cs.subject_id=subjectid and cs.active and s.active and s.deleted_at is null
    ) then raise exception 'A delegated subject is not actively assigned to the selected class'; end if;
    if accesslevel not in ('view','edit','score','review') then raise exception 'Delegated access level is invalid'; end if;
    if role_text='subject_teacher' and subjectid is null then raise exception 'Subject teacher access must identify a subject'; end if;
    if role_text='subject_teacher' and accesslevel not in ('score','edit','review') then raise exception 'Subject teacher access must permit scoring'; end if;
    if role_text='class_teacher' and subjectid is null and accesslevel not in ('edit','review') then raise exception 'Class teacher access must permit class report editing'; end if;
    if role_text='class_teacher' and subjectid is null and accesslevel in ('edit','review') then has_class_scope:=true; end if;
    scopekey:=classid::text||'|'||coalesce(subjectid::text,'*');
    if scopekey=any(seen_scopes) then raise exception 'The same delegated class or subject access was entered more than once'; end if;
    seen_scopes:=array_append(seen_scopes,scopekey);
  end loop;
  if role_text='class_teacher' and coalesce(jsonb_array_length(bundle->'access'),0)>0 and not has_class_scope then raise exception 'Class teacher delegated access requires at least one class-wide editing scope'; end if;
  return jsonb_build_object('valid',true,'role',role_text,'access_count',coalesce(jsonb_array_length(bundle->'access'),0));
end $$;

create or replace function public.admin_apply_user_bundle(actor_id uuid,bundle jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  targetid uuid:=public.safe_uuid(bundle->>'user_id');
  role_text text:=btrim(coalesce(bundle->>'role','viewer'));
  item jsonb; classid uuid; subjectid uuid; accesslevel text; previous jsonb;
begin
  perform public.admin_validate_user_bundle(actor_id,bundle,true);
  select jsonb_build_object(
    'profile',to_jsonb(p),
    'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb)
  ) into previous from public.profiles p where p.id=targetid;

  insert into public.profiles(id,full_name,role,active,mfa_required,phone,updated_at)
  values(targetid,btrim(bundle->>'full_name'),role_text::public.app_role,
    public.safe_boolean(bundle->>'active',true),public.safe_boolean(bundle->>'mfa_required',false),
    btrim(coalesce(bundle->>'phone','')),now())
  on conflict(id) do update set full_name=excluded.full_name,role=excluded.role,active=excluded.active,
    mfa_required=excluded.mfa_required,phone=excluded.phone,updated_at=now();

  delete from public.user_class_access where user_id=targetid;
  for item in select value from jsonb_array_elements(coalesce(bundle->'access','[]'::jsonb)) loop
    classid:=public.safe_uuid(item->>'class_id'); subjectid:=public.safe_uuid(item->>'subject_id');
    accesslevel:=coalesce(nullif(btrim(item->>'access_level'),''),'view');
    insert into public.user_class_access(user_id,class_id,subject_id,access_level)
    values(targetid,classid,subjectid,accesslevel);
  end loop;

  insert into public.audit_log(actor_id,table_name,record_id,action,old_data,new_data,reason)
  values(actor_id,'profiles',targetid,case when previous is null then 'ADMIN_CREATE_USER' else 'ADMIN_UPDATE_USER' end,
    previous,jsonb_build_object('profile',(select to_jsonb(p) from public.profiles p where p.id=targetid),
      'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb)),
    coalesce(nullif(bundle->>'reason',''),'User account management'));
  return jsonb_build_object('profile',(select to_jsonb(p) from public.profiles p where p.id=targetid),
    'access',coalesce((select jsonb_agg(to_jsonb(a)) from public.user_class_access a where a.user_id=targetid),'[]'::jsonb));
end $$;

-- Atomic student record persistence with destination-class validation.
create or replace function public.save_student(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  sid uuid; eid uuid; gid uuid; classid uuid; yearid uuid; guardian_auth_id uuid;
  student_data jsonb:=coalesce(payload->'student','{}'::jsonb);
  enrollment_data jsonb:=coalesce(payload->'enrollment','{}'::jsonb);
  guardian_data jsonb:=coalesce(payload->'guardian','{}'::jsonb);
  current_updated timestamptz; expected_updated timestamptz; birthdate date; rollno integer;
  requested_active boolean:=public.safe_boolean(enrollment_data->>'active',true);
  gender_value text:=coalesce(nullif(btrim(student_data->>'gender'),''),'Other');
  status_value text:=coalesce(nullif(btrim(student_data->>'status'),''),'active');
  affected integer:=0;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if not public.is_system_admin() then raise exception 'Only the System Administrator can create or edit student records' using errcode='42501'; end if;
  sid:=public.safe_uuid(student_data->>'id'); classid:=public.safe_uuid(enrollment_data->>'class_id');
  yearid:=public.safe_uuid(enrollment_data->>'academic_year_id'); guardian_auth_id:=public.safe_uuid(guardian_data->>'auth_user_id');
  expected_updated:=public.safe_timestamptz(student_data->>'updated_at'); birthdate:=public.safe_date(student_data->>'date_of_birth');
  rollno:=public.safe_integer(enrollment_data->>'roll_number');

  if btrim(coalesce(student_data->>'id',''))<>'' and sid is null then raise exception 'Student record identifier is invalid'; end if;
  if btrim(coalesce(enrollment_data->>'class_id',''))<>'' and classid is null then raise exception 'Selected class is invalid'; end if;
  if btrim(coalesce(enrollment_data->>'academic_year_id',''))<>'' and yearid is null then raise exception 'Selected academic year is invalid'; end if;
  if btrim(coalesce(guardian_data->>'auth_user_id',''))<>'' and guardian_auth_id is null then raise exception 'Selected guardian portal account is invalid'; end if;
  if btrim(coalesce(student_data->>'date_of_birth',''))<>'' and birthdate is null then raise exception 'Date of birth is invalid'; end if;
  if btrim(coalesce(enrollment_data->>'roll_number',''))<>'' and rollno is null then raise exception 'Roll number is invalid'; end if;

  if btrim(coalesce(student_data->>'admission_no',''))='' or btrim(coalesce(student_data->>'first_name',''))='' or btrim(coalesce(student_data->>'last_name',''))='' then
    raise exception 'Admission number, first name, and last name are required';
  end if;
  if gender_value not in ('Male','Female','Other') then raise exception 'Gender selection is invalid'; end if;
  if status_value not in ('active','graduated','withdrawn','suspended') then raise exception 'Student status is invalid'; end if;
  if btrim(coalesce(guardian_data->>'email',''))<>'' and guardian_data->>'email' !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Guardian email address is invalid'; end if;
  if birthdate>current_date then raise exception 'Date of birth cannot be in the future'; end if;
  if rollno is not null and rollno<1 then raise exception 'Roll number must be greater than zero'; end if;
  if (classid is null)<>(yearid is null) then raise exception 'Academic year and class must be selected together'; end if;

  if sid is null then
    if not (public.is_records_manager() or (public.has_role(array['class_teacher']) and classid is not null and public.can_access_class(classid,true))) then
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

  if classid is not null then
    if not exists(select 1 from public.classes c where c.id=classid and c.active and c.deleted_at is null) then raise exception 'Selected class is not active'; end if;
    if not exists(select 1 from public.academic_years y where y.id=yearid and y.deleted_at is null) then raise exception 'Selected academic year is unavailable'; end if;
    if public.has_role(array['class_teacher']) and not public.is_records_manager() and not public.can_access_class(classid,true) then
      raise exception 'You can only save students in an assigned class' using errcode='42501';
    end if;
  end if;
  if exists(select 1 from public.students s where lower(s.admission_no::text)=lower(btrim(student_data->>'admission_no')) and (sid is null or s.id<>sid)) then
    raise exception 'Admission number already exists';
  end if;
  if rollno is not null and exists(select 1 from public.enrollments e where e.academic_year_id=yearid and e.class_id=classid and e.roll_number=rollno and e.deleted_at is null and (sid is null or e.student_id<>sid)) then
    raise exception 'Roll number is already assigned in the selected class';
  end if;
  if guardian_auth_id is not null and not exists(select 1 from public.profiles p where p.id=guardian_auth_id and p.active and public.current_app_role_for(p.role)='parent_guardian') then
    raise exception 'Selected portal account is not an active parent or guardian account';
  end if;

  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Student record update'),true);
  if sid is null then
    insert into public.students(admission_no,first_name,middle_name,last_name,gender,date_of_birth,guardian_name,guardian_phone,guardian_email,photo_url,status,updated_at)
    values(btrim(student_data->>'admission_no'),btrim(student_data->>'first_name'),btrim(coalesce(student_data->>'middle_name','')),btrim(student_data->>'last_name'),
      gender_value,birthdate,btrim(coalesce(guardian_data->>'full_name','')),btrim(coalesce(guardian_data->>'phone','')),
      btrim(coalesce(guardian_data->>'email','')),coalesce(student_data->>'photo_url',''),status_value::public.student_status,now()) returning id into sid;
  else
    update public.students set admission_no=btrim(student_data->>'admission_no'),first_name=btrim(student_data->>'first_name'),
      middle_name=btrim(coalesce(student_data->>'middle_name','')),last_name=btrim(student_data->>'last_name'),gender=gender_value,
      date_of_birth=birthdate,guardian_name=btrim(coalesce(guardian_data->>'full_name',guardian_name)),
      guardian_phone=btrim(coalesce(guardian_data->>'phone',guardian_phone)),guardian_email=btrim(coalesce(guardian_data->>'email',guardian_email)),
      photo_url=coalesce(student_data->>'photo_url',photo_url),status=status_value::public.student_status,updated_at=now()
    where id=sid and deleted_at is null;
    get diagnostics affected=row_count; if affected<>1 then raise exception 'Student record was not updated'; end if;
  end if;

  if classid is not null then
    insert into public.enrollments(student_id,academic_year_id,class_id,roll_number,active,deleted_at,updated_at)
    values(sid,yearid,classid,rollno,requested_active,null,now())
    on conflict(student_id,academic_year_id) do update set class_id=excluded.class_id,roll_number=excluded.roll_number,
      active=excluded.active,deleted_at=null,updated_at=now() returning id into eid;
    if requested_active then update public.enrollments set active=(id=eid),updated_at=now() where student_id=sid and deleted_at is null; end if;
  end if;

  if btrim(coalesce(guardian_data->>'full_name',''))<>'' then
    gid:=public.safe_uuid(guardian_data->>'id');
    if btrim(coalesce(guardian_data->>'id',''))<>'' and gid is null then raise exception 'Guardian record identifier is invalid'; end if;
    if gid is null then
      insert into public.student_guardians(full_name,relationship,phone,email,address,is_primary,updated_at)
      values(btrim(guardian_data->>'full_name'),coalesce(nullif(btrim(guardian_data->>'relationship'),''),'Guardian'),
        btrim(coalesce(guardian_data->>'phone','')),nullif(btrim(coalesce(guardian_data->>'email','')),'')::citext,
        btrim(coalesce(guardian_data->>'address','')),public.safe_boolean(guardian_data->>'is_primary',true),now()) returning id into gid;
    else
      if not exists(select 1 from public.guardian_links gl where gl.guardian_id=gid and gl.student_id=sid) then raise exception 'Guardian record does not belong to this student'; end if;
      update public.student_guardians set full_name=btrim(guardian_data->>'full_name'),relationship=coalesce(nullif(btrim(guardian_data->>'relationship'),''),'Guardian'),
        phone=btrim(coalesce(guardian_data->>'phone','')),email=nullif(btrim(coalesce(guardian_data->>'email','')),'')::citext,
        address=btrim(coalesce(guardian_data->>'address','')),is_primary=public.safe_boolean(guardian_data->>'is_primary',false),updated_at=now() where id=gid;
    end if;
    insert into public.guardian_links(guardian_id,student_id,auth_user_id,can_view_reports,can_receive_notifications)
    values(gid,sid,guardian_auth_id,public.safe_boolean(guardian_data->>'can_view_reports',true),public.safe_boolean(guardian_data->>'can_receive_notifications',true))
    on conflict(guardian_id,student_id) do update set auth_user_id=excluded.auth_user_id,can_view_reports=excluded.can_view_reports,
      can_receive_notifications=excluded.can_receive_notifications;
  end if;
  return public.get_student_record_v5(sid);
exception when unique_violation then
  raise exception 'A student, enrolment, roll number, or guardian link already uses these details';
end $$;

create or replace function public.set_student_photo(target_student_id uuid,target_photo_url text,expected_updated_at timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare current_updated timestamptz; affected integer;
begin
  if auth.uid() is null or not public.can_manage_student(target_student_id) then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(target_photo_url,''))='' or target_photo_url not like target_student_id::text||'/%' then raise exception 'Student photograph path is invalid'; end if;
  select updated_at into current_updated from public.students where id=target_student_id and deleted_at is null for update;
  if not found then raise exception 'Student record not found'; end if;
  if expected_updated_at is not null and current_updated is distinct from expected_updated_at then raise exception 'Student record changed by another user' using errcode='40001'; end if;
  perform set_config('app.change_reason','Student photograph updated',true);
  update public.students set photo_url=target_photo_url,updated_at=now() where id=target_student_id and deleted_at is null;
  get diagnostics affected=row_count; if affected<>1 then raise exception 'Student photograph was not saved'; end if;
  return public.get_student_record_v5(target_student_id);
end $$;

-- Atomic teacher record persistence with safe parsing and linked-account validation.
create or replace function public.save_teacher(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  tid uuid:=public.safe_uuid(payload->>'id'); profileid uuid:=public.safe_uuid(payload->>'profile_id');
  staff text:=btrim(coalesce(payload->>'staff_no','')); current_updated timestamptz;
  expected_updated timestamptz:=public.safe_timestamptz(payload->>'updated_at'); joined date:=public.safe_date(payload->>'date_joined');
  employment text:=coalesce(nullif(btrim(payload->>'employment_status'),''),'active');
  gender_value text:=coalesce(nullif(btrim(payload->>'gender'),''),'Other'); linked_role text; affected integer;
begin
  if auth.uid() is null or not public.can_manage_teachers() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(payload->>'id',''))<>'' and tid is null then raise exception 'Teacher record identifier is invalid'; end if;
  if btrim(coalesce(payload->>'profile_id',''))<>'' and profileid is null then raise exception 'Linked user account is invalid'; end if;
  if btrim(coalesce(payload->>'date_joined',''))<>'' and joined is null then raise exception 'Date joined is invalid'; end if;
  if staff='' or btrim(coalesce(payload->>'first_name',''))='' or btrim(coalesce(payload->>'last_name',''))='' then raise exception 'Staff number, first name, and last name are required'; end if;
  if gender_value not in ('Male','Female','Other') then raise exception 'Gender selection is invalid'; end if;
  if btrim(coalesce(payload->>'email',''))<>'' and payload->>'email' !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Teacher email address is invalid'; end if;
  if employment not in ('active','leave','suspended','resigned','retired') then raise exception 'Employment status is invalid'; end if;
  if joined>current_date then raise exception 'Date joined cannot be in the future'; end if;
  if tid is not null then
    select updated_at into current_updated from public.teachers where id=tid and deleted_at is null for update;
    if not found then raise exception 'Teacher record not found'; end if;
    if expected_updated is not null and current_updated is distinct from expected_updated then raise exception 'Teacher record changed by another user' using errcode='40001'; end if;
  end if;
  if exists(select 1 from public.teachers t where lower(t.staff_no::text)=lower(staff) and (tid is null or t.id<>tid)) then raise exception 'Staff number already exists'; end if;
  if profileid is not null then
    select public.current_app_role_for(p.role) into linked_role from public.profiles p where p.id=profileid and p.active;
    if linked_role is null then raise exception 'Selected user account is unavailable'; end if;
    if linked_role not in ('principal','academic_admin','class_teacher','subject_teacher') then raise exception 'Selected user account does not have a teaching role'; end if;
    if exists(select 1 from public.teachers t where t.profile_id=profileid and t.deleted_at is null and (tid is null or t.id<>tid)) then raise exception 'This user account is already linked to another teacher'; end if;
  end if;
  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Teacher record update'),true);
  if tid is null then
    insert into public.teachers(profile_id,staff_no,first_name,middle_name,last_name,gender,phone,email,address,qualification,specialization,date_joined,employment_status,notes,active,created_by,updated_at)
    values(profileid,staff,btrim(payload->>'first_name'),btrim(coalesce(payload->>'middle_name','')),btrim(payload->>'last_name'),gender_value,
      btrim(coalesce(payload->>'phone','')),nullif(btrim(coalesce(payload->>'email','')),'')::citext,btrim(coalesce(payload->>'address','')),
      btrim(coalesce(payload->>'qualification','')),btrim(coalesce(payload->>'specialization','')),joined,employment,btrim(coalesce(payload->>'notes','')),
      public.safe_boolean(payload->>'active',true),auth.uid(),now()) returning id into tid;
  else
    update public.teachers set profile_id=profileid,staff_no=staff,first_name=btrim(payload->>'first_name'),middle_name=btrim(coalesce(payload->>'middle_name','')),
      last_name=btrim(payload->>'last_name'),gender=gender_value,phone=btrim(coalesce(payload->>'phone','')),
      email=nullif(btrim(coalesce(payload->>'email','')),'')::citext,address=btrim(coalesce(payload->>'address','')),
      qualification=btrim(coalesce(payload->>'qualification','')),specialization=btrim(coalesce(payload->>'specialization','')),
      date_joined=joined,employment_status=employment,notes=btrim(coalesce(payload->>'notes','')),active=public.safe_boolean(payload->>'active',true),updated_at=now()
    where id=tid and deleted_at is null;
    get diagnostics affected=row_count; if affected<>1 then raise exception 'Teacher record was not updated'; end if;
  end if;
  return public.get_teacher_record(tid);
exception when unique_violation then raise exception 'Staff number or linked user account is already in use';
end $$;

-- Transactional academic configuration writes.
create or replace function public.save_academic_entity(entity_type text,payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare targetid uuid:=public.safe_uuid(payload->>'id'); affected integer; startdate date:=public.safe_date(payload->>'start_date'); enddate date:=public.safe_date(payload->>'end_date');
declare nextdate date:=public.safe_date(payload->>'next_term_begins'); yearid uuid:=public.safe_uuid(payload->>'academic_year_id'); teacherid uuid:=public.safe_uuid(payload->>'class_teacher_id'); seq integer:=public.safe_integer(payload->>'sequence'); orderno integer;
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
    if btrim(coalesce(payload->>'name',''))='' then raise exception 'Academic year name is required'; end if;
    if targetid is null then insert into public.academic_years(name,start_date,end_date) values(btrim(payload->>'name'),startdate,enddate) returning id into targetid;
    else update public.academic_years set name=btrim(payload->>'name'),start_date=startdate,end_date=enddate,updated_at=now() where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='terms' then
    if yearid is null or not exists(select 1 from public.academic_years y where y.id=yearid and y.deleted_at is null) then raise exception 'Academic year is invalid'; end if;
    if btrim(coalesce(payload->>'name',''))='' then raise exception 'Term name is required'; end if;
    if seq is null or seq not between 1 and 6 then raise exception 'Term sequence must be between 1 and 6'; end if;
    if targetid is null then insert into public.terms(academic_year_id,name,sequence,start_date,end_date,next_term_begins) values(yearid,btrim(payload->>'name'),seq,startdate,enddate,nextdate) returning id into targetid;
    else update public.terms set academic_year_id=yearid,name=btrim(payload->>'name'),sequence=seq,start_date=startdate,end_date=enddate,next_term_begins=nextdate,updated_at=now() where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='classes' then
    if btrim(coalesce(payload->>'name',''))='' then raise exception 'Class name is required'; end if;
    orderno:=coalesce(public.safe_integer(payload->>'level_order'),0);
    if teacherid is not null and not exists(select 1 from public.profiles p where p.id=teacherid and p.active and public.current_app_role_for(p.role) in ('principal','academic_admin','class_teacher')) then raise exception 'Selected class teacher account is invalid'; end if;
    if targetid is null then insert into public.classes(name,level_order,class_teacher_id,active) values(btrim(payload->>'name'),orderno,teacherid,public.safe_boolean(payload->>'active',true)) returning id into targetid;
    else update public.classes set name=btrim(payload->>'name'),level_order=orderno,class_teacher_id=teacherid,active=public.safe_boolean(payload->>'active',true),updated_at=now() where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='subjects' then
    if btrim(coalesce(payload->>'code',''))='' or btrim(coalesce(payload->>'name',''))='' then raise exception 'Subject code and name are required'; end if;
    orderno:=coalesce(public.safe_integer(payload->>'display_order'),0);
    if targetid is null then insert into public.subjects(code,name,display_order,active) values(upper(btrim(payload->>'code')),btrim(payload->>'name'),orderno,public.safe_boolean(payload->>'active',true)) returning id into targetid;
    else update public.subjects set code=upper(btrim(payload->>'code')),name=btrim(payload->>'name'),display_order=orderno,active=public.safe_boolean(payload->>'active',true),updated_at=now() where id=targetid and deleted_at is null;
    end if;
  else raise exception 'Unsupported academic record type'; end if;
  get diagnostics affected=row_count; if targetid is null or affected=0 then raise exception 'Academic record was not saved'; end if;
  return public.get_academic_configuration();
exception when unique_violation then raise exception 'An academic record already uses this name, code, sequence, or date scope';
end $$;

create or replace function public.save_class_subject_assignment(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare targetid uuid:=public.safe_uuid(payload->>'id'); classid uuid:=public.safe_uuid(payload->>'class_id'); subjectid uuid:=public.safe_uuid(payload->>'subject_id'); teacherid uuid:=public.safe_uuid(payload->>'teacher_id');
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(payload->>'id',''))<>'' and targetid is null then raise exception 'Subject assignment identifier is invalid'; end if;
  if btrim(coalesce(payload->>'class_id',''))<>'' and classid is null then raise exception 'Class identifier is invalid'; end if;
  if btrim(coalesce(payload->>'subject_id',''))<>'' and subjectid is null then raise exception 'Subject identifier is invalid'; end if;
  if btrim(coalesce(payload->>'teacher_id',''))<>'' and teacherid is null then raise exception 'Teacher identifier is invalid'; end if;
  if classid is null or not exists(select 1 from public.classes where id=classid and deleted_at is null and active) then raise exception 'Selected class is invalid or inactive'; end if;
  if subjectid is null or not exists(select 1 from public.subjects where id=subjectid and deleted_at is null and active) then raise exception 'Selected subject is invalid or inactive'; end if;
  if teacherid is not null and not exists(select 1 from public.profiles p where p.id=teacherid and p.active and public.current_app_role_for(p.role) in ('principal','academic_admin','class_teacher','subject_teacher')) then raise exception 'Selected teacher account is invalid'; end if;
  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Class subject assignment update'),true);
  if targetid is null then
    insert into public.class_subjects(class_id,subject_id,teacher_id,active,updated_at) values(classid,subjectid,teacherid,public.safe_boolean(payload->>'active',true),now())
    on conflict(class_id,subject_id) do update set teacher_id=excluded.teacher_id,active=excluded.active,updated_at=now() returning id into targetid;
  else
    update public.class_subjects set class_id=classid,subject_id=subjectid,teacher_id=teacherid,active=public.safe_boolean(payload->>'active',true),updated_at=now() where id=targetid;
    if not found then raise exception 'Subject assignment not found'; end if;
  end if;
  return public.get_academic_configuration();
exception when unique_violation then raise exception 'This subject is already assigned to the selected class';
end $$;

create or replace function public.save_grading_scale(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare targetid uuid:=public.safe_uuid(payload->>'id'); yearid uuid:=public.safe_uuid(payload->>'academic_year_id'); classid uuid:=public.safe_uuid(payload->>'class_id'); subjectid uuid:=public.safe_uuid(payload->>'subject_id');
declare minmark numeric:=public.safe_numeric(payload->>'min_mark'); maxmark numeric:=public.safe_numeric(payload->>'max_mark'); pointvalue numeric:=coalesce(public.safe_numeric(payload->>'grade_point'),0); orderno integer:=coalesce(public.safe_integer(payload->>'display_order'),0);
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(payload->>'id',''))<>'' and targetid is null then raise exception 'Grading scale identifier is invalid'; end if;
  if btrim(coalesce(payload->>'academic_year_id',''))<>'' and yearid is null then raise exception 'Academic year identifier is invalid'; end if;
  if btrim(coalesce(payload->>'class_id',''))<>'' and classid is null then raise exception 'Class identifier is invalid'; end if;
  if btrim(coalesce(payload->>'subject_id',''))<>'' and subjectid is null then raise exception 'Subject identifier is invalid'; end if;
  if btrim(coalesce(payload->>'grade',''))='' or btrim(coalesce(payload->>'remark',''))='' then raise exception 'Grade and remark are required'; end if;
  if minmark is null or maxmark is null or minmark<0 or maxmark>100 or minmark>maxmark then raise exception 'Grade range is invalid'; end if;
  if yearid is not null and not exists(select 1 from public.academic_years where id=yearid and deleted_at is null) then raise exception 'Academic year is invalid'; end if;
  if classid is not null and not exists(select 1 from public.classes where id=classid and deleted_at is null) then raise exception 'Class is invalid'; end if;
  if subjectid is not null and not exists(select 1 from public.subjects where id=subjectid and deleted_at is null) then raise exception 'Subject is invalid'; end if;
  if exists(select 1 from public.grading_scales g where g.deleted_at is null and (targetid is null or g.id<>targetid)
    and g.academic_year_id is not distinct from yearid and g.class_id is not distinct from classid and g.subject_id is not distinct from subjectid
    and numrange(g.min_mark,g.max_mark,'[]') && numrange(minmark,maxmark,'[]')) then raise exception 'Grade ranges cannot overlap within the same scope'; end if;
  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Grading scale update'),true);
  if targetid is null then
    insert into public.grading_scales(academic_year_id,class_id,subject_id,min_mark,max_mark,grade,remark,grade_point,display_order,deleted_at,updated_at)
    values(yearid,classid,subjectid,minmark,maxmark,upper(btrim(payload->>'grade')),btrim(payload->>'remark'),pointvalue,orderno,null,now()) returning id into targetid;
  else
    update public.grading_scales set academic_year_id=yearid,class_id=classid,subject_id=subjectid,min_mark=minmark,max_mark=maxmark,
      grade=upper(btrim(payload->>'grade')),remark=btrim(payload->>'remark'),grade_point=pointvalue,display_order=orderno,deleted_at=null,updated_at=now() where id=targetid;
    if not found then raise exception 'Grading scale not found'; end if;
  end if;
  return public.get_academic_configuration();
exception when unique_violation then raise exception 'This grading scope already contains the selected grade';
end $$;

create or replace function public.archive_grading_scale(target_grade_id uuid,reason_text text default 'Grading scale removed')
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Grading scale removed'),true);
  update public.grading_scales set deleted_at=now(),updated_at=now() where id=target_grade_id and deleted_at is null;
  if not found then raise exception 'Grading scale not found'; end if;
  return true;
end $$;

-- Granular report permissions for class and subject teachers.
create or replace function public.can_manage_class_report_fields(target_class_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.is_academic_manager() or exists(select 1 from public.classes c where c.id=target_class_id and c.deleted_at is null and c.class_teacher_id=auth.uid())
    or exists(select 1 from public.user_class_access a where a.user_id=auth.uid() and a.class_id=target_class_id and a.subject_id is null and a.access_level in ('edit','review'))
$$;

create or replace function public.can_score_class_subject(target_class_id uuid,target_subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.is_academic_manager() or public.can_manage_class_report_fields(target_class_id)
    or exists(select 1 from public.class_subjects cs where cs.class_id=target_class_id and cs.subject_id=target_subject_id and cs.active and cs.teacher_id=auth.uid())
    or exists(select 1 from public.user_class_access a where a.user_id=auth.uid() and a.class_id=target_class_id and (a.subject_id is null or a.subject_id=target_subject_id) and a.access_level in ('score','edit','review'))
$$;

create or replace function public.can_create_report_for_class(target_class_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.can_manage_class_report_fields(target_class_id) or exists(
    select 1 from public.class_subjects cs where cs.class_id=target_class_id and cs.active and public.can_score_class_subject(target_class_id,cs.subject_id)
  )
$$;

create or replace function public.can_score_subject(target_report_id uuid,target_subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(select 1 from public.student_reports r where r.id=target_report_id and r.deleted_at is null and r.status in ('draft','returned'))
    and public.can_score_class_subject(public.report_class_id(target_report_id),target_subject_id)
$$;

create or replace function public.can_edit_report(target_report_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(select 1 from public.student_reports r where r.id=target_report_id and r.deleted_at is null and r.status in ('draft','returned'))
    and (public.can_manage_class_report_fields(public.report_class_id(target_report_id)) or exists(
      select 1 from public.class_subjects cs where cs.class_id=public.report_class_id(target_report_id) and cs.active and public.can_score_class_subject(cs.class_id,cs.subject_id)
    ))
$$;

create or replace function public.allowed_report_transitions(target_report_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path=public
as $$
declare current_status public.report_status; classid uuid; result text[]:='{}'::text[];
begin
  select r.status,e.class_id into current_status,classid from public.student_reports r join public.enrollments e on e.id=r.enrollment_id where r.id=target_report_id and r.deleted_at is null;
  if current_status is null then return result; end if;
  if current_status in ('draft','returned') and public.can_manage_class_report_fields(classid) then result:=array_append(result,'submitted'); end if;
  if current_status='submitted' and (public.is_academic_manager() or public.can_manage_class_report_fields(classid)) then result:=array_append(result,'class_reviewed'); end if;
  if current_status in ('submitted','class_reviewed','approved') and public.has_role(array['system_admin','principal','academic_admin']) then result:=array_append(result,'returned'); end if;
  if current_status='class_reviewed' and public.has_role(array['system_admin','principal']) then result:=array_append(result,'approved'); end if;
  if current_status='approved' and public.has_role(array['system_admin','principal']) then result:=array_append(result,'published'); end if;
  if current_status='published' and public.has_role(array['system_admin','principal']) then result:=array_append(result,'withdrawn'); end if;
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
  canfields:=public.can_manage_class_report_fields(classid) and coalesce(report_json->>'status','draft') in ('draft','returned');
  return jsonb_build_object('report',report_json,'student',student_json,'can_edit',canedit,'can_edit_fields',canfields,
    'allowed_transitions',case when rid is null then '[]'::jsonb else to_jsonb(public.allowed_report_transitions(rid)) end,
    'subjects',coalesce((select jsonb_agg(to_jsonb(q) order by q.display_order,q.subject_name) from (
      select sb.id subject_id,sb.code subject_code,sb.name subject_name,sb.display_order,public.can_score_class_subject(classid,sb.id) and coalesce(report_json->>'status','draft') in ('draft','returned') can_score,
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
    if current_status not in ('draft','returned') then raise exception 'This report is locked by the approval workflow'; end if;
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

create or replace function public.transition_report_status(target_report_id uuid,target_status public.report_status,comment_text text default '',expected_version integer default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare current_status public.report_status; current_version integer; ts timestamptz:=now(); revisionid uuid; allowed text[];
begin
  select status,version into current_status,current_version from public.student_reports where id=target_report_id and deleted_at is null for update;
  if current_status is null then raise exception 'Report not found'; end if;
  if expected_version is not null and expected_version<>current_version then raise exception 'This report was changed by another user. Refresh before continuing.' using errcode='40001'; end if;
  allowed:=public.allowed_report_transitions(target_report_id);
  if not target_status::text=any(allowed) then raise exception 'This workflow transition is not permitted' using errcode='42501'; end if;
  if target_status in ('approved','published','withdrawn') then perform public.require_sensitive_access(); end if;
  if target_status in ('submitted','class_reviewed','approved','published') and (
    exists(select 1 from public.class_subjects cs join public.enrollments e on e.class_id=cs.class_id join public.student_reports r on r.enrollment_id=e.id
      left join public.subject_results sr on sr.report_id=r.id and sr.subject_id=cs.subject_id where r.id=target_report_id and cs.active and sr.id is null)
    or exists(select 1 from public.subject_results sr join public.assessment_components ac on ac.scheme_id=sr.scheme_id and ac.required
      left join public.assessment_score_entries se on se.subject_result_id=sr.id and se.component_id=ac.id
      where sr.report_id=target_report_id and se.id is null)
  ) then raise exception 'All assigned subjects and required assessment scores must be complete before this transition'; end if;
  perform set_config('app.report_write','on',true); perform set_config('app.change_reason',coalesce(nullif(comment_text,''),'Report workflow transition'),true);
  update public.student_reports set status=target_status,version=version+1,
    submitted_at=case when target_status='submitted' then ts else submitted_at end,submitted_by=case when target_status='submitted' then auth.uid() else submitted_by end,
    reviewed_at=case when target_status='class_reviewed' then ts else reviewed_at end,reviewed_by=case when target_status='class_reviewed' then auth.uid() else reviewed_by end,
    approved_at=case when target_status='approved' then ts else approved_at end,approved_by=case when target_status='approved' then auth.uid() else approved_by end,
    published_at=case when target_status='published' then ts else published_at end,published_by=case when target_status='published' then auth.uid() else published_by end,
    withdrawn_at=case when target_status='withdrawn' then ts else withdrawn_at end,updated_at=ts where id=target_report_id returning version into current_version;
  insert into public.report_workflow_events(report_id,from_status,to_status,comment,actor_id) values(target_report_id,current_status,target_status,coalesce(comment_text,''),auth.uid());
  insert into public.report_revisions(report_id,version,snapshot,reason,actor_id) values(target_report_id,current_version,public.build_report_snapshot(target_report_id),coalesce(nullif(comment_text,''),replace(target_status::text,'_',' ')),auth.uid())
    on conflict(report_id,version) do update set snapshot=excluded.snapshot,reason=excluded.reason,actor_id=excluded.actor_id,created_at=now() returning id into revisionid;
  if target_status='published' then insert into public.report_publications(report_id,revision_id,published_by) values(target_report_id,revisionid,auth.uid())
    on conflict(report_id) where revoked_at is null do update set revision_id=excluded.revision_id,published_by=excluded.published_by,published_at=now();
  elsif target_status='withdrawn' then update public.report_publications set revoked_at=ts,revoked_by=auth.uid() where report_id=target_report_id and revoked_at is null; end if;
  perform public.create_workflow_notifications(target_report_id,target_status);
  return public.get_report_editor(target_report_id,null,null);
end $$;

-- Role-specific operational workspaces.
create or replace function public.get_role_workspace()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare termid uuid; v_current_role text:=public.current_app_role();
begin
  if v_current_role not in ('class_teacher','subject_teacher','system_admin','principal','academic_admin') then return jsonb_build_object('classes','[]'::jsonb,'subjects','[]'::jsonb); end if;
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
language plpgsql
security definer
set search_path=public,auth
as $$
begin
  if not public.is_system_admin() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  return jsonb_build_object(
    'profiles',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'full_name',p.full_name,'email',au.email,'role',public.current_app_role_for(p.role),
      'active',p.active,'mfa_required',p.mfa_required,'phone',p.phone,'last_seen_at',p.last_seen_at,'account_created_at',au.created_at,
      'email_confirmed_at',au.email_confirmed_at,'last_sign_in_at',au.last_sign_in_at,'teacher_id',t.id,'staff_no',t.staff_no,
      'access',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'class_id',a.class_id,'class_name',c.name,'subject_id',a.subject_id,'subject_name',s.name,'access_level',a.access_level) order by c.name,s.name nulls first)
        from public.user_class_access a join public.classes c on c.id=a.class_id left join public.subjects s on s.id=a.subject_id where a.user_id=p.id),'[]'::jsonb)) order by p.full_name)
      from public.profiles p left join auth.users au on au.id=p.id left join public.teachers t on t.profile_id=p.id and t.deleted_at is null),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(s) order by s.display_order,s.name) from public.subjects s where s.deleted_at is null),'[]'::jsonb),
    'class_subjects',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'class_id',cs.class_id,'subject_id',cs.subject_id,'active',cs.active)) from public.class_subjects cs),'[]'::jsonb)
  );
end $$;

create or replace function public.validate_operational_readiness()
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  rls_state jsonb; function_state jsonb; duplicate_state jsonb; privilege_state jsonb;
  role_state jsonb; integrity_state jsonb; ready_value boolean;
begin
  if not public.has_role(array['system_admin','principal','academic_admin']) then raise exception 'Access denied' using errcode='42501'; end if;
  select jsonb_object_agg(tablename,rowsecurity) into rls_state from pg_tables where schemaname='public' and tablename in
    ('profiles','teachers','students','student_guardians','guardian_links','enrollments','academic_years','terms','classes','subjects','class_subjects','user_class_access','grading_scales','assessment_schemes','assessment_components','student_reports','subject_results','assessment_score_entries');
  function_state:=jsonb_build_object(
    'save_student',to_regprocedure('public.save_student(jsonb)') is not null,
    'set_student_photo',to_regprocedure('public.set_student_photo(uuid,text,timestamptz)') is not null,
    'save_teacher',to_regprocedure('public.save_teacher(jsonb)') is not null,
    'admin_validate_user_bundle',to_regprocedure('public.admin_validate_user_bundle(uuid,jsonb,boolean)') is not null,
    'admin_apply_user_bundle',to_regprocedure('public.admin_apply_user_bundle(uuid,jsonb)') is not null,
    'save_academic_entity',to_regprocedure('public.save_academic_entity(text,jsonb)') is not null,
    'save_class_subject_assignment',to_regprocedure('public.save_class_subject_assignment(jsonb)') is not null,
    'save_grading_scale',to_regprocedure('public.save_grading_scale(jsonb)') is not null,
    'save_assessment_scheme',to_regprocedure('public.save_assessment_scheme(jsonb)') is not null,
    'save_report_card',to_regprocedure('public.save_report_card(jsonb,integer)') is not null,
    'get_role_dashboard',to_regprocedure('public.get_role_dashboard(uuid)') is not null,
    'get_role_workspace',to_regprocedure('public.get_role_workspace()') is not null
  );
  duplicate_state:=jsonb_build_object(
    'admission_numbers',(select count(*) from (select lower(admission_no::text) from public.students group by lower(admission_no::text) having count(*)>1) q),
    'staff_numbers',(select count(*) from (select lower(staff_no::text) from public.teachers group by lower(staff_no::text) having count(*)>1) q),
    'access_scopes',(select count(*) from (select user_id,class_id,coalesce(subject_id,'00000000-0000-0000-0000-000000000000'::uuid) from public.user_class_access group by 1,2,3 having count(*)>1) q),
    'grading_overlaps',(select count(*) from public.grading_scales a join public.grading_scales b on a.id<b.id and a.deleted_at is null and b.deleted_at is null
      and a.academic_year_id is not distinct from b.academic_year_id and a.class_id is not distinct from b.class_id and a.subject_id is not distinct from b.subject_id
      and numrange(a.min_mark,a.max_mark,'[]') && numrange(b.min_mark,b.max_mark,'[]'))
  );
  integrity_state:=jsonb_build_object(
    'assessment_scheme_weights',(select count(*) from (
      select s.id from public.assessment_schemes s left join public.assessment_components c on c.scheme_id=s.id
      where s.deleted_at is null and s.active group by s.id having count(c.id)=0 or abs(coalesce(sum(c.weight),0)-100)>0.01
    ) q),
    'active_enrollment_conflicts',(select count(*) from (
      select e.student_id from public.enrollments e where e.active and e.deleted_at is null group by e.student_id having count(*)>1
    ) q),
    'invalid_teacher_links',(select count(*) from public.teachers t left join public.profiles p on p.id=t.profile_id
      where t.deleted_at is null and t.profile_id is not null and (p.id is null or not p.active or public.current_app_role_for(p.role) not in ('principal','academic_admin','class_teacher','subject_teacher'))),
    'invalid_class_teacher_links',(select count(*) from public.classes c left join public.profiles p on p.id=c.class_teacher_id
      where c.deleted_at is null and c.class_teacher_id is not null and (p.id is null or not p.active or public.current_app_role_for(p.role) not in ('principal','academic_admin','class_teacher'))),
    'invalid_subject_teacher_links',(select count(*) from public.class_subjects cs left join public.profiles p on p.id=cs.teacher_id
      where cs.active and cs.teacher_id is not null and (p.id is null or not p.active or public.current_app_role_for(p.role) not in ('principal','academic_admin','class_teacher','subject_teacher'))),
    'invalid_guardian_portal_links',(select count(*) from public.guardian_links gl left join public.profiles p on p.id=gl.auth_user_id
      where gl.auth_user_id is not null and (p.id is null or not p.active or public.current_app_role_for(p.role)<>'parent_guardian')),
    'missing_auth_profiles',(select count(*) from auth.users u left join public.profiles p on p.id=u.id where p.id is null),
    'active_period_errors',(
      (select greatest(count(*)-1,0) from public.academic_years where is_active and deleted_at is null)
      +(select greatest(count(*)-1,0) from public.terms where is_active and deleted_at is null)
      +(select count(*) from public.terms t left join public.academic_years y on y.id=t.academic_year_id where t.is_active and t.deleted_at is null and (y.id is null or not y.is_active or y.deleted_at is not null))
    ),
    'subject_total_mismatches',(select count(*) from public.subject_results sr where abs(sr.total_score-coalesce((select sum(se.weighted_score) from public.assessment_score_entries se where se.subject_result_id=sr.id),0))>0.01)
  );
  privilege_state:=jsonb_build_object(
    'student_rpc',has_function_privilege('authenticated','public.save_student(jsonb)','EXECUTE'),
    'teacher_rpc',has_function_privilege('authenticated','public.save_teacher(jsonb)','EXECUTE'),
    'academic_rpc',has_function_privilege('authenticated','public.save_academic_entity(text,jsonb)','EXECUTE'),
    'assessment_rpc',has_function_privilege('authenticated','public.save_assessment_scheme(jsonb)','EXECUTE'),
    'report_rpc',has_function_privilege('authenticated','public.save_report_card(jsonb,integer)','EXECUTE'),
    'student_direct_write_blocked',not has_table_privilege('authenticated','public.students','INSERT') and not has_table_privilege('authenticated','public.students','UPDATE') and not has_table_privilege('authenticated','public.students','DELETE'),
    'teacher_direct_write_blocked',not has_table_privilege('authenticated','public.teachers','INSERT') and not has_table_privilege('authenticated','public.teachers','UPDATE') and not has_table_privilege('authenticated','public.teachers','DELETE'),
    'profile_direct_write_blocked',not has_table_privilege('authenticated','public.profiles','INSERT') and not has_table_privilege('authenticated','public.profiles','UPDATE') and not has_table_privilege('authenticated','public.profiles','DELETE')
  );
  role_state:=jsonb_build_object(
    'system_admin',true,'principal',true,'academic_admin',true,'class_teacher',true,
    'subject_teacher',true,'records_officer',true,'viewer',true,'parent_guardian',true
  );
  ready_value:=not exists(select 1 from jsonb_each_text(function_state) x where x.value<>'true')
    and not exists(select 1 from jsonb_each_text(coalesce(rls_state,'{}'::jsonb)) x where x.value<>'true')
    and not exists(select 1 from jsonb_each_text(privilege_state) x where x.value<>'true')
    and not exists(select 1 from jsonb_each_text(duplicate_state) x where x.value::numeric<>0)
    and not exists(select 1 from jsonb_each_text(integrity_state) x where x.value::numeric<>0);
  return jsonb_build_object('ready',ready_value,'functions',function_state,'rls',coalesce(rls_state,'{}'::jsonb),'privileges',privilege_state,
    'roles',role_state,'duplicates',duplicate_state,'integrity',integrity_state,'checked_at',now());
end $$;

-- Force browser writes through validated security-definer RPCs.
revoke insert,update,delete on public.profiles,public.user_class_access,public.teachers,public.students,public.student_guardians,public.guardian_links,public.enrollments from authenticated;
revoke insert,update,delete on public.academic_years,public.terms,public.classes,public.subjects,public.class_subjects,public.grading_scales from authenticated;
revoke insert,update,delete on public.student_reports,public.subject_results,public.assessment_score_entries from authenticated;

revoke all on function public.safe_date(text) from public,anon;
revoke all on function public.safe_timestamptz(text) from public,anon;
revoke all on function public.safe_integer(text) from public,anon;
revoke all on function public.safe_numeric(text) from public,anon;
revoke all on function public.safe_boolean(text,boolean) from public,anon;
revoke all on function public.admin_validate_user_bundle(uuid,jsonb,boolean) from public,anon,authenticated;
revoke all on function public.admin_apply_user_bundle(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.set_student_photo(uuid,text,timestamptz) from public,anon;
revoke all on function public.save_academic_entity(text,jsonb) from public,anon;
revoke all on function public.save_class_subject_assignment(jsonb) from public,anon;
revoke all on function public.save_grading_scale(jsonb) from public,anon;
revoke all on function public.archive_grading_scale(uuid,text) from public,anon;
revoke all on function public.can_manage_class_report_fields(uuid) from public,anon;
revoke all on function public.can_score_class_subject(uuid,uuid) from public,anon;
revoke all on function public.can_create_report_for_class(uuid) from public,anon;
revoke all on function public.allowed_report_transitions(uuid) from public,anon;
revoke all on function public.get_role_workspace() from public,anon;
revoke all on function public.validate_operational_readiness() from public,anon;

grant execute on function public.admin_validate_user_bundle(uuid,jsonb,boolean) to service_role;
grant execute on function public.admin_apply_user_bundle(uuid,jsonb) to service_role;
grant execute on function public.set_student_photo(uuid,text,timestamptz) to authenticated;
grant execute on function public.save_academic_entity(text,jsonb) to authenticated;
grant execute on function public.save_class_subject_assignment(jsonb) to authenticated;
grant execute on function public.save_grading_scale(jsonb) to authenticated;
grant execute on function public.archive_grading_scale(uuid,text) to authenticated;
grant execute on function public.can_manage_class_report_fields(uuid) to authenticated;
grant execute on function public.can_score_class_subject(uuid,uuid) to authenticated;
grant execute on function public.can_create_report_for_class(uuid) to authenticated;
grant execute on function public.allowed_report_transitions(uuid) to authenticated;
grant execute on function public.get_role_workspace() to authenticated;
grant execute on function public.validate_operational_readiness() to authenticated;

-- ---------------------------------------------------------------------------
-- v6.6.1 REPORT RE-CREATION AND ACTIVE-ROW UNIQUENESS REPAIR
-- ---------------------------------------------------------------------------

alter table public.student_reports drop constraint if exists student_reports_enrollment_id_key;
alter table public.student_reports drop constraint if exists student_reports_enrollment_id_term_id_key;

do $$
declare constraint_row record;
begin
  for constraint_row in
    select c.conname
    from pg_constraint c
    where c.conrelid='public.student_reports'::regclass
      and c.contype='u'
      and (
        select array_agg(a.attname::text order by k.ordinality)
        from unnest(c.conkey) with ordinality as k(attnum,ordinality)
        join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum
      ) in (array['enrollment_id'],array['enrollment_id','term_id'])
  loop
    execute format('alter table public.student_reports drop constraint if exists %I',constraint_row.conname);
  end loop;
end $$;

drop index if exists public.student_reports_enrollment_id_key;
drop index if exists public.student_reports_enrollment_id_term_id_key;
create unique index if not exists student_reports_active_enrollment_term_uidx
  on public.student_reports(enrollment_id,term_id)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- AUTH PROFILE SELF-HEALING AND EXISTING-USER BACKFILL
-- ---------------------------------------------------------------------------

create or replace function public.ensure_current_user_profile()
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  target_id uuid:=auth.uid();
  target_email text;
  target_metadata jsonb;
  assigned_role public.app_role;
begin
  if target_id is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;

  select u.email,u.raw_user_meta_data
  into target_email,target_metadata
  from auth.users u
  where u.id=target_id;

  if not found then
    raise exception 'Authentication account not found' using errcode='42501';
  end if;

  if not exists(select 1 from public.profiles p where p.id=target_id) then
    if lower(coalesce(target_metadata->>'role',''))='parent_guardian' then
      assigned_role:='parent_guardian'::public.app_role;
    elsif not exists(
      select 1 from public.profiles p
      where p.active and public.current_app_role_for(p.role)='system_admin'
    ) and target_id=(
      select u.id from auth.users u order by u.created_at,u.id limit 1
    ) then
      assigned_role:='system_admin'::public.app_role;
    else
      assigned_role:='viewer'::public.app_role;
    end if;

    insert into public.profiles(id,full_name,role,active,mfa_required,phone)
    values(
      target_id,
      coalesce(
        nullif(btrim(target_metadata->>'full_name'),''),
        nullif(split_part(coalesce(target_email,''),'@',1),''),
        'User'
      ),
      assigned_role,
      true,
      assigned_role=any(array[
        'system_admin','principal','academic_admin'
      ]::public.app_role[]),
      ''
    )
    on conflict(id) do nothing;
  else
    update public.profiles p
    set full_name=case
          when btrim(coalesce(p.full_name,''))='' then
            coalesce(
              nullif(btrim(target_metadata->>'full_name'),''),
              nullif(split_part(coalesce(target_email,''),'@',1),''),
              'User'
            )
          else p.full_name
        end,
        updated_at=now()
    where p.id=target_id;
  end if;

  return (
    select jsonb_build_object(
      'id',p.id,
      'full_name',p.full_name,
      'role',public.current_app_role_for(p.role),
      'active',p.active,
      'mfa_required',p.mfa_required
    )
    from public.profiles p
    where p.id=target_id
  );
end $$;

do $$
declare
  oldest_user_id uuid;
begin
  insert into public.profiles(id,full_name,role,active,mfa_required,phone)
  select
    u.id,
    coalesce(
      nullif(btrim(u.raw_user_meta_data->>'full_name'),''),
      nullif(split_part(coalesce(u.email,''),'@',1),''),
      'User'
    ),
    case
      when lower(coalesce(u.raw_user_meta_data->>'role',''))='parent_guardian'
        then 'parent_guardian'::public.app_role
      else 'viewer'::public.app_role
    end,
    true,
    false,
    ''
  from auth.users u
  left join public.profiles p on p.id=u.id
  where p.id is null
  on conflict(id) do nothing;

  if not exists(
    select 1 from public.profiles p
    where p.active and public.current_app_role_for(p.role)='system_admin'
  ) then
    select u.id into oldest_user_id
    from auth.users u
    order by u.created_at,u.id
    limit 1;

    if oldest_user_id is not null then
      update public.profiles
      set role='system_admin'::public.app_role,
          active=true,
          mfa_required=true,
          updated_at=now()
      where id=oldest_user_id;
    end if;
  end if;
end $$;

revoke all on function public.ensure_current_user_profile() from public,anon;
grant execute on function public.ensure_current_user_profile() to authenticated;

commit;

-- END OF DATABASE PART 3A
