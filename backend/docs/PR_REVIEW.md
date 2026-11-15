## Task

T-01 — controlled-demo Supabase tracking backend for TrojanGuard / Campus Guard.

## What changes

A confirmed, opted-in reporting account can submit an explicitly enrolled BLE test identifier and approximate phone location. The preassigned, verified owner can retrieve the latest sighting; unrelated accounts cannot. Registration needs an organizer-issued claim secret in addition to the broadcast identifier. Simulated and real reports use separate storage streams.

The backend includes PostgreSQL authorization, atomic rate limits and duplicate suppression, location coarsening, consent withdrawal, expiry filtering, and scheduled deletion. The Edge Function validates the session and forwards the caller JWT; it has no administrative client. The backend retains at most the latest simulated and latest real report per tag. Tests and a simulator exercise the integration boundary without building a phone app or firmware.

## Contract review — `contract-change`

`backend/docs/API_PROPOSAL.md` and `backend/docs/BLE_PROTOCOL.md` propose the initial interface. `docs/CONTRACTS.md` remains unchanged until human approval, per AGENTS.md. The firmware engineer must confirm advertisement bytes and the mobile teammate must confirm scan/filter support. Do not merge or describe this as an approved integration contract before that review.

## Scope outside backend/

- `docs/TASKS.md`: record assigned work and review status.
- `docs/WORKFLOW.md`: append reproducible backend test commands.
- `.env.example`: list backend configuration variable names only.
- `.github/workflows/backend.yml`: run isolated Supabase integration tests on a Docker-capable CI runner.

Existing scaffold files are preserved, with only the task/workflow/env additions described here. No frontend or hardware implementation is added.

## Dependencies and why

- Supabase CLI 3.1.0, pinned development tool: starts the real local Supabase stack, applies SQL migrations, runs pgTAP, and serves/deploys Edge Functions.
- Deno 2.9.6, pinned development tool: type-checks, lints, and formats the Supabase Deno function.
- Supabase-provided PostgreSQL `pg_cron` extension: deletes expired demo tracking data every 15 minutes.
- Supabase-provided PostgreSQL `pgtap` extension: database authorization and retention tests.
- Node.js 24 built-ins: test runner, simulator, provisioning and cleanup. No application/runtime npm dependency, new MCP server, or skill.
- Docker-compatible runtime: required by Supabase local development; already available on GitHub Actions, not installed on the developer's Mac by this change.

## How to test

See `backend/README.md` for clean setup, unit/type/lint checks, real Supabase integration and pgTAP checks, simulated demo, cleanup, and deployment steps. The hardware checklist is separate and remains unverified until run with the phone and ESP32.

## Review checklist

- [ ] Human approval of proposed contract (`contract-change`).
- [ ] Firmware/mobile agreement on the BLE payload.
- [x] Local function tests/type/lint pass (11 function tests; see verification record).
- [x] Real Supabase integration and SQL tests pass in CI (16 integration and 40 pgTAP checks; see verification record).
- [ ] Summary reviewed before merge; no merge performed by this task.
- [ ] Real BLE scan → phone location → authorized owner retrieval demonstrated before claiming live tracking.
