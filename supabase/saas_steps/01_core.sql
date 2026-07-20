-- ولاء SaaS 3.0 | المرحلة 1/6: الجداول الأساسية وهوية الجمعية
-- شغّل هذا الملف وحده وانتظر Success قبل الانتقال للمرحلة التالية.

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


commit;
