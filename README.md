# Noclip Protocol

A Roblox game. The GitHub repository is called `backrooms`; the game itself is
**Noclip Protocol**. `roblox.json` is the source of truth for both.

## Layout

```
roblox.json              identity: game name, place file, sentinel
default.project.json     Rojo mapping from src/ into the DataModel
src/server/              ServerScriptService
src/client/              StarterPlayerScripts
src/shared/              ReplicatedStorage
place/                   tracked XML place file
```

## Develop

```sh
rojo serve                       # sync src/ into an open Studio session
rojo build default.project.json -o place/noclip-protocol.rbxlx
selene src                       # lint
stylua src                       # format
```

Luau edits go in `src/`; geometry goes in the tracked place file. Both are
committed. See `docs/RUNBOOK.md` for the step-by-step procedure (cold start,
daily loop, git, publishing, troubleshooting) and `AGENTS.md` for the agent
contract.

## Multi-agent work

Work is scheduled from the Obsidian vault at `../noclip-vault`, not from a chat
window:

```sh
noclip status      # the queue
noclip run         # dispatch every queued task to its role
noclip merge <id>  # integrate a files-lane branch
```

Seven roles (`librarian`, `designer`, `scripter`, `asset-smith`, `audio`, `qa`,
`builder`) share the vault as memory; `files`-lane tasks run in parallel git
worktrees, `studio`-lane tasks run one at a time. Details:
`docs/AGENTS-WORKFLOW.md`.
