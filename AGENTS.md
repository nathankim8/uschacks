# AGENTS.md — Shared rules for every agent and human

This file is read by Claude Code (via `CLAUDE.md`), Codex, and humans. Keep it short and current.

## 1. Read before you start
1. `docs/PLAN.md` — what we're building and the demo script.
2. `docs/CONTRACTS.md` — the frontend ↔ backend interface. **This is the source of truth.**
3. `docs/TASKS.md` — find your task. Only work on the task you were assigned.
4. `docs/WORKFLOW.md` — branches, PRs, testing, merging.

## 2. Ownership (who touches what)
| Area | Owner | Folder |
|---|---|---|
| Frontend | Claude Code agents + assigned humans | `frontend/` |
| Backend | Codex agents + assigned humans | `backend/` |
| Shared interface | Planning agent / tech lead only | `docs/CONTRACTS.md`, `shared/` |
| Hardware (if any) | Assigned human | `hardware/` |

- Stay inside your folder. If you must change something outside it, say so in your PR description.
- **Never change `docs/CONTRACTS.md` silently.** Propose the change in your PR, tag it `contract-change`, and stop until a human approves.
- Frontend must work against **mock data** that matches the contract until the real backend is ready.
- Backend must serve responses that **exactly match** the contract shapes.

## 3. Git rules
- One task = one branch = one PR. Branch names: `fe/<task-id>-<slug>`, `be/<task-id>-<slug>`, `hw/...`, `docs/...`.
- Never commit directly to `main`. Never force-push to `main`.
- Commit small and often. Message format: `fe: add login form (T-03)`.
- Before opening a PR: `git fetch origin && git rebase origin/main`, then re-run tests.
- Do not commit secrets. Put them in `.env` (gitignored) and list the variable names in `.env.example`.

## 4. Definition of done
A task is done when:
- [ ] It does what the task's acceptance criteria say.
- [ ] Tests / lint pass locally (commands in `docs/WORKFLOW.md`).
- [ ] It matches `docs/CONTRACTS.md`.
- [ ] The PR description explains what changed and how to test it.
- [ ] `docs/TASKS.md` status is updated.

## 5. Agent behavior
- Do **not** install new dependencies, MCP servers, or skills without listing them in the PR and explaining why.
- Prefer boring, well-known libraries. We have limited time.
- If blocked or unsure about scope, stop and ask — don't guess at the contract.
- Keep the demo path working. A smaller feature that works beats a big one that doesn't.
- Don't refactor code you don't own.

## 6. Commands
_Filled in once the stack is chosen (see `docs/WORKFLOW.md`)._
