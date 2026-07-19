-- =====================================================================
-- ولاء | ترقية SaaS متعددة الجمعيات — الإصدار 3.0
-- المتطلبات: schema.sql ثم ملفات Campaign Intelligence حتى v2.4.
-- شغّل هذا الملف مرة واحدة على المشروع القائم بعد أخذ نسخة احتياطية.
-- يحافظ على البيانات الحالية وينسبها تلقائياً إلى «الجهة الحالية».
-- =====================================================================

begin;
set local statement_timeout = '0';

create extension if not exists pgcrypto;
create schema if not exists app_private;
revoke all on schema app_private from public, anon;

-- ---------------------------------------------------------------------
-- الجهات والعضويات ومديرو المنصة
-- ---------------------------------------------------------------------
create table if not exists public.organizations (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  slug                  text not null unique,
  contact_email         text,
  subscription_ends_at  date,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint organizations_name_not_blank check (btrim(name) <> ''),
  constraint organizations_slug_format check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$')
);

create table if not exists public.platform_admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

create table if not exists public.organization_members (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  user_id          uuid not null references auth.users(id) on delete cascade,
  role             text not null default 'member',
  allowed_pages    text[] not null default array['dashboard']::text[],
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint organization_members_role check (role in ('owner','admin','member')),
  constraint organization_members_pages check (
    allowed_pages <@ array[
      'dashboard','reports','targets','donors','operations',
      'campaign_analysis','campaign_targets','marketing_content','settings'
    ]::text[]
  ),
  constraint organization_members_one_org_per_user unique (user_id),
  constraint organization_members_org_user unique (organization_id, user_id)
);

create index if not exists idx_organization_members_org on public.organization_members (organization_id);

-- رمز MCP لا يُحفظ كنص صريح؛ المحفوظ هو SHA-256 فقط.
create table if not exists public.mcp_access_tokens (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  user_id          uuid references auth.users(id) on delete cascade,
  name             text not null,
  token_hash       text not null unique,
  token_prefix     text not null,
  allowed_tools    text[] not null default array[
    'get_dashboard_summary','search_donors','get_donor_profile',
    'search_operations','list_campaigns','get_campaign_analysis','list_projects'
  ]::text[],
  expires_at       timestamptz,
  last_used_at     timestamptz,
  revoked_at       timestamptz,
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  constraint mcp_access_tokens_name_not_blank check (btrim(name) <> '')
);

create index if not exists idx_mcp_tokens_org on public.mcp_access_tokens (organization_id, revoked_at);

create table if not exists public.mcp_audit_logs (
  id               bigint generated always as identity primary key,
  token_id         uuid references public.mcp_access_tokens(id) on delete set null,
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  user_id          uuid references auth.users(id) on delete set null,
  tool_name        text,
  request_id       text,
  status           text not null,
  duration_ms      integer,
  error_message    text,
  created_at       timestamptz not null default now()
);

create index if not exists idx_mcp_audit_org_date on public.mcp_audit_logs (organization_id, created_at desc);

-- أول جهة تحفظ كل البيانات القديمة. أول حساب Auth يصبح مدير المنصة.
insert into public.organizations (name, slug, contact_email, subscription_ends_at, is_active)
select
  'الجهة الحالية',
  'current-organization',
  (select email from auth.users order by created_at limit 1),
  null,
  true
where not exists (select 1 from public.organizations);

insert into public.platform_admins (user_id)
select id from auth.users order by created_at limit 1
on conflict (user_id) do nothing;

insert into public.organization_members (organization_id, user_id, role, allowed_pages, is_active)
select
  (select id from public.organizations order by created_at limit 1),
  u.id,
  case when u.id = (select id from auth.users order by created_at limit 1) then 'owner' else 'member' end,
  array['dashboard','reports','targets','donors','operations','campaign_analysis','campaign_targets','marketing_content','settings']::text[],
  true
from auth.users u
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------
-- دوال الهوية: في مخطط غير مكشوف، وبحث مؤهل بالكامل.
-- ---------------------------------------------------------------------
create or replace function app_private.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.platform_admins pa
    where pa.user_id = (select auth.uid())
  );
$$;

create or replace function app_private.current_organization_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.organization_id
  from public.organization_members m
  where m.user_id = (select auth.uid())
    and m.is_active
  limit 1;
$$;

create or replace function app_private.can_access_organization(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_members m
    join public.organizations o on o.id = m.organization_id
    where m.user_id = (select auth.uid())
      and m.organization_id = p_organization_id
      and m.is_active
      and o.is_active
      and (o.subscription_ends_at is null or o.subscription_ends_at >= (now() at time zone 'Asia/Riyadh')::date)
  );
$$;

revoke all on function app_private.is_platform_admin() from public, anon;
revoke all on function app_private.current_organization_id() from public, anon;
revoke all on function app_private.can_access_organization(uuid) from public, anon;
grant usage on schema app_private to authenticated, service_role;
grant execute on function app_private.is_platform_admin() to authenticated, service_role;
grant execute on function app_private.current_organization_id() to authenticated, service_role;
grant execute on function app_private.can_access_organization(uuid) to authenticated, service_role;

