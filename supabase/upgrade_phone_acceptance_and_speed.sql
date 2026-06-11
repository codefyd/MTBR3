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

-- 5) دالة رفع العمليات: لا ترفض الخاطئ/الفارغ، بل تحفظه بحالة واضحة
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
      (r->>'line_no')::bigint              as line_no,
      (r->>'operation_no')::bigint         as operation_no,
      nullif(r->>'donor_name','')          as donor_name,
      nullif(r->>'phone_raw','')           as phone_raw,
      nullif(r->>'project','')             as project,
      nullif(r->>'referral_code','')       as referral_code,
      nullif(r->>'value','')::numeric      as value,
      nullif(r->>'quantity','')::numeric   as quantity,
      nullif(r->>'total','')::numeric      as total,
      nullif(r->>'op_datetime','')::timestamptz as op_datetime
    from jsonb_array_elements(rows) as r
    where (r->>'line_no') is not null
      and (r->>'operation_no') is not null
  ), incoming as (
    select
      i.*,
      operation_phone_info(i.phone_raw, i.line_no, i.operation_no) as ph
    from incoming0 i
  ), ins as (
    insert into operations (
      line_no, operation_no, donor_name, phone_raw, phone, phone_status, phone_issue,
      project, referral_code, value, quantity, total, op_datetime, updated_at
    )
    select
      line_no, operation_no, donor_name, phone_raw,
      ph->>'phone', ph->>'status', ph->>'issue',
      project, referral_code, value, quantity, total, op_datetime, now()
    from incoming
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
select recalculate_donors();

grant execute on function clean_phone(text) to authenticated;
grant execute on function operation_phone_info(text, bigint, bigint) to authenticated;
grant execute on function upsert_operations(jsonb) to authenticated;
grant execute on function recalculate_donors() to authenticated;
grant execute on function operations_projects() to authenticated;
