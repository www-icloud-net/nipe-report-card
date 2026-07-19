-- NIPE INTERNATIONAL SCHOOL REPORT CARD SYSTEM
-- Enterprise v6.5.9 Split Part 3B Edition
-- DATABASE PART 3B-1: STAFF, IDENTIFIERS, ACADEMICS AND DIGITAL SIGNATURES
-- Run only after 03A_schema_hardening_persistence_and_jobs.sql succeeds.
-- After this file succeeds, run 03B2_schema_governance_workflow_and_upgrades.sql.

-- =============================================================================
-- ENTERPRISE RELEASE 6.2.0 STAFF LINKING, IDENTIFIER AND RECORD-SAVE HARDENING
-- =============================================================================
begin;

create table if not exists public.headteachers (
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
  date_appointed date,
  employment_status text not null default 'active'
    check (employment_status in ('active','leave','suspended','resigned','retired')),
  notes text not null default '',
  active boolean not null default true,
  deleted_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.headteachers add column if not exists profile_id uuid references public.profiles(id) on delete set null;
alter table public.headteachers add column if not exists staff_no citext;
alter table public.headteachers add column if not exists first_name text not null default '';
alter table public.headteachers add column if not exists middle_name text not null default '';
alter table public.headteachers add column if not exists last_name text not null default '';
alter table public.headteachers add column if not exists gender text not null default 'Other';
alter table public.headteachers add column if not exists phone text not null default '';
alter table public.headteachers add column if not exists email citext;
alter table public.headteachers add column if not exists address text not null default '';
alter table public.headteachers add column if not exists qualification text not null default '';
alter table public.headteachers add column if not exists date_appointed date;
alter table public.headteachers add column if not exists employment_status text not null default 'active';
alter table public.headteachers add column if not exists notes text not null default '';
alter table public.headteachers add column if not exists active boolean not null default true;
alter table public.headteachers add column if not exists deleted_at timestamptz;
alter table public.headteachers add column if not exists created_by uuid references public.profiles(id) on delete set null default auth.uid();
alter table public.headteachers add column if not exists created_at timestamptz not null default now();
alter table public.headteachers add column if not exists updated_at timestamptz not null default now();

create unique index if not exists headteachers_staff_no_ci_idx
  on public.headteachers(lower(staff_no::text)) where deleted_at is null;
create unique index if not exists headteachers_profile_active_idx
  on public.headteachers(profile_id) where profile_id is not null and deleted_at is null;
create index if not exists headteachers_name_search_idx
  on public.headteachers(lower(last_name),lower(first_name)) where deleted_at is null;
create index if not exists headteachers_status_idx
  on public.headteachers(employment_status,active) where deleted_at is null;

create or replace function public.can_manage_headteachers()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.is_system_admin()
$$;

create or replace function public.generate_school_identifier(identifier_kind text)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  kind text:=lower(btrim(coalesce(identifier_kind,'')));
  candidate text;
  attempt integer:=0;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if kind='student' then
    if not (public.is_records_manager() or public.has_role(array['class_teacher'])) then raise exception 'Access denied' using errcode='42501'; end if;
  elsif kind='teacher' then
    if not public.can_manage_teachers() then raise exception 'Access denied' using errcode='42501'; end if;
  elsif kind='principal' then
    if not public.can_manage_headteachers() then raise exception 'Access denied' using errcode='42501'; end if;
  else
    raise exception 'Identifier type is invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('nis_identifier_'||kind,0));
  loop
    attempt:=attempt+1;
    candidate:='NIS'||lpad(floor(random()*100000000)::bigint::text,8,'0');
    if kind='student' then
      if not exists(select 1 from public.students s where lower(s.admission_no::text)=lower(candidate)) then return candidate; end if;
    else
      if not exists(select 1 from public.teachers t where lower(t.staff_no::text)=lower(candidate))
         and not exists(select 1 from public.headteachers h where lower(h.staff_no::text)=lower(candidate)) then return candidate; end if;
    end if;
    if attempt>=250 then raise exception 'A unique school identifier could not be generated'; end if;
  end loop;
end $$;

create or replace function public.list_headteachers(
  search_text text default '',status_filter text default '',archive_filter text default 'active',
  page_number integer default 1,page_size integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  offset_value integer:=greatest(page_number-1,0)*least(greatest(page_size,1),100);
  limit_value integer:=least(greatest(page_size,1),100);
begin
  if not public.can_manage_headteachers() then raise exception 'Access denied' using errcode='42501'; end if;
  if archive_filter not in ('active','archived','all') then archive_filter:='active'; end if;
  return (
    with matching as (
      select h.id,h.profile_id,h.staff_no,h.first_name,h.middle_name,h.last_name,h.gender,h.phone,
        h.email,h.address,h.qualification,h.date_appointed,h.employment_status,h.notes,h.active,
        h.deleted_at,h.created_at,h.updated_at,
        concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name) full_name,
        p.role profile_role,p.active profile_active,au.email profile_email
      from public.headteachers h
      left join public.profiles p on p.id=h.profile_id
      left join auth.users au on au.id=h.profile_id
      where (archive_filter='all'
        or (archive_filter='active' and h.deleted_at is null)
        or (archive_filter='archived' and h.deleted_at is not null))
        and (coalesce(status_filter,'')='' or h.employment_status=status_filter)
        and (coalesce(search_text,'')='' or h.staff_no::text ilike '%'||search_text||'%'
          or concat_ws(' ',h.first_name,h.middle_name,h.last_name) ilike '%'||search_text||'%'
          or coalesce(h.email::text,'') ilike '%'||search_text||'%'
          or coalesce(h.phone,'') ilike '%'||search_text||'%')
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

create or replace function public.get_headteacher_record(target_headteacher_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
begin
  if not public.can_manage_headteachers() and not exists(
    select 1 from public.headteachers h where h.id=target_headteacher_id and h.profile_id=auth.uid()
  ) then raise exception 'Access denied' using errcode='42501'; end if;
  return (
    select jsonb_build_object(
      'principal',to_jsonb(h)||jsonb_build_object(
        'full_name',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),
        'profile_email',au.email,'profile_name',p.full_name,
        'profile_role',case when p.id is null then null else public.current_app_role_for(p.role) end
      )
    )
    from public.headteachers h
    left join public.profiles p on p.id=h.profile_id
    left join auth.users au on au.id=h.profile_id
    where h.id=target_headteacher_id
  );
end $$;

create or replace function public.save_headteacher(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  hid uuid:=public.safe_uuid(payload->>'id');
  profileid uuid:=public.safe_uuid(payload->>'profile_id');
  staff text:=upper(btrim(coalesce(payload->>'staff_no','')));
  current_updated timestamptz;
  expected_updated timestamptz:=public.safe_timestamptz(payload->>'updated_at');
  appointed date:=public.safe_date(payload->>'date_appointed');
  employment text:=coalesce(nullif(btrim(payload->>'employment_status'),''),'active');
  gender_value text:=coalesce(nullif(btrim(payload->>'gender'),''),'Other');
  linked_role text;
  affected integer;
begin
  if auth.uid() is null or not public.can_manage_headteachers() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(payload->>'id',''))<>'' and hid is null then raise exception 'Principal record identifier is invalid'; end if;
  if btrim(coalesce(payload->>'profile_id',''))<>'' and profileid is null then raise exception 'Linked user account is invalid'; end if;
  if btrim(coalesce(payload->>'date_appointed',''))<>'' and appointed is null then raise exception 'Date appointed is invalid'; end if;
  if btrim(coalesce(payload->>'first_name',''))='' or btrim(coalesce(payload->>'last_name',''))='' then raise exception 'First name and last name are required'; end if;
  if gender_value not in ('Male','Female','Other') then raise exception 'Gender selection is invalid'; end if;
  if btrim(coalesce(payload->>'email',''))<>'' and payload->>'email' !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Principal email address is invalid'; end if;
  if employment not in ('active','leave','suspended','resigned','retired') then raise exception 'Employment status is invalid'; end if;
  if appointed>current_date then raise exception 'Date appointed cannot be in the future'; end if;

  if hid is not null then
    select updated_at into current_updated from public.headteachers where id=hid and deleted_at is null for update;
    if not found then raise exception 'Principal record not found'; end if;
    if expected_updated is not null and current_updated is distinct from expected_updated then raise exception 'Principal record changed by another user' using errcode='40001'; end if;
  end if;

  if hid is null and (staff='' or exists(select 1 from public.teachers t where lower(t.staff_no::text)=lower(staff))
    or exists(select 1 from public.headteachers h where lower(h.staff_no::text)=lower(staff))) then
    staff:=public.generate_school_identifier('principal');
  end if;
  if staff='' then staff:=public.generate_school_identifier('principal'); end if;
  if exists(select 1 from public.teachers t where lower(t.staff_no::text)=lower(staff))
    or exists(select 1 from public.headteachers h where lower(h.staff_no::text)=lower(staff) and (hid is null or h.id<>hid)) then
    raise exception 'Staff number already exists';
  end if;

  if profileid is not null then
    select public.current_app_role_for(p.role) into linked_role from public.profiles p where p.id=profileid and p.active;
    if linked_role is null then raise exception 'Selected user account is unavailable'; end if;
    if linked_role<>'principal' then raise exception 'Selected user account is not a Principal account'; end if;
    if exists(select 1 from public.headteachers h where h.profile_id=profileid and h.deleted_at is null and (hid is null or h.id<>hid))
      or exists(select 1 from public.teachers t where t.profile_id=profileid and t.deleted_at is null) then
      raise exception 'This user account is already linked to another staff record';
    end if;
  end if;

  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Principal record update'),true);
  if hid is null then
    insert into public.headteachers(profile_id,staff_no,first_name,middle_name,last_name,gender,phone,email,address,qualification,date_appointed,employment_status,notes,active,created_by,updated_at)
    values(profileid,staff,btrim(payload->>'first_name'),btrim(coalesce(payload->>'middle_name','')),btrim(payload->>'last_name'),gender_value,
      btrim(coalesce(payload->>'phone','')),nullif(btrim(coalesce(payload->>'email','')),'')::citext,btrim(coalesce(payload->>'address','')),
      btrim(coalesce(payload->>'qualification','')),appointed,employment,btrim(coalesce(payload->>'notes','')),
      public.safe_boolean(payload->>'active',true),auth.uid(),now()) returning id into hid;
  else
    update public.headteachers set profile_id=profileid,staff_no=staff,first_name=btrim(payload->>'first_name'),
      middle_name=btrim(coalesce(payload->>'middle_name','')),last_name=btrim(payload->>'last_name'),gender=gender_value,
      phone=btrim(coalesce(payload->>'phone','')),email=nullif(btrim(coalesce(payload->>'email','')),'')::citext,
      address=btrim(coalesce(payload->>'address','')),qualification=btrim(coalesce(payload->>'qualification','')),
      date_appointed=appointed,employment_status=employment,notes=btrim(coalesce(payload->>'notes','')),
      active=public.safe_boolean(payload->>'active',true),updated_at=now()
    where id=hid and deleted_at is null;
    get diagnostics affected=row_count;
    if affected<>1 then raise exception 'Principal record was not updated'; end if;
  end if;
  if public.safe_boolean(payload->>'active',true) and employment='active' then
    update public.school_settings
    set head_name=concat_ws(' ',btrim(payload->>'first_name'),nullif(btrim(coalesce(payload->>'middle_name','')),''),btrim(payload->>'last_name')),
        updated_at=now()
    where id=(select id from public.school_settings order by created_at,id limit 1);
  end if;
  return public.get_headteacher_record(hid);
exception when unique_violation then raise exception 'Staff number or linked user account is already in use';
end $$;

create or replace function public.archive_headteacher(target_headteacher_id uuid,reason_text text default 'Principal archived')
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.can_manage_headteachers() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  if not exists(select 1 from public.headteachers where id=target_headteacher_id and deleted_at is null for update) then raise exception 'Principal record not found'; end if;
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Principal archived'),true);
  update public.headteachers set active=false,
    employment_status=case when employment_status='active' then 'resigned' else employment_status end,
    deleted_at=now(),updated_at=now() where id=target_headteacher_id;
  update public.school_settings
  set head_name=coalesce((
    select concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name)
    from public.headteachers h where h.deleted_at is null and h.active and h.employment_status='active'
    order by h.date_appointed desc nulls last,h.created_at desc limit 1
  ),''),
      updated_at=now()
  where id=(select id from public.school_settings order by created_at,id limit 1);
  return true;
end $$;

create or replace function public.restore_headteacher(target_headteacher_id uuid,reason_text text default 'Principal restored')
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.can_manage_headteachers() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  if not exists(select 1 from public.headteachers where id=target_headteacher_id and deleted_at is not null for update) then raise exception 'Archived Principal record not found'; end if;
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Principal restored'),true);
  update public.headteachers set active=true,employment_status='active',deleted_at=null,updated_at=now() where id=target_headteacher_id;
  update public.school_settings
  set head_name=(
    select concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name)
    from public.headteachers h
    where h.id=target_headteacher_id
  ),
      updated_at=now()
  where id=(select id from public.school_settings order by created_at,id limit 1);
  return true;
exception when unique_violation then raise exception 'The Principal record cannot be restored because its staff number or linked account is already in use';
end $$;

-- Student persistence now generates and enforces a unique NIS admission number.
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
  admission text:=upper(btrim(coalesce(student_data->>'admission_no','')));
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
  if btrim(coalesce(student_data->>'first_name',''))='' or btrim(coalesce(student_data->>'last_name',''))='' then raise exception 'First name and last name are required'; end if;
  if gender_value not in ('Male','Female','Other') then raise exception 'Gender selection is invalid'; end if;
  if status_value not in ('active','graduated','withdrawn','suspended') then raise exception 'Student status is invalid'; end if;
  if btrim(coalesce(guardian_data->>'email',''))<>'' and guardian_data->>'email' !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Guardian email address is invalid'; end if;
  if birthdate>current_date then raise exception 'Date of birth cannot be in the future'; end if;
  if rollno is not null and rollno<1 then raise exception 'Roll number must be greater than zero'; end if;
  if (classid is null)<>(yearid is null) then raise exception 'Academic year and class must be selected together'; end if;

  if sid is null then
    if admission='' or exists(select 1 from public.students s where lower(s.admission_no::text)=lower(admission)) then admission:=public.generate_school_identifier('student'); end if;
  else
    if not public.can_manage_student(sid) then raise exception 'Access denied' using errcode='42501'; end if;
    select updated_at into current_updated from public.students where id=sid and deleted_at is null for update;
    if not found then raise exception 'Student record not found'; end if;
    if expected_updated is not null and current_updated is distinct from expected_updated then raise exception 'Student record changed by another user' using errcode='40001'; end if;
    if admission='' then raise exception 'Admission number is required'; end if;
  end if;

  if classid is not null then
    if not exists(select 1 from public.classes c where c.id=classid and c.active and c.deleted_at is null) then raise exception 'Selected class is not active'; end if;
    if not exists(select 1 from public.academic_years y where y.id=yearid and y.deleted_at is null) then raise exception 'Selected academic year is unavailable'; end if;
  end if;
  if exists(select 1 from public.students s where lower(s.admission_no::text)=lower(admission) and (sid is null or s.id<>sid)) then raise exception 'Admission number already exists'; end if;
  if rollno is not null and exists(select 1 from public.enrollments e where e.academic_year_id=yearid and e.class_id=classid and e.roll_number=rollno and e.deleted_at is null and (sid is null or e.student_id<>sid)) then raise exception 'Roll number is already assigned in the selected class'; end if;
  if guardian_auth_id is not null and not exists(select 1 from public.profiles p where p.id=guardian_auth_id and p.active and public.current_app_role_for(p.role)='parent_guardian') then raise exception 'Selected portal account is not an active parent or guardian account'; end if;

  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Student record update'),true);
  if sid is null then
    insert into public.students(admission_no,first_name,middle_name,last_name,gender,date_of_birth,guardian_name,guardian_phone,guardian_email,photo_url,status,updated_at)
    values(admission,btrim(student_data->>'first_name'),btrim(coalesce(student_data->>'middle_name','')),btrim(student_data->>'last_name'),
      gender_value,birthdate,btrim(coalesce(guardian_data->>'full_name','')),btrim(coalesce(guardian_data->>'phone','')),
      btrim(coalesce(guardian_data->>'email','')),coalesce(student_data->>'photo_url',''),status_value::public.student_status,now()) returning id into sid;
  else
    update public.students set admission_no=admission,first_name=btrim(student_data->>'first_name'),
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
exception when unique_violation then raise exception 'A student, enrolment, roll number, or guardian link already uses these details';
end $$;

-- Teacher persistence now generates a unique NIS staff number and preserves linked records.
create or replace function public.save_teacher(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  tid uuid:=public.safe_uuid(payload->>'id'); profileid uuid:=public.safe_uuid(payload->>'profile_id');
  staff text:=upper(btrim(coalesce(payload->>'staff_no',''))); current_updated timestamptz;
  expected_updated timestamptz:=public.safe_timestamptz(payload->>'updated_at'); joined date:=public.safe_date(payload->>'date_joined');
  employment text:=coalesce(nullif(btrim(payload->>'employment_status'),''),'active');
  gender_value text:=coalesce(nullif(btrim(payload->>'gender'),''),'Other'); linked_role text; affected integer;
begin
  if auth.uid() is null or not public.can_manage_teachers() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(payload->>'id',''))<>'' and tid is null then raise exception 'Teacher record identifier is invalid'; end if;
  if btrim(coalesce(payload->>'profile_id',''))<>'' and profileid is null then raise exception 'Linked user account is invalid'; end if;
  if btrim(coalesce(payload->>'date_joined',''))<>'' and joined is null then raise exception 'Date joined is invalid'; end if;
  if btrim(coalesce(payload->>'first_name',''))='' or btrim(coalesce(payload->>'last_name',''))='' then raise exception 'First name and last name are required'; end if;
  if gender_value not in ('Male','Female','Other') then raise exception 'Gender selection is invalid'; end if;
  if btrim(coalesce(payload->>'email',''))<>'' and payload->>'email' !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Teacher email address is invalid'; end if;
  if employment not in ('active','leave','suspended','resigned','retired') then raise exception 'Employment status is invalid'; end if;
  if joined>current_date then raise exception 'Date joined cannot be in the future'; end if;
  if tid is not null then
    select updated_at into current_updated from public.teachers where id=tid and deleted_at is null for update;
    if not found then raise exception 'Teacher record not found'; end if;
    if expected_updated is not null and current_updated is distinct from expected_updated then raise exception 'Teacher record changed by another user' using errcode='40001'; end if;
  end if;
  if tid is null and (staff='' or exists(select 1 from public.teachers t where lower(t.staff_no::text)=lower(staff))
    or exists(select 1 from public.headteachers h where lower(h.staff_no::text)=lower(staff))) then staff:=public.generate_school_identifier('teacher'); end if;
  if staff='' then staff:=public.generate_school_identifier('teacher'); end if;
  if exists(select 1 from public.teachers t where lower(t.staff_no::text)=lower(staff) and (tid is null or t.id<>tid))
    or exists(select 1 from public.headteachers h where lower(h.staff_no::text)=lower(staff)) then raise exception 'Staff number already exists'; end if;
  if profileid is not null then
    select public.current_app_role_for(p.role) into linked_role from public.profiles p where p.id=profileid and p.active;
    if linked_role is null then raise exception 'Selected user account is unavailable'; end if;
    if linked_role not in ('class_teacher','subject_teacher') then raise exception 'Selected user account does not have a teacher role'; end if;
    if exists(select 1 from public.teachers t where t.profile_id=profileid and t.deleted_at is null and (tid is null or t.id<>tid))
      or exists(select 1 from public.headteachers h where h.profile_id=profileid and h.deleted_at is null) then
      raise exception 'This user account is already linked to another staff record';
    end if;
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

-- User-account bundles now require and link the corresponding staff record.
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
  if role_text='class_teacher' and coalesce(jsonb_array_length(bundle->'access'),0)>0 and not has_class_scope then raise exception 'Class teacher delegated access requires at least one class-wide editing scope'; end if;
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

  insert into public.profiles(id,full_name,role,active,mfa_required,phone,updated_at)
  values(targetid,resolved_name,role_text::public.app_role,public.safe_boolean(bundle->>'active',true),
    public.safe_boolean(bundle->>'mfa_required',false),resolved_phone,now())
  on conflict(id) do update set full_name=excluded.full_name,role=excluded.role,active=excluded.active,
    mfa_required=excluded.mfa_required,phone=excluded.phone,updated_at=now();

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
    'profiles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'full_name',p.full_name,'email',au.email,'role',public.current_app_role_for(p.role),
      'active',p.active,'mfa_required',p.mfa_required,'phone',p.phone,'last_seen_at',p.last_seen_at,
      'account_created_at',au.created_at,'email_confirmed_at',au.email_confirmed_at,'last_sign_in_at',au.last_sign_in_at,
      'teacher_id',t.id,'headteacher_id',h.id,'staff_record_id',coalesce(h.id,t.id),'staff_no',coalesce(h.staff_no,t.staff_no),
      'access',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'class_id',a.class_id,'class_name',c.name,
        'subject_id',a.subject_id,'subject_name',s.name,'access_level',a.access_level) order by c.name,s.name nulls first)
        from public.user_class_access a join public.classes c on c.id=a.class_id left join public.subjects s on s.id=a.subject_id
        where a.user_id=p.id),'[]'::jsonb)
      ) order by p.full_name)
      from public.profiles p left join auth.users au on au.id=p.id
      left join public.teachers t on t.profile_id=p.id and t.deleted_at is null
      left join public.headteachers h on h.profile_id=p.id and h.deleted_at is null),'[]'::jsonb),
    'teacher_records',coalesce((select jsonb_agg(jsonb_build_object(
      'id',t.id,'profile_id',t.profile_id,'staff_no',t.staff_no,'first_name',t.first_name,'middle_name',t.middle_name,
      'last_name',t.last_name,'full_name',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name),
      'label',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name)||' • '||t.staff_no::text,
      'phone',t.phone,'email',t.email,'active',t.active) order by t.last_name,t.first_name)
      from public.teachers t where t.deleted_at is null and t.active),'[]'::jsonb),
    'headteacher_records',coalesce((select jsonb_agg(jsonb_build_object(
      'id',h.id,'profile_id',h.profile_id,'staff_no',h.staff_no,'first_name',h.first_name,'middle_name',h.middle_name,
      'last_name',h.last_name,'full_name',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),
      'label',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name)||' • '||h.staff_no::text,
      'phone',h.phone,'email',h.email,'active',h.active) order by h.last_name,h.first_name)
      from public.headteachers h where h.deleted_at is null and h.active),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(s) order by s.display_order,s.name) from public.subjects s where s.deleted_at is null),'[]'::jsonb),
    'class_subjects',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'class_id',cs.class_id,'subject_id',cs.subject_id,'active',cs.active)) from public.class_subjects cs),'[]'::jsonb)
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
    select id,full_name,public.current_app_role() role,active,mfa_required,phone from public.profiles where id=auth.uid()
  ) x;
  if p is null then raise exception 'Active profile not found' using errcode='42501'; end if;
  select jsonb_build_object(
    'profile',p,
    'school',(select to_jsonb(s) from public.school_settings s limit 1),
    'academic_years',coalesce((select jsonb_agg(to_jsonb(y) order by y.start_date desc nulls last,y.name) from public.academic_years y where y.deleted_at is null),'[]'::jsonb),
    'terms',coalesce((select jsonb_agg(to_jsonb(t) order by t.sequence) from public.terms t where t.deleted_at is null),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null and (public.is_records_manager() or public.can_access_class(c.id,false))),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(s) order by s.display_order,s.name) from public.subjects s where s.deleted_at is null and s.active),'[]'::jsonb),
    'permissions',jsonb_build_object(
      'manage_users',public.is_system_admin(),
      'manage_teachers',public.can_manage_teachers(),
      'manage_headteachers',public.can_manage_headteachers(),
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
    'generated_at',now(),'schema_version','6.4.0',
    'school_settings',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.school_settings x),
    'profiles',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.profiles x),
    'user_class_access',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.user_class_access x),
    'teachers',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.teachers x),
    'headteachers',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.headteachers x),
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

