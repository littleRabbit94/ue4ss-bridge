-- HFBridge: a file-based request/response channel so an external process (the MCP server in
-- tools/hf-bridge) can run Lua inside the live game without a relaunch per question.
--
--   external  ->  writes  <ue4ss>\bridge\request.json    {"id":..,"op":"eval","code":".."}
--   this mod  ->  polls it, runs the code on the game thread, writes response.json
--
-- The poll is a timer (LoopAsync), not a per-tick hook, and it only does work when the request
-- file exists. All game-object access happens inside ExecuteInGameThread.
--
-- Wire format
--   request : {"id": string, "op": "ping"|"eval", "code": string}
--   response: {"id", "ok": bool, "result": any, "output": [string], "error": string|null, "ms": n}
--
-- Eval snippets run in an environment that inherits _G plus the HFB helper table below. Whatever
-- the chunk returns is serialised: UObjects become {"__object": fullname, "address": n}, FName /
-- FString become strings, TArrays become lists, structs report common field names one level deep.

package.path = "Mods/HFBridge/scripts/?.lua;" .. package.path
local json = require("json")
local UEHelpers = require("UEHelpers")

-- Lua's io resolves relative paths against the process working directory, which is
-- Binaries\Win64 (the exe directory), NOT the ue4ss folder. Resolve an absolute path so the
-- bridge always lands in <ue4ss>\bridge regardless of how the game was launched.
local function bridgeDir()
    local ok, dirs = pcall(IterateGameDirectories)
    local win64 = ok and dirs and dirs.Game and dirs.Game.Binaries and dirs.Game.Binaries.Win64
    if win64 and win64.__absolute_path then
        return win64.__absolute_path .. "\\ue4ss\\bridge"
    end
    return "ue4ss/bridge"
end
local DIR = bridgeDir()
local REQUEST = DIR .. "/request.json"
local RESPONSE = DIR .. "/response.json"
local RESPONSE_TMP = DIR .. "/response.tmp"
local POLL_MS = 250

local function log(fmt, ...)
    print("[HFBridge] " .. string.format(fmt, ...) .. "\n")
end

