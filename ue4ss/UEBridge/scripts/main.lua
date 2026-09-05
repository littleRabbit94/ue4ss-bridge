-- UEBridge: a file-based request/response channel so an external process (the ue-bridge MCP
-- server, or anything else that can write a file) can run Lua inside a live UE4SS game without a
-- relaunch per question. Game-agnostic: nothing here names a game or an install path.
--
--   external  ->  writes  <ue4ss>\bridge\request.json    {"id":..,"op":"eval","code":".."}
--   this mod  ->  polls it, runs the code on the game thread, writes response.json
--
-- The poll is a timer (LoopAsync), not a per-tick hook, and it only does work when the request
-- file exists. All game-object access happens inside ExecuteInGameThread. The mod opens no
-- sockets and starts no processes; everything it does is in reply to a file in its own folder.
--
-- Wire format (protocol 1)
--   request : {"id": string, "op": "hello"|"ping"|"eval"|"batch", "code": string, "calls": [..]}
--   response: {"id", "ok": bool, "result": any, "output": [string], "error": string|null,
--              "ms": n, "protocol": 1}
--
-- Eval snippets run in an environment that inherits _G plus the UEB helper table below. Whatever
-- the chunk returns is serialised: UObjects become {"__object": fullname, "address": n}, FName /
-- FString become strings, TArrays become lists, structs are walked through their reflected type.

local VERSION = "1.0.0"
local PROTOCOL = 1
local MOD_NAME = "UEBridge"

-- Paths -----------------------------------------------------------------------------------
-- Lua's io resolves relative paths against the process working directory, which is
-- Binaries\Win64 (the exe directory), NOT the ue4ss folder. Resolve an absolute path so the
-- bridge always lands in <ue4ss>\bridge regardless of how the game was launched.
local function ue4ssDir()
    local ok, dirs = pcall(IterateGameDirectories)
    local win64 = ok and dirs and dirs.Game and dirs.Game.Binaries and dirs.Game.Binaries.Win64
    if win64 and win64.__absolute_path then
        return win64.__absolute_path .. "\\ue4ss"
    end
    return "ue4ss"
end
local UE4SS_DIR = ue4ssDir()
local MOD_DIR = UE4SS_DIR .. "\\Mods\\" .. MOD_NAME
local MOD_PATH = MOD_DIR .. "\\scripts\\main.lua"

package.path = MOD_DIR .. "\\scripts\\?.lua;" .. package.path
local json = require("json")
local UEHelpers = require("UEHelpers")

local function log(fmt, ...)
    print("[" .. MOD_NAME .. "] " .. string.format(fmt, ...) .. "\n")
end

-- Settings ----------------------------------------------------------------------------------
-- scripts\settings.lua is optional and user-editable; every key has a default.
--   enabled       false turns the bridge off without removing the mod.
--   poll_ms       how often the request file is checked.
--   allow_eval    false refuses raw Lua ("eval"); the structured "batch" ops still work.
--   allow_writes  false refuses anything that changes state: set, call, console, and eval.
--   bridge_dir    override the request/response folder (absolute path).
-- The file lives in scripts\ because mod managers that deploy only <mod>\scripts would otherwise
-- drop it. A copy at the mod root is still honoured first.
local SETTINGS = { enabled = true, poll_ms = 250, allow_eval = true, allow_writes = true, bridge_dir = nil }
do
    local chunk = loadfile(MOD_DIR .. "\\settings.lua")
                  or loadfile(MOD_DIR .. "\\scripts\\settings.lua")
    if chunk then
        local ok, user = pcall(chunk)
        if ok and type(user) == "table" then
            for k, v in pairs(user) do
                if SETTINGS[k] ~= nil or k == "bridge_dir" then SETTINGS[k] = v end
            end
        else
            log("settings.lua did not return a table (%s); using defaults", tostring(user))
        end
    end
end
if not SETTINGS.allow_writes then SETTINGS.allow_eval = false end

