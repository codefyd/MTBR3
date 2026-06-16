-- =====================================================================
-- ترقية: تبويب المحتوى التسويقي
-- الجداول: المنصات، المشاريع، محتوى التقويم
-- شغّل الملف في Supabase Dashboard > SQL Editor > New Query > Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) منصات النشر المعتمدة: واتس اب، تويتر/X، إنستقرام... إلخ
-- ---------------------------------------------------------------------
create table if not exists public.marketing_platforms (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  color       text not null default '#0f5e54',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint marketing_platforms_color_hex check (color ~ '^#[0-9A-Fa-f]{6}$')
);

create unique index if not exists uq_marketing_platforms_name_lower
  on public.marketing_platforms (lower(name));
create index if not exists idx_marketing_platforms_active
  on public.marketing_platforms (is_active);

insert into public.marketing_platforms (name, color, is_active)
select 'واتس اب', '#25D366', true
where not exists (
  select 1 from public.marketing_platforms where lower(name) = lower('واتس اب')
);

-- ---------------------------------------------------------------------
-- 2) المشاريع وروابطها المعتمدة
-- يمكن وضع {code} داخل الرابط ليتم استبداله بكود الإحالة من الواجهة.
-- ---------------------------------------------------------------------
create table if not exists public.marketing_projects (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  base_url    text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index if not exists uq_marketing_projects_name_lower
  on public.marketing_projects (lower(name));
create index if not exists idx_marketing_projects_active
  on public.marketing_projects (is_active);

-- ---------------------------------------------------------------------
-- 3) محتوى التقويم التسويقي
-- اليوم الواحد يمكن أن يحتوي أكثر من محتوى، وعلى أكثر من منصة.
-- ---------------------------------------------------------------------
create table if not exists public.marketing_contents (
  id               uuid primary key default gen_random_uuid(),
  content_date     date not null,
  platform_id      uuid references public.marketing_platforms(id) on delete set null,
  media_type       text not null default 'none',
  content_text     text,
  referral_code    text,
  project_id       uuid references public.marketing_projects(id) on delete set null,
  final_url        text,
  target_time      time,
  target_audience  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint marketing_contents_media_type check (media_type in ('none', 'image', 'video', 'pdf'))
);

create index if not exists idx_marketing_contents_date
  on public.marketing_contents (content_date);
create index if not exists idx_marketing_contents_platform
  on public.marketing_contents (platform_id);
create index if not exists idx_marketing_contents_project
  on public.marketing_contents (project_id);

-- ---------------------------------------------------------------------
-- 4) RLS: القراءة والكتابة للمستخدم المسجل فقط
-- ---------------------------------------------------------------------
alter table public.marketing_platforms enable row level security;
alter table public.marketing_projects  enable row level security;
alter table public.marketing_contents  enable row level security;

drop policy if exists "auth read marketing platforms" on public.marketing_platforms;
create policy "auth read marketing platforms"
  on public.marketing_platforms for select to authenticated using (true);

drop policy if exists "auth write marketing platforms" on public.marketing_platforms;
create policy "auth write marketing platforms"
  on public.marketing_platforms for all to authenticated using (true) with check (true);

drop policy if exists "auth read marketing projects" on public.marketing_projects;
create policy "auth read marketing projects"
  on public.marketing_projects for select to authenticated using (true);

drop policy if exists "auth write marketing projects" on public.marketing_projects;
create policy "auth write marketing projects"
  on public.marketing_projects for all to authenticated using (true) with check (true);

drop policy if exists "auth read marketing contents" on public.marketing_contents;
create policy "auth read marketing contents"
  on public.marketing_contents for select to authenticated using (true);

drop policy if exists "auth write marketing contents" on public.marketing_contents;
create policy "auth write marketing contents"
  on public.marketing_contents for all to authenticated using (true) with check (true);

-- صلاحيات PostgREST للمستخدم المسجل
grant select, insert, update, delete on public.marketing_platforms to authenticated;
grant select, insert, update, delete on public.marketing_projects  to authenticated;
grant select, insert, update, delete on public.marketing_contents  to authenticated;
