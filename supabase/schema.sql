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
-- تنظيف وتطبيع رقم الجوال:
--   * السعودي الصحيح  => 966 + 5 + مشغّل صحيح + 7 خانات
--   * الأجنبي          => يُترك كما هو (رمز دولة معروف أو طول دولي معقول)
--   * المبتور/الخاطئ   => null (يُرفض ويُسجّل في تقرير الرفض من جهة التطبيق)
-- المشغّلات السعودية المقبولة: 50,53,54,55,56,57,58,59
create or replace function clean_phone(raw text)
returns text
language plpgsql
immutable
as $$
declare
  d   text;
  op  text;
begin
  if raw is null then return null; end if;
  d := regexp_replace(raw, '[^0-9]', '', 'g');
  if d = '' then return null; end if;
  d := regexp_replace(d, '^00', '');   -- بادئة دولية 00

  -- سعودي بصيغة 966 + 5XXXXXXXX
  if d ~ '^9665[0-9]{8}$' then
    op := substring(d from 4 for 2);
    if op in ('50','51','53','54','55','56','57','58','59') then return d; end if;
    return null;
  end if;

  -- محلي بصفر بادئ 05XXXXXXXX
  if d ~ '^05[0-9]{8}$' then
    op := substring(d from 2 for 2);
    if op in ('50','51','53','54','55','56','57','58','59') then return '966' || substring(d from 2); end if;
    return null;
  end if;

  -- محلي 9 خانات 5XXXXXXXX
  if d ~ '^5[0-9]{8}$' then
    op := substring(d from 1 for 2);
    if op in ('50','51','53','54','55','56','57','58','59') then return '966' || d; end if;
    return null;
  end if;

  -- يبدأ بـ966 لكن غير مطابق للصيغة السعودية => غير صالح
  if left(d, 3) = '966' then return null; end if;

  -- أجنبي: طول دولي معقول (8 إلى 15) => يُترك كما هو
  if length(d) between 8 and 15 then return d; end if;

  -- غير ذلك: مبتور/غير صالح
  return null;
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
  no_time_count       integer default 0,   -- عمليات بلا تاريخ/وقت صالح
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

  -- نحسب لكل عملية فريدة (phone + operation_no) ختمًا زمنيًا واحدًا فقط
  -- (أقدم op_datetime غير فارغ للعملية). بهذا تُحسب العملية مرة واحدة في
  -- تحليل الأيام/الأوقات، فيتطابق مجموع الأيام (ومجموع الفترات) مع عدد التبرعات
  -- باستثناء العمليات التي لا تملك تاريخًا/وقتًا صالحًا.
  insert into donors (
    phone, donor_name, first_donation, last_donation,
    total_amount, donations_count, projects,
    sat_count, sun_count, mon_count, tue_count, wed_count, thu_count, fri_count,
    period_morning, period_noon, period_evening, period_night, no_time_count
  )
  select
    agg.phone,
    agg.donor_name,
    agg.first_donation,
    agg.last_donation,
    agg.total_amount,
    agg.donations_count,
    agg.projects,
    coalesce(opx.sat_count,0), coalesce(opx.sun_count,0), coalesce(opx.mon_count,0),
    coalesce(opx.tue_count,0), coalesce(opx.wed_count,0), coalesce(opx.thu_count,0),
    coalesce(opx.fri_count,0),
    coalesce(opx.period_morning,0), coalesce(opx.period_noon,0),
    coalesce(opx.period_evening,0), coalesce(opx.period_night,0),
    -- العمليات الفريدة بلا تاريخ صالح = إجمالي العمليات الفريدة - العمليات ذات التاريخ
    greatest(agg.donations_count - coalesce(opx.timed_ops,0), 0)
  from (
    -- تجميع على مستوى المتبرع: الإجماليات وعدد التبرعات والمشاريع
    select
      o.phone,
      (array_agg(o.donor_name order by o.op_datetime desc nulls last))[1] as donor_name,
      min(o.op_datetime) as first_donation,
      max(o.op_datetime) as last_donation,
      coalesce(sum(o.total), 0) as total_amount,
      count(distinct o.operation_no) as donations_count,
      array(
        select distinct p from unnest(array_agg(o.project)) as p
        where p is not null and btrim(p) <> ''
      ) as projects
    from operations o
    where o.phone is not null
    group by o.phone
  ) agg
  left join (
    -- ختم زمني واحد لكل عملية فريدة ثم تجميع الأيام/الفترات
    select
      uo.phone,
      count(*) filter (where dow = 6) as sat_count,
      count(*) filter (where dow = 0) as sun_count,
      count(*) filter (where dow = 1) as mon_count,
      count(*) filter (where dow = 2) as tue_count,
      count(*) filter (where dow = 3) as wed_count,
      count(*) filter (where dow = 4) as thu_count,
      count(*) filter (where dow = 5) as fri_count,
      count(*) filter (where hr >= 4  and hr < 12) as period_morning,
      count(*) filter (where hr >= 12 and hr < 16) as period_noon,
      count(*) filter (where hr >= 16 and hr < 19) as period_evening,
      count(*) filter (where hr >= 19 or  hr < 4)  as period_night,
      count(*) as timed_ops
    from (
      select
        phone, operation_no,
        extract(dow  from (op_dt at time zone 'Asia/Riyadh'))::int as dow,
        extract(hour from (op_dt at time zone 'Asia/Riyadh'))::int as hr
      from (
        -- صف واحد لكل (phone, operation_no): أقدم تاريخ غير فارغ للعملية
        select phone, operation_no, min(op_datetime) as op_dt
        from operations
        where phone is not null and op_datetime is not null
        group by phone, operation_no
      ) per_op
    ) uo
    group by uo.phone
  ) opx on opx.phone = agg.phone;

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
  end
  where phone is not null;

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

  update donors set updated_at = now() where phone is not null;
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
-- 9.1) تقارير لوحة التحكم — كل الأرقام تُحسب من جدول العمليات مباشرة
--       (تُحسب العملية الواحدة تبرعًا واحدًا = phone + operation_no)
-- ---------------------------------------------------------------------
create or replace function dashboard_stats()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  result        jsonb;
  v_month_start timestamptz := date_trunc('month', (now() at time zone 'Asia/Riyadh'));
  v_year_start  timestamptz := date_trunc('year',  (now() at time zone 'Asia/Riyadh'));
