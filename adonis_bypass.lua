local CONFIG = {

    PREFIX = "knife.lua",

    VERSION = "1.0.0",

    IDENTITY = 7,

    SCAN_IDENTITY = 2,

    MONITOR_INTERVAL = 30,
    DETECTION_RETRIES = 30,
    DETECTION_RETRY_DELAY = 0.5,

    IDEMPOTENT = true,

    YIELD_ON_INSPECT = true,

    EVENT_LOG_LIMIT = 50,

    ENABLE_HOOK_HEALTH_CHECK = false,

    ENABLE_AUTO_RECOVERY = false,

    STATUS_HOTKEY = nil,

    STATE_KEY = "__AdonisBypassState_v1_0_0",

    INSTANCE_KEY = "__AdonisBypass_Instance",

    API_KEY = "AdonisBypass",

}

local DEBUG = false

local VERSION = CONFIG.VERSION

local EXECUTOR_ENV

local STATE

local INSTANCE

local instanceId

local alive = true

local RUN_STARTED_AT = tick()

-- Environment helpers

local function getExecutorEnv()

    if type(getgenv) ~= "function" then

        return nil

    end

    local success, env = pcall(getgenv)

    if success and type(env) == "table" then

        return env

    end

    return nil

end

EXECUTOR_ENV = getExecutorEnv()

local EXISTING_INSTANCE = EXECUTOR_ENV and rawget(EXECUTOR_ENV, CONFIG.INSTANCE_KEY)

local EXISTING_INSTANCE_LIVE = EXISTING_INSTANCE

    and type(EXISTING_INSTANCE.isAlive) == "function"

    and EXISTING_INSTANCE.isAlive()

local function getGlobal(name)

    local value = rawget(_G, name)

    if value ~= nil then

        return value

    end

    if EXECUTOR_ENV then

        return rawget(EXECUTOR_ENV, name)

    end

    return nil

end

local function setGlobal(name, value)

    if EXECUTOR_ENV then

        rawset(EXECUTOR_ENV, name, value)

        return true

    end

    rawset(_G, name, value)

    return true

end

local setthreadidentity = getGlobal("setthreadidentity")

local rawgetFn = getGlobal("rawget") or rawget

local typeofFn = getGlobal("typeof") or typeof

local function restoreIdentity()

    if type(setthreadidentity) == "function" then

        pcall(setthreadidentity, CONFIG.IDENTITY)

    end

end

local function countEntries(tbl)

    local count = 0

    for _ in pairs(tbl) do

        count += 1

    end

    return count

end

local function newWeakKeyTable()

    return setmetatable({}, { __mode = "k" })

end

local function waitForRuntimeReady()
    local deadline = os.clock() + 15

    while os.clock() < deadline do
        local loaded = false
        pcall(function()
            loaded = game:IsLoaded()
        end)

        local hasPlayer = false
        pcall(function()
            hasPlayer = game:GetService("Players").LocalPlayer ~= nil
        end)

        if loaded and hasPlayer then
            return true
        end

        task.wait(0.25)
    end

    return true
end

-- Logging and diagnostics

local function timestamp()

    return string.format("%.3f", tick() - RUN_STARTED_AT)

end

local function recordEvent(eventType, message, ...)

    if not STATE then

        return

    end

    local text

    if select("#", ...) > 0 then

        local success, result = pcall(string.format, message, ...)

        text = success and result or (tostring(message) .. " [format error: " .. tostring(result) .. "]")

    else

        text = tostring(message)

    end

    STATE.eventLog = STATE.eventLog or {}

    STATE.eventLog[#STATE.eventLog + 1] = {

        t = tick() - RUN_STARTED_AT,

        type = tostring(eventType),

        msg = text,

    }

    while #STATE.eventLog > CONFIG.EVENT_LOG_LIMIT do

        table.remove(STATE.eventLog, 1)

    end

end

local function shouldPrint(level)

    if DEBUG then

        return level == "STAGE" or level == "FATAL"

    end

    return level == "FATAL"

end

local function formatMessage(message, ...)

    if select("#", ...) == 0 then

        return tostring(message)

    end

    local success, result = pcall(string.format, message, ...)

    if success then

        return result

    end

    return tostring(message) .. " [format error: " .. tostring(result) .. "]"

end

local function printLog(level, message, ...)

    if not shouldPrint(level) then

        return

    end

    local text = formatMessage(message, ...)

    local marker = ""

    if level == "WARN" or level == "FATAL" then

        marker = "✗ "

    elseif level == "OK" then

        marker = "✓ "

    elseif level == "DEBUG" then

        marker = "DEBUG "

    end

    local line = string.format(

        "%s [%ss] %s%s",

        CONFIG.PREFIX,

        timestamp(),

        marker,

        text

    )

    if level == "WARN" or level == "FATAL" then

        warn(line)

    else

        print(line)

    end

end

