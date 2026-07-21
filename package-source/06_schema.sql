-- =============================================================================
-- REPORT CARD ENTERPRISE v6.8.0
-- Alphabetical directories, strict teacher class visibility, active promotion
-- placement, and class-teacher attendance register.
-- Run after 05_schema.sql.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1. Strict assignment-based class and student visibility
-- -----------------------------------------------------------------------------
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
    else false
  end
$$;

create or replace function public.can_manage_class_report_fields(target_class_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.current_app_role()='class_teacher'
    and exists(
      select 1 from public.classes c
      where c.id=target_class_id
        and c.class_teacher_id=auth.uid()
        and c.active
        and c.deleted_at is null
    )
$$;

create or replace function public.can_score_class_subject(target_class_id uuid,target_subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.current_app_role() in ('class_teacher','subject_teacher')
    and exists(
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
$$;

create or replace function public.can_view_student(target_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select case
    when public.current_app_role() in ('system_admin','principal') then true
    when public.current_app_role() in ('class_teacher','subject_teacher') then exists(
      select 1
      from public.enrollments e
      join public.academic_years y on y.id=e.academic_year_id and y.deleted_at is null
      where e.id=(
        select current_e.id
        from public.enrollments current_e
        join public.academic_years current_y on current_y.id=current_e.academic_year_id and current_y.deleted_at is null
        where current_e.student_id=target_student_id
          and current_e.deleted_at is null
        order by current_e.active desc,
          coalesce(current_y.start_date,current_y.end_date,current_e.created_at::date) desc,
          current_y.name::text desc,
          current_e.created_at desc
        limit 1
      )
      and public.can_access_class(e.class_id,false)
    )
    else false
  end
$$;

-- -----------------------------------------------------------------------------
-- 2. Alphabetical student directories using the displayed full name
-- -----------------------------------------------------------------------------
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
        c.name class_name,y.name academic_year_name,
        concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name) display_name
      from public.students s
      left join lateral (
        select en.* from public.enrollments en
        join public.academic_years ay on ay.id=en.academic_year_id and ay.deleted_at is null
        where en.student_id=s.id and en.deleted_at is null
        order by en.active desc,
          coalesce(ay.start_date,ay.end_date,en.created_at::date) desc,
          ay.name::text desc,en.created_at desc limit 1
      ) e on true
      left join public.classes c on c.id=e.class_id
      left join public.academic_years y on y.id=e.academic_year_id
      where s.deleted_at is null
        and (public.current_app_role() in ('system_admin','principal') or (e.id is not null and public.can_access_class(e.class_id,false)))
        and (target_class_id is null or e.class_id=target_class_id)
        and (target_status is null or s.status=target_status)
        and (coalesce(search_text,'')='' or s.admission_no::text ilike '%'||search_text||'%'
          or concat_ws(' ',s.first_name,s.middle_name,s.last_name) ilike '%'||search_text||'%')
    )
    select jsonb_build_object(
      'rows',coalesce((select jsonb_agg(to_jsonb(x)-'display_name' order by lower(x.display_name),x.admission_no::text) from (
        select * from matching order by lower(display_name),admission_no::text limit limit_value offset offset_value
      ) x),'[]'::jsonb),
      'total',(select count(*) from matching),
      'page',greatest(page_number,1),'page_size',limit_value
    )
  );
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
        c.name class_name,y.name academic_year_name,
        concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name) display_name
      from public.students s
      left join lateral (
        select en.* from public.enrollments en
        join public.academic_years ay on ay.id=en.academic_year_id and ay.deleted_at is null
        where en.student_id=s.id and en.deleted_at is null
        order by en.active desc,
          coalesce(ay.start_date,ay.end_date,en.created_at::date) desc,
          ay.name::text desc,en.created_at desc limit 1
      ) e on true
      left join public.classes c on c.id=e.class_id
      left join public.academic_years y on y.id=e.academic_year_id
      where (public.current_app_role() in ('system_admin','principal') or (e.id is not null and public.can_access_class(e.class_id,false)))
        and (archive_filter='all'
          or (archive_filter='active' and s.deleted_at is null)
          or (archive_filter='archived' and s.deleted_at is not null))
        and (target_class_id is null or e.class_id=target_class_id)
        and (target_status is null or s.status=target_status)
        and (coalesce(search_text,'')='' or s.admission_no::text ilike '%'||search_text||'%'
          or concat_ws(' ',s.first_name,s.middle_name,s.last_name) ilike '%'||search_text||'%')
    )
    select jsonb_build_object(
      'rows',coalesce((select jsonb_agg(to_jsonb(x)-'display_name' order by lower(x.display_name),x.admission_no::text) from (
        select * from matching order by lower(display_name),admission_no::text limit limit_value offset offset_value
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
        and (public.current_app_role() in ('system_admin','principal') or public.can_access_class(e.class_id,false))
    ) q),'[]'::jsonb),
    'guardians',coalesce((select jsonb_agg(to_jsonb(q) order by q.is_primary desc,lower(q.full_name)) from (
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

-- Alphabetical teacher directory.
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
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by lower(x.full_name),x.staff_no::text) from (
        select * from matching order by lower(full_name),staff_no::text limit limit_value offset offset_value
      ) x),'[]'::jsonb),
      'total',(select count(*) from matching),
      'page',greatest(page_number,1),'page_size',limit_value,
      'profiles',coalesce((select jsonb_agg(jsonb_build_object(
        'id',p.id,'full_name',p.full_name,'role',public.current_app_role_for(p.role),'email',au.email
      ) order by lower(p.full_name))
        from public.profiles p left join auth.users au on au.id=p.id
        where p.active and public.current_app_role_for(p.role) in ('system_admin','headteacher','academic_admin','class_teacher','subject_teacher')),'[]'::jsonb)
    )
  );
