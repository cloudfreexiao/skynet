local skynet_suspend
local coroutine_resume

local function start()
    local skynet = require "skynet"
    local openmode = skynet.getenv("vscdbg_open")
    if openmode == nil then
        return
    end

    local ST_INITED = 1
    local ST_RUNNING = 2
    local ST_PAUSE = 3
    local ST_STEP_OVER = 4
    local ST_STEP_IN = 5
    local ST_STEP_OUT = 6

    local vscdebugd
    local vsccmd = {}
    local mainco
    local breakpoints
    local state = ST_INITED
    local co_ctxs = {}
    local debug_ctx
    local var_cache = {}

    local injectrun = require "skynet.injectcode"
    local skynet_debug = require "skynet.debug"
    local vscdebugaux = require "skynet.vscdebugaux"
    skynet_debug.reg_debugcmd("vsccmd", function(subcmd, ...)
        local f = assert(vsccmd[subcmd])
        f(...)
    end)

    local skip_srcs = {}
    skip_srcs[#skip_srcs + 1] = debug.getinfo(skynet_debug.reg_debugcmd, "S").source -- skip when enter debug.lua

    skip_srcs[#skip_srcs + 1] = debug.getinfo(1, "S").source -- skip when enter this source file

    local function is_source_skip(source)
        for _, src in ipairs(skip_srcs) do
            if src == source then
                return true
            end
        end
    end

    local function check_condition(ctx, cond)
        if cond and cond ~= "" then
            local ok, res = injectrun("return " .. cond, ctx.co, 3)
            return (not ok) or res
        else
            return true
        end
    end

    local function eval_log_message(ctx, log)
        return string.gsub(log, "({.-})", function(expr)
            if #expr >= 2 then
                expr = expr:sub(2, -2)
                local ok, res = injectrun("return " .. expr, ctx.co, 5)
                return ok and res or ""
            else
                return ""
            end
        end)
    end

    local function breakpoints_hittest(ctx, source, line)
        source = (string.find(source, "@", 1, true) == 1) and source:sub(2) or source
        source = vscdebugaux.abspath(source)
        local bps = breakpoints[source]
        if bps then
            for _, bp in ipairs(bps) do
                if bp.line == line then
                    if check_condition(ctx, bp.condition) then
                        bp.currHitCount = bp.currHitCount + 1
                        if bp.currHitCount > bp.hitCount then
                            bp.currHitCount = 0
                            if bp.logMessage and bp.logMessage ~= "" then
                                local log = eval_log_message(ctx, bp.logMessage)
                                skynet.send(vscdebugd, "lua", "output", "console", log, source, line)
                                return false
                            end
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    local function get_traceback(co, maxlevel)
        local frames = {}
        local level = 0
        while level < maxlevel do
            local info = debug.getinfo(co, level, "Sln")
            if not info then
                break
            end
            if not is_source_skip(info.source) then
                local frame = {}
                local islua = info.what == "Lua"
                local ismain = info.what == "main"
                frame.id = level
                if info.name then
                    frame.name = info.name
                elseif ismain then
                    frame.name = "main chunk"
                else
                    frame.name = "?"
                end
                if (islua or ismain) and info.source:sub(1, 1) == '@' then
                    frame.source = {
                        path = vscdebugaux.abspath(info.source:sub(2)),
                    }
                    frame.column = 1
                else
                    frame.source = {
                        presentationHint = "deemphasize",
                    }
                end
                frame.line = info.currentline
                frames[#frames + 1] = frame
            end
            level = level + 1
        end
        return frames
    end

    local function clearvarcache()
        var_cache = {
            id = 1,
        }
    end

    local function decode_varref(ref)
        local v = ref // 10000000
        return ref % 10000000, v // 100, v % 100
    end

    local function add_var_info(t, key, value)
        local tp = type(value)
        local refid = 0
        if tp == 'table' then
            if var_cache[value] then
                refid = var_cache[value]
            else
                refid = var_cache.id
                var_cache.id = var_cache.id + 1
            end
            var_cache[refid] = value
            var_cache[value] = refid
        end
        t[#t + 1] = {
            name = tostring(key),
            value = tostring(value),
            type = tp,
            variablesReference = refid,
        }
    end

    local function get_func_locals(co, level)
        local t = {}
        local i = -1
        while true do
            local name, value = debug.getlocal(co, level, i)
            if not name then
                break
            end
            name = string.format("(vararg%d)", -i)
            add_var_info(t, name, value)
            i = i - 1
        end
        i = 1
        while true do
            local name, value = debug.getlocal(co, level, i)
            if not name then
                break
            end
            if name:sub(1, 1) ~= '(' then
                add_var_info(t, name, value)
            end
            i = i + 1
        end
        return t
    end

    local function get_func_upvalues(co, func)
        local t = {}
        local i = 1
        while true do
            local name, value = debug.getupvalue(func, i)
            if not name then
                break
            end
            add_var_info(t, name, value)
            i = i + 1
        end
        return t
    end

    local function get_table_fields(co, id)
        local t = var_cache[id]
        assert(t, "variable invalid")
        local f = {}
        local n = 0
        for k, v in pairs(t) do
            add_var_info(f, k, v)
            n = n + 1
            -- limit to 100
            if n >= 100 then
                break
            end
        end
        return f
    end

    local function get_vars(co, refid)
        local id, type, level = decode_varref(refid)
        if id == 0 then
            local info = debug.getinfo(co, level, "fn")
            assert(info, "frameId invalid")
            if info.what ~= 'C' and info.func then
                if type == 1 then
                    return get_func_locals(co, level)
                elseif type == 2 then
                    return get_func_upvalues(co, info.func)
                else
                    error("scope invalid")
                end
            else
                return {}
            end
        else
            return get_table_fields(co, id)
        end
    end

    local function debughook(mode, source, what, name, line, level)
        local co = coroutine.running()
        if mode == "call" or mode == "tail call" then
            local ctx = co_ctxs[co]
            if not ctx then
                ctx = {
                    co = co,
                    level = 0,
                    plevel = -1,
                }
                co_ctxs[co] = ctx
            end
            ctx.level = level
        elseif mode == "return" then
            local ctx = co_ctxs[co]
            if ctx then
                ctx.level = level - 1
                if ctx.level == 0 then
                    co_ctxs[co] = nil
                end
            end
        else
            local ctx = co_ctxs[co]
            if not ctx or state == ST_INITED then
                return
            end
            -- main thread can not debug
            if co == mainco or is_source_skip(source) then
                return
            end
            -- only supports debugging one coroutine at the same time
            if state ~= ST_RUNNING and ctx ~= debug_ctx then
                return
            end
            local reason;
            local hit = false
            if breakpoints_hittest(ctx, source, line) then
                reason = "breakpoint"
                hit = true
            elseif state == ST_STEP_OVER then
                if ctx.plevel >= ctx.level then
                    reason = "step"
                    hit = true
                end
            elseif state == ST_STEP_OUT then
                if ctx.plevel > ctx.level then
                    reason = "step"
                    hit = true
                end
            elseif state == ST_STEP_IN then
                reason = "step"
                hit = true
            end
            if hit then
                debug_ctx = ctx
                state = ST_PAUSE
                ctx.plevel = -1
                skynet.send(vscdebugd, "lua", "pause", reason)
                return true -- yield
            end
        end
    end

    ----------------------------------------------------
    -- vsccmd
    function vsccmd.update_breakpoints(bps)
        breakpoints = bps
    end

    function vsccmd.launch(bps)
        breakpoints = bps
        state = ST_RUNNING
        skynet.ret()
    end

    function vsccmd.pause_res(succ)
        skynet.ret()
        if not succ and debug_ctx then
            state = ST_RUNNING
            local co = debug_ctx.co
            debug_ctx = nil
            skynet_suspend(co, coroutine_resume(co))
        end
    end

    function vsccmd.evaluate(expr, level)
        if debug_ctx then
            -- only support one result
            local ok, ret = injectrun("return " .. expr, debug_ctx.co, level)
            if not ok then
                ok, ret = injectrun(expr, debug_ctx.co, level)
            end
            skynet.retpack(ok, tostring(ret))
        else
            skynet.retpack(true, "")
        end
    end

    function vsccmd.continue()
        local oldstate = state
        state = ST_RUNNING
        if debug_ctx then
            local co = debug_ctx.co
            debug_ctx = nil
            if oldstate == ST_PAUSE then
                skynet_suspend(co, coroutine_resume(co))
            end
        end
    end

    function vsccmd.next(type)
        if debug_ctx and state == ST_PAUSE then
            debug_ctx.plevel = debug_ctx.level
            if type == "stepin" then
                state = ST_STEP_IN
            elseif type == "stepout" then
                state = ST_STEP_OUT
            elseif type == "stepover" then
                state = ST_STEP_OVER
            end
            skynet_suspend(debug_ctx.co, coroutine_resume(debug_ctx.co))
        end
    end

    function vsccmd.traceback(maxlevel)
        if debug_ctx then
            local frames = get_traceback(debug_ctx.co, maxlevel)
            skynet.retpack(frames)
        else
            skynet.ret()
        end
    end

    function vsccmd.scopes(frameId)
        clearvarcache()
    end

    function vsccmd.variables(refid)
        if not debug_ctx then
            skynet.retpack(false, "no debug")
            return
        end
        local ok, vars = pcall(get_vars, debug_ctx.co, refid)
        skynet.retpack(ok, vars)
    end

    skynet.init(function()
        vscdebugd = skynet.uniqueservice("vscdebugd")
        skynet.call(vscdebugd, "lua", "service_start")
        -- hook skynet exit
        local ori_skynet_exit = skynet.exit
        skynet.exit = function()
            skynet.send(vscdebugd, "lua", "service_exit")
            ori_skynet_exit()
        end
    end)

    -- debug hook
    local co = coroutine.running()
    assert(co == debug.getregistry()[1], "must call in main thread")
    mainco = co
    if openmode == "on" then
        vscdebugaux.sethook(co, debughook, "crl")
    end
end

local function init(skynet, import)
    skynet_suspend = import.suspend
    coroutine_resume = import.resume
    if skynet.getenv("vscdbg_open") == nil then
        return
    end

    local vscdebugaux = require "skynet.vscdebugaux"
    if skynet.getenv("logger") == "vscdebuglog" then
        local ori_skynet_error = skynet.error
        skynet.error = function(...)
            local level = skynet.vsclog_level or 0
            local info = debug.getinfo(level + 2, "Sl")
            if info then
                local t = {...}
                for i = 1, #t do
                    t[i] = tostring(t[i])
                end
                local msg = table.concat(t, '\t')
                local line = info.currentline or 0
                local source
                if info.source and info.source:sub(1, 1) == "@" then
                    source = vscdebugaux.abspath(info.source:sub(2))
                else
                    source = info.source
                end
                msg = string.format("co.vsc.db.%d|%s|%s", line, source, msg)
                ori_skynet_error(msg)
            else
                ori_skynet_error(...)
            end
        end
    end

    local ori_skynet_start = skynet.start
    skynet.start = function(start_func)
        local source = debug.getinfo(start_func, "S").source
        if source and source:sub(1, 1) == "@" then
            source = vscdebugaux.abspath(source:sub(2))
            local service_path = vscdebugaux.abspath("./service")
            if not source:find(service_path) then
                skynet.error("start debug: ", SERVICE_NAME)
                start()
            end
        end
        ori_skynet_start(start_func)
    end
end

return {
    init = init,
}
