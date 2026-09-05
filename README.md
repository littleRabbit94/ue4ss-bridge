# ue-bridge

Run Lua inside a live [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) game from outside it. Two
parts, released separately:

| Part | What | Where it goes |
|---|---|---|
| **UEBridge** (Lua mod) | Polls `ue4ss\bridge\request.json`, runs the request on the game thread, writes `response.json`. Game-agnostic. | The game: `ue4ss\Mods\UEBridge\` (Nexus / GitHub release zip) |
| **ue-bridge** (Python) | An MCP server and CLI that write those files and read the answers. Finds the running game by itself. | Your machine: `uvx ue-bridge` or `pip install ue-bridge` |

```
AI agent / script  ->  ue-bridge (MCP stdio or HTTP, or CLI)  ->  request.json
                                                                 UEBridge mod: ExecuteInGameThread
                       ue-bridge  <-  response.json           <-
```

No sockets in the game, no admin rights, no changes to the game binary. The mod opens no network
connection and starts no process. Only software already running on the same machine with write
access to the game folder can talk to it.

## Install the mod

Extract the release zip into the game's install folder. It carries the path, so the files land in
`<game>\<Project>\Binaries\Win64\ue4ss\Mods\UEBridge`. `enabled.txt` in that folder starts the
mod; **no `mods.txt` edit**. `UE4SS.log` shows `[UEBridge] v1.0.0 ready` when it loaded.

`scripts\settings.lua` in the mod folder:

| Key | Default | Effect |
|---|---|---|
| `enabled` | `true` | `false` stops polling entirely |
| `poll_ms` | `250` | request file check interval |
| `allow_eval` | `true` | `false` refuses raw Lua (`eval_lua`); structured tools still work |
| `allow_writes` | `true` | `false` is read-only: `set_property`, `call_function`, `console_command` and `eval_lua` are refused |
| `bridge_dir` | unset | absolute path override for the request/response folder |

## Install the server and point an agent at it

Any MCP client works. The server finds the running game (an exe in a `Binaries\Win64` folder with
`ue4ss\` beside it), so no path needs configuring; pass `--game-dir` or set `UE_BRIDGE_GAME_DIR` to
pin one.

**stdio** (Claude Code, Claude Desktop, Cursor, Windsurf, Codex, Continue, ...):

```json
{ "mcpServers": { "ue-bridge": { "command": "uvx", "args": ["ue-bridge"] } } }
```

```bash
claude mcp add ue-bridge -- uvx ue-bridge
```

**HTTP** (one long-running server, several clients): `ue-bridge --http` serves streamable-HTTP MCP
on `http://127.0.0.1:8930/mcp`, loopback only.

```bash
claude mcp add --transport http ue-bridge http://127.0.0.1:8930/mcp
```

**Shell**, for scripts and for testing the channel:

```bash
ue-bridge status
ue-bridge hello
ue-bridge eval "return UEB.world()"
ue-bridge props first:PlayerController
ue-bridge types ^Narrative
```

## Tools

| Tool | Does |
|---|---|
| `bridge_status` | Game found, running, mod answering, mod version and permissions, round-trip time. Call first. |
| `eval_lua(code, timeout)` | Any Lua chunk on the game thread. Whole UE4SS API plus the `UEB` helpers in scope; `print` output captured. |
| `world_info` | World, player controller, pawn, game instance, game mode. |
| `find_object(path)` / `find_objects(class, limit)` | Resolve one reference / list live instances of a class. |
| `list_types(pattern, limit)` | Loaded reflected types matching a Lua pattern. |
| `inspect_object(ref, include_super, pattern)` | Every reflected property with its value. |
| `list_functions(ref)` | Every UFunction on the class chain. |
| `get_property` / `set_property` | One property. `set` returns `{previous, current}`. |
| `call_function(ref, fn, args)` | Call a UFunction with positional args. |
| `console_command(cmd)` | Run a console command. |
| `batch(calls)` | Several of the above in one round trip. |
| `dump(kind)` | UE4SS dumpers: `usmap`, `jmap`, `uht`, `cxx`, `actors`, `objects`, `static_meshes`. |

Every tool except `eval_lua` goes through the structured `batch` op, so they keep working when a
user turns `allow_eval` off.

**Object references**: `/Script/Pkg.Object` (any full path), `first:ShortClassName` (first live
instance), `cdo:/Script/Pkg.Class` (class default object).

**Serialisation**: UObjects become `{"__object": fullname, "address": n}`, `FName`/`FString`/`FText`
become strings, `TArray` becomes a list (first 200), structs are walked through their reflected
type including inherited fields. `SoftObjectProperty` values are skipped by default (reading one
has hard-crashed a game inside UE4SS's own property reader).

## Wire protocol (1)

```
request : {"id": str, "op": "hello"|"ping"|"eval"|"batch", "code": str, "calls": [ {op, ...} ]}
response: {"id", "ok": bool, "result", "output": [str], "error": str|null, "ms": int, "protocol": 1}
```

`hello` returns the mod's version, protocol and permissions; the server refuses to proceed on a
protocol mismatch. Anything that can write a JSON file can be a client.

## Failure modes

- **Request never picked up**: no game running, or the mod is not installed or is disabled.
  Check for `[UEBridge] ... ready` in `UE4SS.log`.
- **Picked up, no response**: the game thread is blocked (loading screen) or the request is long.
  `dump` uses a 600 s timeout for that reason. If the process is gone, the error names the
  in-flight operation from `bridge\lastop.log` and the newest crash report.
- **One request at a time.** A `request.json` younger than 10 s is another client's; older is a
  leftover and is reclaimed.

## Developing

```
uv venv --python 3.11 .venv
uv pip install --python .venv\Scripts\python.exe "mcp>=1.8,<2"
.venv\Scripts\python.exe -m ue_bridge status        # from the repo root
python tools/build-release.py                       # dist/UEBridge-<version>.zip
```

Edit `ue4ss/UEBridge/scripts/main.lua`, then `ue-bridge eval "return UEB.reload()"`: the mod
re-runs its source in place and retires the old poll loop, no relaunch.

MIT.
