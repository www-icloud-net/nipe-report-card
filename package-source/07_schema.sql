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

