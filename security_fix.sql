-- =====================================================================
-- ملف تصحيح أمني | منصة ولاء
-- شغّله بالكامل في: Supabase Dashboard > SQL Editor > New Query > Run
-- آمن للتشغيل أكثر من مرة (idempotent).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) [خطير] تفعيل RLS على جدول donor_rebuild_keys
--    كان مكشوفاً لدور anon عبر PostgREST (قراءة/كتابة/حذف بدون تسجيل دخول).
--    لا نضيف أي policy: الدوال security definer تتجاوز RLS وتعمل كالمعتاد،
--    وبدون policy يُمنع anon و authenticated من الوصول المباشر تماماً.
-- ---------------------------------------------------------------------
alter table public.donor_rebuild_keys enable row level security;

-- إلغاء أي صلاحيات مباشرة على الجدول (الوصول يتم فقط عبر الدوال)
revoke all on public.donor_rebuild_keys from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) فحص تحقّق: التأكد أن كل جداول public مفعّل عليها RLS
--    شغّل هذا الاستعلام وراجع النتيجة — يجب أن يكون rls_enabled = true للجميع.
-- ---------------------------------------------------------------------
-- select schemaname, tablename, rowsecurity as rls_enabled
-- from pg_tables
-- where schemaname = 'public'
-- order by rowsecurity asc, tablename;

-- =====================================================================
-- ملاحظات إعداد لوحة Supabase (لا تُنفّذ كـ SQL — خطوات يدوية):
--
--   • Authentication > Providers/Sign In:
--       عطّل "Allow new users to sign up" (Disable sign-ups).
--       أنشئ الحسابات يدوياً من Authentication > Users.
--       السبب: سياسات RLS تستخدم using(true) لكل authenticated،
--       فأي تسجيل ذاتي = وصول كامل للبيانات.
--
--   • Authentication > URL Configuration:
--       Site URL = https://faris0.vip
--       أضف نفس الرابط في Redirect URLs.
-- =====================================================================
