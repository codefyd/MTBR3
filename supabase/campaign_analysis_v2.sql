-- =====================================================================
-- MTBR3 | Campaign Intelligence v2
-- تشغيل آمن على المشروع القائم: يضيف إدارة الحملات وقواعد الإسناد والتحليل.
-- لا يحذف العمليات أو المتبرعين أو تحليل أكواد الإحالة السابق.
-- =====================================================================

begin;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- الحملات والتكاليف
-- ---------------------------------------------------------------------
create table if not exists public.marketing_campaigns (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  nature                text not null default 'short',
  channel               text not null,
  status                text not null default 'draft',
  start_date            date not null,
  end_date              date,
  target_amount         numeric not null default 0,
  attribution_days      integer not null default 7,
  post_campaign_days    integer not null default 30,
  match_mode            text not null default 'all',
  exact_codes           text[] not null default array[]::text[],
  code_prefixes         text[] not null default array[]::text[],
  projects              text[] not null default array[]::text[],
  excluded_codes        text[] not null default array[]::text[],
  excluded_projects     text[] not null default array[]::text[],
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint marketing_campaigns_nature_check
    check (nature in ('short', 'ongoing', 'seasonal')),
  constraint marketing_campaigns_status_check
    check (status in ('draft', 'active', 'ended', 'paused')),
  constraint marketing_campaigns_match_mode_check
    check (match_mode in ('all', 'any')),
  constraint marketing_campaigns_dates_check
    check (end_date is null or end_date >= start_date),
  constraint marketing_campaigns_days_check
    check (attribution_days between 1 and 365 and post_campaign_days between 0 and 730),
  constraint marketing_campaigns_amount_check
    check (target_amount >= 0)
);

create index if not exists idx_marketing_campaigns_dates
  on public.marketing_campaigns (start_date, end_date);
create index if not exists idx_marketing_campaigns_status
  on public.marketing_campaigns (status);
create index if not exists idx_marketing_campaigns_channel
  on public.marketing_campaigns (channel);
create index if not exists idx_marketing_campaigns_exact_codes_gin
  on public.marketing_campaigns using gin (exact_codes);
create index if not exists idx_marketing_campaigns_projects_gin
  on public.marketing_campaigns using gin (projects);

create table if not exists public.marketing_campaign_costs (
  id            uuid primary key default gen_random_uuid(),
  campaign_id   uuid not null references public.marketing_campaigns(id) on delete cascade,
  cost_date     date not null default current_date,
  category      text not null default 'إعلانات',
  amount        numeric not null,
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint marketing_campaign_costs_amount_check check (amount >= 0)
);

create index if not exists idx_marketing_campaign_costs_campaign
  on public.marketing_campaign_costs (campaign_id, cost_date);

-- ربط اختياري مباشر للمستهدفات الجديدة، مع إبقاء الربط باسم الحملة للبيانات السابقة.
alter table public.campaign_targets
  add column if not exists campaign_id uuid references public.marketing_campaigns(id) on delete set null;
create index if not exists idx_campaign_targets_campaign_id
  on public.campaign_targets (campaign_id) where campaign_id is not null;

