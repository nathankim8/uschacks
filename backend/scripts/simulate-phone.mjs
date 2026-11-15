import { configuration, edge, expectStatus, requiredEnv, simulatedSighting } from './client.mjs';

try {
  if (!process.argv.includes('--consent')) {
    throw new Error('Pass --consent to explicitly opt this authenticated TEST reporter into submitting synthetic location reports.');
  }
  const config = configuration();
  const reporterToken = requiredEnv('REPORTER_ACCESS_TOKEN');
  const ownerToken = requiredEnv('OWNER_ACCESS_TOKEN');
  const advertisementId = requiredEnv('ADVERTISEMENT_ID');
  const deviceId = requiredEnv('DEVICE_ID');
  console.log('SIMULATED BLE DETECTION — no Bluetooth hardware or phone GPS was used.');
  expectStatus(await edge(config, '/scanner-consent', {
    method: 'POST', token: reporterToken, body: { opted_in: true },
  }), 200, 'Opting test reporter in');
  const report = expectStatus(await edge(config, '/sightings', {
    method: 'POST', token: reporterToken, body: simulatedSighting(advertisementId),
  }), [200, 202], 'Submitting synthetic sighting');
  console.log(`Authenticated report accepted (simulated=true, duplicate=${report.duplicate}).`);
  const result = expectStatus(await edge(config, `/devices/${deviceId}/last-seen?simulated=true`, {
    token: ownerToken,
  }), 200, 'Retrieving owner-authorized synthetic sighting');
  if (!result.sighting || result.sighting.simulated !== true) throw new Error('Owner retrieval did not return a simulated sighting.');
  console.log('Owner-authorized SIMULATED last-seen response:');
  console.log(JSON.stringify(result, null, 2));
  if (process.env.UNRELATED_ACCESS_TOKEN) {
    expectStatus(await edge(config, `/devices/${deviceId}/last-seen?simulated=true`, {
      token: process.env.UNRELATED_ACCESS_TOKEN,
    }), 404, 'Verifying unrelated user is denied');
    console.log('Unrelated authenticated user denied (404).');
  }
  console.log('Backend simulation complete. Live BLE detection and real phone location reporting remain unverified.');
} catch (error) {
  console.error(error instanceof Error ? error.message : 'Simulation failed.');
  process.exitCode = 1;
}
