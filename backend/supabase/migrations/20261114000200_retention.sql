-- Supabase provides pg_cron. Keep this separate so embedded database tests can
-- exercise the real data model without pretending to run a scheduler.
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule(
  'campus-guard-retention',
  '*/15 * * * *',
  'select private.prune_tracking_data()'
);
