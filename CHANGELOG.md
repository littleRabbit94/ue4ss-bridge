# Changelog

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