begin
  with per_op as (
    -- صف واحد لكل عملية فريدة: المبلغ = مجموع صفوفها، التاريخ = أقدم تاريخ صالح
    select
      phone, operation_no,
      sum(total)            as op_total,
      min(op_datetime)      as op_dt
    from operations
    where phone is not null
    group by phone, operation_no
  ),
  loc as (
    select
      *,
      (op_dt at time zone 'Asia/Riyadh')               as op_local,
      extract(dow  from (op_dt at time zone 'Asia/Riyadh'))::int as dow,
      (op_dt at time zone 'Asia/Riyadh')::date          as op_date
    from per_op
    where op_dt is not null
  ),
  -- تبرعات الشهر الحالي
  month_agg as (
    select coalesce(sum(op_total),0) as sum_amt, count(*) as cnt
    from per_op where op_dt >= v_month_start
  ),
  -- تبرعات السنة الحالية
  year_agg as (
    select coalesce(sum(op_total),0) as sum_amt, count(*) as cnt
    from per_op where op_dt >= v_year_start
  ),
  -- أفضل يوم في الأسبوع خلال الشهر الحالي (حسب عدد التبرعات)
  best_dow as (
    select dow, count(*) as cnt, coalesce(sum(op_total),0) as amt
    from loc where op_local >= v_month_start
    group by dow order by cnt desc limit 1
  ),
  -- أفضل تاريخ (يوم) جاءت فيه أكبر تبرعات خلال السنة
  best_date as (
    select op_date, count(*) as cnt, coalesce(sum(op_total),0) as amt
    from loc where op_local >= v_year_start
    group by op_date order by amt desc limit 1
  ),
  -- المتبرعون الفريدون هذا الشهر
  uniq_month as (
    select count(distinct phone) as c from per_op where op_dt >= v_month_start
  ),
  -- توزيع التبرعات على أيام الأسبوع خلال السنة
  dow_dist as (
    select dow, count(*) as cnt
    from loc where op_local >= v_year_start
    group by dow
  ),
  -- المتبرعون الفريدون عبر السنوات
  donors_by_year as (
    select extract(year from op_local)::int as yr, count(distinct phone) as c
    from loc group by yr order by yr
  ),
  -- التبرعات الشهرية خلال السنة الحالية (مبلغ + عدد)
  monthly as (
    select extract(month from op_local)::int as mo,
           coalesce(sum(op_total),0) as amt, count(*) as cnt
    from loc where op_local >= v_year_start
    group by mo order by mo
  )
  select jsonb_build_object(
    'month_sum',        (select sum_amt from month_agg),
    'month_count',      (select cnt     from month_agg),
    'year_sum',         (select sum_amt from year_agg),
    'year_count',       (select cnt     from year_agg),
    'unique_month',     (select c       from uniq_month),
    'total_donors',     (select count(*) from donors),
    'best_dow',         (select to_jsonb(best_dow)  from best_dow),
    'best_date',        (select to_jsonb(best_date) from best_date),
    'dow_dist',         (select coalesce(jsonb_agg(to_jsonb(dow_dist)),'[]'::jsonb) from dow_dist),
    'donors_by_year',   (select coalesce(jsonb_agg(to_jsonb(donors_by_year)),'[]'::jsonb) from donors_by_year),
    'monthly',          (select coalesce(jsonb_agg(to_jsonb(monthly)),'[]'::jsonb) from monthly)
  ) into result;

  return result;
