local skynet = require "skynet.manager"
local sharetable = require "skynet.sharetable"

local MAIN_NAME = "merge_main"
local OTHER_NAME = "merge_other"
local SOURCE_NAME = "merge_source"
local META_NAME = "merge_meta"
local CONSUMER_COUNT = 8

local busy_started = false

local function count_pairs(value)
	local count = 0
	for _ in pairs(value) do
		count = count + 1
	end
	return count
end

local function expect_write_rejected(write)
	local ok = pcall(write)
	assert(not ok, "shared table write unexpectedly succeeded")
end

local function initial_main()
	return {
		1,
		2,
		3,
		keep = "before",
		removed = { value = "removed" },
		replaced = { value = "replaced" },
		nested = {
			value = 1,
			deep = { marker = "before" },
		},
	}
end

local function grown_main()
	local value = {
		keep = "after",
		added = true,
		replaced = 17,
		nested = {
			value = 2,
			deep = { marker = "after" },
			branch = { leaf = true },
		},
	}
	for i = 1, 512 do
		value[i] = i * 3
		value["hash_" .. i] = i * 5
	end
	return value
end

local function shrunk_main()
	return {
		3,
		6,
		9,
		keep = "final",
		replaced = 17,
		nested = {
			value = 3,
			deep = { marker = "final" },
		},
	}
end

local function start_consumers()
	local consumers = {}
	for i = 1, CONSUMER_COUNT do
		local service = skynet.newservice("testsharetable_consumer")
		assert(skynet.call(service, "lua", "hold", MAIN_NAME))
		consumers[i] = service
	end
	return consumers
end

local function check_consumers(consumers, version, length)
	for _, service in ipairs(consumers) do
		assert(skynet.call(service, "lua", "check", version, length))
	end
end

