---
description: Dispatch queued vault tasks to their agents, or inspect the queue
---
Read `docs/AGENTS-WORKFLOW.md` and the vault's `AGENTS.md` before acting.

The vault is `../noclip-protocol-vault` (path in `.noclip`). Never move or re-status a
task note by hand: `noclip` owns the queue.

If the user asked to run work:

1. `noclip status` — report backlog/active counts and whether the studio lock is
   held. Never dispatch while a studio task is active.
2. `noclip doctor` — if anything FAILs, stop and report the first broken link.
3. Dispatch:
   - explicit task id → `noclip run --once --agent <role of that task>`
   - otherwise → `noclip run --jobs <jobs from .noclip>`
4. When the run finishes, `noclip status` again and report: what moved to
   `done/`, what came back `blocked`, and the first line of each blocked note's
   `## Blocked` section.
5. Files-lane branches are not merged automatically. Ask before
   `noclip merge <task-id>`; a merge that conflicts is a design conflict, not a
   mechanical one.

If the user asked to add work, use `noclip new "<title>" --agent <role> --lane
files|studio` and then fill `acceptance:` with one falsifiable line.

Never edit `place/` or run Studio calls from this command.

Additional context: $ARGUMENTS
