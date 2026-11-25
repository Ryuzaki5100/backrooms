# AGENTS.md

Operating contract for this repository. Read it before editing anything.

## Identity

`roblox.json` is the single source of truth for names:

- repo: `backrooms` (GitHub)
- game/place name: **Noclip Protocol**
- tracked place file: `place/noclip-protocol.rbxlx`
- sentinel: `ServerScriptService.NoclipBoot`

Never infer the game name from the repository or directory name, and never
rename the repo to match the game. If a place ID is needed, read it from
`roblox.json`; do not hardcode one.

## Files are the source of truth

- Luau lives in `src/` and is mapped into the DataModel by
  `default.project.json` via Rojo.
- Geometry built by hand in Studio belongs to `place/noclip-protocol.rbxlx`,
  which is tracked. Keep scripts out of hand-editing: edit files, then sync.
- A change that exists only in an open Studio session does not exist. Save it to
  the tracked place (or write it as a file) before committing.

## Commands

Everything runs inside the pinned environment. Enter it first:

```sh
devenv shell            # rojo, selene, stylua, luau-lsp, lune, jq + helpers
devenv up               # start the Rojo server (the files -> Studio bridge)
devenv test             # lint + format check + build
```

| Task | Command |
|---|---|
| Open Studio on the tracked place | `studio-open` (add `--cloud` for the published place) |
| Start live sync | `devenv up` (or `rojo serve --port 34872`) |
| Build the project | `build` → `rojo build default.project.json -o build/noclip-protocol.rbxlx` |
| Generate LSP sourcemap | `sourcemap` |
| Lint | `lint` (`selene src`) |
| Format | `fmt` (`stylua src`) |
| Check the bridge is healthy | `preflight` |
| Git state (files vs GitHub) | `status` |
| Pull, optionally commit and push | `sync.sh -m "message"` |
| Publish to the Roblox place | `publish` (needs `ROBLOX_API_KEY`) |

`sourcemap.json`, `globalTypes.d.luau`, `build/` and `.devenv/` are generated and
gitignored. `devenv.lock` IS committed: it pins the toolchain.

A build never writes to `place/`. The tracked place carries Studio-authored
geometry (set-piece templates) that the Rojo project does not describe, so a
project build over it would silently delete that work. Regenerating the place is
a deliberate Studio action (`studio-open`, sync, save), not a build step.

## Conventions

- Every script starts with `--!strict`; `.luaurc` sets strict mode repo-wide.
- File suffixes decide the instance class: `.server.luau` → Script,
  `.client.luau` → LocalScript, plain `.luau` → ModuleScript.
- Formatting is StyLua with tabs and a 100-column limit. Run `stylua src` before
  committing rather than hand-aligning.
- The game name is not repeated in Luau: read it from `src/shared/NoclipConfig.luau`.

## Multi-agent workflow

Work is scheduled from an Obsidian vault at `../noclip-protocol-vault` (path in
`.noclip`). The vault — not this repository — is the queue and the shared memory.
Never edit the queue by hand while `noclip run` is running.

| Role | Owns | Never touches |
|---|---|---|
| `noclip` | deciding and delegating (primary) | code, design, lore, Studio |
| `librarian` | task notes, ADRs | any repo file |
| `designer` | `10-design/`, `00-brief/` | `src/`, Studio |
| `scripter` | `src/`, `default.project.json` | `place/`, Studio |
| `asset-smith` | `20-assets/`, Studio instances | `src/` |
| `audio` | `30-audio/`, `Sound` instances | `src/`, geometry |
| `qa` | verification reports in `50-log/` | any edit |
| `builder` | merges, place file, publish | design decisions |
| `lore-keeper` | `60-lore/` wiki corpus | code, design, `game_hooks` |

Two lanes. `lane: files` tasks run in parallel, each in its own git worktree
under `.noclip-worktrees/` (gitignored) and on its own `noclip/<task>` branch.
`lane: studio` tasks run **one at a time, in this checkout**, because Studio is a
single mutable process and Rojo is bound to this directory.

Agent roles are **project-scoped**: they live in `.opencode/agents/` and are
loaded only while working in this repository (or a worktree of it). `noclip` is
the default primary and delegates; the eight roles stay selectable so a single
one can be driven by hand. `noclip agents check` verifies the committed set still
matches the installed one.

```sh
noclip status                  # queue board + studio lock
noclip new "Title" --agent scripter --lane files
noclip run --once              # dispatch one task
noclip run                     # drain the backlog, `jobs` at a time
noclip merge <task-id>         # integrate a files-lane branch
noclip doctor                  # toolchain, agents, vault, stale locks
```

Rules that keep this safe:

1. A task is claimed by moving its note into `40-tasks/active/`; `mv` is the
   lock. Do not move notes yourself.
2. Only `noclip` marks a task `done` (agent exit 0) or `blocked` (non-zero).
3. Studio work is serialized by `../noclip-protocol-vault/.locks/studio`. A stale lock is
   reported by `noclip doctor`; remove it only when no agent is running.
4. Agents commit inside their worktree branch; `builder` merges. Direct commits
   to `main` from an agent are a bug, not a shortcut.
5. `scripter` never calls `save_place`; `asset-smith` never edits scripts. If a
   task needs both, split it into two notes.
6. Lore is read, not paraphrased. A task that leans on the wiki cites the
   `60-lore/` note it used; only `lore-keeper` writes there.

Full procedure: `docs/AGENTS-WORKFLOW.md`.

## Committing

- Commit `src/` and `place/` together when a change spans both.
- Keep `build/`, `sourcemap.json` and anything binary (`*.rbxl`) out of history.
- Never commit API keys, cookies or `.env` files.

## Studio bridge

Roblox Studio is driven through its MCP server (registered globally in
`~/.config/opencode/opencode.json` and per-project in `.opencode/opencode.json`).

**Full procedure, cold start, and troubleshooting: `docs/RUNBOOK.md`.** Read it
before improvising. Slash commands: `/sync` (reconcile files, Studio, GitHub) and
`/doctor` (diagnose a broken bridge).

Verify the target session before editing:

1. `list_roblox_studios` → match cloud sessions by `placeId`, local sessions by
   the `file` field. Never match by window title alone.
2. `get_studio_state` → confirm `Edit` mode.
3. Look for `ServerScriptService.NoclipBoot` in the tree; if it is missing, Rojo
   is not synced and file edits will not reach Studio.

Hard-won constraints (details in `docs/RUNBOOK.md` §10): Studio only scans the
Plugins folder at startup; never run `rojo serve` and `devenv up` together; launch
Studio once per place; Rojo silently overwrites Studio-side script edits; and
`save_place` only writes to disk for local places.