end;
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
grant execute on function dashboard_stats()               to authenticated;
grant execute on function update_settings(integer, jsonb) to authenticated;
-- =====================================================================
-- تحديث: قبول أرقام الجوال الخاطئة/الفارغة + تقرير الحالة + تسريع ملفات المتبرعين
-- شغّل الملف في Supabase SQL Editor مرة واحدة، ثم ارفع الملفات المعدّلة.
-- =====================================================================

-- 1) تنظيف الرقم الصحيح فقط، مع قبول 52 ضمن مشغلات السعودية
create or replace function clean_phone(raw text)
returns text
language plpgsql
immutable
as $$
declare
  d   text;
  op  text;
begin
  if raw is null then return null; end if;
  d := regexp_replace(raw, '[^0-9]', '', 'g');
  if d = '' then return null; end if;
  d := regexp_replace(d, '^00', '');

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
  if length(d) between 8 and 15 then return d; end if;
  return null;
end;
$$;

-- 2) تصنيف رقم العملية: صحيح / خاطئ / فارغ
--    ملاحظة: الخاطئ والفارغ يأخذان مفتاحًا داخليًا حتى لا تُستبعد عملياتهم من التحليلات.
create or replace function operation_phone_info(raw text, p_line_no bigint, p_operation_no bigint)
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

-- 3) أعمدة حالة الرقم
alter table operations add column if not exists phone_status text;
alter table operations add column if not exists phone_issue text;
alter table donors add column if not exists phone_raw text;
alter table donors add column if not exists phone_status text default 'صحيح';
alter table donors add column if not exists phone_issue text;

-- 4) تسريع الاستعلامات الثقيلة
create index if not exists idx_operations_phone_status on operations (phone_status);
create index if not exists idx_operations_project on operations (project) where project is not null;
create index if not exists idx_donors_phone_status on donors (phone_status);
create index if not exists idx_donors_total on donors (total_amount);
create index if not exists idx_donors_projects_gin on donors using gin (projects);

-- 5) منع تكرار العمليات حسب رقم العملية فقط
--    هذا يعالج خطأ: there is no unique or exclusion constraint matching the ON CONFLICT specification
--    لأن قاعدة المشروع تعتمد على operation_no لمنع تكرار رفع نفس الملف.
delete from public.operations o
using (
  select
    id,
    row_number() over (
      partition by operation_no
      order by updated_at desc nulls last, created_at desc nulls last, id desc
    ) as rn
  from public.operations
  where operation_no is not null
) x
where o.id = x.id
  and x.rn > 1;

create unique index if not exists uq_operations_operation_no
on public.operations (operation_no);