create or replace function public.get_my_access_context()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with member_row as (
    select m.*, o.name, o.slug, o.contact_email, o.subscription_ends_at, o.is_active as organization_active
    from public.organization_members m
    join public.organizations o on o.id = m.organization_id
    where m.user_id = (select auth.uid())
    limit 1
  )
  select jsonb_build_object(
    'is_platform_admin', app_private.is_platform_admin(),
    'role', mr.role,
    'allowed_pages', case when mr.is_active then coalesce(to_jsonb(mr.allowed_pages), '[]'::jsonb) else '[]'::jsonb end,
    'subscription_valid', coalesce(
      mr.is_active and mr.organization_active
      and (mr.subscription_ends_at is null or mr.subscription_ends_at >= (now() at time zone 'Asia/Riyadh')::date),
      false
    ),
    'organization', case when mr.organization_id is null then null else jsonb_build_object(
      'id', mr.organization_id,
      'name', mr.name,
      'slug', mr.slug,
      'contact_email', mr.contact_email,
      'subscription_ends_at', mr.subscription_ends_at,
      'is_active', mr.organization_active
    ) end
  )
  from (select 1) seed
  left join member_row mr on true;
$$;

revoke all on function public.get_my_access_context() from public, anon;
grant execute on function public.get_my_access_context() to authenticated;

-- ---------------------------------------------------------------------
-- إضافة organization_id وترحيل البيانات الحالية دون حذفها.
-- ---------------------------------------------------------------------
alter table public.operations add column if not exists organization_id uuid references public.organizations(id);
alter table public.campaign_targets add column if not exists organization_id uuid references public.organizations(id);
alter table public.donors add column if not exists organization_id uuid references public.organizations(id);
alter table public.settings add column if not exists organization_id uuid references public.organizations(id);
alter table public.donor_rebuild_keys add column if not exists organization_id uuid references public.organizations(id);
alter table public.monthly_targets add column if not exists organization_id uuid references public.organizations(id);
alter table public.daily_targets add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_platforms add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_projects add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_contents add column if not exists organization_id uuid references public.organizations(id);
alter table public.referral_code_costs add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_campaigns add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_campaign_costs add column if not exists organization_id uuid references public.organizations(id);
alter table public.campaign_operation_facts add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_campaign_analysis_cache add column if not exists organization_id uuid references public.organizations(id);

do $$
declare
  v_org uuid;
  v_table text;
begin
  select id into v_org from public.organizations order by created_at limit 1;
  foreach v_table in array array[
    'operations','campaign_targets','donors','settings','donor_rebuild_keys',
    'monthly_targets','daily_targets','marketing_platforms','marketing_projects',
    'marketing_contents','referral_code_costs','marketing_campaigns',
    'marketing_campaign_costs','campaign_operation_facts','marketing_campaign_analysis_cache'
  ] loop
    execute format('update public.%I set organization_id = $1 where organization_id is null', v_table) using v_org;
    execute format('alter table public.%I alter column organization_id set default app_private.current_organization_id()', v_table);
    execute format('alter table public.%I alter column organization_id set not null', v_table);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- دوال الكتابة ذات مفاتيح مركبة بالجمعية.
-- ---------------------------------------------------------------------
create or replace function public.upsert_operations(rows jsonb)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  affected integer;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;

  with incoming0 as (
    select
      nullif(r->>'line_no','')::bigint as line_no,
      nullif(r->>'operation_no','')::bigint as operation_no,
      nullif(r->>'donor_name','') as donor_name,
      nullif(r->>'phone_raw','') as phone_raw,
      nullif(r->>'project','') as project,
      nullif(r->>'referral_code','') as referral_code,
      nullif(r->>'value','')::numeric as value,
      nullif(r->>'quantity','')::numeric as quantity,
      nullif(r->>'total','')::numeric as total,
      nullif(r->>'op_datetime','')::timestamptz as op_datetime
    from jsonb_array_elements(rows) as r
    where nullif(r->>'line_no','') is not null
      and nullif(r->>'operation_no','') is not null
  ), incoming as (
    select i.*, public.operation_phone_info(i.phone_raw, i.line_no, i.operation_no) as ph
    from incoming0 i
  ), deduped as (
    select distinct on (line_no, operation_no)
      line_no, operation_no, donor_name, phone_raw, ph,
      project, referral_code, value, quantity, total, op_datetime
    from incoming
    order by line_no, operation_no, op_datetime desc nulls last
  ), ins as (
    insert into public.operations (
      organization_id, line_no, operation_no, donor_name, phone_raw, phone, phone_status, phone_issue,
      project, referral_code, value, quantity, total, op_datetime, updated_at
    )
    select
      v_org, line_no, operation_no, donor_name, phone_raw,
      ph->>'phone', ph->>'status', ph->>'issue',
      project, referral_code, value, quantity, total, op_datetime, now()
    from deduped
    on conflict (organization_id, line_no, operation_no) do update set
      donor_name = excluded.donor_name,
      phone_raw = excluded.phone_raw,
      phone = excluded.phone,
      phone_status = excluded.phone_status,
      phone_issue = excluded.phone_issue,
      project = excluded.project,
      referral_code = excluded.referral_code,
      value = excluded.value,
      quantity = excluded.quantity,
      total = excluded.total,
      op_datetime = excluded.op_datetime,
      updated_at = now()
    returning 1
  )
  select count(*) into affected from ins;
  return affected;