-- Trigger, RLS, Realtime and grants for headteacher records.
drop trigger if exists headteachers_set_updated_at on public.headteachers;
create trigger headteachers_set_updated_at before update on public.headteachers
for each row execute function public.set_updated_at();

drop trigger if exists headteachers_audit on public.headteachers;
create trigger headteachers_audit after insert or update or delete on public.headteachers
for each row execute function public.audit_row_change();

drop trigger if exists headteachers_broadcast on public.headteachers;
create trigger headteachers_broadcast after insert or update or delete on public.headteachers
for each row execute function public.broadcast_application_change();

alter table public.headteachers enable row level security;
drop policy if exists headteachers_select on public.headteachers;
create policy headteachers_select on public.headteachers for select to authenticated
using(public.can_manage_headteachers() or profile_id=auth.uid());

revoke all on public.headteachers from anon,authenticated;
grant select on public.headteachers to authenticated;
grant all on public.headteachers to service_role;

do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime')
    and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='headteachers') then
    alter publication supabase_realtime add table public.headteachers;
  end if;
exception when duplicate_object then null;
end $$;

revoke all on function public.generate_school_identifier(text) from public,anon;
revoke all on function public.list_headteachers(text,text,text,integer,integer) from public,anon;
revoke all on function public.get_headteacher_record(uuid) from public,anon;
revoke all on function public.save_headteacher(jsonb) from public,anon;
revoke all on function public.archive_headteacher(uuid,text) from public,anon;
revoke all on function public.restore_headteacher(uuid,text) from public,anon;
revoke all on function public.admin_validate_user_bundle(uuid,jsonb,boolean) from public,anon,authenticated;
revoke all on function public.admin_apply_user_bundle(uuid,jsonb) from public,anon,authenticated;

