-- ولاء SaaS 3.0 | المرحلة 6/6: سياسات RLS والحماية النهائية
-- شغّل هذا الملف وحده وانتظر Success قبل الانتقال للمرحلة التالية.

begin;
set local statement_timeout = '0';

-- ---------------------------------------------------------------------
-- RLS: العزل الحقيقي في قاعدة البيانات، وليس إخفاءً بصرياً فقط.
-- ---------------------------------------------------------------------
alter table public.organizations enable row level security;
alter table public.platform_admins enable row level security;
alter table public.organization_members enable row level security;
alter table public.mcp_access_tokens enable row level security;
alter table public.mcp_audit_logs enable row level security;

drop policy if exists organizations_select on public.organizations;
create policy organizations_select on public.organizations for select to authenticated
using (
  app_private.is_platform_admin()
  or exists (
    select 1 from public.organization_members m
    where m.organization_id = organizations.id
      and m.user_id = (select auth.uid())
  )
);

drop policy if exists platform_admins_self on public.platform_admins;
create policy platform_admins_self on public.platform_admins for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists organization_members_select on public.organization_members;
create policy organization_members_select on public.organization_members for select to authenticated
using (user_id = (select auth.uid()) or app_private.is_platform_admin());

do $$
declare
  v_table text;
  v_policy record;
begin
  foreach v_table in array array[
    'operations','campaign_targets','donors','settings','donor_rebuild_keys',
    'monthly_targets','daily_targets','marketing_platforms','marketing_projects',
    'marketing_contents','referral_code_costs','marketing_campaigns',
    'marketing_campaign_costs','campaign_operation_facts','marketing_campaign_analysis_cache'
  ] loop
    execute format('alter table public.%I enable row level security', v_table);
    for v_policy in
      select policyname from pg_policies where schemaname = 'public' and tablename = v_table
    loop
      execute format('drop policy if exists %I on public.%I', v_policy.policyname, v_table);
    end loop;
    execute format(
      'create policy tenant_isolation on public.%I for all to authenticated using (app_private.can_access_organization(organization_id)) with check (app_private.can_access_organization(organization_id))',
      v_table
    );
  end loop;
end;
$$;

grant select on public.organizations, public.platform_admins, public.organization_members to authenticated;
grant select, insert, update, delete on
  public.operations, public.campaign_targets, public.donors, public.settings,
  public.donor_rebuild_keys, public.monthly_targets, public.daily_targets,
  public.marketing_platforms, public.marketing_projects, public.marketing_contents,
  public.referral_code_costs, public.marketing_campaigns, public.marketing_campaign_costs,
  public.campaign_operation_facts, public.marketing_campaign_analysis_cache
to authenticated;
revoke insert, update, delete on public.campaign_operation_facts from authenticated;
drop policy if exists tenant_isolation on public.campaign_operation_facts;
create policy tenant_facts_read on public.campaign_operation_facts for select to authenticated
using (app_private.can_access_organization(organization_id));
grant all on public.organizations, public.platform_admins, public.organization_members,
  public.mcp_access_tokens, public.mcp_audit_logs to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;

-- كل جمعية جديدة تحصل على إعداداتها الأساسية تلقائياً.
create or replace function app_private.initialize_organization_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.settings (organization_id, id)
  values (new.id, 1)
  on conflict (organization_id, id) do nothing;

  insert into public.marketing_platforms (organization_id, name, color, is_active)
  values (new.id, 'واتس اب', '#25D366', true)
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists trg_initialize_organization on public.organizations;
create trigger trg_initialize_organization
after insert on public.organizations
for each row execute function app_private.initialize_organization_trigger();
revoke all on function app_private.initialize_organization_trigger() from public, anon, authenticated;

-- منع ربط سجل بمرجع UUID تابع لجمعية أخرى.
create or replace function app_private.assert_tenant_reference_trigger()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_table_name = 'marketing_contents' then
    if new.platform_id is not null and not exists (
      select 1 from public.marketing_platforms p
      where p.id = new.platform_id and p.organization_id = new.organization_id
    ) then raise exception 'المنصة التسويقية لا تتبع الجمعية الحالية'; end if;
    if new.project_id is not null and not exists (
      select 1 from public.marketing_projects p
      where p.id = new.project_id and p.organization_id = new.organization_id
    ) then raise exception 'المشروع لا يتبع الجمعية الحالية'; end if;
  elsif tg_table_name = 'campaign_targets' then
    if new.campaign_id is not null and not exists (
      select 1 from public.marketing_campaigns c
      where c.id = new.campaign_id and c.organization_id = new.organization_id
    ) then raise exception 'الحملة لا تتبع الجمعية الحالية'; end if;
  elsif tg_table_name = 'marketing_campaign_costs' then
    if not exists (
      select 1 from public.marketing_campaigns c
      where c.id = new.campaign_id and c.organization_id = new.organization_id
    ) then raise exception 'تكلفة الحملة لا تتبع الجمعية الحالية'; end if;
  elsif tg_table_name = 'marketing_campaign_analysis_cache' then
    if not exists (
      select 1 from public.marketing_campaigns c
      where c.id = new.campaign_id and c.organization_id = new.organization_id
    ) then raise exception 'ذاكرة التحليل لا تتبع الجمعية الحالية'; end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_tenant_reference_marketing_contents on public.marketing_contents;
create trigger trg_tenant_reference_marketing_contents before insert or update on public.marketing_contents
for each row execute function app_private.assert_tenant_reference_trigger();
drop trigger if exists trg_tenant_reference_campaign_targets on public.campaign_targets;
create trigger trg_tenant_reference_campaign_targets before insert or update on public.campaign_targets
for each row execute function app_private.assert_tenant_reference_trigger();
drop trigger if exists trg_tenant_reference_campaign_costs on public.marketing_campaign_costs;
create trigger trg_tenant_reference_campaign_costs before insert or update on public.marketing_campaign_costs
for each row execute function app_private.assert_tenant_reference_trigger();
drop trigger if exists trg_tenant_reference_analysis_cache on public.marketing_campaign_analysis_cache;
create trigger trg_tenant_reference_analysis_cache before insert or update on public.marketing_campaign_analysis_cache
for each row execute function app_private.assert_tenant_reference_trigger();

-- الدوال العامة التي كانت SECURITY DEFINER تصبح خاضعة لـRLS.
do $$
declare
  v_fn record;
begin
  for v_fn in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any(array[
        'upsert_operations','insert_campaign_targets','donor_rebuild_start',
        'donor_rebuild_chunk','donor_rebuild_start_for_phones','recalculate_donors',
        'update_settings','compute_response_for_phones','dashboard_stats',
        'donors_total_sum','operations_projects','operations_year_summary','reports_stats',
        'save_monthly_target','save_daily_target','targets_month_data','donors_fast_summary',
        'save_referral_code_cost','referral_code_analysis','save_marketing_campaign',
        'delete_marketing_campaign','campaign_match_preview','marketing_campaign_analysis_list',
        'marketing_campaign_analysis_detail','marketing_campaign_analysis_detail_live',
        'empty_marketing_campaign_analysis','refresh_marketing_campaign_analysis_cache',
        'marketing_campaign_analysis_pending'
      ]::text[])
  loop
    execute format('alter function %s security invoker', v_fn.signature);
    execute format('revoke execute on function %s from public, anon', v_fn.signature);
    execute format('grant execute on function %s to authenticated', v_fn.signature);
  end loop;
end;
$$;

notify pgrst, 'reload schema';
notify pgrst, 'reload config';
commit;


-- اكتملت ترقية SaaS 3.0.

