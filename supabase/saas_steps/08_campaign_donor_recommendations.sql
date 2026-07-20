-- ولاء SaaS 3.2 | المرحلة 8: ترشيح متبرعي الحملات دون كشف جدول العمليات
-- شغّل هذا الملف بعد نجاح المراحل 01 إلى 07.

begin;
set local statement_timeout = '0';

create or replace function public.mcp_recommend_campaign_donors(
  p_organization_id uuid,
  p_day_of_week integer default 5,
  p_send_hour integer default 13,
  p_target_count integer default 1200,
  p_cooldown_days integer default 14
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_period text;
  v_day_name text;
begin
  if p_organization_id is null then raise exception 'معرف الجمعية مطلوب'; end if;
  if p_day_of_week not between 0 and 6 then raise exception 'اليوم يجب أن يكون بين 0 و6'; end if;
  if p_send_hour not between 0 and 23 then raise exception 'ساعة الإرسال يجب أن تكون بين 0 و23'; end if;
  if p_target_count not between 1 and 2000 then raise exception 'العدد المستهدف يجب أن يكون بين 1 و2000'; end if;
  if p_cooldown_days not between 0 and 90 then raise exception 'فترة الاستبعاد يجب أن تكون بين 0 و90 يوماً'; end if;

  v_day_name := (array['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'])[p_day_of_week + 1];
  v_period := case
    when p_send_hour >= 4 and p_send_hour < 12 then 'morning'
    when p_send_hour >= 12 and p_send_hour < 16 then 'noon'
    when p_send_hour >= 16 and p_send_hour < 19 then 'evening'
    else 'night'
  end;

  return (
    with candidate_base as (
      select
        d.phone,
        d.donor_name,
        coalesce(d.donations_count, 0) as donations_count,
        coalesce(d.total_amount, 0) as total_amount,
        d.last_donation,
        coalesce(d.targeted_count, 0) as targeted_count,
        coalesce(d.responded, false) as responded,
        case p_day_of_week
          when 0 then coalesce(d.sun_count, 0)
          when 1 then coalesce(d.mon_count, 0)
          when 2 then coalesce(d.tue_count, 0)
          when 3 then coalesce(d.wed_count, 0)
          when 4 then coalesce(d.thu_count, 0)
          when 5 then coalesce(d.fri_count, 0)
          else coalesce(d.sat_count, 0)
        end as weekday_count,
        case v_period
          when 'morning' then coalesce(d.period_morning, 0)
          when 'noon' then coalesce(d.period_noon, 0)
          when 'evening' then coalesce(d.period_evening, 0)
          else coalesce(d.period_night, 0)
        end as period_count,
        coalesce(greatest(0, (
          (now() at time zone 'Asia/Riyadh')::date
          - (d.last_donation at time zone 'Asia/Riyadh')::date
        )), 9999) as recency_days
      from public.donors d
      where d.organization_id = p_organization_id
        and coalesce(d.phone_status, 'صحيح') = 'صحيح'
        and d.phone is not null
        and d.phone not like 'INVALID:%'
        and d.phone not like 'EMPTY:%'
        and coalesce(d.donations_count, 0) > 0
        and (
          p_cooldown_days = 0
          or d.last_targeted is null
          or d.last_targeted < now() - make_interval(days => p_cooldown_days)
        )
    ), scored as (
      select
        b.*,
        round((
          35 * (b.weekday_count::numeric / greatest(b.donations_count, 1))
          + 20 * (b.period_count::numeric / greatest(b.donations_count, 1))
          + case
              when b.recency_days <= 30 then 20
              when b.recency_days <= 90 then 16
              when b.recency_days <= 180 then 12
              when b.recency_days <= 365 then 8
              else 4
            end
          + least(15::numeric, ln(1 + b.donations_count::numeric) * 6)
          + case when b.responded then 10 when b.targeted_count = 0 then 5 else 0 end
        )::numeric, 2) as score
      from candidate_base b
    ), selected as (
      select
        row_number() over (
          order by s.score desc, s.weekday_count desc, s.last_donation desc nulls last, s.total_amount desc
        ) as recommendation_rank,
        s.*
      from scored s
      order by s.score desc, s.weekday_count desc, s.last_donation desc nulls last, s.total_amount desc
      limit p_target_count
    )
    select jsonb_build_object(
      'organization_id', p_organization_id,
      'target_day', v_day_name,
      'send_hour', p_send_hour,
      'requested_count', p_target_count,
      'returned_count', count(*),
      'cooldown_days', p_cooldown_days,
      'methodology', 'قراءة فقط من ملفات المتبرعين المجمعة: توافق اليوم 35%، فترة الإرسال 20%، حداثة التبرع 20%، التكرار 15%، الاستجابة السابقة 10%. لا تُقرأ العمليات الخام ولا تُعدّل أي بيانات.',
      'candidates', coalesce(jsonb_agg(
        jsonb_build_object(
          'rank', recommendation_rank,
          'phone', phone,
          'donor_name', donor_name,
          'score', score,
          'weekday_donations', weekday_count,
          'period_donations', period_count,
          'donations_count', donations_count,
          'total_amount', total_amount,
          'last_donation', last_donation,
          'recency_days', recency_days,
          'previously_responded', responded,
          'targeted_count', targeted_count
        ) order by recommendation_rank
      ), '[]'::jsonb)
    )
    from selected
  );
end;
$$;

revoke all on function public.mcp_recommend_campaign_donors(uuid,integer,integer,integer,integer)
from public, anon, authenticated;
grant execute on function public.mcp_recommend_campaign_donors(uuid,integer,integer,integer,integer)
to service_role;

-- لا نعرض العمليات الخام للذكاء؛ نستبدل أداتها بأداة الترشيح المجمعة.
alter table public.mcp_access_tokens
  alter column allowed_tools set default array[
    'get_dashboard_summary','search_donors','get_donor_profile',
    'recommend_campaign_donors','list_campaigns','get_campaign_analysis','list_projects'
  ]::text[];

update public.mcp_access_tokens
set allowed_tools = array_append(array_remove(allowed_tools, 'search_operations'), 'recommend_campaign_donors')
where not ('recommend_campaign_donors' = any(allowed_tools));

update public.mcp_access_tokens
set allowed_tools = array_remove(allowed_tools, 'search_operations')
where 'search_operations' = any(allowed_tools);

commit;

-- التحقق: يجب أن تكون الدالة موجودة، ولا يظهر search_operations في أي مفتاح.
select
  to_regprocedure('public.mcp_recommend_campaign_donors(uuid,integer,integer,integer,integer)') as recommendation_function,
  count(*) filter (where 'search_operations' = any(allowed_tools)) as tokens_with_operations_tool,
  count(*) filter (where 'recommend_campaign_donors' = any(allowed_tools)) as tokens_with_recommendation_tool
from public.mcp_access_tokens;