end $$;

create or replace function public.list_headteachers(
  search_text text default '',status_filter text default '',archive_filter text default 'active',
  page_number integer default 1,page_size integer default 20
)
returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
declare offset_value integer:=greatest(page_number-1,0)*least(greatest(page_size,1),100);
declare limit_value integer:=least(greatest(page_size,1),100);
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
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by lower(x.full_name),x.staff_no::text) from (select * from matching order by lower(full_name),staff_no::text limit limit_value offset offset_value) x),'[]'::jsonb),
      'total',(select count(*) from matching),'page',greatest(page_number,1),'page_size',limit_value
    )
  );
end $$;


-- Keep user, teacher, principal, and assignment pickers alphabetically ordered
-- by the same full name displayed in the interface.
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
      'access',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'class_id',a.class_id,'class_name',c.name,'subject_id',a.subject_id,'subject_name',sub.name,'access_level',a.access_level) order by lower(c.name),lower(sub.name) nulls first)
        from public.user_class_access a join public.classes c on c.id=a.class_id left join public.subjects sub on sub.id=a.subject_id where a.user_id=p.id),'[]'::jsonb)
      ) order by lower(p.full_name),p.id)
      from public.profiles p left join auth.users au on au.id=p.id
      left join public.teachers t on t.profile_id=p.id and t.deleted_at is null
      left join public.headteachers h on h.profile_id=p.id and h.deleted_at is null
      where public.current_app_role_for(p.role) in ('system_admin','principal','class_teacher','subject_teacher','parent_guardian')),'[]'::jsonb),
    'teacher_records',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'profile_id',t.profile_id,'staff_no',t.staff_no,'first_name',t.first_name,'middle_name',t.middle_name,'last_name',t.last_name,'full_name',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name),'label',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name)||' • '||t.staff_no::text,'phone',t.phone,'email',t.email,'active',t.active)
      order by lower(concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name)),t.staff_no::text)
      from public.teachers t where t.deleted_at is null and t.active),'[]'::jsonb),
    'headteacher_records',coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'profile_id',h.profile_id,'staff_no',h.staff_no,'first_name',h.first_name,'middle_name',h.middle_name,'last_name',h.last_name,'full_name',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name),'label',concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name)||' • '||h.staff_no::text,'phone',h.phone,'email',h.email,'active',h.active)
      order by lower(concat_ws(' ',h.first_name,nullif(h.middle_name,''),h.last_name)),h.staff_no::text)
      from public.headteachers h where h.deleted_at is null and h.active),'[]'::jsonb),
    'classes',coalesce((select jsonb_agg(to_jsonb(c) order by c.level_order,c.name) from public.classes c where c.deleted_at is null),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(to_jsonb(sub) order by sub.display_order,sub.name) from public.subjects sub where sub.deleted_at is null),'[]'::jsonb),
    'class_subjects',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'class_id',cs.class_id,'subject_id',cs.subject_id,'teacher_id',cs.teacher_id,'active',cs.active)) from public.class_subjects cs),'[]'::jsonb)
  );
