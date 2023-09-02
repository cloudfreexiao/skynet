local skynet = require "skynet"

local max_client = 64

skynet.start(function()
    skynet.error("Server start")
    skynet.uniqueservice("protoloader")
    skynet.newexlusive("debug_console", 8000)
    skynet.newexlusive("simpledb")
    local watchdog = skynet.newexlusive("watchdog")
    local addr, port = skynet.call(watchdog, "lua", "start", {
        port = 8888,
        maxclient = max_client,
        nodelay = true,
    })
    skynet.error("Watchdog listen on " .. addr .. ":" .. port)
    skynet.exit()
end)
