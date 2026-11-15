import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { parseEnv, promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { access, readFile, stat } from 'node:fs/promises';
import test from 'node:test';
import {
  configuration, createTestUser, deleteTestUser, edge, expectStatus,
  provisionTestDevice, request, rpc, simulatedSighting,
} from '../scripts/client.mjs';

// This is a real Supabase integration test: Auth sessions, deployed Edge handler,
// PostgREST RPCs, and PostgreSQL. It never silently substitutes an in-memory mock.
test('Supabase: simulated sighting is persisted and only its verified owner can retrieve it', { timeout: 180_000 }, async (t) => {
  const config = configuration({ admin: true });
  const users = [];
  async function user(prefix) {
    const value = await createTestUser(config, prefix);
    users.push(value);
    return value;
  }
  t.after(async () => {
    let failures = 0;
    // Delete reporters before the owner, with no competing cascade transactions.
    for (const created of users.reverse()) {
      try { await deleteTestUser(config, created.id); } catch { failures += 1; }
    }
    assert.equal(failures, 0, 'Disposable Auth user cleanup failed.');
  });
  const owner = await user('owner');
  const reporter = await user('reporter');
  const unrelated = await user('unrelated');
  const olderReporter = await user('older-reporter');
  const rateReporter = await user('rate-reporter');
  const concurrentReporter = await user('concurrent-reporter');
  const tag = await provisionTestDevice(config, owner.id);
  const registration = { advertisement_id: tag.advertisementId, claim_token: tag.claimToken, name: 'SIMULATED integration tag' };
  let device;
  let recorded;

  await t.test('registration requires authenticated, preassigned ownership and secret proof', async () => {
    assert.equal((await edge(config, '/devices', { method: 'POST', body: registration })).status, 401);
    const stolen = await edge(config, '/devices', { method: 'POST', token: unrelated.token, body: registration });
    assert.equal(stolen.status, 403);
    assert.equal((await edge(config, '/devices', {
      method: 'POST', token: owner.token, body: { ...registration, claim_token: 'a'.repeat(64) },
    })).status, 403);
    const registered = expectStatus(await edge(config, '/devices', {
      method: 'POST', token: owner.token, body: registration,
    }), 201, 'Registering test device');
    assert.deepEqual(Object.keys(registered).sort(), ['device']);
    device = registered.device;
    assert.deepEqual(Object.keys(device).sort(), ['advertisement_id', 'id', 'name', 'verified_at']);
    assert.equal(device.advertisement_id, tag.advertisementId);
    assert.equal(device.name, registration.name);
    assert.ok(Number.isFinite(Date.parse(device.verified_at)));
    const repeated = expectStatus(await edge(config, '/devices', {
      method: 'POST', token: owner.token, body: registration,
    }), 200, 'Retrying registration');
    assert.equal(repeated.device.id, device.id);
    assert.equal((await edge(config, '/devices', {
      method: 'POST', token: owner.token, body: { ...registration, owner_id: unrelated.id },
    })).status, 400, 'A request cannot inject its own ownership identity.');
  });

  await t.test('a new registered device has no synthetic location', async () => {
    const result = expectStatus(await edge(config, `/devices/${device.id}/last-seen?simulated=true`, {
      token: owner.token,
    }), 200, 'Reading empty device');
    assert.deepEqual(result, { device_id: device.id, sighting: null });
  });

  await t.test('reports require authentication and explicit opt-in', async () => {
    const payload = simulatedSighting(tag.advertisementId);
    assert.equal((await edge(config, '/sightings', { method: 'POST', body: payload })).status, 401);
    assert.equal((await edge(config, '/sightings', { method: 'POST', token: reporter.token, body: payload })).status, 403);
    assert.deepEqual(expectStatus(await edge(config, '/scanner-consent', {
      method: 'POST', token: reporter.token, body: { opted_in: true },
    }), 200, 'Opting reporter in'), { scanner: { opted_in: true } });
  });

  await t.test('synthetic phone report traverses Edge/Auth/Postgres and owner retrieval', async () => {
    const payload = simulatedSighting(tag.advertisementId);
    assert.deepEqual(expectStatus(await edge(config, '/sightings', {
      method: 'POST', token: reporter.token, body: payload,
    }), 202, 'Submitting synthetic sighting'), { accepted: true, duplicate: false });
    const result = expectStatus(await edge(config, `/devices/${device.id}/last-seen?simulated=true`, {
      token: owner.token,
    }), 200, 'Owner retrieving synthetic sighting');
    assert.equal(result.device_id, device.id);
    recorded = result.sighting;
    assert.deepEqual(Object.keys(recorded).sort(), ['accuracy_m', 'latitude', 'longitude', 'observed_at', 'received_at', 'simulated']);
    assert.equal(recorded.latitude, 34.021);
    assert.equal(recorded.longitude, -118.286);
    assert.ok(recorded.accuracy_m >= 150);
    assert.equal(Date.parse(recorded.observed_at), Date.parse(payload.observed_at));
    assert.ok(Number.isFinite(Date.parse(recorded.received_at)));
    assert.equal(recorded.simulated, true);
    // Independent Data API read uses the same caller's database authorization.
    const stored = expectStatus(await rpc(config, 'cg_last_seen', { device_id: device.id, simulated: true }, {
      token: owner.token,
    }), 200, 'Reading persisted sighting directly through authorized RPC');
    assert.equal(stored.status, 200);
    assert.deepEqual(stored.body, result);
  });

  await t.test('unrelated user and reporter cannot read owner location or infer device existence', async () => {
    const missing = await edge(config, `/devices/${randomUUID()}/last-seen?simulated=true`, { token: unrelated.token });
    for (const token of [unrelated.token, reporter.token]) {
      const denied = await edge(config, `/devices/${device.id}/last-seen?simulated=true`, { token });
      assert.equal(denied.status, 404);
      assert.deepEqual(denied.body, missing.body);
      assert.equal(JSON.stringify(denied.body).includes('latitude'), false);
      const direct = expectStatus(await rpc(config, 'cg_last_seen', { device_id: device.id, simulated: true }, { token }), 200, 'Checking direct RPC authorization');
      assert.equal(direct.status, 404);
      assert.deepEqual(direct.body, denied.body);
    }
  });

  await t.test('duplicate suppression and older reports preserve the newest location', async () => {
    assert.deepEqual(expectStatus(await edge(config, '/sightings', {
      method: 'POST', token: reporter.token, body: simulatedSighting(tag.advertisementId, { latitude: 35 }),
    }), 200, 'Submitting duplicate'), { accepted: true, duplicate: true });
    expectStatus(await edge(config, '/scanner-consent', { method: 'POST', token: olderReporter.token, body: { opted_in: true } }), 200, 'Opting second reporter in');
    expectStatus(await edge(config, '/sightings', {
      method: 'POST', token: olderReporter.token,
      body: simulatedSighting(tag.advertisementId, { latitude: 36, observed_at: new Date(Date.parse(recorded.observed_at) - 60_000).toISOString() }),
    }), 202, 'Submitting older report');
    const latest = expectStatus(await edge(config, `/devices/${device.id}/last-seen?simulated=true`, { token: owner.token }), 200, 'Checking newest sighting');
    assert.deepEqual(latest.sighting, recorded);
  });

  await t.test('simulated and real-input channels remain separate', async () => {
    const emptyReal = expectStatus(await edge(config, `/devices/${device.id}/last-seen?simulated=false`, { token: owner.token }), 200, 'Checking isolated non-simulation channel');
    assert.equal(emptyReal.sighting, null);
    // Still synthetic TEST input: exercises the channel flag, not real BLE support.
    expectStatus(await edge(config, '/sightings', {
      method: 'POST', token: reporter.token,
      body: simulatedSighting(tag.advertisementId, { simulated: false, latitude: 33.111111 }),
    }), 202, 'Testing non-simulation channel routing with synthetic test input');
    const realChannel = expectStatus(await edge(config, `/devices/${device.id}/last-seen?simulated=false`, { token: owner.token }), 200, 'Reading test channel');
    assert.equal(realChannel.sighting.simulated, false);
    assert.equal(realChannel.sighting.latitude, 33.111);
    const stillSimulated = expectStatus(await edge(config, `/devices/${device.id}/last-seen?simulated=true`, { token: owner.token }), 200, 'Checking simulation unchanged');
    assert.deepEqual(stillSimulated.sighting, recorded);
  });

  await t.test('invalid reports are rejected before storage', async () => {
    const invalid = [
      { latitude: 91 }, { latitude: -91 }, { longitude: 181 }, { longitude: -181 },
      { latitude: '34.0' }, { longitude: null }, { accuracy_m: -1 }, { accuracy_m: 1001 },
      { simulated: 'true' }, { observed_at: 'yesterday' },
      { observed_at: new Date(Date.now() - 6 * 60_000).toISOString() },
      { observed_at: new Date(Date.now() + 2 * 60_000).toISOString() },
      { reporter_id: unrelated.id },
    ];
    for (const patch of invalid) {
      const response = await edge(config, '/sightings', {
        method: 'POST', token: reporter.token, body: simulatedSighting(tag.advertisementId, patch),
      });
      assert.equal(response.status, 400, `Malformed report with ${Object.keys(patch)[0]} was accepted.`);
    }
    const noSimulation = simulatedSighting(tag.advertisementId);
    delete noSimulation.simulated;
    assert.equal((await edge(config, '/sightings', { method: 'POST', token: reporter.token, body: noSimulation })).status, 400);
    const unknown = await edge(config, '/sightings', { method: 'POST', token: reporter.token, body: simulatedSighting(randomUUID()) });
    assert.equal(unknown.status, 403);
    assert.equal(unknown.body.error.code, 'identifier_not_allowed');
  });

  await t.test('database access cannot bypass opt-in, validation, ownership, or admin enrollment', async () => {
    const noConsent = expectStatus(await rpc(config, 'cg_submit_sighting', simulatedSighting(tag.advertisementId), { token: unrelated.token }), 200, 'Testing RPC opt-in');
    assert.equal(noConsent.status, 403);
    const invalid = expectStatus(await rpc(config, 'cg_submit_sighting', simulatedSighting(tag.advertisementId, { latitude: '34.02' }), { token: reporter.token }), 200, 'Testing RPC validation');
    assert.equal(invalid.status, 400);
    const cannotEnroll = await rpc(config, 'cg_provision_test_device', {
      advertisement_id: randomUUID(), owner_id: unrelated.id, claim_token: 'a'.repeat(64),
    }, { token: unrelated.token });
    assert.ok([401, 403, 404].includes(cannotEnroll.status));
    const anonymousRpc = await rpc(config, 'cg_last_seen', { device_id: device.id, simulated: true });
    assert.ok([401, 403, 404].includes(anonymousRpc.status));
    for (const table of ['sightings', 'devices', 'scanners', 'test_identifiers', 'users']) {
      const exposed = await request(config, `/rest/v1/${table}?select=*`, { token: unrelated.token });
      assert.ok([401, 403, 404].includes(exposed.status), `${table} must not be an exposed readable relation`);
      const privateSchema = await request(config, `/rest/v1/${table}?select=*`, {
        token: unrelated.token, headers: { 'Accept-Profile': 'private' },
      });
      assert.ok([400, 401, 403, 404, 406].includes(privateSchema.status));
    }
  });

  await t.test('parallel rejected reports still consume the atomic per-user rate limit', async () => {
    expectStatus(await edge(config, '/scanner-consent', { method: 'POST', token: rateReporter.token, body: { opted_in: true } }), 200, 'Opting rate-test reporter in');
    // Every unknown identifier is rejected, but must still consume quota. The
    // calls run concurrently to expose read-then-write counter races.
    const results = await Promise.all(Array.from({ length: 65 }, () => edge(config, '/sightings', {
      method: 'POST', token: rateReporter.token, body: simulatedSighting(randomUUID()),
    })));
    assert.ok(results.every((result) => [403, 404, 429].includes(result.status)));
    assert.ok(results.some((result) => result.status === 429), 'Rejected/concurrent reports bypassed the quota.');
    const limited = results.find((result) => result.status === 429);
    assert.equal(limited.body.error.code, 'rate_limited');
    assert.ok(Number(limited.headers.get('Retry-After')) > 0);
  });

  await t.test('parallel duplicate reports produce exactly one accepted write', async () => {
    const concurrentTag = await provisionTestDevice(config, owner.id);
    const registered = expectStatus(await edge(config, '/devices', {
      method: 'POST', token: owner.token,
      body: { advertisement_id: concurrentTag.advertisementId, claim_token: concurrentTag.claimToken, name: 'SIMULATED concurrency test' },
    }), 201, 'Registering concurrency test device');
    expectStatus(await edge(config, '/scanner-consent', {
      method: 'POST', token: concurrentReporter.token, body: { opted_in: true },
    }), 200, 'Opting concurrency reporter in');
    const payload = simulatedSighting(concurrentTag.advertisementId);
    const results = await Promise.all(Array.from({ length: 6 }, () => edge(config, '/sightings', {
      method: 'POST', token: concurrentReporter.token, body: payload,
    })));
    assert.equal(results.filter((result) => result.status === 202 && result.body.duplicate === false).length, 1);
    assert.equal(results.filter((result) => result.status === 200 && result.body.duplicate === true).length, 5);
    const latest = expectStatus(await edge(config, `/devices/${registered.device.id}/last-seen?simulated=true`, {
      token: owner.token,
    }), 200, 'Reading concurrent test sighting');
    assert.equal(Date.parse(latest.sighting.observed_at), Date.parse(payload.observed_at));
  });

  await t.test('the supplied simulator script completes the authenticated owner/outsider demonstration', async () => {
    const { stdout } = await promisify(execFile)(process.execPath, [
      fileURLToPath(new URL('../scripts/simulate-phone.mjs', import.meta.url)), '--consent',
    ], {
      env: {
        ...process.env,
        SUPABASE_URL: config.url,
        SUPABASE_PUBLISHABLE_KEY: config.key,
        REPORTER_ACCESS_TOKEN: reporter.token,
        OWNER_ACCESS_TOKEN: owner.token,
        UNRELATED_ACCESS_TOKEN: unrelated.token,
        DEVICE_ID: device.id,
        ADVERTISEMENT_ID: tag.advertisementId,
      },
      timeout: 45_000,
    });
    assert.match(stdout, /SIMULATED BLE DETECTION/);
    assert.match(stdout, /Unrelated authenticated user denied \(404\)/);
    assert.match(stdout, /Live BLE detection and real phone location reporting remain unverified/);
    for (const secret of [owner.token, reporter.token, unrelated.token, config.secret]) {
      assert.equal(stdout.includes(secret), false, 'Simulator must not log credentials.');
    }
    // Keep the demonstrable synthetic result in CI logs, never its credentials.
    t.diagnostic(stdout.trim());
  });

  await t.test('opting out revokes reporting and removes this reporter’s stored locations', async () => {
    expectStatus(await edge(config, '/scanner-consent', { method: 'POST', token: reporter.token, body: { opted_in: false } }), 200, 'Opting reporter out');
    assert.equal((await edge(config, '/sightings', { method: 'POST', token: reporter.token, body: simulatedSighting(tag.advertisementId) })).status, 403);
    for (const simulated of ['true', 'false']) {
      const result = expectStatus(await edge(config, `/devices/${device.id}/last-seen?simulated=${simulated}`, { token: owner.token }), 200, 'Checking consent withdrawal cleanup');
      assert.equal(result.sighting, null);
    }
  });

  await t.test('operator revocation disables both reporting and owner location retrieval', async () => {
    expectStatus(await edge(config, '/sightings', {
      method: 'POST', token: concurrentReporter.token, body: simulatedSighting(tag.advertisementId),
    }), 202, 'Creating sighting before operator revocation');
    const revoked = expectStatus(await rpc(config, 'cg_provision_test_device', {
      advertisement_id: tag.advertisementId,
      owner_id: owner.id,
      claim_token: tag.claimToken,
      enabled: false,
    }, { admin: true }), 200, 'Revoking allowed test identifier');
    assert.equal(revoked.status, 200);
    const rejected = await edge(config, '/sightings', {
      method: 'POST', token: olderReporter.token, body: simulatedSighting(tag.advertisementId),
    });
    assert.equal(rejected.status, 403);
    assert.equal(rejected.body.error.code, 'identifier_not_allowed');
    assert.equal((await edge(config, `/devices/${device.id}/last-seen?simulated=true`, { token: owner.token })).status, 404);
    const reenabled = expectStatus(await rpc(config, 'cg_provision_test_device', {
      advertisement_id: tag.advertisementId, owner_id: owner.id, claim_token: tag.claimToken, enabled: true,
    }, { admin: true }), 200, 'Re-enabling test identifier to check deletion');
    assert.equal(reenabled.status, 200);
    const empty = expectStatus(await edge(config, `/devices/${device.id}/last-seen?simulated=true`, { token: owner.token }), 200, 'Verifying revocation deleted the stored sighting');
    assert.equal(empty.sighting, null);
  });

  await t.test('demo setup, simulator, and cleanup scripts complete their full lifecycle', async () => {
    const demoFile = new URL('../.env.demo', import.meta.url);
    try {
      await access(demoFile);
      assert.fail('backend/.env.demo already exists. Clean up that demo before running this integration suite; it will not be overwritten or deleted.');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    const env = { ...process.env, SUPABASE_URL: config.url, SUPABASE_PUBLISHABLE_KEY: config.key, SUPABASE_SECRET_KEY: config.secret };
    const run = (name, childEnv, args = []) => promisify(execFile)(process.execPath, [
      fileURLToPath(new URL(`../scripts/${name}.mjs`, import.meta.url)), ...args,
    ], { env: childEnv, timeout: 60_000 });
    await run('setup-demo', env);
    const demo = parseEnv(await readFile(demoFile, 'utf8'));
    try {
      assert.equal((await stat(demoFile)).mode & 0o777, 0o600);
      assert.equal(demo.DEMO_CREATED_BY, 'campus-guard-simulator-v1');
      assert.equal(Object.hasOwn(demo, 'SUPABASE_SECRET_KEY'), false);
      const { stdout } = await run('simulate-phone', { ...env, ...demo }, ['--consent']);
      assert.match(stdout, /Unrelated authenticated user denied \(404\)/);
    } finally {
      await run('cleanup-demo', { ...env, ...demo });
    }
    await assert.rejects(access(demoFile), { code: 'ENOENT' });
    for (const id of [demo.DEMO_OWNER_USER_ID, demo.DEMO_REPORTER_USER_ID, demo.DEMO_UNRELATED_USER_ID]) {
      assert.equal((await request(config, `/auth/v1/admin/users/${id}`, { admin: true })).status, 404);
    }
  });
});
