---
description: Reconcile src/, the open Studio session, and GitHub
---
Read `docs/RUNBOOK.md` §6 (the sync gesture) and §11 (agent rules) before acting,
then reconcile this repository.

1. Run `status`. If local and `origin/main` have diverged, halt and report.
2. If behind, `git pull --ff-only`.
3. Read `roblox.json` for the placeId, then `list_roblox_studios` and match by
   placeId. If no session is connected, say exactly that and stop — a file edit
   will not reach Studio.
4. `get_studio_state`. If play mode is running, stop it first.
5. For every script mapped in `default.project.json`, compare Studio
   (`script_read`) against disk, using `git HEAD` as the last-synced baseline:
   - only files changed → Rojo already pushed it; continue.
   - only Studio changed → show the diff, ask for approval, then write the file.
   - both changed differently → halt and show both diffs. Never guess.
6. Only when scripts are settled, call `save_place` so geometry is captured in
   the tracked place file.
7. Run `status`, then commit and push the approved changes only, using
   `scripts/sync.sh -m "<message>"`.

Report a one-line summary per surface (files, Studio, GitHub) at the end.

Additional context: $ARGUMENTS
