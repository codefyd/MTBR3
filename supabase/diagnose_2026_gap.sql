-- =====================================================================
-- تشخيص فرق عدد/مبالغ عمليات 2026
-- شغّله قبل الإصلاح لمعرفة الأرقام الموجودة حاليًا في قاعدة البيانات.
-- =====================================================================

-- 1) إجمالي 2026 الموجود حاليًا في جدول العمليات
select
  count(*)::bigint as rows_count_2026,
  count(distinct operation_no)::bigint as unique_operation_no_2026,
  coalesce(sum(total), 0)::numeric as total_amount_2026,
  coalesce(sum(total) filter (where total is null), 0)::numeric as null_total_sum_2026,
  count(*) filter (where total is null)::bigint as null_total_rows_2026,
  count(*) filter (where op_datetime is null)::bigint as null_datetime_rows_2026
from public.operations
where op_datetime >= make_timestamptz(2026, 1, 1, 0, 0, 0, 'Asia/Riyadh')
  and op_datetime <  make_timestamptz(2027, 1, 1, 0, 0, 0, 'Asia/Riyadh');

-- 2) هل يوجد قيد يمنع تكرار رقم العملية وحده؟
select
  indexname,
  indexdef
from pg_indexes
where schemaname = 'public'
  and tablename = 'operations'
  and indexdef ilike '%unique%';

-- 3) ملخص شهري يساعدك تقارنه مع الشيت شهرًا بشهر
select
  extract(month from (op_datetime at time zone 'Asia/Riyadh'))::int as month_no,
  count(*)::bigint as rows_count,
  count(distinct operation_no)::bigint as unique_operation_no,
  coalesce(sum(total), 0)::numeric as amount
from public.operations
where op_datetime >= make_timestamptz(2026, 1, 1, 0, 0, 0, 'Asia/Riyadh')
  and op_datetime <  make_timestamptz(2027, 1, 1, 0, 0, 0, 'Asia/Riyadh')
group by 1
order by 1;