local DIR = SETTINGS.bridge_dir or (UE4SS_DIR .. "\\bridge")
local REQUEST = DIR .. "/request.json"
local RESPONSE = DIR .. "/response.json"
local RESPONSE_TMP = DIR .. "/response.tmp"
local POLL_MS = math.max(50, tonumber(SETTINGS.poll_ms) or 250)

-- One line, rewritten in place and flushed, naming the operation in flight. A native crash cannot
-- be caught by pcall; the server reads this after a timeout to report what was running.
local TRACE = DIR .. "/lastop.log"
local traceHandle, traceOpened = nil, false
local function trace(s)
    if not traceOpened then traceHandle = io.open(TRACE, "wb") traceOpened = true end
    if not traceHandle then return end
    traceHandle:seek("set", 0)
    -- Pad to a fixed width so a short line overwrites a longer one. (%-300s exceeds format's width cap.)
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

-- A batched props result nests values two levels deeper than a direct one; 6 keeps them intact.
local MAX_DEPTH = 6
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

local UNSAFE_TYPES = { SoftObjectProperty = true, SoftClassProperty = true }

-- Probe list for a struct whose type does not resolve.
local STRUCT_FIELDS = { "X", "Y", "Z", "W", "Pitch", "Yaw", "Roll", "R", "G", "B", "A",
                        "Min", "Max", "AssetPath", "SubPathString", "PackageName", "AssetName",
                        "TagName", "Value", "Guid", "B", "C", "D", "Key" }

-- A struct value's GetFullName() names its type ("ScriptStruct /Script/CoreUObject.Vector"); that
-- path resolves to a UScriptStruct whose properties walk like a class. Cached per type.
local STRUCT_TYPE_CACHE = {}

local function structType(s)
    local ok, full = pcall(function() return s:GetFullName() end)
    if not ok or type(full) ~= "string" then return nil, nil end
    local path = full:match("^%S+%s+(.+)$") or full
    local hit = STRUCT_TYPE_CACHE[path]
    if hit ~= nil then
        if hit == false then return nil, path end
        return hit, path
    end
    local st = StaticFindObject(path)
    if st and safe(function() return st:IsValid() end) then
        STRUCT_TYPE_CACHE[path] = st
        return st, path
    end
    STRUCT_TYPE_CACHE[path] = false
    return nil, path
end

-- Blueprint UserDefinedStruct fields carry a "_<n>_<32 hex>" suffix. Read by the raw reflected
-- name, report the readable one.
local function fieldName(n)
    local base, _, hex = n:match("^(.-)_(%d+)_(%x+)$")
    if base and #hex == 32 then return base end
    return n
end

local function encodeStruct(s, depth)
    local out = { __struct = true }
    out.address = safe(function() return s:GetStructAddress() end)
    local st, path = structType(s)
    out.__type = path
    if not st then
        out.__fields = "guessed"          -- type would not resolve; fall back to the probe list
        for _, k in ipairs(STRUCT_FIELDS) do
            local v = safe(function() return s[k] end)
            if v ~= nil then out[k] = encodeValue(v, depth + 1) end
        end
        return out
    end
    -- Walk the super chain: FVector_NetQuantize100 declares nothing itself and inherits X/Y/Z.
    local seen = {}
    while st and st:IsValid() do
        st:ForEachProperty(function(prop)
            local rawn = prop:GetFName():ToString()
            if seen[rawn] then return end
            seen[rawn] = true
            local ptype = safe(function() return prop:GetClass():GetFName():ToString() end)
            local key = fieldName(rawn)
            if UNSAFE_TYPES[ptype] then
                out[key] = "<skipped: " .. tostring(ptype) .. ">"
                return
            end
            local ok, v = pcall(function() return s[rawn] end)
            if ok then
                out[key] = encodeValue(v, depth + 1)
            else
                out[key] = "<error: " .. tostring(v) .. ">"
            end
        end)
        st = safe(function() return st:GetSuperStruct() end)
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

-- Helper library exposed to eval snippets as UEB -------------------------------------------

UEB = {}
UEB.encode = encodeValue
UEB.trace = trace
UEB.version = VERSION
UEB.protocol = PROTOCOL
UEB.settings = SETTINGS

-- Resolve an object reference string:
--   "/Script/Pkg.Object"    full path, via StaticFindObject
--   "first:ClassName"       first live instance of that short class name
--   "cdo:/Script/Pkg.Class" class default object of that class
function UEB.resolve(ref)
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

-- Reflected properties of an object as {name, type, value}. includeSuper defaults to false.
-- SoftObject/SoftClass reads are skipped unless readSoft: they have crashed the process inside
-- UE4SS's property reader, which no pcall can catch.
function UEB.props(ref, includeSuper, readSoft, pattern)
    local obj = UEB.resolve(ref)
    if pattern ~= nil then
        -- Validate here so a bad pattern is reported against the argument, not a property.
        local okPat = pcall(string.match, "probe", pattern)
        if not okPat then error("invalid Lua pattern: " .. tostring(pattern)) end
    end
    if includeSuper == nil then includeSuper = false end
    local out, seen = {}, {}
    local cls = obj:GetClass()
    while cls and cls:IsValid() do
        local cname = safe(function() return cls:GetFName():ToString() end)
        cls:ForEachProperty(function(prop)
            local name = prop:GetFName():ToString()
            if not seen[name] then
                seen[name] = true
                if pattern and not name:match(pattern) then return end
                local ptype = safe(function() return prop:GetClass():GetFName():ToString() end)
                trace("props " .. tostring(cname) .. "." .. name .. " (" .. tostring(ptype) .. ")")
                -- Explicit branches: `ok and x or y` misreports values that encode to false/nil.
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
function UEB.funcs(ref)
    local obj = UEB.resolve(ref)
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

-- UE4SS returns an "<invalid>" object for an undeclared property name and silently ignores writes
-- to one, so get/set check the reflection first.
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

local function requireWrites(what)
    if not SETTINGS.allow_writes then
        error(what .. " refused: allow_writes = false in " .. MOD_NAME .. "/scripts/settings.lua")
    end
end

function UEB.get(ref, prop)
    local obj = UEB.resolve(ref)
    requireProperty(obj, prop)
    return obj[prop]
end

-- Returns { previous, current }; previous is what a caller restores from.
function UEB.set(ref, prop, value)
    requireWrites("set")
    local obj = UEB.resolve(ref)
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

function UEB.call(ref, fname, args)
    requireWrites("call")
    local obj = UEB.resolve(ref)
    local fn = obj[fname]
    if fn == nil then error("no function " .. fname .. " on " .. obj:GetFullName()) end
    return fn(obj, table.unpack(args or {}))
end

-- Live instances of a short class name.
function UEB.objects(className, limit)
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
function UEB.types(pattern, limit)
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

function UEB.console(cmd)
    requireWrites("console")
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

function UEB.world()
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

-- What the server needs to know about this end before it does anything else.
function UEB.hello()
    return {
        mod = MOD_NAME, version = VERSION, protocol = PROTOCOL,
        poll_ms = POLL_MS, allow_eval = SETTINGS.allow_eval, allow_writes = SETTINGS.allow_writes,
        bridge_dir = DIR, ue4ss_dir = UE4SS_DIR,
    }
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

function UEB.dump(kind)
    local fn = dumpers[kind]
    if not fn then error("unknown dump kind " .. tostring(kind)) end
    fn()
    return "dump " .. kind .. " written to the ue4ss directory"
end

-- Several ops in one round trip, each pcall-fenced. Also the structured surface that stays
-- available when allow_eval is off.
local BATCH_OPS = {
    hello   = function(a) return UEB.hello() end,
    world   = function(a) return UEB.world() end,
    get     = function(a) return UEB.get(a.ref, a.name) end,
    set     = function(a) return UEB.set(a.ref, a.name, a.value) end,
    call    = function(a) return UEB.call(a.ref, a["function"], a.args) end,
    props   = function(a) return UEB.props(a.ref, a.include_super, a.read_soft, a.pattern) end,
    funcs   = function(a) return UEB.funcs(a.ref) end,
    objects = function(a) return UEB.objects(a.class_name, a.limit) end,
    types   = function(a) return UEB.types(a.pattern, a.limit) end,
    console = function(a) return UEB.console(a.command) end,
    dump    = function(a) return UEB.dump(a.kind) end,
    find    = function(a)
        local o = UEB.resolve(a.ref)
        return { object = o:GetFullName(), class = o:GetClass():GetFullName(), address = o:GetAddress() }
    end,
}

function UEB.batch(calls)
    if type(calls) ~= "table" then error("batch expects a list of calls") end
    local out = {}
    for i, c in ipairs(calls) do
        local op = tostring(c and c.op)
        local fn = BATCH_OPS[op]
        if not fn then
            local known = {}
            for k in pairs(BATCH_OPS) do known[#known + 1] = k end
            table.sort(known)
            out[i] = { op = op, ok = false, error = "unknown batch op '" .. op .. "'; known: " .. table.concat(known, ", ") }
        else
            trace("batch[" .. i .. "] " .. op)
            local ok, res = pcall(fn, c)
            if ok then out[i] = { op = op, ok = true, result = encodeValue(res, 1) }
            else out[i] = { op = op, ok = false, error = tostring(res) } end
        end
    end
    return out
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

-- ms is os.clock() CPU time, an approximation; Lua has no wall clock finer than a second.
local function respond(id, ok, result, output, err, started)
    local body = json.encode({
        id = id, ok = ok, result = result, output = output, error = err,
        ms = math.floor((os.clock() - started) * 1000), protocol = PROTOCOL,
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
    if req.op == "hello" then
        local info = UEB.hello()
        info.handled = handled
        respond(req.id, true, info, {}, nil, started)
        return
    end
    if req.op == "batch" then
        if type(req.calls) ~= "table" then
            respond(req.id, false, nil, {}, "batch needs a 'calls' list", started)
            return
        end
        busy = true
        trace("batch id=" .. tostring(req.id) .. " (" .. #req.calls .. " calls)")
        ExecuteInGameThread(function()
            local ok, result = pcall(UEB.batch, req.calls)
            trace("idle after id=" .. tostring(req.id))
            if ok then respond(req.id, true, result, {}, nil, started)
            else respond(req.id, false, nil, {}, tostring(result), started) end
            busy = false
        end)
        return
    end
    if req.op ~= "eval" or type(req.code) ~= "string" then
        respond(req.id, false, nil, {}, "unknown op or missing code", started)
        return
    end
    if not SETTINGS.allow_eval then
        respond(req.id, false, nil, {},
            "eval refused: allow_eval = false in " .. MOD_NAME .. "/scripts/settings.lua (batch ops still work)", started)
        return
    end
    busy = true
    trace("eval id=" .. tostring(req.id) .. " " .. req.code:gsub("%s+", " "))
    ExecuteInGameThread(function()
        local ok, result, output, err = runEval(req.code)
        trace("idle after id=" .. tostring(req.id))
        respond(req.id, ok, result, output, err, started)
        busy = false
    end)
end

-- UEB.reload() re-runs this file in place; the generation bump retires the previous poll loop.
UEB_GENERATION = (UEB_GENERATION or 0) + 1
local myGeneration = UEB_GENERATION
function UEB.reload()
    dofile(MOD_PATH)
    return "reloaded, generation " .. tostring(UEB_GENERATION)
end

if not SETTINGS.enabled then
    log("disabled by scripts/settings.lua (enabled = false); not polling")
    return
end

LoopAsync(POLL_MS, function()
    if myGeneration ~= UEB_GENERATION then return true end
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

log("v%s ready (protocol %d, generation %d), polling %s every %d ms; eval=%s writes=%s",
    VERSION, PROTOCOL, myGeneration, REQUEST, POLL_MS,
    tostring(SETTINGS.allow_eval), tostring(SETTINGS.allow_writes))
