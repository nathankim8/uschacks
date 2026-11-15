-- Run with: cd backend && npx supabase test db
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(40);

insert into auth.users(id, email, email_confirmed_at, is_anonymous) values
  ('10000000-0000-4000-8000-000000000001','cg-owner@example.invalid', now(), false),
  ('10000000-0000-4000-8000-000000000002','cg-reporter@example.invalid', now(), false),
  ('10000000-0000-4000-8000-000000000003','cg-other@example.invalid', now(), false),
  ('10000000-0000-4000-8000-000000000004','cg-unverified@example.invalid', null, false);
create temporary table cg_test_results (name text primary key, response jsonb);
grant all on cg_test_results to authenticated;

select is((public.cg_provision_test_device(jsonb_build_object(
  'advertisement_id','20000000-0000-4000-8000-000000000001',
  'owner_id','10000000-0000-4000-8000-000000000001',
  'claim_token', repeat('a', 64)))->>'status')::integer, 200, 'operator provisions explicit test identifier');
select ok(not has_function_privilege('authenticated', 'public.cg_provision_test_device(jsonb)', 'EXECUTE'), 'mobile callers cannot provision identifiers');
select ok(not has_function_privilege('anon', 'public.cg_submit_sighting(jsonb)', 'EXECUTE'), 'anonymous callers cannot invoke report RPC');
select ok(not has_schema_privilege('authenticated', 'private', 'USAGE'), 'private schema unavailable to mobile callers');
select ok(not has_table_privilege('authenticated', 'private.sightings', 'SELECT'), 'clients cannot read location tables directly');
select is((select count(*)::integer from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='private' and c.relkind='r' and c.relrowsecurity), 7, 'RLS enabled on all private tables');

select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001', true);
set local role authenticated;
insert into cg_test_results values ('register', public.cg_register_device(jsonb_build_object(
  'advertisement_id','20000000-0000-4000-8000-000000000001',
  'claim_token', repeat('a',64), 'name','Demo ESP32')));
select is((select (response->>'status')::integer from cg_test_results where name='register'),201,'verified expected owner claims device');
select is((public.cg_register_device(jsonb_build_object(
  'advertisement_id','20000000-0000-4000-8000-000000000001',
  'claim_token',repeat('a',64),'name','Demo ESP32'))->>'status')::integer,200,'same owner claim is idempotent');
