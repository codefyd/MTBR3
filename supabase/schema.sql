-- =====================================================================
-- MTBR3 Clean Production Schema
-- نسخة نظيفة ومباشرة بدون ملفات ترقيات متراكمة.
-- شغّل هذا الملف كاملًا في Supabase SQL Editor لمشروع جديد.
--
-- المعتمد:
-- - العمليات لا تُدمج على operation_no وحده.
-- - مفتاح الصف الصحيح: (line_no, operation_no).
-- - توجد نسخة واحدة فقط من donor_rebuild_chunk: (integer, boolean).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- الجداول الأساسية
-- ---------------------------------------------------------------------

create table if not exists public.operations (
  id            bigint generated always as identity primary key,
  line_no       bigint      not null,
  operation_no  bigint      not null,
  donor_name    text,
  phone_raw     text,
  phone         text,
  phone_status  text,
  phone_issue   text,
  project       text,
  referral_code text,
  value         numeric,
  quantity      numeric,
  total         numeric,
  op_datetime   timestamptz,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now(),
  constraint uq_operations_line_operation unique (line_no, operation_no)
);

create index if not exists idx_operations_phone on public.operations (phone);
create index if not exists idx_operations_operation_no on public.operations (operation_no);
create index if not exists idx_operations_datetime on public.operations (op_datetime);
create index if not exists idx_operations_phone_datetime on public.operations (phone, op_datetime) where phone is not null;
create index if not exists idx_operations_phone_status on public.operations (phone_status);
create index if not exists idx_operations_project on public.operations (project) where project is not null;
create index if not exists idx_operations_phone_line_operation on public.operations (phone, line_no, operation_no) where phone is not null;

create table if not exists public.campaign_targets (
  id             bigint generated always as identity primary key,
  phone_raw      text,
  phone          text not null,
  campaign_name  text,
  target_date    timestamptz,
  target_key     text,
  created_at     timestamptz default now()
);

create unique index if not exists uq_campaign_targets_target_key on public.campaign_targets (target_key);
create index if not exists idx_campaign_targets_phone on public.campaign_targets (phone) where phone is not null;
create index if not exists idx_campaign_targets_date on public.campaign_targets (target_date);

create table if not exists public.donors (
  phone               text primary key,
  phone_raw           text,
  phone_status        text default 'صحيح',
  phone_issue         text,
  donor_name          text,
  first_donation      timestamptz,
  last_donation       timestamptz,
  total_amount        numeric default 0,
  donations_count     integer default 0,
  projects            text[],
  status              text,
  category            text,
  sat_count           integer default 0,
  sun_count           integer default 0,
  mon_count           integer default 0,
  tue_count           integer default 0,
  wed_count           integer default 0,
  thu_count           integer default 0,
  fri_count           integer default 0,
  period_morning      integer default 0,
  period_noon         integer default 0,
  period_evening      integer default 0,
  period_night        integer default 0,
  no_time_count       integer default 0,
  targeted_count      integer default 0,
  last_targeted       timestamptz,
  responded           boolean default false,
  response_date       timestamptz,
  response_lag_days   integer,
  updated_at          timestamptz default now()
);

create index if not exists idx_donors_status on public.donors (status);
create index if not exists idx_donors_category on public.donors (category);
create index if not exists idx_donors_last on public.donors (last_donation);
create index if not exists idx_donors_count on public.donors (donations_count);
create index if not exists idx_donors_phone_status on public.donors (phone_status);
create index if not exists idx_donors_total on public.donors (total_amount);
create index if not exists idx_donors_projects_gin on public.donors using gin (projects);
create index if not exists idx_donors_responded on public.donors (responded);
create index if not exists idx_donors_last_targeted on public.donors (last_targeted);

create table if not exists public.settings (
  id              integer primary key default 1,
  inactive_days   integer not null default 90,
  response_days   integer not null default 30,
  categories      jsonb not null default
    '[
      {"name":"جديد","min":1,"max":2},
      {"name":"برونزي","min":3,"max":4},
      {"name":"فضي","min":5,"max":8},
      {"name":"ذهبي","min":9,"max":null}
    ]'::jsonb,
  updated_at      timestamptz default now(),
  constraint settings_singleton check (id = 1)
);

insert into public.settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.donor_rebuild_keys (
  phone text primary key
);

-- ---------------------------------------------------------------------
-- المستهدفات اليومية
-- ---------------------------------------------------------------------
create table if not exists public.monthly_targets (
  month_key       text primary key,
  default_daily   numeric not null default 0,
  season_override text,
  updated_at      timestamptz default now()
);

create table if not exists public.daily_targets (
  day_date     date primary key,
  target_value numeric,
  deduction    numeric default 0,
  note         text,
  updated_at   timestamptz default now()
);

create index if not exists idx_daily_targets_month on public.daily_targets (day_date);

-- ---------------------------------------------------------------------
-- المحتوى التسويقي
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

create unique index if not exists uq_marketing_platforms_name_lower on public.marketing_platforms (lower(name));
create index if not exists idx_marketing_platforms_active on public.marketing_platforms (is_active);

insert into public.marketing_platforms (name, color, is_active)
select 'واتس اب', '#25D366', true
where not exists (select 1 from public.marketing_platforms where lower(name) = lower('واتس اب'));

