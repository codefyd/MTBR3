-- ولاء SaaS 3.0 | المرحلة 5/6: إعادة بناء ذاكرة العمليات والحملات
-- شغّل هذا الملف وحده وانتظر Success قبل الانتقال للمرحلة التالية.

begin;
set local statement_timeout = '0';

-- ---------------------------------------------------------------------
-- Cache العمليات: المفتاح (الجمعية، رقم العملية).
-- ---------------------------------------------------------------------
drop trigger if exists trg_sync_campaign_operation_fact on public.operations;
drop function if exists public.refresh_campaign_operation_fact(bigint);
drop function if exists public.sync_campaign_operation_fact_trigger();

truncate table public.campaign_operation_facts;
insert into public.campaign_operation_facts (
  organization_id, operation_no, op_datetime, op_date, total_amount, phone, codes, projects, updated_at
)
select
  o.organization_id,
  o.operation_no,
  min(o.op_datetime),
  (min(o.op_datetime) at time zone 'Asia/Riyadh')::date,
  coalesce(sum(o.total),0)::numeric,
  max(o.phone) filter (
    where o.phone is not null and o.phone not like 'INVALID:%' and o.phone not like 'EMPTY:%'
      and coalesce(o.phone_status,'صحيح')='صحيح'
  ),
  array_remove(array_agg(distinct nullif(btrim(o.referral_code),'')),null)::text[],
  array_remove(array_agg(distinct nullif(btrim(o.project),'')),null)::text[],
  now()
from public.operations o
group by o.organization_id, o.operation_no;

create or replace function app_private.refresh_campaign_operation_fact(p_org uuid, p_operation_no bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_org is null or p_operation_no is null then return; end if;
  if not exists (
    select 1 from public.operations o
    where o.organization_id=p_org and o.operation_no=p_operation_no
  ) then
    delete from public.campaign_operation_facts f
    where f.organization_id=p_org and f.operation_no=p_operation_no;
    return;
  end if;

  insert into public.campaign_operation_facts (
    organization_id, operation_no, op_datetime, op_date, total_amount, phone, codes, projects, updated_at
  )
  select
    p_org, o.operation_no, min(o.op_datetime),
    (min(o.op_datetime) at time zone 'Asia/Riyadh')::date,
    coalesce(sum(o.total),0)::numeric,
    max(o.phone) filter (
      where o.phone is not null and o.phone not like 'INVALID:%' and o.phone not like 'EMPTY:%'
        and coalesce(o.phone_status,'صحيح')='صحيح'
    ),
    array_remove(array_agg(distinct nullif(btrim(o.referral_code),'')),null)::text[],
    array_remove(array_agg(distinct nullif(btrim(o.project),'')),null)::text[], now()
  from public.operations o
  where o.organization_id=p_org and o.operation_no=p_operation_no
  group by o.operation_no
  on conflict (organization_id, operation_no) do update set
    op_datetime=excluded.op_datetime, op_date=excluded.op_date,
    total_amount=excluded.total_amount, phone=excluded.phone,
    codes=excluded.codes, projects=excluded.projects, updated_at=now();
end;
$$;

create or replace function app_private.sync_campaign_operation_fact_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op='DELETE' then
    perform app_private.refresh_campaign_operation_fact(old.organization_id, old.operation_no);
    return old;
  end if;
  if tg_op='UPDATE' and (
    old.organization_id is distinct from new.organization_id
    or old.operation_no is distinct from new.operation_no
  ) then
    perform app_private.refresh_campaign_operation_fact(old.organization_id, old.operation_no);
  end if;
  perform app_private.refresh_campaign_operation_fact(new.organization_id, new.operation_no);
  return new;
end;
$$;

create trigger trg_sync_campaign_operation_fact
after insert or update or delete on public.operations
for each row execute function app_private.sync_campaign_operation_fact_trigger();
revoke all on function app_private.refresh_campaign_operation_fact(uuid,bigint) from public, anon, authenticated;
revoke all on function app_private.sync_campaign_operation_fact_trigger() from public, anon, authenticated;

-- Cache نتائج الحملات يحمل organization_id حتى في الدوال ذات الامتياز.
create or replace function public.mark_campaign_analysis_stale_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := case when tg_op='DELETE' then old.id else new.id end;
  v_org uuid := case when tg_op='DELETE' then old.organization_id else new.organization_id end;
begin
  if v_id is null or not exists (
    select 1 from public.marketing_campaigns c where c.id=v_id and c.organization_id=v_org
  ) then return case when tg_op='DELETE' then old else new end; end if;
  insert into public.marketing_campaign_analysis_cache (organization_id,campaign_id,is_stale,updated_at)
  values (v_org,v_id,true,now())
  on conflict (campaign_id) do update set
    organization_id=excluded.organization_id,is_stale=true,updated_at=now();
  return case when tg_op='DELETE' then old else new end;
end;
$$;

create or replace function public.mark_campaign_cost_analysis_stale_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := case when tg_op='DELETE' then old.campaign_id else new.campaign_id end;
  v_org uuid := case when tg_op='DELETE' then old.organization_id else new.organization_id end;
begin
  if v_id is null or not exists (
    select 1 from public.marketing_campaigns c where c.id=v_id and c.organization_id=v_org
  ) then return case when tg_op='DELETE' then old else new end; end if;
  insert into public.marketing_campaign_analysis_cache (organization_id,campaign_id,is_stale,updated_at)
  values (v_org,v_id,true,now())
  on conflict (campaign_id) do update set
    organization_id=excluded.organization_id,is_stale=true,updated_at=now();
  return case when tg_op='DELETE' then old else new end;
end;
$$;

revoke execute on function public.mark_campaign_analysis_stale_trigger() from public, anon, authenticated;
revoke execute on function public.mark_campaign_cost_analysis_stale_trigger() from public, anon, authenticated;


commit;


