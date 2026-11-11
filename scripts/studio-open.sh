#!/bin/sh
# Open the canonical place in Roblox Studio.
#
#   studio-open            tracked local place (default: geometry lives here)
#   studio-open --cloud    the published place (needs placeId/universeId)
#
# Local is the default because MCP `save_place` only writes to disk for local
# places; a cloud place saves a cloud version, which git never sees.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

mode=local
case "${1:-}" in
	""|--local) mode=local ;;
	--cloud) mode=cloud ;;
	-h|--help)
		echo "usage: studio-open [--local|--cloud]"
		exit 0
		;;
	*)
		echo "studio-open: unknown argument $1" >&2
		exit 2
		;;
esac

place_file=${ROBLOX_PLACE_FILE:-$(jq -r .placeFile roblox.json)}
place_id=${ROBLOX_PLACE_ID:-$(jq -r '.game.placeId // empty' roblox.json)}
universe_id=${ROBLOX_UNIVERSE_ID:-$(jq -r '.game.universeId // empty' roblox.json)}

if [ "$(uname -s)" != Darwin ]; then
	echo "studio-open: only macOS is wired up so far" >&2
	exit 1
fi

if [ "$mode" = cloud ]; then
	[ -n "$place_id" ] || { echo "studio-open: no game.placeId in roblox.json" >&2; exit 1; }
	[ -n "$universe_id" ] || { echo "studio-open: no game.universeId in roblox.json" >&2; exit 1; }
	exec open -a RobloxStudio --args --task EditPlace \
		--placeId "$place_id" --universeId "$universe_id"
fi

[ -f "$place_file" ] || {
	echo "studio-open: $place_file is missing; run 'rojo build default.project.json -o $place_file'" >&2
	exit 1
}
exec open -a RobloxStudio --args --task EditFile --localPlaceFile "$ROOT/$place_file"
