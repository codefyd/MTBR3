-- ولاء SaaS 3.1 | المرحلة 7/7: تنظيف سجل MCP الناجح بعد 24 ساعة
-- شغّل هذا الملف بعد نجاح المراحل 01 إلى 06.

begin;
set local statement_timeout = '0';

create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

-- يجعل حذف السجلات الناجحة القديمة سريعاً دون تضخيم فهرس الأخطاء.
create index if not exists idx_mcp_audit_success_retention
on public.mcp_audit_logs (created_at)
where status = 'success';

-- إعادة إنشاء المهمة بالاسم نفسه يجعل الملف قابلاً لإعادة التشغيل بأمان.
do $cleanup$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid from cron.job where jobname = 'walaa-purge-successful-mcp-audit'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'walaa-purge-successful-mcp-audit',
    '17 * * * *',
    $job$
      delete from public.mcp_audit_logs
      where status = 'success'
        and created_at < now() - interval '1 day';

      delete from cron.job_run_details
      where end_time < now() - interval '7 days';
    $job$
  );
end;
$cleanup$;

commit;

-- تحقق: يجب أن يظهر صف واحد باسم المهمة وجدولته 17 * * * *.
select jobid, jobname, schedule, active
from cron.job
where jobname = 'walaa-purge-successful-mcp-audit';