grant execute on function public.generate_school_identifier(text) to authenticated;
grant execute on function public.list_headteachers(text,text,text,integer,integer) to authenticated;
grant execute on function public.get_headteacher_record(uuid) to authenticated;
grant execute on function public.save_headteacher(jsonb) to authenticated;
grant execute on function public.archive_headteacher(uuid,text) to authenticated;
grant execute on function public.restore_headteacher(uuid,text) to authenticated;
grant execute on function public.admin_validate_user_bundle(uuid,jsonb,boolean) to service_role;
grant execute on function public.admin_apply_user_bundle(uuid,jsonb) to service_role;

commit;

begin;

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
  if not public.has_role(array['system_admin','principal']) then raise exception 'Access denied' using errcode='42501'; end if;
  select jsonb_object_agg(tablename,rowsecurity) into rls_state from pg_tables where schemaname='public' and tablename in
    ('profiles','teachers','headteachers','students','student_guardians','guardian_links','enrollments','academic_years','terms','classes','subjects','class_subjects','user_class_access','grading_scales','assessment_schemes','assessment_components','student_reports','subject_results','assessment_score_entries');
  function_state:=jsonb_build_object(
    'generate_school_identifier',to_regprocedure('public.generate_school_identifier(text)') is not null,
    'save_student',to_regprocedure('public.save_student(jsonb)') is not null,
    'set_student_photo',to_regprocedure('public.set_student_photo(uuid,text,timestamptz)') is not null,
    'save_teacher',to_regprocedure('public.save_teacher(jsonb)') is not null,
    'save_headteacher',to_regprocedure('public.save_headteacher(jsonb)') is not null,
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
    'staff_numbers',(select count(*) from (
      select staff_no from (
        select lower(staff_no::text) staff_no from public.teachers
        union all select lower(staff_no::text) from public.headteachers
      ) all_staff group by staff_no having count(*)>1
    ) duplicate_staff),
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
      where t.deleted_at is null and t.profile_id is not null and (p.id is null or not p.active or public.current_app_role_for(p.role) not in ('class_teacher','subject_teacher'))),
    'invalid_headteacher_links',(select count(*) from public.headteachers h left join public.profiles p on p.id=h.profile_id
      where h.deleted_at is null and h.profile_id is not null and (p.id is null or not p.active or public.current_app_role_for(p.role)<>'principal')),
    'duplicate_staff_profile_links',(select count(*) from (
      select profile_id from (
        select profile_id from public.teachers where deleted_at is null and profile_id is not null
        union all select profile_id from public.headteachers where deleted_at is null and profile_id is not null
      ) staff_links group by profile_id having count(*)>1
    ) q),
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
    'identifier_rpc',has_function_privilege('authenticated','public.generate_school_identifier(text)','EXECUTE'),
    'student_rpc',has_function_privilege('authenticated','public.save_student(jsonb)','EXECUTE'),
    'teacher_rpc',has_function_privilege('authenticated','public.save_teacher(jsonb)','EXECUTE'),
    'headteacher_rpc',has_function_privilege('authenticated','public.save_headteacher(jsonb)','EXECUTE'),
    'academic_rpc',has_function_privilege('authenticated','public.save_academic_entity(text,jsonb)','EXECUTE'),
    'assessment_rpc',has_function_privilege('authenticated','public.save_assessment_scheme(jsonb)','EXECUTE'),
    'report_rpc',has_function_privilege('authenticated','public.save_report_card(jsonb,integer)','EXECUTE'),
    'student_direct_write_blocked',not has_table_privilege('authenticated','public.students','INSERT') and not has_table_privilege('authenticated','public.students','UPDATE') and not has_table_privilege('authenticated','public.students','DELETE'),
    'teacher_direct_write_blocked',not has_table_privilege('authenticated','public.teachers','INSERT') and not has_table_privilege('authenticated','public.teachers','UPDATE') and not has_table_privilege('authenticated','public.teachers','DELETE'),
    'headteacher_direct_write_blocked',not has_table_privilege('authenticated','public.headteachers','INSERT') and not has_table_privilege('authenticated','public.headteachers','UPDATE') and not has_table_privilege('authenticated','public.headteachers','DELETE'),
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

