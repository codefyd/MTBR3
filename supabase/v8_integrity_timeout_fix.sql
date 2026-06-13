-- =====================================================================
-- MTBR3 v8 - إصلاح سلامة حفظ العمليات + معالجة timeout في المستهدفين
--
-- المشاكل التي يعالجها:
-- 1) عدم حفظ كل صفوف العمليات عندما يتكرر رقم العملية أو يتكرر نفس (رقم، #العملية)
--    مع اختلاف الجوال/المشروع/المبلغ.
-- 2) timeout عند رفع ملف المستهدفين بسبب recalculate_donors الكامل.
-- 3) منع تضخم جدول campaign_targets عند إعادة رفع نفس ملف المستهدفين.
--
-- بعد تشغيل هذا الملف:
-- - ارفع operations.html + campaigns.html المعدلة.
-- - أعد رفع ملف العمليات الذي كان ناقصًا.
-- - أعد احتساب ملفات المتبرعين من الزر اليدوي أو اترك الواجهة تعمل بالدفعات.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) دالة تنظيف رقم الجوال الصحيحة للمستهدفين؛ ترجع رقمًا صحيحًا فقط أو NULL
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

-- ---------------------------------------------------------------------
-- 2) مفتاح ثابت للصف الواحد في العمليات
--    لا نعتمد على operation_no وحده ولا على (line_no, operation_no) فقط.
--    هذا يسمح بأن تحتوي العملية الواحدة على أكثر من جوال/مشروع/مبلغ دون دمج خاطئ.
-- ---------------------------------------------------------------------
create or replace function public.operation_import_key(
  p_line_no bigint,
  p_operation_no bigint,
  p_phone_raw text,
  p_project text,
  p_value numeric,
  p_quantity numeric,
  p_total numeric,
  p_op_datetime timestamptz
)
returns text
language sql
stable
as $$
  select md5(concat_ws('|',
    coalesce(p_line_no::text, ''),
    coalesce(p_operation_no::text, ''),
    regexp_replace(coalesce(p_phone_raw, ''), '[^0-9]', '', 'g'),
    lower(btrim(coalesce(p_project, ''))),
    coalesce(p_value::text, ''),
    coalesce(p_quantity::text, ''),
    coalesce(p_total::text, ''),
    coalesce(to_char(p_op_datetime at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'), '')
  ));
$$;

alter table public.operations add column if not exists import_key text;

update public.operations
set import_key = public.operation_import_key(
  line_no,
  operation_no,
  phone_raw,
  project,
  value,
  quantity,
  total,
  op_datetime
)
where import_key is null;

-- حذف التكرار المطابق فقط قبل إنشاء الفهرس الفريد.
delete from public.operations o
using (
  select
    id,
    row_number() over (
      partition by import_key
      order by updated_at desc nulls last, created_at desc nulls last, id desc
    ) as rn
  from public.operations
  where import_key is not null
) d
where o.id = d.id
  and d.rn > 1;

-- إزالة القيود القديمة التي كانت تدمج صفوفًا مختلفة.
alter table if exists public.operations drop constraint if exists uq_operations_operation_no_conflict;
alter table if exists public.operations drop constraint if exists uq_operations_operation_no;
alter table if exists public.operations drop constraint if exists operations_operation_no_key;
alter table if exists public.operations drop constraint if exists uq_operations_line_operation;
alter table if exists public.operations drop constraint if exists uq_operation;

drop index if exists public.uq_operations_operation_no_conflict;
drop index if exists public.uq_operations_operation_no;
drop index if exists public.operations_operation_no_key;
drop index if exists public.uq_operations_line_operation;
drop index if exists public.uq_operation;

create unique index if not exists uq_operations_import_key on public.operations (import_key);
create index if not exists idx_operations_line_operation on public.operations (line_no, operation_no);
create index if not exists idx_operations_operation_no on public.operations (operation_no);
create index if not exists idx_operations_datetime on public.operations (op_datetime);
create index if not exists idx_operations_phone_datetime on public.operations (phone, op_datetime) where phone is not null;
create index if not exists idx_operations_phone_status on public.operations (phone_status);
create index if not exists idx_operations_project on public.operations (project) where project is not null;

-- ---------------------------------------------------------------------
-- 3) دالة رفع العمليات الجديدة
-- ---------------------------------------------------------------------
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
    where nullif(r->>'operation_no','') is not null
  ), incoming as (
    select
      i.*,
      public.operation_phone_info(i.phone_raw, i.line_no, i.operation_no) as ph,
      public.operation_import_key(
        coalesce(i.line_no, i.operation_no),
        i.operation_no,
        i.phone_raw,
        i.project,
        i.value,
        i.quantity,
        i.total,
        i.op_datetime
      ) as import_key
    from incoming0 i
  ), deduped as (
    -- نزيل التكرار المطابق داخل نفس الدفعة فقط.
    -- الصفوف التي تختلف في الجوال/المشروع/المبلغ لا تُدمج.
    select distinct on (import_key)
      coalesce(line_no, operation_no) as line_no,
      operation_no,
      donor_name,
      phone_raw,
      ph,
      project,
      referral_code,
      value,
      quantity,
      total,
      op_datetime,
      import_key
    from incoming
    where import_key is not null
    order by import_key, op_datetime desc nulls last
  ), ins as (
    insert into public.operations (
      line_no, operation_no, donor_name, phone_raw, phone, phone_status, phone_issue,
      project, referral_code, value, quantity, total, op_datetime, import_key, updated_at
    )
    select
      line_no,
      operation_no,
      donor_name,
      phone_raw,
      ph->>'phone',
      ph->>'status',
      ph->>'issue',
      project,
      referral_code,
      value,
      quantity,
      total,
      op_datetime,
      import_key,
      now()
    from deduped
    on conflict (import_key) do update set
      line_no       = excluded.line_no,
      operation_no  = excluded.operation_no,
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

grant execute on function public.operation_import_key(bigint, bigint, text, text, numeric, numeric, numeric, timestamptz) to authenticated;
grant execute on function public.upsert_operations(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 4) المستهدفون في الحملات: مفتاح منع تكرار + دالة رفع لا تسبب تكرارًا
-- ---------------------------------------------------------------------
alter table public.campaign_targets add column if not exists target_key text;

update public.campaign_targets
set target_key = md5(concat_ws('|',
  coalesce(phone, ''),
  lower(btrim(coalesce(campaign_name, ''))),
  coalesce(to_char(target_date at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'), '')
))
where target_key is null;

delete from public.campaign_targets c
using (
  select
    id,
    row_number() over (
      partition by target_key
      order by created_at desc nulls last, id desc
    ) as rn
  from public.campaign_targets
  where target_key is not null
) d
where c.id = d.id
  and d.rn > 1;

create unique index if not exists uq_campaign_targets_target_key on public.campaign_targets (target_key);
create index if not exists idx_campaign_targets_phone on public.campaign_targets (phone) where phone is not null;
create index if not exists idx_campaign_targets_date on public.campaign_targets (target_date);

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

grant execute on function public.insert_campaign_targets(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 5) إعادة بناء المتبرعين على دفعات - عدد التبرعات = عدد صفوف العمليات المحفوظة
-- ---------------------------------------------------------------------
create index if not exists idx_operations_phone_rebuild on public.operations (phone) where phone is not null;
create index if not exists idx_operations_phone_datetime_rebuild on public.operations (phone, op_datetime) where phone is not null;
create index if not exists idx_campaign_targets_phone_rebuild on public.campaign_targets (phone) where phone is not null;
create index if not exists idx_donors_phone_status_rebuild on public.donors (phone_status);

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

grant execute on function public.donor_rebuild_start() to authenticated;
grant execute on function public.donor_rebuild_chunk(integer) to authenticated;

-- ---------------------------------------------------------------------
-- 6) ملخص سنة للمطابقة مع الشيت/المتجر
-- ---------------------------------------------------------------------
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
    'empty_total_rows', count(*) filter (where total is null),
    'same_operation_multiple_rows', (
      select count(*)
      from (
        select operation_no
        from public.operations
        where op_datetime >= make_timestamptz(p_year, 1, 1, 0, 0, 0, 'Asia/Riyadh')
          and op_datetime <  make_timestamptz(p_year + 1, 1, 1, 0, 0, 0, 'Asia/Riyadh')
        group by operation_no
        having count(*) > 1
      ) x
    )
  )
  from public.operations
  where op_datetime >= make_timestamptz(p_year, 1, 1, 0, 0, 0, 'Asia/Riyadh')
    and op_datetime <  make_timestamptz(p_year + 1, 1, 1, 0, 0, 0, 'Asia/Riyadh');
$$;

grant execute on function public.operations_year_summary(integer) to authenticated;

-- بعد التنفيذ يمكن التحقق:
-- select public.operations_year_summary(2026);
