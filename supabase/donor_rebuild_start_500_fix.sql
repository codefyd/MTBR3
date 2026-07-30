-- =====================================================================
-- MTBR3 | إصلاح خطأ 500 عند بدء إعادة احتساب المتبرعين
-- شغّل هذا الملف مرة واحدة كاملًا في Supabase SQL Editor.
--
-- السبب:
-- donor_rebuild_start كان يحذف ويعيد إدخال جميع مفاتيح المتبرعين في طلب
-- واحد. بعد زيادة البيانات وتحويل النظام إلى SaaS قد يتجاوز مهلة PostgREST.
--
-- الحل:
-- 1) تنظيف طابور الجمعية على دفعات.
-- 2) تعبئة الطابور من العمليات على دفعات مرتبة ومفهرسة.
-- 3) منح الدوال الجديدة الصلاحيات نفسها مع إبقاء عزل organization_id.
-- 4) رفع مهلة دوال إعادة البناء كحماية إضافية.
-- =====================================================================

begin;
set local statement_timeout = '0';

create index if not exists idx_operations_org_phone
  on public.operations (organization_id, phone);

create or replace function public.donor_rebuild_clear_chunk(p_limit integer default 5000)
returns jsonb
language plpgsql
security invoker
set search_path = ''
set statement_timeout = '30s'
as $$
declare
  v_org uuid := app_private.current_organization_id();
  v_deleted integer := 0;
  v_has_more boolean := false;
begin
  if v_org is null then
    raise exception 'الحساب غير مرتبط بجمعية فعّالة';
  end if;

  p_limit := greatest(100, least(coalesce(p_limit, 5000), 10000));

  with batch as materialized (
    select k.organization_id, k.phone
    from public.donor_rebuild_keys k
    where k.organization_id = v_org
    order by k.phone
    limit p_limit
  ), deleted as (
    delete from public.donor_rebuild_keys k
    using batch b
    where k.organization_id = b.organization_id
      and k.phone = b.phone
    returning 1
  )
  select count(*)::integer into v_deleted from deleted;

  select exists (
    select 1
    from public.donor_rebuild_keys k
    where k.organization_id = v_org
  ) into v_has_more;

  return jsonb_build_object(
    'deleted', coalesce(v_deleted, 0),
    'has_more', coalesce(v_has_more, false)
  );
end;
$$;

create or replace function public.donor_rebuild_seed_chunk(
  p_after text default null,
  p_limit integer default 5000
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
set statement_timeout = '30s'
as $$
declare
  v_org uuid := app_private.current_organization_id();
  v_scanned integer := 0;
  v_inserted integer := 0;
  v_next_after text;
begin
  if v_org is null then
    raise exception 'الحساب غير مرتبط بجمعية فعّالة';
  end if;

  p_limit := greatest(100, least(coalesce(p_limit, 5000), 10000));

  with batch as materialized (
    select o.phone
    from public.operations o
    where o.organization_id = v_org
      and o.phone is not null
      and btrim(o.phone) <> ''
      and (p_after is null or o.phone > p_after)
    group by o.phone
    order by o.phone
    limit p_limit
  ), inserted as (
    insert into public.donor_rebuild_keys (organization_id, phone)
    select v_org, b.phone
    from batch b
    on conflict (organization_id, phone) do nothing
    returning 1
  )
  select
    count(*)::integer,
    max(phone),
    (select count(*)::integer from inserted)
  into v_scanned, v_next_after, v_inserted
  from batch;

  return jsonb_build_object(
    'scanned', coalesce(v_scanned, 0),
    'inserted', coalesce(v_inserted, 0),
    'next_after', v_next_after,
    'done', coalesce(v_scanned, 0) < p_limit
  );
end;
$$;

revoke execute on function public.donor_rebuild_clear_chunk(integer) from public, anon;
revoke execute on function public.donor_rebuild_seed_chunk(text, integer) from public, anon;
grant execute on function public.donor_rebuild_clear_chunk(integer) to authenticated;
grant execute on function public.donor_rebuild_seed_chunk(text, integer) to authenticated;

alter function public.donor_rebuild_start() set statement_timeout = '45s';
alter function public.donor_rebuild_start_for_phones(text[]) set statement_timeout = '30s';
alter function public.donor_rebuild_chunk(integer, boolean) set statement_timeout = '30s';

notify pgrst, 'reload schema';
notify pgrst, 'reload config';
commit;

-- فحص آمن بعد التشغيل: يجب أن يعيد صفين.
select
  p.oid::regprocedure::text as function_name,
  p.proconfig
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('donor_rebuild_clear_chunk', 'donor_rebuild_seed_chunk')
order by function_name;