select is((public.cg_last_seen(jsonb_build_object('device_id',
  (select response#>>'{body,device,id}' from cg_test_results where name='register'), 'simulated',true))#>'{body,sighting}'),
  'null'::jsonb, 'owner has no location before reports');

select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
insert into cg_test_results values ('payload', jsonb_build_object(
  'advertisement_id','20000000-0000-4000-8000-000000000001','observed_at',now(),
  'latitude',34.021234,'longitude',-118.285678,'accuracy_m',20,'simulated',true));
select is((public.cg_submit_sighting((select response from cg_test_results where name='payload'))->>'status')::integer,
  403,'authenticated reporter must opt in first');
select is((public.cg_set_scanner('{"opted_in":true}'::jsonb)->>'status')::integer,200,'reporter opts in explicitly');
select is((public.cg_submit_sighting((select response from cg_test_results where name='payload'))->>'status')::integer,
  202,'simulated sighting accepted');
select is((public.cg_submit_sighting((select response from cg_test_results where name='payload'))#>>'{body,duplicate}'),
  'true','duplicate suppressed');
select is((public.cg_submit_sighting((select response || '{"latitude":91}'::jsonb from cg_test_results where name='payload'))->>'status')::integer,
  400,'malformed latitude rejected before duplicate shortcut');
select is((public.cg_submit_sighting((select response || jsonb_build_object('observed_at', now()-interval '6 minutes') from cg_test_results where name='payload'))->>'status')::integer,
  400,'stale reports rejected');
select is((public.cg_submit_sighting((select response || '{"owner_id":"10000000-0000-4000-8000-000000000001"}'::jsonb from cg_test_results where name='payload'))->>'status')::integer,
  400,'extra identity fields rejected');
select is((public.cg_submit_sighting((select response || '{"advertisement_id":"20000000-0000-4000-8000-000000000002"}'::jsonb from cg_test_results where name='payload'))->>'status')::integer,
  403,'unregistered identifiers rejected');

-- A late, valid report is accepted but cannot replace a newer observation.
reset role;
update private.sighting_dedup set accepted_at=now()-interval '31 seconds'
  where reporter_id='10000000-0000-4000-8000-000000000002';
set local role authenticated;
select is((public.cg_submit_sighting((select response || jsonb_build_object(
  'observed_at', now()-interval '1 minute', 'latitude', 10)
  from cg_test_results where name='payload'))->>'status')::integer,202,'out-of-order report is acknowledged');
select is((public.cg_submit_sighting((select response || jsonb_build_object(
  'observed_at', to_char(now(), 'YYYY-MM-DD') || 'T24:00:00Z')
  from cg_test_results where name='payload'))->>'status')::integer,400,'24-hour clock rollover is not accepted');
select is((public.cg_submit_sighting((select response || jsonb_build_object(
  'observed_at', '2026-02-30T12:00:00Z')
  from cg_test_results where name='payload'))->>'status')::integer,400,'impossible calendar dates are rejected');
select is((public.cg_submit_sighting((select response || jsonb_build_object('unused', repeat('x',5000))
  from cg_test_results where name='payload'))->>'status')::integer,400,'oversized direct RPC payload is rejected');

select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
insert into cg_test_results values ('latest', public.cg_last_seen(jsonb_build_object('device_id',
  (select response#>>'{body,device,id}' from cg_test_results where name='register'), 'simulated',true)));
select is((select (response->>'status')::integer from cg_test_results where name='latest'),200,'owner can retrieve sighting');
select is((select response#>>'{body,sighting,latitude}' from cg_test_results where name='latest'),'34.021','latitude is coarsened and older report did not overwrite it');
select is((select response#>>'{body,sighting,accuracy_m}' from cg_test_results where name='latest'),'150','response never implies exact GPS precision');
select is((public.cg_last_seen(jsonb_build_object('device_id',
  (select response#>>'{body,device,id}' from cg_test_results where name='register'), 'simulated',false))#>'{body,sighting}'),
  'null'::jsonb,'simulated data never appears in real stream');

select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',true);
select is((public.cg_last_seen(jsonb_build_object('device_id',
  (select response#>>'{body,device,id}' from cg_test_results where name='register'), 'simulated',true))->>'status')::integer,
  404,'unrelated user cannot retrieve owner location');
select is((public.cg_register_device(jsonb_build_object(
  'advertisement_id','20000000-0000-4000-8000-000000000001',
  'claim_token',repeat('a',64),'name','Stolen claim'))->>'status')::integer,403,'another user cannot claim even with token');

select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000004',true);
select is((public.cg_set_scanner('{"opted_in":true}'::jsonb)->>'status')::integer,401,'unverified user cannot participate');

-- Consent withdrawal cannot be blocked by an exhausted toggle quota.
reset role;
insert into private.rate_buckets(user_id,operation,window_start,attempts)
values('10000000-0000-4000-8000-000000000002','scanner_minute',date_trunc('minute',now()),10)
on conflict(user_id,operation,window_start) do update set attempts=10;
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
select is((public.cg_set_scanner('{"opted_in":false}'::jsonb)->>'status')::integer,200,'reporter withdraws consent despite exhausted toggle quota');
reset role;
select is((select count(*)::integer from private.sightings where reporter_id='10000000-0000-4000-8000-000000000002'),0,'optout removes reporter locations');
select is((select count(*)::integer from private.sighting_dedup where reporter_id='10000000-0000-4000-8000-000000000002'),0,'optout removes reporter dedup metadata');

-- Return errors without raising: rejected requests still consume the durable quota.
set local role authenticated;
select public.cg_submit_sighting('{}'::jsonb) from generate_series(1,30);
select is((public.cg_submit_sighting('{}'::jsonb)->>'status')::integer,429,'rejected requests also exhaust rate limit');
reset role;
select ok((select sum(attempts) > 30 from private.rate_buckets
  where user_id='10000000-0000-4000-8000-000000000002' and operation='sighting_minute'),
  'rate counts survive validation failures');

-- Check daily quota separately from the minute quota.
update private.rate_buckets set attempts=1 where
  user_id='10000000-0000-4000-8000-000000000002' and operation='sighting_minute';
update private.rate_buckets set attempts=500 where
  user_id='10000000-0000-4000-8000-000000000002' and operation='sighting_day';
set local role authenticated;
insert into cg_test_results values('daily',public.cg_submit_sighting('{}'::jsonb));
select is((select (response->>'status')::integer from cg_test_results where name='daily'),429,'daily quota applies independently');
select ok((select (response#>>'{body,retry_after_seconds}')::integer between 1 and 86400
  from cg_test_results where name='daily'),'daily quota returns a bounded retry delay');
reset role;

-- Hide expired data immediately, even if scheduled cleanup has not run yet.
insert into private.sightings(device_id,simulated,reporter_id,latitude,longitude,accuracy_m,observed_at)
values((select (response#>>'{body,device,id}')::uuid from cg_test_results where name='register'),
  true,'10000000-0000-4000-8000-000000000002',34.021,-118.286,150,now()-interval '25 hours');
insert into private.sighting_dedup(reporter_id,device_id,simulated,accepted_at)
values('10000000-0000-4000-8000-000000000002',
  (select (response#>>'{body,device,id}')::uuid from cg_test_results where name='register'),true,now()-interval '25 hours');
insert into private.rate_buckets(user_id,operation,window_start,attempts)
values('10000000-0000-4000-8000-000000000002','expired_test',now()-interval '49 hours',1);
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
set local role authenticated;
select is((public.cg_last_seen(jsonb_build_object('device_id',
  (select response#>>'{body,device,id}' from cg_test_results where name='register'), 'simulated',true))#>'{body,sighting}'),
  'null'::jsonb,'expired location is invisible before cleanup');
reset role;
select private.prune_tracking_data();
select is((select count(*)::integer from private.sightings
  where reporter_id='10000000-0000-4000-8000-000000000002'),0,'cleanup physically removes expired locations');
select is((select count(*)::integer from private.sighting_dedup
  where reporter_id='10000000-0000-4000-8000-000000000002'),0,'cleanup removes expired dedup metadata');
select is((select count(*)::integer from private.rate_buckets
  where user_id='10000000-0000-4000-8000-000000000002' and operation='expired_test'),0,'cleanup removes expired rate metadata');
select ok(exists(select 1 from cron.job where jobname='campus-guard-retention'
  and schedule='*/15 * * * *' and active),'retention cron job is scheduled and enabled');

select * from finish();
rollback;
