# Changelog

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
