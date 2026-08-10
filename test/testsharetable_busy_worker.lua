local skynet = require "skynet"

skynet.start(function()
	skynet.dispatch("lua", function(_, _, command, target, duration)
		assert(command == "block")
		target = assert(tonumber(target))
		duration = assert(tonumber(duration))
		skynet.send(target, "lua", "busy_started")
		local deadline = skynet.now() + duration
		while skynet.now() < deadline do
			-- Keep this worker inside the current callback.
		end
		skynet.exit()
	end)
end)
