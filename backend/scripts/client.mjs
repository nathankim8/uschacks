import { randomBytes, randomUUID } from 'node:crypto';

export function requiredEnv(name, fallback) {
  const value = process.env[name] || (fallback && process.env[fallback]);
  if (!value) throw new Error(`Missing ${name}. See backend/README.md for test/demo configuration.`);
  return value;
}

export function configuration({ admin = false } = {}) {
  const url = requiredEnv('SUPABASE_URL').replace(/\/$/, '');
  const parsed = new URL(url);
  if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('SUPABASE_URL must be HTTP(S).');
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(parsed.hostname);
  if (parsed.protocol !== 'https:' && !local) throw new Error('Remote Supabase requests require HTTPS.');
  if (admin && !local && process.env.ALLOW_REMOTE_TEST_PROJECT !== 'true') {
    throw new Error('Administrative test fixtures require a local Supabase instance. For an isolated remote TEST project, explicitly set ALLOW_REMOTE_TEST_PROJECT=true.');
  }
  return {
    url,
    key: requiredEnv('SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_ANON_KEY'),
    secret: admin ? requiredEnv('SUPABASE_SECRET_KEY', 'SUPABASE_SERVICE_ROLE_KEY') : undefined,
  };
}

export async function request(config, path, { method = 'GET', token, body, admin = false, headers = {} } = {}) {
  const key = admin ? config.secret : config.key;
  if (admin && !key) throw new Error('Administrative credentials are not configured.');
  const response = await fetch(`${config.url}${path}`, {
    method,
    headers: {
      apikey: key,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(admin && key?.startsWith('eyJ') ? { Authorization: `Bearer ${key}` } : {}),
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...headers,
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  let result;
  try { result = JSON.parse(text); } catch { result = { error: { message: 'Non-JSON response' } }; }
  return { status: response.status, body: result, headers: response.headers };
}

export function expectStatus(result, expected, operation) {
  const statuses = Array.isArray(expected) ? expected : [expected];
  if (!statuses.includes(result.status)) {
    // Never echo a response that might include access tokens or passwords.
    throw new Error(`${operation} failed: HTTP ${result.status}; expected ${statuses.join('/')}.`);
  }
  return result.body;
}

export function edge(config, path, options) {
  return request(config, `/functions/v1/campus-guard${path}`, options);
}

export async function rpc(config, name, body, options = {}) {
  return request(config, `/rest/v1/rpc/${name}`, { ...options, method: 'POST', body: { p_body: body } });
}

export async function createTestUser(config, prefix) {
  const email = `campus-guard-${prefix}-${randomUUID()}@example.com`;
  const password = randomBytes(32).toString('base64url');
  const created = expectStatus(await request(config, '/auth/v1/admin/users', {
    method: 'POST', admin: true, body: { email, password, email_confirm: true },
  }), [200, 201], 'Creating disposable test user');
  const user = created.user || created;
  if (!user.id) throw new Error('Auth admin response did not contain a user ID.');
  try {
    const session = expectStatus(await request(config, '/auth/v1/token?grant_type=password', {
      method: 'POST', body: { email, password },
    }), 200, 'Signing in disposable test user');
    if (!session.access_token) throw new Error('Auth session did not contain an access token.');
    return { id: user.id, token: session.access_token };
  } catch (error) {
    await deleteTestUser(config, user.id);
    throw error;
  }
}

export async function deleteTestUser(config, id) {
  const result = await request(config, `/auth/v1/admin/users/${id}`, { method: 'DELETE', admin: true });
  expectStatus(result, [200, 204, 404], 'Deleting disposable test user');
}

export async function provisionTestDevice(config, ownerId, advertisementId = randomUUID()) {
  const claimToken = randomBytes(32).toString('hex');
  const result = expectStatus(await rpc(config, 'cg_provision_test_device', {
    advertisement_id: advertisementId, owner_id: ownerId, claim_token: claimToken,
  }, { admin: true }), 200, 'Provisioning explicitly allowed test identifier');
  if (!result || ![200, 201].includes(result.status)) throw new Error('Test identifier provisioning was rejected.');
  return { advertisementId, claimToken };
}

export function simulatedSighting(advertisementId, overrides = {}) {
  return {
    advertisement_id: advertisementId,
    observed_at: new Date().toISOString(),
    // Synthetic coordinates near USC; not measurements from any phone.
    latitude: 34.020512,
    longitude: -118.285643,
    accuracy_m: 75,
    simulated: true,
    ...overrides,
  };
}
