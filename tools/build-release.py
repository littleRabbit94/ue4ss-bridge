"""Build the UEBridge mod archive for Nexus / GitHub releases.

Output: dist/UEBridge-<version>.zip with the folder path inside, so extracting it into the game
root (or the folder holding ue4ss\\) lands the mod in ue4ss\\Mods\\UEBridge with no further step:

    ue4ss/Mods/UEBridge/enabled.txt          <- starts the mod without editing mods.txt
    ue4ss/Mods/UEBridge/settings.lua
    ue4ss/Mods/UEBridge/scripts/main.lua
    ue4ss/Mods/UEBridge/scripts/json.lua
    ue4ss/Mods/UEBridge/README.txt

mod.toml is left out: it is a mod-manager manifest for the author's own tooling, not a UE4SS
file. The archive carries nothing executable beyond the Lua the mod is.

Usage: python tools/build-release.py   (from the repo root; no dependencies)
"""
from __future__ import annotations

import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD = ROOT / "ue4ss" / "UEBridge"
DIST = ROOT / "dist"

README = """UEBridge {version}

A developer tool for UE4SS games. It changes nothing on its own. It lets a program on this
computer (for example the ue-bridge MCP server, so an AI agent can help you mod) run Lua inside
the running game and read the result, without a relaunch per question.

INSTALL
  Extract this archive into your game's install folder. The files land in
  <game>\\<Project>\\Binaries\\Win64\\ue4ss\\Mods\\UEBridge on their own. UE4SS must already be
  installed. No mods.txt edit is needed: enabled.txt in the mod folder turns it on.

  UE4SS.log will show "[UEBridge] v{version} ready" when it loaded.

WHAT IT DOES, EXACTLY
  Every 250 ms it checks for a file named request.json in ue4ss\\bridge. If one appears it runs the
  request on the game thread and writes response.json. That is all. It opens no network
  connection, starts no program, and downloads nothing. Only software already running on your
  computer, with write access to your game folder, can talk to it.

SETTINGS (settings.lua in the mod folder)
  enabled       = false  turns it off without uninstalling
  allow_writes  = false  read-only: nothing can change game state through the bridge
  allow_eval    = false  refuses raw Lua; the structured inspection tools still work

THE OTHER HALF
  The MCP server and CLI (ue-bridge) is a separate, optional download:
    pip install ue-bridge        or        uvx ue-bridge
  Source, documentation and the agent setup snippets: {source}

UNINSTALL
  Delete the ue4ss\\Mods\\UEBridge folder and ue4ss\\bridge.

License: MIT.
"""


def version() -> str:
    text = (MOD / "scripts" / "main.lua").read_text(encoding="utf-8")
    m = re.search(r'^local VERSION = "([^"]+)"', text, re.M)
    if not m:
        sys.exit("VERSION not found in main.lua")
    return m.group(1)


def source_url() -> str:
    text = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    m = re.search(r'^Source = "([^"]+)"', text, re.M)
    return m.group(1) if m else ""


def main() -> int:
    ver = version()
    DIST.mkdir(exist_ok=True)
    out = DIST / f"UEBridge-{ver}.zip"
    prefix = "ue4ss/Mods/UEBridge/"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(prefix + "enabled.txt", "")
        z.write(MOD / "settings.lua", prefix + "settings.lua")
        for f in sorted((MOD / "scripts").glob("*.lua")):
            z.write(f, prefix + "scripts/" + f.name)
        z.writestr(prefix + "README.txt", README.format(version=ver, source=source_url()))
        z.write(ROOT / "LICENSE", prefix + "LICENSE.txt")
    names = zipfile.ZipFile(out).namelist()
    print(out, f"{out.stat().st_size:,} bytes")
    for n in names:
        print("  ", n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