revoke insert,update,delete on public.headteachers from authenticated;
grant execute on function public.can_manage_headteachers() to authenticated;

commit;


-- =============================================================================
-- ENTERPRISE RELEASE 6.4.0 ACADEMIC REMOVAL, SUBJECT CODES, DIGITAL SIGNATURE
-- =============================================================================
begin;

alter table public.headteachers add column if not exists signature_path text not null default '';
alter table public.headteachers add column if not exists signature_updated_at timestamptz;

create or replace function public.list_headteachers(
  search_text text default '',status_filter text default '',archive_filter text default 'active',
  page_number integer default 1,page_size integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  offset_value integer:=greatest(page_number-1,0)*least(greatest(page_size,1),100);
  limit_value integer:=least(greatest(page_size,1),100);
begin
  if not public.can_manage_headteachers() then raise exception 'Access denied' using errcode='42501'; end if;
  if archive_filter not in ('active','archived','all') then archive_filter:='active'; end if;
  return (
    with matching as (
      select h.id,h.profile_id,h.staff_no,h.first_name,h.middle_name,h.last_name,h.phone,h.active,h.signature_path,h.signature_updated_at,
        h.deleted_at,h.created_at,h.updated_at,concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name) full_name,
        p.role profile_role,p.active profile_active,au.email profile_email
      from public.headteachers h
      left join public.profiles p on p.id=h.profile_id
      left join auth.users au on au.id=h.profile_id
      where (archive_filter='all' or (archive_filter='active' and h.deleted_at is null) or (archive_filter='archived' and h.deleted_at is not null))
        and (coalesce(status_filter,'')='' or h.employment_status=status_filter)
        and (coalesce(search_text,'')='' or h.staff_no::text ilike '%'||search_text||'%' or concat_ws(' ',h.first_name,h.middle_name,h.last_name) ilike '%'||search_text||'%' or coalesce(h.phone,'') ilike '%'||search_text||'%' or coalesce(au.email::text,'') ilike '%'||search_text||'%')
    )
    select jsonb_build_object(
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by x.full_name) from (select * from matching order by full_name limit limit_value offset offset_value) x),'[]'::jsonb),
      'total',(select count(*) from matching),'page',greatest(page_number,1),'page_size',limit_value
    )
  );
