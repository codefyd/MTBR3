-- =====================================================================
-- MTBR3 | Campaign Intelligence v2.3 - Result Cache
-- يفصل حساب التقرير الثقيل عن تحميل الصفحة.
-- المتطلبات: نجاح v2.2 وتساوي operations_count مع cached_count.
-- لا يحذف أو يغير بيانات العمليات والمتبرعين والمستهدفين.
-- =====================================================================

begin;
set local statement_timeout = '0';

create table if not exists public.marketing_campaign_analysis_cache (
  campaign_id  uuid primary key references public.marketing_campaigns(id) on delete cascade,
  payload      jsonb,
  is_stale     boolean not null default true,
  refreshed_at timestamptz,
  updated_at   timestamptz not null default now()
);

create index if not exists idx_campaign_analysis_cache_stale
  on public.marketing_campaign_analysis_cache (is_stale, campaign_id);

alter table public.marketing_campaign_analysis_cache enable row level security;
drop policy if exists "authenticated manage campaign analysis cache" on public.marketing_campaign_analysis_cache;
create policy "authenticated manage campaign analysis cache"
  on public.marketing_campaign_analysis_cache for all to authenticated
  using (true) with check (true);
grant select, insert, update, delete on public.marketing_campaign_analysis_cache to authenticated;

-- نحافظ على دالة الحساب الحية باسم داخلي، ثم نضع مكان الاسم العام دالة Cache سريعة.
do $$
begin
  if to_regprocedure('public.marketing_campaign_analysis_detail_live(uuid)') is null then
    if to_regprocedure('public.marketing_campaign_analysis_detail(uuid)') is null then
      raise exception 'يجب تشغيل campaign_analysis_v2_2_cache_fix.sql أولًا';
    end if;
    alter function public.marketing_campaign_analysis_detail(uuid)
      rename to marketing_campaign_analysis_detail_live;
  end if;
end;
$$;

revoke execute on function public.marketing_campaign_analysis_detail_live(uuid) from public, anon;
grant execute on function public.marketing_campaign_analysis_detail_live(uuid) to authenticated;

-- يبني النتائج الحالية مرة واحدة داخل SQL Editor دون مهلة Data API.
insert into public.marketing_campaign_analysis_cache (
  campaign_id, payload, is_stale, refreshed_at, updated_at
)
select
  c.id,
  public.marketing_campaign_analysis_detail_live(c.id),
  false,
  now(),
  now()
from public.marketing_campaigns c
where not exists (
  select 1 from public.marketing_campaign_analysis_cache x where x.campaign_id = c.id
)
on conflict (campaign_id) do nothing;

-- تقرير فارغ منظم للحملة الجديدة قبل أول تحديث.
create or replace function public.empty_marketing_campaign_analysis(p_campaign_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'campaign', to_jsonb(c.*),
    'costs', coalesce((
      select jsonb_agg(to_jsonb(mc.*) order by mc.cost_date)
      from public.marketing_campaign_costs mc where mc.campaign_id = c.id
    ), '[]'::jsonb),
    'metrics', jsonb_build_object(
      'total_amount', 0, 'donations_count', 0, 'unique_donors', 0,
      'average_donation', 0, 'largest_donation', 0,
      'total_cost', coalesce((select sum(amount) from public.marketing_campaign_costs where campaign_id = c.id), 0),
      'net_return', -coalesce((select sum(amount) from public.marketing_campaign_costs where campaign_id = c.id), 0),
      'roas', null, 'cost_revenue_percent', null,
      'acquisition_cost', null, 'target_achievement_percent', 0
    ),
    'donors', jsonb_build_object(
      'new_donors', 0, 'returning_donors', 0, 'new_donors_percent', 0,
      'repeat_donors', 0, 'avg_new_donation', 0,
      'avg_returning_donation', 0, 'subsequent_amount', 0
    ),
    'targeting', jsonb_build_object(
      'targeted_count', 0, 'respondents_count', 0, 'response_rate', 0,
      'response_cost', null, 'respondent_donor_cost', null,
      'average_response_hours', 0, 'response_24h', 0,
      'response_3d', 0, 'response_7d', 0
    ),
    'daily', '[]'::jsonb, 'projects', '[]'::jsonb, 'codes', '[]'::jsonb
  )
  from public.marketing_campaigns c
  where c.id = p_campaign_id;
$$;

-- تحديث حملة واحدة؛ الواجهة تستدعيها بالتتابع لتجنب مهلة استعلام شامل.
create or replace function public.refresh_marketing_campaign_analysis_cache(p_campaign_id uuid)
returns timestamptz
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_now timestamptz := now();
begin
  if not exists (select 1 from public.marketing_campaigns where id = p_campaign_id) then
    raise exception 'الحملة غير موجودة';
  end if;

  v_payload := public.marketing_campaign_analysis_detail_live(p_campaign_id);
  insert into public.marketing_campaign_analysis_cache (
    campaign_id, payload, is_stale, refreshed_at, updated_at
  ) values (p_campaign_id, v_payload, false, v_now, v_now)
  on conflict (campaign_id) do update set
    payload = excluded.payload,
    is_stale = false,
    refreshed_at = excluded.refreshed_at,
    updated_at = excluded.updated_at;
  return v_now;
end;
$$;

