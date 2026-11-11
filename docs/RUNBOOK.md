# Noclip Protocol — development runbook

Everything you need to go from "opened my laptop" to "code in Roblox Studio and
on GitHub". Written to be followed literally, and to be read by an AI agent when
you have forgotten the next step.

Identifiers (source of truth is `roblox.json`):

| | |
|---|---|
| Game name | **Noclip Protocol** |
| GitHub repo | `Ryuzaki5100/backrooms` (the repo name is *not* the game name) |
| Place file | `place/noclip-protocol.rbxlx` (tracked) |
| placeId | 90472056249191 |
| universeId | 10775950241 |
| Sentinel | `ServerScriptService.NoclipBoot` |
| Rojo port | 34872 |

---

## 1. TL;DR

```sh
cd ~/roblox/backrooms
devenv up                      # terminal 1: Rojo server (files -> Studio)
devenv shell -- opencode       # terminal 2: agent, with the same pinned tools
studio-open                    # opens the tracked place in Studio
```

Then in Studio: **Plugins → Rojo → Connect**. In the agent: *"verify the bridge"*.
Work in `src/*.luau`, then ask the agent to *"sync"* to commit and push.

---

## 2. Mental model — four surfaces, one authority each

| Surface | What it holds | Who updates it | Authority |
|---|---|---|---|
| `src/**` | all scripts | you edit files | **source of truth** for code |
| `place/*.rbxlx` | geometry, lighting, terrain | Studio save / MCP `save_place` | **source of truth** for the world |
| Studio session | the live DataModel | Rojo (from files) | disposable runtime |
| `origin/main` | history | `git push` | **source of truth** for history |

Two rules follow, and they explain almost every confusing situation:

1. **Scripts are written in files, never in Studio.** While Rojo is connected it
   overwrites Studio-side script edits on the next file change, silently.
2. **Geometry is written in Studio, never in the `.rbxlx` by hand.** A cloud
   place does *not* write to disk on save — only a local place does.

---

## 3. One-time prerequisites

- Roblox Studio installed at `/Applications/RobloxStudio.app`.
- In Studio: **Assistant → `…` → Manage MCP Servers → Enable Studio as MCP server**.
  The green indicator means a client is connected.
- Rojo plugin installed. If missing: `rojo plugin install`, then **quit Studio
  completely** (`Cmd+Q`) and reopen — plugins are only scanned at startup.
- `git ls-remote origin` succeeds (SSH key works).
- `preflight` prints all `ok` and exits 0.

---

## 4. Cold start (a new session, from zero)

1. `cd ~/roblox/backrooms`
2. `preflight` — expect every line `ok`. If something is `MISS`, jump to §9.
3. Terminal 1: `devenv up` — Rojo listening on 34872. Leave it running.
4. Terminal 2: `devenv shell -- opencode` — the agent inherits the pinned tools.
5. `studio-open` — Studio opens **the tracked place**, not the cloud place.
6. In Studio: **Plugins → Rojo → Connect**. Expect `127.0.0.1:34872` connected.
7. In the agent, ask: *"verify the bridge"*. It should:
   - call `list_roblox_studios` and match by placeId (not by name),
   - call `get_studio_state` and confirm `Edit` mode,
   - look for `ServerScriptService.NoclipBoot` in the tree.
8. Optional smoke test: agent runs a playtest and reads the console. Expect
   `[noclip] boot ok - Noclip Protocol v0.1.0`.

If step 6 has no Connect button, see §9.

---

## 5. The daily loop

**Editing code**

1. Edit files under `src/`.
2. Save. Rojo pushes to Studio within a second or two.
3. Check it landed: the agent can `script_read` the mapped path, or just look.
4. Test: agent runs `start_stop_play`, then `get_console_output`, then stops it.
   Screenshots via `screen_capture` when you need to see the viewport.

**Where a file lands** is decided by `default.project.json`:

```json
"ServerScriptService": { "NoclipBoot": { "$path": "src/server/NoclipBoot.server.luau" } }
```

Suffixes pick the class: `.server.luau` → Script, `.client.luau` → LocalScript,
plain `.luau` → ModuleScript. A new file that isn't in `default.project.json`
will **never** appear in Studio — that is the usual cause of "my script is gone".

**Editing the world**

1. Move parts, add rooms, set lighting — in Studio, in Edit mode.
2. Ask the agent: *"sync"* (or *"save the place"*). It calls `save_place`, which
   writes `place/noclip-protocol.rbxlx` on disk.