local function stage(message, ...)

    local text = formatMessage(message, ...)

    recordEvent("stage", text)

    printLog("STAGE", "%s", text)

end

local function log(message, ...)

    printLog("INFO", message, ...)

end

local function ok(message, ...)

    printLog("OK", message, ...)

end

local function fail(message, ...)

    local text = formatMessage(message, ...)

    recordEvent("error", text)

    printLog("WARN", "%s", text)

end

local function fatal(message, ...)

    local text = formatMessage(message, ...)

    recordEvent("fatal", text)

    printLog("FATAL", "%s", text)

end

local function debugLog(message, ...)

    printLog("DEBUG", message, ...)

end

-- Development sanity checks stay silent unless a helper is missing.

local function selfCheck()

    assert(type(formatMessage) == "function", "formatMessage is unavailable")

    assert(type(printLog) == "function", "printLog is unavailable")

    assert(type(stage) == "function", "stage is unavailable")

    assert(type(getExecutorEnv) == "function", "getExecutorEnv is unavailable")

    assert(type(getGlobal) == "function", "getGlobal is unavailable")

end



-- Development check. Leave in place; it has no output on a healthy build.

selfCheck()

local function notifyFailure(reason)

    if DEBUG or not STATE or STATE.failureNotified then

        return false

    end

    STATE.failureNotified = true

    recordEvent("notification", "Failure notification requested: " .. tostring(reason or "unknown"))

    local success, err = pcall(function()

        game:GetService("StarterGui"):SetCore("SendNotification", {

            Title = "Adonis Bypass",

            Text = "Bypass failed. Try re-executing, or contact the script owner if the issue persists.",

            Duration = 8,

        })

    end)

    if not success then

        recordEvent("notification", "SetCore notification failed: " .. tostring(err))

        warn(CONFIG.PREFIX .. " Bypass failed. Try re-executing, or contact the script owner.")

    end

    return success

end

local function notifySuccess()

    if DEBUG or not STATE or STATE.firstRunShown then

        return false

    end

    STATE.firstRunShown = true

    recordEvent("notification", "Success notification requested")

    local success, err = pcall(function()

        game:GetService("StarterGui"):SetCore("SendNotification", {

            Title = "Adonis Bypass",

            Text = "Bypass installed successfully.",

            Duration = 4,

        })

    end)

    if not success then

        recordEvent("notification", "SetCore success notification failed: " .. tostring(err))

        warn(CONFIG.PREFIX .. " Bypass installed successfully.")

    end

    return success

end

