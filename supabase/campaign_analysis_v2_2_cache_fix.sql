-- =====================================================================
-- MTBR3 | Campaign Intelligence v2.2 - Operation Facts Cache
-- الحل النهائي لمهلة التحليل: يبني ملخصًا واحدًا لكل عملية ويحافظ عليه
-- تلقائيًا عند الإضافة أو التعديل أو الحذف. لا يغيّر بيانات operations.
-- شغّل الملف كاملًا مرة واحدة بعد v2 أو v2.1.
-- =====================================================================

begin;

create table if not exists public.campaign_operation_facts (
  operation_no bigint primary key,
  op_datetime  timestamptz,
  op_date      date,
  total_amount numeric not null default 0,
  phone        text,
  codes        text[] not null default array[]::text[],
  projects     text[] not null default array[]::text[],
  updated_at   timestamptz not null default now()
);

create index if not exists idx_campaign_facts_date
  on public.campaign_operation_facts (op_date, operation_no);
create index if not exists idx_campaign_facts_phone_date
  on public.campaign_operation_facts (phone, op_datetime)
  where phone is not null;
alter table public.campaign_operation_facts enable row level security;
drop policy if exists "authenticated read campaign operation facts" on public.campaign_operation_facts;
create policy "authenticated read campaign operation facts"
  on public.campaign_operation_facts for select to authenticated using (true);
grant select on public.campaign_operation_facts to authenticated;

-- بناء أولي من العمليات الحالية. هذا Cache فقط ويمكن إعادة بنائه بأمان.
truncate table public.campaign_operation_facts;
insert into public.campaign_operation_facts (
  operation_no, op_datetime, op_date, total_amount, phone, codes, projects, updated_at
)
select
  o.operation_no,
  min(o.op_datetime),
  (min(o.op_datetime) at time zone 'Asia/Riyadh')::date,
  coalesce(sum(o.total), 0)::numeric,
  max(o.phone) filter (
    where o.phone is not null
      and o.phone not like 'INVALID:%'
      and o.phone not like 'EMPTY:%'
      and coalesce(o.phone_status, 'صحيح') = 'صحيح'
  ),
  array_remove(array_agg(distinct nullif(btrim(o.referral_code), '')), null)::text[],
  array_remove(array_agg(distinct nullif(btrim(o.project), '')), null)::text[],
  now()
from public.operations o
group by o.operation_no;