3. `status` shows the place file modified. Commit it (`sync.sh -m "..."`).

---

## 6. The sync gesture

One request — *"sync"* — should do this, in order:

1. `git pull --ff-only`; halt if local and GitHub have diverged.
2. Compare every mapped script: Studio (`script_read`) vs disk.
   Use `git HEAD` as the last-synced baseline:
   | files | Studio | action |
   |---|---|---|
   | same as HEAD | same as HEAD | nothing |
   | changed | same as HEAD | push files to Studio, commit |
   | same as HEAD | changed | **propose** a file change, wait for approval |
   | changed | changed, different | **halt**, show both diffs |
3. `save_place` to capture geometry into the tracked place file.
4. `status` and report.
5. Commit + push only what was approved.

`sync.sh` handles only the git half (steps 1, 4, 5) — scripts comparison needs
MCP, so it belongs to the agent.

---

## 7. Git

```sh
status                     # branch, working tree, ahead/behind, place file
sync.sh                    # pull only (fast-forward)
sync.sh -m "message"       # pull, commit everything, push
sync.sh -m "message" --no-push
```

Rules the scripts enforce, and you should too:

- **Never** `--force`, never `reset --hard`, never delete a file you did not
  create in this session.
- Diverged history stops everything; resolve by hand.
- Both scripts refuse to commit without a message, so nothing lands accidentally.

---

## 8. Publishing

Not automated yet. Two ways:

- **Studio:** File → Publish to Roblox, choosing the **existing experience**
  (never "Create new"). This overwrites the cloud place with the local build.
- **CLI:** `ROBLOX_API_KEY=... publish` — an Open Cloud key with `place:write`
  is required; `publish` refuses to run on a dirty tree.

Note: publishing a *local* place replaces the cloud version, including the
template's inherited cloud script and stray assets — which is why the console
noise recorded in §10 disappears after the first publish.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No Rojo button in Plugins tab | Studio was running when the plugin was installed (plugins load only at startup) | Quit Studio fully (`Cmd+Q`), reopen |
| Rojo button exists, no Connect | Panel closed | Plugins tab → Rojo → Connect |
| Connect fails, "address in use" | a stale `rojo serve` | `lsof -nP -iTCP:34872` then kill it, or `devenv down` |
| Extra Studio entry with "Place is not open" | the place was launched twice | ignore it, or quit that window; launch once (§10.4) |
| Studio not listed by the agent | MCP toggle off, or no place open | Enable in Assistant settings; open a place |
| Agent edited the wrong window | two Studio instances open | always match `placeId`, then the sentinel; never match by name |
| Script edits don't appear | file not mapped in `default.project.json`, or wrong session | add the mapping; `script_read` to confirm the target |
| Studio-side script edit vanished | Rojo overwrote it (expected) | edit files instead; Stage 3 rules refuse to guess |
| `game`/`Instance` unknown in the LSP | missing `globalTypes.d.luau` | `sourcemap`, then add definitions (see §11) |
| `wally` unavailable | nixpkgs marks it badPlatforms on Apple Silicon | pin wally's prebuilt release in `devenv.nix` if a package is ever needed |
| `git` says diverged | local and remote both moved | stop; merge manually; never force |
| `publish` says dirty tree | uncommitted changes | commit first |

---

## 10. Studio-side console noise (not this project)

Every playtest — including one in a clean place built from this repo — prints:

```
cloud_3104443226.S^X | v1.4.1b:26: attempt to index nil with 'WaitForChild'
ContentId: rbxassetid://203785492 failed due to: Asset type does not match requested type
```

Confirmed not to come from this repository:

- a DataModel-wide scan for `203785492` returns **zero** matches;
- `search_game_tree` shows only `NoclipBoot`, `NoclipClient`, `NoclipConfig`;
- the Rojo plugin binary contains neither identifier;
- the same two errors appear in the template **cloud** place and in the clean
  **local** place built from `place/noclip-protocol.rbxlx`.

They are Studio/engine-level (an injected cloud script plus an asset type
mismatch). Reported to Roblox with `submit_feedback`. Ignore them; they are not
a signal about your code. If they ever disappear after a Studio update, nothing
in the repo needs changing.

### Lessons learned the hard way

