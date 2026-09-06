# Changelog

## Unreleased

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
