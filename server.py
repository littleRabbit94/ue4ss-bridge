"""hf-bridge: MCP server that talks to the running game through the HFBridge UE4SS Lua mod.

Transport is two files in <ue4ss>\\bridge\\ (request.json / response.json). The Lua mod polls the
request file every 250 ms, runs the snippet on the game thread, and writes the response. Nothing
here needs sockets or admin rights.

Run as an MCP server (stdio):   python server.py
Run from a shell:               python server.py ping
                                python server.py eval "return HFB.world()"
                                python server.py world | props <ref> | funcs <ref> | objects <Class>
                                python server.py types [pattern] | console <cmd> | status
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

DEFAULT_UE4SS_DIR = (
    r"C:\_Games\launchers\steamapps\common\The Lantern of the Laughless Saint"
    r"\The_Holy_Fool\Binaries\Win64\ue4ss"
)
BRIDGE_DIR = Path(os.environ.get("HF_BRIDGE_DIR") or Path(DEFAULT_UE4SS_DIR) / "bridge")
GAME_PROCESS = "The_Holy_Fool-Win64-Shipping"
DEFAULT_TIMEOUT = 15.0


class BridgeError(RuntimeError):
    pass


def game_running() -> bool:
    try:
        out = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {GAME_PROCESS}.exe", "/NH", "/FO", "CSV"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except Exception:
        return False
    # Table output truncates image names to 25 characters; CSV keeps the full name.
    return GAME_PROCESS in out


def _lua_literal(value: Any) -> str:
    """Embed a JSON value in Lua source, decoded at runtime by the mod's json module."""
    text = json.dumps(value)
    level = "="
    while f"]{level}]" in text:
        level += "="
    return f"json.decode([{level}[{text}]{level}])"


