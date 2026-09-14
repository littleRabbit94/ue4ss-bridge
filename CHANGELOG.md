# Changelog

## 1.2.1 (2026-09-14)

- `get` and `set` no longer fail with `attempt to index a nil value (local 'prop')` raised inside
  UE4SS's `ForEachProperty` when UE4SS hands the property-name check a nil entry (seen once in
  play 2026-09-13). Every property walk now skips nil entries and counts them. When the name is
  not found and entries were skipped, the error says the class had unreadable properties instead
  of "no property"; `props` returns the count as `skipped`, a struct value as `__skipped`. An
  error inside a walk is raised after the walk returns, so it reaches the caller as an ordinary
  batch error without the `[Lua::call_function]` wrapper or a UE4SS log line.

## 1.2.0 (2026-09-11)

**Renamed to ue4ss-bridge.** The old name collided with grapeot/ue-bridge, an Unreal Editor TCP
bridge, and the new one says what the tool needs.

- The PyPI package is `ue4ss-bridge`, the Python module is `ue4ss_bridge`, and the command is
  `ue4ss-bridge`. `argparse` and `--version` print the new name.
- `ue-bridge` stays installed as a second console script pointing at the same entry point, so an
  MCP client config written against the old name keeps launching. `pip install -U ue-bridge`
  keeps working: that package is now a stub that depends on `ue4ss-bridge`.
- The server reads `UE4SS_BRIDGE_GAME_DIR` and `UE4SS_BRIDGE_DATA_DIR`, falling back to the old
  `UE_BRIDGE_GAME_DIR` / `UE_BRIDGE_DATA_DIR`.
- The FastMCP server name is `ue4ss-bridge`; the source URL is
  https://github.com/littleRabbit94/ue4ss-bridge (GitHub redirects the old one).
