# Multi-agent workflow

How work moves through this repository without a server, a paid orchestrator, or
a shared chat window.

- **Memory and queue:** `../noclip-vault` (Obsidian folder, its own git repo).
- **Scheduler:** the `noclip` command (`scripts/noclip.sh` in `~/dotfiles`).
- **Workers:** `opencode run --agent <role>` — one process per task.
- **Isolation:** one git worktree per `files`-lane task.
- **Serialization:** one Studio at a time, enforced by a lock directory.

The decision behind this shape is recorded in the vault at
`90-decisions/0001-vault-as-blackboard.md`.

---

## 1. The queue

A task is one Markdown note. Frontmatter is the machine contract:

```markdown
---
id: 0007-inventory-ui
title: Inventory HUD panel
agent: asset-smith
lane: studio
status: backlog
priority: 3
depends:
acceptance: panel opens on Tab, 3 slots, no console errors
---
## Intent
## Log
```

| Field | Meaning |
|---|---|
| `agent` | one of the seven roles; anything else is not dispatched |
| `lane` | `studio` (live DataModel) or `files` (everything else) |
| `status` | `backlog` → `active` → `done` / `blocked` |
| `acceptance` | one line; if a `qa` run cannot fail it unambiguously, rewrite it |
| `depends` | task IDs that must land first |

State is the **directory**, not the field: `40-tasks/backlog/`,
`40-tasks/active/`, `40-tasks/done/`. The `status` field exists so Obsidian and
`cp`/`mv` accidents stay visible.

Claiming is `mv` into `active/`. On one filesystem that is atomic: every racing
worker fails but one, and a failure to move means "somebody else has it".

---

## 2. Roles

| Role | Surface | Lane | Refuses |
|---|---|---|---|
| `librarian` | vault only | files | touching code, marking tasks done |
| `designer` | `10-design/`, `00-brief/` | files | writing Luau, opening Studio |
| `scripter` | `src/`, Rojo mapping | files | `place/`, `save_place`, publishing |
| `asset-smith` | Studio instances, `20-assets/` | studio | scripts, deleting foreign instances |
| `audio` | cue sheets, `Sound` instances | files → studio | inventing `SoundId`s |
| `qa` | verification only | studio | editing anything but its report |
| `builder` | merges, build, publish | files | force-push, unverified "done" |
| `lore-keeper` | `60-lore/` wiki corpus | files | code, design, `game_hooks` |

Definitions live in `~/dotfiles/agents/*.md`, deployed by Home Manager to
`~/.config/opencode/agents/`. Edit them there, not per project.

A role's permissions are enforced, not advisory: `scripter` cannot write
`place/`, `designer` cannot write `src/`, `qa` can only append to `50-log/`.

---

## 3. Lanes

### files lane (parallel)

1. `noclip` creates `.noclip-worktrees/wt-<task-id>` from `HEAD` on branch
   `noclip/<task-id>`.
2. The agent works there, commits, and appends to the note.
3. `noclip merge <task-id>` merges that branch into the current one with
   `--no-ff`, removes the worktree and deletes the branch.

Two `scripter` tasks therefore never touch the same checkout, so there is nothing
to conflict until merge time — and a conflict is then a real design conflict, not
a race.

### studio lane (serialized)

Runs in the **main checkout**, never in a worktree, because Rojo is bound to this
directory and Studio sees one filesystem. `noclip` takes
`../noclip-vault/.locks/studio` for the duration; other studio tasks wait, and
give up after `lock_wait` seconds (default 600) and requeue.

Rule of thumb: keep studio tasks small. A 20-minute mesh batch blocks every other
Studio role, including `qa`.

---

## 4. Daily loop

```sh
cd ~/roblox/backrooms
devenv up                                   # terminal 1: Rojo
noclip status                               # terminal 2: what is queued
noclip run --jobs 2                         # dispatch
noclip merge 0003-report-boot-state-to-the-client
noclip doctor                               # after anything looks wrong
```

Draining the backlog is safe to interrupt: Ctrl-C leaves each in-flight note in
`active/` with a `## Blocked`/partial log, and the next `noclip run` requeues
anything whose worker is gone via the exit trap.

---

## 5. Handoff invariants

1. **The note is the only handoff.** No agent reads another agent's session; the
   vault is the interface. If it is not in a note, it did not happen.
2. **One note, one outcome.** A note needing two outcomes is two notes.
3. **Acceptance is falsifiable.** "Looks better" is not acceptance. "Panel opens
   on Tab, 3 slots, no console errors" is.
4. **Assets are manifest-first.** No `generate_mesh` before a row exists or a
   `search_asset` came back empty.
5. **Studio ends in `Edit`.** Every studio-lane role stops play mode on the way
   out, including on failure.

---

## 6. Failure handling

| Symptom | Cause | Fix |
|---|---|---|
| Task stuck in `active/` | worker killed mid-run | next `noclip run` requeues it; otherwise `mv` back to `backlog/` |
| `no studio lock after 600s` | another studio task, or stale lock | `noclip doctor`, then remove `.locks/studio` if the pid is dead |
| Agent exits 0 but did nothing | task too vague to act on | rewrite `acceptance`; ambiguity is the bug |
| Merge conflict | two tasks changed the same lines | resolve by hand; do not pick a side blindly |
| `noclip` cannot find the vault | `.noclip` missing or `vault=` wrong | `noclip init` (idempotent) |

---

## 7. Cost posture

- Deterministic work — import, insert, build, publish — is tool calls, not
  inference. It does not touch a model at all.
- Assets are generated in Studio (`generate_mesh`, `generate_scene`,
  `generate_texture`) or sourced CC0. Check `search_asset` first; regeneration is
  the main way this pipeline wastes money.
- Model choice per role lives in `~/dotfiles/agents/*.md` (`model:`). Cheap/free
  models for `librarian`, `qa`, `builder`; escalate only `designer`/`scripter`
  when quality actually matters.

---

## 8. Lore corpus

`60-lore/` in the vault is a transcription of the Backrooms Wiki: 1,722 notes,
one per article, each stamped with `source`, `revid`, `retrieved` and
`license: CC-BY-SA-3.0`.

- **Index first.** `60-lore/_index.md` for humans, `_index.json` for queries. Do
  not load the corpus into a context window.
- **Cite the note.** A task that leans on lore names the path
  (`60-lore/levels/level-0.md`). "I read the wiki" is not a citation.
- **Bodies are read-only.** `lore-ingest sync` refreshes them; only
  `lore-keeper` writes there.
- **`game_hooks` is the bridge.** `designer` fills it per level we actually
  build; a re-render preserves it. `10-design/lore-map.md` decides which levels
  get hooks at all.
- **Licence.** Rendered text is CC-BY-SA. Attribute when quoting outside the
  vault; do not paste article prose into the game or its store page.
