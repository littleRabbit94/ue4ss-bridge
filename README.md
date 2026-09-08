# ue-bridge

[![PyPI version](https://img.shields.io/pypi/v/ue-bridge.svg)](https://pypi.org/project/ue-bridge/)
[![PyPI Downloads](https://img.shields.io/pypi/dm/ue-bridge.svg)](https://pypistats.org/packages/ue-bridge)
[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Live engine inspection and an MCP bridge for [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) games.**
Inspect objects, invoke functions, run Lua, and connect AI coding agents (Claude Code, Claude
Desktop, Cursor, Codex, any MCP client) to the running game, without restarting it.

> **Developer tool, not a gameplay mod.** The mod changes nothing on its own and adds no gameplay
> content. It is a communication bridge for mod authors, reverse engineers and developers who want
> external scripts or AI coding agents to interact with the live engine while it runs.

Two parts, released separately:

| Part | What | Where it goes |
|---|---|---|
| **UEBridge** (Lua mod) | Polls `ue4ss\bridge\request.json`, runs the request on the game thread, writes `response.json`. Game-agnostic. | The game: `ue4ss\Mods\UEBridge\` ([GitHub release](https://github.com/littleRabbit94/ue-bridge/releases), [Dawnwalker Nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/198), [Laughless Saint Nexus](https://www.nexusmods.com/thelanternofthelaughlesssaint/mods/5)) |
| **ue-bridge** (Python) | An MCP server and CLI that write those files and read the answers. Finds the running game by itself. | Your machine: `uvx ue-bridge` or `pip install ue-bridge` |

## What it does

Instead of relaunching the game every time you test an offset, check an object reference or tweak
a variable, UEBridge runs your queries live on the engine's game thread:

- **AI coding agents (MCP).** Connect Claude Code, Claude Desktop, Cursor, Codex or any Model
  Context Protocol client directly to the running game.
- **Live object inspection.** Find live instances of a `UClass`, read every reflected property and
  its current value, list the `UFunction`s on the class chain.
- **Runtime manipulation.** Set properties, call `UFunction`s with arguments, evaluate raw Lua.
- **Snapshot and diff.** Keep a property walk under a label, play, then ask what changed.
- **Engine commands and dumps.** Run console commands or trigger the UE4SS dumpers (`usmap`,
  `jmap`, `uht`, `cxx`, `actors`, `objects`, `static_meshes`) programmatically.

## How it works and the security model

```
AI agent / script  ->  ue-bridge (MCP stdio or HTTP, or CLI)  ->  request.json
                                                                 UEBridge mod: ExecuteInGameThread
                       ue-bridge  <-  response.json           <-
```

A minimal file-based IPC protocol:

1. Every 50 ms the in-game Lua loop checks for `request.json` in `ue4ss\bridge\`.
2. When one appears, the request runs on the game thread via `ExecuteInGameThread`.
3. The result is written to `response.json`.

**Security and privacy**

- No open network sockets or ports.
- No background daemon or subprocess execution.
- No downloads, no telemetry, no changes to the game binary, no admin rights.
- Only software already running on your PC with write access to the game folder can talk to it.

**Compatibility.** Game-agnostic: any Unreal Engine title running UE4SS. UEBridge registers no
native C++ hooks; its Lua runs entirely through engine-thread execution, so it is unaffected by
the hook settings of your UE4SS build. Verified on:

- *The Lantern of the Laughless Saint* (Steam build, UE 5.8, project `The_Holy_Fool`)
- *The Blood of Dawnwalker* (Steam build, UE 5.5.4)

## Requirements

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) installed for your game.
- Python 3.10+ (only for the CLI or MCP server; `uvx` handles it for you).

## Install the mod

**1. Extract.** Extract the release zip into the folder that holds the `ue4ss` folder and the
game executable:

```
<game>\<Project>\Binaries\Win64\
```

The archive carries the folder path, so the files land in `ue4ss\Mods\UEBridge\` on their own.
**No `mods.txt` edit**: the included `enabled.txt` turns the mod on.

**2. Verify.** Launch the game and check `ue4ss\UE4SS.log` for:

```
[UEBridge] v1.1.0 ready
```

**3. Uninstall.** Delete `ue4ss\Mods\UEBridge\` and, if present, `ue4ss\bridge\`.

### Configuration (`scripts\settings.lua`)

That copy always wins. A `settings.lua` at the mod root (where 1.0.0 put it) is read only when
`scripts\` has none, and the mod logs one line naming it as ignored when both exist, so delete
the root file after an in-place upgrade. Edit, save, then `ue-bridge reload` (or the `reload_mod`
tool), or restart the game.

| Key | Default | Effect |
|---|---|---|
| `enabled` | `true` | `false` disables the bridge without uninstalling; nothing is polled |
| `allow_writes` | `true` | `false` is strict read-only: `set_property`, `call_function`, `console_command` and `eval_lua` are refused |
| `allow_eval` | `true` | `false` refuses raw Lua (`eval_lua`); the structured inspection tools keep working |
| `poll_ms` | `50` | request file check interval in milliseconds (50 is the floor; lower values are clamped) |
| `bridge_dir` | unset | absolute path override for the request/response folder |

## Connect a tool or an AI agent (the MCP server)

The program that writes and reads the IPC files is **ue-bridge**, a small Python package. It
finds any running UE4SS game on its own (an exe in a `Binaries\Win64` folder with `ue4ss\` beside
it), so there are no paths to configure. Pass `--game-dir` or set `UE_BRIDGE_GAME_DIR` to pin one.

**Install**

```bash
uvx ue-bridge
```

or with pip:

```bash
pip install ue-bridge
```

**Quick check.** With the game up and the mod loaded:

```bash
uvx ue-bridge status
```

```
game: The_Holy_Fool | process: The_Holy_Fool-Win64-Shipping.exe | running: True | bridge dir: C:\...\Binaries\Win64\ue4ss\bridge
```

`uvx ue-bridge hello` returns the mod's version, protocol and permissions.

### Claude Code

```bash
claude mcp add ue-bridge -- uvx ue-bridge
```

### Claude Desktop

Add this to `claude_desktop_config.json` (`%APPDATA%\Claude\` on Windows,
`~/Library/Application Support/Claude/` on macOS):

```json
{
  "mcpServers": {
    "ue-bridge": {
      "command": "uvx",
      "args": ["ue-bridge"]
    }
  }
}
```

### Cursor and other MCP clients

Pass `uvx ue-bridge` (or, with pip, `ue-bridge` / `python -m ue_bridge`) as the MCP server
command. Cursor reads `.cursor/mcp.json` in the project root, or Cursor Settings > Features > MCP;
Windsurf, Continue, VS Code and Codex each take the same JSON block in their MCP settings file.

### HTTP (one long-running server, several clients)

`ue-bridge --http` serves streamable-HTTP MCP on `http://127.0.0.1:8930/mcp`, loopback only
(`--port` changes the port):

```bash
claude mcp add --transport http ue-bridge http://127.0.0.1:8930/mcp
```

### Shell, for scripts and for testing the channel

```bash
ue-bridge status
ue-bridge hello
ue-bridge eval "return UEB.world()"
ue-bridge props first:PlayerController
ue-bridge types ^Narrative
ue-bridge snapshot first:PlayerController before --super   # --super: include inherited properties (props too)
ue-bridge diff before                       # or: diff <ref> <label> for another object
```

### Example prompts

Once an agent is connected, ask it about the running game in plain language:

- "Inspect the player pawn and list every health, stamina and combat property."
- "Which enemy characters are spawned in the world right now?"
- "What UFunctions on the player controller relate to movement, interaction or camera?"
- "Snapshot the player controller, then tell me what changed after I open the map."
- "Set the player's walk speed to 1200."
- "Trigger a USMAP dump so I can open the cooked assets in FModel."

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
| `snapshot_object(ref, label, include_super, pattern)` | Keep an `inspect_object` walk in the game under a label. Read-only. |
| `diff_object(label, ref, update)` | Re-walk and report `{changed, added, removed, same}` against that snapshot, by dotted property path. `ref` defaults to the snapshot's own reference. At most 500 rows per list, with a `truncated` count when that bites. Read-only. |
| `list_snapshots()` | Labels held, with object path, wall-clock `taken` timestamp (whole seconds since the epoch) and property count. Read-only. |
| `forget_snapshot(label)` | Drop one snapshot, or all with `"*"`. Read-only. |
| `reload_mod()` | Re-read `settings.lua` and re-run the mod in place, no game restart. Read-only, so it is the way back after `allow_eval` was turned off. |
| `batch(calls)` | Several of the above in one round trip. |
| `dump(kind)` | UE4SS dumpers: `usmap`, `jmap`, `uht`, `cxx`, `actors`, `objects`, `static_meshes`. |

Every tool except `eval_lua` goes through the structured `batch` op, so they keep working when a
user turns `allow_eval` off.

**Object references**: `/Script/Pkg.Object` (any full path), `first:ShortClassName` (first live
instance), `cdo:/Script/Pkg.Class` (class default object). `first:` returns whichever instance
UE4SS finds first, which can be a template, a cutscene copy or a pooled actor rather than the live
one; for the player pawn or controller prefer the exact path reported by `world_info`.

**Serialisation**: UObjects become `{"__object": fullname, "address": n}`, `FName`/`FString`/`FText`
become strings, `TArray` becomes a list (first 200), structs are walked through their reflected
type including inherited fields. `SoftObjectProperty` and `SoftClassProperty` values are skipped
by default (reading one has hard-crashed a game inside UE4SS's own property reader).

**Snapshots** live in the game process, keyed by label rather than by object address. They
survive `UEB.reload()` and are lost when the game exits. A diff ignores object and struct
addresses and uses the same depth and array caps as the original walk, so an unchanged object
diffs empty.

## Wire protocol (2)

```
request : {"id": str, "op": "hello"|"ping"|"eval"|"batch", "code": str, "calls": [ {op, ...} ]}
response: {"id", "ok": bool, "result", "output": [str], "error": str|null, "ms": int, "protocol": 2}
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

```bash
uv venv --python 3.11 .venv
uv pip install --python .venv\Scripts\python.exe "mcp>=1.8,<2"
.venv\Scripts\python.exe -m ue_bridge status        # from the repo root
python tools/build-release.py                       # dist/UEBridge-<version>.zip
```

Edit `ue4ss/UEBridge/scripts/main.lua`, then `ue-bridge reload`: the mod
re-runs its source in place and retires the old poll loop, no relaunch.

## Credits and license

- MIT. See [LICENSE](LICENSE).
- Built on [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) by the UE4SS-RE team (MIT).
- Written with the assistance of an AI coding agent.