- Unchanged, so nothing in the game needs touching: the mod folder `ue4ss\Mods\UEBridge\`, the
  `UEB` helper table, the `[UEBridge]` log prefix, `settings.lua` and its keys, and the
  request/response file layout.
- `tools/build-release.py` now writes `dist/ue4ss-bridge-<version>.zip`; the folder inside the
  archive is still `ue4ss/Mods/UEBridge/`.

**Event streams.** Watch a property or hook a function, play, then poll what piled up.

- New `watch` batch op and `watch_property` MCP tool (CLI: `watch <ref> <prop> <label>
  [--interval ms]`) sample one property or a list of them on a timer and record an event whenever
  a value changes. `every = true` records every sample instead.
- The game-thread runner is built once, when the watch is created: the timer body only checks
  flags and queues that one function, so nothing is allocated on the mod's async thread while the
  game thread runs Lua in the same state (allocating there corrupted a Lua table and crashed a
  game in `lua_next`).
- The sampler holds the resolved object between passes and rechecks it with `IsValid()` on each
  one, looking it up again only when the object is gone or a read failed. A watch on
  `first:PlayerController` still follows a respawn, without paying an object lookup per pass or
  trusting a stale pointer across a save reload.
- `interval_ms` defaults to 250 and is clamped to at least 100: a lookup costs roughly 10 to 25 ms
  of game-thread time on a game without object hash tables. One sample is in flight at a time, so
  a slow game thread does not queue overlapping closures.
- A watch survives a map change. When the reference stops resolving it records one
  `{kind: "stream", event: "lost"}` row and retries at a slow cadence instead of every interval.
  `{kind: "stream", event: "resumed"}` is recorded when the watch adopts a different object (by
  address) after the previous one stopped being valid or was lost, with the baseline reset so the
  first sample on the new object is not reported as a change; the same object coming back after a
  blip records nothing. Only `stop_stream` ends a watch, and `list_streams` reports `lost`.
- New `hook` batch op and `hook_function` MCP tool (CLI: `hook <fnpath> <label>`) record every
  call of a UFunction with up to `max_args` parameters (default 8) and the calling object's name.
  The callback copies values and does nothing else. A hook registers cleanly, but an eval that
  then CALLED the hooked function crashed the game with an access violation, so read hook output
  through `poll_events` and do not call a hooked function from eval in the same session.
- Hooking goes through `requireWrites`, since a hook intercepts game code: it is refused with
  `allow_writes = false`. Watches are read-only.
- New `events` batch op and `poll_events` MCP tool (CLI: `events [label]`) drain the buffer:
  `since` is an exclusive sequence number, `label` filters to one stream, `clear` drops the rows
  returned. Returns `{events, next, dropped, buffered}`.
- One buffer of 2000 events is shared by every stream, with a rising `seq` per event and a
  `dropped` counter for what the cap evicted. Rows are keyed by `seq`, so eviction is O(1) and a
  client can ask for everything after a sequence number it already has.
- New `streams` and `unwatch` batch ops and the `list_streams` / `stop_stream` MCP tools (CLI:
  `streams`, `unwatch <label>`). `unwatch "*"` stops everything; stopping a hook unregisters it.
- Reusing a label errors rather than silently replacing a running stream.
- Streams and their events live on `_G`, so `UEB.reload()` keeps them, as it does snapshots.

**What the player is looking at.** New `target` batch op and `targeted_actor` MCP tool (CLI:
`target [distance]`).

- A line trace from the player camera along its forward vector, returning `{hit, actor,
  actor_class, component, component_class, distance, impact_point, impact_normal, bone,
  phys_material, materials}`. A miss returns `{hit: false}` alone.
- `distance` is in centimetres (default 5000) and `channel` selects the trace channel
  (0 = Visibility, 1 = Camera).
- `ref` traces from that actor's own `K2_GetActorLocation()` along its `GetActorForwardVector()`
  instead of the camera, which is how to ask what an NPC faces.
- The actor is the hit component's owner; `materials` are the component's material full names
  (first 32) when it exposes `GetMaterials`.
- Read-only: it calls const getters and the trace, so it works with `allow_writes = false`. Each
  engine call writes its own `lastop.log` line, so a native crash names the stage that caused it.

**Subclasses.** New `subclasses` batch op and `list_subclasses` MCP tool (CLI:
`subclasses <class>`).

- Every loaded class derived from a base class, Blueprint classes included. The engine keeps no
  reverse index, so this walks every UObject and tests `IsChildOf`: about 1.5 s on a large game,
  hence a 30 s timeout.
- `ref` is a class path such as `/Script/Engine.PlayerController`; an object that is not a `Class`
  or `BlueprintGeneratedClass` is an error rather than an empty result.
- Returns `{base, count, types}` with `{name, kind, path, parent}` rows, `parent` being the
  immediate super class's short name. The base itself is excluded, `pattern` filters on the short
  name, and rows are sorted by path so two runs agree.

**Other**

- `UEHelpers` is now in the eval environment. It was a file local in `main.lua` and unreachable
  from an eval chunk, which failed with `attempt to index a nil value (global 'UEHelpers')`.
- Protocol bumped to 3 on both sides.

## 1.1.0 (2026-09-07)

- New `reload` batch op and `reload_mod` MCP tool (CLI: `ue-bridge reload`) re-read `settings.lua` and re-run the mod in place via `UEB.reload()`. It bypasses `requireWrites`, so it is the way to recover after `allow_eval` was turned off without a game restart: eval was the only path to `UEB.reload()` before, and eval itself is refused when `allow_eval = false`.
- `first:ShortClassName` can resolve to a template, cutscene copy or pooled actor rather than the live instance; use the exact path from `world_info` for the player pawn or controller.
- CLI: `props` and `snapshot` take `--super` to include inherited properties, matching the MCP tools' `include_super`; the CLI help now lists it.
- `scripts\settings.lua` is loaded first and a `settings.lua` at the mod root only as a fallback, so an in-place upgrade from 1.0.0 no longer keeps the old file (including its 250 ms poll) and a mod manager that deploys `scripts\` is no longer overridden. With both present the mod logs one line naming the root file as ignored.
- `props`, `funcs`, `objects` and `types` results pass through `batch` unchanged, like `diff`, so a walk of more than 200 properties stays a JSON list instead of turning into an object keyed `"1"`..`"200"`.
- A truncated plain Lua table's `"<more>"` is the number of keys dropped, not `true`.
- `bridge_status` re-checks the running process before reading the game's identity, so it names the game that is running now rather than the previous one after a switch.
- `allow_writes = false` still forces `allow_eval` off, but the mod logs one line saying so at load and the eval refusal names `allow_writes` as the cause.
- `same` in a diff is documented consistently as the number of top-level properties with no changed, added or removed rows.
- Release README no longer states the old 250 ms poll.
- **Snapshot and diff.** Four new `batch` ops: `snapshot` (ref, label, include_super, pattern) keeps a property walk in the game under a label, `diff` (ref, label, update) re-walks with the stored options and reports `{changed, added, removed, same}` with dotted property paths, `snapshots` lists what is held, `forget` drops one label or all with `"*"`. MCP tools `snapshot_object`, `diff_object`, `list_snapshots`, `forget_snapshot` and the matching CLI subcommands.
- All four are read-only: they work with `allow_writes = false` and `allow_eval = false`. Snapshots are keyed by label, not by object address, are stored on `_G` so `UEB.reload()` keeps them, and are lost when the game exits. Diffs ignore object and struct addresses and reuse the walk's depth and array caps, so an unchanged object diffs empty.
- Values that are unstable between two walks no longer make an unchanged object diff non-empty: the userdata fallback compares by its `__type` and not its `tostring()` text, two `<error: ...>` read markers compare equal, a failed `ToString` encodes as `<FName>` rather than a pointer, and two NaNs compare equal. A plain Lua table longer than 200 keys sorts its keys before truncating, so the kept subset is the same on both walks.
- `diff` returns its rows unchanged through `batch` instead of being re-encoded, so `changed`/`added`/`removed` always serialise as JSON lists and rows keep their full depth. Each list holds at most 500 rows, with a `truncated` count per list when that bites.
- A snapshot's `taken` is `os.time()`, a wall-clock timestamp in whole seconds, not CPU time.
- `diff_object`'s `ref` is optional and defaults to the reference the snapshot was taken with; the CLI accepts `diff <label>` as well as `diff <ref> <label>`.
- Protocol bumped to 2 on both sides.
- `poll_ms` default lowered from 250 to 50. Measured on The Lantern of the Laughless Saint (UE 5.8), 60 pings each: median 209 ms at 250, median 57 ms and p90 107 ms at 50. The Python response wait stays at 50 ms; 20 ms gave the same mean (~70 ms), since the mod's poll sets the pace.
- The mod keeps its 50 ms floor; lower values are clamped.

## 1.0.0 (2026-09-05)

First release.

**UEBridge** (UE4SS Lua mod)
- File-based request/response channel in `ue4ss\bridge`: `hello`, `ping`, `eval`, `batch`.
- Game-agnostic; resolves its own paths through `IterateGameDirectories`.
- `scripts\settings.lua`: `enabled`, `poll_ms`, `allow_eval`, `allow_writes`, `bridge_dir`.
- Structured `batch` ops (`world`, `find`, `get`, `set`, `props`, `funcs`, `objects`, `types`, `call`, `console`, `dump`) keep working with `allow_eval = false`; `set`, `call`, `console` and `eval` are refused with `allow_writes = false`.
- Property reads walk reflected struct types, including inherited fields; `SoftObjectProperty` and `SoftClassProperty` are skipped unless asked for.
- Unknown property names on `get`/`set` are errors, not silent no-ops.
- `UEB.reload()` re-runs the mod in place without a game restart.
- Ships with `enabled.txt`; no `mods.txt` edit.

**ue-bridge** (Python, MCP server and CLI)
- MCP over stdio, or streamable HTTP on `127.0.0.1:8930` with `--http`.
- Finds the running game by itself: any exe in a `Binaries\Win64` folder with `ue4ss\` beside it. `--game-dir` / `UE_BRIDGE_GAME_DIR` / `UE_BRIDGE_DATA_DIR` override.
- Protocol version check against the mod; stale requests reclaimed after 10 s.
- On a timeout with the process gone, reports the in-flight operation and the newest crash report.
- Tools: `bridge_status`, `eval_lua`, `world_info`, `find_object`, `find_objects`, `list_types`, `inspect_object`, `list_functions`, `get_property`, `set_property`, `call_function`, `console_command`, `batch`, `dump`.

Verified on The Lantern of the Laughless Saint (UE 5.8) and The Blood of Dawnwalker (UE 5.5.4).
