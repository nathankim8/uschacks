# Backend verification record

Scope: controlled, simulated backend milestone only. No real phone BLE callback, phone GPS report, or ESP32 integration has been demonstrated by these checks. No hosted Supabase project is deployed by CI.

## Local checks

On 2026-11-15, Node.js 24.21.0:

- `npm run check`: passed Deno type checking, lint, and formatting.
- `npm test`: 11 function tests passed.
- `git diff --check`: passed.

This Mac has no Docker runtime, so the real Supabase stack is tested on the isolated GitHub Actions runner. The integration suite uses actual Supabase Auth, Edge Functions, PostgREST, and PostgreSQL. Test data is explicitly synthetic and disposable.

## Supabase checks

The prior run exposed an Edge startup readiness check that mistook the gateway's unauthenticated response for readiness. The check now requires the function's structured authentication error across consecutive requests. A new CI run is required before this branch can be described as validated.

Required checks: real integration suite (including owner/unrelated-user isolation and setup/simulator/cleanup lifecycle), and pgTAP authorization/retention tests. Record the passing run link here when available.

## Remaining review

- Human approval of `API_PROPOSAL.md` before changing the shared contract.
- Firmware/mobile agreement on `BLE_PROTOCOL.md`.
- Real phone and ESP32 checks in `REAL_HARDWARE_CHECKLIST.md`.
- User review before merging; no merge is performed by this task.
