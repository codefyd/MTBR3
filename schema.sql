-- =====================================================================
-- منصة تحليل المتبرعين | Supabase / PostgreSQL Schema (نسخة HTML بدون خادم)
-- =====================================================================
-- شغّل هذا الملف بالكامل في:
-- Supabase Dashboard > SQL Editor > New Query > Run
--
-- ملاحظة: في هذه النسخة كل المنطق داخل قاعدة البيانات، ولوحة HTML
-- تتصل مباشرة بـ Supabase بالمفتاح العام (publishable). الكتابة مسموحة
-- للمستخدم المسجّل فقط عبر سياسات RLS أدناه — لا حاجة لمفتاح سرّي.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) دالة تنظيف رقم الجوال (المعرّف الأساسي للمتبرع)
-- ---------------------------------------------------------------------
create or replace function clean_phone(raw text)
returns text
language plpgsql
immutable
as $$
declare
  digits text;
begin
  if raw is null then return null; end if;
  digits := regexp_replace(raw, '[^0-9]', '', 'g');
  if digits = '' then return null; end if;
  if left(digits, 5) = '00966' then
    digits := substring(digits from 6);
  elsif left(digits, 3) = '966' then
    digits := substring(digits from 4);
  end if;
  digits := regexp_replace(digits, '^0+', '');
  return digits;
end;
$$;

-- ---------------------------------------------------------------------
-- 2) جدول العمليات (التبويب الأول)
-- ---------------------------------------------------------------------
create table if not exists operations (
  id            bigint generated always as identity primary key,
  line_no       bigint      not null,
  operation_no  bigint      not null,
  donor_name    text,
  phone_raw     text,
  phone         text,
  project       text,
  referral_code text,
  value         numeric,
  quantity      numeric,
  total         numeric,
  op_datetime   timestamptz,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now(),
  constraint uq_operation unique (line_no, operation_no)
);

create index if not exists idx_operations_phone      on operations (phone);
create index if not exists idx_operations_opno        on operations (operation_no);
create index if not exists idx_operations_datetime    on operations (op_datetime);
create index if not exists idx_operations_phone_opno  on operations (phone, operation_no);

-- ---------------------------------------------------------------------
-- 3) جدول المستهدفين في الحملات (التبويب الثالث)
-- ---------------------------------------------------------------------
create table if not exists campaign_targets (
  id             bigint generated always as identity primary key,
  phone_raw      text,
  phone          text not null,
  campaign_name  text,
  target_date    timestamptz,
  created_at     timestamptz default now()
);

create index if not exists idx_targets_phone on campaign_targets (phone);
create index if not exists idx_targets_date  on campaign_targets (target_date);

-- ---------------------------------------------------------------------
-- 4) جدول المتبرعين (التبويب الثاني) - يُعاد بناؤه بعد كل رفع
-- ---------------------------------------------------------------------
create table if not exists donors (
  phone               text primary key,
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
  period_morning      integer default 0,   -- 4ص - 11:59ص
  period_noon         integer default 0,   -- 12م - 3م
  period_evening      integer default 0,   -- 4م - 6:59م
  period_night        integer default 0,   -- 7م - 3:59ص
  targeted_count      integer default 0,
  last_targeted       timestamptz,
  updated_at          timestamptz default now()
);

create index if not exists idx_donors_status   on donors (status);
create index if not exists idx_donors_category on donors (category);
create index if not exists idx_donors_last     on donors (last_donation);
create index if not exists idx_donors_count    on donors (donations_count);

-- ---------------------------------------------------------------------
-- 5) جدول الإعدادات (مدة الخمول + الفئات)
-- ---------------------------------------------------------------------
create table if not exists settings (
  id              integer primary key default 1,
  inactive_days   integer not null default 90,
  categories      jsonb   not null default
    '[
      {"name":"جديد","min":1,"max":2},
      {"name":"برونزي","min":3,"max":4},
      {"name":"فضي","min":5,"max":8},
      {"name":"ذهبي","min":9,"max":null}
    ]'::jsonb,
  updated_at      timestamptz default now(),
  constraint settings_singleton check (id = 1)
);