end $$;

create or replace function public.generate_subject_code(subject_name text,exclude_subject_id uuid default null)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  cleaned text:=upper(regexp_replace(btrim(coalesce(subject_name,'')),'[^[:alnum:] ]+',' ','g'));
  meaningful text[];
  all_words text[];
  selected_words text[];
  token text;
  prefix text:='';
  candidate text;
  attempt integer:=0;
begin
  if auth.uid() is null or not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(cleaned)='' then raise exception 'Subject name is required'; end if;

  select coalesce(array_agg(word order by ord),'{}'::text[]) into all_words
  from regexp_split_to_table(cleaned,'[[:space:]]+') with ordinality as words(word,ord)
  where btrim(word)<>'';

  select coalesce(array_agg(word order by ord),'{}'::text[]) into meaningful
  from regexp_split_to_table(cleaned,'[[:space:]]+') with ordinality as words(word,ord)
  where btrim(word)<>'' and word not in ('AND','OF','THE','FOR','IN','TO');

  selected_words:=case when cardinality(meaningful)>0 then meaningful else all_words end;
  if cardinality(selected_words)=1 then
    prefix:=left(regexp_replace(selected_words[1],'[^A-Z0-9]','','g'),3);
  else
    foreach token in array selected_words loop
      prefix:=prefix||left(token,1);
      exit when length(prefix)>=4;
    end loop;
  end if;
  if prefix='' then prefix:='SUB'; end if;

  perform pg_advisory_xact_lock(hashtextextended('nis_subject_code_'||prefix,0));
  loop
    attempt:=attempt+1;
    candidate:=prefix||lpad(floor(random()*10000)::integer::text,4,'0');
    if not exists(
      select 1 from public.subjects s
      where lower(s.code::text)=lower(candidate)
        and (exclude_subject_id is null or s.id<>exclude_subject_id)
    ) then return candidate; end if;
    if attempt>=250 then raise exception 'A unique subject code could not be generated'; end if;
  end loop;
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
  seq integer:=public.safe_integer(payload->>'sequence');
  orderno integer;
  subjectcode text;
  existingcode text;
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
    if targetid is null then
      insert into public.academic_years(name,start_date,end_date) values(btrim(payload->>'name'),startdate,enddate) returning id into targetid;
    else
      update public.academic_years set name=btrim(payload->>'name'),start_date=startdate,end_date=enddate,updated_at=now() where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='terms' then
    if yearid is null or not exists(select 1 from public.academic_years y where y.id=yearid and y.deleted_at is null) then raise exception 'Academic year is invalid'; end if;
    if btrim(coalesce(payload->>'name',''))='' then raise exception 'Term name is required'; end if;
    if seq is null or seq not between 1 and 6 then raise exception 'Term sequence must be between 1 and 6'; end if;
    if targetid is null then
      insert into public.terms(academic_year_id,name,sequence,start_date,end_date,next_term_begins) values(yearid,btrim(payload->>'name'),seq,startdate,enddate,nextdate) returning id into targetid;
    else
      update public.terms set academic_year_id=yearid,name=btrim(payload->>'name'),sequence=seq,start_date=startdate,end_date=enddate,next_term_begins=nextdate,updated_at=now() where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='classes' then
    if btrim(coalesce(payload->>'name',''))='' then raise exception 'Class name is required'; end if;
    orderno:=coalesce(public.safe_integer(payload->>'level_order'),0);
    if teacherid is not null and not exists(select 1 from public.profiles p where p.id=teacherid and p.active and public.current_app_role_for(p.role) in ('principal','academic_admin','class_teacher')) then raise exception 'Selected class teacher account is invalid'; end if;
    if targetid is null then
      insert into public.classes(name,level_order,class_teacher_id,active) values(btrim(payload->>'name'),orderno,teacherid,public.safe_boolean(payload->>'active',true)) returning id into targetid;
    else
      update public.classes set name=btrim(payload->>'name'),level_order=orderno,class_teacher_id=teacherid,active=public.safe_boolean(payload->>'active',true),updated_at=now() where id=targetid and deleted_at is null;
    end if;
  elsif entity_type='subjects' then
    if btrim(coalesce(payload->>'name',''))='' then raise exception 'Subject name is required'; end if;
    orderno:=coalesce(public.safe_integer(payload->>'display_order'),0);
    subjectcode:=upper(btrim(coalesce(payload->>'code','')));
    if targetid is null then
      if subjectcode='' or exists(select 1 from public.subjects s where lower(s.code::text)=lower(subjectcode)) then subjectcode:=public.generate_subject_code(payload->>'name',null); end if;
      insert into public.subjects(code,name,display_order,active) values(subjectcode,btrim(payload->>'name'),orderno,public.safe_boolean(payload->>'active',true)) returning id into targetid;
    else
      select s.code::text into existingcode from public.subjects s where s.id=targetid and s.deleted_at is null for update;
      if not found then raise exception 'Subject not found'; end if;
      subjectcode:=coalesce(nullif(subjectcode,''),existingcode);
      if exists(select 1 from public.subjects s where lower(s.code::text)=lower(subjectcode) and s.id<>targetid) then subjectcode:=public.generate_subject_code(payload->>'name',targetid); end if;
      update public.subjects set code=subjectcode,name=btrim(payload->>'name'),display_order=orderno,active=public.safe_boolean(payload->>'active',true),updated_at=now() where id=targetid and deleted_at is null;
    end if;
  else
    raise exception 'Unsupported academic record type';
  end if;

  get diagnostics affected=row_count;
  if targetid is null or affected=0 then raise exception 'Academic record was not saved'; end if;
  return public.get_academic_configuration();
