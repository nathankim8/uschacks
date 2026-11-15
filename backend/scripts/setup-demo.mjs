import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { configuration, createTestUser, deleteTestUser, edge, expectStatus, provisionTestDevice } from './client.mjs';

const config = configuration({ admin: true });
const users = [];
try {
  const owner = await createTestUser(config, 'demo-owner');
  users.push(owner);
  const reporter = await createTestUser(config, 'demo-reporter');
  users.push(reporter);
  const unrelated = await createTestUser(config, 'demo-unrelated');
  users.push(unrelated);
  const testTag = await provisionTestDevice(config, owner.id);
  const registered = expectStatus(await edge(config, '/devices', {
    method: 'POST', token: owner.token,
    body: { advertisement_id: testTag.advertisementId, claim_token: testTag.claimToken, name: 'SIMULATED demo tag' },
  }), 201, 'Registering simulated demo tag');
  const destination = new URL('../.env.demo', import.meta.url);
  const contents = Object.entries({
    DEMO_CREATED_BY: 'campus-guard-simulator-v1',
    SUPABASE_URL: config.url,
    SUPABASE_PUBLISHABLE_KEY: config.key,
    OWNER_ACCESS_TOKEN: owner.token,
    REPORTER_ACCESS_TOKEN: reporter.token,
    UNRELATED_ACCESS_TOKEN: unrelated.token,
    DEMO_OWNER_USER_ID: owner.id,
    DEMO_REPORTER_USER_ID: reporter.id,
    DEMO_UNRELATED_USER_ID: unrelated.id,
    DEVICE_ID: registered.device.id,
    ADVERTISEMENT_ID: testTag.advertisementId,
  }).map(([key, value]) => `${key}=${JSON.stringify(value)}`).join('\n');
  // Exclusive create prevents replacing credentials needed to clean up an earlier demo.
  await writeFile(destination, `# SIMULATED test fixtures only. Private, short-lived user tokens; never commit.\n${contents}\n`, { mode: 0o600, flag: 'wx' });
  console.log(`SIMULATED demo fixtures created. Credentials saved privately to ${fileURLToPath(destination)}.`);
  console.log('From backend/: node --env-file=.env.demo scripts/simulate-phone.mjs --consent');
  console.log('These are test accounts and synthetic inputs. No Bluetooth scan has occurred.');
} catch (error) {
  let cleanupFailures = 0;
  for (const user of users.reverse()) {
    try { await deleteTestUser(config, user.id); } catch { cleanupFailures += 1; }
  }
  if (cleanupFailures) console.error('Some disposable test users could not be removed; inspect the test project Auth users.');
  console.error(error instanceof Error ? error.message : 'Demo setup failed.');
  process.exitCode = 1;
}
