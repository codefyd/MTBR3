-- ولاء SaaS 3.0 | المرحلة 4/6: دوال الرفع والتقارير
-- شغّل هذا الملف وحده وانتظر Success قبل الانتقال للمرحلة التالية.

begin;
set local statement_timeout = '0';

-- ---------------------------------------------------------------------
-- دوال الكتابة ذات مفاتيح مركبة بالجمعية.
-- ---------------------------------------------------------------------
create or replace function public.upsert_operations(rows jsonb)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  affected integer;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;

  with incoming0 as (
    select
      nullif(r->>'line_no','')::bigint as line_no,
      nullif(r->>'operation_no','')::bigint as operation_no,
      nullif(r->>'donor_name','') as donor_name,
      nullif(r->>'phone_raw','') as phone_raw,
      nullif(r->>'project','') as project,
      nullif(r->>'referral_code','') as referral_code,
      nullif(r->>'value','')::numeric as value,
      nullif(r->>'quantity','')::numeric as quantity,
      nullif(r->>'total','')::numeric as total,
      nullif(r->>'op_datetime','')::timestamptz as op_datetime
    from jsonb_array_elements(rows) as r
    where nullif(r->>'line_no','') is not null
      and nullif(r->>'operation_no','') is not null
  ), incoming as (
    select i.*, public.operation_phone_info(i.phone_raw, i.line_no, i.operation_no) as ph
    from incoming0 i
  ), deduped as (
    select distinct on (line_no, operation_no)
      line_no, operation_no, donor_name, phone_raw, ph,
      project, referral_code, value, quantity, total, op_datetime
    from incoming
    order by line_no, operation_no, op_datetime desc nulls last
  ), ins as (
    insert into public.operations (
      organization_id, line_no, operation_no, donor_name, phone_raw, phone, phone_status, phone_issue,
      project, referral_code, value, quantity, total, op_datetime, updated_at
    )
    select
      v_org, line_no, operation_no, donor_name, phone_raw,
      ph->>'phone', ph->>'status', ph->>'issue',
      project, referral_code, value, quantity, total, op_datetime, now()
    from deduped
    on conflict (organization_id, line_no, operation_no) do update set
      donor_name = excluded.donor_name,
      phone_raw = excluded.phone_raw,
      phone = excluded.phone,
      phone_status = excluded.phone_status,
      phone_issue = excluded.phone_issue,
      project = excluded.project,
      referral_code = excluded.referral_code,
      value = excluded.value,
      quantity = excluded.quantity,
      total = excluded.total,
      op_datetime = excluded.op_datetime,
      updated_at = now()
    returning 1
  )
  select count(*) into affected from ins;
  return affected;
end;
$$;

