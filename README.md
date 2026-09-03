# hf-bridge

An MCP server that runs Lua inside the live game (The Lantern of the Laughless Saint) through
UE4SS, so a question about runtime state costs one tool call instead of one relaunch.

```
MCP server (server.py)  ->  writes  <ue4ss>\bridge\request.json
HFBridge Lua mod        ->  polls every 250 ms, runs the code on the game thread, writes response.json
MCP server              ->  reads response.json, deletes it
```

No sockets, no admin rights, no changes to the game binary. The Lua side is
[`ue4ss/HFBridge`](ue4ss/HFBridge/scripts/main.lua) in this repo; it is deployed into the game by
modman (the `modman` repo lists `hf-bridge/ue4ss` as a store root and the default profile
enables the mod `hf-bridge`). Deployed Lua files are hardlinks to the ones here, so an edit to
`main.lua` is live after `HFB.reload()`.

This repo was split out of `private-toolkit` on 2026-09-03 with its history. The knowledgebase
that explains the bridge ("The live bridge" in `docs/ue4ss.md`) stays in the toolkit at
`private-toolkit`.

## Registration

The private-toolkit Claude Code plugin registers the server as `hf-bridge`
(`plugin/.mcp.json` in the toolkit, launched through `plugin/mcp/run.sh` on this repo's venv).
Because it is plugin-provided, the tools are named
`mcp__hf-bridge__<tool>`, for example
`mcp__hf-bridge__eval_lua`.

The venv is `.venv` here (Python 3.11, `mcp<2` because the server uses the 1.x `FastMCP` name,
plus pywin32). Recreate it with:

```
uv venv --python 3.11 .venv
uv pip install --python .venv\Scripts\python.exe "mcp<2" pywin32
```

## Tools

| Tool | Does |
|---|---|
| `bridge_status` | Is the game process up, is the mod answering, round-trip time. Call first. |
| `eval_lua(code, timeout)` | Run any Lua chunk on the game thread. Returns the chunk's return value plus captured `print` output. The whole UE4SS API and the `HFB` helpers are in scope. |
| `world_info` | Current world, player controller, pawn, game instance, game mode. |
| `find_object(path)` | Resolve a reference and report class and address. |
| `find_objects(class, limit)` | Live instances of a short class name (`FindAllOf`). |
| `list_types(pattern, limit)` | Loaded reflected types matching a Lua pattern (walks GUObjectArray, ~400 ms). |
| `inspect_object(ref)` | Every reflected property with its current value, across the class chain. |
| `list_functions(ref)` | Every UFunction on the object's class chain, with flags. |
| `get_property(ref, name)` / `set_property(ref, name, value)` | One property. Writes change live state. |
| `call_function(ref, fn, args)` | Call a UFunction with positional args. |
| `console_command(cmd)` | Execute a console command. No output capture; engine logging is compiled out. |
| `dump(kind)` | Trigger a UE4SS dumper: `usmap`, `jmap`, `uht`, `cxx`, `actors`, `objects`, `static_meshes`. |

**Object references** accepted by every `ref` parameter:

- `/Script/Pkg.Object` or any full path: `StaticFindObject`
- `first:ShortClassName`: first live instance
- `cdo:/Script/Pkg.Class`: the class default object

**Serialisation** of returned values: UObjects become `{"__object": fullname, "address": n}`,
`FName`/`FString`/`FText` become strings, `TArray` becomes a list (first 200), structs report a
fixed set of common field names (`X Y Z`, `Pitch Yaw Roll`, `AssetPath`, `TagName`, ...) because
the UE4SS struct wrapper does not expose its own type. For anything deeper, write the walk in
`eval_lua`.

## Shell use

The same file doubles as a CLI, which is the fastest way to test the channel:

```bash
PY=.venv/Scripts/python.exe
$PY server.py ping
$PY server.py world
$PY server.py eval "return HFB.props('cdo:/Script/The_Holy_Fool.HFCharacter')"
$PY server.py props first:PlayerController
$PY server.py types ^Narrative
```

`HF_BRIDGE_DIR` overrides the bridge directory (default `<game>\...\Win64\ue4ss\bridge`).

## Editing the mod

Edit `ue4ss/HFBridge/scripts/main.lua` here (the deployed copy is a hardlink to it), then run
`server.py eval "return HFB.reload()"`. The mod reloads in place; no relaunch. If the deployed
file is not a hardlink (status shows drift), run `modman deploy` from the `modman` repo.

## Failure modes

- **Request never picked up**: the game is not running, or `HFBridge` is not enabled in
  `mods.txt`. `UE4SS.log` shows `[HFBridge] ready` when the mod loaded.
- **Picked up, no response**: the game thread is blocked (loading screen, breakpoint) or the
  snippet is long. `dump` calls use a 600 s timeout for that reason.
- **One request at a time.** The mod ignores the request file while a previous eval is still on
  the game thread; the server never has two in flight.