end;
$$;

create or replace function public.insert_campaign_targets(rows jsonb)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  affected integer;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;

  with incoming as (
    select
      nullif(r->>'phone_raw','') as phone_raw,
      public.clean_phone(r->>'phone_raw') as phone,
      nullif(r->>'campaign_name','') as campaign_name,
      nullif(r->>'target_date','')::timestamptz as target_date
    from jsonb_array_elements(rows) as r
  ), valid as (
    select
      phone_raw, phone, campaign_name, target_date,
      md5(concat_ws('|', coalesce(phone, ''), lower(btrim(coalesce(campaign_name, ''))),
        coalesce(to_char(target_date at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'), ''))) as target_key
    from incoming where phone is not null
  ), deduped as (
    select distinct on (target_key) phone_raw, phone, campaign_name, target_date, target_key
    from valid order by target_key
  ), ins as (
    insert into public.campaign_targets (
      organization_id, phone_raw, phone, campaign_name, target_date, target_key
    )
    select v_org, phone_raw, phone, campaign_name, target_date, target_key
    from deduped
    on conflict (organization_id, target_key) do update set
      phone_raw = excluded.phone_raw,
      phone = excluded.phone,
      campaign_name = excluded.campaign_name,
      target_date = excluded.target_date
    returning 1
  )
  select count(*) into affected from ins;
  return affected;
end;
$$;

create or replace function public.donor_rebuild_start()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  v_total integer;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  delete from public.donor_rebuild_keys where organization_id = v_org;
  insert into public.donor_rebuild_keys (organization_id, phone)
  select v_org, o.phone
  from public.operations o
  where o.organization_id = v_org and o.phone is not null
  group by o.phone;
  get diagnostics v_total = row_count;
  return coalesce(v_total, 0);
end;
$$;

create or replace function public.donor_rebuild_start_for_phones(p_phones text[])
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  v_total integer;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  if p_phones is not null and array_length(p_phones, 1) is not null then
    insert into public.donor_rebuild_keys (organization_id, phone)
    select v_org, btrim(p)
    from unnest(p_phones) as p
    where btrim(coalesce(p, '')) <> ''
    group by btrim(p)
    on conflict (organization_id, phone) do nothing;
  end if;
  select count(*)::integer into v_total
  from public.donor_rebuild_keys where organization_id = v_org;
  return coalesce(v_total, 0);
end;
$$;

create or replace function public.donor_rebuild_chunk(p_limit integer default 300, p_cleanup boolean default true)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  v_processed integer := 0;
  v_remaining integer := 0;
  v_inactive_days integer := 90;
  v_response_days integer := 30;
  v_categories jsonb := '[]'::jsonb;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  if p_limit is null or p_limit <= 0 then p_limit := 300; end if;

  select coalesce(s.inactive_days, 90), coalesce(s.response_days, 30), coalesce(s.categories, '[]'::jsonb)
  into v_inactive_days, v_response_days, v_categories
  from public.settings s
  where s.organization_id = v_org and s.id = 1;

  with batch as (
    select k.phone
    from public.donor_rebuild_keys k
    where k.organization_id = v_org
    order by k.phone
    limit p_limit
  ), target_agg as (
    select ct.phone, count(*)::integer as targeted_count, max(ct.target_date) as last_targeted
    from public.campaign_targets ct
    join batch b on b.phone = ct.phone
    where ct.organization_id = v_org and ct.phone is not null
    group by ct.phone
  ), resp as (
    select t.phone, t.last_targeted, min(o.op_datetime) as first_after
    from target_agg t
    join public.operations o
      on o.organization_id = v_org
     and o.phone = t.phone
     and o.op_datetime is not null
     and t.last_targeted is not null
     and o.op_datetime > t.last_targeted
    group by t.phone, t.last_targeted
  ), agg as (
    select
      o.phone,
      (array_agg(o.phone_raw order by o.op_datetime desc nulls last, o.updated_at desc nulls last, o.id desc))[1] as phone_raw,
      (array_agg(coalesce(o.phone_status, 'صحيح') order by o.op_datetime desc nulls last, o.updated_at desc nulls last, o.id desc))[1] as phone_status,
      (array_agg(o.phone_issue order by o.op_datetime desc nulls last, o.updated_at desc nulls last, o.id desc))[1] as phone_issue,
      (array_agg(o.donor_name order by o.op_datetime desc nulls last, o.updated_at desc nulls last, o.id desc))[1] as donor_name,
      min(o.op_datetime) as first_donation,
      max(o.op_datetime) as last_donation,
      coalesce(sum(o.total), 0) as total_amount,
      count(distinct o.operation_no)::integer as donations_count,
      array_remove(array_agg(distinct nullif(btrim(o.project), '')), null)::text[] as projects,
      count(distinct o.operation_no) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 6)::integer as sat_count,
      count(distinct o.operation_no) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 0)::integer as sun_count,
      count(distinct o.operation_no) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 1)::integer as mon_count,
      count(distinct o.operation_no) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 2)::integer as tue_count,
      count(distinct o.operation_no) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 3)::integer as wed_count,
      count(distinct o.operation_no) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 4)::integer as thu_count,
      count(distinct o.operation_no) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 5)::integer as fri_count,
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int between 4 and 11)::integer as period_morning,
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int between 12 and 15)::integer as period_noon,
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int between 16 and 18)::integer as period_evening,
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 19 or extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 4)::integer as period_night,
      count(distinct o.operation_no) filter (where o.op_datetime is null)::integer as no_time_count
    from public.operations o
    join batch b on b.phone = o.phone
    where o.organization_id = v_org and o.phone is not null
    group by o.phone
  ), upserted as (
    insert into public.donors (
      organization_id, phone, phone_raw, phone_status, phone_issue, donor_name,
      first_donation, last_donation, total_amount, donations_count, projects,
      sat_count, sun_count, mon_count, tue_count, wed_count, thu_count, fri_count,
      period_morning, period_noon, period_evening, period_night, no_time_count,
      targeted_count, last_targeted, responded, response_date, response_lag_days,
      status, category, updated_at
    )
    select
      v_org, a.phone, a.phone_raw, a.phone_status, a.phone_issue, a.donor_name,
      a.first_donation, a.last_donation, a.total_amount, a.donations_count,
      coalesce(a.projects, array[]::text[]),
      coalesce(a.sat_count,0), coalesce(a.sun_count,0), coalesce(a.mon_count,0),
      coalesce(a.tue_count,0), coalesce(a.wed_count,0), coalesce(a.thu_count,0), coalesce(a.fri_count,0),
      coalesce(a.period_morning,0), coalesce(a.period_noon,0), coalesce(a.period_evening,0),
      coalesce(a.period_night,0), coalesce(a.no_time_count,0),
      coalesce(t.targeted_count,0), t.last_targeted,
      coalesce(r.first_after <= t.last_targeted + (v_response_days || ' days')::interval, false),
      case when r.first_after <= t.last_targeted + (v_response_days || ' days')::interval then r.first_after end,
      case when r.first_after <= t.last_targeted + (v_response_days || ' days')::interval
        then greatest(0, (extract(epoch from (r.first_after - t.last_targeted)) / 86400)::int) end,
      case when a.last_donation is not null and a.last_donation >= now() - (v_inactive_days || ' days')::interval then 'مستمر' else 'خامل' end,
      (
        select c->>'name'
        from jsonb_array_elements(v_categories) c
        where a.donations_count >= coalesce((c->>'min')::int,0)
          and (c->>'max' is null or c->>'max' = 'null' or a.donations_count <= (c->>'max')::int)
        order by coalesce((c->>'min')::int,0) desc limit 1
      ),
      now()
    from agg a
    left join target_agg t on t.phone = a.phone
    left join resp r on r.phone = a.phone
    on conflict (organization_id, phone) do update set
      phone_raw=excluded.phone_raw, phone_status=excluded.phone_status, phone_issue=excluded.phone_issue,
      donor_name=excluded.donor_name, first_donation=excluded.first_donation, last_donation=excluded.last_donation,
      total_amount=excluded.total_amount, donations_count=excluded.donations_count, projects=excluded.projects,
      sat_count=excluded.sat_count, sun_count=excluded.sun_count, mon_count=excluded.mon_count,
      tue_count=excluded.tue_count, wed_count=excluded.wed_count, thu_count=excluded.thu_count, fri_count=excluded.fri_count,
      period_morning=excluded.period_morning, period_noon=excluded.period_noon,
      period_evening=excluded.period_evening, period_night=excluded.period_night, no_time_count=excluded.no_time_count,
      targeted_count=excluded.targeted_count, last_targeted=excluded.last_targeted,
      responded=excluded.responded, response_date=excluded.response_date, response_lag_days=excluded.response_lag_days,
      status=excluded.status, category=excluded.category, updated_at=now()
    returning phone
  ), deleted as (
    delete from public.donor_rebuild_keys k
    using batch b
    where k.organization_id = v_org and k.phone = b.phone
    returning k.phone
  )
  select count(*)::integer into v_processed from deleted;

  select count(*)::integer into v_remaining
  from public.donor_rebuild_keys where organization_id = v_org;

  if v_remaining = 0 and p_cleanup then
    delete from public.donors d
    where d.organization_id = v_org
      and not exists (
        select 1 from public.operations o
        where o.organization_id = v_org and o.phone = d.phone
      );
  end if;

  return jsonb_build_object('processed', coalesce(v_processed,0), 'remaining', coalesce(v_remaining,0));