-- A crash inside UE4SS's native code takes the process down mid-request and no pcall can catch
-- it, so the only way to learn what was in flight is to have written it to disk already. Keep ONE
-- line, rewritten in place and flushed, naming the current operation. The MCP server reads it
-- after a timeout to report what killed the game instead of guessing "blocked or long-running".
local TRACE = DIR .. "/lastop.log"
local traceHandle, traceOpened = nil, false
local function trace(s)
    if not traceOpened then traceHandle = io.open(TRACE, "wb") traceOpened = true end
    if not traceHandle then return end
    traceHandle:seek("set", 0)
    -- Pad so a short line never leaves the tail of a longer one behind it.
    -- Lua's string.format caps a field width at two digits, so %-300s is rejected. Pad by hand.
    local line = tostring(s):sub(1, 300)
    traceHandle:write(line .. string.rep(" ", 300 - #line))
    traceHandle:flush()
end

-- File helpers --------------------------------------------------------------------------

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

local function writeAtomic(path, tmp, content)
    local f = io.open(tmp, "wb")
    if not f then return false, "cannot open " .. tmp end
    f:write(content)
    f:close()
    os.remove(path)
    local ok, err = os.rename(tmp, path)
    if not ok then return false, tostring(err) end
    return true
end

-- Value serialisation --------------------------------------------------------------------

local MAX_DEPTH = 4
local MAX_ITEMS = 200

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local encodeValue

local function encodeUObject(obj)
    local out = { __object = obj:GetFullName() }
    out.address = safe(function() return obj:GetAddress() end)
    return out
end

local function encodeArray(arr, depth)
    local out, n = {}, 0
    local count = safe(function() return arr:GetArrayNum() end) or 0
    arr:ForEach(function(i, elem)
        n = n + 1
        if n > MAX_ITEMS then return true end
        out[n] = encodeValue(safe(function() return elem:get() end), depth + 1)
    end)
    if count > MAX_ITEMS then out[MAX_ITEMS + 1] = string.format("<%d more>", count - MAX_ITEMS) end
    return out
end

-- The UE4SS UScriptStruct wrapper does not expose its own type, so probe common field names.
local STRUCT_FIELDS = { "X", "Y", "Z", "W", "Pitch", "Yaw", "Roll", "R", "G", "B", "A",
                        "Min", "Max", "AssetPath", "SubPathString", "PackageName", "AssetName",
                        "TagName", "Value", "Guid", "B", "C", "D", "Key" }

local function encodeStruct(s, depth)
    local out = { __struct = true }
    out.address = safe(function() return s:GetStructAddress() end)
    for _, k in ipairs(STRUCT_FIELDS) do
        local v = safe(function() return s[k] end)
        if v ~= nil then out[k] = encodeValue(v, depth + 1) end
    end
    return out
end

function encodeValue(v, depth)
    depth = depth or 0
    local tv = type(v)
    if tv == "nil" or tv == "boolean" or tv == "number" or tv == "string" then return v end
    if depth > MAX_DEPTH then return "<depth>" end
    if tv == "table" then
        local out = {}
        local n = 0
        for k, val in pairs(v) do
            n = n + 1
            if n > MAX_ITEMS then out["<more>"] = true; break end
            out[type(k) == "number" and k or tostring(k)] = encodeValue(val, depth + 1)
        end
        return out
    end
    if tv == "userdata" then
        local kind = safe(function() return v:type() end)
        if kind == "FName" or kind == "FString" or kind == "FText" then
            return safe(function() return v:ToString() end) or tostring(v)
        end
        if kind == "TArray" then return encodeArray(v, depth) end
        if kind == "UScriptStruct" then return encodeStruct(v, depth) end
        if kind == "RemoteUnrealParam" or kind == "LocalUnrealParam" then
            return encodeValue(safe(function() return v:get() end), depth)
        end
        if kind == "FWeakObjectPtr" then
            return encodeValue(safe(function() return v:Get() end), depth)
        end
        if v.IsValid and v.GetFullName then
            if not safe(function() return v:IsValid() end) then return { __object = "<invalid>" } end
            return encodeUObject(v)
        end
        return { __type = kind or "userdata", str = tostring(v) }
    end
    return tostring(v)
end

-- Helper library exposed to eval snippets as HFB -------------------------------------------

HFB = {}
HFB.encode = encodeValue
HFB.trace = trace

-- Resolve an object reference string:
--   "/Script/Pkg.Object"    full path, via StaticFindObject
--   "first:ClassName"       first live instance of that short class name
--   "cdo:/Script/Pkg.Class" class default object of that class
function HFB.resolve(ref)
    if type(ref) ~= "string" then return ref end
    local first = ref:match("^first:(.+)$")
    if first then
        local o = FindFirstOf(first)
        if o and o:IsValid() then return o end
        error("no live instance of " .. first)
    end
    local cdo = ref:match("^cdo:(.+)$")
    if cdo then
        local cls = StaticFindObject(cdo)
        if not cls or not cls:IsValid() then error("class not found: " .. cdo) end
        return cls:GetCDO()
    end
    local o = StaticFindObject(ref)
    if not o or not o:IsValid() then error("object not found: " .. ref) end
    return o
end

-- All reflected properties of an object, walking the super chain. Returns {name, type, value}.
-- Reading a SoftObjectProperty has hard-crashed the game (null dereference inside UE4SS's own
-- property reader, uncatchable by pcall). Most soft reads are harmless and yield a wrapper whose
-- fields all probe nil anyway, so the information is worth almost nothing and the downside is the
-- user's session. Skipped unless readSoft is passed explicitly.
local UNSAFE_TYPES = { SoftObjectProperty = true, SoftClassProperty = true }

function HFB.props(ref, includeSuper, readSoft)
    local obj = HFB.resolve(ref)
    -- Defaults to false. A full super-chain walk on a live actor has crashed the game with a null
    -- dereference inside UE4SS's own property reader, which no pcall can catch.
    if includeSuper == nil then includeSuper = false end
    local out, seen = {}, {}
    local cls = obj:GetClass()
    while cls and cls:IsValid() do
        local cname = safe(function() return cls:GetFName():ToString() end)
        cls:ForEachProperty(function(prop)
            local name = prop:GetFName():ToString()
            if not seen[name] then
                seen[name] = true
                local ptype = safe(function() return prop:GetClass():GetFName():ToString() end)
                trace("props " .. tostring(cname) .. "." .. name .. " (" .. tostring(ptype) .. ")")
                -- Branch explicitly. The `ok and encode(val) or "<error>"` idiom misreports
                -- every property that encodes to false or nil, because the and-branch is falsy.
                local encoded
                if UNSAFE_TYPES[ptype] and not readSoft then
                    encoded = "<skipped: " .. ptype .. ">"
                else
                    local ok, val = pcall(function() return obj[name] end)
                    if ok then
                        encoded = encodeValue(val, 1)
                    else
                        encoded = "<error: " .. tostring(val) .. ">"
                    end
                end
                out[#out + 1] = { name = name, type = ptype, value = encoded }
            end
        end)
        if not includeSuper then break end
        cls = safe(function() return cls:GetSuperStruct() end)
    end
    return { object = obj:GetFullName(), class = obj:GetClass():GetFullName(), properties = out }
end

-- Reflected UFunctions on the object's class chain.
function HFB.funcs(ref)
    local obj = HFB.resolve(ref)
    local out, seen = {}, {}
    local cls = obj:GetClass()
    while cls and cls:IsValid() do
        cls:ForEachFunction(function(fn)
            local name = fn:GetFName():ToString()
            if not seen[name] then
                seen[name] = true
                out[#out + 1] = { name = name, owner = cls:GetFName():ToString(),
                                  flags = safe(function() return fn:GetFunctionFlags() end) }
            end
        end)
        cls = safe(function() return cls:GetSuperStruct() end)
    end
    return out
end

-- UE4SS hands back a bogus "<invalid>" UObject for a name the class does not declare, instead of
-- failing. A typo therefore reads back as something that looks like data, and a WRITE silently does
-- nothing while reporting success. Both are checked against the reflection first.
local function declaresProperty(cls, name)
    while cls and cls:IsValid() do
        local found = false
        cls:ForEachProperty(function(prop)
            if prop:GetFName():ToString() == name then found = true end
        end)
        if found then return true end
        cls = safe(function() return cls:GetSuperStruct() end)
    end
    return false
end

local function declaresFunction(cls, name)
    while cls and cls:IsValid() do
        local found = false
        cls:ForEachFunction(function(fn)
            if fn:GetFName():ToString() == name then found = true end
        end)
        if found then return true end
        cls = safe(function() return cls:GetSuperStruct() end)
    end
    return false
end

local function requireProperty(obj, name)
    local cls = obj:GetClass()
    if declaresProperty(cls, name) then return end
    local cname = tostring(safe(function() return cls:GetFName():ToString() end))
    if declaresFunction(cls, name) then
        error("'" .. name .. "' is a UFunction on " .. cname .. ", not a property; call it with call_function")
    end
    error("no property '" .. name .. "' on " .. cname .. "; inspect_object lists the ones it has")
end

function HFB.get(ref, prop)
    local obj = HFB.resolve(ref)
    requireProperty(obj, prop)
    return obj[prop]
end

-- Returns { previous, current }. Writes are never undone, so handing back the prior value is what
-- makes a restore possible without a separate read first.
function HFB.set(ref, prop, value)
    local obj = HFB.resolve(ref)
    requireProperty(obj, prop)
    local okPrev, prev = pcall(function() return obj[prop] end)
    local out = {}
    if okPrev then
        out.previous = encodeValue(prev, 1)
    else
        out.previous = "<unreadable: " .. tostring(prev) .. ">"
    end
    obj[prop] = value
    out.current = encodeValue(obj[prop], 1)
    return out
end

function HFB.call(ref, fname, args)
    local obj = HFB.resolve(ref)
    local fn = obj[fname]
    if fn == nil then error("no function " .. fname .. " on " .. obj:GetFullName()) end
    return fn(obj, table.unpack(args or {}))
end

-- Live instances of a short class name.
function HFB.objects(className, limit)
    limit = limit or 100
    local found = FindAllOf(className) or {}
    local out = {}
    for i, o in ipairs(found) do
        if i > limit then out[#out + 1] = string.format("<%d more>", #found - limit); break end
        out[#out + 1] = o:GetFullName()
    end
    return { count = #found, objects = out }
end

-- Loaded reflected types (Class, BlueprintGeneratedClass, ScriptStruct, Enum) matching a pattern.
function HFB.types(pattern, limit)
    limit = limit or 200
    local out, total = {}, 0
    ForEachUObject(function(obj)
        if not obj:IsValid() then return end
        local cls = obj:GetClass()
        if not cls or not cls:IsValid() then return end
        local cn = cls:GetFName():ToString()
        if cn == "Class" or cn == "BlueprintGeneratedClass" or cn == "ScriptStruct" or cn == "Enum" then
            local n = obj:GetFName():ToString()
            if not pattern or n:find(pattern) then
                total = total + 1
                if total <= limit then out[total] = { name = n, kind = cn, path = obj:GetFullName() } end
            end
        end
    end)
    return { count = total, types = out }
end

function HFB.console(cmd)
    local pc = UEHelpers.GetPlayerController()
    local world = UEHelpers.GetWorld()
    local ksl = UEHelpers.GetKismetSystemLibrary()
    if ksl and ksl:IsValid() and world and world:IsValid() then
        ksl:ExecuteConsoleCommand(world, cmd, pc)
        return "executed via KismetSystemLibrary"
    end
    if pc and pc:IsValid() then
        pc:ConsoleCommand(cmd, false)
        return "executed via PlayerController"
    end
    error("no world or player controller to run a console command in")
end

function HFB.world()
    local pc = FindFirstOf("PlayerController")
    local out = {}
    if pc and pc:IsValid() then
        out.playerController = pc:GetFullName()
        local pawn = safe(function() return pc.Pawn end)
        out.pawn = (pawn and pawn:IsValid()) and pawn:GetFullName() or nil
        local world = safe(function() return pc:GetWorld() end)
        out.world = (world and world:IsValid()) and world:GetFullName() or nil
    end
    local gi = safe(function() return UEHelpers.GetGameInstance() end)
    out.gameInstance = (gi and gi:IsValid()) and gi:GetFullName() or nil
    local gm = safe(function() return UEHelpers.GetGameModeBase() end)
    out.gameMode = (gm and gm:IsValid()) and gm:GetFullName() or nil
    return out
end

local dumpers = {
    usmap = function() DumpUSMAP(true) end,
    jmap = function() DumpJMAP(true) end,
    uht = function() GenerateUHTCompatibleHeaders() end,
    cxx = function() GenerateSDK() end,
    actors = function() DumpAllActors() end,
    objects = function() DumpAllObjects() end,
    static_meshes = function() DumpStaticMeshes() end,
}
function HFB.dump(kind)
    local fn = dumpers[kind]
    if not fn then error("unknown dump kind " .. tostring(kind)) end
    fn()
    return "dump " .. kind .. " written to the ue4ss directory"
end

-- Request handling -----------------------------------------------------------------------

local function runEval(code)
    local output = {}
    local env = setmetatable({
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
            output[#output + 1] = table.concat(parts, "\t")
        end,
    }, { __index = _G })
    local chunk, err = load(code, "=bridge", "t", env)
    if not chunk then return false, nil, output, "compile: " .. tostring(err) end
    local ok, result = xpcall(chunk, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
    if not ok then return false, nil, output, result end
    local okEnc, encoded = pcall(encodeValue, result, 0)
    if not okEnc then return true, tostring(result), output, "encode: " .. tostring(encoded) end
    return true, encoded, output, nil
end

local busy = false
local handled = 0

local function respond(id, ok, result, output, err, started)
    local body = json.encode({
        id = id, ok = ok, result = result, output = output, error = err,
        ms = math.floor((os.clock() - started) * 1000),
    })
    local wrote, werr = writeAtomic(RESPONSE, RESPONSE_TMP, body)
    if not wrote then log("response write failed: %s", tostring(werr)) end
end

local function handle(req)
    local started = os.clock()
    handled = handled + 1
    if req.op == "ping" then
        respond(req.id, true, { pong = true, handled = handled, poll_ms = POLL_MS }, {}, nil, started)
        return
    end
    if req.op ~= "eval" or type(req.code) ~= "string" then
        respond(req.id, false, nil, {}, "unknown op or missing code", started)
        return
    end
    busy = true
    trace("eval id=" .. tostring(req.id) .. " " .. req.code:gsub("%s+", " "))
    ExecuteInGameThread(function()
        local ok, result, output, err = runEval(req.code)
        -- Cleared only on the way out, so a crash leaves the in-flight line on disk.
        trace("idle after id=" .. tostring(req.id))
        respond(req.id, ok, result, output, err, started)
        busy = false
    end)
end

-- Reload this file in place without restarting the game: HFB.reload() from any bridge eval.
-- Each load bumps the generation; an older poll loop sees the bump and retires, so only one
-- loop ever reads the request file.
local MOD_PATH = "ue4ss/Mods/HFBridge/scripts/main.lua"   -- relative to Binaries\Win64
HFB_GENERATION = (HFB_GENERATION or 0) + 1
local myGeneration = HFB_GENERATION
function HFB.reload()
    dofile(MOD_PATH)
    return "reloaded, generation " .. tostring(HFB_GENERATION)
end

LoopAsync(POLL_MS, function()
    if myGeneration ~= HFB_GENERATION then return true end
    if busy then return false end
    local raw = readFile(REQUEST)
    if not raw then return false end
    os.remove(REQUEST)
    local ok, req = pcall(json.decode, raw)
    if not ok or type(req) ~= "table" then
        respond("?", false, nil, {}, "bad request json: " .. tostring(req), os.clock())
        return false
    end
    local okH, err = pcall(handle, req)
    if not okH then
        busy = false
        respond(req.id, false, nil, {}, "handler: " .. tostring(err), os.clock())
    end
    return false
end)

log("ready (generation %d), polling %s every %d ms", myGeneration, REQUEST, POLL_MS)
