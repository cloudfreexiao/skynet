-- vscdebug
local skynet = require "skynet"

local mode = ...

if mode and mode:find("slave") then -----------------------------------------

    local function dosomething()
        local a = 10
        local s = "hello"
        local t = {
            name = "tom",
            age = 30,
            male = true,
            record = {10, true, "tttttt"},
        }
        local function concat(...)
            local t = {...}
            for i = 1, #t do
                t[i] = tostring(t[i])
            end
            local msg = table.concat(t, '')
            -- skynet.error(mode, coroutine.running(), msg)
            error("error")
            return msg
        end
        local msg = pcall(concat, a, s, t)
        local addr = skynet.self()
        for i = 1, 10 do
            a = a + i
        end
    end

    skynet.start(function()
        skynet.dispatch("lua", function(_, _, ...)
            dosomething()
            skynet.retpack(...)
        end)
    end)

else ------------------------------------------------------------

    skynet.start(function()
        local slaves = {}
        for i = 1, 5 do
            slaves[i] = skynet.newservice(SERVICE_NAME, "slave" .. i)
        end

        for i = 1, 5 do
            skynet.fork(function()
                while true do
                    local msg = skynet.call(slaves[i], "lua", "master fork call: " .. i)
                    skynet.sleep(100)
                    -- skynet.error(msg)
                end
            end)
        end

        local i = 0
        while true do
            local msg = skynet.call(slaves[(i % #slaves) + 1], "lua", "master call: " .. i)
            i = i + 1
            -- skynet.error(msg)
            skynet.sleep(300)
        end
    end)

end
