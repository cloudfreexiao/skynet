rule("checkplatform")
	on_load(function (target)
		if not is_plat("linux", "bsd", "macosx") then
			raise("only support linux bsd macosx")
		end
	end)
rule_end()
add_rules("checkplatform")

----------------------------------------------------------------------------------------------
-- options

option("opt_jemalloc")
	set_default(true)
	set_showmenu(true)
	set_description("Use jemalloc")
	after_check(function (option)
		if not is_plat("linux") then
			option:enable(false)
		end
	end)
option_end()

option("opt_tls")
	set_default(true)
	set_showmenu(true)
	set_description("Enable tls")
option_end()

----------------------------------------------------------------------------------------------
-- lua

target("lua")
	set_kind("phony")
	set_default(false)
	on_build(function (target)
		local olddir = os.cd("3rd/lua")
		os.exec("make")
		os.cd(olddir)
	end)
target_end()

----------------------------------------------------------------------------------------------
-- jemalloc

target("jemalloc")
	set_kind("phony")
	set_default(false)
	add_includedirs("3rd/jemalloc/include/jemalloc", {public = true})
	on_build(function (target)
		local olddir = os.cd("3rd/jemalloc")
		if not os.exists("autogen.sh") then
			os.exec("git submodule update --init")
		end
	
		if not os.exists("Makefile") then
			-- https://www.cnblogs.com/Lifehacker/p/jemalloc_settings.html
			local je = "./autogen.sh " ..
						" --with-jemalloc-prefix=je_ " ..
						" --enable-prof " ..
						" --with-malloc-conf='background_thread:true,dirty_decay_ms:0,muzzy_decay_ms:0' "
			os.exec(je)
		end
		if not os.exists("lib/libjemalloc_pic.a") then
			os.exec("make")
		end
		os.cd(olddir)
	end)
target_end()

target("upjemalloc")
	set_kind("phony")
	set_default(false)
	on_build(function (target)
		os.exec("rm -rf 3rd/jemalloc && git submodule update --init")
	end)
target_end()

----------------------------------------------------------------------------------------------
-- skynet

set_languages("c11", "c++17")
add_includedirs("3rd/lua")
add_includedirs("skynet-src")
set_symbols("debug")						-- -g
set_optimize("faster")						-- -O2
set_warnings("all")							-- -Wall

target("skynet")
	set_kind("binary")
	add_files(
	"skynet-src/skynet_main.c",
	"skynet-src/skynet_handle.c",
	"skynet-src/skynet_module.c",
	"skynet-src/skynet_mq.c",
	"skynet-src/skynet_server.c",
	"skynet-src/skynet_start.c",
	"skynet-src/skynet_timer.c",
	"skynet-src/skynet_error.c",
	"skynet-src/skynet_harbor.c",
	"skynet-src/skynet_env.c",
	"skynet-src/skynet_monitor.c",
	"skynet-src/skynet_socket.c",
	"skynet-src/socket_server.c",
	"skynet-src/malloc_hook.c",
	"skynet-src/skynet_daemon.c",
	"skynet-src/skynet_log.c")

	set_targetdir(".")
	-- lua
	add_deps("lua")
	-- jemalloc
	add_options("opt_jemalloc")
	if has_config("opt_jemalloc") then
		add_deps("jemalloc")
		add_defines("MEMORY_CHECK")
	else
		add_defines("NOUSE_JEMALLOC")
	end
	before_link(function (target)
		target:add("links", "lua")
		target:add("linkdirs", "3rd/lua")
		if has_config("opt_jemalloc") then
			target:add("links", "jemalloc_pic")
			target:add("linkdirs", "3rd/jemalloc/lib")
		end
    end)
	-- flags
	add_syslinks("pthread", "m")
	if is_plat("linux") then
		add_syslinks("dl", "rt")
		add_ldflags("-Wl,-E")
	elseif is_plat("macosx") then
		add_syslinks("dl")
	elseif is_plat("bsd") then
		add_syslinks("rt")
		add_ldflags("-Wl,-E")
	end
target_end()

----------------------------------------------------------------------------------------------
-- skynet c services

rule("services_flags")
	on_config(function (target)
		if is_plat("macosx") then
			target:add("shflags", "-dynamiclib", "-undefined dynamic_lookup")
		end
		target:add("includedirs", "service-src")
		target:set("targetdir", "cservice")
	end)
rule_end()

target("snlua")
	set_kind("shared")
	set_filename("snlua.so")
	add_rules("services_flags")
	add_files("service-src/service_snlua.c")
target_end()

