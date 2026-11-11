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
committed. See `AGENTS.md` for the full operating contract.
