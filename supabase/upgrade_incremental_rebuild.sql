-- =====================================================================
-- تحديث: التحديث التزايدي لملفات المتبرعين
-- بدل إعادة احتساب كل المتبرعين بعد رفع ملف، نحدّث فقط أرقام الملف المرفوع.
-- شغّل هذا الملف بالكامل في Supabase > SQL Editor > New Query > Run.
-- يعتمد على schema.sql + upgrade_phone_acceptance_and_speed.sql
--          + fix_timeout_batch_rebuild.sql + upgrade_response_and_reports.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) إعادة تعريف دالة الدفعة لتقبل التحكم في التنظيف الشامل.
--    p_cleanup = true  (الافتراضي): سلوك سابق — في آخر دفعة يحذف المتبرعين
--                بلا أي عمليات. يُستخدم في إعادة الاحتساب الكامل.
--    p_cleanup = false : للتحديث التزايدي — لا يلمس بقية المتبرعين إطلاقًا.
--    نُسقط التوقيع القديم (معامل واحد) أولًا لتفادي تعدد النسخ المتعارض.
-- ---------------------------------------------------------------------
drop function if exists public.donor_rebuild_chunk(integer);

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

grant execute on function public.donor_rebuild_chunk(integer, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 2) بذر مفاتيح إعادة البناء لمجموعة أرقام محددة فقط (التحديث التزايدي).
--    يُستخدم بعد رفع ملف عمليات أو مستهدفين: نمرّر أرقام الملف فقط.
--    لا يُفرّغ الطابور (على عكس donor_rebuild_start) بل يضيف فقط.
-- ---------------------------------------------------------------------
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

grant execute on function public.donor_rebuild_start_for_phones(text[]) to authenticated;

-- =====================================================================
-- تم. ارفع assets/app.js و operations.html و campaigns.html المعدّلة، ثم Ctrl+F5.
-- =====================================================================
