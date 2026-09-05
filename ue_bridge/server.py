"""ue-bridge: MCP server and CLI that talk to a running UE4SS game through the UEBridge Lua mod.

Transport is two files in <game>\\Binaries\\Win64\\ue4ss\\bridge\\ (request.json / response.json).
The Lua mod polls the request file, runs the request on the game thread, and writes the response.
Nothing here needs sockets or admin rights, and nothing here names a particular game: the game is
found by looking for a running exe in a Binaries\\Win64 folder that has ue4ss\\ beside it.

Run as an MCP server (stdio):   ue-bridge                (or: python -m ue_bridge)
Run as an MCP server (HTTP):    ue-bridge --http [--port 8930]
Run from a shell:               ue-bridge ping | hello | status | world
                                ue-bridge eval "return UEB.world()"
                                ue-bridge props <ref> | funcs <ref> | objects <Class>
                                ue-bridge types [pattern] | console <cmd>

Configuration, all optional, first match wins:
  --game-dir PATH / UE_BRIDGE_GAME_DIR   the game root or any folder under it
  UE_BRIDGE_DATA_DIR                     the bridge folder itself (request/response files)
  otherwise                              discovered from the running game process
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import __version__

PROTOCOL = 1
DEFAULT_TIMEOUT = 15.0
# An unconsumed request.json older than this is a leftover from a dead game, not a call in flight.
STALE_REQUEST_S = 10.0

SHIPPING_SUFFIXES = ("-Win64-Shipping.exe", "-Win64-Test.exe", "-Win64-Debug.exe", "-Win64-DebugGame.exe")


class BridgeError(RuntimeError):
    pass


# --- Finding the game -----------------------------------------------------------------------

@dataclass
class Game:
    """Where the game is. Every path here is derived from the executable, nothing is assumed."""
    exe: Path | None            # ...\<Project>\Binaries\Win64\<Project>-Win64-Shipping.exe
    process: str | None         # image name without .exe
    project: str | None         # <Project>, the UE project name (also the %LOCALAPPDATA% folder)
    bridge_dir: Path

    @property
    def crash_dir(self) -> Path | None:
        if not self.project:
            return None
        return Path(os.environ.get("LOCALAPPDATA", "")) / self.project / "Saved" / "Crashes"


def _has_ue4ss(win64: Path) -> bool:
    return (win64 / "ue4ss").is_dir() or (win64 / "UE4SS.dll").is_file()


def _running_ue_processes() -> list[tuple[str, str]]:
    """(image name, full path) for every running exe in a Binaries\\Win64 folder with UE4SS beside it.

    The exe name is not reliable (Dawnwalker ships as Dawnwalker.exe, not *-Win64-Shipping.exe);
    the folder shape is.
    """
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like '*\\Binaries\\Win64\\*.exe' } | "
             "ForEach-Object { $_.Name + '|' + $_.ExecutablePath }"],
            capture_output=True, text=True, timeout=15,
        ).stdout
    except Exception:
        return []
    found = []
    for line in out.splitlines():
        name, _, path = line.strip().partition("|")
        if not path:
            continue
        exe = Path(path)
        win64 = exe.parent
        if (win64.name == "Win64" and win64.parent.name == "Binaries"
                and win64.parent.parent.name != "Engine" and _has_ue4ss(win64)):
            found.append((name, path))
    return found


def _project_from_exe(exe: Path) -> str:
    name = exe.name
    for suffix in SHIPPING_SUFFIXES:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return exe.stem


def _find_win64(root: Path) -> Path | None:
    """Locate <Project>\\Binaries\\Win64 under a game root (or accept it when handed directly)."""
    if root.name == "Win64" and root.parent.name == "Binaries":
        return root
    # Engine\Binaries\Win64 holds helper exes (CrashReportClient, ...); the project folder wins.
    cands = [c for c in list(root.glob("*/Binaries/Win64")) + [root / "Binaries" / "Win64"] if c.is_dir()]
    project = [c for c in cands if c.parent.parent.name != "Engine"]
    for cand in project:
        if _has_ue4ss(cand) or _game_exe_in(cand):
            return cand
    return project[0] if project else None


def _game_exe_in(win64: Path) -> Path | None:
    """The game exe in a Win64 folder: *-Win64-<Config>.exe, else <ProjectFolder>.exe."""
    for p in win64.glob("*-Win64-*.exe"):
        if p.name.endswith(SHIPPING_SUFFIXES):
            return p
    named = win64 / f"{win64.parent.parent.name}.exe"
    return named if named.is_file() else None


def locate_game(game_dir: str | None = None) -> Game:
    data_dir = os.environ.get("UE_BRIDGE_DATA_DIR")
    game_dir = game_dir or os.environ.get("UE_BRIDGE_GAME_DIR")

    if game_dir:
        win64 = _find_win64(Path(game_dir))
        if not win64:
            raise BridgeError(f"no <Project>\\Binaries\\Win64 folder under {game_dir}")
        exe = _game_exe_in(win64)
        bridge = Path(data_dir) if data_dir else win64 / "ue4ss" / "bridge"
        project = _project_from_exe(exe) if exe else win64.parent.parent.name
        return Game(exe=exe, process=exe.stem if exe else None, project=project, bridge_dir=bridge)

    procs = _running_ue_processes()
    if procs:
        _, path = procs[0]
        exe = Path(path)
        bridge = Path(data_dir) if data_dir else exe.parent / "ue4ss" / "bridge"
        return Game(exe=exe, process=exe.stem, project=_project_from_exe(exe), bridge_dir=bridge)

    if data_dir:
        return Game(exe=None, process=None, project=None, bridge_dir=Path(data_dir))
    raise BridgeError(
        "no running Unreal game found and no location configured. Start the game, or pass "
        "--game-dir / set UE_BRIDGE_GAME_DIR to the game's install folder."
    )


_GAME: Game | None = None
_GAME_DIR_ARG: str | None = None


def _pinned() -> bool:
    return bool(_GAME_DIR_ARG or os.environ.get("UE_BRIDGE_GAME_DIR") or os.environ.get("UE_BRIDGE_DATA_DIR"))


def game() -> Game:
    """The located game. Cached; a process-discovered game is re-discovered once it is gone."""
    global _GAME
    if _GAME is None or (_GAME.process is None and not _pinned()):
        _GAME = locate_game(_GAME_DIR_ARG)
    return _GAME


def _process_running(image: str) -> bool:
    try:
        out = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {image}.exe", "/NH", "/FO", "CSV"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except Exception:
        return False
    # CSV keeps the full image name (the table format truncates at 25 chars). First field is the name.
    return any(line.startswith(f'"{image}.exe"') for line in out.splitlines())


def game_running() -> bool:
    global _GAME
    g = game()
    if g.process and _process_running(g.process):
        return True
    if not _pinned():
        # Another game may have been started since discovery.
        _GAME = None
        try:
            return game().process is not None
        except BridgeError:
            return False
    return False


# --- Crash forensics ------------------------------------------------------------------------

def _last_op() -> str | None:
    """What the mod was doing when it last wrote its trace line. See `trace` in main.lua."""
    try:
        text = (game().bridge_dir / "lastop.log").read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return None
    return text or None


def _crash_since(started: float) -> dict | None:
    """The newest crash report, if one was written after `started` (a time.time() stamp)."""
    crash_dir = game().crash_dir
    if not crash_dir:
        return None
    try:
        folders = [d for d in crash_dir.iterdir() if d.is_dir()]
    except OSError:
        return None
    if not folders:
        return None
    newest = max(folders, key=lambda d: d.stat().st_mtime)
    if newest.stat().st_mtime < started - 5:
        return None
    info: dict[str, Any] = {"report": str(newest)}
    try:
        xml = (newest / "CrashContext.runtime-xml").read_text(encoding="utf-8", errors="replace")
        start = xml.find("<ErrorMessage>")
        if start >= 0:
            end = xml.find("</ErrorMessage>", start)
            info["error"] = xml[start + len("<ErrorMessage>"):end].strip()
    except OSError:
        pass
    return info


def _crash_report(started: float) -> str:
    lines = ["the game crashed during this call (the process is gone)."]
    op = _last_op()
    if op:
        lines.append("  in flight: " + op)
    crash = _crash_since(started)
    if crash:
        if crash.get("error"):
            lines.append("  crash: " + crash["error"])
        lines.append("  report: " + crash["report"])
    else:
        lines.append("  no crash report was written; the process may have been closed instead.")
    lines.append("  relaunch the game to continue.")
    return "\n".join(lines)


# --- Transport ------------------------------------------------------------------------------

def request(op: str, timeout: float = DEFAULT_TIMEOUT, **fields: Any) -> dict:
    bridge_dir = game().bridge_dir
    bridge_dir.mkdir(parents=True, exist_ok=True)
    req_path = bridge_dir / "request.json"
    tmp_path = bridge_dir / "request.tmp"
    res_path = bridge_dir / "response.json"

    res_path.unlink(missing_ok=True)  # stale response from a timed-out call
    if req_path.exists():
        age = time.time() - req_path.stat().st_mtime
        if age < STALE_REQUEST_S:
            raise BridgeError(
                f"a request.json written {age:.1f}s ago is still unconsumed: another client is "
                "mid-call, or the game is not polling. Retry in a moment."
            )
        req_path.unlink(missing_ok=True)

    rid = uuid.uuid4().hex[:12]
    body = {"id": rid, "op": op, **fields}
    tmp_path.write_text(json.dumps(body), encoding="utf-8")
    os.replace(tmp_path, req_path)

    started_wall = time.time()
    deadline = time.monotonic() + timeout
    picked_up = False
    while time.monotonic() < deadline:
        if not picked_up and not req_path.exists():
            picked_up = True
        if res_path.exists():
            try:
                data = json.loads(res_path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                time.sleep(0.02)
                continue
            res_path.unlink(missing_ok=True)
            if data.get("id") == rid:
                return data
            continue  # stale response from an earlier id; keep waiting
        time.sleep(0.05)

    if not picked_up:
        req_path.unlink(missing_ok=True)
        if game_running():
            raise BridgeError(
                "request never picked up. The game is running; check that the UEBridge mod is "
                "installed and enabled, and that ue4ss\\UE4SS.log contains '[UEBridge] ... ready'. "
                f"Bridge folder: {bridge_dir}"
            )
        raise BridgeError("request never picked up: the game is not running.")
    if not game_running():
        raise BridgeError(_crash_report(started_wall))
    op_line = _last_op()
    detail = ("\n  in flight: " + op_line) if op_line else ""
    raise BridgeError(
        f"request {rid} was picked up but no response arrived within {timeout}s. The game is still "
        f"running, so the thread is blocked (loading screen) or the request is long-running.{detail}"
    )


def eval_lua(code: str, timeout: float = DEFAULT_TIMEOUT) -> dict:
    return request("eval", timeout=timeout, code=code)


def _unwrap(res: dict) -> Any:
    """Turn a bridge response into a tool result, raising on Lua errors."""
    if not res.get("ok"):
        out = "\n".join(res.get("output") or [])
        raise BridgeError((res.get("error") or "unknown error") + (f"\n--- output ---\n{out}" if out else ""))
    result = res.get("result")
    output = res.get("output") or []
    if output:
        return {"result": result, "output": output, "ms": res.get("ms")}
    return {"result": result, "ms": res.get("ms")}


def batch(calls: list[dict], timeout: float = DEFAULT_TIMEOUT) -> list[dict]:
    """The structured op set, which stays available when the mod refuses raw eval."""
    return _unwrap(request("batch", timeout=timeout, calls=calls))["result"]


def one(op: str, timeout: float = DEFAULT_TIMEOUT, **args: Any) -> dict:
    """One structured op; the batch entry's error becomes a BridgeError."""
    entry = batch([{"op": op, **args}], timeout=timeout)[0]
    if not entry.get("ok"):
        raise BridgeError(entry.get("error") or "unknown error")
    return {"result": entry.get("result")}


