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
devenv build                     # scratch build into build/; never the tracked place
selene src                       # lint
stylua src                       # format
```

Luau edits go in `src/`; geometry goes in the tracked place file. Both are
committed. `build` writes under `build/` only: the place carries Studio-authored
geometry that a project build cannot reproduce. See `docs/RUNBOOK.md` for the step-by-step procedure (cold start,
daily loop, git, publishing, troubleshooting) and `AGENTS.md` for the agent
contract.

## Multi-agent work

Work is planned by the prodev orchestrator in `.prodev-vault` (this repo). See
AGENTS.md "Multi-agent workflow".
