{ pkgs, ... }:
let
  identity = builtins.fromJSON (builtins.readFile ./roblox.json);
  game = identity.game;
  placeId = if game.placeId == null then "" else toString game.placeId;
  universeId = if game.universeId == null then "" else toString game.universeId;
  # Builds are emitted under build/, never over the tracked place: the place
  # carries Studio-authored geometry that the Rojo project cannot reproduce.
  placeName = builtins.baseNameOf identity.placeFile;
in {
  # Pinned Luau toolchain. Roblox Studio itself is not packaged: it installs and
  # updates from Roblox's own installer, and its MCP server ships inside the
  # .app. Everything on our side is pinned here.
  packages = with pkgs; [
    rojo
    selene
    stylua
    luau-lsp
    luau
    lune
    git
    jq
    curl
  ];

  # Project identity is read from roblox.json so it is stated exactly once.
  env = {
    ROBLOX_PLACE_FILE = identity.placeFile;
    ROBLOX_PLACE_NAME = game.name;
    ROBLOX_PLACE_ID = placeId;
    ROBLOX_UNIVERSE_ID = universeId;
    ROBLOX_SENTINEL = identity.sentinel;
  };

  # `devenv up` starts the filesystem -> Studio bridge.
  processes.rojo.exec = "rojo serve --port 34872";

  scripts = {
    # Same name the global nix profile provides, so .opencode/opencode.json and
    # .mcp.json work identically with or without this shell.
    roblox-studio-mcp.exec = ''exec "$DEVENV_ROOT/scripts/studio-mcp.sh"'';
    studio-open.exec = ''exec "$DEVENV_ROOT/scripts/studio-open.sh" "$@"'';
    status.exec = ''exec "$DEVENV_ROOT/scripts/status.sh" "$@"'';
    sync.exec = ''exec "$DEVENV_ROOT/scripts/sync.sh" "$@"'';
    preflight.exec = ''exec "$DEVENV_ROOT/scripts/preflight.sh" "$@"'';
    publish.exec = ''exec "$DEVENV_ROOT/scripts/publish.sh" "$@"'';
    lint.exec = "selene src";
    fmt.exec = "stylua src";
    # A project build cannot recreate Studio-authored geometry (the set-piece
    # templates live only in the place), so writing a build over the tracked
    # place would delete work. Regenerating the place is a deliberate Studio
    # action; `build` stays a scratch build, as in CI.
    build.exec = "mkdir -p build && rojo build default.project.json -o build/${placeName}";
    sourcemap.exec = "rojo sourcemap default.project.json --output sourcemap.json";
    progentest.exec = "lune run tests/run.luau";
    configcheck.exec = "lune run scripts/gen-config.luau --check";
  };

  # devenv 2.x exposes "test" as a task; assigning the legacy enterTest option
  # leaves devenv:enterTest with no command.
  tasks."devenv:enterTest".exec = ''
    mkdir -p build
    selene src
    stylua --check src
    lune run scripts/gen-config.luau --check
    lune run tests/run.luau
    rojo build default.project.json -o build/test.rbxlx
  '';

  enterShell = ''
    echo "Noclip Protocol — ${if placeId == "" then "local place" else "place ${placeId}"}"
    echo "  rojo serve is started by 'devenv up'; studio-open opens the tracked place."
  '';
}
