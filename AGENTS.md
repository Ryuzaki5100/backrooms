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

| Task | Command |
|---|---|
| Build the place | `rojo build default.project.json -o place/noclip-protocol.rbxlx` |
| Live sync into Studio | `rojo serve` (port 34872, Rojo plugin) |
| Generate LSP sourcemap | `rojo sourcemap default.project.json --output sourcemap.json` |
| Lint | `selene src` |
| Format | `stylua src` (check: `stylua --check src`) |
| Build + lint + format gate | `rojo build ... && selene src && stylua --check src` |

`sourcemap.json`, `globalTypes.d.luau` and `build/` are generated and gitignored.

## Conventions

- Every script starts with `--!strict`; `.luaurc` sets strict mode repo-wide.
- File suffixes decide the instance class: `.server.luau` → Script,
  `.client.luau` → LocalScript, plain `.luau` → ModuleScript.
- Formatting is StyLua with tabs and a 100-column limit. Run `stylua src` before
  committing rather than hand-aligning.
- The game name is not repeated in Luau: read it from `src/shared/NoclipConfig.luau`.

## Committing

- Commit `src/` and `place/` together when a change spans both.
- Keep `build/`, `sourcemap.json` and anything binary (`*.rbxl`) out of history.
- Never commit API keys, cookies or `.env` files.

## Studio bridge

Roblox Studio is driven through its MCP server (registered globally in
`~/.config/opencode/opencode.json`). Verify the target session before editing:

1. `list_roblox_studios` → match the entry by sentinel/place, not by a
   lookalike window name.
2. `get_studio_state` → confirm `Edit` mode.
3. Look for `ServerScriptService.NoclipBoot` in the tree; if it is missing, Rojo
   is not synced and file edits will not reach Studio.