end $$;

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
    ) order by lower(s.name)) from public.assessment_schemes s where s.deleted_at is null),'[]'::jsonb),
    'profiles',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'full_name',p.full_name,'role',public.current_app_role_for(p.role))
      order by lower(p.full_name),p.id) from public.profiles p where p.active),'[]'::jsonb),
    'teacher_records',coalesce((select jsonb_agg(jsonb_build_object(
      'id',t.id,
      'profile_id',t.profile_id,
      'staff_no',t.staff_no,
      'full_name',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name),
      'label',concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name)
        ||' • '||t.staff_no::text
        ||case when t.profile_id is null then ' • No linked account' else '' end,
      'active',t.active
    ) order by lower(concat_ws(' ',t.first_name,nullif(t.middle_name,''),t.last_name)),t.staff_no::text)
      from public.teachers t
      where t.deleted_at is null and t.active and t.employment_status='active'),'[]'::jsonb)
  );
end $$;

-- -----------------------------------------------------------------------------
-- 3. Promotion updates the student's active placement
-- -----------------------------------------------------------------------------
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
  source_enrollment_id uuid;
  enrollment_created boolean:=false;
  enrollment_withdrawn boolean:=false;
begin
  evaluation:=public.report_promotion_evaluation(target_report_id);
  eligible_for_promotion:=coalesce((evaluation->>'eligible')::boolean,false);
  should_apply_enrollment:=coalesce((evaluation->>'can_create_enrollment')::boolean,false);
  next_class_id:=public.safe_uuid(evaluation->>'next_class_id');
  target_year_id:=public.safe_uuid(evaluation->>'target_academic_year_id');

  select e.student_id,e.id into source_student_id,source_enrollment_id
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

      update public.enrollments
      set active=false,updated_at=now()
      where student_id=source_student_id
        and deleted_at is null
        and id<>coalesce((select id from public.enrollments where student_id=source_student_id and academic_year_id=target_year_id and deleted_at is null limit 1),'00000000-0000-0000-0000-000000000000'::uuid);
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

      if source_enrollment_id is not null then
        update public.enrollments
        set active=true,updated_at=now()
        where id=source_enrollment_id and deleted_at is null;
      end if;
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

-- Reconcile promotions already applied before this upgrade.
update public.enrollments source_e
set active=false,updated_at=now()
from public.student_reports r
join public.enrollments promoted_e
  on promoted_e.promotion_source_report_id=r.id
 and promoted_e.enrollment_origin='automatic_promotion'
 and promoted_e.deleted_at is null
 and promoted_e.active
where r.enrollment_id=source_e.id
  and source_e.deleted_at is null
  and source_e.id<>promoted_e.id
  and source_e.active;

