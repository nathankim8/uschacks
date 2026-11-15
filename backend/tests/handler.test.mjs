import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler } from '../supabase/functions/campus-guard/handler.ts';

const verifiedUser = { id: 'user-id', email_confirmed_at: '2026-11-14T00:00:00Z', is_anonymous: false };
const config = { supabaseUrl: 'https://project.example', publishableKey: 'public-key', allowedOrigins: ['https://mobile.example'] };
const uuid = '12345678-1234-4abc-8def-0123456789ab';

function fixture({ user = verifiedUser, authStatus = 200, rpcStatus = 200, result = { status: 202, body: { accepted: true, duplicate: false } }, throws = false } = {}) {
  const calls = [];
  const handler = createHandler(config, async (url, init) => {
    calls.push({ url, init });
    if (throws) throw new Error('secret upstream text');
    return url.endsWith('/user')
      ? Response.json(user, { status: authStatus })
      : Response.json(result, { status: rpcStatus });
  });
  return { handler, calls };
}

function request(path = '/sightings', { method = 'POST', body = '{}', token = 'user-jwt', headers = {} } = {}) {
  return new Request(`https://edge.example/functions/v1/campus-guard${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), 'content-type': 'application/json', ...headers },
    ...(method === 'POST' ? { body } : {}),
  });
}

test('missing bearer token is denied before any upstream request', async () => {
  const { handler, calls } = fixture();
  assert.equal((await handler(request('/sightings', { token: null }))).status, 401);
  assert.equal(calls.length, 0);
});

test('expired JWT, anonymous account and unverified account cannot reach RPC', async () => {
  for (const args of [{ authStatus: 401 }, { user: { ...verifiedUser, is_anonymous: true } }, { user: { id: 'unconfirmed' } }]) {
    const { handler, calls } = fixture(args);
    assert.equal((await handler(request())).status, 401);
    assert.equal(calls.length, 1);
  }
});

test('auth service outages are distinguishable from invalid sessions without leaking details', async () => {
  for (const args of [{ authStatus: 503 }, { authStatus: 429 }, { throws: true }]) {
    const { handler } = fixture(args);
    const response = await handler(request());
    assert.equal(response.status, 503);
    assert.doesNotMatch(await response.text(), /secret upstream/);
  }
});

test('phone-confirmed accounts work and the original user JWT reaches Postgres', async () => {
  const { handler, calls } = fixture({ user: { id: 'user-id', phone_confirmed_at: '2026-11-14T00:00:00Z' } });
  const body = { simulated: true };
  const response = await handler(request('/sightings', { body: JSON.stringify(body) }));
  assert.equal(response.status, 202);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(calls[1].url, 'https://project.example/rest/v1/rpc/cg_submit_sighting');
  assert.equal(calls[1].init.headers.Authorization, 'Bearer user-jwt');
  assert.equal(calls[1].init.headers.apikey, 'public-key');
  assert.deepEqual(JSON.parse(calls[1].init.body), { p_body: body });
});

test('last-seen requires an explicit simulation stream and valid device UUID', async () => {
  for (const query of ['', '?simulated=yes', '?simulated=true&simulated=false', '?simulated=true&owner_id=someone']) {
    const { handler, calls } = fixture();
    assert.equal((await handler(request(`/devices/${uuid}/last-seen${query}`, { method: 'GET' }))).status, 400);
    assert.equal(calls.length, 1);
  }
  const { handler, calls } = fixture({ result: { status: 200, body: { device_id: uuid, sighting: null } } });
  const response = await handler(request(`/devices/${uuid}/last-seen?simulated=false`, { method: 'GET' }));
  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse(calls[1].init.body), { p_body: { device_id: uuid, simulated: false } });
});

test('JSON and payload limits reject invalid data before RPC, even without Content-Length', async () => {
  for (const [body, expected] of [['{', 400], ['null', 400], ['[]', 400], ['"value"', 400], [' '.repeat(4097), 413], [JSON.stringify({ text: '😅'.repeat(1100) }), 413]]) {
    const { handler, calls } = fixture();
    const response = await handler(request('/sightings', { body }));
    assert.equal(response.status, expected);
    assert.equal(calls.length, 1);
  }
});

test('wrong method, unsupported media type, unknown route and extra query are rejected', async () => {
  for (const [path, args, expected] of [
    ['/devices', { method: 'GET' }, 405],
    ['/sightings', { headers: { 'content-type': 'text/plain' } }, 415],
    ['/missing', {}, 404],
    ['/sightings?bypass=true', {}, 400],
  ]) {
    const { handler, calls } = fixture();
    assert.equal((await handler(request(path, args))).status, expected);
    assert.equal(calls.length, 1);
  }
});

test('CORS is a configured browser allowlist, native no-Origin requests work', async () => {
  const { handler, calls } = fixture();
  const rejected = await handler(request('/sightings', { headers: { origin: 'https://unknown.example' } }));
  assert.equal(rejected.status, 403);
  assert.equal(calls.length, 0);
  const preflight = await handler(request('/sightings', { method: 'OPTIONS', token: null, headers: { origin: 'https://mobile.example' } }));
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('access-control-allow-origin'), 'https://mobile.example');
  assert.equal(calls.length, 0);
  assert.equal((await handler(request())).status, 202);
});

test('database denial and retry limits are preserved without privileged fallback', async () => {
  for (const status of [400, 401, 403, 404, 409, 429]) {
    const body = { error: { code: 'denied', message: 'Denied.' }, ...(status === 429 ? { retry_after_seconds: 91 } : {}) };
    const { handler, calls } = fixture({ result: { status, body } });
    const response = await handler(request());
    assert.equal(response.status, status);
    assert.deepEqual(await response.json(), body);
    if (status === 429) assert.equal(response.headers.get('retry-after'), '91');
    assert.equal(calls.length, 2);
  }
});

test('unexpected database output is hidden', async () => {
  for (const args of [{ rpcStatus: 500, result: { secret: 'database internals' } }, { result: { status: 999, body: {} } }]) {
    const { handler } = fixture(args);
    const response = await handler(request());
    assert.equal(response.status, 503);
    assert.doesNotMatch(await response.text(), /database internals/);
  }
});

test('misconfiguration fails closed', async () => {
  const handler = createHandler({ ...config, publishableKey: '' }, () => { throw new Error('must not reach upstream'); });
  assert.equal((await handler(request())).status, 503);
});
