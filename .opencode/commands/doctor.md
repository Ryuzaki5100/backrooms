---
description: Diagnose why the Roblox Studio bridge is not working
---
Follow `docs/RUNBOOK.md` §9 and §11. Diagnose, do not blindly fix: report the
first broken link and the exact command that repairs it.

1. `preflight` — report every `MISS` line verbatim.
2. `list_roblox_studios`:
   - empty → Studio is closed, no place is loaded, or "Enable Studio as MCP
     server" is off (Assistant → … → Manage MCP Servers). Say which.
   - more than one → match by `placeId` from `roblox.json`; never by name.
3. `get_studio_state` — confirm `Edit` mode, and whether play mode is running.
4. Check the sentinel `ServerScriptService.NoclipBoot` via `search_game_tree`.
   Missing means Rojo is not connected: check `lsof -nP -iTCP:34872` and whether
   `devenv up` is running.
5. Check the plugin file `~/Documents/Roblox/Plugins/RojoManagedPlugin.rbxm` and
   whether Studio was started after it was written (plugins load only at startup).
6. Run `status` for the git side; report diverged history instead of resolving it.

End with: the diagnosis, the single next action for the user, and what to expect
when it works (e.g. "Plugins → Rojo → Connect shows 127.0.0.1:34872").

Extra context from the user: $ARGUMENTS
