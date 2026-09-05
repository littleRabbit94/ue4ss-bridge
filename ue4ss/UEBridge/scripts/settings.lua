-- UEBridge settings. Every key is optional; a missing key takes the default shown.
-- This file belongs next to main.lua, inside the mod's scripts folder.
-- Edit, save, then either restart the game or run UEB.reload() through the bridge.
return {
    -- false turns the bridge off without removing the mod. Nothing is polled.
    enabled = true,

    -- How often the request file is checked, in milliseconds.
    poll_ms = 250,

    -- false refuses raw Lua (the eval_lua tool). The structured tools (inspect_object,
    -- get_property, find_objects, ...) keep working through the batch op.
    allow_eval = true,

    -- false makes the bridge read-only: set_property, call_function, console_command and
    -- eval_lua are refused. Reads are unaffected.
    allow_writes = true,

    -- Absolute path for request.json / response.json. Default: <game>\Binaries\Win64\ue4ss\bridge
    -- bridge_dir = "C:\\path\\to\\bridge",
}
