local skynet = require "skynet"
local service = require "skynet.service"
local core = require "skynet.sharetable.core"

local function sharetable_service()
	local skynet = require "skynet"
	local core = require "skynet.sharetable.core"
	local Queue = require "skynet.queue"

	local TABLE_SOURCE = [[
		local unpack, ptr, len = ...
		return unpack(ptr, len)
	]]

	local matrix = {}	-- all the matrix
	local files = {}	-- filename : matrix
	local clients = {}
	local mutation_queue = Queue()
	local pending = {}

	local sharetable = {}

	skynet.register_protocol {
		name = "sharetable_completion",
		id = skynet.PTYPE_SYSTEM,
		unpack = core.unpack_completion,
		dispatch = function(_, _, plan, committed)
			local result = assert(pending[plan])
			result.committed = committed
			skynet.wakeup(plan)
		end,
	}

	local function close_matrix(m)
		if m == nil then
			return
		end
		local ptr = m:getptr()
		local ref = matrix[ptr]
		if ref == nil or ref.count == 0 then
			matrix[ptr] = nil
			m:close()
		end
	end

	local function loadfile(filename, ...)
		close_matrix(files[filename])
		local m = core.matrix("@" .. filename, ...)
		files[filename] = m
	end

	function sharetable.loadfile(_, filename, ...)
		mutation_queue(loadfile, filename, ...)
		skynet.ret()
	end

	local function loadstring(filename, datasource, ...)
		close_matrix(files[filename])
		local m = core.matrix(datasource, ...)
		files[filename] = m
	end

	function sharetable.loadstring(_, filename, datasource, ...)
		mutation_queue(loadstring, filename, datasource, ...)
		skynet.ret()
	end

	local function loadtable(filename, ptr, len)
		close_matrix(files[filename])
		local m = core.matrix(TABLE_SOURCE, skynet.unpack, ptr, len)
		files[filename] = m
	end

	function sharetable.loadtable(_, filename, ptr, len)
		local ok, err = pcall(mutation_queue, loadtable, filename, ptr, len)
		skynet.trash(ptr, len)
		assert(ok, err)
		skynet.ret()
	end

	local function commit_merge(plan, changed)
		if not changed then
			core.finalize_merge(plan)
			return true
		end

		local result = {}
		pending[plan] = result
		local submitted, err = core.submit_merge(plan, skynet.self())
		if not submitted then
			pending[plan] = nil
			core.finalize_merge(plan)
			return false, err
		end
		skynet.wait(plan)
		pending[plan] = nil
		core.finalize_merge(plan)
		if result.committed then
			return true
		end
		return false, "ShareTable update timed out waiting for workers"
	end

	local function merge(values)
		local plan
		local function prepare_batch()
			local changed = false
			for i = 1, #values, 3 do
				local filename = values[i]
				local m = files[filename]
				if not m then
					error(string.format("ShareTable is not loaded: %s", filename), 0)
				end
				local result = table.pack(pcall(
					m.prepare_merge, m, values[i + 1], values[i + 2], plan))
				if not result[1] then
					error(string.format("ShareTable merge failed: %s: %s",
						filename, result[2]), 0)
				end
				plan, changed = table.unpack(result, 2, result.n)
			end
			return changed
		end

		local ok, changed = xpcall(prepare_batch, debug.traceback)
		for i = 1, #values, 3 do
			skynet.trash(values[i + 1], values[i + 2])
		end
		if not ok then
			if plan then
				core.finalize_merge(plan)
			end
			return false, changed
		end
		if not plan then
			return true
		end
		return commit_merge(plan, changed)
	end

	local function run_merge(func, ...)
		local ok, success, err = xpcall(func, debug.traceback, ...)
		if not ok then
			return false, success
		end
		return success, err
	end

	function sharetable.merge(_, values)
		skynet.retpack(mutation_queue(run_merge, merge, values))
	end

	local function query_file(source, filename)
		local m = files[filename]
		local ptr = m:getptr()
		local ref = matrix[ptr]
		if ref == nil then
			ref = {
				filename = filename,
				count = 0,
				matrix = m,
				refs = {},
			}
			matrix[ptr] = ref
		end
		if ref.refs[source] == nil then
			ref.refs[source] = true
			local list = clients[source]
			if not list then
				clients[source] = { ptr }
			else
				table.insert(list, ptr)
			end
			ref.count = ref.count + 1
		end
		return ptr
	end

	function sharetable.query(source, filename)
		local m = files[filename]
		if m == nil then
			skynet.ret()
			return
		end
		local ptr = query_file(source, filename)
		skynet.ret(skynet.pack(ptr))
	end

	local function querylist(source, filenamelist)
		local ptrList = {}
		for _, filename in ipairs(filenamelist) do
			if files[filename] then
				ptrList[filename] = query_file(source, filename)
			end
		end
		return ptrList
	end

	local function queryall(source)
		local ptrList = {}
		for filename in pairs(files) do
			ptrList[filename] = query_file(source, filename)
		end
		return ptrList
	end

	function sharetable.queryall(source, filenamelist)
		local queryFunc = filenamelist and querylist or queryall
		local ptrList = queryFunc(source, filenamelist)
		skynet.ret(skynet.pack(ptrList))
	end

	function sharetable.close(source)
		local list = clients[source]
		if list then
			for _, ptr in ipairs(list) do
				local ref = matrix[ptr]
				if ref and ref.refs[source] then
					ref.refs[source] = nil
					ref.count = ref.count - 1
					if ref.count == 0 then
						if files[ref.filename] ~= ref.matrix then
							-- It's a history version
							skynet.error(string.format("Delete a version (%s) of %s", ptr, ref.filename))
							ref.matrix:close()
							matrix[ptr] = nil
						end
					end
				end
			end
			clients[source] = nil
		end
		-- no return
	end

	skynet.dispatch("lua", function(_,source,cmd,...)
		sharetable[cmd](source,...)
	end)

	skynet.info_func(function()
		local info = {}

		for filename, m in pairs(files) do
			info[filename] = {
				current = m:getptr(),
				size = m:size(),
			}
		end

		local function address(refs)
			local keys = {}
			for addr in pairs(refs) do
				table.insert(keys, skynet.address(addr))
			end
			table.sort(keys)
			return table.concat(keys, ",")
		end

		for ptr, copy in pairs(matrix) do
			local v = info[copy.filename]
			local h = v.history
			if h == nil then
				h = {}
				v.history = h
			end
			table.insert(h, string.format("%s [%d]: (%s)", copy.matrix:getptr(), copy.matrix:size(), address(copy.refs)))
		end
		for _, v in pairs(info) do
			if v.history then
				v.history = table.concat(v.history, "\n\t")
			end
		end

		return info
	end)

