import { unlink } from 'node:fs/promises';
import { configuration, deleteTestUser, requiredEnv } from './client.mjs';

try {
  if (requiredEnv('DEMO_CREATED_BY') !== 'campus-guard-simulator-v1') throw new Error('Load the .env.demo produced by setup-demo.mjs.');
  const config = configuration({ admin: true });
  for (const name of ['DEMO_REPORTER_USER_ID', 'DEMO_UNRELATED_USER_ID', 'DEMO_OWNER_USER_ID']) {
    await deleteTestUser(config, requiredEnv(name));
  }
  await unlink(new URL('../.env.demo', import.meta.url)).catch((error) => {
    if (error.code !== 'ENOENT') throw error;
  });
  console.log('Deleted disposable SIMULATED demo users and their cascading test data; removed .env.demo.');
} catch (error) {
  console.error(error instanceof Error ? error.message : 'Demo cleanup failed.');
  process.exitCode = 1;
}
