# تشغيل ترقية SaaS على مراحل

شغّل الملفات بالترتيب داخل Supabase SQL Editor. استخدم New Query لكل ملف، وانتظر `Success` قبل الانتقال للملف التالي:

1. `01_core.sql`
2. `02_tenant_columns.sql`
3. `03_constraints_indexes.sql`
4. `04_functions.sql`
5. `05_caches.sql`
6. `06_rls_and_finalize.sql`

لا تستخدم النظام بين المراحل. بعد نجاح المرحلة السادسة يمكنك رفع ملفات الواجهة ونشر Edge Functions.

كل مرحلة داخل Transaction مستقلة؛ إذا أخفقت مرحلة، أصلح خطأها وأعد تشغيل المرحلة نفسها فقط، ولا تعد المراحل التي ظهر لها `Success`.

## تحقق نهائي

```sql
select
  to_regclass('public.organizations') as organizations_table,
  to_regclass('public.organization_members') as members_table,
  to_regprocedure('public.get_my_access_context()') as access_function,
  exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='operations' and column_name='organization_id'
  ) as operations_has_organization,
  (
    select count(*) from pg_policies
    where schemaname='public'
      and policyname in ('tenant_isolation','tenant_facts_read')
  ) as tenant_policies;
```

النتيجة النهائية: الجداول والدالة ليست `null`، والحقل `true`، وعدد السياسات `15`.