def request(op: str, timeout: float = DEFAULT_TIMEOUT, **fields: Any) -> dict:
    BRIDGE_DIR.mkdir(parents=True, exist_ok=True)
    req_path = BRIDGE_DIR / "request.json"
    tmp_path = BRIDGE_DIR / "request.tmp"
    res_path = BRIDGE_DIR / "response.json"

    res_path.unlink(missing_ok=True)  # a stale response from a timed-out call
    if req_path.exists():
        raise BridgeError(
            "a previous request.json is still unconsumed: the game is not polling. "
            "Is it running with HFBridge enabled in mods.txt?"
        )

    rid = uuid.uuid4().hex[:12]
    body = {"id": rid, "op": op, **fields}
    tmp_path.write_text(json.dumps(body), encoding="utf-8")
    os.replace(tmp_path, req_path)

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
                "request never picked up. The game is running; check that HFBridge is enabled in "
                "mods.txt and that ue4ss\\UE4SS.log contains '[HFBridge] ready'."
            )
        raise BridgeError("request never picked up: the game is not running. Launch with scripts\\Start-Game.ps1.")
    raise BridgeError(
        f"request {rid} was picked up but no response arrived within {timeout}s. "
        "The game thread may be blocked (loading screen) or the snippet may be long-running."
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


def _helper(expr: str, timeout: float = DEFAULT_TIMEOUT) -> Any:
    return _unwrap(eval_lua(f"local json = require('json')\nreturn {expr}", timeout))


# --- MCP server ---------------------------------------------------------------------------

def build_server():
    from mcp.server.fastmcp import FastMCP

    mcp = FastMCP(
        "hf-bridge",
        instructions=(
            "Live bridge into The Lantern of the Laughless Saint via UE4SS. Every tool runs Lua on "
            "the game thread of the running game. Call bridge_status first. Object references are "
            "full paths ('/Script/Pkg.Object'), 'first:<ShortClassName>' for the first live "
            "instance, or 'cdo:/Script/Pkg.Class' for a class default object. Writes change live "
            "game state and are not undone."
        ),
    )

    @mcp.tool()
    def bridge_status() -> dict:
        """Whether the game is running and the HFBridge mod is answering. Reports round-trip time."""
        running = game_running()
        info: dict[str, Any] = {"game_running": running, "bridge_dir": str(BRIDGE_DIR)}
        if not running:
            info["bridge"] = "down"
            return info
        try:
            t0 = time.monotonic()
            res = request("ping", timeout=3.0)
            info["bridge"] = "up"
            info["round_trip_ms"] = round((time.monotonic() - t0) * 1000)
            info["handled"] = (res.get("result") or {}).get("handled")
        except BridgeError as e:
            info["bridge"] = "down"
            info["detail"] = str(e)
        return info

    @mcp.tool(name="eval_lua")
    def eval_lua_tool(code: str, timeout: float = DEFAULT_TIMEOUT) -> dict:
        """Run a Lua chunk inside the game on the game thread and return what it returns.

        The full UE4SS Lua API is available (StaticFindObject, FindFirstOf, FindAllOf, RegisterHook,
        ForEachUObject, ...) plus the HFB helper table: HFB.resolve(ref), HFB.props(ref),
        HFB.funcs(ref), HFB.get(ref, name), HFB.set(ref, name, value), HFB.call(ref, fn, args),
        HFB.objects(class, limit), HFB.types(pattern, limit), HFB.console(cmd), HFB.world(),
        HFB.dump(kind). print() output is captured and returned alongside the result.
        """
        return _unwrap(eval_lua(code, timeout))

    @mcp.tool()
    def world_info() -> dict:
        """Current world, player controller, pawn, game instance and game mode."""
        return _helper("HFB.world()")

    @mcp.tool()
    def find_object(path: str) -> dict:
        """Resolve an object reference and return its full name, class and address."""
        return _helper(
            f"(function() local o = HFB.resolve({_lua_literal(path)}) "
            "return { object = o:GetFullName(), class = o:GetClass():GetFullName(), address = o:GetAddress() } end)()"
        )

    @mcp.tool()
    def find_objects(class_name: str, limit: int = 100) -> dict:
        """Live (non-default) instances of a short class name, e.g. 'HFCharacter'."""
        return _helper(f"HFB.objects({_lua_literal(class_name)}, {int(limit)})")

    @mcp.tool()
    def list_types(pattern: str = "^HF", limit: int = 200) -> dict:
        """Loaded reflected types whose name matches a Lua pattern. Walks GUObjectArray (~400 ms)."""
        return _helper(f"HFB.types({_lua_literal(pattern)}, {int(limit)})", timeout=30)

    @mcp.tool()
    def inspect_object(ref: str, include_super: bool = False) -> dict:
        """Every reflected property of an object with its current value. Use on CDOs and live actors.

        include_super defaults to False. The full chain is now survivable, since HFB.props skips
        SoftObjectProperty reads (the null dereference inside UE4SS's own property reader that no
        Lua pcall can catch), but it is the more expensive call and the conservative default is the
        useful one. See "The live bridge" in docs/ue4ss.md.
        """
        return _helper(f"HFB.props({_lua_literal(ref)}, {'true' if include_super else 'false'})", timeout=30)

    @mcp.tool()
    def list_functions(ref: str) -> dict:
        """Every reflected UFunction callable on an object, across its class chain."""
        return _helper(f"HFB.funcs({_lua_literal(ref)})")

    @mcp.tool()
    def get_property(ref: str, name: str) -> dict:
        """Read one property of an object."""
        return _helper(f"HFB.get({_lua_literal(ref)}, {_lua_literal(name)})")

    @mcp.tool()
    def set_property(ref: str, name: str, value: Any) -> dict:
        """Write one property of an object (number, bool or string). Returns the value read back."""
        return _helper(f"HFB.set({_lua_literal(ref)}, {_lua_literal(name)}, {_lua_literal(value)})")

    @mcp.tool()
    def call_function(ref: str, function: str, args: list[Any] | None = None) -> dict:
        """Call a UFunction on an object with positional JSON args and return its result."""
        return _helper(
            f"HFB.call({_lua_literal(ref)}, {_lua_literal(function)}, {_lua_literal(args or [])})"
        )

    @mcp.tool()
    def console_command(command: str) -> dict:
        """Execute a console command in the running world. Output is not captured (engine logging is compiled out)."""
        return _helper(f"HFB.console({_lua_literal(command)})")

    @mcp.tool()
    def dump(kind: str) -> dict:
        """Trigger a UE4SS dumper: usmap, jmap, uht, cxx, actors, objects, static_meshes. Output lands in the ue4ss directory; jmap and uht take minutes."""
        return _helper(f"HFB.dump({_lua_literal(kind)})", timeout=600)

    return mcp


# --- CLI ----------------------------------------------------------------------------------

def _cli(argv: list[str]) -> int:
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "ping":
            t0 = time.monotonic()
            res = request("ping", timeout=float(rest[0]) if rest else 5.0)
            print(json.dumps({"round_trip_ms": round((time.monotonic() - t0) * 1000), **res}, indent=1))
        elif cmd == "eval":
            code = rest[0] if rest else "-"
            if code == "-":
                code = sys.stdin.read()
            print(json.dumps(_unwrap(eval_lua(code)), indent=1))
        elif cmd == "world":
            print(json.dumps(_helper("HFB.world()"), indent=1))
        elif cmd == "props":
            print(json.dumps(_helper(f"HFB.props({_lua_literal(rest[0])})", 30), indent=1))
        elif cmd == "funcs":
            print(json.dumps(_helper(f"HFB.funcs({_lua_literal(rest[0])})"), indent=1))
        elif cmd == "objects":
            print(json.dumps(_helper(f"HFB.objects({_lua_literal(rest[0])})"), indent=1))
        elif cmd == "types":
            print(json.dumps(_helper(f"HFB.types({_lua_literal(rest[0] if rest else '^HF')})", 30), indent=1))
        elif cmd == "console":
            print(json.dumps(_helper(f"HFB.console({_lua_literal(' '.join(rest))})"), indent=1))
        elif cmd == "status":
            print("game running:", game_running(), "| bridge dir:", BRIDGE_DIR)
        else:
            print(__doc__)
            return 2
    except BridgeError as e:
        print("bridge error:", e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1:
        sys.exit(_cli(sys.argv[1:]))
    build_server().run()