local function test_merge()
	sharetable.loadtable(MAIN_NAME, initial_main())
	sharetable.loadtable(OTHER_NAME, {
		version = 1,
		number = 1,
		child = { value = "before" },
	})

	local root = assert(sharetable.query(MAIN_NAME))
	local nested = root.nested
	local deep = nested.deep
	local removed = root.removed
	local replaced = root.replaced
	local other = assert(sharetable.query(OTHER_NAME))
	local other_child = other.child
	local consumers = start_consumers()

	local ok, err = sharetable.merge {
		[MAIN_NAME] = grown_main(),
		[OTHER_NAME] = {
			version = 2,
			number = 1.0,
			child = { value = "after" },
			added = true,
		},
	}
	assert(ok, err)

	assert(rawequal(root, assert(sharetable.query(MAIN_NAME))))
	assert(rawequal(nested, root.nested))
	assert(rawequal(deep, root.nested.deep))
	assert(rawequal(other, assert(sharetable.query(OTHER_NAME))))
	assert(rawequal(other_child, other.child))
	assert(root.keep == "after" and root.added)
	assert(root.removed == nil and root.replaced == 17)
	assert(removed.value == "removed")
	assert(replaced.value == "replaced")
	assert(root.nested.value == 2 and root.nested.deep.marker == "after")
	assert(root.nested.branch.leaf)
	assert(#root == 512 and rawlen(root) == 512)
	assert(count_pairs(root) == 1028)
	assert(rawget(root, 256) == 768)
	assert(next(root) ~= nil)
	for i = 1, 512 do
		assert(root[i] == i * 3)
		assert(root["hash_" .. i] == i * 5)
	end
	assert(other.version == 2 and other.child.value == "after" and other.added)
	assert(math.type(other.number) == "float")
	check_consumers(consumers, 2, 512)

	expect_write_rejected(function()
		root.forbidden = true
	end)
	expect_write_rejected(function()
		rawset(root, "forbidden", true)
	end)
	expect_write_rejected(function()
		setmetatable(root, {})
	end)

	ok, err = sharetable.merge {
		[MAIN_NAME] = grown_main(),
		[OTHER_NAME] = {
			version = 2,
			number = 1.0,
			child = { value = "after" },
			added = true,
		},
	}
	assert(ok, err)
	assert(rawequal(root, assert(sharetable.query(MAIN_NAME))))
	assert(rawequal(nested, root.nested) and rawequal(deep, root.nested.deep))

	sharetable.loadstring(SOURCE_NAME, [[
		return {
			version = 1,
			child = { value = "source" },
		}
	]])
	local source = assert(sharetable.query(SOURCE_NAME))
	local source_child = source.child
	ok, err = sharetable.merge {
		[SOURCE_NAME] = {
			version = 2,
			child = { value = "merged" },
		},
	}
	assert(ok, err)
	assert(rawequal(source, assert(sharetable.query(SOURCE_NAME))))
	assert(rawequal(source_child, source.child))
	assert(source.version == 2 and source.child.value == "merged")

	sharetable.loadtable(META_NAME, { marker = true })
	local shared_metatable = assert(sharetable.query(META_NAME))
	local target = setmetatable({}, shared_metatable)
	assert(target.answer == nil)
	ok, err = sharetable.merge {
		[META_NAME] = {
			marker = true,
			__index = { answer = 42 },
		},
	}
	assert(ok, err)
	assert(target.answer == 42)
	ok, err = sharetable.merge {
		[META_NAME] = { marker = true },
	}
	assert(ok, err)
	assert(target.answer == nil)

	local missing_ok, missing_err = sharetable.merge {
		missing_sharetable = { value = true },
	}
	assert(not missing_ok and tostring(missing_err):find("not loaded", 1, true))

	local infinite_ok, infinite_err = sharetable.merge {
		[MAIN_NAME] = { value = math.huge },
	}
	assert(not infinite_ok and tostring(infinite_err):find("finite", 1, true))
	assert(root.keep == "after" and #root == 512)

	local cycle = {}
	cycle.self = cycle
	local cycle_ok = pcall(sharetable.merge, {
		[MAIN_NAME] = cycle,
	})
	assert(not cycle_ok)

	local function_ok = pcall(sharetable.merge, {
		[MAIN_NAME] = { callback = function() end },
	})
	assert(not function_ok)

	busy_started = false
	local busy_worker = skynet.newservice("testsharetable_busy_worker")
	skynet.send(busy_worker, "lua", "block", skynet.self(), 400)
	while not busy_started do
		skynet.sleep(1)
	end

	local timeout_ok, timeout_err = sharetable.merge {
		[MAIN_NAME] = shrunk_main(),
	}
	assert(not timeout_ok)
	assert(tostring(timeout_err):find("timed out", 1, true))
	assert(root.keep == "after" and #root == 512 and root.nested.value == 2)

	skynet.sleep(220)
	ok, err = sharetable.merge {
		[MAIN_NAME] = shrunk_main(),
	}
	assert(ok, err)
	assert(rawequal(root, assert(sharetable.query(MAIN_NAME))))
	assert(rawequal(nested, root.nested) and rawequal(deep, root.nested.deep))
	assert(#root == 3 and rawlen(root) == 3)
	assert(root.keep == "final" and root.nested.value == 3)
	assert(root.nested.deep.marker == "final")
	assert(root.added == nil and root.hash_1 == nil and root.nested.branch == nil)
	check_consumers(consumers, 3, 3)

	local all = sharetable.queryall({ MAIN_NAME, OTHER_NAME, SOURCE_NAME })
	assert(rawequal(root, all[MAIN_NAME]))
	assert(rawequal(other, all[OTHER_NAME]))
	assert(rawequal(source, all[SOURCE_NAME]))
end

skynet.start(function()
	skynet.dispatch("lua", function(_, _, command)
		assert(command == "busy_started")
		busy_started = true
	end)

	local ok, err = xpcall(test_merge, debug.traceback)
	if ok then
		skynet.error("ShareTable atomic merge test: PASS")
	else
		skynet.error("ShareTable atomic merge test: FAIL\n", err)
	end
	skynet.sleep(1)
	skynet.abort()
end)