insert into settings (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 6) رفع دفعة عمليات عبر JSON (upsert + تنظيف الجوال داخل القاعدة)
--    تستقبل مصفوفة صفوف، تنظّف الجوال، وتُدخل/تحدّث حسب (line_no, operation_no)
--    تُستدعى من HTML عبر supabase.rpc('upsert_operations', { rows })
-- ---------------------------------------------------------------------
create or replace function upsert_operations(rows jsonb)
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
      (r->>'line_no')::bigint              as line_no,
      (r->>'operation_no')::bigint         as operation_no,
      nullif(r->>'donor_name','')          as donor_name,
      nullif(r->>'phone_raw','')           as phone_raw,
      clean_phone(r->>'phone_raw')         as phone,
      nullif(r->>'project','')             as project,
      nullif(r->>'referral_code','')       as referral_code,
      (r->>'value')::numeric               as value,
      (r->>'quantity')::numeric            as quantity,
      (r->>'total')::numeric               as total,
      (r->>'op_datetime')::timestamptz     as op_datetime
    from jsonb_array_elements(rows) as r
    where (r->>'line_no') is not null
      and (r->>'operation_no') is not null
  ), ins as (
    insert into operations (
      line_no, operation_no, donor_name, phone_raw, phone, project,
      referral_code, value, quantity, total, op_datetime, updated_at
    )
    select
      line_no, operation_no, donor_name, phone_raw, phone, project,
      referral_code, value, quantity, total, op_datetime, now()
    from incoming
    on conflict (line_no, operation_no) do update set
      donor_name    = excluded.donor_name,
      phone_raw     = excluded.phone_raw,
      phone         = excluded.phone,
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

-- ---------------------------------------------------------------------
-- 7) رفع دفعة مستهدفين عبر JSON
-- ---------------------------------------------------------------------
create or replace function insert_campaign_targets(rows jsonb)
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
      clean_phone(r->>'phone_raw')      as phone,
      nullif(r->>'campaign_name','')    as campaign_name,
      (r->>'target_date')::timestamptz  as target_date
    from jsonb_array_elements(rows) as r
  ), valid as (
    select * from incoming where phone is not null
  ), ins as (
    insert into campaign_targets (phone_raw, phone, campaign_name, target_date)
    select phone_raw, phone, campaign_name, target_date from valid
    returning 1
  )
  select count(*) into affected from ins;
  return affected;
end;
$$;

-- ---------------------------------------------------------------------
-- 8) الدالة الرئيسية: إعادة حساب ملفات المتبرعين بالكامل
-- ---------------------------------------------------------------------
create or replace function recalculate_donors()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inactive_days integer;
  v_categories    jsonb;