end;
$$;

create or replace function public.save_monthly_target(
  p_month_key text,
  p_default_daily numeric,
  p_season_override text default null
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare v_org uuid := app_private.current_organization_id();
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  insert into public.monthly_targets (organization_id, month_key, default_daily, season_override, updated_at)
  values (v_org, p_month_key, coalesce(p_default_daily,0), nullif(btrim(p_season_override),''), now())
  on conflict (organization_id, month_key) do update set
    default_daily=excluded.default_daily,
    season_override=excluded.season_override,
    updated_at=now();
end;
$$;

create or replace function public.save_daily_target(
  p_day date,
  p_target numeric default null,
  p_deduction numeric default 0,
  p_note text default null
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare v_org uuid := app_private.current_organization_id();
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  insert into public.daily_targets (organization_id, day_date, target_value, deduction, note, updated_at)
  values (v_org, p_day, p_target, coalesce(p_deduction,0), nullif(btrim(p_note),''), now())
  on conflict (organization_id, day_date) do update set
    target_value=excluded.target_value,
    deduction=excluded.deduction,
    note=excluded.note,
    updated_at=now();
end;
$$;

create or replace function public.save_referral_code_cost(
  p_referral_code text,
  p_cost numeric,
  p_note text default null
)
returns public.referral_code_costs
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  v_code text := nullif(btrim(p_referral_code),'');
  result public.referral_code_costs;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  if v_code is null then raise exception 'كود الإحالة مطلوب'; end if;
  if p_cost is null or p_cost < 0 then raise exception 'التكلفة يجب أن تكون أكبر من أو تساوي صفر'; end if;

  insert into public.referral_code_costs (organization_id, referral_code, cost, note, updated_at)
  values (v_org, v_code, p_cost, p_note, now())
  on conflict (organization_id, referral_code) do update set
    cost=excluded.cost, note=excluded.note, updated_at=now()
  returning * into result;
  return result;
end;
$$;

-- ---------------------------------------------------------------------
-- Cache العمليات: المفتاح (الجمعية، رقم العملية).
-- ---------------------------------------------------------------------
drop trigger if exists trg_sync_campaign_operation_fact on public.operations;
drop function if exists public.refresh_campaign_operation_fact(bigint);
drop function if exists public.sync_campaign_operation_fact_trigger();

truncate table public.campaign_operation_facts;
insert into public.campaign_operation_facts (
  organization_id, operation_no, op_datetime, op_date, total_amount, phone, codes, projects, updated_at
)
select
  o.organization_id,
  o.operation_no,
  min(o.op_datetime),
  (min(o.op_datetime) at time zone 'Asia/Riyadh')::date,
  coalesce(sum(o.total),0)::numeric,
  max(o.phone) filter (
    where o.phone is not null and o.phone not like 'INVALID:%' and o.phone not like 'EMPTY:%'
      and coalesce(o.phone_status,'صحيح')='صحيح'
  ),
  array_remove(array_agg(distinct nullif(btrim(o.referral_code),'')),null)::text[],
  array_remove(array_agg(distinct nullif(btrim(o.project),'')),null)::text[],
  now()
from public.operations o
group by o.organization_id, o.operation_no;

create or replace function app_private.refresh_campaign_operation_fact(p_org uuid, p_operation_no bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_org is null or p_operation_no is null then return; end if;
  if not exists (
    select 1 from public.operations o
    where o.organization_id=p_org and o.operation_no=p_operation_no
  ) then
    delete from public.campaign_operation_facts f
    where f.organization_id=p_org and f.operation_no=p_operation_no;
    return;
  end if;

  insert into public.campaign_operation_facts (
    organization_id, operation_no, op_datetime, op_date, total_amount, phone, codes, projects, updated_at
  )
  select
    p_org, o.operation_no, min(o.op_datetime),
    (min(o.op_datetime) at time zone 'Asia/Riyadh')::date,
    coalesce(sum(o.total),0)::numeric,
    max(o.phone) filter (
      where o.phone is not null and o.phone not like 'INVALID:%' and o.phone not like 'EMPTY:%'
        and coalesce(o.phone_status,'صحيح')='صحيح'
    ),
    array_remove(array_agg(distinct nullif(btrim(o.referral_code),'')),null)::text[],
    array_remove(array_agg(distinct nullif(btrim(o.project),'')),null)::text[], now()
  from public.operations o
  where o.organization_id=p_org and o.operation_no=p_operation_no
  group by o.operation_no
  on conflict (organization_id, operation_no) do update set
    op_datetime=excluded.op_datetime, op_date=excluded.op_date,
    total_amount=excluded.total_amount, phone=excluded.phone,
    codes=excluded.codes, projects=excluded.projects, updated_at=now();
end;
$$;

create or replace function app_private.sync_campaign_operation_fact_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op='DELETE' then
    perform app_private.refresh_campaign_operation_fact(old.organization_id, old.operation_no);
    return old;
  end if;
  if tg_op='UPDATE' and (
    old.organization_id is distinct from new.organization_id
    or old.operation_no is distinct from new.operation_no
  ) then
    perform app_private.refresh_campaign_operation_fact(old.organization_id, old.operation_no);
  end if;
  perform app_private.refresh_campaign_operation_fact(new.organization_id, new.operation_no);
  return new;
end;
$$;

create trigger trg_sync_campaign_operation_fact
after insert or update or delete on public.operations
for each row execute function app_private.sync_campaign_operation_fact_trigger();
revoke all on function app_private.refresh_campaign_operation_fact(uuid,bigint) from public, anon, authenticated;
revoke all on function app_private.sync_campaign_operation_fact_trigger() from public, anon, authenticated;

-- Cache نتائج الحملات يحمل organization_id حتى في الدوال ذات الامتياز.
create or replace function public.mark_campaign_analysis_stale_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := case when tg_op='DELETE' then old.id else new.id end;
  v_org uuid := case when tg_op='DELETE' then old.organization_id else new.organization_id end;
begin
  if v_id is null or not exists (
    select 1 from public.marketing_campaigns c where c.id=v_id and c.organization_id=v_org
  ) then return case when tg_op='DELETE' then old else new end; end if;
  insert into public.marketing_campaign_analysis_cache (organization_id,campaign_id,is_stale,updated_at)
  values (v_org,v_id,true,now())
  on conflict (campaign_id) do update set
    organization_id=excluded.organization_id,is_stale=true,updated_at=now();
  return case when tg_op='DELETE' then old else new end;
end;
$$;

create or replace function public.mark_campaign_cost_analysis_stale_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := case when tg_op='DELETE' then old.campaign_id else new.campaign_id end;
  v_org uuid := case when tg_op='DELETE' then old.organization_id else new.organization_id end;
begin
  if v_id is null or not exists (
    select 1 from public.marketing_campaigns c where c.id=v_id and c.organization_id=v_org
  ) then return case when tg_op='DELETE' then old else new end; end if;
  insert into public.marketing_campaign_analysis_cache (organization_id,campaign_id,is_stale,updated_at)
  values (v_org,v_id,true,now())
  on conflict (campaign_id) do update set
    organization_id=excluded.organization_id,is_stale=true,updated_at=now();
  return case when tg_op='DELETE' then old else new end;
end;
$$;

revoke execute on function public.mark_campaign_analysis_stale_trigger() from public, anon, authenticated;
revoke execute on function public.mark_campaign_cost_analysis_stale_trigger() from public, anon, authenticated;

-- ملخص خاص ببوابة MCP، ولا يمكن استدعاؤه إلا بمفتاح service_role داخل Edge Function.
create or replace function public.mcp_organization_summary(p_organization_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'organization_id', p_organization_id,
    'operations_rows', (select count(*) from public.operations o where o.organization_id=p_organization_id),
    'donations_count', (select count(distinct o.operation_no) from public.operations o where o.organization_id=p_organization_id),
    'total_amount', (select coalesce(sum(o.total),0) from public.operations o where o.organization_id=p_organization_id),
    'donors_count', (select count(*) from public.donors d where d.organization_id=p_organization_id),
    'active_donors', (select count(*) from public.donors d where d.organization_id=p_organization_id and d.status='مستمر'),
    'campaigns_count', (select count(*) from public.marketing_campaigns c where c.organization_id=p_organization_id),
    'last_operation_at', (select max(o.op_datetime) from public.operations o where o.organization_id=p_organization_id)
  );
$$;

revoke all on function public.mcp_organization_summary(uuid) from public, anon, authenticated;
grant execute on function public.mcp_organization_summary(uuid) to service_role;

revoke execute on function public.upsert_operations(jsonb) from public, anon;
revoke execute on function public.insert_campaign_targets(jsonb) from public, anon;
revoke execute on function public.donor_rebuild_start() from public, anon;
revoke execute on function public.donor_rebuild_chunk(integer,boolean) from public, anon;
revoke execute on function public.donor_rebuild_start_for_phones(text[]) from public, anon;
revoke execute on function public.save_monthly_target(text,numeric,text) from public, anon;
revoke execute on function public.save_daily_target(date,numeric,numeric,text) from public, anon;
revoke execute on function public.save_referral_code_cost(text,numeric,text) from public, anon;
grant execute on function public.upsert_operations(jsonb) to authenticated;
grant execute on function public.insert_campaign_targets(jsonb) to authenticated;
grant execute on function public.donor_rebuild_start() to authenticated;
grant execute on function public.donor_rebuild_chunk(integer,boolean) to authenticated;
grant execute on function public.donor_rebuild_start_for_phones(text[]) to authenticated;
grant execute on function public.save_monthly_target(text,numeric,text) to authenticated;
grant execute on function public.save_daily_target(date,numeric,numeric,text) to authenticated;
grant execute on function public.save_referral_code_cost(text,numeric,text) to authenticated;

-- القيود الفريدة يجب أن تكون داخل الجمعية لا على مستوى المنصة كاملة.
alter table public.operations drop constraint if exists uq_operations_line_operation;
create unique index if not exists uq_operations_org_line_operation
  on public.operations (organization_id, line_no, operation_no);

drop index if exists public.uq_campaign_targets_target_key;
create unique index if not exists uq_campaign_targets_org_target_key
  on public.campaign_targets (organization_id, target_key);

alter table public.donors drop constraint if exists donors_pkey;
alter table public.donors add constraint donors_pkey primary key (organization_id, phone);
alter table public.settings drop constraint if exists settings_pkey;
alter table public.settings add constraint settings_pkey primary key (organization_id, id);
alter table public.donor_rebuild_keys drop constraint if exists donor_rebuild_keys_pkey;
alter table public.donor_rebuild_keys add constraint donor_rebuild_keys_pkey primary key (organization_id, phone);
alter table public.monthly_targets drop constraint if exists monthly_targets_pkey;
alter table public.monthly_targets add constraint monthly_targets_pkey primary key (organization_id, month_key);
alter table public.daily_targets drop constraint if exists daily_targets_pkey;
alter table public.daily_targets add constraint daily_targets_pkey primary key (organization_id, day_date);
alter table public.referral_code_costs drop constraint if exists referral_code_costs_pkey;
alter table public.referral_code_costs add constraint referral_code_costs_pkey primary key (organization_id, referral_code);
alter table public.campaign_operation_facts drop constraint if exists campaign_operation_facts_pkey;
alter table public.campaign_operation_facts add constraint campaign_operation_facts_pkey primary key (organization_id, operation_no);

drop index if exists public.uq_marketing_platforms_name_lower;
create unique index if not exists uq_marketing_platforms_org_name_lower
  on public.marketing_platforms (organization_id, lower(name));
drop index if exists public.uq_marketing_projects_name_lower;
create unique index if not exists uq_marketing_projects_org_name_lower
  on public.marketing_projects (organization_id, lower(name));

create index if not exists idx_operations_org_datetime on public.operations (organization_id, op_datetime);
create index if not exists idx_operations_org_phone on public.operations (organization_id, phone);
create index if not exists idx_donors_org_last on public.donors (organization_id, last_donation);
create index if not exists idx_campaign_targets_org_date on public.campaign_targets (organization_id, target_date);
create index if not exists idx_campaign_facts_org_date on public.campaign_operation_facts (organization_id, op_date);

-- ---------------------------------------------------------------------
-- RLS: العزل الحقيقي في قاعدة البيانات، وليس إخفاءً بصرياً فقط.
-- ---------------------------------------------------------------------
alter table public.organizations enable row level security;
alter table public.platform_admins enable row level security;
alter table public.organization_members enable row level security;
alter table public.mcp_access_tokens enable row level security;
alter table public.mcp_audit_logs enable row level security;

drop policy if exists organizations_select on public.organizations;
create policy organizations_select on public.organizations for select to authenticated
using (
  app_private.is_platform_admin()
  or exists (
    select 1 from public.organization_members m
    where m.organization_id = organizations.id
      and m.user_id = (select auth.uid())
  )
);

drop policy if exists platform_admins_self on public.platform_admins;
create policy platform_admins_self on public.platform_admins for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists organization_members_select on public.organization_members;
create policy organization_members_select on public.organization_members for select to authenticated
using (user_id = (select auth.uid()) or app_private.is_platform_admin());

do $$
declare
  v_table text;
  v_policy record;
begin
  foreach v_table in array array[
    'operations','campaign_targets','donors','settings','donor_rebuild_keys',
    'monthly_targets','daily_targets','marketing_platforms','marketing_projects',
    'marketing_contents','referral_code_costs','marketing_campaigns',
    'marketing_campaign_costs','campaign_operation_facts','marketing_campaign_analysis_cache'
  ] loop
    execute format('alter table public.%I enable row level security', v_table);
    for v_policy in
      select policyname from pg_policies where schemaname = 'public' and tablename = v_table
    loop
      execute format('drop policy if exists %I on public.%I', v_policy.policyname, v_table);
    end loop;
    execute format(
      'create policy tenant_isolation on public.%I for all to authenticated using (app_private.can_access_organization(organization_id)) with check (app_private.can_access_organization(organization_id))',
      v_table
    );
  end loop;
end;
$$;

grant select on public.organizations, public.platform_admins, public.organization_members to authenticated;
grant select, insert, update, delete on
  public.operations, public.campaign_targets, public.donors, public.settings,
  public.donor_rebuild_keys, public.monthly_targets, public.daily_targets,
  public.marketing_platforms, public.marketing_projects, public.marketing_contents,
  public.referral_code_costs, public.marketing_campaigns, public.marketing_campaign_costs,
  public.campaign_operation_facts, public.marketing_campaign_analysis_cache
to authenticated;
revoke insert, update, delete on public.campaign_operation_facts from authenticated;
drop policy if exists tenant_isolation on public.campaign_operation_facts;
create policy tenant_facts_read on public.campaign_operation_facts for select to authenticated
using (app_private.can_access_organization(organization_id));
grant all on public.organizations, public.platform_admins, public.organization_members,
  public.mcp_access_tokens, public.mcp_audit_logs to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;

-- كل جمعية جديدة تحصل على إعداداتها الأساسية تلقائياً.
create or replace function app_private.initialize_organization_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.settings (organization_id, id)
  values (new.id, 1)
  on conflict (organization_id, id) do nothing;

  insert into public.marketing_platforms (organization_id, name, color, is_active)
  values (new.id, 'واتس اب', '#25D366', true)
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists trg_initialize_organization on public.organizations;
create trigger trg_initialize_organization
after insert on public.organizations
for each row execute function app_private.initialize_organization_trigger();
revoke all on function app_private.initialize_organization_trigger() from public, anon, authenticated;

-- منع ربط سجل بمرجع UUID تابع لجمعية أخرى.
create or replace function app_private.assert_tenant_reference_trigger()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_table_name = 'marketing_contents' then
    if new.platform_id is not null and not exists (
      select 1 from public.marketing_platforms p
      where p.id = new.platform_id and p.organization_id = new.organization_id
    ) then raise exception 'المنصة التسويقية لا تتبع الجمعية الحالية'; end if;
    if new.project_id is not null and not exists (
      select 1 from public.marketing_projects p
      where p.id = new.project_id and p.organization_id = new.organization_id
    ) then raise exception 'المشروع لا يتبع الجمعية الحالية'; end if;
  elsif tg_table_name = 'campaign_targets' then
    if new.campaign_id is not null and not exists (
      select 1 from public.marketing_campaigns c
      where c.id = new.campaign_id and c.organization_id = new.organization_id
    ) then raise exception 'الحملة لا تتبع الجمعية الحالية'; end if;
  elsif tg_table_name = 'marketing_campaign_costs' then
    if not exists (
      select 1 from public.marketing_campaigns c
      where c.id = new.campaign_id and c.organization_id = new.organization_id
    ) then raise exception 'تكلفة الحملة لا تتبع الجمعية الحالية'; end if;
  elsif tg_table_name = 'marketing_campaign_analysis_cache' then
    if not exists (
      select 1 from public.marketing_campaigns c
      where c.id = new.campaign_id and c.organization_id = new.organization_id
    ) then raise exception 'ذاكرة التحليل لا تتبع الجمعية الحالية'; end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_tenant_reference_marketing_contents on public.marketing_contents;
create trigger trg_tenant_reference_marketing_contents before insert or update on public.marketing_contents
for each row execute function app_private.assert_tenant_reference_trigger();
drop trigger if exists trg_tenant_reference_campaign_targets on public.campaign_targets;
create trigger trg_tenant_reference_campaign_targets before insert or update on public.campaign_targets
for each row execute function app_private.assert_tenant_reference_trigger();
drop trigger if exists trg_tenant_reference_campaign_costs on public.marketing_campaign_costs;
create trigger trg_tenant_reference_campaign_costs before insert or update on public.marketing_campaign_costs
for each row execute function app_private.assert_tenant_reference_trigger();
drop trigger if exists trg_tenant_reference_analysis_cache on public.marketing_campaign_analysis_cache;
create trigger trg_tenant_reference_analysis_cache before insert or update on public.marketing_campaign_analysis_cache
for each row execute function app_private.assert_tenant_reference_trigger();

-- الدوال العامة التي كانت SECURITY DEFINER تصبح خاضعة لـRLS.
do $$
declare
  v_fn record;
begin
  for v_fn in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any(array[
        'upsert_operations','insert_campaign_targets','donor_rebuild_start',
        'donor_rebuild_chunk','donor_rebuild_start_for_phones','recalculate_donors',
        'update_settings','compute_response_for_phones','dashboard_stats',
        'donors_total_sum','operations_projects','operations_year_summary','reports_stats',
        'save_monthly_target','save_daily_target','targets_month_data','donors_fast_summary',
        'save_referral_code_cost','referral_code_analysis','save_marketing_campaign',
        'delete_marketing_campaign','campaign_match_preview','marketing_campaign_analysis_list',
        'marketing_campaign_analysis_detail','marketing_campaign_analysis_detail_live',
        'empty_marketing_campaign_analysis','refresh_marketing_campaign_analysis_cache',
        'marketing_campaign_analysis_pending'
      ]::text[])
  loop
    execute format('alter function %s security invoker', v_fn.signature);
    execute format('revoke execute on function %s from public, anon', v_fn.signature);
    execute format('grant execute on function %s to authenticated', v_fn.signature);
  end loop;
end;
$$;

notify pgrst, 'reload schema';
notify pgrst, 'reload config';
commit;

-- بعد النجاح: افتح admin.html وحدّث اسم «الجهة الحالية» وتاريخ اشتراكها.