1. **Studio scans plugins only at startup.** Installing the Rojo plugin while
   Studio is running does nothing visible — no button, no error. Quit with
   `Cmd+Q` and reopen. (Detected by comparing process start time with the
   plugin file's mtime.)
2. **`enterTest` is inert in devenv 2.4.** Declaring the option leaves
   `devenv:enterTest` with "no command" and `devenv test` passes without running
   anything. It must be `tasks."devenv:enterTest".exec`. Verify with
   `devenv tasks list`.
3. **Never run `rojo serve` and `devenv up` together.** The second fails with
   "address already in use"; the port belongs to one process only. Use
   `devenv up`, and `devenv down` to stop it.
4. **`open -a RobloxStudio <file>` does not load the place.** It starts a
   protocol-handler process that reports `mode: Unavailable`,
   `"Place is not open"` — even with no other Studio running. Use
   `studio-open`, which runs the binary directly with
   `--task EditFile --localPlaceFile` and detaches with `nohup`. Launch exactly
   one instance per place, and ignore `Unavailable` entries in
   `list_roblox_studios`.
5. **Rojo silently overwrites Studio-side script edits.** There is no conflict
   detection. That is why scripts are edited in files and why the sync gesture
   compares before writing. Geometry is the opposite direction and is safe.
6. **`save_place` writes to disk only for local places.** On a cloud place it
   creates a cloud version that git never sees. This is the reason the tracked
   local place is canonical.
7. **`wally` is `badPlatforms` on aarch64-darwin** in nixpkgs. It is deliberately
   absent; pin its prebuilt release per-project if a package is ever needed.
8. **`devenv test` does not prove your test ran** unless the task has a command —
   see (2). Check `devenv tasks list` when a green result looks suspicious.
9. **A local place has no `placeId`.** `list_roblox_studios` returns a `file`
   field instead. Match cloud sessions by `placeId`, local sessions by file name;
   never by the window title alone.
10. **Nix flakes ignore untracked files.** A new module or script is invisible to
    `home-manager switch` until `git add -N` (or a commit). The error is
    "Path … is not tracked by Git", not the module being wrong.



---

## 11. If you are an AI agent reading this

Order of operations when the user says *"sync"*, *"is it connected"*, or *"I'm stuck"*:

1. `list_roblox_studios` — if empty: Studio is closed, the place is not loaded,
   or "Enable Studio as MCP server" is off. Report which, do not guess.
2. Match the instance: cloud sessions by the `placeId` from `roblox.json`, local
   sessions by the `file` field (a local place has no placeId). Use the Studio
   name only to disambiguate two windows, never as proof. An entry with
   `mode: Unavailable` / "Place is not open" is a stray window — ignore it.
3. `get_studio_state` — must be `Edit`. If play mode is running, stop it before
   touching scripts.
4. Check the sentinel: `search_game_tree` for `ServerScriptService` and confirm
   `NoclipBoot` exists. Absent means Rojo is not connected; a file edit will not
   reach Studio, so say so instead of editing.
5. Compare each mapped script: `script_read` vs disk, using `git HEAD` as the
   baseline (§6 table). On any two-sided divergence: **stop and show both diffs**.
6. `save_place` only when scripts are settled — it captures geometry into the
   tracked place file.
7. `status`, then commit/push only what the user approved.

Hard rules: never force-push, never `reset --hard`, never delete files you did
not create, never edit scripts inside Studio (Rojo will overwrite them), and
never claim a sync succeeded without reading it back with `script_read`.

Useful MCP tools: `list_roblox_studios`, `get_studio_state`, `search_game_tree`,
`inspect_instance`, `script_read`, `script_grep`, `multi_edit` (prefer file
edits), `execute_luau`, `start_stop_play`, `get_console_output`,
`screen_capture`, `save_place`, `open_cloud_invoke`.

---

## 12. Reference

```sh
devenv shell              # enter the pinned env
devenv up / devenv down   # start/stop the Rojo process
devenv test               # selene + stylua --check + rojo build
preflight                 # health of tools, plugin, repo, remote
studio-open [--cloud]     # open the tracked place, or the published one
status                    # git-side state
sync.sh -m "msg"          # pull, commit, push
publish                   # rojo upload (needs ROBLOX_API_KEY)
lint / fmt / build / sourcemap   # devenv script wrappers
```

Paths: `src/{server,client,shared}`, `place/`, `scripts/`, `.opencode/`.
Generated and ignored: `build/`, `sourcemap.json`, `globalTypes.d.luau`, `.devenv/`.
Committed and pinned: `devenv.nix`, `devenv.yaml`, `devenv.lock`.

Sources: `roblox.json` (identity), `default.project.json` (mapping), `AGENTS.md`
(agent contract), this file (procedure).
