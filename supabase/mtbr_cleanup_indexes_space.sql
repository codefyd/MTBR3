-- =============================================================
-- MTBR: تنظيف الفهارس الضخمة بعد امتلاء مساحة Supabase
-- الهدف: تقليل الحجم بدون حذف بيانات العمليات أو المتبرعين.
-- ملاحظة: لا تحذف القيد الفريد الصحيح على (line_no, operation_no).
-- =============================================================

-- 1) تقرير الفهارس قبل التنظيف
select
  schemaname,
  relname as table_name,
  indexrelname as index_name,
  pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
  idx_scan,
  pg_get_indexdef(indexrelid) as index_def
from pg_stat_user_indexes
where schemaname = 'public'
  and relname in ('operations', 'donors', 'donor_rebuild_keys')
order by pg_relation_size(indexrelid) desc;

-- 2) حذف القيد القديم الخاطئ على رقم العملية وحده، إن كان موجودًا.
-- هذا لا يحذف القيد الصحيح على (line_no, operation_no).
alter table if exists public.operations drop constraint if exists uq_operations_operation_no_conflict;
alter table if exists public.operations drop constraint if exists uq_operations_operation_no;
alter table if exists public.operations drop constraint if exists operations_operation_no_key;

drop index if exists public.uq_operations_operation_no_conflict;
drop index if exists public.uq_operations_operation_no;
drop index if exists public.operations_operation_no_key;

-- 3) حذف فهارس v6 الضخمة/المكررة، خصوصًا GIN/TRGM.
-- هذه الفهارس تفيد البحث الجزئي ILIKE '%...%' لكنها تأكل مساحة كبيرة جدًا.
-- بعد حذفها يبقى البحث يعمل، وقد يكون أبطأ عند البحث الجزئي فقط.
drop index if exists public.idx_operations_project_trgm_v6;
drop index if exists public.idx_operations_phone_raw_trgm_v6;
drop index if exists public.idx_operations_phone_trgm_v6;
drop index if exists public.idx_operations_donor_name_trgm_v6;
drop index if exists public.idx_donors_phone_raw_trgm_v6;
drop index if exists public.idx_donors_phone_trgm_v6;
drop index if exists public.idx_donors_donor_name_trgm_v6;

-- 4) حذف فهارس مكررة قديمة، ثم إنشاء فهارس أساسية قليلة بأسماء ثابتة.
-- العمليات: نحتاج التاريخ، رقم العملية، الجوال+التاريخ، الجوال+رقم العملية، وحالة الرقم/المشروع عند الحاجة.
drop index if exists public.idx_operations_opno;
drop index if exists public.idx_operations_operation_no_v6;
drop index if exists public.idx_operations_op_datetime_desc_v6;
drop index if exists public.idx_operations_year_datetime_v6;
drop index if exists public.idx_operations_phone_rebuild;
drop index if exists public.idx_operations_phone_datetime_rebuild;
drop index if exists public.idx_operations_phone_datetime_v6;
drop index if exists public.idx_operations_phone_opno;
drop index if exists public.idx_operations_phone_operation_rebuild;
drop index if exists public.idx_operations_phone_line_operation;
drop index if exists public.idx_operations_project_v6;

create index if not exists idx_operations_operation_no on public.operations (operation_no);
create index if not exists idx_operations_datetime on public.operations (op_datetime);
create index if not exists idx_operations_phone_datetime on public.operations (phone, op_datetime) where phone is not null;
create index if not exists idx_operations_phone_operation on public.operations (phone, operation_no) where phone is not null;
create index if not exists idx_operations_phone_status on public.operations (phone_status);
create index if not exists idx_operations_project on public.operations (project) where project is not null;

-- المتبرعين: نحتاج فهارس للترتيب والفلاتر فقط. الفهرس الأساسي للجوال موجود لأنه PRIMARY KEY.
drop index if exists public.idx_donors_last_donation_desc_v6;
drop index if exists public.idx_donors_total_amount_desc_v6;
drop index if exists public.idx_donors_donations_count_desc_v6;
drop index if exists public.idx_donors_status_category_v6;
drop index if exists public.idx_donors_targeted_count_v6;
drop index if exists public.idx_donors_phone_status_rebuild;
drop index if exists public.idx_donors_phone_status_v6;
-- أبقِ فهرس projects GIN واحد فقط إن وجد؛ واحذف نسخة v6 المكررة.
drop index if exists public.idx_donors_projects_gin_v6;

create index if not exists idx_donors_last on public.donors (last_donation);
create index if not exists idx_donors_total on public.donors (total_amount);
create index if not exists idx_donors_count on public.donors (donations_count);
create index if not exists idx_donors_status on public.donors (status);
create index if not exists idx_donors_category on public.donors (category);
create index if not exists idx_donors_phone_status on public.donors (phone_status);
create index if not exists idx_donors_projects_gin on public.donors using gin (projects);

-- جدول مفاتيح إعادة البناء فارغ عندك لكنه محتفظ بفهرس كبير نسبيًا؛ إعادة بنائه تنظفه.
reindex table public.donor_rebuild_keys;

-- 5) تحديث الإحصاءات ليستفيد المخطط من الفهارس الحالية.
analyze public.operations;
analyze public.donors;

-- 6) تقرير الحجم بعد التنظيف
select
  schemaname,
  relname as table_name,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size,
  pg_size_pretty(pg_relation_size(relid)) as table_size,
  pg_size_pretty(pg_indexes_size(relid)) as indexes_size,
  n_live_tup as live_rows,
  n_dead_tup as dead_rows
from pg_stat_user_tables
where schemaname = 'public'
  and relname in ('operations', 'donors', 'donor_rebuild_keys')
order by pg_total_relation_size(relid) desc;

-- 7) تقرير الفهارس بعد التنظيف
select
  schemaname,
  relname as table_name,
  indexrelname as index_name,
  pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
  idx_scan,
  pg_get_indexdef(indexrelid) as index_def
from pg_stat_user_indexes
where schemaname = 'public'
  and relname in ('operations', 'donors', 'donor_rebuild_keys')
order by pg_relation_size(indexrelid) desc;
