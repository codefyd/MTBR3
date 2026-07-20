-- ولاء SaaS 3.0 | المرحلة 3/6: تحديث القيود والفهارس
-- شغّل هذا الملف وحده وانتظر Success قبل الانتقال للمرحلة التالية.

begin;
set local statement_timeout = '0';

-- القيود الفريدة يجب أن تكون داخل الجمعية لا على مستوى المنصة كاملة.
alter table public.operations drop constraint if exists uq_operations_line_operation;
create unique index if not exists uq_operations_org_line_operation
  on public.operations (organization_id, line_no, operation_no);

drop index if exists public.uq_campaign_targets_target_key;
create unique index if not exists uq_campaign_targets_org_target_key
  on public.campaign_targets (organization_id, target_key);

alter table public.donors drop constraint if exists donors_pkey;
alter table public.donors add constraint donors_pkey primary key (organization_id, phone);
alter table public.settings drop constraint if exists settings_pkey;
alter table public.settings add constraint settings_pkey primary key (organization_id, id);
alter table public.donor_rebuild_keys drop constraint if exists donor_rebuild_keys_pkey;
alter table public.donor_rebuild_keys add constraint donor_rebuild_keys_pkey primary key (organization_id, phone);
alter table public.monthly_targets drop constraint if exists monthly_targets_pkey;
alter table public.monthly_targets add constraint monthly_targets_pkey primary key (organization_id, month_key);
alter table public.daily_targets drop constraint if exists daily_targets_pkey;
alter table public.daily_targets add constraint daily_targets_pkey primary key (organization_id, day_date);
alter table public.referral_code_costs drop constraint if exists referral_code_costs_pkey;
alter table public.referral_code_costs add constraint referral_code_costs_pkey primary key (organization_id, referral_code);
alter table public.campaign_operation_facts drop constraint if exists campaign_operation_facts_pkey;
alter table public.campaign_operation_facts add constraint campaign_operation_facts_pkey primary key (organization_id, operation_no);

drop index if exists public.uq_marketing_platforms_name_lower;
create unique index if not exists uq_marketing_platforms_org_name_lower
  on public.marketing_platforms (organization_id, lower(name));
drop index if exists public.uq_marketing_projects_name_lower;
create unique index if not exists uq_marketing_projects_org_name_lower
  on public.marketing_projects (organization_id, lower(name));

create index if not exists idx_operations_org_datetime on public.operations (organization_id, op_datetime);
create index if not exists idx_operations_org_phone on public.operations (organization_id, phone);
create index if not exists idx_donors_org_last on public.donors (organization_id, last_donation);
create index if not exists idx_campaign_targets_org_date on public.campaign_targets (organization_id, target_date);
create index if not exists idx_campaign_facts_org_date on public.campaign_operation_facts (organization_id, op_date);


commit;