def hello(timeout: float = 3.0) -> dict:
    res = _unwrap(request("hello", timeout=timeout))
    info = res["result"] or {}
    if info.get("protocol") != PROTOCOL:
        raise BridgeError(
            f"protocol mismatch: the UEBridge mod speaks protocol {info.get('protocol')}, this "
            f"server speaks {PROTOCOL}. Update whichever is older."
        )
    return info


# --- MCP server -----------------------------------------------------------------------------

def build_server(host: str = "127.0.0.1", port: int = 8930):
    from mcp.server.fastmcp import FastMCP

    mcp = FastMCP(
        "ue-bridge",
        instructions=(
            "Live bridge into a running Unreal Engine game via UE4SS. Every tool runs on the game "
            "thread of the running game. Call bridge_status first. Object references are full paths "
            "('/Script/Pkg.Object'), 'first:<ShortClassName>' for the first live instance, or "
            "'cdo:/Script/Pkg.Class' for a class default object. Writes change live game state and "
            "are not undone; the game's UEBridge/settings.lua may refuse writes or raw Lua."
        ),
        host=host,
        port=port,
    )

    @mcp.tool()
    def bridge_status() -> dict:
        """Whether a UE4SS game is running and the UEBridge mod is answering. Reports the game found, mod version, permissions, round-trip time."""
        info: dict[str, Any] = {"server_version": __version__, "protocol": PROTOCOL}
        try:
            g = game()
        except BridgeError as e:
            info.update(game_running=False, bridge="down", detail=str(e))
            return info
        info.update(game=g.project, process=g.process, bridge_dir=str(g.bridge_dir))
        running = game_running()
        info["game_running"] = running
        if not running:
            info["bridge"] = "down"
            return info
        try:
            t0 = time.monotonic()
            h = hello()
            info["bridge"] = "up"
            info["round_trip_ms"] = round((time.monotonic() - t0) * 1000)
            info["mod"] = {k: h.get(k) for k in ("version", "poll_ms", "allow_eval", "allow_writes", "handled")}
        except BridgeError as e:
            info["bridge"] = "down"
            info["detail"] = str(e)
        return info

    @mcp.tool(name="eval_lua")
    def eval_lua_tool(code: str, timeout: float = DEFAULT_TIMEOUT) -> dict:
        """Run a Lua chunk inside the game on the game thread and return what it returns.

        The full UE4SS Lua API is available (StaticFindObject, FindFirstOf, FindAllOf, RegisterHook,
        ForEachUObject, ...) plus the UEB helper table: UEB.resolve(ref), UEB.props(ref),
        UEB.funcs(ref), UEB.get(ref, name), UEB.set(ref, name, value), UEB.call(ref, fn, args),
        UEB.objects(class, limit), UEB.types(pattern, limit), UEB.console(cmd), UEB.world(),
        UEB.dump(kind). print() output is captured and returned alongside the result. Refused when
        the mod's settings.lua sets allow_eval = false; the other tools keep working.
        """
        return _unwrap(eval_lua(code, timeout))

    @mcp.tool()
    def world_info() -> dict:
        """Current world, player controller, pawn, game instance and game mode."""
        return one("world")

    @mcp.tool()
    def find_object(path: str) -> dict:
        """Resolve an object reference and return its full name, class and address."""
        return one("find", ref=path)

    @mcp.tool()
    def find_objects(class_name: str, limit: int = 100) -> dict:
        """Live (non-default) instances of a short class name, e.g. 'PlayerController'."""
        return one("objects", class_name=class_name, limit=int(limit))

    @mcp.tool()
    def list_types(pattern: str = "", limit: int = 200) -> dict:
        """Loaded reflected types whose name matches a Lua pattern (empty = all). Walks GUObjectArray (~400 ms)."""
        return one("types", timeout=30, pattern=pattern or None, limit=int(limit))

    @mcp.tool()
    def inspect_object(ref: str, include_super: bool = False, pattern: str | None = None) -> dict:
        """Every reflected property of an object with its current value. Use on CDOs and live actors.

        pattern is an optional Lua pattern matched against the property name, e.g. "^Camera" or
        "Speed"; one pawn can be 300 properties, so filtering is usually what you want.

        include_super defaults to False. SoftObjectProperty values are skipped (reading one has
        crashed a game inside UE4SS's own property reader, which no Lua pcall can catch).
        """
        return one("props", timeout=30, ref=ref, include_super=bool(include_super), read_soft=False, pattern=pattern)

    @mcp.tool()
    def list_functions(ref: str) -> dict:
        """Every reflected UFunction callable on an object, across its class chain."""
        return one("funcs", ref=ref)

    @mcp.tool()
    def get_property(ref: str, name: str) -> dict:
        """Read one property of an object. An unknown property name raises rather than returning junk."""
        return one("get", ref=ref, name=name)

    @mcp.tool()
    def set_property(ref: str, name: str, value: Any) -> dict:
        """Write one property of an object (number, bool or string).

        Returns {previous, current}. Writes are never undone, so `previous` is what you restore
        from if the write turns out to be wrong. An unknown property name raises instead of
        silently doing nothing. Refused when the mod's settings.lua sets allow_writes = false.
        """
        return one("set", ref=ref, name=name, value=value)

    @mcp.tool(name="batch")
    def batch_tool(calls: list[dict]) -> dict:
        """Run several bridge operations in ONE round trip and return a result per call.

        A round trip costs a poll interval plus latency against single-digit ms of actual work, so a
        sequence of small calls is nearly all waiting. Each entry is a dict with an "op" key:

          {"op": "world"}
          {"op": "find",    "ref": ...}
          {"op": "get",     "ref": ..., "name": ...}
          {"op": "set",     "ref": ..., "name": ..., "value": ...}
          {"op": "call",    "ref": ..., "function": ..., "args": [...]}
          {"op": "props",   "ref": ..., "include_super": bool, "read_soft": bool, "pattern": str}
          {"op": "funcs",   "ref": ...}
          {"op": "objects", "class_name": ..., "limit": int}
          {"op": "types",   "pattern": ..., "limit": int}
          {"op": "console", "command": ...}
          {"op": "dump",    "kind": ...}

        Each result is {op, ok, result} or {op, ok: false, error}. One failing call does not
        abandon the rest, so a batch is safe to use for exploration.
        """
        return {"result": batch(calls, timeout=60)}

    @mcp.tool()
    def call_function(ref: str, function: str, args: list[Any] | None = None) -> dict:
        """Call a UFunction on an object with positional JSON args and return its result. Refused when allow_writes = false."""
        return one("call", ref=ref, **{"function": function}, args=args or [])

    @mcp.tool()
    def console_command(command: str) -> dict:
        """Execute a console command in the running world. Output is not captured. Refused when allow_writes = false."""
        return one("console", command=command)

    @mcp.tool()
    def dump(kind: str) -> dict:
        """Trigger a UE4SS dumper: usmap, jmap, uht, cxx, actors, objects, static_meshes. Output lands in the ue4ss directory; jmap and uht take minutes."""
        return one("dump", timeout=600, kind=kind)

    return mcp