-- تحديث ملخص عملية واحدة.
create or replace function public.refresh_campaign_operation_fact(p_operation_no bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_operation_no is null then return; end if;

  if not exists (select 1 from public.operations where operation_no = p_operation_no) then
    delete from public.campaign_operation_facts where operation_no = p_operation_no;
    return;
  end if;

  insert into public.campaign_operation_facts (
    operation_no, op_datetime, op_date, total_amount, phone, codes, projects, updated_at
  )
  select
    o.operation_no,
    min(o.op_datetime),
    (min(o.op_datetime) at time zone 'Asia/Riyadh')::date,
    coalesce(sum(o.total), 0)::numeric,
    max(o.phone) filter (
      where o.phone is not null
        and o.phone not like 'INVALID:%'
        and o.phone not like 'EMPTY:%'
        and coalesce(o.phone_status, 'صحيح') = 'صحيح'
    ),
    array_remove(array_agg(distinct nullif(btrim(o.referral_code), '')), null)::text[],
    array_remove(array_agg(distinct nullif(btrim(o.project), '')), null)::text[],
    now()
  from public.operations o
  where o.operation_no = p_operation_no
  group by o.operation_no
  on conflict (operation_no) do update set
    op_datetime = excluded.op_datetime,
    op_date = excluded.op_date,
    total_amount = excluded.total_amount,
    phone = excluded.phone,
    codes = excluded.codes,
    projects = excluded.projects,
    updated_at = now();
end;
$$;

create or replace function public.sync_campaign_operation_fact_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform public.refresh_campaign_operation_fact(old.operation_no);
    return old;
  end if;

  if tg_op = 'UPDATE' and old.operation_no is distinct from new.operation_no then
    perform public.refresh_campaign_operation_fact(old.operation_no);
  end if;
  perform public.refresh_campaign_operation_fact(new.operation_no);
  return new;
end;
$$;

drop trigger if exists trg_sync_campaign_operation_fact on public.operations;
create trigger trg_sync_campaign_operation_fact
after insert or update or delete on public.operations
for each row execute function public.sync_campaign_operation_fact_trigger();

revoke execute on function public.refresh_campaign_operation_fact(bigint) from public, anon, authenticated;
revoke execute on function public.sync_campaign_operation_fact_trigger() from public, anon, authenticated;

-- المعاينة الآن تقرأ ملخص العمليات الجاهز.
create or replace function public.campaign_match_preview(
  p_start_date date,
  p_end_date date,
  p_match_mode text,
  p_exact_codes text[],
  p_code_prefixes text[],
  p_projects text[],
  p_excluded_codes text[],
  p_excluded_projects text[]
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with matched as (
    select f.*
    from public.campaign_operation_facts f
    where f.op_date between p_start_date and coalesce(p_end_date, current_date)
      and public.campaign_rule_matches(
        f.codes, f.projects, p_match_mode, p_exact_codes,
        p_code_prefixes, p_projects, p_excluded_codes, p_excluded_projects
      )
  )
  select jsonb_build_object(
    'total_amount', coalesce(sum(total_amount), 0),
    'donations_count', count(*),
    'unique_donors', count(distinct phone),
    'average_donation', coalesce(avg(total_amount), 0),
    'largest_donation', coalesce(max(total_amount), 0)
  ) from matched;
$$;

-- قائمة الحملات السريعة.
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
  ), matched as materialized (
    select c.id as campaign_id, f.*
    from campaigns c
    join public.campaign_operation_facts f
      on f.op_date between c.start_date and coalesce(c.end_date, current_date)
    where public.campaign_rule_matches(
      f.codes, f.projects, c.match_mode, c.exact_codes,
      c.code_prefixes, c.projects, c.excluded_codes, c.excluded_projects
    )
  ), agg as (
    select
      c.id as campaign_id,
      coalesce(sum(m.total_amount), 0)::numeric as total_amount,
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
    select c.id as campaign_id, c.attribution_days, ct.phone, max(ct.target_date) as target_date
    from campaigns c
    join public.campaign_targets ct
      on ct.campaign_id = c.id
      or (ct.campaign_id is null and lower(btrim(ct.campaign_name)) = lower(btrim(c.name)))
    where ct.phone is not null and ct.target_date is not null
      and (ct.target_date at time zone 'Asia/Riyadh')::date
          between c.start_date and coalesce(c.end_date, current_date)
    group by c.id, c.attribution_days, ct.phone
  ), target_responses as (
    select t.campaign_id, t.phone, bool_or(m.operation_no is not null) as responded
    from target_base t
    left join matched m
      on m.campaign_id = t.campaign_id
     and m.phone = t.phone
     and m.op_datetime >= t.target_date
     and m.op_datetime <= t.target_date + make_interval(days => t.attribution_days)
    group by t.campaign_id, t.phone
  ), target_metrics as (
    select campaign_id, count(*)::bigint as targeted_count,
      count(*) filter (where responded)::bigint as respondents_count
    from target_responses group by campaign_id
  )
  select
    c.id, c.name, c.nature, c.channel, c.status, c.start_date, c.end_date, c.target_amount,
    coalesce(a.total_amount, 0), coalesce(a.donations_count, 0), coalesce(a.unique_donors, 0),
    coalesce(co.total_cost, 0),
    (coalesce(a.total_amount, 0) - coalesce(co.total_cost, 0))::numeric,
    case when coalesce(co.total_cost, 0) > 0 then round(coalesce(a.total_amount, 0) / co.total_cost, 4) end,
    case when coalesce(a.total_amount, 0) > 0 then round(coalesce(co.total_cost, 0) / a.total_amount * 100, 2) end,
    coalesce(a.new_donors, 0), coalesce(a.returning_donors, 0),
    coalesce(t.targeted_count, 0), coalesce(t.respondents_count, 0)
  from campaigns c
  left join agg a on a.campaign_id = c.id
  left join costs co on co.campaign_id = c.id
  left join target_metrics t on t.campaign_id = c.id
  order by c.start_date desc, c.created_at desc;
$$;

-- التقرير التفصيلي السريع.
create or replace function public.marketing_campaign_analysis_detail(p_campaign_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with c as materialized (
    select * from public.marketing_campaigns where id = p_campaign_id
  ), matched as materialized (
    select f.*
    from public.campaign_operation_facts f cross join c
    where f.op_date between c.start_date and coalesce(c.end_date, current_date)
      and public.campaign_rule_matches(
        f.codes, f.projects, c.match_mode, c.exact_codes,
        c.code_prefixes, c.projects, c.excluded_codes, c.excluded_projects
      )
  ), donor_rollup as materialized (
    select m.phone, count(*) as gift_count, sum(m.total_amount) as donor_total,
      min(d.first_donation) as first_donation
    from matched m left join public.donors d on d.phone = m.phone
    where m.phone is not null group by m.phone
  ), costs as (
    select coalesce(sum(amount), 0)::numeric as total_cost
    from public.marketing_campaign_costs where campaign_id = p_campaign_id
  ), base as (
    select coalesce(sum(total_amount), 0)::numeric as total_amount,
      count(operation_no)::bigint as donations_count,
      count(distinct phone)::bigint as unique_donors,
      coalesce(avg(total_amount), 0)::numeric as average_donation,
      coalesce(max(total_amount), 0)::numeric as largest_donation
    from matched
  ), donors_metrics as (
    select
      count(donor_rollup.phone) filter (where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date >= c.start_date)::bigint as new_donors,
      count(donor_rollup.phone) filter (where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date < c.start_date)::bigint as returning_donors,
      count(donor_rollup.phone) filter (where gift_count > 1)::bigint as repeat_donors,
      coalesce(sum(donor_total) filter (where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date >= c.start_date)
        / nullif(sum(gift_count) filter (where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date >= c.start_date), 0), 0)::numeric as avg_new_donation,
      coalesce(sum(donor_total) filter (where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date < c.start_date)
        / nullif(sum(gift_count) filter (where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date < c.start_date), 0), 0)::numeric as avg_returning_donation
    from c left join donor_rollup on true group by c.start_date
  ), target_base as materialized (
    select distinct on (ct.phone) ct.phone, ct.target_date
    from public.campaign_targets ct cross join c
    where ct.phone is not null and ct.target_date is not null
      and (ct.campaign_id = c.id or (ct.campaign_id is null and lower(btrim(ct.campaign_name)) = lower(btrim(c.name))))
      and (ct.target_date at time zone 'Asia/Riyadh')::date between c.start_date and coalesce(c.end_date, current_date)
    order by ct.phone, ct.target_date desc
  ), response_join as materialized (
    select t.phone, t.target_date, m.operation_no, m.op_datetime,
      extract(epoch from (m.op_datetime - t.target_date)) / 3600.0 as lag_hours
    from target_base t cross join c
    left join matched m on m.phone = t.phone
      and m.op_datetime >= t.target_date
      and m.op_datetime <= t.target_date + make_interval(days => c.attribution_days)
  ), responses as (
    select phone, target_date, min(op_datetime) as response_date, min(lag_hours) as lag_hours
    from response_join group by phone, target_date
  ), response_operations as (
    select count(distinct operation_no)::bigint as response_operations_count
    from response_join where operation_no is not null
  ), target_metrics as (
    select count(responses.phone)::bigint as targeted_count,
      count(responses.phone) filter (where response_date is not null)::bigint as respondents_count,
      ro.response_operations_count,
      count(responses.phone) filter (where lag_hours <= 24)::bigint as response_24h,
      count(responses.phone) filter (where lag_hours <= 72)::bigint as response_3d,
      count(responses.phone) filter (where lag_hours <= 168)::bigint as response_7d,
      coalesce(avg(lag_hours) filter (where response_date is not null), 0)::numeric as average_response_hours
    from response_operations ro left join responses on true group by ro.response_operations_count
  ), subsequent as (
    select coalesce(sum(f.total_amount), 0)::numeric as subsequent_amount
    from c left join public.campaign_operation_facts f
      on c.end_date is not null and c.end_date < current_date
     and f.phone in (select phone from donor_rollup)
     and f.op_date between c.end_date + 1 and c.end_date + c.post_campaign_days
  ), daily as (
    select op_date as day, sum(total_amount)::numeric as amount, count(*)::bigint as donations
    from matched group by op_date order by op_date
  ), project_breakdown as (
    select coalesce(nullif(btrim(o.project), ''), 'غير محدد') as label,
      coalesce(sum(o.total), 0)::numeric as amount,
      count(distinct o.operation_no)::bigint as donations
    from public.operations o join matched m on m.operation_no = o.operation_no
    group by coalesce(nullif(btrim(o.project), ''), 'غير محدد') order by amount desc
  ), code_breakdown as (
    select coalesce(nullif(btrim(o.referral_code), ''), 'بدون كود') as label,
      coalesce(sum(o.total), 0)::numeric as amount,
      count(distinct o.operation_no)::bigint as donations
    from public.operations o join matched m on m.operation_no = o.operation_no
    group by coalesce(nullif(btrim(o.referral_code), ''), 'بدون كود') order by amount desc
  )
  select jsonb_build_object(
    'campaign', (select to_jsonb(c.*) from c),
    'costs', (select coalesce(jsonb_agg(to_jsonb(mc.*) order by mc.cost_date), '[]'::jsonb) from public.marketing_campaign_costs mc where mc.campaign_id = p_campaign_id),
    'metrics', (select jsonb_build_object(
      'total_amount', b.total_amount, 'donations_count', b.donations_count,
      'unique_donors', b.unique_donors, 'average_donation', b.average_donation,
      'largest_donation', b.largest_donation, 'total_cost', co.total_cost,
      'net_return', b.total_amount - co.total_cost,
      'roas', case when co.total_cost > 0 then round(b.total_amount / co.total_cost, 4) end,
      'cost_revenue_percent', case when b.total_amount > 0 then round(co.total_cost / b.total_amount * 100, 2) end,
      'acquisition_cost', case when dm.new_donors > 0 then round(co.total_cost / dm.new_donors, 2) end,
      'target_achievement_percent', case when c.target_amount > 0 then round(b.total_amount / c.target_amount * 100, 2) end
    ) from base b cross join costs co cross join c cross join donors_metrics dm),
    'donors', (select jsonb_build_object(
      'new_donors', dm.new_donors, 'returning_donors', dm.returning_donors,
      'new_donors_percent', case when dm.new_donors + dm.returning_donors > 0 then round(dm.new_donors::numeric / (dm.new_donors + dm.returning_donors) * 100, 2) end,
      'repeat_donors', dm.repeat_donors, 'avg_new_donation', dm.avg_new_donation,
      'avg_returning_donation', dm.avg_returning_donation, 'subsequent_amount', s.subsequent_amount
    ) from donors_metrics dm cross join subsequent s),
    'targeting', (select jsonb_build_object(
      'targeted_count', tm.targeted_count, 'respondents_count', tm.respondents_count,
      'response_rate', case when tm.targeted_count > 0 then round(tm.respondents_count::numeric / tm.targeted_count * 100, 2) end,
      'response_cost', case when tm.response_operations_count > 0 then round(co.total_cost / tm.response_operations_count, 2) end,
      'respondent_donor_cost', case when tm.respondents_count > 0 then round(co.total_cost / tm.respondents_count, 2) end,
      'average_response_hours', tm.average_response_hours, 'response_24h', tm.response_24h,
      'response_3d', tm.response_3d, 'response_7d', tm.response_7d
    ) from target_metrics tm cross join costs co),
    'daily', (select coalesce(jsonb_agg(to_jsonb(daily.*) order by day), '[]'::jsonb) from daily),
    'projects', (select coalesce(jsonb_agg(to_jsonb(project_breakdown.*)), '[]'::jsonb) from project_breakdown),
    'codes', (select coalesce(jsonb_agg(to_jsonb(code_breakdown.*)), '[]'::jsonb) from code_breakdown)
  );
$$;

revoke execute on function public.campaign_match_preview(date, date, text, text[], text[], text[], text[], text[]) from public, anon;
revoke execute on function public.marketing_campaign_analysis_list(text, text, text, text) from public, anon;
revoke execute on function public.marketing_campaign_analysis_detail(uuid) from public, anon;
grant execute on function public.campaign_match_preview(date, date, text, text[], text[], text[], text[], text[]) to authenticated;
grant execute on function public.marketing_campaign_analysis_list(text, text, text, text) to authenticated;
grant execute on function public.marketing_campaign_analysis_detail(uuid) to authenticated;

analyze public.campaign_operation_facts;
notify pgrst, 'reload schema';

commit;
