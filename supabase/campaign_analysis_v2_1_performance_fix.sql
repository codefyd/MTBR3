-- =====================================================================
-- MTBR3 | Campaign Intelligence v2.1 - Performance Fix
-- شغّل هذا الملف مرة واحدة بعد campaign_analysis_v2.sql.
-- يعالج statement timeout ولا يحذف أو يغيّر بيانات العمليات والمتبرعين.
-- =====================================================================

begin;

-- فهارس مخصصة لمسارات التحليل والربط بالاسم القديم للمستهدفات.
create index if not exists idx_campaign_targets_campaign_phone_date
  on public.campaign_targets (campaign_id, phone, target_date)
  where campaign_id is not null and phone is not null and target_date is not null;

create index if not exists idx_campaign_targets_name_phone_date
  on public.campaign_targets (lower(btrim(campaign_name)), phone, target_date)
  where campaign_id is null and phone is not null and target_date is not null;

create index if not exists idx_operations_datetime_operation
  on public.operations (op_datetime, operation_no)
  where op_datetime is not null;

-- ---------------------------------------------------------------------
-- قائمة الحملات: تجميع العمليات مرة واحدة، ثم ربط المستهدفين دون EXISTS
-- مترابط لكل صف. هذا هو الإصلاح الأساسي لمشكلة انتهاء المهلة.
-- ---------------------------------------------------------------------
create or replace function public.marketing_campaign_analysis_list(
  p_search text default null,
  p_nature text default null,
  p_status text default null,
  p_channel text default null
)
returns table (
  id uuid, name text, nature text, channel text, status text,
  start_date date, end_date date, target_amount numeric,
  total_amount numeric, donations_count bigint, unique_donors bigint,
  total_cost numeric, net_return numeric, roas numeric,
  cost_revenue_percent numeric, new_donors bigint, returning_donors bigint,
  targeted_count bigint, respondents_count bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  with campaigns as materialized (
    select c.*
    from public.marketing_campaigns c
    where (p_search is null or c.name ilike '%' || btrim(p_search) || '%' or c.channel ilike '%' || btrim(p_search) || '%')
      and (p_nature is null or c.nature = p_nature)
      and (p_status is null or c.status = p_status)
      and (p_channel is null or lower(c.channel) = lower(p_channel))
  ), bounds as (
    select
      min(c.start_date)::date as first_day,
      max(coalesce(c.end_date, current_date))::date as last_day
    from campaigns c
  ), op as materialized (
    select
      o.operation_no,
      min(o.op_datetime) as op_datetime,
      (min(o.op_datetime) at time zone 'Asia/Riyadh')::date as op_date,
      coalesce(sum(o.total), 0)::numeric as op_total,
      array_remove(array_agg(distinct nullif(btrim(o.referral_code), '')), null)::text[] as codes,
      array_remove(array_agg(distinct nullif(btrim(o.project), '')), null)::text[] as projects,
      max(o.phone) filter (
        where o.phone is not null
          and o.phone not like 'INVALID:%'
          and o.phone not like 'EMPTY:%'
          and coalesce(o.phone_status, 'صحيح') = 'صحيح'
      ) as phone
    from public.operations o cross join bounds b
    where b.first_day is not null
      and o.op_datetime >= (b.first_day::timestamp at time zone 'Asia/Riyadh')
      and o.op_datetime < (((b.last_day + 1)::timestamp) at time zone 'Asia/Riyadh')
    group by o.operation_no
  ), matched as materialized (
    select c.id as campaign_id, op.*
    from campaigns c
    join op on op.op_date between c.start_date and coalesce(c.end_date, current_date)
    where public.campaign_rule_matches(
      op.codes, op.projects, c.match_mode, c.exact_codes,
      c.code_prefixes, c.projects, c.excluded_codes, c.excluded_projects
    )
  ), agg as (
    select
      c.id as campaign_id,
      coalesce(sum(m.op_total), 0)::numeric as total_amount,
      count(m.operation_no)::bigint as donations_count,
      count(distinct m.phone)::bigint as unique_donors,
      count(distinct m.phone) filter (
        where d.first_donation is not null
          and (d.first_donation at time zone 'Asia/Riyadh')::date >= c.start_date
      )::bigint as new_donors,
      count(distinct m.phone) filter (
        where d.first_donation is not null
          and (d.first_donation at time zone 'Asia/Riyadh')::date < c.start_date
      )::bigint as returning_donors
    from campaigns c
    left join matched m on m.campaign_id = c.id
    left join public.donors d on d.phone = m.phone
    group by c.id
  ), costs as (
    select cc.campaign_id, coalesce(sum(cc.amount), 0)::numeric as total_cost
    from public.marketing_campaign_costs cc
    join campaigns c on c.id = cc.campaign_id
    group by cc.campaign_id
  ), target_base as materialized (
    select
      c.id as campaign_id,
      c.attribution_days,
      ct.phone,
      max(ct.target_date) as target_date
    from campaigns c
    join public.campaign_targets ct
      on (
        ct.campaign_id = c.id
        or (
          ct.campaign_id is null
          and lower(btrim(ct.campaign_name)) = lower(btrim(c.name))
        )
      )
    where ct.phone is not null
      and ct.target_date is not null
      and (ct.target_date at time zone 'Asia/Riyadh')::date
          between c.start_date and coalesce(c.end_date, current_date)
    group by c.id, c.attribution_days, ct.phone
  ), target_responses as materialized (
    select
      t.campaign_id,
      t.phone,
      bool_or(m.operation_no is not null) as responded
    from target_base t
    left join matched m
      on m.campaign_id = t.campaign_id
     and m.phone = t.phone
     and m.op_datetime >= t.target_date
     and m.op_datetime <= t.target_date + make_interval(days => t.attribution_days)
    group by t.campaign_id, t.phone
  ), target_metrics as (
    select
      tr.campaign_id,
      count(*)::bigint as targeted_count,
      count(*) filter (where tr.responded)::bigint as respondents_count
    from target_responses tr
    group by tr.campaign_id
  )
  select
    c.id, c.name, c.nature, c.channel, c.status, c.start_date, c.end_date, c.target_amount,
    coalesce(a.total_amount, 0),
    coalesce(a.donations_count, 0),
    coalesce(a.unique_donors, 0),
    coalesce(co.total_cost, 0),
    (coalesce(a.total_amount, 0) - coalesce(co.total_cost, 0))::numeric,
    case when coalesce(co.total_cost, 0) > 0
      then round(coalesce(a.total_amount, 0) / co.total_cost, 4) end,
    case when coalesce(a.total_amount, 0) > 0
      then round(coalesce(co.total_cost, 0) / a.total_amount * 100, 2) end,
    coalesce(a.new_donors, 0),
    coalesce(a.returning_donors, 0),
    coalesce(t.targeted_count, 0),
    coalesce(t.respondents_count, 0)
  from campaigns c
  left join agg a on a.campaign_id = c.id
  left join costs co on co.campaign_id = c.id
  left join target_metrics t on t.campaign_id = c.id
  order by c.start_date desc, c.created_at desc;
$$;

-- ---------------------------------------------------------------------
-- التقرير التفصيلي: يحوّل ربط المستهدفين من بحث متكرر لكل مستهدف إلى
-- عملية JOIN واحدة على النتائج المطابقة المحفوظة داخل الاستعلام.
-- ---------------------------------------------------------------------
create or replace function public.marketing_campaign_analysis_detail(p_campaign_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with c as materialized (
    select * from public.marketing_campaigns where id = p_campaign_id
  ), op as materialized (
    select
      o.operation_no,
      min(o.op_datetime) as op_datetime,
      (min(o.op_datetime) at time zone 'Asia/Riyadh')::date as op_date,
      coalesce(sum(o.total), 0)::numeric as op_total,
      array_remove(array_agg(distinct nullif(btrim(o.referral_code), '')), null)::text[] as codes,
      array_remove(array_agg(distinct nullif(btrim(o.project), '')), null)::text[] as projects,
      max(o.phone) filter (
        where o.phone is not null
          and o.phone not like 'INVALID:%'
          and o.phone not like 'EMPTY:%'
          and coalesce(o.phone_status, 'صحيح') = 'صحيح'
      ) as phone
    from public.operations o cross join c
    where o.op_datetime is not null
      and o.op_datetime >= (c.start_date::timestamp at time zone 'Asia/Riyadh')
      and o.op_datetime < (((coalesce(c.end_date, current_date) + 1)::timestamp) at time zone 'Asia/Riyadh')
    group by o.operation_no
  ), matched as materialized (
    select op.*
    from op cross join c
    where public.campaign_rule_matches(
      op.codes, op.projects, c.match_mode, c.exact_codes,
      c.code_prefixes, c.projects, c.excluded_codes, c.excluded_projects
    )
  ), donor_rollup as materialized (
    select
      m.phone,
      count(*) as gift_count,
      sum(m.op_total) as donor_total,
      min(d.first_donation) as first_donation
    from matched m
    left join public.donors d on d.phone = m.phone
    where m.phone is not null
    group by m.phone
  ), costs as (
    select coalesce(sum(amount), 0)::numeric as total_cost
    from public.marketing_campaign_costs
    where campaign_id = p_campaign_id
  ), base as (
    select
      coalesce(sum(m.op_total), 0)::numeric as total_amount,
      count(m.operation_no)::bigint as donations_count,
      count(distinct m.phone)::bigint as unique_donors,
      coalesce(avg(m.op_total), 0)::numeric as average_donation,
      coalesce(max(m.op_total), 0)::numeric as largest_donation
    from matched m
  ), donors_metrics as (
    select
      count(donor_rollup.phone) filter (
        where first_donation is not null
          and (first_donation at time zone 'Asia/Riyadh')::date >= c.start_date
      )::bigint as new_donors,
      count(donor_rollup.phone) filter (
        where first_donation is not null
          and (first_donation at time zone 'Asia/Riyadh')::date < c.start_date
      )::bigint as returning_donors,
      count(donor_rollup.phone) filter (where gift_count > 1)::bigint as repeat_donors,
      coalesce(
        sum(donor_total) filter (where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date >= c.start_date)
        / nullif(sum(gift_count) filter (where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date >= c.start_date), 0),
        0
      )::numeric as avg_new_donation,
      coalesce(
        sum(donor_total) filter (where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date < c.start_date)
        / nullif(sum(gift_count) filter (where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date < c.start_date), 0),
        0
      )::numeric as avg_returning_donation
    from c left join donor_rollup on true
    group by c.start_date
  ), target_base as materialized (
    select distinct on (ct.phone)
      ct.phone, ct.target_date
    from public.campaign_targets ct cross join c
    where ct.phone is not null
      and ct.target_date is not null
      and (
        ct.campaign_id = c.id
        or (
          ct.campaign_id is null
          and lower(btrim(ct.campaign_name)) = lower(btrim(c.name))
        )
      )
      and (ct.target_date at time zone 'Asia/Riyadh')::date
          between c.start_date and coalesce(c.end_date, current_date)
    order by ct.phone, ct.target_date desc
  ), response_join as materialized (
    select
      t.phone,
      t.target_date,
      m.operation_no,
      m.op_datetime,
      m.op_total,
      extract(epoch from (m.op_datetime - t.target_date)) / 3600.0 as lag_hours
    from target_base t cross join c
    left join matched m
      on m.phone = t.phone
     and m.op_datetime >= t.target_date
     and m.op_datetime <= t.target_date + make_interval(days => c.attribution_days)
  ), responses as (
    select
      phone,
      target_date,
      min(op_datetime) as response_date,
      min(lag_hours) as lag_hours
    from response_join
    group by phone, target_date
  ), response_operations as (
    select count(distinct operation_no)::bigint as response_operations_count
    from response_join
    where operation_no is not null
  ), target_metrics as (
    select
      count(responses.phone)::bigint as targeted_count,
      count(responses.phone) filter (where response_date is not null)::bigint as respondents_count,
      ro.response_operations_count,
      count(responses.phone) filter (where lag_hours <= 24)::bigint as response_24h,
      count(responses.phone) filter (where lag_hours <= 72)::bigint as response_3d,
      count(responses.phone) filter (where lag_hours <= 168)::bigint as response_7d,
      coalesce(avg(lag_hours) filter (where response_date is not null), 0)::numeric as average_response_hours
    from response_operations ro left join responses on true
    group by ro.response_operations_count
  ), subsequent as (
    select coalesce(sum(x.op_total), 0)::numeric as subsequent_amount
    from c
    left join lateral (
      select ao.operation_no, sum(ao.total)::numeric as op_total
      from public.operations ao
      where c.end_date is not null
        and c.end_date < current_date
        and ao.phone in (select phone from donor_rollup)
        and ao.op_datetime >= (((c.end_date + 1)::timestamp) at time zone 'Asia/Riyadh')
        and ao.op_datetime < (((c.end_date + c.post_campaign_days + 1)::timestamp) at time zone 'Asia/Riyadh')
      group by ao.operation_no
    ) x on true
  ), daily as (
    select op_date as day, sum(op_total)::numeric as amount, count(*)::bigint as donations
    from matched
    group by op_date
    order by op_date
  ), project_breakdown as (
    select
      coalesce(nullif(btrim(o.project), ''), 'غير محدد') as label,
      coalesce(sum(o.total), 0)::numeric as amount,
      count(distinct o.operation_no)::bigint as donations
    from public.operations o
    join matched m on m.operation_no = o.operation_no
    group by coalesce(nullif(btrim(o.project), ''), 'غير محدد')
    order by amount desc
  ), code_breakdown as (
    select
      coalesce(nullif(btrim(o.referral_code), ''), 'بدون كود') as label,
      coalesce(sum(o.total), 0)::numeric as amount,
      count(distinct o.operation_no)::bigint as donations
    from public.operations o
    join matched m on m.operation_no = o.operation_no
    group by coalesce(nullif(btrim(o.referral_code), ''), 'بدون كود')
    order by amount desc
  )
  select jsonb_build_object(
    'campaign', (select to_jsonb(c.*) from c),
    'costs', (
      select coalesce(jsonb_agg(to_jsonb(mc.*) order by mc.cost_date), '[]'::jsonb)
      from public.marketing_campaign_costs mc
      where mc.campaign_id = p_campaign_id
    ),
    'metrics', (
      select jsonb_build_object(
        'total_amount', b.total_amount,
        'donations_count', b.donations_count,
        'unique_donors', b.unique_donors,
        'average_donation', b.average_donation,
        'largest_donation', b.largest_donation,
        'total_cost', co.total_cost,
        'net_return', b.total_amount - co.total_cost,
        'roas', case when co.total_cost > 0 then round(b.total_amount / co.total_cost, 4) end,
        'cost_revenue_percent', case when b.total_amount > 0 then round(co.total_cost / b.total_amount * 100, 2) end,
        'acquisition_cost', case when dm.new_donors > 0 then round(co.total_cost / dm.new_donors, 2) end,
        'target_achievement_percent', case when c.target_amount > 0 then round(b.total_amount / c.target_amount * 100, 2) end
      )
      from base b cross join costs co cross join c cross join donors_metrics dm
    ),
    'donors', (
      select jsonb_build_object(
        'new_donors', dm.new_donors,
        'returning_donors', dm.returning_donors,
        'new_donors_percent', case when (dm.new_donors + dm.returning_donors) > 0
          then round(dm.new_donors::numeric / (dm.new_donors + dm.returning_donors) * 100, 2) end,
        'repeat_donors', dm.repeat_donors,
        'avg_new_donation', dm.avg_new_donation,
        'avg_returning_donation', dm.avg_returning_donation,
        'subsequent_amount', s.subsequent_amount
      )
      from donors_metrics dm cross join subsequent s
    ),
    'targeting', (
      select jsonb_build_object(
        'targeted_count', tm.targeted_count,
        'respondents_count', tm.respondents_count,
        'response_rate', case when tm.targeted_count > 0
          then round(tm.respondents_count::numeric / tm.targeted_count * 100, 2) end,
        'response_cost', case when tm.response_operations_count > 0
          then round(co.total_cost / tm.response_operations_count, 2) end,
        'respondent_donor_cost', case when tm.respondents_count > 0
          then round(co.total_cost / tm.respondents_count, 2) end,
        'average_response_hours', tm.average_response_hours,
        'response_24h', tm.response_24h,
        'response_3d', tm.response_3d,
        'response_7d', tm.response_7d
      )
      from target_metrics tm cross join costs co
    ),
    'daily', (
      select coalesce(jsonb_agg(to_jsonb(daily.*) order by day), '[]'::jsonb)
      from daily
    ),
    'projects', (
      select coalesce(jsonb_agg(to_jsonb(project_breakdown.*)), '[]'::jsonb)
      from project_breakdown
    ),
    'codes', (
      select coalesce(jsonb_agg(to_jsonb(code_breakdown.*)), '[]'::jsonb)
      from code_breakdown
    )
  );
$$;

revoke execute on function public.marketing_campaign_analysis_list(text, text, text, text) from public, anon;
revoke execute on function public.marketing_campaign_analysis_detail(uuid) from public, anon;
grant execute on function public.marketing_campaign_analysis_list(text, text, text, text) to authenticated;
grant execute on function public.marketing_campaign_analysis_detail(uuid) to authenticated;

notify pgrst, 'reload schema';

commit;