-- -----------------------------------------------------------------------------
-- 4. Class-teacher attendance register and automatic report totals
-- -----------------------------------------------------------------------------
create table if not exists public.class_attendance_registers (
  id uuid primary key default gen_random_uuid(),
  term_id uuid not null references public.terms(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete restrict,
  attendance_date date not null,
  marked_by uuid not null references public.profiles(id) on delete restrict,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(term_id,class_id,attendance_date)
);

create table if not exists public.student_attendance_entries (
  id uuid primary key default gen_random_uuid(),
  register_id uuid not null references public.class_attendance_registers(id) on delete cascade,
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  attendance_status text not null default 'present' check(attendance_status in ('present','absent','late','excused')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(register_id,enrollment_id)
);

create index if not exists attendance_register_term_class_date_idx
  on public.class_attendance_registers(term_id,class_id,attendance_date);
create index if not exists attendance_entry_enrollment_idx
  on public.student_attendance_entries(enrollment_id,register_id);

alter table public.class_attendance_registers enable row level security;
alter table public.class_attendance_registers force row level security;
alter table public.student_attendance_entries enable row level security;
alter table public.student_attendance_entries force row level security;

revoke all on public.class_attendance_registers from anon,authenticated;
revoke all on public.student_attendance_entries from anon,authenticated;

create or replace function public.is_assigned_class_teacher(target_class_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.current_app_role()='class_teacher'
    and exists(
      select 1 from public.classes c
      where c.id=target_class_id
        and c.class_teacher_id=auth.uid()
        and c.active
        and c.deleted_at is null
    )
$$;

create or replace function public.attendance_counts_for_enrollment(target_enrollment_id uuid,target_term_id uuid)
returns table(days_school_opened integer,days_present integer)
language sql
stable
security definer
set search_path=public
as $$
  select count(r.id)::integer,
    count(a.id) filter(where a.attendance_status in ('present','late'))::integer
  from public.enrollments e
  join public.class_attendance_registers r on r.class_id=e.class_id and r.term_id=target_term_id
  left join public.student_attendance_entries a on a.register_id=r.id and a.enrollment_id=e.id
  where e.id=target_enrollment_id
$$;

create or replace function public.apply_attendance_totals_to_report()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare opened integer:=0;present integer:=0;
begin
  select c.days_school_opened,c.days_present into opened,present
  from public.attendance_counts_for_enrollment(new.enrollment_id,new.term_id) c;
  if coalesce(opened,0)>0 then
    new.days_school_opened:=opened;
    new.days_present:=least(coalesce(present,0),opened);
  end if;
  return new;
end $$;

drop trigger if exists student_report_attendance_totals on public.student_reports;
create trigger student_report_attendance_totals
before insert or update of enrollment_id,term_id,days_school_opened,days_present
on public.student_reports
for each row execute function public.apply_attendance_totals_to_report();

create or replace function public.sync_attendance_reports(target_term_id uuid,target_class_id uuid)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare affected integer:=0;
begin
  perform set_config('app.report_write','on',true);
  update public.student_reports r
  set days_school_opened=counts.days_school_opened,
      days_present=least(counts.days_present,counts.days_school_opened),
      updated_at=now()
  from public.enrollments e
  cross join lateral public.attendance_counts_for_enrollment(e.id,target_term_id) counts
  where r.enrollment_id=e.id
    and r.term_id=target_term_id
    and e.class_id=target_class_id
    and r.deleted_at is null
    and counts.days_school_opened>0;
  get diagnostics affected=row_count;
  return affected;
end $$;

create or replace function public.list_my_attendance_classes(target_term_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
begin
  if public.current_app_role()<>'class_teacher' then raise exception 'Only assigned class teachers can use attendance' using errcode='42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',c.id,'name',c.name,'level_order',c.level_order,
      'student_count',(select count(*) from public.enrollments e join public.students s on s.id=e.student_id and s.deleted_at is null and s.status='active'
        where e.class_id=c.id and e.deleted_at is null and (target_term_id is null or e.academic_year_id=(select t.academic_year_id from public.terms t where t.id=target_term_id)))
    ) order by c.level_order,c.name)
    from public.classes c
    where c.class_teacher_id=auth.uid() and c.active and c.deleted_at is null
  ),'[]'::jsonb);
end $$;