-- 5.1) دالة رفع العمليات: لا ترفض الخاطئ/الفارغ، بل تحفظه بحالة واضحة
create or replace function upsert_operations(rows jsonb)
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
    where nullif(r->>'operation_no','') is not null
  ), incoming as (
    select
      i.*,
      operation_phone_info(i.phone_raw, i.line_no, i.operation_no) as ph
    from incoming0 i
  ), deduped as (
    -- لو تكرر رقم العملية داخل نفس الملف، نأخذ آخر صف منه
    select distinct on (operation_no)
      line_no, operation_no, donor_name, phone_raw, ph,
      project, referral_code, value, quantity, total, op_datetime
    from incoming
    order by operation_no, line_no desc nulls last
  ), ins as (
    insert into operations (
      line_no, operation_no, donor_name, phone_raw, phone, phone_status, phone_issue,
      project, referral_code, value, quantity, total, op_datetime, updated_at
    )
    select
      coalesce(line_no, operation_no), operation_no, donor_name, phone_raw,
      ph->>'phone', ph->>'status', ph->>'issue',
      project, referral_code, value, quantity, total, op_datetime, now()
    from deduped
    on conflict (operation_no) do update set
      line_no       = excluded.line_no,
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

-- 6) تصحيح العمليات القديمة التي كانت phone فيها null أو بلا حالة
with fixed as (
  select id, operation_phone_info(phone_raw, line_no, operation_no) as ph
  from operations
  where phone is null or phone_status is null
)
update operations o
set phone = fixed.ph->>'phone',
    phone_status = fixed.ph->>'status',
    phone_issue = fixed.ph->>'issue',
    updated_at = now()
from fixed
where o.id = fixed.id;

-- 7) إعادة حساب ملفات المتبرعين مع إدخال الخاطئ/الفارغ كمراجعة بدل استبعادهم
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
    phone, phone_raw, phone_status, phone_issue, donor_name, first_donation, last_donation,
    total_amount, donations_count, projects,
    sat_count, sun_count, mon_count, tue_count, wed_count, thu_count, fri_count,
    period_morning, period_noon, period_evening, period_night, no_time_count
  )
  select
    agg.phone,
    agg.phone_raw,
    agg.phone_status,
    agg.phone_issue,
    agg.donor_name,
    agg.first_donation,
    agg.last_donation,
    agg.total_amount,
    agg.donations_count,
    agg.projects,
    coalesce(opx.sat_count,0), coalesce(opx.sun_count,0), coalesce(opx.mon_count,0),
    coalesce(opx.tue_count,0), coalesce(opx.wed_count,0), coalesce(opx.thu_count,0),
    coalesce(opx.fri_count,0),
    coalesce(opx.period_morning,0), coalesce(opx.period_noon,0),
    coalesce(opx.period_evening,0), coalesce(opx.period_night,0),
    greatest(agg.donations_count - coalesce(opx.timed_ops,0), 0)
  from (
    select
      o.phone,
      (array_agg(o.phone_raw order by o.op_datetime desc nulls last))[1] as phone_raw,
      (array_agg(coalesce(o.phone_status,'صحيح') order by o.op_datetime desc nulls last))[1] as phone_status,
      (array_agg(o.phone_issue order by o.op_datetime desc nulls last))[1] as phone_issue,
      (array_agg(o.donor_name order by o.op_datetime desc nulls last))[1] as donor_name,
      min(o.op_datetime) as first_donation,
      max(o.op_datetime) as last_donation,
      coalesce(sum(o.total), 0) as total_amount,
      count(distinct o.operation_no) as donations_count,
      array(
        select distinct p from unnest(array_agg(o.project)) as p
        where p is not null and btrim(p) <> ''
      ) as projects
    from operations o
    where o.phone is not null
    group by o.phone
  ) agg
  left join (
    select
      uo.phone,
      count(*) filter (where dow = 6) as sat_count,
      count(*) filter (where dow = 0) as sun_count,
      count(*) filter (where dow = 1) as mon_count,
      count(*) filter (where dow = 2) as tue_count,
      count(*) filter (where dow = 3) as wed_count,
      count(*) filter (where dow = 4) as thu_count,
      count(*) filter (where dow = 5) as fri_count,
      count(*) filter (where hr >= 4  and hr < 12) as period_morning,
      count(*) filter (where hr >= 12 and hr < 16) as period_noon,
      count(*) filter (where hr >= 16 and hr < 19) as period_evening,
      count(*) filter (where hr >= 19 or  hr < 4)  as period_night,
      count(*) as timed_ops
    from (
      select
        phone, operation_no,
        extract(dow  from (op_dt at time zone 'Asia/Riyadh'))::int as dow,
        extract(hour from (op_dt at time zone 'Asia/Riyadh'))::int as hr
      from (
        select phone, operation_no, min(op_datetime) as op_dt
        from operations
        where phone is not null and op_datetime is not null
        group by phone, operation_no
      ) per_op
    ) uo
    group by uo.phone
  ) opx on opx.phone = agg.phone;

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
  end
  where phone is not null;

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

  update donors set updated_at = now() where phone is not null;