create or replace function public.insert_campaign_targets(rows jsonb)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  affected integer;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;

  with incoming as (
    select
      nullif(r->>'phone_raw','') as phone_raw,
      public.clean_phone(r->>'phone_raw') as phone,
      nullif(r->>'campaign_name','') as campaign_name,
      nullif(r->>'target_date','')::timestamptz as target_date
    from jsonb_array_elements(rows) as r
  ), valid as (
    select
      phone_raw, phone, campaign_name, target_date,
      md5(concat_ws('|', coalesce(phone, ''), lower(btrim(coalesce(campaign_name, ''))),
        coalesce(to_char(target_date at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'), ''))) as target_key
    from incoming where phone is not null
  ), deduped as (
    select distinct on (target_key) phone_raw, phone, campaign_name, target_date, target_key
    from valid order by target_key
  ), ins as (
    insert into public.campaign_targets (
      organization_id, phone_raw, phone, campaign_name, target_date, target_key
    )
    select v_org, phone_raw, phone, campaign_name, target_date, target_key
    from deduped
    on conflict (organization_id, target_key) do update set
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

create or replace function public.donor_rebuild_start()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  v_total integer;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  delete from public.donor_rebuild_keys where organization_id = v_org;
  insert into public.donor_rebuild_keys (organization_id, phone)
  select v_org, o.phone
  from public.operations o
  where o.organization_id = v_org and o.phone is not null
  group by o.phone;
  get diagnostics v_total = row_count;
  return coalesce(v_total, 0);
end;
$$;

create or replace function public.donor_rebuild_start_for_phones(p_phones text[])
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  v_total integer;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  if p_phones is not null and array_length(p_phones, 1) is not null then
    insert into public.donor_rebuild_keys (organization_id, phone)
    select v_org, btrim(p)
    from unnest(p_phones) as p
    where btrim(coalesce(p, '')) <> ''
    group by btrim(p)
    on conflict (organization_id, phone) do nothing;
  end if;
  select count(*)::integer into v_total
  from public.donor_rebuild_keys where organization_id = v_org;
  return coalesce(v_total, 0);
end;
$$;

create or replace function public.donor_rebuild_chunk(p_limit integer default 300, p_cleanup boolean default true)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  v_processed integer := 0;
  v_remaining integer := 0;
  v_inactive_days integer := 90;
  v_response_days integer := 30;
  v_categories jsonb := '[]'::jsonb;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  if p_limit is null or p_limit <= 0 then p_limit := 300; end if;

  select coalesce(s.inactive_days, 90), coalesce(s.response_days, 30), coalesce(s.categories, '[]'::jsonb)
  into v_inactive_days, v_response_days, v_categories
  from public.settings s
  where s.organization_id = v_org and s.id = 1;

  with batch as (
    select k.phone
    from public.donor_rebuild_keys k
    where k.organization_id = v_org
    order by k.phone
    limit p_limit
  ), target_agg as (
    select ct.phone, count(*)::integer as targeted_count, max(ct.target_date) as last_targeted
    from public.campaign_targets ct
    join batch b on b.phone = ct.phone
    where ct.organization_id = v_org and ct.phone is not null
    group by ct.phone
  ), resp as (
    select t.phone, t.last_targeted, min(o.op_datetime) as first_after
    from target_agg t
    join public.operations o
      on o.organization_id = v_org
     and o.phone = t.phone
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
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int between 4 and 11)::integer as period_morning,
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int between 12 and 15)::integer as period_noon,
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int between 16 and 18)::integer as period_evening,
      count(distinct o.operation_no) filter (where extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int >= 19 or extract(hour from (o.op_datetime at time zone 'Asia/Riyadh'))::int < 4)::integer as period_night,
      count(distinct o.operation_no) filter (where o.op_datetime is null)::integer as no_time_count
    from public.operations o
    join batch b on b.phone = o.phone
    where o.organization_id = v_org and o.phone is not null
    group by o.phone
  ), upserted as (
    insert into public.donors (
      organization_id, phone, phone_raw, phone_status, phone_issue, donor_name,
      first_donation, last_donation, total_amount, donations_count, projects,
      sat_count, sun_count, mon_count, tue_count, wed_count, thu_count, fri_count,
      period_morning, period_noon, period_evening, period_night, no_time_count,
      targeted_count, last_targeted, responded, response_date, response_lag_days,
      status, category, updated_at
    )
    select
      v_org, a.phone, a.phone_raw, a.phone_status, a.phone_issue, a.donor_name,
      a.first_donation, a.last_donation, a.total_amount, a.donations_count,
      coalesce(a.projects, array[]::text[]),
      coalesce(a.sat_count,0), coalesce(a.sun_count,0), coalesce(a.mon_count,0),
      coalesce(a.tue_count,0), coalesce(a.wed_count,0), coalesce(a.thu_count,0), coalesce(a.fri_count,0),
      coalesce(a.period_morning,0), coalesce(a.period_noon,0), coalesce(a.period_evening,0),
      coalesce(a.period_night,0), coalesce(a.no_time_count,0),
      coalesce(t.targeted_count,0), t.last_targeted,
      coalesce(r.first_after <= t.last_targeted + (v_response_days || ' days')::interval, false),
      case when r.first_after <= t.last_targeted + (v_response_days || ' days')::interval then r.first_after end,
      case when r.first_after <= t.last_targeted + (v_response_days || ' days')::interval
        then greatest(0, (extract(epoch from (r.first_after - t.last_targeted)) / 86400)::int) end,
      case when a.last_donation is not null and a.last_donation >= now() - (v_inactive_days || ' days')::interval then 'مستمر' else 'خامل' end,
      (
        select c->>'name'
        from jsonb_array_elements(v_categories) c
        where a.donations_count >= coalesce((c->>'min')::int,0)
          and (c->>'max' is null or c->>'max' = 'null' or a.donations_count <= (c->>'max')::int)
        order by coalesce((c->>'min')::int,0) desc limit 1
      ),
      now()
    from agg a
    left join target_agg t on t.phone = a.phone
    left join resp r on r.phone = a.phone
    on conflict (organization_id, phone) do update set
      phone_raw=excluded.phone_raw, phone_status=excluded.phone_status, phone_issue=excluded.phone_issue,
      donor_name=excluded.donor_name, first_donation=excluded.first_donation, last_donation=excluded.last_donation,
      total_amount=excluded.total_amount, donations_count=excluded.donations_count, projects=excluded.projects,
      sat_count=excluded.sat_count, sun_count=excluded.sun_count, mon_count=excluded.mon_count,
      tue_count=excluded.tue_count, wed_count=excluded.wed_count, thu_count=excluded.thu_count, fri_count=excluded.fri_count,
      period_morning=excluded.period_morning, period_noon=excluded.period_noon,
      period_evening=excluded.period_evening, period_night=excluded.period_night, no_time_count=excluded.no_time_count,
      targeted_count=excluded.targeted_count, last_targeted=excluded.last_targeted,
      responded=excluded.responded, response_date=excluded.response_date, response_lag_days=excluded.response_lag_days,
      status=excluded.status, category=excluded.category, updated_at=now()
    returning phone
  ), deleted as (
    delete from public.donor_rebuild_keys k
    using batch b
    where k.organization_id = v_org and k.phone = b.phone
    returning k.phone
  )
  select count(*)::integer into v_processed from deleted;

  select count(*)::integer into v_remaining
  from public.donor_rebuild_keys where organization_id = v_org;

  if v_remaining = 0 and p_cleanup then
    delete from public.donors d
    where d.organization_id = v_org
      and not exists (
        select 1 from public.operations o
        where o.organization_id = v_org and o.phone = d.phone
      );
  end if;

  return jsonb_build_object('processed', coalesce(v_processed,0), 'remaining', coalesce(v_remaining,0));
end;
$$;

create or replace function public.save_monthly_target(
  p_month_key text,
  p_default_daily numeric,
  p_season_override text default null
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare v_org uuid := app_private.current_organization_id();
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  insert into public.monthly_targets (organization_id, month_key, default_daily, season_override, updated_at)
  values (v_org, p_month_key, coalesce(p_default_daily,0), nullif(btrim(p_season_override),''), now())
  on conflict (organization_id, month_key) do update set
    default_daily=excluded.default_daily,
    season_override=excluded.season_override,
    updated_at=now();
end;
$$;

create or replace function public.save_daily_target(
  p_day date,
  p_target numeric default null,
  p_deduction numeric default 0,
  p_note text default null
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare v_org uuid := app_private.current_organization_id();
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  insert into public.daily_targets (organization_id, day_date, target_value, deduction, note, updated_at)
  values (v_org, p_day, p_target, coalesce(p_deduction,0), nullif(btrim(p_note),''), now())
  on conflict (organization_id, day_date) do update set
    target_value=excluded.target_value,
    deduction=excluded.deduction,
    note=excluded.note,
    updated_at=now();
end;
$$;

create or replace function public.save_referral_code_cost(
  p_referral_code text,
  p_cost numeric,
  p_note text default null
)
returns public.referral_code_costs
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_org uuid := app_private.current_organization_id();
  v_code text := nullif(btrim(p_referral_code),'');
  result public.referral_code_costs;
begin
  if v_org is null then raise exception 'الحساب غير مرتبط بجمعية فعّالة'; end if;
  if v_code is null then raise exception 'كود الإحالة مطلوب'; end if;
  if p_cost is null or p_cost < 0 then raise exception 'التكلفة يجب أن تكون أكبر من أو تساوي صفر'; end if;

  insert into public.referral_code_costs (organization_id, referral_code, cost, note, updated_at)
  values (v_org, v_code, p_cost, p_note, now())
  on conflict (organization_id, referral_code) do update set
    cost=excluded.cost, note=excluded.note, updated_at=now()
  returning * into result;
  return result;
end;
$$;

-- ملخص خاص ببوابة MCP، ولا يمكن استدعاؤه إلا بمفتاح service_role داخل Edge Function.
create or replace function public.mcp_organization_summary(p_organization_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'organization_id', p_organization_id,
    'operations_rows', (select count(*) from public.operations o where o.organization_id=p_organization_id),
    'donations_count', (select count(distinct o.operation_no) from public.operations o where o.organization_id=p_organization_id),
    'total_amount', (select coalesce(sum(o.total),0) from public.operations o where o.organization_id=p_organization_id),
    'donors_count', (select count(*) from public.donors d where d.organization_id=p_organization_id),
    'active_donors', (select count(*) from public.donors d where d.organization_id=p_organization_id and d.status='مستمر'),
    'campaigns_count', (select count(*) from public.marketing_campaigns c where c.organization_id=p_organization_id),
    'last_operation_at', (select max(o.op_datetime) from public.operations o where o.organization_id=p_organization_id)
  );
$$;

revoke all on function public.mcp_organization_summary(uuid) from public, anon, authenticated;
grant execute on function public.mcp_organization_summary(uuid) to service_role;

revoke execute on function public.upsert_operations(jsonb) from public, anon;
revoke execute on function public.insert_campaign_targets(jsonb) from public, anon;
revoke execute on function public.donor_rebuild_start() from public, anon;
revoke execute on function public.donor_rebuild_chunk(integer,boolean) from public, anon;
revoke execute on function public.donor_rebuild_start_for_phones(text[]) from public, anon;
revoke execute on function public.save_monthly_target(text,numeric,text) from public, anon;
revoke execute on function public.save_daily_target(date,numeric,numeric,text) from public, anon;
revoke execute on function public.save_referral_code_cost(text,numeric,text) from public, anon;
grant execute on function public.upsert_operations(jsonb) to authenticated;
grant execute on function public.insert_campaign_targets(jsonb) to authenticated;
grant execute on function public.donor_rebuild_start() to authenticated;
grant execute on function public.donor_rebuild_chunk(integer,boolean) to authenticated;
grant execute on function public.donor_rebuild_start_for_phones(text[]) to authenticated;
grant execute on function public.save_monthly_target(text,numeric,text) to authenticated;
grant execute on function public.save_daily_target(date,numeric,numeric,text) to authenticated;
grant execute on function public.save_referral_code_cost(text,numeric,text) to authenticated;


commit;


