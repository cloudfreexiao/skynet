local skynet = require "skynet"
local sharetable = require "skynet.sharetable"

local root
local nested
local deep
local filename

skynet.start(function()
	skynet.dispatch("lua", function(_, _, command, ...)
		if command == "hold" then
			filename = ...
			root = assert(sharetable.query(filename))
			nested = root.nested
			deep = nested.deep
			skynet.retpack(true)
		elseif command == "check" then
			local version, length = ...
			local current = assert(sharetable.query(filename))
			assert(rawequal(root, current))
			assert(rawequal(nested, current.nested))
			assert(rawequal(deep, current.nested.deep))
			assert(current.nested.value == version)
			assert(#current == length and rawlen(current) == length)
			collectgarbage()
			assert(current.nested.value == version)
			skynet.retpack(true)
		else
			error("unknown command: " .. tostring(command))
		end
	end)
end)