end

local function load_service(t, key)
	if key == "address" then
		t.address = service.new("sharetable", sharetable_service)
		return t.address
	else
		return nil
	end
end

local function report_close(t)
	local addr = rawget(t, "address")
	if addr then
		skynet.send(addr, "lua", "close")
	end
end

local sharetable = setmetatable ( {} , {
	__index = load_service,
	__gc = report_close,
})

function sharetable.loadfile(filename, ...)
	skynet.call(sharetable.address, "lua", "loadfile", filename, ...)
end

function sharetable.loadstring(filename, source, ...)
	skynet.call(sharetable.address, "lua", "loadstring", filename, source, ...)
end

function sharetable.loadtable(filename, tbl)
	assert(type(tbl) == "table")
	skynet.call(sharetable.address, "lua", "loadtable", filename, skynet.pack(tbl))
end

function sharetable.merge(values)
	assert(type(values) == "table", "ShareTable merge values must be a table")
	for filename, value in pairs(values) do
		assert(type(filename) == "string", "ShareTable merge name must be a string")
		assert(type(value) == "table", "ShareTable merge value must be a table")
	end

	local packed = {}
	local ok, err = xpcall(function()
		for filename, value in pairs(values) do
			local ptr, len = skynet.pack(value)
			packed[#packed + 1] = filename
			packed[#packed + 1] = ptr
			packed[#packed + 1] = len
		end
	end, debug.traceback)
	if not ok then
		for i = 1, #packed, 3 do
			skynet.trash(packed[i + 1], packed[i + 2])
		end
		error(err, 0)
	end
	if #packed == 0 then
		return true
	end
	return skynet.call(sharetable.address, "lua", "merge", packed)
end
function sharetable.query(filename)
	local newptr = skynet.call(sharetable.address, "lua", "query", filename)
	if newptr then
		return core.clone(newptr)
	end
end

function sharetable.queryall(filenamelist)
	local list = {}
	local ptrList = skynet.call(sharetable.address, "lua", "queryall", filenamelist)
	for filename, ptr in pairs(ptrList) do
		list[filename] = core.clone(ptr)
	end
	return list
end

return sharetable
