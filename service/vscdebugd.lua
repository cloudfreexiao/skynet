local skynet = require "skynet"
require "skynet.manager"
local socket = require "skynet.socket"
local cjson = require "cjson"
local vscdebugaux = require "skynet.vscdebugaux"
cjson.encode_empty_table_as_array(true)

---------------------------------------------------
-- debug
local THREAD_ID = 1

local addressmap = {} -- service addresses being debugged
local stdin
local request = {} -- vscode request
local breakpoints = {}
local isterm = false -- is terminated
local debug_addr

local function recv_request()
    -- -- TODO 测试
    -- local msg = socket.readline(stdin, "\n")
    -- local ok, req = pcall(cjson.decode, msg)
    -- if ok then
    --     return req
    -- else
    --     skynet.error(req)
    -- end
    -- do return end

    local header = socket.readline(stdin, "\r\n")
    if header:find("Content-Length: ", 1, true) then
        local rd = socket.readline(stdin, "\r\n")
        if rd then
            local len = tonumber(header:match("(%d+)"))
            local sreq = socket.read(stdin, len)
            if sreq then
                local ok, req = pcall(cjson.decode, sreq)
                -- skynet.error(sreq)
                if ok then
                    return req
                else
                    skynet.error("recv_request - error", req)
                end
            end
        end
    end
end

