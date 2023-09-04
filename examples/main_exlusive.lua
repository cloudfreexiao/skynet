local skynet = require "skynet"

local cjson = require "cjson"
print("cjsoncjsoncjsoncjson", cjson)
local lfs = require "lfs"
print("lfslfslfslfslfs", lfs)
local pb = require "pb"
print("pbpbpbpbpbpb", pb)
local laoi = require "laoi"
print("laoilaoilaoilaoilaoi", laoi)
local ldetour = require "ldetour"
print("ldetourldetourldetourldetour", ldetour)

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