-- ---------------------------------------------------------------------
-- دالة نقية لمطابقة أكواد ومشاريع العملية مع تعريف الحملة.
-- داخل المجموعة الواحدة المطابقة OR، وبين مجموعة الأكواد والمشاريع ALL/ANY.
-- ---------------------------------------------------------------------
create or replace function public.campaign_rule_matches(
  p_operation_codes text[],
  p_operation_projects text[],
  p_match_mode text,
  p_exact_codes text[],
  p_code_prefixes text[],
  p_projects text[],
  p_excluded_codes text[],
  p_excluded_projects text[]
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  with x as (
    select
      coalesce(p_operation_codes, array[]::text[]) as op_codes,
      coalesce(p_operation_projects, array[]::text[]) as op_projects,
      coalesce(p_exact_codes, array[]::text[]) as exact_codes,
      coalesce(p_code_prefixes, array[]::text[]) as prefixes,
      coalesce(p_projects, array[]::text[]) as projects,
      coalesce(p_excluded_codes, array[]::text[]) as excluded_codes,
      coalesce(p_excluded_projects, array[]::text[]) as excluded_projects
  ), flags as (
    select
      cardinality(exact_codes) > 0 or cardinality(prefixes) > 0 as has_code_rule,
      cardinality(projects) > 0 as has_project_rule,
      exists (
        select 1 from unnest(op_codes) oc
        where exists (select 1 from unnest(exact_codes) ec where lower(btrim(oc)) = lower(btrim(ec)))
           or exists (
             select 1 from unnest(prefixes) px
             where btrim(px) <> ''
               and left(lower(btrim(oc)), char_length(btrim(px))) = lower(btrim(px))
           )
      ) as code_match,
      exists (
        select 1 from unnest(op_projects) op
        where exists (select 1 from unnest(projects) cp where lower(btrim(op)) = lower(btrim(cp)))
      ) as project_match,
      exists (
        select 1 from unnest(op_codes) oc
        where exists (select 1 from unnest(excluded_codes) ec where lower(btrim(oc)) = lower(btrim(ec)))
      ) as code_excluded,
      exists (
        select 1 from unnest(op_projects) op
        where exists (select 1 from unnest(excluded_projects) ep where lower(btrim(op)) = lower(btrim(ep)))
      ) as project_excluded
    from x
  )
  select
    not code_excluded
    and not project_excluded
    and (has_code_rule or has_project_rule)
    and case
      when coalesce(p_match_mode, 'all') = 'any'
        then ((has_code_rule and code_match) or (has_project_rule and project_match))
      else ((not has_code_rule or code_match) and (not has_project_rule or project_match))
    end
  from flags;
$$;

-- ---------------------------------------------------------------------
-- إنشاء/تعديل حملة مع تكاليفها في عملية ذرية واحدة.
-- ---------------------------------------------------------------------
create or replace function public.save_marketing_campaign(p_payload jsonb)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
  v_start date;
  v_end date;
  v_exact text[];
  v_prefix text[];
  v_projects text[];
  v_ex_codes text[];
  v_ex_projects text[];
begin
  if nullif(btrim(p_payload->>'name'), '') is null then
    raise exception 'اسم الحملة مطلوب';
  end if;
  if nullif(btrim(p_payload->>'channel'), '') is null then
    raise exception 'القناة التسويقية مطلوبة';
  end if;

  v_start := nullif(p_payload->>'start_date', '')::date;
  v_end := nullif(p_payload->>'end_date', '')::date;
  if v_start is null then raise exception 'تاريخ بداية الحملة مطلوب'; end if;
  if v_end is not null and v_end < v_start then raise exception 'تاريخ النهاية يسبق تاريخ البداية'; end if;

  select coalesce(array_agg(btrim(v)) filter (where btrim(v) <> ''), array[]::text[])
    into v_exact from jsonb_array_elements_text(coalesce(p_payload->'exact_codes', '[]'::jsonb)) v;
  select coalesce(array_agg(btrim(v)) filter (where btrim(v) <> ''), array[]::text[])
    into v_prefix from jsonb_array_elements_text(coalesce(p_payload->'code_prefixes', '[]'::jsonb)) v;
  select coalesce(array_agg(btrim(v)) filter (where btrim(v) <> ''), array[]::text[])
    into v_projects from jsonb_array_elements_text(coalesce(p_payload->'projects', '[]'::jsonb)) v;
  select coalesce(array_agg(btrim(v)) filter (where btrim(v) <> ''), array[]::text[])
    into v_ex_codes from jsonb_array_elements_text(coalesce(p_payload->'excluded_codes', '[]'::jsonb)) v;
  select coalesce(array_agg(btrim(v)) filter (where btrim(v) <> ''), array[]::text[])
    into v_ex_projects from jsonb_array_elements_text(coalesce(p_payload->'excluded_projects', '[]'::jsonb)) v;

  if cardinality(v_exact) = 0 and cardinality(v_prefix) = 0 and cardinality(v_projects) = 0 then
    raise exception 'أضف كودًا أو بادئة كود أو مشروعًا واحدًا على الأقل';
  end if;

  begin
    v_id := nullif(p_payload->>'id', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'معرف الحملة غير صحيح';
  end;
  v_id := coalesce(v_id, gen_random_uuid());

  insert into public.marketing_campaigns (
    id, name, nature, channel, status, start_date, end_date, target_amount,
    attribution_days, post_campaign_days, match_mode, exact_codes, code_prefixes,
    projects, excluded_codes, excluded_projects, notes, updated_at
  ) values (
    v_id,
    btrim(p_payload->>'name'),
    coalesce(nullif(p_payload->>'nature', ''), 'short'),
    btrim(p_payload->>'channel'),
    coalesce(nullif(p_payload->>'status', ''), 'draft'),
    v_start, v_end,
    greatest(coalesce(nullif(p_payload->>'target_amount', '')::numeric, 0), 0),
    greatest(1, least(365, coalesce(nullif(p_payload->>'attribution_days', '')::integer, 7))),
    greatest(0, least(730, coalesce(nullif(p_payload->>'post_campaign_days', '')::integer, 30))),
    coalesce(nullif(p_payload->>'match_mode', ''), 'all'),
    v_exact, v_prefix, v_projects, v_ex_codes, v_ex_projects,
    nullif(btrim(p_payload->>'notes'), ''), now()
  )
  on conflict (id) do update set
    name = excluded.name,
    nature = excluded.nature,
    channel = excluded.channel,
    status = excluded.status,
    start_date = excluded.start_date,
    end_date = excluded.end_date,
    target_amount = excluded.target_amount,
    attribution_days = excluded.attribution_days,
    post_campaign_days = excluded.post_campaign_days,
    match_mode = excluded.match_mode,
    exact_codes = excluded.exact_codes,
    code_prefixes = excluded.code_prefixes,
    projects = excluded.projects,
    excluded_codes = excluded.excluded_codes,
    excluded_projects = excluded.excluded_projects,
    notes = excluded.notes,
    updated_at = now();

  if p_payload ? 'costs' then
    delete from public.marketing_campaign_costs where campaign_id = v_id;
    insert into public.marketing_campaign_costs (campaign_id, cost_date, category, amount, note)
    select
      v_id,
      coalesce(nullif(x->>'cost_date', '')::date, v_start),
      coalesce(nullif(btrim(x->>'category'), ''), 'إعلانات'),
      greatest(coalesce(nullif(x->>'amount', '')::numeric, 0), 0),
      nullif(btrim(x->>'note'), '')
    from jsonb_array_elements(coalesce(p_payload->'costs', '[]'::jsonb)) x
    where coalesce(nullif(x->>'amount', '')::numeric, 0) > 0;
  end if;

  -- يربط السجلات القديمة المكتوبة باسم الحملة، ويبقي الحقول القديمة كما هي.
  update public.campaign_targets
     set campaign_id = v_id
   where campaign_id is null
     and lower(btrim(campaign_name)) = lower(btrim(p_payload->>'name'));

  return v_id;
end;
$$;

create or replace function public.delete_marketing_campaign(p_campaign_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  delete from public.marketing_campaigns where id = p_campaign_id;
  return found;
end;
$$;

-- ---------------------------------------------------------------------
-- معاينة سريعة قبل الحفظ.
-- ---------------------------------------------------------------------
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
  with op as (
    select
      o.operation_no,
      min(o.op_datetime) as op_datetime,
      coalesce(sum(o.total), 0)::numeric as total_amount,
      array_remove(array_agg(distinct nullif(btrim(o.referral_code), '')), null)::text[] as codes,
      array_remove(array_agg(distinct nullif(btrim(o.project), '')), null)::text[] as projects,
      max(o.phone) filter (
        where o.phone is not null and o.phone not like 'INVALID:%' and o.phone not like 'EMPTY:%'
          and coalesce(o.phone_status, 'صحيح') = 'صحيح'
      ) as phone
    from public.operations o
    where o.op_datetime is not null
      and o.op_datetime >= (p_start_date::timestamp at time zone 'Asia/Riyadh')
      and o.op_datetime < (((coalesce(p_end_date, current_date) + 1)::timestamp) at time zone 'Asia/Riyadh')
    group by o.operation_no
  ), matched as (
    select * from op
    where public.campaign_rule_matches(codes, projects, p_match_mode, p_exact_codes,
      p_code_prefixes, p_projects, p_excluded_codes, p_excluded_projects)
  )
  select jsonb_build_object(
    'total_amount', coalesce(sum(total_amount), 0),
    'donations_count', count(*),
    'unique_donors', count(distinct phone),
    'average_donation', coalesce(avg(total_amount), 0),
    'largest_donation', coalesce(max(total_amount), 0)
  ) from matched;
$$;

-- ---------------------------------------------------------------------
-- قائمة الحملات: مؤشرات سريعة لكل حملة.
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
  with campaigns as (
    select c.*
    from public.marketing_campaigns c
    where (p_search is null or c.name ilike '%' || btrim(p_search) || '%' or c.channel ilike '%' || btrim(p_search) || '%')
      and (p_nature is null or c.nature = p_nature)
      and (p_status is null or c.status = p_status)
      and (p_channel is null or lower(c.channel) = lower(p_channel))
  ), op as (
    select
      o.operation_no,
      min(o.op_datetime) as op_datetime,
      (min(o.op_datetime) at time zone 'Asia/Riyadh')::date as op_date,
      coalesce(sum(o.total), 0)::numeric as op_total,
      array_remove(array_agg(distinct nullif(btrim(o.referral_code), '')), null)::text[] as codes,
      array_remove(array_agg(distinct nullif(btrim(o.project), '')), null)::text[] as projects,
      max(o.phone) filter (
        where o.phone is not null and o.phone not like 'INVALID:%' and o.phone not like 'EMPTY:%'
          and coalesce(o.phone_status, 'صحيح') = 'صحيح'
      ) as phone
    from public.operations o
    where o.op_datetime is not null
      and exists (
        select 1 from campaigns c
        where o.op_datetime >= (c.start_date::timestamp at time zone 'Asia/Riyadh')
          and o.op_datetime < (((coalesce(c.end_date, current_date) + 1)::timestamp) at time zone 'Asia/Riyadh')
      )
    group by o.operation_no
  ), matched as (
    select c.id as campaign_id, op.*
    from campaigns c
    join op on op.op_date between c.start_date and coalesce(c.end_date, current_date)
    where public.campaign_rule_matches(op.codes, op.projects, c.match_mode, c.exact_codes,
      c.code_prefixes, c.projects, c.excluded_codes, c.excluded_projects)
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
    where cc.campaign_id in (select campaigns.id from campaigns)
    group by cc.campaign_id
  ), targets as (
    select
      c.id as campaign_id,
      count(distinct ct.phone)::bigint as targeted_count,
      count(distinct ct.phone) filter (where exists (
        select 1 from matched m
        where m.campaign_id = c.id and m.phone = ct.phone
          and m.op_datetime >= ct.target_date
          and m.op_datetime <= ct.target_date + make_interval(days => c.attribution_days)
      ))::bigint as respondents_count
    from campaigns c
    left join public.campaign_targets ct
      on (ct.campaign_id = c.id or (ct.campaign_id is null and lower(btrim(ct.campaign_name)) = lower(btrim(c.name))))
      and ct.target_date is not null
      and (ct.target_date at time zone 'Asia/Riyadh')::date between c.start_date and coalesce(c.end_date, current_date)
    group by c.id
  )
  select
    c.id, c.name, c.nature, c.channel, c.status, c.start_date, c.end_date, c.target_amount,
    coalesce(a.total_amount, 0), coalesce(a.donations_count, 0), coalesce(a.unique_donors, 0),
    coalesce(co.total_cost, 0),
    (coalesce(a.total_amount, 0) - coalesce(co.total_cost, 0))::numeric,
    case when coalesce(co.total_cost, 0) > 0 then round(a.total_amount / co.total_cost, 4) end,
    case when coalesce(a.total_amount, 0) > 0 then round(coalesce(co.total_cost, 0) / a.total_amount * 100, 2) end,
    coalesce(a.new_donors, 0), coalesce(a.returning_donors, 0),
    coalesce(t.targeted_count, 0), coalesce(t.respondents_count, 0)
  from campaigns c
  left join agg a on a.campaign_id = c.id
  left join costs co on co.campaign_id = c.id
  left join targets t on t.campaign_id = c.id
  order by c.start_date desc, c.created_at desc;
$$;

-- ---------------------------------------------------------------------
-- التحليل التفصيلي لحملة واحدة.
-- ---------------------------------------------------------------------
create or replace function public.marketing_campaign_analysis_detail(p_campaign_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with c as (
    select * from public.marketing_campaigns where id = p_campaign_id
  ), op as (
    select
      o.operation_no,
      min(o.op_datetime) as op_datetime,
      (min(o.op_datetime) at time zone 'Asia/Riyadh')::date as op_date,
      coalesce(sum(o.total), 0)::numeric as op_total,
      array_remove(array_agg(distinct nullif(btrim(o.referral_code), '')), null)::text[] as codes,
      array_remove(array_agg(distinct nullif(btrim(o.project), '')), null)::text[] as projects,
      max(o.phone) filter (
        where o.phone is not null and o.phone not like 'INVALID:%' and o.phone not like 'EMPTY:%'
          and coalesce(o.phone_status, 'صحيح') = 'صحيح'
      ) as phone
    from public.operations o cross join c
    where o.op_datetime is not null
      and o.op_datetime >= (c.start_date::timestamp at time zone 'Asia/Riyadh')
      and o.op_datetime < (((coalesce(c.end_date, current_date) + 1)::timestamp) at time zone 'Asia/Riyadh')
    group by o.operation_no
  ), matched as (
    select op.* from op cross join c
    where public.campaign_rule_matches(op.codes, op.projects, c.match_mode, c.exact_codes,
      c.code_prefixes, c.projects, c.excluded_codes, c.excluded_projects)
  ), donor_rollup as (
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
    from public.marketing_campaign_costs where campaign_id = p_campaign_id
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
      count(*) filter (
        where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date >= c.start_date
      )::bigint as new_donors,
      count(*) filter (
        where first_donation is not null and (first_donation at time zone 'Asia/Riyadh')::date < c.start_date
      )::bigint as returning_donors,
      count(*) filter (where gift_count > 1)::bigint as repeat_donors,
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
  ), target_base as (
    select distinct on (ct.phone)
      ct.phone, ct.target_date
    from public.campaign_targets ct cross join c
    where ct.phone is not null and ct.target_date is not null
      and (ct.campaign_id = c.id or (ct.campaign_id is null and lower(btrim(ct.campaign_name)) = lower(btrim(c.name))))
      and (ct.target_date at time zone 'Asia/Riyadh')::date between c.start_date and coalesce(c.end_date, current_date)
    order by ct.phone, ct.target_date desc
  ), responses as (
    select
      t.phone, t.target_date,
      r.op_datetime as response_date,
      r.operation_no,
      r.op_total,
      extract(epoch from (r.op_datetime - t.target_date)) / 3600.0 as lag_hours
    from target_base t cross join c
    left join lateral (
      select m.* from matched m
      where m.phone = t.phone
        and m.op_datetime >= t.target_date
        and m.op_datetime <= t.target_date + make_interval(days => c.attribution_days)
      order by m.op_datetime
      limit 1
    ) r on true
  ), response_operations as (
    select count(distinct m.operation_no)::bigint as response_operations_count
    from target_base t cross join c
    join matched m
      on m.phone = t.phone
     and m.op_datetime >= t.target_date
     and m.op_datetime <= t.target_date + make_interval(days => c.attribution_days)
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
      where c.end_date is not null and c.end_date < current_date
        and ao.phone in (select phone from donor_rollup)
        and ao.op_datetime >= (((c.end_date + 1)::timestamp) at time zone 'Asia/Riyadh')
        and ao.op_datetime < (((c.end_date + c.post_campaign_days + 1)::timestamp) at time zone 'Asia/Riyadh')
      group by ao.operation_no
    ) x on true
  ), daily as (
    select op_date as day, sum(op_total)::numeric as amount, count(*)::bigint as donations
    from matched group by op_date order by op_date
  ), project_breakdown as (
    select
      coalesce(nullif(btrim(o.project), ''), 'غير محدد') as label,
      coalesce(sum(o.total), 0)::numeric as amount,
      count(distinct o.operation_no)::bigint as donations
    from public.operations o
    where o.operation_no in (select operation_no from matched)
    group by coalesce(nullif(btrim(o.project), ''), 'غير محدد')
    order by amount desc
  ), code_breakdown as (
    select
      coalesce(nullif(btrim(o.referral_code), ''), 'بدون كود') as label,
      coalesce(sum(o.total), 0)::numeric as amount,
      count(distinct o.operation_no)::bigint as donations
    from public.operations o
    where o.operation_no in (select operation_no from matched)
    group by coalesce(nullif(btrim(o.referral_code), ''), 'بدون كود')
    order by amount desc
  )
  select jsonb_build_object(
    'campaign', (select to_jsonb(c.*) from c),
    'costs', (select coalesce(jsonb_agg(to_jsonb(mc.*) order by mc.cost_date), '[]'::jsonb)
              from public.marketing_campaign_costs mc where mc.campaign_id = p_campaign_id),
    'metrics', (select jsonb_build_object(
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
    ) from base b cross join costs co cross join c cross join donors_metrics dm),
    'donors', (select jsonb_build_object(
      'new_donors', dm.new_donors,
      'returning_donors', dm.returning_donors,
      'new_donors_percent', case when (dm.new_donors + dm.returning_donors) > 0
        then round(dm.new_donors::numeric / (dm.new_donors + dm.returning_donors) * 100, 2) end,
      'repeat_donors', dm.repeat_donors,
      'avg_new_donation', dm.avg_new_donation,
      'avg_returning_donation', dm.avg_returning_donation,
      'subsequent_amount', s.subsequent_amount
    ) from donors_metrics dm cross join subsequent s),
    'targeting', (select jsonb_build_object(
      'targeted_count', tm.targeted_count,
      'respondents_count', tm.respondents_count,
      'response_rate', case when tm.targeted_count > 0 then round(tm.respondents_count::numeric / tm.targeted_count * 100, 2) end,
      'response_cost', case when tm.response_operations_count > 0 then round(co.total_cost / tm.response_operations_count, 2) end,
      'respondent_donor_cost', case when tm.respondents_count > 0 then round(co.total_cost / tm.respondents_count, 2) end,
      'average_response_hours', tm.average_response_hours,
      'response_24h', tm.response_24h,
      'response_3d', tm.response_3d,
      'response_7d', tm.response_7d
    ) from target_metrics tm cross join costs co),
    'daily', (select coalesce(jsonb_agg(to_jsonb(daily.*) order by day), '[]'::jsonb) from daily),
    'projects', (select coalesce(jsonb_agg(to_jsonb(project_breakdown.*)), '[]'::jsonb) from project_breakdown),
    'codes', (select coalesce(jsonb_agg(to_jsonb(code_breakdown.*)), '[]'::jsonb) from code_breakdown)
  );
$$;

-- ---------------------------------------------------------------------
-- RLS والصلاحيات
-- يتبع المشروع الحالي نموذج لوحة داخلية: كل مستخدم مسجل يملك الوصول.
-- ---------------------------------------------------------------------
alter table public.marketing_campaigns enable row level security;
alter table public.marketing_campaign_costs enable row level security;

drop policy if exists "authenticated manage marketing campaigns" on public.marketing_campaigns;
create policy "authenticated manage marketing campaigns"
  on public.marketing_campaigns for all to authenticated
  using (true) with check (true);

drop policy if exists "authenticated manage marketing campaign costs" on public.marketing_campaign_costs;
create policy "authenticated manage marketing campaign costs"
  on public.marketing_campaign_costs for all to authenticated
  using (true) with check (true);

grant select, insert, update, delete on public.marketing_campaigns to authenticated;
grant select, insert, update, delete on public.marketing_campaign_costs to authenticated;

revoke execute on function public.campaign_rule_matches(text[], text[], text, text[], text[], text[], text[], text[]) from public, anon;
revoke execute on function public.save_marketing_campaign(jsonb) from public, anon;
revoke execute on function public.delete_marketing_campaign(uuid) from public, anon;
revoke execute on function public.campaign_match_preview(date, date, text, text[], text[], text[], text[], text[]) from public, anon;
revoke execute on function public.marketing_campaign_analysis_list(text, text, text, text) from public, anon;
revoke execute on function public.marketing_campaign_analysis_detail(uuid) from public, anon;

grant execute on function public.campaign_rule_matches(text[], text[], text, text[], text[], text[], text[], text[]) to authenticated;
grant execute on function public.save_marketing_campaign(jsonb) to authenticated;
grant execute on function public.delete_marketing_campaign(uuid) to authenticated;
grant execute on function public.campaign_match_preview(date, date, text, text[], text[], text[], text[], text[]) to authenticated;
grant execute on function public.marketing_campaign_analysis_list(text, text, text, text) to authenticated;
grant execute on function public.marketing_campaign_analysis_detail(uuid) to authenticated;

notify pgrst, 'reload schema';

commit;