local function send_response(cmd, succ, rseq, content)
    local body, message
    if succ then
        body = content
    else
        message = content
    end
    local res = {
        seq = vscdebugaux.nextseq(),
        type = "response",
        success = succ,
        request_seq = rseq,
        command = cmd,
        body = body,
        message = message,
    }
    local output = io.stdout
    local ok, msg = pcall(cjson.encode, res)
    if ok then
        local data = string.format("Content-Length: %s\r\n\r\n%s\n", #msg, msg)
        if output:write(data) then
            output:flush()
            return true
        end
    else
        skynet.error("send_response - error", msg)
    end
end

local function send_event(event, body)
    local res = {
        seq = vscdebugaux.nextseq(),
        type = "event",
        event = event,
        body = body,
    }
    local output = io.stdout
    local ok, msg = pcall(cjson.encode, res)
    if ok then
        local data = string.format("Content-Length: %s\r\n\r\n%s\n", #msg, msg)
        if output:write(data) then
            output:flush()
            return true
        end
    else
        skynet.error("send_event - error", msg)
    end
end

local function debug_update_breakpoints(breakpoints)
    for addr, _ in pairs(addressmap) do
        skynet.send(addr, "debug", "vsccmd", "update_breakpoints", breakpoints)
    end
end

local function process_requests()
    while true do
        local req = recv_request()
        if req and req.command then
            local func = request[req.command]
            if not func then
                send_response(req.command, false, req.seq, string.format("%s not yet implemented", req.command))
            else
                local ok, brk = pcall(func, req)
                if not ok then
                    skynet.error("process_requests error: ", req.command, brk)
                elseif brk then
                    break
                end
            end
        end
    end
end

function request.initialize(req)
    send_response(req.command, true, req.seq, {
        supportsConfigurationDoneRequest = true,
        supportsSetVariable = false,
        supportsConditionalBreakpoints = true,
        supportsHitConditionalBreakpoints = true,
    })
    send_event("initialized")
    send_event("output", {
        category = "console",
        output = "skynet debugger start!\n",
    })
end

function request.setExceptionBreakpoints(req)
    send_response(req.command, true, req.seq)
end

function request.configurationDone(req)
    send_response(req.command, true, req.seq)
end

local function calc_hitcount(hitexpr)
    if not hitexpr then
        return 0
    end
    local f, msg = load("return " .. hitexpr, "=hitexpr")
    if not f then
        return 0
    end
    local ok, ret = pcall(f)
    if not ok then
        return 0
    end
    return tonumber(ret) or 0
end

function request.setBreakpoints(req)
    local args = req.arguments
    local src = args.source.path
    local bpinfos = {}
    local bps = {}
    for _, bp in ipairs(args.breakpoints) do
        local logmsg
        if bp.logMessage and bp.logMessage ~= "" then
            logmsg = bp.logMessage .. '\n'
        end
        bpinfos[#bpinfos + 1] = {
            source = {
                path = src,
            },
            line = bp.line,
            logMessage = logmsg,
            condition = bp.condition,
            hitCount = calc_hitcount(bp.hitCondition),
            currHitCount = 0,
        }
        bps[#bps + 1] = {
            verified = true,
            source = {
                path = src,
            },
            line = bp.line,
        }
    end
    breakpoints[src] = bpinfos
    send_response(req.command, true, req.seq, {
        breakpoints = bps,
    })

    debug_update_breakpoints(breakpoints)
end

function request.launch(req)
    send_response(req.command, true, req.seq)
end

function request.evaluate(req)
    if not debug_addr then
        send_response(req.command, true, req.seq, {
            result = "",
        })
    end
    local ok, result = skynet.call(debug_addr, "debug", "vsccmd", "evaluate", req.arguments.expression,
                           req.arguments.frameId)
    if not ok then
        send_response(req.command, false, req.seq, result)
    else
        send_response(req.command, true, req.seq, {
            result = result,
        })
    end
end

function request.continue(req)
    if debug_addr then
        skynet.send(debug_addr, "debug", "vsccmd", "continue")
        debug_addr = nil
    end
    send_response(req.command, true, req.seq)
end

function request.threads(req)
    send_response(req.command, true, req.seq, {
        threads = {{
            id = THREAD_ID,
            name = "mainthread",
        }},
    })
end

function request.next(req)
    if debug_addr then
        skynet.send(debug_addr, "debug", "vsccmd", "next", "stepover")
    end
    send_response(req.command, true, req.seq)
end

function request.stepIn(req)
    if debug_addr then
        skynet.send(debug_addr, "debug", "vsccmd", "next", "stepin")
    end
    send_response(req.command, true, req.seq)
end

function request.stepOut(req)
    if debug_addr then
        skynet.send(debug_addr, "debug", "vsccmd", "next", "stepout")
    end
    send_response(req.command, true, req.seq)
end

function request.stackTrace(req)
    if debug_addr then
        local maxlevel = math.min(req.arguments.levels or 20, 50)
        local frames = skynet.call(debug_addr, "debug", "vsccmd", "traceback", maxlevel)
        send_response(req.command, true, req.seq, {
            stackFrames = frames,
            totalFrames = #frames,
        })
    else
        send_response(req.command, false, req.seq, "strackTrace error")
    end
end

local function encode_varref(type, frameId)
    return (type * 100 + frameId) * 10000000
end

function request.scopes(req)
    if debug_addr then
        local frameId = req.arguments.frameId
        skynet.send(debug_addr, "debug", "vsccmd", "scopes", frameId)
        send_response(req.command, true, req.seq, {
            scopes = {{
                name = "Locals",
                variablesReference = encode_varref(1, frameId),
            }, {
                name = "UpValues",
                variablesReference = encode_varref(2, frameId),
            }},
        })
    else
        send_response(req.command, false, req.seq, "scopes error")
    end
end

function request.variables(req)
    if debug_addr then
        local ok, vars = skynet.call(debug_addr, "debug", "vsccmd", "variables", req.arguments.variablesReference)
        if ok then
            send_response(req.command, true, req.seq, {
                variables = vars,
            })
        else
            send_response(req.command, false, req.seq, vars)
        end
    else
        send_response(req.command, false, req.seq, "variables error")
    end
end

function request.disconnect(req)
    -- TODO: data persistence?
    isterm = true
    send_response(req.command, true, req.seq)
    send_event("output", {
        category = "console",
        output = "skynet debugger stop!\n",
    })
    send_event("exited", {
        exitCode = 0,
    })
    os.exit(0)
    -- skynet.abort()
    return true
end

------------------------------------------
-- cmd
local command = {}

function command.service_start(addr)
    addressmap[addr] = true
    skynet.call(addr, "debug", "vsccmd", "launch", breakpoints)
end

function command.service_exit(addr)
    addressmap[addr] = false
end

function command.pause(addr, reason)
    if isterm then
        return
    end
    if debug_addr and debug_addr ~= addr then
        skynet.call(addr, "debug", "vsccmd", "pause_res", false)
    else
        debug_addr = addr
        skynet.call(addr, "debug", "vsccmd", "pause_res", true)
        send_event("stopped", {
            reason = reason,
            threadId = THREAD_ID,
        })
    end
end

function command.output(addr, category, msg, source, line)
    if isterm then
        return
    end
    send_event("output", {
        category = category,
        output = msg,
        source = {
            path = source,
        },
        line = tonumber(line),
    })
end

------------------------------------------
-- service start

skynet.start(function()
    skynet.dispatch("lua", function(session, address, cmd, ...)
        local f = assert(command[cmd])
        if session ~= 0 then
            skynet.ret(skynet.pack(f(address, ...)))
        else
            f(address, ...)
        end
    end)

    local pbs = skynet.getenv("vscdbg_bps")
    local ok, bps = pcall(cjson.decode, pbs)
    if ok then
        breakpoints = bps
    end

    stdin = socket.stdin()
    skynet.fork(function()
        process_requests()
    end)
end)
