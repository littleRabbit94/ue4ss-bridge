# ue-bridge (renamed)

This project is now **ue4ss-bridge**: https://pypi.org/project/ue4ss-bridge/

This package contains no code. Installing or upgrading it installs `ue4ss-bridge`, which still
provides the `ue-bridge` command, so existing MCP client configs keep launching.

Switch to the new name when convenient:

    pip uninstall ue-bridge
    pip install -U ue4ss-bridge

or run it with `uvx ue4ss-bridge`.