create table if not exists public.marketing_projects (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  base_url    text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index if not exists uq_marketing_projects_name_lower on public.marketing_projects (lower(name));
create index if not exists idx_marketing_projects_active on public.marketing_projects (is_active);

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

create index if not exists idx_marketing_contents_date on public.marketing_contents (content_date);
create index if not exists idx_marketing_contents_platform on public.marketing_contents (platform_id);
create index if not exists idx_marketing_contents_project on public.marketing_contents (project_id);

-- ---------------------------------------------------------------------
-- الدوال
-- ---------------------------------------------------------------------
create or replace function public.clean_phone(raw text)
returns text
language plpgsql
immutable
as $$
declare
  d text;
  op text;
  fixed text;
begin
  if raw is null or btrim(raw) = '' then return null; end if;
  d := regexp_replace(raw, '[^0-9]', '', 'g');
  if d = '' then return null; end if;
  d := regexp_replace(d, '^00', '');

  -- 9660 + 9665XXXXXXXX  مثال: 9660966544747447 => 966544747447
  if d ~ '^9660+9665[0-9]{8}$' then
    fixed := regexp_replace(d, '^9660+', '');
    op := substring(fixed from 4 for 2);
    if op in ('50','51','52','53','54','55','56','57','58','59') then return fixed; end if;
  end if;

  -- 9660 + 5XXXXXXXX  مثال: 9660501234567 => 966501234567
  if d ~ '^9660+5[0-9]{8}$' then
    fixed := regexp_replace(d, '^9660+', '');
    op := substring(fixed from 1 for 2);
    if op in ('50','51','52','53','54','55','56','57','58','59') then return '966' || fixed; end if;
  end if;

  if d ~ '^9665[0-9]{8}$' then
    op := substring(d from 4 for 2);
    if op in ('50','51','52','53','54','55','56','57','58','59') then return d; end if;
    return null;
  end if;

  if d ~ '^05[0-9]{8}$' then
    op := substring(d from 2 for 2);
    if op in ('50','51','52','53','54','55','56','57','58','59') then return '966' || substring(d from 2); end if;
    return null;
  end if;

  if d ~ '^5[0-9]{8}$' then
    op := substring(d from 1 for 2);
    if op in ('50','51','52','53','54','55','56','57','58','59') then return '966' || d; end if;
    return null;
  end if;

  -- رقم طويل يبدأ بـ966 وفي آخره رقم سعودي صحيح
  if d like '966%' and length(d) > 12 then
    if right(d, 12) ~ '^9665[0-9]{8}$' then
      op := substring(right(d, 12) from 4 for 2);
      if op in ('50','51','52','53','54','55','56','57','58','59') then return right(d, 12); end if;
    end if;
    if right(d, 10) ~ '^05[0-9]{8}$' then
      op := substring(right(d, 10) from 2 for 2);
      if op in ('50','51','52','53','54','55','56','57','58','59') then return '966' || substring(right(d, 10) from 2); end if;
    end if;
  end if;

  if left(d, 3) = '966' then return null; end if;

  -- أجنبي: طول دولي معقول
  if length(d) between 8 and 15 then return d; end if;

  return null;
end;
$$;


create or replace function public.operation_phone_info(raw text, p_line_no bigint, p_operation_no bigint)
returns jsonb
language plpgsql
immutable
as $$
declare
  d text;
  op text;
  fixed text;
  empty_key text := 'EMPTY:' || coalesce(p_operation_no::text, '0') || ':' || coalesce(p_line_no::text, '0');
  invalid_key text;
begin
  if raw is null or btrim(raw) = '' then
    return jsonb_build_object('phone', empty_key, 'status', 'فارغ', 'issue', 'رقم الجوال فارغ', 'digits', '');
  end if;

  d := regexp_replace(raw, '[^0-9]', '', 'g');
  if d = '' then
    return jsonb_build_object('phone', empty_key, 'status', 'فارغ', 'issue', 'لا يحتوي أرقام', 'digits', '');
  end if;
  d := regexp_replace(d, '^00', '');
  invalid_key := 'INVALID:' || left(md5(d), 20);

  if d ~ '^9665[0-9]{8}$' then
    op := substring(d from 4 for 2);
    if op in ('50','51','52','53','54','55','56','57','58','59') then
      return jsonb_build_object('phone', d, 'status', 'صحيح', 'issue', 'سعودي صحيح', 'digits', d);
    end if;
    return jsonb_build_object('phone', invalid_key, 'status', 'خاطئ', 'issue', 'مشغّل سعودي غير صحيح', 'digits', d);
  end if;

  if d ~ '^05[0-9]{8}$' then
    op := substring(d from 2 for 2);
    if op in ('50','51','52','53','54','55','56','57','58','59') then
      fixed := '966' || substring(d from 2);
      return jsonb_build_object('phone', fixed, 'status', 'صحيح', 'issue', 'محلي بصفر', 'digits', d);
    end if;
    return jsonb_build_object('phone', invalid_key, 'status', 'خاطئ', 'issue', 'مشغّل سعودي غير صحيح', 'digits', d);
  end if;

  if d ~ '^5[0-9]{8}$' then
    op := substring(d from 1 for 2);
    if op in ('50','51','52','53','54','55','56','57','58','59') then
      fixed := '966' || d;
      return jsonb_build_object('phone', fixed, 'status', 'صحيح', 'issue', 'محلي 9 خانات', 'digits', d);
    end if;
    return jsonb_build_object('phone', invalid_key, 'status', 'خاطئ', 'issue', 'مشغّل سعودي غير صحيح (' || op || ')', 'digits', d);
  end if;

  if d like '966%' and length(d) > 12 then
    if right(d, 12) ~ '^9665[0-9]{8}$' then
      op := substring(right(d, 12) from 4 for 2);
      if op in ('50','51','52','53','54','55','56','57','58','59') then
        return jsonb_build_object('phone', right(d, 12), 'status', 'صحيح', 'issue', 'تصحيح رقم سعودي مكرر', 'digits', d);
      end if;
    end if;
    if right(d, 10) ~ '^05[0-9]{8}$' then
      op := substring(right(d, 10) from 2 for 2);
      if op in ('50','51','52','53','54','55','56','57','58','59') then
        fixed := '966' || substring(right(d, 10) from 2);
        return jsonb_build_object('phone', fixed, 'status', 'صحيح', 'issue', 'تصحيح من آخر رقم محلي صحيح', 'digits', d);
      end if;
    end if;
  end if;

  if left(d, 3) = '966' then
    return jsonb_build_object('phone', invalid_key, 'status', 'خاطئ', 'issue', 'يبدأ بـ966 لكن غير صالح', 'digits', d);
  end if;

  if length(d) between 8 and 15 then
    return jsonb_build_object('phone', d, 'status', 'صحيح', 'issue', 'أجنبي', 'digits', d);
  end if;

  return jsonb_build_object('phone', invalid_key, 'status', 'خاطئ', 'issue', 'مبتور/غير صالح (' || length(d) || ' خانة)', 'digits', d);
end;
$$;


create or replace function public.upsert_operations(rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  affected integer;
begin
  with incoming0 as (
    select
      nullif(r->>'line_no','')::bigint       as line_no,
      nullif(r->>'operation_no','')::bigint  as operation_no,
      nullif(r->>'donor_name','')            as donor_name,
      nullif(r->>'phone_raw','')             as phone_raw,
      nullif(r->>'project','')               as project,
      nullif(r->>'referral_code','')         as referral_code,
      nullif(r->>'value','')::numeric        as value,
      nullif(r->>'quantity','')::numeric     as quantity,
      nullif(r->>'total','')::numeric        as total,
      nullif(r->>'op_datetime','')::timestamptz as op_datetime
    from jsonb_array_elements(rows) as r
    where nullif(r->>'line_no','') is not null
      and nullif(r->>'operation_no','') is not null
  ), incoming as (
    select
      i.*,
      public.operation_phone_info(i.phone_raw, i.line_no, i.operation_no) as ph
    from incoming0 i
  ), deduped as (
    -- تكرار مطابق لنفس السطر داخل نفس الدفعة: نأخذ آخر نسخة.
    select distinct on (line_no, operation_no)
      line_no, operation_no, donor_name, phone_raw, ph,
      project, referral_code, value, quantity, total, op_datetime
    from incoming
    order by line_no, operation_no, op_datetime desc nulls last
  ), ins as (
    insert into public.operations (
      line_no, operation_no, donor_name, phone_raw, phone, phone_status, phone_issue,
      project, referral_code, value, quantity, total, op_datetime, updated_at
    )
    select
      line_no, operation_no, donor_name, phone_raw,
      ph->>'phone', ph->>'status', ph->>'issue',
      project, referral_code, value, quantity, total, op_datetime, now()
    from deduped
    on conflict (line_no, operation_no) do update set
      donor_name    = excluded.donor_name,
      phone_raw     = excluded.phone_raw,
      phone         = excluded.phone,
      phone_status  = excluded.phone_status,
      phone_issue   = excluded.phone_issue,
      project       = excluded.project,
      referral_code = excluded.referral_code,
      value         = excluded.value,
      quantity      = excluded.quantity,
      total         = excluded.total,
      op_datetime   = excluded.op_datetime,
      updated_at    = now()
    returning 1
  )
  select count(*) into affected from ins;

  return affected;
end;
$$;


create or replace function public.insert_campaign_targets(rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  affected integer;
begin
  with incoming as (
    select
      nullif(r->>'phone_raw','')        as phone_raw,
      public.clean_phone(r->>'phone_raw') as phone,
      nullif(r->>'campaign_name','')    as campaign_name,
      nullif(r->>'target_date','')::timestamptz as target_date
    from jsonb_array_elements(rows) as r
  ), valid as (
    select
      phone_raw,
      phone,
      campaign_name,
      target_date,
      md5(concat_ws('|',
        coalesce(phone, ''),
        lower(btrim(coalesce(campaign_name, ''))),
        coalesce(to_char(target_date at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'), '')
      )) as target_key
    from incoming
    where phone is not null
  ), deduped as (
    select distinct on (target_key)
      phone_raw, phone, campaign_name, target_date, target_key
    from valid
    order by target_key
  ), ins as (
    insert into public.campaign_targets (phone_raw, phone, campaign_name, target_date, target_key)
    select phone_raw, phone, campaign_name, target_date, target_key
    from deduped
    on conflict (target_key) do update set
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
security definer
set search_path = public
as $$
declare
  v_total integer;
begin
  truncate table public.donor_rebuild_keys;

  insert into public.donor_rebuild_keys (phone)
  select distinct phone
  from public.operations
  where phone is not null;

  get diagnostics v_total = row_count;
  return coalesce(v_total, 0);
end;
$$;


create or replace function public.donor_rebuild_chunk(p_limit integer default 300, p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_processed integer := 0;
  v_remaining integer := 0;
  v_inactive_days integer;
  v_response_days integer;
  v_categories jsonb;
begin
  if p_limit is null or p_limit <= 0 then
    p_limit := 300;
  end if;

  select inactive_days, categories, coalesce(response_days, 30)
    into v_inactive_days, v_categories, v_response_days
  from public.settings
  where id = 1;

  if v_inactive_days is null then
    v_inactive_days := 90;
  end if;
  if v_response_days is null then
    v_response_days := 30;
  end if;

  with batch as (
    select phone
    from public.donor_rebuild_keys
    order by phone
    limit p_limit
  ), target_agg as (
    select
      ct.phone,
      count(*)::integer as targeted_count,
      max(ct.target_date) as last_targeted
    from public.campaign_targets ct
    join batch b on b.phone = ct.phone
    where ct.phone is not null
    group by ct.phone
  ), resp as (
    -- أول تبرع وقع بعد آخر استهداف لكل متبرع في الدفعة
    select
      t.phone,
      t.last_targeted,
      min(o.op_datetime) as first_after
    from target_agg t
    join public.operations o
      on o.phone = t.phone
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
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 4 and extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 12)::integer as period_morning,
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 12 and extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 16)::integer as period_noon,
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 16 and extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 19)::integer as period_evening,
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 19 or extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 4)::integer as period_night,
      count(distinct o.operation_no) filter (where o.op_datetime is null)::integer as no_time_count
    from public.operations o
    join batch b on b.phone = o.phone
    where o.phone is not null
    group by o.phone
  ), upserted as (
    insert into public.donors (
      phone, phone_raw, phone_status, phone_issue, donor_name,
      first_donation, last_donation, total_amount, donations_count, projects,
      sat_count, sun_count, mon_count, tue_count, wed_count, thu_count, fri_count,
      period_morning, period_noon, period_evening, period_night, no_time_count,
      targeted_count, last_targeted, responded, response_date, response_lag_days,
      status, category, updated_at
    )
    select
      a.phone,
      a.phone_raw,
      a.phone_status,
      a.phone_issue,
      a.donor_name,
      a.first_donation,
      a.last_donation,
      a.total_amount,
      a.donations_count,
      coalesce(a.projects, array[]::text[]),
      coalesce(a.sat_count, 0), coalesce(a.sun_count, 0), coalesce(a.mon_count, 0),
      coalesce(a.tue_count, 0), coalesce(a.wed_count, 0), coalesce(a.thu_count, 0), coalesce(a.fri_count, 0),
      coalesce(a.period_morning, 0), coalesce(a.period_noon, 0),
      coalesce(a.period_evening, 0), coalesce(a.period_night, 0), coalesce(a.no_time_count, 0),
      coalesce(t.targeted_count, 0),
      t.last_targeted,
      -- استجابة: تبرّع خلال نافذة response_days بعد آخر استهداف
      case
        when r.first_after is not null
         and r.first_after <= t.last_targeted + (v_response_days || ' days')::interval
        then true else false
      end as responded,
      case
        when r.first_after is not null
         and r.first_after <= t.last_targeted + (v_response_days || ' days')::interval
        then r.first_after else null
      end as response_date,
      case
        when r.first_after is not null
         and r.first_after <= t.last_targeted + (v_response_days || ' days')::interval
        then greatest(0, (extract(epoch from (r.first_after - t.last_targeted)) / 86400)::int)
        else null
      end as response_lag_days,
      case
        when a.last_donation is null then 'خامل'
        when a.last_donation >= (now() - (v_inactive_days || ' days')::interval) then 'مستمر'
        else 'خامل'
      end as status,
      (
        select c->>'name'
        from jsonb_array_elements(coalesce(v_categories, '[]'::jsonb)) c
        where a.donations_count >= coalesce((c->>'min')::int, 0)
          and (
            c->>'max' is null
            or c->>'max' = 'null'
            or a.donations_count <= (c->>'max')::int
          )
        order by coalesce((c->>'min')::int, 0) desc
        limit 1
      ) as category,
      now()
    from agg a
    left join target_agg t on t.phone = a.phone
    left join resp r on r.phone = a.phone
    on conflict (phone) do update set
      phone_raw         = excluded.phone_raw,
      phone_status      = excluded.phone_status,
      phone_issue       = excluded.phone_issue,
      donor_name        = excluded.donor_name,
      first_donation    = excluded.first_donation,
      last_donation     = excluded.last_donation,
      total_amount      = excluded.total_amount,
      donations_count   = excluded.donations_count,
      projects          = excluded.projects,
      sat_count         = excluded.sat_count,
      sun_count         = excluded.sun_count,
      mon_count         = excluded.mon_count,
      tue_count         = excluded.tue_count,
      wed_count         = excluded.wed_count,
      thu_count         = excluded.thu_count,
      fri_count         = excluded.fri_count,
      period_morning    = excluded.period_morning,
      period_noon       = excluded.period_noon,
      period_evening    = excluded.period_evening,
      period_night      = excluded.period_night,
      no_time_count     = excluded.no_time_count,
      targeted_count    = excluded.targeted_count,
      last_targeted     = excluded.last_targeted,
      responded         = excluded.responded,
      response_date     = excluded.response_date,
      response_lag_days = excluded.response_lag_days,
      status            = excluded.status,
      category          = excluded.category,
      updated_at        = now()
    returning phone
  ), deleted as (
    delete from public.donor_rebuild_keys k
    using batch b
    where k.phone = b.phone
    returning k.phone
  )
  select count(*)::integer into v_processed from deleted;

  select count(*)::integer into v_remaining from public.donor_rebuild_keys;

  if v_remaining = 0 and p_cleanup then
    delete from public.donors d
    where not exists (
      select 1 from public.operations o
      where o.phone = d.phone
    );
  end if;

  return jsonb_build_object(
    'processed', coalesce(v_processed, 0),
    'remaining', coalesce(v_remaining, 0)
  );
end;
$$;


create or replace function public.donor_rebuild_start_for_phones(p_phones text[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total integer;
begin
  if p_phones is null or array_length(p_phones, 1) is null then
    select count(*)::integer into v_total from public.donor_rebuild_keys;
    return coalesce(v_total, 0);
  end if;

  insert into public.donor_rebuild_keys (phone)
  select distinct btrim(p)
  from unnest(p_phones) as p
  where btrim(coalesce(p, '')) <> ''
  on conflict (phone) do nothing;

  select count(*)::integer into v_total from public.donor_rebuild_keys;
  return coalesce(v_total, 0);
end;
$$;


create or replace function public.recalculate_donors()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- نعيد البناء عبر مفاتيح الدفعات لكن في تنفيذ واحد (قد يكون ثقيلًا لبيانات كبيرة).
  perform public.donor_rebuild_start();
  -- ننفّذ دفعات كبيرة حتى الانتهاء
  loop
    exit when (public.donor_rebuild_chunk(2000)->>'remaining')::int = 0;
  end loop;
end;
$$;


create or replace function public.update_settings(
  p_days integer,
  p_categories jsonb,
  p_response_days integer default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.settings
  set inactive_days = p_days,
      categories    = p_categories,
      response_days = coalesce(p_response_days, response_days),
      updated_at    = now()
  where id = 1;
end;
$$;


create or replace function public.compute_response_for_phones(p_phones text[])
returns table (
  phone text,
  responded boolean,
  response_date timestamptz,
  response_lag_days integer
)
language sql
stable
security definer
set search_path = public
as $$
  with cfg as (
    select coalesce(response_days, 30) as response_days from public.settings where id = 1
  ),
  tgt as (
    select ct.phone, max(ct.target_date) as last_targeted
    from public.campaign_targets ct
    where ct.phone = any(p_phones) and ct.phone is not null and ct.target_date is not null
    group by ct.phone
  ),
  first_after as (
    select
      t.phone,
      t.last_targeted,
      min(o.op_datetime) as response_date
    from tgt t
    join public.operations o
      on o.phone = t.phone
     and o.op_datetime is not null
     and o.op_datetime > t.last_targeted
    group by t.phone, t.last_targeted
  )
  select
    t.phone,
    case
      when fa.response_date is not null
       and fa.response_date <= t.last_targeted + ((select response_days from cfg) || ' days')::interval
      then true else false
    end as responded,
    case
      when fa.response_date is not null
       and fa.response_date <= t.last_targeted + ((select response_days from cfg) || ' days')::interval
      then fa.response_date else null
    end as response_date,
    case
      when fa.response_date is not null
       and fa.response_date <= t.last_targeted + ((select response_days from cfg) || ' days')::interval
      then greatest(0, (extract(epoch from (fa.response_date - t.last_targeted)) / 86400)::int)
      else null
    end as response_lag_days
  from tgt t
  left join first_after fa on fa.phone = t.phone;
$$;


create or replace function public.dashboard_stats()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  result jsonb;
  v_month_start timestamptz := date_trunc('month', now() at time zone 'Asia/Riyadh') at time zone 'Asia/Riyadh';
  v_year_start  timestamptz := date_trunc('year',  now() at time zone 'Asia/Riyadh') at time zone 'Asia/Riyadh';
begin
  with year_ops as (
    select
      id,
      phone,
      operation_no,
      coalesce(total, 0) as op_total,
      op_datetime as op_dt
    from public.operations
    where op_datetime is not null
      and op_datetime >= v_year_start
  ), year_loc as (
    select
      *,
      (op_dt at time zone 'Asia/Riyadh') as op_local,
      extract(dow from (op_dt at time zone 'Asia/Riyadh'))::int as dow,
      (op_dt at time zone 'Asia/Riyadh')::date as op_date
    from year_ops
  ), month_agg as (
    select coalesce(sum(op_total), 0) as sum_amt, count(*) as cnt
    from year_ops
    where op_dt >= v_month_start
  ), year_agg as (
    select coalesce(sum(op_total), 0) as sum_amt, count(*) as cnt
    from year_ops
  ), best_dow as (
    select dow, count(*) as cnt, coalesce(sum(op_total), 0) as amt
    from year_loc
    where op_local >= (v_month_start at time zone 'Asia/Riyadh')
    group by dow
    order by cnt desc
    limit 1
  ), best_date as (
    select op_date, count(*) as cnt, coalesce(sum(op_total), 0) as amt
    from year_loc
    group by op_date
    order by amt desc
    limit 1
  ), uniq_month as (
    select count(distinct phone) as c
    from year_ops
    where op_dt >= v_month_start
      and phone is not null
  ), dow_dist as (
    select dow, count(*) as cnt
    from year_loc
    group by dow
  ), monthly as (
    select extract(month from op_local)::int as mo,
           coalesce(sum(op_total), 0) as amt,
           count(*) as cnt
    from year_loc
    group by mo
    order by mo
  ), donors_by_year as (
    select extract(year from (first_donation at time zone 'Asia/Riyadh'))::int as yr,
           count(*) as c
    from public.donors
    where first_donation is not null
    group by yr
    order by yr
  )
  select jsonb_build_object(
    'month_sum',      (select sum_amt from month_agg),
    'month_count',    (select cnt from month_agg),
    'year_sum',       (select sum_amt from year_agg),
    'year_count',     (select cnt from year_agg),
    'unique_month',   (select c from uniq_month),
    'total_donors',   (select count(*) from public.donors),
    'best_dow',       (select to_jsonb(best_dow) from best_dow),
    'best_date',      (select to_jsonb(best_date) from best_date),
    'dow_dist',       (select coalesce(jsonb_agg(to_jsonb(dow_dist)), '[]'::jsonb) from dow_dist),
    'donors_by_year', (select coalesce(jsonb_agg(to_jsonb(donors_by_year)), '[]'::jsonb) from donors_by_year),
    'monthly',        (select coalesce(jsonb_agg(to_jsonb(monthly)), '[]'::jsonb) from monthly)
  ) into result;

  return result;
end;
$$;


create or replace function public.donors_total_sum()
returns numeric language sql stable as $$
  select coalesce(sum(total_amount), 0) from donors;
$$;


create or replace function public.operations_projects()
returns text[]
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(array_agg(project order by project), array[]::text[])
  from (
    select distinct btrim(project) as project
    from operations
    where project is not null and btrim(project) <> ''
  ) p;
$$;


create or replace function public.operations_year_summary(p_year integer default 2026)
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select jsonb_build_object(
    'year', p_year,
    'rows_count', count(*),
    'unique_operation_no', count(distinct operation_no),
    'total_amount', coalesce(sum(total), 0),
    'empty_datetime_rows', count(*) filter (where op_datetime is null),
    'empty_total_rows', count(*) filter (where total is null)
  )
  from public.operations
  where op_datetime >= make_timestamptz(p_year, 1, 1, 0, 0, 0, 'Asia/Riyadh')
    and op_datetime <  make_timestamptz(p_year + 1, 1, 1, 0, 0, 0, 'Asia/Riyadh');
$$;


create or replace function public.reports_stats(p_year integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  result jsonb;
  v_year integer := coalesce(p_year, extract(year from (now() at time zone 'Asia/Riyadh'))::int);
  v_year_start timestamptz := make_timestamptz(v_year, 1, 1, 0, 0, 0, 'Asia/Riyadh');
  v_year_end   timestamptz := make_timestamptz(v_year + 1, 1, 1, 0, 0, 0, 'Asia/Riyadh');
  v_prev_start timestamptz := make_timestamptz(v_year - 1, 1, 1, 0, 0, 0, 'Asia/Riyadh');
begin
  with per_op as (
    -- عملية فريدة واحدة: المبلغ = مجموع صفوفها، التاريخ = أقدم تاريخ صالح، أول مشروع
    select
      phone, operation_no,
      sum(total) as op_total,
      min(op_datetime) as op_dt,
      (array_agg(project order by op_datetime nulls last))[1] as project
    from public.operations
    where phone is not null and op_datetime is not null
    group by phone, operation_no
  ),
  loc as (
    select
      *,
      (op_dt at time zone 'Asia/Riyadh')                       as op_local,
      extract(month from (op_dt at time zone 'Asia/Riyadh'))::int as mo,
      (op_dt at time zone 'Asia/Riyadh')::date                 as op_date
    from per_op
    where op_dt >= v_year_start and op_dt < v_year_end
  ),
  -- أول ظهور لكل متبرع في النظام (لتحديد المتبرعين الجدد)
  donor_first as (
    select phone, min(op_dt) as first_ever
    from per_op group by phone
  ),
  -- ملخص سنوي إجمالي
  year_tot as (
    select
      coalesce(sum(op_total),0) as amt,
      count(*) as cnt,
      count(distinct phone) as donors
    from loc
  ),
  -- ملخص السنة السابقة (للمقارنة)
  prev_tot as (
    select coalesce(sum(op_total),0) as amt, count(*) as cnt
    from per_op where op_dt >= v_prev_start and op_dt < v_year_start
  ),
  -- متبرعون جدد هذه السنة (أول تبرع لهم وقع داخل السنة المطلوبة)
  new_donors as (
    select count(*) as c
    from donor_first
    where first_ever >= v_year_start and first_ever < v_year_end
  ),
  -- التفصيل الشهري: مبلغ + عدد + متبرعون فريدون + جدد
  monthly as (
    select
      m.mo,
      coalesce(sum(l.op_total),0) as amt,
      count(l.operation_no) as cnt,
      count(distinct l.phone) as donors
    from generate_series(1,12) as m(mo)
    left join loc l on l.mo = m.mo
    group by m.mo order by m.mo
  ),
  monthly_new as (
    select extract(month from (first_ever at time zone 'Asia/Riyadh'))::int as mo, count(*) as c
    from donor_first
    where first_ever >= v_year_start and first_ever < v_year_end
    group by mo
  ),
  -- أفضل شهر (بالمبلغ)
  best_month as (
    select mo, amt, cnt from monthly order by amt desc limit 1
  ),
  -- توزيع أيام الأسبوع خلال السنة
  dow_dist as (
    select extract(dow from op_local)::int as dow, count(*) as cnt, coalesce(sum(op_total),0) as amt
    from loc group by dow
  ),
  -- توزيع الفترات اليومية
  period_dist as (
    select
      count(*) filter (where extract(hour from op_local)::int >= 4  and extract(hour from op_local)::int < 12) as morning,
      count(*) filter (where extract(hour from op_local)::int >= 12 and extract(hour from op_local)::int < 16) as noon,
      count(*) filter (where extract(hour from op_local)::int >= 16 and extract(hour from op_local)::int < 19) as evening,
      count(*) filter (where extract(hour from op_local)::int >= 19 or  extract(hour from op_local)::int < 4)  as night
    from loc
  ),
  -- أعلى المشاريع تبرعًا خلال السنة
  top_projects as (
    select nullif(btrim(project),'') as project, coalesce(sum(op_total),0) as amt, count(*) as cnt
    from loc
    where nullif(btrim(project),'') is not null
    group by nullif(btrim(project),'')
    order by amt desc limit 8
  ),
  -- أعلى المتبرعين خلال السنة
  top_donors as (
    select l.phone,
      (select donor_name from public.donors d where d.phone = l.phone) as donor_name,
      coalesce(sum(l.op_total),0) as amt, count(*) as cnt
    from loc l group by l.phone
    order by amt desc limit 10
  ),
  -- السنوات المتاحة في البيانات (لقائمة اختيار السنة)
  years_avail as (
    select distinct extract(year from (op_dt at time zone 'Asia/Riyadh'))::int as yr
    from per_op order by yr desc
  ),
  -- ملخص الاستجابة للحملات (من جدول المتبرعين)
  resp as (
    select
      count(*) filter (where targeted_count > 0) as targeted,
      count(*) filter (where responded) as responded,
      round(avg(response_lag_days) filter (where responded)::numeric, 1) as avg_lag
    from public.donors
  )
  select jsonb_build_object(
    'year',            v_year,
    'year_sum',        (select amt from year_tot),
    'year_count',      (select cnt from year_tot),
    'year_donors',     (select donors from year_tot),
    'new_donors',      (select c from new_donors),
    'avg_donation',    (select case when cnt>0 then amt/cnt else 0 end from year_tot),
    'prev_sum',        (select amt from prev_tot),
    'prev_count',      (select cnt from prev_tot),
    'best_month',      (select to_jsonb(best_month) from best_month),
    'monthly',         (select coalesce(jsonb_agg(jsonb_build_object(
                          'mo', mo, 'amt', amt, 'cnt', cnt, 'donors', donors,
                          'new', coalesce((select c from monthly_new mn where mn.mo = monthly.mo),0)
                        ) order by mo), '[]'::jsonb) from monthly),
    'dow_dist',        (select coalesce(jsonb_agg(to_jsonb(dow_dist)), '[]'::jsonb) from dow_dist),
    'period_dist',     (select to_jsonb(period_dist) from period_dist),
    'top_projects',    (select coalesce(jsonb_agg(to_jsonb(top_projects)), '[]'::jsonb) from top_projects),
    'top_donors',      (select coalesce(jsonb_agg(to_jsonb(top_donors)), '[]'::jsonb) from top_donors),
    'years_available', (select coalesce(jsonb_agg(yr), '[]'::jsonb) from years_avail),
    'response',        (select to_jsonb(resp) from resp)
  ) into result;

  return result;
end;
$$;


create or replace function public.save_monthly_target(
  p_month_key text,
  p_default_daily numeric,
  p_season_override text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.monthly_targets (month_key, default_daily, season_override, updated_at)
  values (p_month_key, coalesce(p_default_daily, 0), nullif(btrim(p_season_override), ''), now())
  on conflict (month_key) do update set
    default_daily   = excluded.default_daily,
    season_override = excluded.season_override,
    updated_at      = now();
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
security definer
set search_path = public
as $$
begin
  insert into public.daily_targets (day_date, target_value, deduction, note, updated_at)
  values (p_day, p_target, coalesce(p_deduction, 0), nullif(btrim(p_note), ''), now())
  on conflict (day_date) do update set
    target_value = excluded.target_value,
    deduction    = excluded.deduction,
    note         = excluded.note,
    updated_at   = now();
end;
$$;


create or replace function public.targets_month_data(p_year integer, p_month integer)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  result jsonb;
  v_month_key text := to_char(make_date(p_year, p_month, 1), 'YYYY-MM');
  v_start timestamptz := make_timestamptz(p_year, p_month, 1, 0, 0, 0, 'Asia/Riyadh');
  v_end   timestamptz := (make_date(p_year, p_month, 1) + interval '1 month')::date
                          at time zone 'Asia/Riyadh';
  v_default_daily numeric;
  v_season_override text;
begin
  select default_daily, season_override
    into v_default_daily, v_season_override
  from public.monthly_targets where month_key = v_month_key;
  if v_default_daily is null then v_default_daily := 0; end if;

  with per_op as (
    -- عملية فريدة واحدة: المبلغ = مجموع صفوفها، التاريخ = أقدم تاريخ صالح
    select phone, operation_no, sum(total) as op_total, min(op_datetime) as op_dt
    from public.operations
    where phone is not null and op_datetime is not null
    group by phone, operation_no
  ),
  -- أول تبرع لكل متبرع في النظام بالكامل (لتحديد الجدد)
  donor_first as (
    select phone, min(op_dt) as first_ever from per_op group by phone
  ),
  month_ops as (
    select
      po.phone,
      po.operation_no,
      po.op_total,
      (po.op_dt at time zone 'Asia/Riyadh')::date as op_date,
      (df.first_ever at time zone 'Asia/Riyadh')::date as first_date
    from per_op po
    join donor_first df on df.phone = po.phone
    where po.op_dt >= v_start and po.op_dt < v_end
  ),
  by_day as (
    select
      op_date,
      coalesce(sum(op_total), 0) as achieved,
      count(distinct phone)      as donors,
      count(distinct phone) filter (where first_date = op_date) as new_donors
    from month_ops
    group by op_date
  ),
  -- كل أيام الشهر (حتى الأيام بلا تبرعات تظهر بصف)
  all_days as (
    select gs::date as d
    from generate_series(
      make_date(p_year, p_month, 1),
      (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date,
      interval '1 day'
    ) gs
  ),
  rows_out as (
    select
      ad.d as day_date,
      extract(dow from ad.d)::int as dow,
      coalesce(bd.achieved, 0) as achieved,
      coalesce(bd.donors, 0)   as donors,
      coalesce(bd.new_donors, 0) as new_donors,
      coalesce(dt.target_value, v_default_daily) as target,
      coalesce(dt.deduction, 0) as deduction,
      dt.note as note
    from all_days ad
    left join by_day bd on bd.op_date = ad.d
    left join public.daily_targets dt on dt.day_date = ad.d
    order by ad.d
  )
  select jsonb_build_object(
    'year',          p_year,
    'month',         p_month,
    'month_key',     v_month_key,
    'default_daily', v_default_daily,
    'season_override', v_season_override,
    'days', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'date',       to_char(day_date, 'YYYY-MM-DD'),
        'dow',        dow,
        'achieved',   achieved,
        'donors',     donors,
        'new_donors', new_donors,
        'target',     target,
        'deduction',  deduction,
        'note',       note
      ) order by day_date), '[]'::jsonb)
      from rows_out
    )
  ) into result;

  return result;
end;
$$;


-- ملخص سريع مطلوب في dashboard.html و donors.html
create or replace function public.donors_fast_summary()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'total_donors',    count(*),
    'valid_phones',    count(*) filter (
                         where coalesce(phone_status, 'صحيح') = 'صحيح'
                           and phone is not null
                           and phone not like 'INVALID:%'
                           and phone not like 'EMPTY:%'
                       ),
    'active_donors',   count(*) filter (where status = 'مستمر'),
    'inactive_donors', count(*) filter (where status = 'خامل'),
    'total_amount',    coalesce(sum(total_amount), 0)
  )
  from public.donors;
$$;

-- ---------------------------------------------------------------------
-- RLS والسياسات
-- ---------------------------------------------------------------------
alter table public.operations enable row level security;
alter table public.campaign_targets enable row level security;
alter table public.donors enable row level security;
alter table public.settings enable row level security;
alter table public.donor_rebuild_keys enable row level security;
alter table public.monthly_targets enable row level security;
alter table public.daily_targets enable row level security;
alter table public.marketing_platforms enable row level security;
alter table public.marketing_projects enable row level security;
alter table public.marketing_contents enable row level security;

drop policy if exists "auth read operations" on public.operations;
create policy "auth read operations" on public.operations for select to authenticated using (true);
drop policy if exists "auth write operations" on public.operations;
create policy "auth write operations" on public.operations for all to authenticated using (true) with check (true);

drop policy if exists "auth read targets" on public.campaign_targets;
create policy "auth read targets" on public.campaign_targets for select to authenticated using (true);
drop policy if exists "auth write targets" on public.campaign_targets;
create policy "auth write targets" on public.campaign_targets for all to authenticated using (true) with check (true);

drop policy if exists "auth read donors" on public.donors;
create policy "auth read donors" on public.donors for select to authenticated using (true);
drop policy if exists "auth write donors" on public.donors;
create policy "auth write donors" on public.donors for all to authenticated using (true) with check (true);

drop policy if exists "auth read settings" on public.settings;
create policy "auth read settings" on public.settings for select to authenticated using (true);
drop policy if exists "auth update settings" on public.settings;
create policy "auth update settings" on public.settings for update to authenticated using (true) with check (true);

drop policy if exists "auth read monthly_targets" on public.monthly_targets;
create policy "auth read monthly_targets" on public.monthly_targets for select to authenticated using (true);
drop policy if exists "auth write monthly_targets" on public.monthly_targets;
create policy "auth write monthly_targets" on public.monthly_targets for all to authenticated using (true) with check (true);

drop policy if exists "auth read daily_targets" on public.daily_targets;
create policy "auth read daily_targets" on public.daily_targets for select to authenticated using (true);
drop policy if exists "auth write daily_targets" on public.daily_targets;
create policy "auth write daily_targets" on public.daily_targets for all to authenticated using (true) with check (true);

drop policy if exists "auth read marketing platforms" on public.marketing_platforms;
create policy "auth read marketing platforms" on public.marketing_platforms for select to authenticated using (true);
drop policy if exists "auth write marketing platforms" on public.marketing_platforms;
create policy "auth write marketing platforms" on public.marketing_platforms for all to authenticated using (true) with check (true);

drop policy if exists "auth read marketing projects" on public.marketing_projects;
create policy "auth read marketing projects" on public.marketing_projects for select to authenticated using (true);
drop policy if exists "auth write marketing projects" on public.marketing_projects;
create policy "auth write marketing projects" on public.marketing_projects for all to authenticated using (true) with check (true);

drop policy if exists "auth read marketing contents" on public.marketing_contents;
create policy "auth read marketing contents" on public.marketing_contents for select to authenticated using (true);
drop policy if exists "auth write marketing contents" on public.marketing_contents;
create policy "auth write marketing contents" on public.marketing_contents for all to authenticated using (true) with check (true);

-- لا يوجد policy لجدول donor_rebuild_keys؛ الوصول يتم عبر دوال security definer فقط.
revoke all on public.donor_rebuild_keys from anon, authenticated;

-- ---------------------------------------------------------------------
-- الصلاحيات
-- ---------------------------------------------------------------------
grant select, insert, update, delete on public.operations to authenticated;
grant select, insert, update, delete on public.campaign_targets to authenticated;
grant select, insert, update, delete on public.donors to authenticated;
grant select, update on public.settings to authenticated;
grant select, insert, update, delete on public.monthly_targets to authenticated;
grant select, insert, update, delete on public.daily_targets to authenticated;
grant select, insert, update, delete on public.marketing_platforms to authenticated;
grant select, insert, update, delete on public.marketing_projects to authenticated;
grant select, insert, update, delete on public.marketing_contents to authenticated;

grant execute on function public.clean_phone(text) to authenticated;
grant execute on function public.operation_phone_info(text, bigint, bigint) to authenticated;
grant execute on function public.upsert_operations(jsonb) to authenticated;
grant execute on function public.insert_campaign_targets(jsonb) to authenticated;
grant execute on function public.donor_rebuild_start() to authenticated;
grant execute on function public.donor_rebuild_chunk(integer, boolean) to authenticated;
grant execute on function public.donor_rebuild_start_for_phones(text[]) to authenticated;
grant execute on function public.recalculate_donors() to authenticated;
grant execute on function public.update_settings(integer, jsonb, integer) to authenticated;
grant execute on function public.compute_response_for_phones(text[]) to authenticated;
grant execute on function public.dashboard_stats() to authenticated;
grant execute on function public.donors_total_sum() to authenticated;
grant execute on function public.operations_projects() to authenticated;
grant execute on function public.operations_year_summary(integer) to authenticated;
grant execute on function public.reports_stats(integer) to authenticated;
grant execute on function public.save_monthly_target(text, numeric, text) to authenticated;
grant execute on function public.save_daily_target(date, numeric, numeric, text) to authenticated;
grant execute on function public.targets_month_data(integer, integer) to authenticated;
grant execute on function public.donors_fast_summary() to authenticated;

-- =====================================================================
-- MTBR3 - تحليل الحملات التسويقية عبر أكواد الإحالة
-- =====================================================================


create table if not exists public.referral_code_costs (
  referral_code text primary key,
  cost          numeric not null default 0 check (cost >= 0),
  note          text,
  updated_at    timestamptz not null default now()
);

create index if not exists idx_operations_referral_code on public.operations (referral_code) where referral_code is not null;
create index if not exists idx_operations_referral_datetime on public.operations (referral_code, op_datetime) where referral_code is not null;

create or replace function public.save_referral_code_cost(
  p_referral_code text,
  p_cost numeric,
  p_note text default null
)
returns public.referral_code_costs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := nullif(btrim(p_referral_code), '');
  result public.referral_code_costs;
begin
  if v_code is null then
    raise exception 'كود الإحالة مطلوب';
  end if;
  if p_cost is null or p_cost < 0 then
    raise exception 'التكلفة يجب أن تكون أكبر من أو تساوي صفر';
  end if;

  insert into public.referral_code_costs (referral_code, cost, note, updated_at)
  values (v_code, p_cost, p_note, now())
  on conflict (referral_code) do update set
    cost = excluded.cost,
    note = excluded.note,
    updated_at = now()
  returning * into result;

  return result;
end;
$$;

create or replace function public.referral_code_analysis(
  p_from date default null,
  p_to date default null,
  p_project text default null,
  p_search text default null
)
returns table (
  referral_code text,
  projects text[],
  rows_count bigint,
  donations_count bigint,
  donor_operations bigint,
  unique_donors bigint,
  total_amount numeric,
  first_donation timestamptz,
  last_donation timestamptz,
  cost numeric,
  net_return numeric,
  roas numeric,
  roi_percent numeric
)
language sql
security definer
set search_path = public
stable
as $$
  with filtered as (
    select
      btrim(o.referral_code) as code,
      nullif(btrim(o.project), '') as project,
      o.operation_no,
      o.phone,
      coalesce(o.phone_status, 'صحيح') as phone_status,
      o.total,
      o.op_datetime
    from public.operations o
    where o.referral_code is not null
      and btrim(o.referral_code) <> ''
      and (p_from is null or o.op_datetime >= (p_from::timestamp at time zone 'Asia/Riyadh'))
      and (p_to is null or o.op_datetime < ((p_to + 1)::timestamp at time zone 'Asia/Riyadh'))
      and (p_project is null or btrim(coalesce(o.project, '')) = btrim(p_project))
      and (p_search is null or btrim(o.referral_code) ilike ('%' || btrim(p_search) || '%'))
  ), agg as (
    select
      f.code,
      array_remove(array_agg(distinct f.project order by f.project), null)::text[] as projects,
      count(*)::bigint as rows_count,
      count(distinct f.operation_no)::bigint as donations_count,
      count(distinct f.operation_no) filter (
        where f.phone is not null
          and f.phone not like 'INVALID:%'
          and f.phone not like 'EMPTY:%'
          and f.phone_status = 'صحيح'
      )::bigint as donor_operations,
      count(distinct f.phone) filter (
        where f.phone is not null
          and f.phone not like 'INVALID:%'
          and f.phone not like 'EMPTY:%'
          and f.phone_status = 'صحيح'
      )::bigint as unique_donors,
      coalesce(sum(f.total), 0)::numeric as total_amount,
      min(f.op_datetime) as first_donation,
      max(f.op_datetime) as last_donation
    from filtered f
    group by f.code
  )
  select
    a.code as referral_code,
    coalesce(a.projects, array[]::text[]) as projects,
    a.rows_count,
    a.donations_count,
    a.donor_operations,
    a.unique_donors,
    a.total_amount,
    a.first_donation,
    a.last_donation,
    coalesce(c.cost, 0)::numeric as cost,
    (a.total_amount - coalesce(c.cost, 0))::numeric as net_return,
    case when coalesce(c.cost, 0) > 0 then round((a.total_amount / c.cost)::numeric, 4) else null end as roas,
    case when coalesce(c.cost, 0) > 0 then round(((a.total_amount - c.cost) / c.cost * 100)::numeric, 2) else null end as roi_percent
  from agg a
  left join public.referral_code_costs c on c.referral_code = a.code
  order by a.total_amount desc, a.unique_donors desc, a.code;
$$;

alter table public.referral_code_costs enable row level security;

drop policy if exists "auth read referral costs" on public.referral_code_costs;
create policy "auth read referral costs" on public.referral_code_costs for select to authenticated using (true);

drop policy if exists "auth write referral costs" on public.referral_code_costs;
create policy "auth write referral costs" on public.referral_code_costs for all to authenticated using (true) with check (true);

grant select, insert, update, delete on public.referral_code_costs to authenticated;
grant execute on function public.save_referral_code_cost(text, numeric, text) to authenticated;
grant execute on function public.referral_code_analysis(date, date, text, text) to authenticated;

-- تأكيد نهائي: حذف النسخة القديمة ذات المعامل الواحد إن وجدت من مشروع قائم.
drop function if exists public.donor_rebuild_chunk(integer);

-- =====================================================================
-- END
-- =====================================================================
