-- =====================================================================
-- MTBR3 v7 - إصلاح نقص عدد العمليات والمبالغ
-- السبب: منع التكرار على operation_no وحده يحذف/يستبدل الصفوف التي لها نفس رقم العملية.
-- التصحيح: منع التكرار يكون على (line_no, operation_no) مثل تصميم الجدول الأصلي.
-- بعد تشغيل هذا الملف: أعد رفع ملفات 2026، ثم أعد احتساب ملفات المتبرعين.
-- =====================================================================

-- 1) إزالة القيد/الفهرس الخاطئ إن وجد: رقم العملية وحده ليس كافيًا لتمييز الصف.
alter table if exists public.operations drop constraint if exists uq_operations_operation_no;
drop index if exists public.uq_operations_operation_no;

-- 2) ضمان عدم وجود تكرار مطابق لنفس الصف قبل إنشاء القيد الصحيح.
--    إذا تكرر نفس (line_no, operation_no) بسبب رفع سابق، نُبقي آخر نسخة فقط.
delete from public.operations o
using (
  select
    id,
    row_number() over (
      partition by line_no, operation_no
      order by updated_at desc nulls last, created_at desc nulls last, id desc
    ) as rn
  from public.operations
  where line_no is not null
    and operation_no is not null
) x
where o.id = x.id
  and x.rn > 1;

-- 3) القيد الصحيح: نفس الملف إذا أُعيد رفعه لا يتكرر،
--    لكن إذا ظهر نفس operation_no في أكثر من سطر line_no مختلف فلا يُحذف.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'uq_operations_line_operation'
      and conrelid = 'public.operations'::regclass
  ) then
    alter table public.operations
      add constraint uq_operations_line_operation
      unique (line_no, operation_no);
  end if;
end;
$$;

create index if not exists idx_operations_operation_no on public.operations (operation_no);
create index if not exists idx_operations_datetime on public.operations (op_datetime);
create index if not exists idx_operations_phone_datetime on public.operations (phone, op_datetime) where phone is not null;
create index if not exists idx_operations_phone_line_operation on public.operations (phone, line_no, operation_no) where phone is not null;

-- 4) دالة الرفع: تحفظ كل صف مستقل حسب (line_no, operation_no)
--    ولا تختزل الصفوف المتشابهة في operation_no.
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

grant execute on function public.upsert_operations(jsonb) to authenticated;

-- 5) إعادة الاحتساب الكامل: عدد التبرعات = عدد صفوف العمليات المحفوظة، وليس distinct operation_no.
create or replace function public.recalculate_donors()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inactive_days integer;
  v_categories jsonb;
begin
  select inactive_days, categories
    into v_inactive_days, v_categories
  from public.settings
  where id = 1;

  if v_inactive_days is null then
    v_inactive_days := 90;
  end if;

  truncate table public.donors;

  insert into public.donors (
    phone, phone_raw, phone_status, phone_issue, donor_name,
    first_donation, last_donation, total_amount, donations_count, projects,
    sat_count, sun_count, mon_count, tue_count, wed_count, thu_count, fri_count,
    period_morning, period_noon, period_evening, period_night, no_time_count
  )
  select
    o.phone,
    (array_agg(o.phone_raw order by o.op_datetime desc nulls last, o.updated_at desc nulls last, o.id desc))[1] as phone_raw,
    (array_agg(coalesce(o.phone_status, 'صحيح') order by o.op_datetime desc nulls last, o.updated_at desc nulls last, o.id desc))[1] as phone_status,
    (array_agg(o.phone_issue order by o.op_datetime desc nulls last, o.updated_at desc nulls last, o.id desc))[1] as phone_issue,
    (array_agg(o.donor_name order by o.op_datetime desc nulls last, o.updated_at desc nulls last, o.id desc))[1] as donor_name,
    min(o.op_datetime) as first_donation,
    max(o.op_datetime) as last_donation,
    coalesce(sum(o.total), 0) as total_amount,
    count(*)::integer as donations_count,
    array_remove(array_agg(distinct nullif(btrim(o.project), '')), null)::text[] as projects,
    count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 6)::integer as sat_count,
    count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 0)::integer as sun_count,
    count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 1)::integer as mon_count,
    count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 2)::integer as tue_count,
    count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 3)::integer as wed_count,
    count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 4)::integer as thu_count,
    count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 5)::integer as fri_count,
    count(*) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 4 and extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 12)::integer as period_morning,
    count(*) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 12 and extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 16)::integer as period_noon,
    count(*) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 16 and extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 19)::integer as period_evening,
    count(*) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 19 or extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 4)::integer as period_night,
    count(*) filter (where o.op_datetime is null)::integer as no_time_count
  from public.operations o
  where o.phone is not null
  group by o.phone;

  update public.donors d
  set targeted_count = t.cnt,
      last_targeted = t.last_dt
  from (
    select phone, count(*)::integer as cnt, max(target_date) as last_dt
    from public.campaign_targets
    where phone is not null
    group by phone
  ) t
  where d.phone = t.phone;

  update public.donors
  set status = case
    when last_donation is null then 'خامل'
    when last_donation >= (now() - (v_inactive_days || ' days')::interval) then 'مستمر'
    else 'خامل'
  end;

  update public.donors d
  set category = sub.cat
  from (
    select d2.phone,
      (
        select c->>'name'
        from jsonb_array_elements(coalesce(v_categories, '[]'::jsonb)) c
        where d2.donations_count >= coalesce((c->>'min')::int, 0)
          and (
            c->>'max' is null
            or c->>'max' = 'null'
            or d2.donations_count <= (c->>'max')::int
          )
        order by coalesce((c->>'min')::int, 0) desc
        limit 1
      ) as cat
    from public.donors d2
  ) sub
  where d.phone = sub.phone;

  update public.donors set updated_at = now();
end;
$$;

grant execute on function public.recalculate_donors() to authenticated;

-- 6) إعادة البناء على دفعات: نفس منطق العد الصفّي.
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
      count(*)::integer as donations_count,
      array_remove(array_agg(distinct nullif(btrim(o.project), '')), null)::text[] as projects,
      count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 6)::integer as sat_count,
      count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 0)::integer as sun_count,
      count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 1)::integer as mon_count,
      count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 2)::integer as tue_count,
      count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 3)::integer as wed_count,
      count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 4)::integer as thu_count,
      count(*) filter (where extract(dow from (o.op_datetime at time zone 'Asia/Riyadh'))::int = 5)::integer as fri_count,
      count(*) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 4 and extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 12)::integer as period_morning,
      count(*) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 12 and extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 16)::integer as period_noon,
      count(*) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 16 and extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 19)::integer as period_evening,
      count(*) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 19 or extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 4)::integer as period_night,
      count(*) filter (where o.op_datetime is null)::integer as no_time_count
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

grant execute on function public.donor_rebuild_chunk(integer) to authenticated;

-- 7) لوحة التحكم: الحساب من صفوف العمليات مباشرة، وليس من رقم العملية الفريد.
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

grant execute on function public.dashboard_stats() to authenticated;

-- 8) استعلام سريع للتأكد بعد إعادة رفع ملفات 2026.
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

grant execute on function public.operations_year_summary(integer) to authenticated;
