# Workflow

## Branches
```
main                 always demo-able; protected; merge via PR only
 ├─ fe/T-01-...      frontend task (Claude Code agent or human)
 ├─ be/T-02-...      backend task (Codex agent or human)
 ├─ hw/T-03-...      hardware task
 └─ docs/...         plan / contract changes
```
- Each Paradev workspace = its own git worktree + branch, so agents never share files.
- Humans: `git checkout -b fe/T-04-settings-page origin/main`.

## Lifecycle of a task
1. Pick a task from `docs/TASKS.md`, set status to `in progress`, put your name / agent.
2. Create a branch (or a Paradev workspace on that branch).
3. Build against `docs/CONTRACTS.md`. Frontend uses mocks until backend lands.
4. Rebase on `origin/main`, run tests, push, open a PR using the template.
5. Another person (or a review agent) reviews. CI must be green.
6. **Squash-merge** into `main`. Delete the branch.

## Review
- Every PR needs 1 approval from someone who didn't write it (a human, or a review agent run by a human).
- Reviewers check: matches the contract, demo path still works, no secrets, no surprise dependencies.
- Claude Code: run `/code-review` in the PR's workspace for a quick automated pass.

## Integration
- Merge small PRs often (aim: every 1–2 hours) rather than one giant merge at the end.
- After each merge to `main`, someone runs the **demo smoke test** below.
- Freeze `main` ~2 hours before judging: only bug fixes after that.

## Commands
_To be filled in once the stack is chosen._
| What | Frontend | Backend |
|---|---|---|
| Install | | |
| Run dev | | |
| Test | | |
| Lint | | |

## Demo smoke test
_To be filled in from `docs/PLAN.md` → Demo script._

## Backend T-01 commands (Supabase proposal)

Run from `backend/`. Requires Node.js 24 and Docker for the Supabase stack.

| What | Command |
|---|---|
| Install pinned development tools | `npm ci` |
| Start local Supabase / apply fresh migrations | `npm start` |
| Serve Edge Function (second terminal) | `npm run dev` |
| Function tests | `npm test` |
| Type check, lint, formatting | `npm run check` |
| Real Supabase integration | `node --env-file=.env --test --test-concurrency=1 tests/integration.test.mjs` |
| Database security/retention | `npx supabase test db` |
| Simulated milestone | Follow `backend/README.md` → Run the first milestone |

The integration contract is proposed in `backend/docs/API_PROPOSAL.md`; human approval is required before changing `docs/CONTRACTS.md`. CI runs the real Supabase tests on an isolated Docker-capable runner. Real BLE detection and phone GPS are a separate, unverified milestone tracked in `backend/docs/REAL_HARDWARE_CHECKLIST.md`.
