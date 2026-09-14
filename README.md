# ue4ss-bridge

[![PyPI version](https://img.shields.io/pypi/v/ue4ss-bridge.svg)](https://pypi.org/project/ue4ss-bridge/)
[![PyPI Downloads](https://static.pepy.tech/badge/ue4ss-bridge/month)](https://pepy.tech/projects/ue4ss-bridge)
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
| **UEBridge** (Lua mod) | Polls `ue4ss\bridge\request.json`, runs the request on the game thread, writes `response.json`. Game-agnostic. | The game: `ue4ss\Mods\UEBridge\` ([GitHub release](https://github.com/littleRabbit94/ue4ss-bridge/releases), [Dawnwalker Nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/198), [Laughless Saint Nexus](https://www.nexusmods.com/thelanternofthelaughlesssaint/mods/5)) |
| **ue4ss-bridge** (Python) | An MCP server and CLI that write those files and read the answers. Finds the running game by itself. | Your machine: `uvx ue4ss-bridge` or `pip install ue4ss-bridge` |

## What it does

Instead of relaunching the game every time you test an offset, check an object reference or tweak
a variable, UEBridge runs your queries live on the engine's game thread:

- **AI coding agents (MCP).** Connect Claude Code, Claude Desktop, Cursor, Codex or any Model
  Context Protocol client directly to the running game.
- **Live object inspection.** Find live instances of a `UClass`, read every reflected property and
  its current value, list the `UFunction`s on the class chain.
- **Runtime manipulation.** Set properties, call `UFunction`s with arguments, evaluate raw Lua.
- **Snapshot and diff.** Keep a property walk under a label, play, then ask what changed.
- **Event streams.** Watch properties on a timer or hook a `UFunction`, play, then poll the events
  that piled up while you did.
- **Class hierarchy and aim.** List every loaded subclass of a base class; line-trace from the
  camera to find out what the player is looking at.
- **Engine commands and dumps.** Run console commands or trigger the UE4SS dumpers (`usmap`,
  `jmap`, `uht`, `cxx`, `actors`, `objects`, `static_meshes`) programmatically.

## How it works and the security model

```
AI agent / script  ->  ue4ss-bridge (MCP stdio or HTTP, or CLI)  ->  request.json
                                                                     UEBridge mod: ExecuteInGameThread
                       ue4ss-bridge  <-  response.json            <-
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
hooks of its own; its Lua runs entirely through engine-thread execution, so it is unaffected by
the hook settings of your UE4SS build. `hook_function` registers a UE4SS hook only for the
function you name, and only while you ask for it. Verified on:

- *The Lantern of the Laughless Saint* (Steam build, UE 5.8, project `The_Holy_Fool`)
- *The Blood of Dawnwalker* (Steam build, UE 5.5.4)

## Renamed from ue-bridge

**Why.** The old name collided with [grapeot/ue-bridge](https://github.com/grapeot/ue-bridge), an
Unreal *Editor* TCP bridge, and the new name says what the tool needs: UE4SS.

**What changed.** The PyPI package is `ue4ss-bridge`, the Python module is `ue4ss_bridge`, and the
command is `ue4ss-bridge`. Environment variables are `UE4SS_BRIDGE_GAME_DIR` and
`UE4SS_BRIDGE_DATA_DIR`.

**What did not.** The mod folder is still `ue4ss\Mods\UEBridge\`, `settings.lua` keeps its keys and
its place, the `UEB` helper table keeps its name, the log prefix is still `[UEBridge]`, and the
request/response file layout is unchanged.

**Nothing to update.** `ue-bridge` is still installed as a command alias, so an existing MCP
client config keeps launching. The old environment variable names are still read. `pip install -U
ue-bridge` keeps working: that package is now a stub that depends on `ue4ss-bridge`.

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
[UEBridge] v1.2.1 ready
```

**3. Uninstall.** Delete `ue4ss\Mods\UEBridge\` and, if present, `ue4ss\bridge\`.

### Configuration (`scripts\settings.lua`)

That copy always wins. A `settings.lua` at the mod root (where 1.0.0 put it) is read only when
`scripts\` has none, and the mod logs one line naming it as ignored when both exist, so delete
the root file after an in-place upgrade. Edit, save, then `ue4ss-bridge reload` (or the `reload_mod`
tool), or restart the game.

| Key | Default | Effect |
|---|---|---|
| `enabled` | `true` | `false` disables the bridge without uninstalling; nothing is polled |
| `allow_writes` | `true` | `false` is strict read-only: `set_property`, `call_function`, `console_command`, `hook_function` and `eval_lua` are refused |
| `allow_eval` | `true` | `false` refuses raw Lua (`eval_lua`); the structured inspection tools keep working |
| `poll_ms` | `50` | request file check interval in milliseconds (50 is the floor; lower values are clamped) |
| `bridge_dir` | unset | absolute path override for the request/response folder |

## Connect a tool or an AI agent (the MCP server)

The program that writes and reads the IPC files is **ue4ss-bridge**, a small Python package. It
finds any running UE4SS game on its own (an exe in a `Binaries\Win64` folder with `ue4ss\` beside
it), so there are no paths to configure. Pass `--game-dir` or set `UE4SS_BRIDGE_GAME_DIR` to pin
one. The pre-1.2.0 `UE_BRIDGE_GAME_DIR` and `UE_BRIDGE_DATA_DIR` are still read as a fallback.

**Install**

```bash
uvx ue4ss-bridge
```

or with pip:

```bash
pip install ue4ss-bridge
```

**Quick check.** With the game up and the mod loaded:

```bash
uvx ue4ss-bridge status
```

```
game: The_Holy_Fool | process: The_Holy_Fool-Win64-Shipping.exe | running: True | bridge dir: C:\...\Binaries\Win64\ue4ss\bridge
```

`uvx ue4ss-bridge hello` returns the mod's version, protocol and permissions.

### Claude Code

```bash
claude mcp add ue4ss-bridge -- uvx ue4ss-bridge
```

### Claude Desktop

Add this to `claude_desktop_config.json` (`%APPDATA%\Claude\` on Windows,
`~/Library/Application Support/Claude/` on macOS):

```json
{
  "mcpServers": {
    "ue4ss-bridge": {
      "command": "uvx",
      "args": ["ue4ss-bridge"]
    }
  }
}
```

### Cursor and other MCP clients

Pass `uvx ue4ss-bridge` (or, with pip, `ue4ss-bridge` / `python -m ue4ss_bridge`) as the MCP server
command. Cursor reads `.cursor/mcp.json` in the project root, or Cursor Settings > Features > MCP;
Windsurf, Continue, VS Code and Codex each take the same JSON block in their MCP settings file.

### HTTP (one long-running server, several clients)

`ue4ss-bridge --http` serves streamable-HTTP MCP on `http://127.0.0.1:8930/mcp`, loopback only
(`--port` changes the port):

```bash
claude mcp add --transport http ue4ss-bridge http://127.0.0.1:8930/mcp
```

### Shell, for scripts and for testing the channel

```bash
ue4ss-bridge status
ue4ss-bridge hello
ue4ss-bridge eval "return UEB.world()"
ue4ss-bridge props first:PlayerController
ue4ss-bridge types ^Narrative
ue4ss-bridge subclasses /Script/Engine.Pawn
ue4ss-bridge target 5000                    # what the camera is pointed at
ue4ss-bridge snapshot first:PlayerController before --super   # --super: include inherited properties (props too)
ue4ss-bridge diff before                    # or: diff <ref> <label> for another object
ue4ss-bridge watch first:PlayerController Pawn pawnwatch --interval 500
ue4ss-bridge hook /Script/Engine.PlayerController:ClientRestart restarts
ue4ss-bridge events                         # or: events <label>
ue4ss-bridge streams
ue4ss-bridge unwatch pawnwatch              # or: unwatch "*"
```

### Example prompts

Once an agent is connected, ask it about the running game in plain language:

- "Inspect the player pawn and list every health, stamina and combat property."
- "Which enemy characters are spawned in the world right now?"
- "What UFunctions on the player controller relate to movement, interaction or camera?"
- "Snapshot the player controller, then tell me what changed after I open the map."
- "Watch the player pawn's health, then tell me every time it dropped while I fought."
- "What am I looking at right now, and which materials are on it?"
- "List every Blueprint class derived from the enemy base class."
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
| `list_subclasses(ref, limit, pattern)` | Every loaded class derived from a base class, Blueprint classes included: `{base, count, types}` with `{name, kind, path, parent}` rows sorted by path. Read-only; about 1.5 s. |
| `targeted_actor(distance, channel, ref)` | Line trace from the camera (or from `ref`'s own location and forward vector): the actor, component, impact point and normal, bone, physical material and materials hit. Read-only. |
| `watch_property(ref, names, label, interval_ms, every)` | Sample properties on a timer and record every change under a label. `interval_ms` defaults to 250 with a 100 ms floor. Read-only. |
| `hook_function(function, label, max_args)` | Record every call of a `UFunction` with its parameters. Counts as a write. |
| `poll_events(since, label, limit, clear)` | Drain what the watches and hooks recorded: `{events, next, dropped, buffered}`. Read-only. |
| `list_streams()` / `stop_stream(label)` | Watches and hooks running / stop one, or all with `"*"`. |
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

**Streams** (watches and hooks) also live in the game process and survive `UEB.reload()`. They
share one buffer of 2000 events with a rising sequence number; `poll_events` reports `dropped`
when the cap evicted rows before you read them. Labels are unique. A watch holds its object between
passes and rechecks it with `IsValid()` each pass, looking it up again only when it is gone or a
read failed, so it follows `first:PlayerController` across respawns; its interval defaults to
250 ms and is floored at 100 ms, because a lookup costs 10 to 25 ms of game-thread time on a game
without object hash tables. It records `resumed` when it adopts a different object (by address and full name)
after the previous one stopped being valid or was lost, resetting the baseline so the first sample
on the new object is not a change; the same object back after a blip records nothing. When the
reference goes away it records one `lost` event and retries at a slow cadence.
A hook's callback copies parameters and nothing
else: calling a hooked function from `eval_lua` in the same session has crashed the game, so read
hook output through `poll_events`.

## Wire protocol (3)

```
request : {"id": str, "op": "hello"|"ping"|"eval"|"batch", "code": str, "calls": [ {op, ...} ]}
response: {"id", "ok": bool, "result", "output": [str], "error": str|null, "ms": int, "protocol": 3}
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
git clone https://github.com/littleRabbit94/ue4ss-bridge.git
cd ue4ss-bridge
uv venv --python 3.11 .venv
uv pip install --python .venv\Scripts\python.exe -e .   # the package and its one dependency (mcp)
.venv\Scripts\python.exe -m ue4ss_bridge status       # from the repo root
python tools/build-release.py                         # dist/ue4ss-bridge-<version>.zip
```

The mod half is `ue4ss/UEBridge/`; copy or link it into the game's `ue4ss\Mods\` to run the
checkout rather than a release zip.

Edit `ue4ss/UEBridge/scripts/main.lua`, then `ue4ss-bridge reload`: the mod
re-runs its source in place and retires the old poll loop, no relaunch.

## Credits and license

- MIT. See [LICENSE](LICENSE).
- Built on [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) by the UE4SS-RE team (MIT).
- Written with an AI coding agent workflow.
