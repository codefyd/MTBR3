-- ولاء SaaS 3.0 | المرحلة 2/6: إضافة organization_id ونقل البيانات الحالية
-- شغّل هذا الملف وحده وانتظر Success قبل الانتقال للمرحلة التالية.

begin;
set local statement_timeout = '0';

-- ---------------------------------------------------------------------
-- إضافة organization_id وترحيل البيانات الحالية دون حذفها.
-- ---------------------------------------------------------------------
alter table public.operations add column if not exists organization_id uuid references public.organizations(id);
alter table public.campaign_targets add column if not exists organization_id uuid references public.organizations(id);
alter table public.donors add column if not exists organization_id uuid references public.organizations(id);
alter table public.settings add column if not exists organization_id uuid references public.organizations(id);
alter table public.donor_rebuild_keys add column if not exists organization_id uuid references public.organizations(id);
alter table public.monthly_targets add column if not exists organization_id uuid references public.organizations(id);
alter table public.daily_targets add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_platforms add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_projects add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_contents add column if not exists organization_id uuid references public.organizations(id);
alter table public.referral_code_costs add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_campaigns add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_campaign_costs add column if not exists organization_id uuid references public.organizations(id);
alter table public.campaign_operation_facts add column if not exists organization_id uuid references public.organizations(id);
alter table public.marketing_campaign_analysis_cache add column if not exists organization_id uuid references public.organizations(id);

do $$
declare
  v_org uuid;
  v_table text;
begin
  select id into v_org from public.organizations order by created_at limit 1;
  foreach v_table in array array[
    'operations','campaign_targets','donors','settings','donor_rebuild_keys',
    'monthly_targets','daily_targets','marketing_platforms','marketing_projects',
    'marketing_contents','referral_code_costs','marketing_campaigns',
    'marketing_campaign_costs','campaign_operation_facts','marketing_campaign_analysis_cache'
  ] loop
    execute format('update public.%I set organization_id = $1 where organization_id is null', v_table) using v_org;
    execute format('alter table public.%I alter column organization_id set default app_private.current_organization_id()', v_table);
    execute format('alter table public.%I alter column organization_id set not null', v_table);
  end loop;
end;
$$;


commit;