create or replace function public.get_class_attendance_register(
  target_term_id uuid,
  target_class_id uuid,
  target_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare target_year_id uuid;term_start date;term_end date;register_row public.class_attendance_registers%rowtype;
begin
  if not public.is_assigned_class_teacher(target_class_id) then raise exception 'You can mark attendance only for your assigned class' using errcode='42501'; end if;
  if target_term_id is null or target_date is null then raise exception 'Term and attendance date are required'; end if;
  select t.academic_year_id,t.start_date,t.end_date into target_year_id,term_start,term_end
  from public.terms t where t.id=target_term_id and t.deleted_at is null;
  if target_year_id is null then raise exception 'Term is unavailable'; end if;
  if term_start is not null and target_date<term_start then raise exception 'Attendance date is before the selected term'; end if;
  if term_end is not null and target_date>term_end then raise exception 'Attendance date is after the selected term'; end if;

  select * into register_row from public.class_attendance_registers r
  where r.term_id=target_term_id and r.class_id=target_class_id and r.attendance_date=target_date;

  return jsonb_build_object(
    'register',case when register_row.id is null then null else to_jsonb(register_row) end,
    'term',jsonb_build_object('id',target_term_id,'start_date',term_start,'end_date',term_end,'academic_year_id',target_year_id),
    'class',(select jsonb_build_object('id',c.id,'name',c.name) from public.classes c where c.id=target_class_id),
    'days_school_opened',(select count(*) from public.class_attendance_registers r where r.term_id=target_term_id and r.class_id=target_class_id),
    'students',coalesce((
      select jsonb_agg(jsonb_build_object(
        'enrollment_id',e.id,'student_id',s.id,'admission_no',s.admission_no,
        'first_name',s.first_name,'middle_name',s.middle_name,'last_name',s.last_name,
        'full_name',concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name),
        'roll_number',e.roll_number,
        'attendance_status',coalesce(a.attendance_status,'present'),
        'days_present',counts.days_present,
        'days_school_opened',counts.days_school_opened
      ) order by lower(concat_ws(' ',s.first_name,nullif(s.middle_name,''),s.last_name)),s.admission_no::text)
      from public.enrollments e
      join public.students s on s.id=e.student_id and s.deleted_at is null and s.status='active'
      left join public.student_attendance_entries a on a.register_id=register_row.id and a.enrollment_id=e.id
      cross join lateral public.attendance_counts_for_enrollment(e.id,target_term_id) counts
      where e.academic_year_id=target_year_id
        and e.class_id=target_class_id
        and e.deleted_at is null
    ),'[]'::jsonb)
  );
end $$;

