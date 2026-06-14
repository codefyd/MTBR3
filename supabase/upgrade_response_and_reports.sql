-- =====================================================================
-- تحديث: استجابة المتبرع بعد الاستهداف + إعداد أيام الاستجابة + تبويب التقارير
-- شغّل هذا الملف بالكامل في Supabase > SQL Editor > New Query > Run
-- ثم ارفع ملفات الواجهة المعدّلة، واعمل Ctrl+F5، ثم «إعادة احتساب الملفات».
--
-- يعتمد هذا الملف على أنك شغّلت سابقًا:
--   schema.sql + upgrade_phone_acceptance_and_speed.sql + fix_timeout_batch_rebuild.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) إعداد جديد: عدد أيام الاستجابة (يُعتبر المتبرع مستجيبًا إذا تبرّع
--    خلال هذه المدة بعد آخر تاريخ استهداف له). إدخال حر بالأرقام.
-- ---------------------------------------------------------------------
alter table public.settings
  add column if not exists response_days integer not null default 30;

-- ---------------------------------------------------------------------
-- 2) أعمدة استجابة المتبرع في جدول المتبرعين (محسوبة تلقائيًا)
--    responded         : هل تبرّع خلال نافذة الاستجابة بعد آخر استهداف؟
--    response_date     : أول تبرع وقع بعد آخر استهداف وضمن النافذة
--    response_lag_days  : عدد الأيام بين آخر استهداف وأول تبرع مستجيب
-- ---------------------------------------------------------------------
alter table public.donors
  add column if not exists responded boolean default false;
alter table public.donors
  add column if not exists response_date timestamptz;
alter table public.donors
  add column if not exists response_lag_days integer;

create index if not exists idx_donors_responded on public.donors (responded);
create index if not exists idx_donors_last_targeted on public.donors (last_targeted);

-- ---------------------------------------------------------------------
-- 3) تحديث دالة update_settings لتقبل أيام الاستجابة أيضًا
--    (نُبقي النسخة القديمة تعمل عبر معامل افتراضي حتى لا تنكسر استدعاءات قديمة)
-- ---------------------------------------------------------------------
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

grant execute on function public.update_settings(integer, jsonb, integer) to authenticated;

-- ---------------------------------------------------------------------
-- 4) دالة مساعدة: حساب الاستجابة لمجموعة أرقام
--    منطق الاستجابة:
--      * يجب أن يكون للمتبرع تاريخ استهداف (last_targeted)
--      * نأخذ أول عملية تبرع بتاريخ صالح وقعت بعد آخر استهداف
--      * إن وقعت خلال response_days يومًا => مستجيب، ونسجّل تاريخها وفارق الأيام
-- ---------------------------------------------------------------------
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

grant execute on function public.compute_response_for_phones(text[]) to authenticated;

-- ---------------------------------------------------------------------
-- 5) تحديث دالة الدفعة donor_rebuild_chunk لتشمل حساب الاستجابة
--    نُعيد تعريف الدالة بالكامل (نفس منطق النسخة الحالية + كتلة الاستجابة)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 6) تحديث دالة الاحتساب الكامل recalculate_donors لتشمل الاستجابة أيضًا
--    (تُستخدم احتياطيًا؛ الواجهة تعتمد على الدفعات، لكن نُبقيها متسقة)
-- ---------------------------------------------------------------------
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

grant execute on function public.recalculate_donors() to authenticated;

-- ---------------------------------------------------------------------
-- 7) دالة التقارير الشهرية والسنوية (تبويب التقارير الجديد)
--    p_year: السنة المطلوبة (مثلاً 2026). تُحسب كل الأرقام من جدول العمليات
--    على مستوى العملية الفريدة (phone + operation_no) بتوقيت السعودية.
-- ---------------------------------------------------------------------
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

grant execute on function public.reports_stats(integer) to authenticated;

-- ---------------------------------------------------------------------
-- تم. بعد التشغيل: ارفع ملفات الواجهة، ثم من «ملفات المتبرعين» اضغط
-- «إعادة احتساب الملفات» لتعبئة أعمدة الاستجابة لأول مرة.
-- ---------------------------------------------------------------------
