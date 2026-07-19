-- =====================================================================
-- MTBR3 | Campaign Intelligence v2.4
-- إصلاح حذف الحملات + تحديث الاستهداف + مهلة تحديث الحملة الكبيرة.
-- المتطلبات: نجاح v2.3.
-- لا يحذف أو يعدل العمليات أو المتبرعين أو المستهدفين.
-- =====================================================================

begin;

-- أثناء حذف حملة، قد يُحذف بند تكلفة عبر ON DELETE CASCADE بعد اختفاء
-- سجل الحملة. نتأكد من وجود الحملة قبل إنشاء/تحديث سجل الـ Cache.
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

  if v_id is null or not exists (
    select 1 from public.marketing_campaigns c where c.id = v_id
  ) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  insert into public.marketing_campaign_analysis_cache (campaign_id, is_stale, updated_at)
  values (v_id, true, now())
  on conflict (campaign_id) do update
    set is_stale = true, updated_at = now();

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

  if v_id is null or not exists (
    select 1 from public.marketing_campaigns c where c.id = v_id
  ) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  insert into public.marketing_campaign_analysis_cache (campaign_id, is_stale, updated_at)
  values (v_id, true, now())
  on conflict (campaign_id) do update
    set is_stale = true, updated_at = now();

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

-- حذف الـ Cache صراحة قبل الحملة. إذا فشل حذف الحملة تتراجع العملية كاملة.
create or replace function public.delete_marketing_campaign(p_campaign_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_deleted boolean;
begin
  delete from public.marketing_campaign_analysis_cache
  where campaign_id = p_campaign_id;

  delete from public.marketing_campaigns
  where id = p_campaign_id;

  v_deleted := found;
  return v_deleted;
end;
$$;

-- أي إضافة/تعديل/حذف/تفريغ للمستهدفين يجعل مؤشرات الحملات قديمة.
drop trigger if exists trg_mark_targets_campaign_analysis_stale on public.campaign_targets;
create trigger trg_mark_targets_campaign_analysis_stale
after insert or update or delete or truncate on public.campaign_targets
for each statement execute function public.mark_all_campaign_analysis_stale_trigger();

-- المهلة الافتراضية للمستخدم authenticated هي 8 ثوانٍ. نرفعها لهذا
-- الحساب الثقيل وحده، مع بقائه تحت سقف Data API البالغ 60 ثانية.
alter function public.refresh_marketing_campaign_analysis_cache(uuid)
  set statement_timeout = '55s';

alter function public.marketing_campaign_analysis_detail_live(uuid)
  set statement_timeout = '55s';

-- المستهدفون الذين أضيفوا قبل تثبيت v2.4 يجب أن يدخلوا في أول تحديث.
update public.marketing_campaign_analysis_cache
set is_stale = true,
    updated_at = now();

revoke execute on function public.mark_campaign_analysis_stale_trigger() from public, anon, authenticated;
revoke execute on function public.mark_campaign_cost_analysis_stale_trigger() from public, anon, authenticated;
revoke execute on function public.mark_all_campaign_analysis_stale_trigger() from public, anon, authenticated;
revoke execute on function public.delete_marketing_campaign(uuid) from public, anon;
grant execute on function public.delete_marketing_campaign(uuid) to authenticated;

notify pgrst, 'reload schema';
notify pgrst, 'reload config';

commit;