# --- CLI ------------------------------------------------------------------------------------

def _cli(cmd: str, rest: list[str]) -> int:
    def arg(i: int, what: str) -> str:
        if len(rest) <= i:
            raise BridgeError(f"{cmd} needs {what}")
        return rest[i]

    try:
        if cmd == "ping":
            t0 = time.monotonic()
            res = request("ping", timeout=float(rest[0]) if rest else 5.0)
            print(json.dumps({"round_trip_ms": round((time.monotonic() - t0) * 1000), **res}, indent=1))
        elif cmd == "hello":
            print(json.dumps(hello(), indent=1))
        elif cmd == "eval":
            code = rest[0] if rest else "-"
            if code == "-":
                code = sys.stdin.read()
            print(json.dumps(_unwrap(eval_lua(code)), indent=1))
        elif cmd == "world":
            print(json.dumps(one("world"), indent=1))
        elif cmd == "props":
            print(json.dumps(one("props", 30, ref=arg(0, "an object reference")), indent=1))
        elif cmd == "funcs":
            print(json.dumps(one("funcs", ref=arg(0, "an object reference")), indent=1))
        elif cmd == "objects":
            print(json.dumps(one("objects", class_name=arg(0, "a class name")), indent=1))
        elif cmd == "types":
            print(json.dumps(one("types", 30, pattern=rest[0] if rest else None), indent=1))
        elif cmd == "console":
            print(json.dumps(one("console", command=" ".join(rest)), indent=1))
        elif cmd == "status":
            try:
                g = game()
                print(f"game: {g.project} | process: {g.process} | running: {game_running()} | bridge dir: {g.bridge_dir}")
            except BridgeError as e:
                print("game: not found |", e)
        else:
            print(__doc__)
            return 2
    except BridgeError as e:
        print("bridge error:", e, file=sys.stderr)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    global _GAME_DIR_ARG
    parser = argparse.ArgumentParser(prog="ue-bridge", add_help=True,
                                     description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game-dir", help="game install folder (or any folder under it); default: discover the running game")
    parser.add_argument("--http", action="store_true", help="serve MCP over streamable HTTP on localhost instead of stdio")
    parser.add_argument("--port", type=int, default=8930, help="port for --http (default 8930)")
    parser.add_argument("--version", action="version", version=f"ue-bridge {__version__} (protocol {PROTOCOL})")
    parser.add_argument("command", nargs="?", help="CLI command; omit to run the MCP server")
    parser.add_argument("args", nargs=argparse.REMAINDER)
    ns = parser.parse_args(argv)
    _GAME_DIR_ARG = ns.game_dir

    if ns.command:
        return _cli(ns.command, ns.args)
    server = build_server(port=ns.port)  # loopback only: the bridge executes Lua inside the game
    server.run(transport="streamable-http" if ns.http else "stdio")
    return 0


if __name__ == "__main__":
    sys.exit(main())