exception when unique_violation then
  raise exception 'An academic record already uses this name, code, sequence, or date scope';
end $$;

create or replace function public.archive_academic_entity(entity_type text,target_id uuid,reason_text text default 'Academic record archived')
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare active_value boolean;
begin
  if not public.is_academic_manager() then raise exception 'Access denied' using errcode='42501'; end if;
  perform public.require_sensitive_access();
  perform set_config('app.change_reason',coalesce(nullif(reason_text,''),'Academic record archived'),true);

  if entity_type in ('academic_year','academic_years') then
    select y.is_active into active_value from public.academic_years y where y.id=target_id and y.deleted_at is null for update;
    if not found then raise exception 'Academic year not found'; end if;
    if active_value then raise exception 'Deactivate this academic year before removing it'; end if;
    if exists(select 1 from public.terms t where t.academic_year_id=target_id and t.deleted_at is null and t.is_active) then raise exception 'Deactivate the academic year term before removing it'; end if;
    if exists(select 1 from public.enrollments e where e.academic_year_id=target_id and e.active and e.deleted_at is null) then raise exception 'This academic year has active student enrolments'; end if;
    if exists(select 1 from public.student_reports r join public.enrollments e on e.id=r.enrollment_id where e.academic_year_id=target_id and r.deleted_at is null and r.status not in ('published','withdrawn')) then raise exception 'This academic year has unfinished report cards'; end if;
    update public.assessment_schemes set active=false,deleted_at=coalesce(deleted_at,now()),updated_at=now() where academic_year_id=target_id and deleted_at is null;
    update public.grading_scales set deleted_at=coalesce(deleted_at,now()),updated_at=now() where academic_year_id=target_id and deleted_at is null;
    update public.terms set is_active=false,deleted_at=coalesce(deleted_at,now()),updated_at=now() where academic_year_id=target_id and deleted_at is null;
    update public.academic_years set is_active=false,deleted_at=now(),updated_at=now() where id=target_id;
  elsif entity_type in ('term','terms') then
    select t.is_active into active_value from public.terms t where t.id=target_id and t.deleted_at is null for update;
    if not found then raise exception 'Term not found'; end if;
    if active_value then raise exception 'Deactivate this term before removing it'; end if;
    if exists(select 1 from public.student_reports r where r.term_id=target_id and r.deleted_at is null and r.status not in ('published','withdrawn')) then raise exception 'This term has unfinished report cards'; end if;
    update public.assessment_schemes set active=false,deleted_at=coalesce(deleted_at,now()),updated_at=now() where term_id=target_id and deleted_at is null;
    update public.terms set is_active=false,deleted_at=now(),updated_at=now() where id=target_id;
  elsif entity_type='class' then
    if exists(select 1 from public.enrollments e join public.students s on s.id=e.student_id where e.class_id=target_id and e.active and e.deleted_at is null and s.deleted_at is null) then raise exception 'This class has active student enrolments'; end if;
    update public.classes set active=false,deleted_at=now(),updated_at=now() where id=target_id and deleted_at is null;
    if not found then raise exception 'Class not found'; end if;
    update public.class_subjects set active=false,updated_at=now() where class_id=target_id;
  elsif entity_type='subject' then
    if exists(select 1 from public.subject_results sr join public.student_reports r on r.id=sr.report_id where sr.subject_id=target_id and r.deleted_at is null and r.status in ('draft','returned','submitted','class_reviewed','approved')) then raise exception 'This subject is used by an unfinished report card'; end if;
    update public.subjects set active=false,deleted_at=now(),updated_at=now() where id=target_id and deleted_at is null;
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