begin
  select inactive_days, categories into v_inactive_days, v_categories
  from settings where id = 1;
  if v_inactive_days is null then v_inactive_days := 90; end if;

  truncate table donors;

  insert into donors (
    phone, donor_name, first_donation, last_donation,
    total_amount, donations_count, projects,
    sat_count, sun_count, mon_count, tue_count, wed_count, thu_count, fri_count,
    period_morning, period_noon, period_evening, period_night
  )
  select
    o.phone,
    (array_agg(o.donor_name order by o.op_datetime desc nulls last))[1],
    min(o.op_datetime),
    max(o.op_datetime),
    coalesce(sum(o.total), 0),
    count(distinct o.operation_no),
    array(
      select distinct p from unnest(array_agg(o.project)) as p
      where p is not null and btrim(p) <> ''
    ),
    count(distinct o.operation_no) filter (where dow = 6),  -- السبت
    count(distinct o.operation_no) filter (where dow = 0),  -- الأحد
    count(distinct o.operation_no) filter (where dow = 1),  -- الاثنين
    count(distinct o.operation_no) filter (where dow = 2),  -- الثلاثاء
    count(distinct o.operation_no) filter (where dow = 3),  -- الأربعاء
    count(distinct o.operation_no) filter (where dow = 4),  -- الخميس
    count(distinct o.operation_no) filter (where dow = 5),  -- الجمعة
    count(distinct o.operation_no) filter (where hr >= 4  and hr < 12),  -- 4ص-11:59ص
    count(distinct o.operation_no) filter (where hr >= 12 and hr < 16),  -- 12م-3م
    count(distinct o.operation_no) filter (where hr >= 16 and hr < 19),  -- 4م-6:59م
    count(distinct o.operation_no) filter (where hr >= 19 or  hr < 4)    -- 7م-3:59ص
  from (
    select *,
      extract(dow  from (op_datetime at time zone 'Asia/Riyadh'))::int as dow,
      extract(hour from (op_datetime at time zone 'Asia/Riyadh'))::int as hr
    from operations
    where phone is not null
  ) o
  group by o.phone;

  update donors d
  set targeted_count = t.cnt, last_targeted = t.last_dt
  from (
    select phone, count(*) as cnt, max(target_date) as last_dt
    from campaign_targets where phone is not null group by phone
  ) t
  where d.phone = t.phone;

  update donors
  set status = case
    when last_donation is null then 'خامل'
    when last_donation >= (now() - (v_inactive_days || ' days')::interval) then 'مستمر'
    else 'خامل'
  end;

  update donors d
  set category = sub.cat
  from (
    select d2.phone,
      (
        select c->>'name'
        from jsonb_array_elements(v_categories) c
        where d2.donations_count >= coalesce((c->>'min')::int, 0)
          and (c->>'max' is null or c->>'max' = 'null'
               or d2.donations_count <= (c->>'max')::int)
        limit 1
      ) as cat
    from donors d2
  ) sub
  where d.phone = sub.phone;

  update donors set updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------
-- 9) دالة مساعدة: مجموع إجمالي التبرعات (لمؤشر KPI)
-- ---------------------------------------------------------------------
create or replace function donors_total_sum()
returns numeric language sql stable as $$
  select coalesce(sum(total_amount), 0) from donors;
$$;

-- ---------------------------------------------------------------------
-- 10) تحديث الإعدادات من اللوحة
-- ---------------------------------------------------------------------
create or replace function update_settings(p_days integer, p_categories jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update settings
  set inactive_days = p_days,
      categories = p_categories,
      updated_at = now()
  where id = 1;
end;
$$;

-- =====================================================================
-- الأمان (RLS): القراءة والكتابة للمستخدم المسجّل فقط
-- =====================================================================
alter table operations       enable row level security;
alter table campaign_targets enable row level security;
alter table donors           enable row level security;
alter table settings         enable row level security;

-- قراءة
drop policy if exists "auth read operations" on operations;
create policy "auth read operations" on operations for select to authenticated using (true);
drop policy if exists "auth read donors" on donors;
create policy "auth read donors" on donors for select to authenticated using (true);
drop policy if exists "auth read targets" on campaign_targets;
create policy "auth read targets" on campaign_targets for select to authenticated using (true);
drop policy if exists "auth read settings" on settings;
create policy "auth read settings" on settings for select to authenticated using (true);

-- كتابة العمليات (للبحث/التحديث المباشر إن لزم)
drop policy if exists "auth write operations" on operations;
create policy "auth write operations" on operations for all to authenticated using (true) with check (true);
drop policy if exists "auth write targets" on campaign_targets;
create policy "auth write targets" on campaign_targets for all to authenticated using (true) with check (true);
drop policy if exists "auth write donors" on donors;
create policy "auth write donors" on donors for all to authenticated using (true) with check (true);
drop policy if exists "auth update settings" on settings;
create policy "auth update settings" on settings for update to authenticated using (true) with check (true);

-- منح صلاحية تنفيذ الدوال للمستخدم المسجّل
grant execute on function upsert_operations(jsonb)        to authenticated;
grant execute on function insert_campaign_targets(jsonb)  to authenticated;
grant execute on function recalculate_donors()            to authenticated;
grant execute on function donors_total_sum()              to authenticated;
grant execute on function update_settings(integer, jsonb) to authenticated;