local function dumpEvents()

    local events = STATE and STATE.eventLog or {}

    if DEBUG then

        print(CONFIG.PREFIX .. " ── EVENT LOG (" .. tostring(#events) .. ") ──")

        for _, event in ipairs(events) do

            print(string.format(

                "%s [%07.3fs] %-8s %s",

                CONFIG.PREFIX,

                tonumber(event.t) or 0,

                tostring(event.type),

                tostring(event.msg)

            ))

        end

    end

    return events

end

-- State

local function newState()

    return {

        schema = 5,

        version = VERSION,

        installed = false,

        degraded = false,

        monitorStarted = false,

        hotkeyStarted = false,

        scanned = 0,

        acFound = 0,

        blocked = 0,

        hooks = {

            Detected = false,

            RLocked = false,

            AddDetector = false,

            Launch = false,

        },

        wrapperCalls = {

            Detected = 0,

            RLocked = 0,

            AddDetector = 0,

            Launch = 0,

        },

        hookedFunctions = newWeakKeyTable(),

        originals = newWeakKeyTable(),

        wrappers = newWeakKeyTable(),

        metadata = newWeakKeyTable(),

        debugInfoTarget = nil,

        debugInfoOriginal = nil,

        debugInfoWrapper = nil,

        eventLog = {},

        lastError = nil,

        lastErrorTime = nil,

        instanceId = nil,

        failureNotified = false,

        firstRunShown = false,

    }

end

if EXECUTOR_ENV and not EXISTING_INSTANCE_LIVE then

    STATE = rawget(EXECUTOR_ENV, CONFIG.STATE_KEY)

end

if EXISTING_INSTANCE_LIVE or type(STATE) ~= "table" or STATE.schema ~= 5 then

    STATE = newState()

    if not EXISTING_INSTANCE_LIVE then

        setGlobal(CONFIG.STATE_KEY, STATE)

    end

end

-- Restore and lifecycle declarations

local restore

local startMonitor

local stopHotkey

local setupHotkey

local runBypass

local showStatus

local replaceCurrentInstance

local function clearHookMaps()

    STATE.hookedFunctions = newWeakKeyTable()

    STATE.originals = newWeakKeyTable()

    STATE.wrappers = newWeakKeyTable()

    STATE.metadata = newWeakKeyTable()

    for name in pairs(STATE.hooks) do

        STATE.hooks[name] = false

    end

end

-- Instance handle

local function makeInstance()

    local instanceId = string.format(

        "%d-%d",

        math.floor(tick() * 1000),

        math.random(1, 1000000000)

    )

    STATE.instanceId = instanceId

    local instance = {

        version = VERSION,

        startedAt = RUN_STARTED_AT,

        pid = instanceId,

        state = STATE,

    }

    instance.isAlive = function()

        return alive == true and instance.state == STATE

    end

    instance.status = function()

        return showStatus and showStatus(false) or {

            version = VERSION,

            instanceId = instanceId,

            alive = instance.isAlive(),

            installed = STATE.installed,

            degraded = STATE.degraded,

        }

    end

    instance.restore = function(silent)

        return restore(silent == true)

    end

    return instance, instanceId

end

INSTANCE, instanceId = makeInstance()

-- Public API


local HOOK_NAMES = {

    "Detected",

    "RLocked",

    "AddDetector",

    "Launch",

}

local API = {

    Version = VERSION,

    InstanceId = instanceId,

}

INSTANCE.api = API

showStatus = function(printOutput)

    local installedHooks = 0

    for _, name in ipairs(HOOK_NAMES or { "Detected", "RLocked", "AddDetector", "Launch" }) do

        if STATE.hooks[name] then

            installedHooks += 1

        end

    end

    local snapshot = {

        version = VERSION,

        instanceId = instanceId,

        alive = alive,

        installed = STATE.installed,

        degraded = STATE.degraded,

        scanned = STATE.scanned,

        acModules = STATE.acFound,

        blocked = STATE.blocked,

        installedHookTypes = installedHooks,

        configuredHookTypes = 4,

        debugInfoPatched = STATE.debugInfoOriginal ~= nil,

        monitorStarted = STATE.monitorStarted,

        hotkeyStarted = STATE.hotkeyStarted,

        lastError = STATE.lastError,

        lastErrorTime = STATE.lastErrorTime,

    }

    if printOutput then



        print(CONFIG.PREFIX .. " ── STATUS ──")

        for key, value in pairs(snapshot) do

            print(string.format("%s: %s", key, tostring(value)))

        end

    end

    return snapshot

end

API.Status = function()

    return showStatus(true)

end

API.Dump = function()

    return dumpEvents()

end

API.Unload = function()

    return restore(false)

end

API.Reload = function()

    return replaceCurrentInstance(true)

end

INSTANCE.api = API

-- Preflight validation


local REQUIRED_CRITICAL = {

    "getgc",

    "hookfunction",

    "newcclosure",

    "getrenv",

}

local REQUIRED_OPTIONAL = {

    "setthreadidentity",

}

local BUILTIN_FALLBACK = {

    rawget = rawget,

    typeof = typeof,

}

local REQUIRED_BUILTINS = {

    "rawget",

    "typeof",

}

local missingCritical = {}

for _, name in ipairs(REQUIRED_CRITICAL) do

    if type(getGlobal(name)) ~= "function" then

        missingCritical[#missingCritical + 1] = name

    end

end

if #missingCritical > 0 then

    for _, name in ipairs(missingCritical) do

        fatal("bypass failed: %s missing", name)

    end

    stage("bypass failed")

    notifyFailure("missing critical runtime API")

    alive = false

    return

end

local missingOptional = {}

for _, name in ipairs(REQUIRED_OPTIONAL) do

    if type(getGlobal(name)) ~= "function" then

        missingOptional[#missingOptional + 1] = name

        local warning = "bypass may not work: " .. name .. " isn't available"

        recordEvent("warning", warning)

        if DEBUG then

            warn(string.format("%s ⚠ %s", CONFIG.PREFIX, warning))

        end

    end

end

local missingBuiltins = {}

for _, name in ipairs(REQUIRED_BUILTINS) do

    if type(BUILTIN_FALLBACK[name]) ~= "function" then

        missingBuiltins[#missingBuiltins + 1] = name

    end

end

if #missingBuiltins > 0 then

    for _, name in ipairs(missingBuiltins) do

        fatal("bypass failed: %s missing", name)

    end

    stage("bypass failed")

    notifyFailure("missing required runtime builtin")

    alive = false

    return

end

local BUILTIN_COUNT = #REQUIRED_BUILTINS

local validationMessage = string.format(

    "Runtime APIs validated (%d critical, %d optional%s, %d builtin)",

    #REQUIRED_CRITICAL,

    #REQUIRED_OPTIONAL,

    #missingOptional > 0 and string.format(" [%d missing]", #missingOptional) or "",

    BUILTIN_COUNT

)

ok("%s", validationMessage)

recordEvent("status", validationMessage)

local getgc = getGlobal("getgc")

local hookfunction = getGlobal("hookfunction")

local newcclosure = getGlobal("newcclosure")

local getrenv = getGlobal("getrenv")

setthreadidentity = getGlobal("setthreadidentity")

rawgetFn = getGlobal("rawget") or BUILTIN_FALLBACK.rawget

typeofFn = getGlobal("typeof") or BUILTIN_FALLBACK.typeof

-- Detection

local function runDetection()

    local detection = {

        hierarchy = {},

        hierarchySet = {},

        globals = {},

        modules = {},

    }

    local function addUnique(set, list, value)

        if set[value] then

            return false

        end

        set[value] = true

        list[#list + 1] = value

        return true

    end

    local function safeFullName(object)

        local success, value = pcall(function()

            return object:GetFullName()

        end)

        return success and value or nil

    end

    local function scanContainer(container)

        if not container then

            return

        end

        local success, descendants = pcall(function()

            return container:GetDescendants()

        end)

        if not success or type(descendants) ~= "table" then

            return

        end

        for _, object in ipairs(descendants) do

            local objectName = object.Name

            if type(objectName) == "string"

                and objectName:lower():find("adonis", 1, true)

            then

                local path = safeFullName(object)

                if path then

                    addUnique(

                        detection.hierarchySet,

                        detection.hierarchy,

                        path

                    )

                end

            end

        end

    end

    log("Scanning game hierarchy...")

    pcall(function()

        scanContainer(game:GetService("ServerScriptService"))

    end)

    pcall(function()

        scanContainer(workspace)

    end)

    pcall(function()

        scanContainer(game:GetService("ReplicatedStorage"))

    end)

    local hasHierarchy = #detection.hierarchy > 0

    if hasHierarchy then

        for _, path in ipairs(detection.hierarchy) do

            ok("Hierarchy marker: %s", path)

        end

    else

        log("No Adonis hierarchy markers found.")

    end

    log("Checking globals...")

    local GLOBAL_MARKERS = {

        "Adonis_Debug_API",

        "Adonis",

        "AdonisHandler",

        "AdonisAC",

        "Adonis_Handler",

    }

    for _, name in ipairs(GLOBAL_MARKERS) do

        if getGlobal(name) ~= nil then

            detection.globals[#detection.globals + 1] = name

            ok("Found global: %s", name)

        end

    end

    local hasGlobal = #detection.globals > 0

    if not hasGlobal then

        log("No Adonis globals found.")

    end

    log("Scanning GC for AC modules...")

    pcall(setthreadidentity, CONFIG.SCAN_IDENTITY)

    local gcOk, gcObjects = pcall(getgc, true)

    if not gcOk or type(gcObjects) ~= "table" then

        restoreIdentity()

        return detection, false, "getgc(true) failed: " .. tostring(gcObjects)

    end

    local seenDetected = {}

    for _, object in next, gcObjects do

        STATE.scanned += 1

        if typeofFn(object) == "table" then

            local detected = rawgetFn(object, "Detected")

            local rlocked = rawgetFn(object, "RLocked")

            if type(detected) == "function" and type(rlocked) == "function" then

                if not seenDetected[detected] then

                    seenDetected[detected] = true

                    detection.modules[#detection.modules + 1] = object

                end

            end

        end

    end

    STATE.acFound = #detection.modules

    log(

        "Scanned %d GC objects, found %d unique AC module candidate(s).",

        STATE.scanned,

        STATE.acFound

    )


    restoreIdentity()

    return detection, true

end

-- Hook management

local function isAlreadyHooked(func)

    return type(func) == "function" and STATE.hookedFunctions[func] ~= nil

end

local function markBlocked(name)

    STATE.blocked += 1

    STATE.wrapperCalls[name] = (STATE.wrapperCalls[name] or 0) + 1

    recordEvent("hook", string.format(

        "Blocked %s invocation #%d",

        name,

        STATE.blocked

    ))

    if DEBUG then

        debugLog("Blocked %s invocation #%d", name, STATE.blocked)

    end

end

local function installHook(target, hookName, wrapper, moduleIndex)

    if type(target) ~= "function" then

        return false, hookName .. " is not a function"

    end

    if isAlreadyHooked(target) then

        local metadata = STATE.metadata[target]

        if metadata and metadata.name == hookName then

            return false, "already hooked"

        end

        return false, "already tracked by " .. tostring(metadata and metadata.name or "another hook")

    end

    local success, previous = pcall(function()

        return hookfunction(target, wrapper)

    end)

    if not success then

        return false, tostring(previous)

    end

    if type(previous) ~= "function" then

        previous = nil

    end

    STATE.hookedFunctions[target] = true

    STATE.originals[target] = previous

    STATE.wrappers[target] = wrapper

    STATE.metadata[target] = {

        name = hookName,

        module = moduleIndex,

    }

    recordEvent("hook", string.format(

        "Installed %s on module #%d",

        hookName,

        moduleIndex

    ))

    return true, previous

end

local function makeWrapper(name, original)

    if name == "Detected" then

        return newcclosure(function(Action, Info, NoCrash)


            if Action == "_" and NoCrash == true then

                if type(original) == "function" then

                    return original(Action, Info, NoCrash)

                end

                return true

            end

            markBlocked("Detected")

            if DEBUG and Action ~= "_" then

                debugLog("Detected action: %s", tostring(Action))

            end

            return true

        end)

    elseif name == "RLocked" then

        return newcclosure(function(...)

            markBlocked("RLocked")

            return true

        end)

    elseif name == "AddDetector" then

        return newcclosure(function(...)

            markBlocked("AddDetector")

            return nil

        end)

    elseif name == "Launch" then

        return newcclosure(function(...)

            markBlocked("Launch")

            return nil

        end)

    end

    return nil

end

local function hookModules(modules)

    for moduleIndex, module in ipairs(modules) do

        log("Processing AC module #%d...", moduleIndex)

        for _, hookName in ipairs(HOOK_NAMES) do

            local target = rawgetFn(module, hookName)

            if target ~= nil then

                local wrapper = makeWrapper(hookName, target)

                if wrapper then

                    local success, result = installHook(

                        target,

                        hookName,

                        wrapper,

                        moduleIndex

                    )

                    if success then

                        STATE.hooks[hookName] = true

                        ok("Module #%d: Hooked %s", moduleIndex, hookName)

                    elseif result == "already hooked" then

                        STATE.hooks[hookName] = true

                        log("Module #%d: %s already hooked.", moduleIndex, hookName)

                    else

                        fail(

                            "Module #%d: %s — %s",

                            moduleIndex,

                            hookName,

                            tostring(result)

                        )

                    end

                else

                    fail(

                        "Module #%d: could not create wrapper for %s",

                        moduleIndex,

                        hookName

                    )

                end

            end

        end

    end

end

-- debug.info

local function patchDebugInfo()

    if STATE.debugInfoOriginal ~= nil then

        return true, "already patched"

    end

    local envOk, renv = pcall(getrenv)

    if not envOk or type(renv) ~= "table" or type(renv.debug) ~= "table" then

        return false, "debug environment unavailable"

    end

    local originalInfo = renv.debug.info

    if type(originalInfo) ~= "function" then

        return false, "debug.info is not a function"

    end

    local wrapper

    wrapper = newcclosure(function(...)

        local firstArg = ...

        if STATE.hookedFunctions[firstArg] then

            if CONFIG.YIELD_ON_INSPECT

                and type(coroutine.isyieldable) == "function"

                and coroutine.isyieldable()

            then

                return coroutine.yield()

            end

            return nil

        end

        if type(STATE.debugInfoOriginal) == "function" then

            return STATE.debugInfoOriginal(...)

        end

        return nil

    end)

    local hookOk, hookResult = pcall(function()

        return hookfunction(originalInfo, wrapper)

    end)

    if not hookOk then

        return false, tostring(hookResult)

    end

    if type(hookResult) ~= "function" then

        return false, "hookfunction(debug.info) did not return the original function"

    end

    STATE.debugInfoTarget = originalInfo

    STATE.debugInfoOriginal = hookResult

    STATE.debugInfoWrapper = wrapper

    recordEvent("hook", "Patched debug.info")

    return true

end

-- Restore

restore = function(silent)


    alive = false

    STATE.monitorStarted = false

    STATE.installed = false

    STATE.degraded = false

    recordEvent("restore", "Restore requested; instance marked dead before unhooking.")

    if type(stopHotkey) == "function" then

        pcall(stopHotkey)

    end

    local restored = 0

    local failed = 0

    for target, previous in pairs(STATE.originals) do

        if type(target) == "function" and type(previous) == "function" then

            local success, err = pcall(function()

                hookfunction(target, previous)

            end)

            if success then

                restored += 1

            else

                failed += 1

                recordEvent("restore", string.format(

                    "Could not restore %s: %s",

                    tostring(STATE.metadata[target] and STATE.metadata[target].name),

                    tostring(err)

                ))

                if not silent then

                    fail(

                        "Could not restore %s: %s",

                        tostring(STATE.metadata[target] and STATE.metadata[target].name),

                        tostring(err)

                    )

                end

            end

        end

    end

    if STATE.debugInfoTarget

        and STATE.debugInfoOriginal

        and type(STATE.debugInfoTarget) == "function"

        and type(STATE.debugInfoOriginal) == "function"

    then

        local success, err = pcall(function()

            hookfunction(STATE.debugInfoTarget, STATE.debugInfoOriginal)

        end)

        if success then

            restored += 1

        else

            failed += 1

            recordEvent("restore", "Could not restore debug.info: " .. tostring(err))

            if not silent then

                fail("Could not restore debug.info: %s", tostring(err))

            end

        end

    end

    clearHookMaps()

    STATE.debugInfoTarget = nil

    STATE.debugInfoOriginal = nil

    STATE.debugInfoWrapper = nil

    STATE.monitorStarted = false

    STATE.hotkeyStarted = false

    STATE.installed = false

    if EXECUTOR_ENV then

        if rawget(EXECUTOR_ENV, CONFIG.STATE_KEY) == STATE then

            rawset(EXECUTOR_ENV, CONFIG.STATE_KEY, STATE)

        end

        if rawget(EXECUTOR_ENV, CONFIG.INSTANCE_KEY) == INSTANCE then

            rawset(EXECUTOR_ENV, CONFIG.INSTANCE_KEY, nil)

        end

        if rawget(EXECUTOR_ENV, CONFIG.API_KEY) == API then

            rawset(EXECUTOR_ENV, CONFIG.API_KEY, nil)

        end

        if rawget(EXECUTOR_ENV, "AdonisBypass_Dump") == API.Dump then

            rawset(EXECUTOR_ENV, "AdonisBypass_Dump", nil)

        end

    end

    recordEvent(

        "restore",

        string.format("Restore complete: %d restored, %d failed.", restored, failed)

    )

    if not silent then

        log(

            "Restore complete: %d function hook(s) restored, %d failure(s).",

            restored,

            failed

        )

    end

    return failed == 0

end

-- Monitor / health scaffold

startMonitor = function()

    if not DEBUG then

        return

    end

    if STATE.monitorStarted then

        log("Live monitor already running; not spawning another.")

        return

    end

    STATE.monitorStarted = true

    log("Monitor started — reporting every %d seconds.", CONFIG.MONITOR_INTERVAL)

    task.spawn(function()

        while STATE.monitorStarted and alive do

            task.wait(CONFIG.MONITOR_INTERVAL)

            if not STATE.monitorStarted or not alive then

                break

            end

            log(

                "Status | Blocks:%d | D:%s R:%s A:%s L:%s | Hooks:%d",

                STATE.blocked,

                STATE.hooks.Detected and "✓" or "✗",

                STATE.hooks.RLocked and "✓" or "✗",

                STATE.hooks.AddDetector and "✓" or "✗",

                STATE.hooks.Launch and "✓" or "✗",

                countEntries(STATE.hookedFunctions)

            )

        end

    end)

end

local function startHealthScaffold()

    if not DEBUG or not CONFIG.ENABLE_HOOK_HEALTH_CHECK then

        return

    end

    if CONFIG.ENABLE_AUTO_RECOVERY then

        fail("Auto-recovery is configured, but recovery remains disabled pending target-specific validation.")

    else

        log("Hook health checking requested; recovery remains disabled.")

end

-- Optional status hotkey

setupHotkey = function()

    if not DEBUG or CONFIG.STATUS_HOTKEY == nil or STATE.hotkeyStarted then

        return

    end

    local success, UserInputService = pcall(function()

        return game:GetService("UserInputService")

    end)

    if not success or not UserInputService then

        fail("Could not initialize status hotkey.")

        return

    end

    local connection

    connection = UserInputService.InputBegan:Connect(function(input, processed)

        if processed or not alive then

            return

        end

        if input.KeyCode == CONFIG.STATUS_HOTKEY then

            API.Status()

        end

    end)

    STATE.hotkeyConnection = connection

    STATE.hotkeyStarted = true

end

stopHotkey = function()

    if STATE.hotkeyConnection then

        pcall(function()

            STATE.hotkeyConnection:Disconnect()

        end)

        STATE.hotkeyConnection = nil

    end

    STATE.hotkeyStarted = false

end

-- Instance replacement

replaceCurrentInstance = function(silent)


    local current = EXECUTOR_ENV and rawget(EXECUTOR_ENV, CONFIG.INSTANCE_KEY)

    local oldInstance

    if current and type(current.isAlive) == "function" and current.isAlive() then

        oldInstance = current

    else

        oldInstance = INSTANCE

    end

    if not oldInstance or type(oldInstance.restore) ~= "function" then

        return false, "no live instance available for replacement"

    end

    recordEvent("reload", "Re-execution detected, old instance killed")

    if DEBUG then

        stage("existing instance detected — replacing")

    end

    local restored, restoreError = pcall(oldInstance.restore, true)

    if not restored then

        recordEvent("reload", "Old instance restore raised: " .. tostring(restoreError))

    elseif oldInstance.state and type(oldInstance.state) == "table" then

        oldInstance.state.installed = false

        oldInstance.state.degraded = true

    end

    if EXECUTOR_ENV and rawget(EXECUTOR_ENV, CONFIG.INSTANCE_KEY) == oldInstance then

        rawset(EXECUTOR_ENV, CONFIG.INSTANCE_KEY, nil)

    end


    STATE = newState()

    STATE.eventLog[1] = {

        t = 0,

        type = "reload",

        msg = "Re-execution detected, old instance killed",

    }

    RUN_STARTED_AT = tick()

    alive = true

    INSTANCE, instanceId = makeInstance()

    API.Version = VERSION

    API.InstanceId = instanceId

    INSTANCE.api = API

    if EXECUTOR_ENV then

        rawset(EXECUTOR_ENV, CONFIG.STATE_KEY, STATE)

        rawset(EXECUTOR_ENV, CONFIG.INSTANCE_KEY, INSTANCE)

        rawset(EXECUTOR_ENV, CONFIG.API_KEY, API)

        rawset(EXECUTOR_ENV, "AdonisBypass_Dump", API.Dump)

    end

    local started, result = runBypass(true, oldInstance)

    if not started then

        recordEvent("reload", "Replacement completed without a fully installed instance.")

    end

    return started, result

end

-- Main runner

local function showSummary()

    local installedHooks = 0

    local configuredHooks = #HOOK_NAMES

    for _, name in ipairs(HOOK_NAMES) do

        if STATE.hooks[name] then

            installedHooks += 1

        end

    end

    local uniqueHookCount = countEntries(STATE.hookedFunctions)

    log("GC scanned             : %d", STATE.scanned)

    log("AC modules             : %d", STATE.acFound)

    log("Hook types installed   : %d/%d", installedHooks, configuredHooks)

    log("Unique function hooks  : %d", uniqueHookCount)

    log("debug.info patched     : %s", tostring(STATE.debugInfoOriginal ~= nil))

    log("Blocked calls          : %d", STATE.blocked)

    if installedHooks == configuredHooks and STATE.debugInfoOriginal ~= nil then

        ok("All configured hooks are installed.")

        STATE.installed = true

        STATE.degraded = false

    elseif installedHooks > 0 then

        fail("Only %d/%d hook types were installed.", installedHooks, configuredHooks)

        STATE.installed = false

        STATE.degraded = true

    else

        fail("No AC hooks were successfully installed.")

        STATE.installed = false

        STATE.degraded = true

    end

    if EXECUTOR_ENV then

        rawset(EXECUTOR_ENV, CONFIG.STATE_KEY, STATE)

        rawset(EXECUTOR_ENV, CONFIG.INSTANCE_KEY, INSTANCE)

    end

    return installedHooks, configuredHooks

end

local function main()

    STATE.lastError = nil

    STATE.lastErrorTime = nil

    STATE.degraded = false

    STATE.failureNotified = false

    waitForRuntimeReady()

    local detection
    local detectionOk = false
    local detectionError = nil

    -- client-side AC tables. Keep scanning for a short bounded period.
    for attempt = 1, CONFIG.DETECTION_RETRIES do
        detection, detectionOk, detectionError = runDetection()

        if detectionOk and #detection.modules > 0 then
            if DEBUG and attempt > 1 then
                stage("table detected after %d scan attempt(s)", attempt)
            end
            break
        end

        if attempt < CONFIG.DETECTION_RETRIES then
            if DEBUG then
                debugLog(
                    "No AC table on scan %d/%d; retrying in %.2fs.",
                    attempt,
                    CONFIG.DETECTION_RETRIES,
                    CONFIG.DETECTION_RETRY_DELAY
                )
            end
            task.wait(CONFIG.DETECTION_RETRY_DELAY)
        end
    end

    if not detectionOk then
        fail("%s", tostring(detectionError or "detection failed"))
        notifyFailure("gc scan failure")
        stage("bypass failed")
        return false
    end

    local hasHierarchy = #detection.hierarchy > 0

    local hasGlobal = #detection.globals > 0

    local hasACModule = #detection.modules > 0

    if hasACModule then

        for index, module in ipairs(detection.modules) do

            local id = tostring(module)

            recordEvent("detection", string.format("AC module #%d: %s", index, id))

            if DEBUG then

                stage("table detected: %s", id)

            end

        end

    else

        stage("table not detected")

    end

    log("Adonis in hierarchy : %s", hasHierarchy and "YES" or "no")

    log("Adonis in globals   : %s", hasGlobal and "YES" or "no")

    log("Adonis AC in GC     : %s", hasACModule and "YES" or "no")

    if not hasHierarchy and not hasGlobal and not hasACModule then

        fail("No Adonis markers were found.")

        fail("Nothing will be modified.")

        notifyFailure("Adonis not detected")

        stage("bypass failed")

        return false

    end

    if not hasACModule then

        if hasHierarchy then

            fail("Adonis hierarchy markers found, but no AC module in GC.")

        end

        if hasGlobal then

            fail("Adonis globals found, but no AC module in GC.")

        end

        fail("Nothing will be hooked.")

        notifyFailure("Adonis present without client AC module")

        stage("bypass failed")

        return false

    end

    ok("AC module(s) detected — continuing.")

    stage("trying to spoof")

    hookModules(detection.modules)

    local debugSuccess, debugError = patchDebugInfo()

    if debugSuccess then

        ok("debug.info patched (%s).", tostring(debugError or "installed"))

    else

        fail("Could not patch debug.info: %s", tostring(debugError))

    end

    local installedHooks, configuredHooks = showSummary()

    restoreIdentity()

    local fullyInstalled = installedHooks == configuredHooks and debugSuccess

    if fullyInstalled then

        if DEBUG then

            startMonitor()

        else

            notifySuccess()

        end

        setupHotkey()

        startHealthScaffold()

        stage("bypass successful")

        return true

    end

    if installedHooks == 0 then

        notifyFailure("zero successful hooks")

    elseif not debugSuccess then




    end

    if installedHooks > 0 then

        if DEBUG then

            startMonitor()

        end

        setupHotkey()

        startHealthScaffold()

    end

    stage("bypass failed")

    return installedHooks > 0

end

runBypass = function(isReplacement, oldInstance)

    RUN_STARTED_AT = tick()

    alive = true

    if isReplacement then

        recordEvent("reload", string.format(

            "Starting replacement v%s after retiring v%s.",

            VERSION,

            tostring(oldInstance and oldInstance.version or "unknown")

        ))

    end

    stage("bypass starting")

    if EXECUTOR_ENV then

        rawset(EXECUTOR_ENV, CONFIG.STATE_KEY, STATE)

        rawset(EXECUTOR_ENV, CONFIG.INSTANCE_KEY, INSTANCE)

        rawset(EXECUTOR_ENV, CONFIG.API_KEY, API)

        rawset(EXECUTOR_ENV, "AdonisBypass_Dump", API.Dump)

    end

    local success, result = xpcall(

        main,

        function(err)

            return debug.traceback(tostring(err), 2)

        end

    )

    restoreIdentity()

    if not success then

        STATE.lastError = result

        STATE.lastErrorTime = tick()

        STATE.installed = false

        STATE.degraded = true

        recordEvent("crash", result)

        if DEBUG then

            fail("Unhandled runtime error:\n%s", tostring(result))

        end

        notifyFailure("unhandled runtime error")

        stage("bypass failed")

        return false, result

    end

    STATE.degraded = STATE.installed == false

    if EXECUTOR_ENV then

        rawset(EXECUTOR_ENV, CONFIG.STATE_KEY, STATE)

        rawset(EXECUTOR_ENV, CONFIG.INSTANCE_KEY, INSTANCE)

        rawset(EXECUTOR_ENV, CONFIG.API_KEY, API)

        rawset(EXECUTOR_ENV, "AdonisBypass_Dump", API.Dump)

    end

    return result ~= false, result

end

-- Startup


if EXISTING_INSTANCE_LIVE and EXISTING_INSTANCE then

    local started = replaceCurrentInstance(true)

    if not started then

        recordEvent("status", "Replacement finished in non-installed/degraded state.")

    end

elseif EXISTING_INSTANCE then


    if type(EXISTING_INSTANCE.state) == "table" then

        EXISTING_INSTANCE.state.installed = false

        EXISTING_INSTANCE.state.degraded = true

    end

    if EXECUTOR_ENV and rawget(EXECUTOR_ENV, CONFIG.INSTANCE_KEY) == EXISTING_INSTANCE then

        rawset(EXECUTOR_ENV, CONFIG.INSTANCE_KEY, nil)

    end

    if CONFIG.IDEMPOTENT and type(STATE) == "table" and STATE.installed then

        fatal("This v%s state is already marked active; refusing to double-hook.", VERSION)

        fatal("Use AdonisBypass.Reload() or unload before starting another copy.")

        alive = false

    else

        setGlobal(CONFIG.INSTANCE_KEY, INSTANCE)

        if EXECUTOR_ENV then

            rawset(EXECUTOR_ENV, CONFIG.STATE_KEY, STATE)

            rawset(EXECUTOR_ENV, CONFIG.API_KEY, API)

            rawset(EXECUTOR_ENV, "AdonisBypass_Dump", API.Dump)

        end

        local started = runBypass(false)

        if not started then

            recordEvent("status", "Instance finished in non-installed/degraded state.")

        end

    end

else

    if CONFIG.IDEMPOTENT and type(STATE) == "table" and STATE.installed then

        fatal("This v%s state is already marked active; refusing to double-hook.", VERSION)

        fatal("Use AdonisBypass.Reload() or unload before starting another copy.")

        alive = false

    else

        setGlobal(CONFIG.INSTANCE_KEY, INSTANCE)

        if EXECUTOR_ENV then

            rawset(EXECUTOR_ENV, CONFIG.STATE_KEY, STATE)

            rawset(EXECUTOR_ENV, CONFIG.API_KEY, API)

            rawset(EXECUTOR_ENV, "AdonisBypass_Dump", API.Dump)

        end

        local started = runBypass(false)

        if not started then

            recordEvent("status", "Instance finished in non-installed/degraded state.")

        end

    end

end
