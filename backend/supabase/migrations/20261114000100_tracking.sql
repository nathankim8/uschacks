-- Campus Guard controlled-demo API. Private tables are deliberately not exposed
-- through PostgREST. Every callable function rechecks the authenticated actor.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table private.users (
  id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table private.scanners (
  user_id uuid primary key references private.users(id) on delete cascade,
  opted_in boolean not null default false,
  updated_at timestamptz not null default now()
);
create table private.test_identifiers (
  advertisement_id uuid primary key,
  expected_owner_id uuid not null references private.users(id) on delete cascade,
  claim_token_hash bytea not null check (octet_length(claim_token_hash) = 32),
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);
create table private.devices (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references private.users(id) on delete cascade,
  advertisement_id uuid unique not null references private.test_identifiers(advertisement_id) on delete cascade,
  name text not null check (length(name) between 1 and 80),
  verified_at timestamptz not null default now()
);
create index devices_owner_id_idx on private.devices(owner_id);
-- Keep a maximum of two rows per device: latest simulated and latest real report.
create table private.sightings (
  device_id uuid not null references private.devices(id) on delete cascade,
  simulated boolean not null,
  reporter_id uuid not null references private.users(id) on delete cascade,
  latitude numeric(6,3) not null check (latitude between -90 and 90),
  longitude numeric(7,3) not null check (longitude between -180 and 180),
  accuracy_m numeric not null check (accuracy_m between 150 and 1000),
  observed_at timestamptz not null,
  received_at timestamptz not null default now(),
  primary key (device_id, simulated)
);
create index sightings_reporter_id_idx on private.sightings(reporter_id);
create index sightings_observed_at_idx on private.sightings(observed_at);
create table private.sighting_dedup (
  reporter_id uuid not null references private.users(id) on delete cascade,
  device_id uuid not null references private.devices(id) on delete cascade,
  simulated boolean not null,
  accepted_at timestamptz not null,
  primary key (reporter_id, device_id, simulated)
);
create index sighting_dedup_accepted_at_idx on private.sighting_dedup(accepted_at);
create table private.rate_buckets (
  user_id uuid not null references private.users(id) on delete cascade,
  operation text not null,
  window_start timestamptz not null,
  attempts integer not null check (attempts > 0),
  primary key (user_id, operation, window_start)
);
create index rate_buckets_window_start_idx on private.rate_buckets(window_start);

alter table private.users enable row level security;
alter table private.scanners enable row level security;
alter table private.test_identifiers enable row level security;
alter table private.devices enable row level security;
alter table private.sightings enable row level security;
alter table private.sighting_dedup enable row level security;
alter table private.rate_buckets enable row level security;
-- No permissive policies: clients cannot read history, identifiers, secrets, or
-- write tables directly. SECURITY DEFINER API functions are the only entry path.
revoke all on all tables in schema private from public, anon, authenticated;
alter default privileges in schema private revoke all on tables from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated;

create function private.reply(p_status integer, p_body jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('status', p_status, 'body', p_body)
$$;
create function private.failure(p_status integer, p_code text, p_message text) returns jsonb
language sql immutable set search_path = '' as $$
  select private.reply(p_status, jsonb_build_object('error', jsonb_build_object('code', p_code, 'message', p_message)))
$$;
create function private.valid_keys(p_body jsonb, p_keys text[]) returns boolean
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_body) = 'object' and octet_length(p_body::text) <= 4096 then
    (select array_agg(k order by k) from jsonb_object_keys(p_body) k) =
    (select array_agg(k order by k) from unnest(p_keys) k)
  else false end
$$;
create function private.valid_uuid(p_value jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_typeof(p_value) = 'string' and
    (p_value #>> '{}') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false)
$$;
create function private.actor() returns uuid
language sql stable security definer set search_path = '' as $$
  select id from auth.users
  where id = auth.uid()
    and (email_confirmed_at is not null or phone_confirmed_at is not null)
    and not coalesce(is_anonymous, false)
    and (banned_until is null or banned_until <= now())
$$;
-- Returns seconds to wait, or zero when allowed. Atomic UPSERT serializes requests
-- across Edge isolates. Rejections RETURN rather than RAISE so counters persist.
create function private.take_limit(p_user uuid, p_operation text, p_limit integer, p_window_seconds integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_start timestamptz := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  v_count integer;
begin
  insert into private.rate_buckets(user_id, operation, window_start, attempts)
  values (p_user, p_operation, v_start, 1)
  on conflict (user_id, operation, window_start) do update
    set attempts = least(private.rate_buckets.attempts + 1, 1000000)
  returning attempts into v_count;
  if v_count > p_limit then
    return greatest(1, ceil(extract(epoch from v_start + make_interval(secs => p_window_seconds) - now()))::integer);
  end if;
  return 0;
end
$$;
create function private.limited(p_wait integer) returns jsonb
language sql immutable set search_path = '' as $$
  select private.reply(429, jsonb_build_object(
    'error', jsonb_build_object('code', 'rate_limited', 'message', 'Too many requests. Retry after the indicated delay.'),
    'retry_after_seconds', p_wait))
$$;

create function public.cg_set_scanner(p_body jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := private.actor(); v_wait integer; v_opted boolean;
begin
  if v_actor is null then return private.failure(401, 'unauthorized', 'A verified authenticated account is required.'); end if;
  insert into private.users(id) values (v_actor) on conflict do nothing;
  v_wait := private.take_limit(v_actor, 'scanner_minute', 10, 60);
  -- Withdrawal is always available, even after excessive opt-in toggles. Count
  -- the attempt, but never require a user to wait before revoking participation.
  if v_wait > 0 and not coalesce(
    private.valid_keys(p_body, array['opted_in']) and p_body->'opted_in' = 'false'::jsonb, false
  ) then return private.limited(v_wait); end if;
  if not coalesce(private.valid_keys(p_body, array['opted_in']), false)
    or jsonb_typeof(p_body->'opted_in') is distinct from 'boolean' then
    return private.failure(400, 'invalid_request', 'Expected only opted_in as a boolean.');
  end if;
  v_opted := (p_body->>'opted_in')::boolean;
  -- The row lock also serializes reports against withdrawal of consent.
  insert into private.scanners(user_id, opted_in) values (v_actor, v_opted)
  on conflict (user_id) do update set opted_in = excluded.opted_in, updated_at = now();
  if not v_opted then
    delete from private.sightings where reporter_id = v_actor;
    delete from private.sighting_dedup where reporter_id = v_actor;
  end if;
  return private.reply(200, jsonb_build_object('scanner', jsonb_build_object('opted_in', v_opted)));
end
$$;

create function public.cg_register_device(p_body jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := private.actor(); v_wait integer; v_tag private.test_identifiers;
  v_device private.devices; v_status integer := 200;
begin
  if v_actor is null then return private.failure(401, 'unauthorized', 'A verified authenticated account is required.'); end if;
  insert into private.users(id) values (v_actor) on conflict do nothing;
  v_wait := private.take_limit(v_actor, 'register_minute', 5, 60);
  if v_wait > 0 then return private.limited(v_wait); end if;
  if not coalesce(private.valid_keys(p_body, array['advertisement_id','claim_token','name']), false)
    or not private.valid_uuid(p_body->'advertisement_id')
    or jsonb_typeof(p_body->'claim_token') is distinct from 'string'
    or length(p_body->>'claim_token') not between 32 and 256
    or jsonb_typeof(p_body->'name') is distinct from 'string'
    or length(btrim(p_body->>'name')) not between 1 and 80 then
    return private.failure(400, 'invalid_request', 'Expected a canonical advertisement_id, claim_token (32–256 characters), and name (1–80 characters).');
  end if;
  select * into v_tag from private.test_identifiers
    where advertisement_id = (p_body->>'advertisement_id')::uuid for update;
  if not found or not v_tag.enabled or v_tag.expected_owner_id <> v_actor
    or v_tag.claim_token_hash <> sha256(convert_to(p_body->>'claim_token', 'UTF8')) then
    return private.failure(403, 'device_not_claimable', 'This test device cannot be claimed with these credentials.');
  end if;
  select * into v_device from private.devices where advertisement_id = v_tag.advertisement_id;
  if found and v_device.owner_id <> v_actor then
    return private.failure(403, 'device_not_claimable', 'This test device cannot be claimed with these credentials.');
  elsif not found then
    insert into private.devices(owner_id, advertisement_id, name)
      values(v_actor, v_tag.advertisement_id, btrim(p_body->>'name')) returning * into v_device;
    v_status := 201;
  end if;
  return private.reply(v_status, jsonb_build_object('device', jsonb_build_object(
    'id', v_device.id, 'advertisement_id', v_device.advertisement_id,
    'name', v_device.name, 'verified_at', v_device.verified_at)));
end
$$;

create function public.cg_submit_sighting(p_body jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := private.actor(); v_wait integer; v_day_wait integer;
  v_opted boolean; v_tag private.test_identifiers; v_device uuid;
  v_observed timestamptz; v_lat numeric; v_lon numeric; v_accuracy numeric;
  v_simulated boolean; v_previous timestamptz;
begin
  if v_actor is null then return private.failure(401, 'unauthorized', 'A verified authenticated account is required.'); end if;
  insert into private.users(id) values (v_actor) on conflict do nothing;
  v_wait := private.take_limit(v_actor, 'sighting_minute', 30, 60);
  v_day_wait := private.take_limit(v_actor, 'sighting_day', 500, 86400);
  if greatest(v_wait, v_day_wait) > 0 then return private.limited(greatest(v_wait, v_day_wait)); end if;
  select opted_in into v_opted from private.scanners where user_id = v_actor for update;
  if not found or not v_opted then
    return private.failure(403, 'scanner_opt_in_required', 'Opt in to participating scanning before reporting.');
  end if;
  if not coalesce(private.valid_keys(p_body, array['advertisement_id','observed_at','latitude','longitude','accuracy_m','simulated']), false)
    or not private.valid_uuid(p_body->'advertisement_id')
    or jsonb_typeof(p_body->'observed_at') is distinct from 'string'
    or not coalesce((p_body->>'observed_at') ~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d{1,6})?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)$', false)
    or jsonb_typeof(p_body->'latitude') is distinct from 'number'
    or jsonb_typeof(p_body->'longitude') is distinct from 'number'
    or jsonb_typeof(p_body->'accuracy_m') is distinct from 'number'
    or jsonb_typeof(p_body->'simulated') is distinct from 'boolean' then
    return private.failure(400, 'invalid_request', 'Expected advertisement_id, observed_at (RFC3339), numeric latitude/longitude/accuracy_m, and boolean simulated.');
  end if;
  -- Catch only parsing operations; this subtransaction cannot undo rate counts.
  begin
    v_observed := (p_body->>'observed_at')::timestamptz;
    v_lat := (p_body->>'latitude')::numeric;
    v_lon := (p_body->>'longitude')::numeric;
    v_accuracy := (p_body->>'accuracy_m')::numeric;
  exception when invalid_datetime_format or datetime_field_overflow or invalid_text_representation or numeric_value_out_of_range then
    return private.failure(400, 'invalid_request', 'Invalid timestamp or numeric value.');
  end;
  if not isfinite(v_observed) or v_observed < now() - interval '5 minutes' or v_observed > now() + interval '30 seconds'
    or not (v_lat between -90 and 90) or not (v_lon between -180 and 180)
    or not (v_accuracy between 0 and 1000) then
    return private.failure(400, 'invalid_request', 'Coordinates, accuracy, or observation time are outside the permitted range.');
  end if;
  v_simulated := (p_body->>'simulated')::boolean;
  -- Hold registry row so administrative revocation cannot race an accepted write.
  select * into v_tag from private.test_identifiers
    where advertisement_id = (p_body->>'advertisement_id')::uuid for share;
  if not found or not v_tag.enabled then
    return private.failure(403, 'identifier_not_allowed', 'This identifier is not available for the controlled demo.');
  end if;
  select id into v_device from private.devices where advertisement_id = v_tag.advertisement_id;
  if not found then
    return private.failure(403, 'identifier_not_allowed', 'This identifier is not available for the controlled demo.');
  end if;
  -- Scanner row above serializes requests from this reporter, even across devices.
  select accepted_at into v_previous from private.sighting_dedup
    where reporter_id = v_actor and device_id = v_device and simulated = v_simulated;
  if found and v_previous > now() - interval '30 seconds' then
    return private.reply(200, '{"accepted":true,"duplicate":true}'::jsonb);
  end if;
  insert into private.sighting_dedup(reporter_id, device_id, simulated, accepted_at)
    values(v_actor, v_device, v_simulated, now())
  on conflict (reporter_id, device_id, simulated) do update set accepted_at = excluded.accepted_at;
  insert into private.sightings(device_id, simulated, reporter_id, latitude, longitude, accuracy_m, observed_at)
    values(v_device, v_simulated, v_actor, round(v_lat, 3), round(v_lon, 3), greatest(v_accuracy, 150), v_observed)
  on conflict (device_id, simulated) do update set
    reporter_id = excluded.reporter_id, latitude = excluded.latitude, longitude = excluded.longitude,
    accuracy_m = excluded.accuracy_m, observed_at = excluded.observed_at, received_at = excluded.received_at
    where excluded.observed_at > private.sightings.observed_at;
  return private.reply(202, '{"accepted":true,"duplicate":false}'::jsonb);
end
$$;

create function public.cg_last_seen(p_body jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := private.actor(); v_wait integer; v_device uuid; v_sighting jsonb;
begin
  if v_actor is null then return private.failure(401, 'unauthorized', 'A verified authenticated account is required.'); end if;
  insert into private.users(id) values (v_actor) on conflict do nothing;
  v_wait := private.take_limit(v_actor, 'last_seen_minute', 60, 60);
  if v_wait > 0 then return private.limited(v_wait); end if;
  if not coalesce(private.valid_keys(p_body, array['device_id','simulated']), false)
    or not private.valid_uuid(p_body->'device_id')
    or jsonb_typeof(p_body->'simulated') is distinct from 'boolean' then
    return private.failure(400, 'invalid_request', 'Expected only a canonical device_id and boolean simulated.');
  end if;
  select d.id into v_device from private.devices d
    join private.test_identifiers t on t.advertisement_id = d.advertisement_id
    where d.id = (p_body->>'device_id')::uuid and d.owner_id = v_actor and t.enabled;
  if not found then return private.failure(404, 'device_not_found', 'Device not found.'); end if;
  select jsonb_build_object('latitude', s.latitude, 'longitude', s.longitude, 'accuracy_m', s.accuracy_m,
    'observed_at', s.observed_at, 'received_at', s.received_at, 'simulated', s.simulated)
  into v_sighting from private.sightings s
  where s.device_id = v_device and s.simulated = (p_body->>'simulated')::boolean
    and s.observed_at > now() - interval '24 hours';
  return private.reply(200, jsonb_build_object('device_id', v_device, 'sighting', v_sighting));
end
$$;

-- Trusted operator only. Checking physical ownership and issuing the claim token
-- happens out of band; an observed BLE identifier alone is never ownership proof.
create function public.cg_provision_test_device(p_body jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid; v_id uuid; v_enabled boolean := true; v_existing private.test_identifiers;
begin
  if not (coalesce(private.valid_keys(p_body, array['advertisement_id','owner_id','claim_token']), false)
    or coalesce(private.valid_keys(p_body, array['advertisement_id','owner_id','claim_token','enabled']), false))
    or not private.valid_uuid(p_body->'advertisement_id') or not private.valid_uuid(p_body->'owner_id')
    or jsonb_typeof(p_body->'claim_token') is distinct from 'string'
    or length(p_body->>'claim_token') not between 32 and 256
    or (p_body ? 'enabled' and jsonb_typeof(p_body->'enabled') is distinct from 'boolean') then
    return private.failure(400, 'invalid_request', 'Expected advertisement_id, owner_id, claim_token (32–256 characters), and optional enabled boolean.');
  end if;
  v_owner := (p_body->>'owner_id')::uuid;
  v_id := (p_body->>'advertisement_id')::uuid;
  if p_body ? 'enabled' then v_enabled := (p_body->>'enabled')::boolean; end if;
  if not exists(select 1 from auth.users where id = v_owner
    and (email_confirmed_at is not null or phone_confirmed_at is not null) and not coalesce(is_anonymous, false)
    and (banned_until is null or banned_until <= now())) then
    return private.failure(400, 'invalid_owner', 'Owner must be a verified, active account.');
  end if;
  insert into private.users(id) values(v_owner) on conflict do nothing;
  -- This advisory lock protects a not-yet-existing registry row from racing admins.
  perform pg_advisory_xact_lock(hashtextextended(v_id::text, 0));
  select * into v_existing from private.test_identifiers where advertisement_id = v_id for update;
  if found and v_existing.expected_owner_id <> v_owner then
    return private.failure(409, 'identifier_already_provisioned', 'Identifiers cannot be reassigned through the demo API.');
  end if;
  insert into private.test_identifiers(advertisement_id, expected_owner_id, claim_token_hash, enabled)
    values(v_id, v_owner, sha256(convert_to(p_body->>'claim_token', 'UTF8')), v_enabled)
  on conflict (advertisement_id) do update set claim_token_hash = excluded.claim_token_hash, enabled = excluded.enabled;
  if not v_enabled then
    delete from private.sightings where device_id in (select id from private.devices where advertisement_id = v_id);
    delete from private.sighting_dedup where device_id in (select id from private.devices where advertisement_id = v_id);
  end if;
  return private.reply(200, jsonb_build_object('advertisement_id', v_id, 'enabled', v_enabled));
end
$$;

create function private.prune_tracking_data() returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from private.sightings where observed_at <= now() - interval '24 hours';
  delete from private.sighting_dedup where accepted_at <= now() - interval '24 hours';
  delete from private.rate_buckets where window_start <= now() - interval '48 hours';
end
$$;

-- PostgreSQL grants EXECUTE to PUBLIC on newly created functions by default.
revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.cg_set_scanner(jsonb) from public, anon, authenticated;
revoke all on function public.cg_register_device(jsonb) from public, anon, authenticated;
revoke all on function public.cg_submit_sighting(jsonb) from public, anon, authenticated;
revoke all on function public.cg_last_seen(jsonb) from public, anon, authenticated;
revoke all on function public.cg_provision_test_device(jsonb) from public, anon, authenticated;
grant execute on function public.cg_set_scanner(jsonb), public.cg_register_device(jsonb),
  public.cg_submit_sighting(jsonb), public.cg_last_seen(jsonb) to authenticated;
grant execute on function public.cg_provision_test_device(jsonb) to service_role;
