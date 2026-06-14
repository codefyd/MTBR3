-- =====================================================================
-- تحديث: تبويب المستهدفات اليومية (هدف يومي/شهري + متابعة المحقق)
-- شغّل هذا الملف بالكامل في Supabase > SQL Editor > New Query > Run
-- يعتمد على schema.sql + الترقيات السابقة.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) جدول إعداد الشهر: الهدف الافتراضي اليومي + تجاوز يدوي للموسم
--    month_key بصيغة 'YYYY-MM' (ميلادي). الموسم يُكتشف تلقائيًا في الواجهة
--    من التاريخ الهجري، وهذا الحقل لتجاوزه يدويًا عند الحاجة فقط.
-- ---------------------------------------------------------------------
create table if not exists public.monthly_targets (
  month_key       text primary key,              -- '2026-03'
  default_daily   numeric not null default 0,     -- الهدف الافتراضي لكل يوم
  season_override text,                            -- تجاوز يدوي لاسم الموسم (اختياري)
  updated_at      timestamptz default now()
);

-- ---------------------------------------------------------------------
-- 2) جدول اليوم: تجاوز الهدف اليومي + الخصم اليدوي + الملاحظات
--    day_date تاريخ ميلادي (date). أي يوم بلا صف هنا يأخذ الهدف الافتراضي.
-- ---------------------------------------------------------------------
create table if not exists public.daily_targets (
  day_date     date primary key,
  target_value numeric,            -- تجاوز هدف هذا اليوم (null => استخدم الافتراضي)
  deduction    numeric default 0,  -- خصم تبرعات يدوي لهذا اليوم
  note         text,               -- ملاحظات يدوية
  updated_at   timestamptz default now()
);

create index if not exists idx_daily_targets_month on public.daily_targets (day_date);

-- ---------------------------------------------------------------------
-- 3) حفظ إعداد الشهر (upsert)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 4) حفظ يوم واحد (upsert). لمسح تجاوز اليوم مرّر القيم فارغة/صفرية.
-- ---------------------------------------------------------------------
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

grant execute on function public.save_monthly_target(text, numeric, text) to authenticated;
grant execute on function public.save_daily_target(date, numeric, numeric, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5) بيانات الشهر: المحقق الفعلي اليومي من العمليات + الإدخال اليدوي
--    لكل يوم من أيام الشهر نُرجع:
--      achieved   : مجموع تبرعات اليوم (عملية فريدة = phone+operation_no)
--      donors     : عدد المتبرعين الفريدين في اليوم
--      new_donors : من تبرّع لأول مرة في النظام بهذا اليوم
--      target     : تجاوز اليوم إن وُجد، وإلا الهدف الافتراضي للشهر
--      deduction  : خصم اليوم اليدوي
--      note       : ملاحظة اليوم
--    التراكمي والصافي والنِسب تُحسب في الواجهة لمرونة العرض.
-- ---------------------------------------------------------------------
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

grant execute on function public.targets_month_data(integer, integer) to authenticated;

-- ---------------------------------------------------------------------
-- 6) الأمان (RLS)
-- ---------------------------------------------------------------------
alter table public.monthly_targets enable row level security;
alter table public.daily_targets   enable row level security;

drop policy if exists "auth read monthly_targets" on public.monthly_targets;
create policy "auth read monthly_targets" on public.monthly_targets for select to authenticated using (true);
drop policy if exists "auth write monthly_targets" on public.monthly_targets;
create policy "auth write monthly_targets" on public.monthly_targets for all to authenticated using (true) with check (true);

drop policy if exists "auth read daily_targets" on public.daily_targets;
create policy "auth read daily_targets" on public.daily_targets for select to authenticated using (true);
drop policy if exists "auth write daily_targets" on public.daily_targets;
create policy "auth write daily_targets" on public.daily_targets for all to authenticated using (true) with check (true);

-- =====================================================================
-- تم. ارفع targets.html و assets/app.js المعدّل، ثم Ctrl+F5.
-- =====================================================================