create or replace function public.save_headteacher(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  hid uuid:=public.safe_uuid(payload->>'id');
  profileid uuid:=public.safe_uuid(payload->>'profile_id');
  staff text:=upper(btrim(coalesce(payload->>'staff_no','')));
  full_name_value text:=regexp_replace(btrim(coalesce(payload->>'full_name','')),'[[:space:]]+',' ','g');
  contact_value text:=btrim(coalesce(payload->>'contact',payload->>'phone',''));
  name_parts text[];
  first_name_value text;
  last_name_value text:='';
  current_updated timestamptz;
  expected_updated timestamptz:=public.safe_timestamptz(payload->>'updated_at');
  linked_role text;
  affected integer;
begin
  if auth.uid() is null or not public.can_manage_headteachers() then raise exception 'Access denied' using errcode='42501'; end if;
  if btrim(coalesce(payload->>'id',''))<>'' and hid is null then raise exception 'Principal record identifier is invalid'; end if;
  if btrim(coalesce(payload->>'profile_id',''))<>'' and profileid is null then raise exception 'Linked user account is invalid'; end if;
  if full_name_value='' then raise exception 'Principal full name is required'; end if;
  if contact_value='' then raise exception 'Principal contact is required'; end if;
  name_parts:=regexp_split_to_array(full_name_value,'[[:space:]]+');
  first_name_value:=name_parts[1];
  if cardinality(name_parts)>1 then last_name_value:=array_to_string(name_parts[2:cardinality(name_parts)],' '); end if;

  if hid is not null then
    select updated_at into current_updated from public.headteachers where id=hid and deleted_at is null for update;
    if not found then raise exception 'Principal record not found'; end if;
    if expected_updated is not null and current_updated is distinct from expected_updated then raise exception 'Principal record changed by another user' using errcode='40001'; end if;
  end if;

  if hid is null and (staff='' or exists(select 1 from public.teachers t where lower(t.staff_no::text)=lower(staff)) or exists(select 1 from public.headteachers h where lower(h.staff_no::text)=lower(staff))) then staff:=public.generate_school_identifier('principal'); end if;
  if staff='' then staff:=public.generate_school_identifier('principal'); end if;
  if exists(select 1 from public.teachers t where lower(t.staff_no::text)=lower(staff)) or exists(select 1 from public.headteachers h where lower(h.staff_no::text)=lower(staff) and (hid is null or h.id<>hid)) then raise exception 'Staff number already exists'; end if;

  if profileid is not null then
    select public.current_app_role_for(p.role) into linked_role from public.profiles p where p.id=profileid and p.active;
    if linked_role is null then raise exception 'Selected user account is unavailable'; end if;
    if linked_role<>'principal' then raise exception 'Selected user account is not a Principal account'; end if;
    if exists(select 1 from public.headteachers h where h.profile_id=profileid and h.deleted_at is null and (hid is null or h.id<>hid)) or exists(select 1 from public.teachers t where t.profile_id=profileid and t.deleted_at is null) then raise exception 'This user account is already linked to another staff record'; end if;
  end if;

  perform set_config('app.change_reason',coalesce(nullif(payload->>'reason',''),'Principal record update'),true);
  if hid is null then
    insert into public.headteachers(profile_id,staff_no,first_name,middle_name,last_name,phone,employment_status,active,created_by,updated_at)
    values(profileid,staff,first_name_value,'',last_name_value,contact_value,'active',true,auth.uid(),now()) returning id into hid;
  else
    update public.headteachers set profile_id=profileid,staff_no=staff,first_name=first_name_value,middle_name='',last_name=last_name_value,phone=contact_value,employment_status='active',active=true,updated_at=now()
    where id=hid and deleted_at is null;
    get diagnostics affected=row_count;
    if affected<>1 then raise exception 'Principal record was not updated'; end if;
  end if;
  update public.school_settings
  set head_name=full_name_value,
      updated_at=now()
  where id=(select id from public.school_settings order by created_at,id limit 1);
  return public.get_headteacher_record(hid);
exception when unique_violation then
  raise exception 'Staff number or linked user account is already in use';
end $$;

create or replace function public.get_my_headteacher_signature()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare result jsonb;
begin
  if auth.uid() is null or not public.has_role(array['principal']) then raise exception 'Access denied' using errcode='42501'; end if;
  select jsonb_build_object('linked',true,'headteacher_id',h.id,'full_name',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),'contact',h.phone,'signature_path',h.signature_path,'signature_updated_at',h.signature_updated_at,'updated_at',h.updated_at)
  into result from public.headteachers h where h.profile_id=auth.uid() and h.deleted_at is null and h.active order by h.updated_at desc limit 1;
  return coalesce(result,jsonb_build_object('linked',false,'full_name',(select p.full_name from public.profiles p where p.id=auth.uid()),'signature_path',''));
