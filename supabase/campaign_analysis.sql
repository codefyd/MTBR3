-- =====================================================================
-- MTBR3 - تحليل الحملات التسويقية عبر أكواد الإحالة
-- شغّل هذا الملف على مشروع قائم لإضافة صفحة تحليل الحملات التسويقية.
-- للمشروع الجديد: هذا المحتوى مدمج كذلك داخل supabase/schema.sql.
-- =====================================================================

begin;

create table if not exists public.referral_code_costs (
  referral_code text primary key,
  cost          numeric not null default 0 check (cost >= 0),
  note          text,
  updated_at    timestamptz not null default now()
);

create index if not exists idx_operations_referral_code on public.operations (referral_code) where referral_code is not null;
create index if not exists idx_operations_referral_datetime on public.operations (referral_code, op_datetime) where referral_code is not null;

create or replace function public.save_referral_code_cost(
  p_referral_code text,
  p_cost numeric,
  p_note text default null
)
returns public.referral_code_costs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := nullif(btrim(p_referral_code), '');
  result public.referral_code_costs;
begin
  if v_code is null then
    raise exception 'كود الإحالة مطلوب';
  end if;
  if p_cost is null or p_cost < 0 then
    raise exception 'التكلفة يجب أن تكون أكبر من أو تساوي صفر';
  end if;

  insert into public.referral_code_costs (referral_code, cost, note, updated_at)
  values (v_code, p_cost, p_note, now())
  on conflict (referral_code) do update set
    cost = excluded.cost,
    note = excluded.note,
    updated_at = now()
  returning * into result;

  return result;
end;
$$;

create or replace function public.referral_code_analysis(
  p_from date default null,
  p_to date default null,
  p_project text default null,
  p_search text default null
)
returns table (
  referral_code text,
  projects text[],
  rows_count bigint,
  donations_count bigint,
  donor_operations bigint,
  unique_donors bigint,
  total_amount numeric,
  first_donation timestamptz,
  last_donation timestamptz,
  cost numeric,
  net_return numeric,
  roas numeric,
  roi_percent numeric
)
language sql
security definer
set search_path = public
stable
as $$
  with filtered as (
    select
      btrim(o.referral_code) as code,
      nullif(btrim(o.project), '') as project,
      o.operation_no,
      o.phone,
      coalesce(o.phone_status, 'صحيح') as phone_status,
      o.total,
      o.op_datetime
    from public.operations o
    where o.referral_code is not null
      and btrim(o.referral_code) <> ''
      and (p_from is null or o.op_datetime >= (p_from::timestamp at time zone 'Asia/Riyadh'))
      and (p_to is null or o.op_datetime < ((p_to + 1)::timestamp at time zone 'Asia/Riyadh'))
      and (p_project is null or btrim(coalesce(o.project, '')) = btrim(p_project))
      and (p_search is null or btrim(o.referral_code) ilike ('%' || btrim(p_search) || '%'))
  ), agg as (
    select
      f.code,
      array_remove(array_agg(distinct f.project order by f.project), null)::text[] as projects,
      count(*)::bigint as rows_count,
      count(distinct f.operation_no)::bigint as donations_count,
      count(distinct f.operation_no) filter (
        where f.phone is not null
          and f.phone not like 'INVALID:%'
          and f.phone not like 'EMPTY:%'
          and f.phone_status = 'صحيح'
      )::bigint as donor_operations,
      count(distinct f.phone) filter (
        where f.phone is not null
          and f.phone not like 'INVALID:%'
          and f.phone not like 'EMPTY:%'
          and f.phone_status = 'صحيح'
      )::bigint as unique_donors,
      coalesce(sum(f.total), 0)::numeric as total_amount,
      min(f.op_datetime) as first_donation,
      max(f.op_datetime) as last_donation
    from filtered f
    group by f.code
  )
  select
    a.code as referral_code,
    coalesce(a.projects, array[]::text[]) as projects,
    a.rows_count,
    a.donations_count,
    a.donor_operations,
    a.unique_donors,
    a.total_amount,
    a.first_donation,
    a.last_donation,
    coalesce(c.cost, 0)::numeric as cost,
    (a.total_amount - coalesce(c.cost, 0))::numeric as net_return,
    case when coalesce(c.cost, 0) > 0 then round((a.total_amount / c.cost)::numeric, 4) else null end as roas,
    case when a.total_amount > 0 then round((coalesce(c.cost, 0) / a.total_amount * 100)::numeric, 2) else null end as roi_percent
  from agg a
  left join public.referral_code_costs c on c.referral_code = a.code
  order by a.total_amount desc, a.unique_donors desc, a.code;
$$;

alter table public.referral_code_costs enable row level security;

drop policy if exists "auth read referral costs" on public.referral_code_costs;
create policy "auth read referral costs" on public.referral_code_costs for select to authenticated using (true);

drop policy if exists "auth write referral costs" on public.referral_code_costs;
create policy "auth write referral costs" on public.referral_code_costs for all to authenticated using (true) with check (true);

grant select, insert, update, delete on public.referral_code_costs to authenticated;
grant execute on function public.save_referral_code_cost(text, numeric, text) to authenticated;
grant execute on function public.referral_code_analysis(date, date, text, text) to authenticated;

commit;