create or replace function public.save_class_attendance(
  target_term_id uuid,
  target_class_id uuid,
  target_date date,
  entries jsonb,
  notes_text text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare target_year_id uuid;term_start date;term_end date;target_register_id uuid;expected_count integer;provided_count integer;distinct_count integer;invalid_count integer;
begin
  if not public.is_assigned_class_teacher(target_class_id) then raise exception 'You can mark attendance only for your assigned class' using errcode='42501'; end if;
  if target_term_id is null or target_date is null then raise exception 'Term and attendance date are required'; end if;
  if entries is null or jsonb_typeof(entries)<>'array' then raise exception 'Attendance entries must be supplied as a list'; end if;

  select t.academic_year_id,t.start_date,t.end_date into target_year_id,term_start,term_end
  from public.terms t where t.id=target_term_id and t.deleted_at is null;
  if target_year_id is null then raise exception 'Term is unavailable'; end if;
  if term_start is not null and target_date<term_start then raise exception 'Attendance date is before the selected term'; end if;
  if term_end is not null and target_date>term_end then raise exception 'Attendance date is after the selected term'; end if;
  if target_date>current_date then raise exception 'Attendance cannot be marked for a future date'; end if;

  select count(*) into expected_count
  from public.enrollments e join public.students s on s.id=e.student_id and s.deleted_at is null and s.status='active'
  where e.academic_year_id=target_year_id and e.class_id=target_class_id and e.deleted_at is null;
  if expected_count=0 then raise exception 'No students are enrolled in this class for the selected term'; end if;

  select count(*),count(distinct public.safe_uuid(item->>'enrollment_id')) into provided_count,distinct_count
  from jsonb_array_elements(entries) item;
  if provided_count<>expected_count or distinct_count<>provided_count then
    raise exception 'Attendance must include each student exactly once';
  end if;

  select count(*) into invalid_count
  from jsonb_array_elements(entries) item
  left join public.enrollments e on e.id=public.safe_uuid(item->>'enrollment_id')
  left join public.students s on s.id=e.student_id
  where public.safe_uuid(item->>'enrollment_id') is null
     or coalesce(item->>'attendance_status','') not in ('present','absent','late','excused')
     or e.id is null or e.deleted_at is not null
     or e.academic_year_id<>target_year_id or e.class_id<>target_class_id
     or s.id is null or s.deleted_at is not null or s.status<>'active';
  if invalid_count>0 then raise exception 'One or more attendance entries are invalid or outside the assigned class'; end if;

  perform set_config('app.change_reason','Class attendance marked',true);
  insert into public.class_attendance_registers(term_id,class_id,attendance_date,marked_by,notes,updated_at)
  values(target_term_id,target_class_id,target_date,auth.uid(),coalesce(notes_text,''),now())
  on conflict(term_id,class_id,attendance_date) do update
    set marked_by=auth.uid(),notes=excluded.notes,updated_at=now()
  returning id into target_register_id;

  insert into public.student_attendance_entries(register_id,enrollment_id,attendance_status,updated_at)
  select target_register_id,public.safe_uuid(item->>'enrollment_id'),item->>'attendance_status',now()
  from jsonb_array_elements(entries) item
  on conflict(register_id,enrollment_id) do update
    set attendance_status=excluded.attendance_status,updated_at=now();

  delete from public.student_attendance_entries a
  where a.register_id=target_register_id
    and not exists(select 1 from jsonb_array_elements(entries) item where public.safe_uuid(item->>'enrollment_id')=a.enrollment_id);

  perform public.sync_attendance_reports(target_term_id,target_class_id);
  return public.get_class_attendance_register(target_term_id,target_class_id,target_date);
end $$;

-- Apply timestamps and audit logging where the shared trigger functions exist.
do $$
begin
  if to_regprocedure('public.set_updated_at()') is not null then
    execute 'drop trigger if exists attendance_register_updated_at on public.class_attendance_registers';
    execute 'create trigger attendance_register_updated_at before update on public.class_attendance_registers for each row execute function public.set_updated_at()';
    execute 'drop trigger if exists attendance_entry_updated_at on public.student_attendance_entries';
    execute 'create trigger attendance_entry_updated_at before update on public.student_attendance_entries for each row execute function public.set_updated_at()';
  end if;
end $$;

revoke all on function public.is_assigned_class_teacher(uuid) from public,anon,authenticated;
revoke all on function public.attendance_counts_for_enrollment(uuid,uuid) from public,anon,authenticated;
revoke all on function public.apply_attendance_totals_to_report() from public,anon,authenticated;
revoke all on function public.sync_attendance_reports(uuid,uuid) from public,anon,authenticated;
revoke all on function public.list_my_attendance_classes(uuid) from public,anon;
revoke all on function public.get_class_attendance_register(uuid,uuid,date) from public,anon;
revoke all on function public.save_class_attendance(uuid,uuid,date,jsonb,text) from public,anon;

grant execute on function public.list_my_attendance_classes(uuid) to authenticated;
grant execute on function public.get_class_attendance_register(uuid,uuid,date) to authenticated;
grant execute on function public.save_class_attendance(uuid,uuid,date,jsonb,text) to authenticated;

-- Verification marker.
do $$
begin
  if to_regclass('public.class_attendance_registers') is null
     or to_regclass('public.student_attendance_entries') is null
     or to_regprocedure('public.save_class_attendance(uuid,uuid,date,jsonb,text)') is null
     or to_regprocedure('public.get_class_attendance_register(uuid,uuid,date)') is null then
    raise exception 'v6.8.0 attendance upgrade verification failed';
  end if;
end $$;

commit;

select '06 SCHEMA: PASS' as status;