end $$;

create or replace function public.set_my_headteacher_signature(target_signature_path text,expected_updated_at timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare hid uuid;current_updated timestamptz;clean_path text:=btrim(coalesce(target_signature_path,''));
begin
  if auth.uid() is null or not public.has_role(array['principal']) then raise exception 'Access denied' using errcode='42501'; end if;
  select h.id,h.updated_at into hid,current_updated from public.headteachers h where h.profile_id=auth.uid() and h.deleted_at is null and h.active order by h.updated_at desc limit 1 for update;
  if hid is null then raise exception 'No active Principal record is linked to this account'; end if;
  if expected_updated_at is not null and current_updated is distinct from expected_updated_at then raise exception 'Principal record changed. Reload and try again.' using errcode='40001'; end if;
  if clean_path<>'' and clean_path not like auth.uid()::text||'/%' then raise exception 'Signature storage path is invalid'; end if;
  perform set_config('app.change_reason',case when clean_path='' then 'Principal signature removed' else 'Principal signature updated' end,true);
  update public.headteachers set signature_path=clean_path,signature_updated_at=case when clean_path='' then null else now() end,updated_at=now() where id=hid;
  return public.get_my_headteacher_signature();
end $$;

create or replace function public.get_report_headteacher_signature(target_report_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare result jsonb;
begin
  if auth.uid() is null or not public.can_view_report(target_report_id) then raise exception 'Access denied' using errcode='42501'; end if;
  with publication_actor as (
    select rp.published_by from public.report_publications rp where rp.report_id=target_report_id and rp.revoked_at is null order by rp.published_at desc limit 1
  ), candidates as (
    select h.id,h.profile_id,h.first_name,h.middle_name,h.last_name,h.phone,h.signature_path,h.signature_updated_at,h.created_at,0 priority
    from public.headteachers h join publication_actor pa on pa.published_by=h.profile_id where btrim(coalesce(h.signature_path,''))<>''
    union all
    select h.id,h.profile_id,h.first_name,h.middle_name,h.last_name,h.phone,h.signature_path,h.signature_updated_at,h.created_at,1 priority
    from public.headteachers h where h.deleted_at is null and h.active and h.employment_status='active' and btrim(coalesce(h.signature_path,''))<>''
    union all
    select h.id,h.profile_id,h.first_name,h.middle_name,h.last_name,h.phone,h.signature_path,h.signature_updated_at,h.created_at,2 priority
    from public.headteachers h where h.deleted_at is null and h.active and h.employment_status='active'
  )
  select jsonb_build_object('headteacher_id',c.id,'profile_id',c.profile_id,'full_name',concat_ws(' ',c.first_name,nullif(c.middle_name,''),c.last_name),'contact',c.phone,'signature_path',c.signature_path,'signature_updated_at',c.signature_updated_at)
  into result from candidates c order by c.priority,c.created_at desc limit 1;
  return coalesce(result,jsonb_build_object('full_name',coalesce((select s.head_name from public.school_settings s limit 1),'Principal'),'signature_path',''));
end $$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('headteacher-signatures','headteacher-signatures',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists headteacher_signatures_read on storage.objects;
create policy headteacher_signatures_read on storage.objects for select to authenticated
using(bucket_id='headteacher-signatures' and (public.is_system_admin() or (public.has_role(array['principal']) and public.safe_uuid((storage.foldername(name))[1])=auth.uid())));

drop policy if exists headteacher_signatures_insert on storage.objects;
create policy headteacher_signatures_insert on storage.objects for insert to authenticated
with check(bucket_id='headteacher-signatures' and public.has_role(array['principal']) and public.safe_uuid((storage.foldername(name))[1])=auth.uid() and exists(select 1 from public.headteachers h where h.profile_id=auth.uid() and h.deleted_at is null and h.active));

drop policy if exists headteacher_signatures_update on storage.objects;
create policy headteacher_signatures_update on storage.objects for update to authenticated
using(bucket_id='headteacher-signatures' and public.has_role(array['principal']) and public.safe_uuid((storage.foldername(name))[1])=auth.uid())
with check(bucket_id='headteacher-signatures' and public.has_role(array['principal']) and public.safe_uuid((storage.foldername(name))[1])=auth.uid());

drop policy if exists headteacher_signatures_delete on storage.objects;
create policy headteacher_signatures_delete on storage.objects for delete to authenticated
using(bucket_id='headteacher-signatures' and public.has_role(array['principal']) and public.safe_uuid((storage.foldername(name))[1])=auth.uid());

revoke all on function public.generate_subject_code(text,uuid) from public,anon;
revoke all on function public.get_my_headteacher_signature() from public,anon;
revoke all on function public.set_my_headteacher_signature(text,timestamptz) from public,anon;
revoke all on function public.get_report_headteacher_signature(uuid) from public,anon;
grant execute on function public.generate_subject_code(text,uuid) to authenticated;
grant execute on function public.get_my_headteacher_signature() to authenticated;
grant execute on function public.set_my_headteacher_signature(text,timestamptz) to authenticated;
grant execute on function public.get_report_headteacher_signature(uuid) to authenticated;
grant execute on function public.archive_academic_entity(text,uuid,text) to authenticated;
grant execute on function public.save_academic_entity(text,jsonb) to authenticated;
grant execute on function public.save_headteacher(jsonb) to authenticated;

commit;

-- END OF DATABASE PART 3B-1

-- =============================================================================
-- ENTERPRISE RELEASE 6.6.0 PROFESSIONAL REPORT-CARD TEMPLATE
-- Permanent location: Database Part 3B1
-- =============================================================================
begin;

create or replace function public.get_current_principal_signature()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  result jsonb;
begin
  if auth.uid() is null
     or public.current_app_role() not in ('system_admin','principal','class_teacher','subject_teacher') then
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

revoke all on function public.get_current_principal_signature() from public,anon;
grant execute on function public.get_current_principal_signature() to authenticated;

commit;

