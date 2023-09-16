cmake_minimum_required(VERSION 3.10)

project(skynet)

# 把lua头文件添加到全局搜索路径
include_directories(3rd/lua 3rd/posix skynet-src)

# 添加编译选项
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

if (CMAKE_SYSTEM_NAME MATCHES "Linux")
    message(STATUS "current platform: Linux")
    add_compile_definitions(NOUSE_JEMALLOC LUA_USE_LINUX LUA_USE_READLINE)
elseif (CMAKE_SYSTEM_NAME MATCHES "Windows")
    message(STATUS "current platform: Windows")
    # set(CMAKE_C_SOURCE_FILE_EXTENSIONS c h)
    # set(CMAKE_C_COMPILER "clang-cl")
    add_compile_definitions(NOUSE_JEMALLOC LUA_BUILD_AS_DLL  _CRT_SECURE_NO_WARNINGS)
    set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)
elseif (CMAKE_SYSTEM_NAME MATCHES "Darwin")
    message(STATUS "current platform: Mac OS X")
    add_compile_definitions(NOUSE_JEMALLOC LUA_USE_MACOSX LUA_USE_READLINE)
else ()
    message(WARNING "other platform: ${CMAKE_SYSTEM_NAME}")
endif ()

message(STATUS "The value of CMAKE_BINARY_DIR is: ${CMAKE_BINARY_DIR}")

aux_source_directory(skynet-src LIB_SKYNET_SRC)
list(REMOVE_ITEM LIB_SKYNET_SRC lualib-src/skynet_main.c)
aux_source_directory(3rd/lua LUA_LIB_SRC)
list(REMOVE_ITEM LUA_LIB_SRC "3rd/lua/lua.c" "3rd/lua/luac.c" "3rd/lua/onelua.c")
aux_source_directory(3rd/posix POSIX_SRC)

message(STATUS "The value of LUA_LIB_SRC is: ${LUA_LIB_SRC}")
add_library(liblua SHARED ${LUA_LIB_SRC})
add_library(libposix SHARED ${POSIX_SRC})
target_link_libraries(libposix ws2_32)
add_library(libskynet SHARED ${LIB_SKYNET_SRC})
target_link_libraries(libskynet liblua libposix)

# 编译 lua 可执行文件
add_executable(lua ${LUA_LIB_SRC} 3rd/lua/lua.c)
# 编译 luac 可执行文件
add_executable(luac ${LUA_LIB_SRC} 3rd/lua/luac.c)
# 编译 skynet 可执行文件
add_executable(skynet skynet-src/skynet_main.c)
target_link_libraries(skynet ws2_32 liblua libposix libskynet)

# 生成动态库 skynet.so
set(LUA_CLIB_SKYNET_SRC
    lualib-src/lua-skynet.c
    lualib-src/lua-seri.c
    lualib-src/lua-socket.c
    lualib-src/lua-mongo.c
    lualib-src/lua-netpack.c
    lualib-src/lua-memory.c
    lualib-src/lua-multicast.c
    lualib-src/lua-cluster.c
    lualib-src/lua-crypt.c
    lualib-src/lsha1.c
    lualib-src/lua-sharedata.c
    lualib-src/lua-stm.c
    lualib-src/lua-debugchannel.c
    lualib-src/lua-datasheet.c
    lualib-src/lua-sharetable.c
    lualib-src/lua-vscdebugaux.c
    lualib-src/lua-fmt.c
)
message(STATUS "The value of LIB_SKYNET_SRC is: ${LIB_SKYNET_SRC}")
add_library(skynetso SHARED ${LUA_CLIB_SKYNET_SRC})
set_target_properties(skynetso PROPERTIES OUTPUT_NAME skynet)
target_link_libraries(skynetso ws2_32 libskynet)

# 生成动态库 bson.so
add_library(bson SHARED lualib-src/lua-bson.c)
target_link_libraries(bson ws2_32 liblua)

# 生成动态库 md5.so
aux_source_directory(3rd/lua-md5 LUA_MD5_SRC)
add_library(md5 SHARED ${LUA_MD5_SRC})
target_link_libraries(md5 liblua)

# 生成动态库 client.so
set(LUA_CLIENT_SOCKET_SRC
    lualib-src/lua-crypt.c
    lualib-src/lsha1.c
    lualib-src/lua-clientsocket.c
)
add_library(client SHARED ${LUA_CLIENT_SOCKET_SRC})
target_link_libraries(client ws2_32 liblua libposix)

# 生成动态库 sproto.so
aux_source_directory(lualib-src/sproto LUA_SPROTO_SRC)
add_library(sproto SHARED ${LUA_SPROTO_SRC})
target_link_libraries(sproto liblua)

# 生成动态库 lpeg.so
aux_source_directory(3rd/lpeg LPEG_SRC)
add_library(lpeg SHARED ${LPEG_SRC})
target_link_libraries(lpeg liblua)

#生成动态库 lfs.so
aux_source_directory(3rd/luafilesystem LFS_SRC)
add_library(lfs SHARED ${LFS_SRC})
target_link_libraries(lfs liblua)

#生成动态库 pb.so
aux_source_directory(3rd/lua-protobuf PB_SRC)
add_library(pb SHARED ${PB_SRC})
target_link_libraries(pb liblua)

#生成动态库 cjson.so
set(LUA_CJSON_SRC
    3rd/lua-cjson/lua_cjson.c
    3rd/lua-cjson/fpconv.c
    3rd/lua-cjson/strbuf.c
)
add_library(cjson SHARED ${LUA_CJSON_SRC})
target_link_libraries(cjson liblua)

set_target_properties(client skynetso lpeg sproto md5 bson lfs pb cjson PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/luaclib
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/luaclib
    PREFIX ""
    SUFFIX .so
)

# 生成c服务
file(GLOB CSERVICE_FILE_LIST "service-src/*.c")
message(STATUS "The value of CSERVICE_FILE_LIST is: ${CSERVICE_FILE_LIST}")
foreach(FILE_PATH IN LISTS CSERVICE_FILE_LIST)
    message(STATUS "Processing file: ${FILE_PATH}")
    string(REGEX REPLACE ".*service-src/service_" "" LIB_NAME "${FILE_PATH}")
    string(REGEX REPLACE ".c$" "" LIB_NAME "${LIB_NAME}")
    message(STATUS "The value of LIB_NAME is: ${LIB_NAME}")
    add_library(${LIB_NAME} SHARED ${FILE_PATH})
    target_link_libraries(${LIB_NAME} ws2_32 libskynet)
    set_target_properties(${LIB_NAME} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY  ${CMAKE_BINARY_DIR}/cservice
        LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/cservice
        PREFIX ""
        SUFFIX .so
        ENABLE_EXPORTS ON
    )
endforeach()

# 拷贝其他文件
# CMAKE_SOURCE_DIR
message(STATUS "The value of CMAKE_SOURCE_DIR is: ${CMAKE_SOURCE_DIR}")
file(COPY ${CMAKE_SOURCE_DIR}/lualib/ DESTINATION lualib NO_SOURCE_PERMISSIONS)
file(COPY ${CMAKE_SOURCE_DIR}/test/ DESTINATION test NO_SOURCE_PERMISSIONS)
file(COPY ${CMAKE_SOURCE_DIR}/service/ DESTINATION service NO_SOURCE_PERMISSIONS)
file(COPY ${CMAKE_SOURCE_DIR}/examples/ DESTINATION examples NO_SOURCE_PERMISSIONS)
