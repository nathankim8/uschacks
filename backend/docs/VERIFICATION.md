# Backend verification record

Scope: controlled, simulated backend milestone only. No real phone BLE callback, phone GPS report, or ESP32 integration has been demonstrated by these checks. No hosted Supabase project is deployed by CI.

## Local checks

On 2026-11-15, Node.js 24.21.0:

- `npm run check`: passed Deno type checking, lint, and formatting.
- `npm test`: 11 function tests passed.
- `git diff --check`: passed.

This Mac has no Docker runtime, so the real Supabase stack is tested on the isolated GitHub Actions runner. The integration suite uses actual Supabase Auth, Edge Functions, PostgREST, and PostgreSQL. Test data is explicitly synthetic and disposable.

## Supabase checks

The [passing GitHub Actions run](https://github.com/nathankim8/uschacks/actions/runs/43703369307) tested implementation commit `68d6e6e` on 2026-11-15. All checks passed:

- Deno type check, lint, and formatting; 11 function tests.
- 16 integration tests using real Supabase services, including the setup/simulator/cleanup lifecycle.
- 40 pgTAP database authorization, validation, quota, and retention tests.

The run demonstrated an authenticated synthetic report accepted by the Edge Function and persisted through PostgREST into PostgreSQL, an owner-authorized read of that persisted sighting, and an unrelated authenticated user's `404` denial. The simulator's coarse synthetic result was latitude `34.021`, longitude `-118.286`, accuracy `150` meters, and `simulated: true`. These are test coordinates, not a phone measurement. Temporary users and their cascading test data were deleted, and CI stopped its isolated services.

The previous failed run exposed an Edge startup readiness check that mistook the gateway's unauthenticated response for readiness. The corrected check requires the function's structured authentication error across consecutive requests. This infrastructure issue is resolved in the passing run.

## Remaining review

- Human approval of `API_PROPOSAL.md` before changing the shared contract.
- Firmware/mobile agreement on `BLE_PROTOCOL.md`.
- Real phone and ESP32 checks in `REAL_HARDWARE_CHECKLIST.md`.
- User review before merging; no merge is performed by this task.
