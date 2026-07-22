-- REPORT CARD ENTERPRISE v6.9.0
-- ONE-TIME PLATFORM SUPER ADMINISTRATOR ACCOUNT SETUP
--
-- 1. Apply the v6.9.0 continuation in 07_schema.sql first.
-- 2. In Supabase Authentication > Users, create a SEPARATE user for the
--    software owner/platform administrator and confirm the email.
-- 3. Replace the placeholder below with that exact email address.
-- 4. Run this file in the Supabase SQL Editor.
-- 5. Sign in with the new account and complete mandatory MFA enrolment.
--
-- Do not convert the school's only System Administrator account. Platform and
-- school administration must remain separate.

begin;

do $$
declare
  target_email text:='REPLACE_WITH_PLATFORM_ADMIN_EMAIL';
  target_user auth.users%rowtype;
  display_name text;
  license_id_value uuid;
begin
  if target_email='REPLACE_WITH_PLATFORM_ADMIN_EMAIL' or position('@' in target_email)=0 then
    raise exception 'Replace REPLACE_WITH_PLATFORM_ADMIN_EMAIL with the exact Supabase Auth user email';
  end if;

  select * into target_user
  from auth.users
  where lower(email)=lower(trim(target_email))
  order by created_at desc
  limit 1;

  if target_user.id is null then
    raise exception 'No Supabase Authentication user was found for %',target_email;
  end if;

  if exists(
    select 1 from public.teachers t where t.profile_id=target_user.id and t.deleted_at is null
    union all
    select 1 from public.headteachers h where h.profile_id=target_user.id and h.deleted_at is null
  ) then
    raise exception 'Use a separate Auth account that is not linked to a teacher or Principal record';
  end if;

  display_name:=coalesce(
    nullif(trim(target_user.raw_user_meta_data->>'full_name'),''),
    nullif(split_part(coalesce(target_user.email,''),'@',1),''),
    'Platform Super Administrator'
  );

  insert into public.profiles(id,full_name,role,active,mfa_required,must_change_password,phone,created_at,updated_at)
  values(target_user.id,display_name,'platform_super_admin',true,true,false,'',now(),now())
  on conflict(id) do update set
    full_name=case when trim(public.profiles.full_name)='' then excluded.full_name else public.profiles.full_name end,
    role='platform_super_admin',
    active=true,
    mfa_required=true,
    must_change_password=false,
    updated_at=now();

  update auth.users
  set raw_app_meta_data=jsonb_set(coalesce(raw_app_meta_data,'{}'::jsonb),'{role}',to_jsonb('platform_super_admin'::text),true),
      updated_at=now()
  where id=target_user.id;

  select id into license_id_value from public.school_licenses order by created_at limit 1;
  insert into public.license_events(license_id,event_type,actor_id,event_reason,new_data)
  values(license_id_value,'platform_admin_provisioned',target_user.id,
    'Platform Super Administrator account provisioned through the protected setup script',
    jsonb_build_object('profile_id',target_user.id,'email',target_user.email,'mfa_required',true));
end $$;

commit;

select p.id,p.full_name,p.role,p.active,p.mfa_required,u.email
from public.profiles p
join auth.users u on u.id=p.id
where p.role='platform_super_admin'
order by lower(p.full_name),p.id;