create or replace function public.marketing_campaign_analysis_pending()
returns table (campaign_id uuid, campaign_name text, is_stale boolean, refreshed_at timestamptz)
language sql
stable
security invoker
set search_path = ''
as $$
  select c.id, c.name, coalesce(x.is_stale, true), x.refreshed_at
  from public.marketing_campaigns c
  left join public.marketing_campaign_analysis_cache x on x.campaign_id = c.id
  where coalesce(x.is_stale, true) = true or x.payload is null
  order by c.start_date desc, c.created_at desc;
$$;

-- دالة التقرير العامة أصبحت قراءة فورية من Cache.
create or replace function public.marketing_campaign_analysis_detail(p_campaign_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(
    (select x.payload from public.marketing_campaign_analysis_cache x
      where x.campaign_id = p_campaign_id and x.payload is not null),
    public.empty_marketing_campaign_analysis(p_campaign_id)
  );
$$;

-- قائمة الحملات تقرأ مؤشرات JSON المحفوظة فقط، دون مسح جدول العمليات.
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
  select
    c.id, c.name, c.nature, c.channel, c.status, c.start_date, c.end_date, c.target_amount,
    coalesce((x.payload->'metrics'->>'total_amount')::numeric, 0),
    coalesce((x.payload->'metrics'->>'donations_count')::bigint, 0),
    coalesce((x.payload->'metrics'->>'unique_donors')::bigint, 0),
    coalesce((x.payload->'metrics'->>'total_cost')::numeric, 0),
    coalesce((x.payload->'metrics'->>'net_return')::numeric, 0),
    nullif(x.payload->'metrics'->>'roas', '')::numeric,
    nullif(x.payload->'metrics'->>'cost_revenue_percent', '')::numeric,
    coalesce((x.payload->'donors'->>'new_donors')::bigint, 0),
    coalesce((x.payload->'donors'->>'returning_donors')::bigint, 0),
    coalesce((x.payload->'targeting'->>'targeted_count')::bigint, 0),
    coalesce((x.payload->'targeting'->>'respondents_count')::bigint, 0)
  from public.marketing_campaigns c
  left join public.marketing_campaign_analysis_cache x on x.campaign_id = c.id
  where (p_search is null or c.name ilike '%' || btrim(p_search) || '%' or c.channel ilike '%' || btrim(p_search) || '%')
    and (p_nature is null or c.nature = p_nature)
    and (p_status is null or c.status = p_status)
    and (p_channel is null or lower(c.channel) = lower(p_channel))
  order by c.start_date desc, c.created_at desc;
$$;

-- وسم Cache الحملة عند تعديل تعريفها أو تكاليفها.
create or replace function public.mark_campaign_analysis_stale_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  v_id := case when tg_op = 'DELETE' then old.id else new.id end;
  insert into public.marketing_campaign_analysis_cache (campaign_id, is_stale, updated_at)
  values (v_id, true, now())
  on conflict (campaign_id) do update set is_stale = true, updated_at = now();
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function public.mark_campaign_cost_analysis_stale_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  v_id := case when tg_op = 'DELETE' then old.campaign_id else new.campaign_id end;
  insert into public.marketing_campaign_analysis_cache (campaign_id, is_stale, updated_at)
  values (v_id, true, now())
  on conflict (campaign_id) do update set is_stale = true, updated_at = now();
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function public.mark_all_campaign_analysis_stale_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.marketing_campaign_analysis_cache
    set is_stale = true, updated_at = now()
    where is_stale = false;
  return null;
end;
$$;

drop trigger if exists trg_mark_campaign_analysis_stale on public.marketing_campaigns;
create trigger trg_mark_campaign_analysis_stale
after insert or update on public.marketing_campaigns
for each row execute function public.mark_campaign_analysis_stale_trigger();

drop trigger if exists trg_mark_campaign_cost_analysis_stale on public.marketing_campaign_costs;
create trigger trg_mark_campaign_cost_analysis_stale
after insert or update or delete on public.marketing_campaign_costs
for each row execute function public.mark_campaign_cost_analysis_stale_trigger();

drop trigger if exists trg_mark_all_campaign_analysis_stale on public.operations;
create trigger trg_mark_all_campaign_analysis_stale
after insert or update or delete on public.operations
for each statement execute function public.mark_all_campaign_analysis_stale_trigger();

revoke execute on function public.mark_campaign_analysis_stale_trigger() from public, anon, authenticated;
revoke execute on function public.mark_campaign_cost_analysis_stale_trigger() from public, anon, authenticated;
revoke execute on function public.mark_all_campaign_analysis_stale_trigger() from public, anon, authenticated;
revoke execute on function public.empty_marketing_campaign_analysis(uuid) from public, anon;
revoke execute on function public.refresh_marketing_campaign_analysis_cache(uuid) from public, anon;
revoke execute on function public.marketing_campaign_analysis_pending() from public, anon;
revoke execute on function public.marketing_campaign_analysis_detail(uuid) from public, anon;
revoke execute on function public.marketing_campaign_analysis_list(text, text, text, text) from public, anon;

grant execute on function public.empty_marketing_campaign_analysis(uuid) to authenticated;
grant execute on function public.refresh_marketing_campaign_analysis_cache(uuid) to authenticated;
grant execute on function public.marketing_campaign_analysis_pending() to authenticated;
grant execute on function public.marketing_campaign_analysis_detail(uuid) to authenticated;
grant execute on function public.marketing_campaign_analysis_list(text, text, text, text) to authenticated;

analyze public.marketing_campaign_analysis_cache;
notify pgrst, 'reload schema';
commit;