target("logger")
	set_kind("shared")
	set_filename("logger.so")
	add_rules("services_flags")
	add_files("service-src/service_logger.c")
target_end()

target("gate")
	set_kind("shared")
	set_filename("gate.so")
	add_rules("services_flags")
	add_files("service-src/service_gate.c")
target_end()

target("harbor")
	set_kind("shared")
	set_filename("harbor.so")
	add_rules("services_flags")
	add_files("service-src/service_harbor.c")
target_end()

----------------------------------------------------------------------------------------------
-- lua libs

rule("lualib_flags")
	on_config(function (target)
		if is_plat("macosx") then
			target:add("shflags", "-dynamiclib", "-undefined dynamic_lookup")
		end
		target:add("includedirs", "lualib-src")
		target:set("targetdir", "luaclib")
	end)
rule_end()

target("skynet_so")
	set_kind("shared")
	set_filename("skynet.so")
	add_rules("lualib_flags")
	add_files(
        "lualib-src/lua-skynet.c",
		"lualib-src/lua-seri.c",
		"lualib-src/lua-socket.c",
		"lualib-src/lua-mongo.c",
		"lualib-src/lua-netpack.c",
		"lualib-src/lua-memory.c",
		"lualib-src/lua-multicast.c",
		"lualib-src/lua-cluster.c",
		"lualib-src/lua-crypt.c",
		"lualib-src/lsha1.c",
		"lualib-src/lua-sharedata.c",
		"lualib-src/lua-stm.c",
		"lualib-src/lua-debugchannel.c",
		"lualib-src/lua-datasheet.c",
		"lualib-src/lua-sharetable.c",
		"lualib-src/lua-vscdebugaux.c",
		"lualib-src/lua-fmt.c")
target_end()

target("bson")
	set_kind("shared")
	set_filename("bson.so")
	add_rules("lualib_flags")
	add_files("lualib-src/lua-bson.c")
target_end()

target("md5")
	set_kind("shared")
	set_filename("md5.so")
	add_rules("lualib_flags")
	add_includedirs("3rd/lua-md5")
	add_files("3rd/lua-md5/md5.c",
		"3rd/lua-md5/md5lib.c",
		"3rd/lua-md5/compat-5.2.c")
target_end()

target("client")
	set_kind("shared")
	set_filename("client.so")
	add_rules("lualib_flags")
	add_files("lualib-src/lua-clientsocket.c",
		"lualib-src/lua-crypt.c",
		"lualib-src/lsha1.c")
target_end()

target("sproto")
	set_kind("shared")
	set_filename("sproto.so")
	add_rules("lualib_flags")
	add_includedirs("lualib-src/sproto")
	add_files("lualib-src/sproto/sproto.c",
		"lualib-src/sproto/lsproto.c")
target_end()

------------------------------
-- tls
target("tlsmodule")
	set_default(false)
	set_kind("shared")
	set_filename("ltls.so")
	add_rules("lualib_flags")
	if is_plat("macosx") then
		add_includedirs("/usr/local/opt/openssl/include")
		add_linkdirs("/usr/local/opt/openssl/lib")
	end
	add_syslinks("ssl")
	add_files("lualib-src/ltls.c")
target_end()

target("ltls")
	set_kind("phony")
	add_options("opt_tls")
	if has_config("opt_tls") then
		add_deps("tlsmodule")
	end
target_end()
------------------------------

target("lpeg")
	set_kind("shared")
	set_filename("lpeg.so")
	add_rules("lualib_flags")
	add_includedirs("3rd/lpeg")
	add_files("3rd/lpeg/lpcap.c",
		"3rd/lpeg/lpcode.c",
		"3rd/lpeg/lpprint.c",
		"3rd/lpeg/lptree.c",
		"3rd/lpeg/lpvm.c",
        "3rd/lpeg/lpcset.c")
target_end()

target("cjson")
	set_kind("shared")
	set_filename("cjson.so")
	add_rules("lualib_flags")
	add_includedirs("3rd/lua-cjson")
	add_files("3rd/lua-cjson/lua_cjson.c",
		"3rd/lua-cjson/fpconv.c",
		"3rd/lua-cjson/strbuf.c")
target_end()

target("lfs")
	set_kind("shared")
	set_filename("lfs.so")
	add_rules("lualib_flags")
	add_includedirs("3rd/luafilesystem")
	add_files("3rd/luafilesystem/lfs.c")
target_end()

target("pb")
	set_kind("shared")
	set_filename("pb.so")
	add_rules("lualib_flags")
	add_includedirs("3rd/lua-protobuf")
	add_files("3rd/lua-protobuf/pb.c")
target_end()
