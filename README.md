# hf-bridge

An MCP server that runs Lua inside the live game through UE4SS, so a question about runtime state
costs one tool call instead of one relaunch.

```
MCP server (this)  ->  writes  <ue4ss>\bridge\request.json
HFBridge Lua mod   ->  polls every 250 ms, runs the code on the game thread, writes response.json
MCP server         ->  reads response.json, deletes it
```

No sockets, no admin rights, no changes to the game binary. The Lua side is
[`ue4ss/HFBridge`](../../ue4ss/HFBridge/scripts/main.lua); install it like any other mod in
`ue4ss/README.md`.

## Registration

`.mcp.json` at the toolkit root registers the server as `hf-bridge` (stdio, `python server.py`).
Claude Code picks it up when the toolkit is the working directory. Requires the `mcp` Python
package (1.26 is installed).

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
python tools/hf-bridge/server.py ping
python tools/hf-bridge/server.py world
python tools/hf-bridge/server.py eval "return HFB.props('cdo:/Script/The_Holy_Fool.HFCharacter')"
python tools/hf-bridge/server.py props first:PlayerController
python tools/hf-bridge/server.py types ^Narrative
```

`HF_BRIDGE_DIR` overrides the bridge directory (default `<game>\...\Win64\ue4ss\bridge`).

## Editing the mod

Copy the changed `main.lua` into the game's `Mods\HFBridge\scripts\` folder, then run
`python tools/hf-bridge/server.py eval "return HFB.reload()"`. The mod reloads in place; no relaunch.

## Failure modes

- **Request never picked up**: the game is not running, or `HFBridge` is not enabled in
  `mods.txt`. `UE4SS.log` shows `[HFBridge] ready` when the mod loaded.
- **Picked up, no response**: the game thread is blocked (loading screen, breakpoint) or the
  snippet is long. `dump` calls use a 600 s timeout for that reason.
- **One request at a time.** The mod ignores the request file while a previous eval is still on
  the game thread; the server never has two in flight.