end;
$$;

-- 8) جلب قائمة المشاريع بسرعة بدل مسح العمليات من المتصفح
create or replace function operations_projects()
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

-- 9) تحديث ملفات المتبرعين بعد ترحيل البيانات القديمة
-- لا يتم تشغيل recalculate_donors هنا حتى لا يحدث timeout؛ الواجهة ستعيد البناء على دفعات.

-- =====================================================================
-- تصحيح timeout بعد رفع العمليات:
-- إعادة بناء ملفات المتبرعين على دفعات بدل عملية واحدة طويلة
-- شغّل هذا الملف في Supabase SQL Editor، ثم ارفع ملفات v3.
-- =====================================================================

-- جدول مفاتيح مؤقت عمليًا لتقسيم إعادة الاحتساب على عدة طلبات قصيرة.
create table if not exists public.donor_rebuild_keys (
  phone text primary key,
  created_at timestamptz default now()
);

create index if not exists idx_operations_phone_rebuild on public.operations (phone) where phone is not null;
create index if not exists idx_operations_phone_datetime_rebuild on public.operations (phone, op_datetime) where phone is not null;
create index if not exists idx_operations_phone_operation_rebuild on public.operations (phone, operation_no) where phone is not null;
create index if not exists idx_campaign_targets_phone_rebuild on public.campaign_targets (phone) where phone is not null;
create index if not exists idx_donors_phone_status_rebuild on public.donors (phone_status);

-- تجهيز قائمة أرقام المتبرعين المطلوب إعادة بنائها.
-- لا نحذف جدول donors هنا حتى لا تصبح الصفحة فارغة لو تعطل الاتصال في المنتصف.
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

-- تنفيذ دفعة واحدة من إعادة بناء ملفات المتبرعين.
create or replace function public.donor_rebuild_chunk(p_limit integer default 300)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_processed integer := 0;
  v_remaining integer := 0;
  v_inactive_days integer;
  v_categories jsonb;
begin
  if p_limit is null or p_limit <= 0 then
    p_limit := 300;
  end if;

  select inactive_days, categories
    into v_inactive_days, v_categories
  from public.settings
  where id = 1;

  if v_inactive_days is null then
    v_inactive_days := 90;
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
      targeted_count, last_targeted, status, category, updated_at
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
    on conflict (phone) do update set
      phone_raw       = excluded.phone_raw,
      phone_status    = excluded.phone_status,
      phone_issue     = excluded.phone_issue,
      donor_name      = excluded.donor_name,
      first_donation  = excluded.first_donation,
      last_donation   = excluded.last_donation,
      total_amount    = excluded.total_amount,
      donations_count = excluded.donations_count,
      projects        = excluded.projects,
      sat_count       = excluded.sat_count,
      sun_count       = excluded.sun_count,
      mon_count       = excluded.mon_count,
      tue_count       = excluded.tue_count,
      wed_count       = excluded.wed_count,
      thu_count       = excluded.thu_count,
      fri_count       = excluded.fri_count,
      period_morning  = excluded.period_morning,
      period_noon     = excluded.period_noon,
      period_evening  = excluded.period_evening,
      period_night    = excluded.period_night,
      no_time_count   = excluded.no_time_count,
      targeted_count  = excluded.targeted_count,
      last_targeted   = excluded.last_targeted,
      status          = excluded.status,
      category        = excluded.category,
      updated_at      = now()
    returning phone
  ), deleted as (
    delete from public.donor_rebuild_keys k
    using batch b
    where k.phone = b.phone
    returning k.phone
  )
  select count(*)::integer into v_processed from deleted;

  select count(*)::integer into v_remaining from public.donor_rebuild_keys;

  -- تنظيف أي ملف متبرع قديم لم يعد له أي عملية، ويتم فقط بعد اكتمال كل الدفعات.
  if v_remaining = 0 then
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

grant execute on function public.donor_rebuild_start() to authenticated;
grant execute on function public.donor_rebuild_chunk(integer) to authenticated;


grant execute on function clean_phone(text) to authenticated;
grant execute on function operation_phone_info(text, bigint, bigint) to authenticated;
grant execute on function upsert_operations(jsonb) to authenticated;
grant execute on function recalculate_donors() to authenticated;
grant execute on function operations_projects() to authenticated;
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
