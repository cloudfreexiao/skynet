local skynet = require "skynet"
require "skynet.manager"
local cjson = require "cjson"
local vscdebugaux = require "skynet.vscdebugaux"

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
        output:write(data)
        output:flush()
    else
        output:write(string.format("send_event - error: %s\n", msg))
    end
end

-- register protocol text before skynet.start would be better.
skynet.register_protocol {
    name = "text",
    id = skynet.PTYPE_TEXT,
    unpack = skynet.tostring,
    dispatch = function(_, address, msg)
        local line, source
        if msg:find("co.vsc.db.", 1, true) == 1 then
            line, source, msg = msg:match("co.vsc.db.([^|]+)|([^|]+)|(.+)$")
        end
        if source then
            source = {
                path = source,
            }
        end
        send_event("output", {
            category = "stdout",
            output = string.format("[:%08x] %s\n", address, msg),
            source = source,
            line = tonumber(line),
        })
    end,
}

skynet.register_protocol {
    name = "SYSTEM",
    id = skynet.PTYPE_SYSTEM,
    unpack = function(...)
        return ...
    end,
    dispatch = function()
        -- reopen signal
    end,
}

skynet.start(function()
end)
