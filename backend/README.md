# TrojanGuard / Campus Guard backend

Controlled-demo Supabase backend only. No mobile app or ESP32 firmware is implemented here. It accepts a participating phone's approximate position near a pre-enrolled BLE test tag; the tag itself has no GPS or cellular connection.

The initial integration contract is proposed in [API_PROPOSAL.md](docs/API_PROPOSAL.md) and [BLE_PROTOCOL.md](docs/BLE_PROTOCOL.md). The shared `docs/CONTRACTS.md` stays unchanged until human approval in the `contract-change` PR. The mobile and firmware teammates must confirm the proposal before integration is frozen.

## What is included

- Supabase Auth sessions; verified, non-anonymous accounts only.
- Operator-enrolled identifiers, preassigned owners, and private claim-token verification.
- Scanner opt-in/withdrawal, authenticated sighting reports, owner-only last-seen lookup.
- PostgreSQL private tables with RLS and no client table privileges; narrowly granted routines enforce access using the caller's JWT identity.
- Atomic database rate limits, duplicate suppression, newest-only storage, three-decimal coordinates, and scheduled expiry.
- Separate simulated and real report streams, explicit simulation labels, a runnable phone simulator, and authorization tests.

The Edge Function uses native `fetch`, checks the bearer token through Supabase Auth, and forwards it to PostgreSQL. It does not need an administrative key. Disabling gateway `verify_jwt` in `config.toml` allows current and legacy signing-key projects; it does **not** disable the handler's authentication. See Supabase's [key migration guidance](https://supabase.com/docs/guides/getting-started/migrating-to-new-api-keys) and [authorization headers](https://supabase.com/docs/guides/functions/auth-headers).

## Local setup

Requires Node.js 24+, npm, and a running Docker-compatible runtime. Supabase CLI and Deno are pinned development dependencies. Nothing needs a global npm install. The local stack is the actual Supabase Auth, PostgreSQL, Data API, and Edge runtime, not an in-memory substitute.

From the repository root:

```bash
cd backend
npm ci
npm run check
npm test
npm start
```

`npm start` applies the migrations to a fresh local stack. If reusing a development database, `npx supabase migration up --local` applies pending migrations without resetting existing data. This project does not seed any universally authorized tag or reusable secret. `npx supabase db reset` is **only** for a disposable local database; it deletes its existing data.

Copy the local `API_URL`, `ANON_KEY`, and `SERVICE_ROLE_KEY` from `npx supabase status` into a private `backend/.env` using the corresponding variable names below. The root `.env.example` lists all supported names. Do not commit this file, screenshots of keys, or the generated `.env.demo`.

```dotenv
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_PUBLISHABLE_KEY=<local ANON_KEY>
SUPABASE_SECRET_KEY=<local SERVICE_ROLE_KEY; setup/test/cleanup only>
```

Start the function in a second terminal:

```bash
cd backend
npm run dev
```

Local confirmation email can be inspected at `http://127.0.0.1:54324`. Test fixture scripts create already-confirmed disposable accounts through the trusted Auth admin API; they do not send mail. Ordinary app accounts must complete verification.

## Run the first milestone

With the stack and Edge Function running:

```bash
# Creates three disposable users and one explicitly enrolled, claimed test tag.
# Writes backend/.env.demo with mode 0600; refuses to overwrite it.
node --env-file=.env scripts/setup-demo.mjs

# Explicitly consent as the TEST reporter, submit synthetic data, retrieve as
# owner, and check that the unrelated signed-in account receives 404.
npm run demo -- --consent

# Remove the disposable users and their cascading data, then remove .env.demo.
node --env-file=.env --env-file=.env.demo scripts/cleanup-demo.mjs
```

Expected output includes `SIMULATED BLE DETECTION`, an accepted authenticated report, an owner response with `simulated: true`, and `Unrelated authenticated user denied (404)`. No phone GPS or BLE detection is used. User access tokens expire; clean up and recreate the fixtures if needed. `setup-demo.mjs` deliberately keeps the privileged key out of `.env.demo`; the simulator only uses user tokens and the publishable key.

## Tests

```bash
npm run check
npm test
node --env-file=.env --test --test-concurrency=1 tests/integration.test.mjs
npx supabase test db
```

The integration suite creates fresh users, gets actual Auth JWTs, submits through the Edge Function, reads the stored result as owner, checks unrelated-user denial, and runs the supplied simulator. It also tests malicious requests, consent withdrawal, concurrent limits, duplicate suppression, and direct Data API attempts. It fails when Supabase credentials are missing; it does not silently skip or replace the database with a mock.

The pgTAP suite checks database privileges, RLS, expiry, physical pruning, daily limits, and the scheduled cleanup job. SQL tests roll back their fixtures. Integration tests delete their disposable Auth users and linked backend rows afterward.

The [backend workflow](../.github/workflows/backend.yml) runs these checks against an isolated Supabase stack on GitHub Actions, which supplies Docker. Local unit/type/lint checks work without Docker. GitHub test runs do not deploy a persistent hosted backend.

## Hosted demo deployment

Use an isolated Supabase **test** project and obtain review of the contract proposal first. Confirm PostgreSQL 17 compatibility, email/phone verification settings, and that anonymous sign-in is disabled. The backend additionally rejects unverified/anonymous/banned users even if a project's Auth settings are changed.

```bash
cd backend
npx supabase login
npx supabase link --project-ref <your-test-project-ref>
npx supabase db push --dry-run
npx supabase db push
npx supabase functions deploy campus-guard
```

Keep the function's `verify_jwt=false` setting from the checked-in config: the function verifies every user through Auth. Set the optional Edge secret `CAMPUS_GUARD_PUBLISHABLE_KEY` to the project's current publishable key when using current API keys; local runtimes can use their injected `SUPABASE_ANON_KEY`. Set `ALLOWED_ORIGINS` only if a browser integration is needed (comma-separated exact origins, no wildcard). Native phone requests need no `Origin` header. Use a private environment file with `npx supabase secrets set --env-file <private-edge-env>`; never put service keys in that file or the mobile app.

Put the hosted URL, publishable key and trusted setup-only secret key in your private `.env`. Administrative fixtures default to local-only; an isolated hosted test project requires `ALLOW_REMOTE_TEST_PROJECT=true`. Inspect the target URL before enabling that option. Run the same integration test, then create demo fixtures. Share only the API base URL, publishable key, approved protocol, and out-of-band demo UUID allowlist with the mobile teammate. Deliver each claim token privately to its assigned owner.

The cleanup migration enables `pg_cron` and schedules `campus-guard-retention` every 15 minutes. Verify its successful runs in the Supabase SQL editor:

```sql
select jobname, schedule, active from cron.job where jobname = 'campus-guard-retention';
select status, start_time, end_time from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = 'campus-guard-retention')
order by start_time desc limit 5;
```

Last-seen filtering hides observations after 24 hours independently of cron; prompt physical deletion still depends on the scheduled job. Configure backup/log retention separately. See [SECURITY.md](docs/SECURITY.md) for the exact threat model and retention limits.

## Handoff and verification status

Run [REAL_HARDWARE_CHECKLIST.md](docs/REAL_HARDWARE_CHECKLIST.md) with both teammates. The phone must report data from a real BLE callback and fresh location fix using `simulated:false`, and the owner must retrieve it remotely. All three must be demonstrated before calling this live crowdsourced tracking.

See [VERIFICATION.md](docs/VERIFICATION.md) for evidence gathered for this branch. The branch stays separate and unmerged for review. No public deployment is authorized by passing a controlled simulation; rotating identifiers and unwanted-tracking protections remain required before public use.
