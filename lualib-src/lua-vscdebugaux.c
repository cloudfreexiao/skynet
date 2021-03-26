#define LUA_LIB
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "atomic.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lua.h"
#include "lualib.h"
#include "skynet.h"

static const int HOOKKEY = 0;

// 计算调用层级
static int get_call_level(lua_State *L) {
    int level = 0;
    CallInfo *ci = &L->base_ci;
    for (; ci && ci != L->ci; ci = ci->next) {
        level++;
    }
    return level;
}

/*
** Auxiliary function used by several library functions: check for
** an optional thread as function's first argument and set 'arg' with
** 1 if this argument is present (so that functions can skip it to
** access their other arguments)
*/
static lua_State *getthread(lua_State *L, int *arg) {
    if (lua_isthread(L, 1)) {
        *arg = 1;
        return lua_tothread(L, 1);
    } else {
        *arg = 0;
        return L; /* function will operate over current thread */
    }
}

/*
** Call hook function registered at hook table for the current
** thread (if there is one)
*/
static void hookf(lua_State *L, lua_Debug *ar) {
    static const char *const hooknames[] = {"call", "return", "line", "count",
                                            "tail call"};
    lua_rawgetp(L, LUA_REGISTRYINDEX, &HOOKKEY);
    if (lua_isfunction(L, -1)) {
        lua_pushstring(L, hooknames[(int)ar->event]); /* push event name */
        lua_getinfo(L, "nSl", ar);
        lua_pushstring(L, ar->source);
        lua_pushstring(L, ar->what);
        lua_pushstring(L, ar->name);
        lua_pushinteger(L, ar->currentline);
        if (ar->event == LUA_HOOKCALL || ar->event == LUA_HOOKTAILCALL ||
            ar->event == LUA_HOOKRET)
            lua_pushinteger(L, get_call_level(L));
        else
            lua_pushnil(L);
        lua_call(L, 6, 1); /* call hook function */
        int yield = lua_toboolean(L, -1);
        lua_pop(L, 1);
        if (yield) {
            lua_yield(L, 0);
        }
    }
}

/*
** Convert a string mask (for 'sethook') into a bit mask
*/
static int makemask(const char *smask, int count) {
    int mask = 0;
    if (strchr(smask, 'c')) mask |= LUA_MASKCALL;
    if (strchr(smask, 'r')) mask |= LUA_MASKRET;
    if (strchr(smask, 'l')) mask |= LUA_MASKLINE;
    if (count > 0) mask |= LUA_MASKCOUNT;
    return mask;
}

static int sethook(lua_State *L) {
    int arg, mask, count;
    lua_Hook func;
    lua_State *L1 = getthread(L, &arg);
    if (lua_isnoneornil(L, arg + 1)) { /* no hook? */
        lua_sethook(L1, NULL, 0, 0);
    } else {
        const char *smask = luaL_checkstring(L, arg + 2);
        count = (int)luaL_optinteger(L, arg + 3, 0);
        func = hookf;
        mask = makemask(smask, count);
        luaL_checktype(L, arg + 1, LUA_TFUNCTION);
        lua_pushvalue(L, arg + 1);
        lua_rawsetp(L, LUA_REGISTRYINDEX, &HOOKKEY);
        lua_sethook(L1, func, mask, count);
    }
    return 0;
}

// () -> int
static ATOM_INT cur_seq = 0;
static int nextseq(lua_State *L) {
    int seq = ATOM_FINC(&cur_seq) + 1;
    lua_pushinteger(L, seq);
    return 1;
}

static int getcurrentdir(lua_State *L) {
    char buff[256];
    size_t size = sizeof(buff) / sizeof(buff[0]);
    if (getcwd(buff, size) != NULL) {
        lua_pushstring(L, buff);
        return 1;
    } else {
        char *path = NULL;
        while (1) {
            size *= 2;
            path = skynet_realloc(path, size);
            if (getcwd(path, size) != NULL) {
                lua_pushstring(L, path);
                break;
            } else if (errno != ERANGE) {
                lua_pushnil(L);
                break;
            }
        }
        skynet_free(path);
        return 1;
    }
}

/*
** Decode one UTF-8 sequence, returning NULL if byte sequence is invalid.
*/
#define MAXUNICODE	0x10FFFF
static const char *utf8_decode(const char *o, int *val) {
    static const unsigned int limits[] = {0xFF, 0x7F, 0x7FF, 0xFFFF};
    const unsigned char *s = (const unsigned char *)o;
    unsigned int c = s[0];
    unsigned int res = 0; /* final result */
    if (c < 0x80)         /* ascii? */
        res = c;
    else {
        int count = 0;               /* to count number of continuation bytes */
        while (c & 0x40) {           /* still have continuation bytes? */
            int cc = s[++count];     /* read next byte */
            if ((cc & 0xC0) != 0x80) /* not a continuation byte? */
                return NULL;         /* invalid byte sequence */
            res =
                (res << 6) | (cc & 0x3F); /* add lower 6 bits from cont. byte */
            c <<= 1;                      /* to test next bit */
        }
        res |= ((c & 0x7F) << (count * 5)); /* add first byte */
        if (count > 3 || res > MAXUNICODE || res <= limits[count])
            return NULL; /* invalid byte sequence */
        s += count;      /* skip continuation bytes read */
    }
    if (val) *val = res;
    return (const char *)s + 1; /* +1 to include first byte */
}

#define ST_START 1
#define ST_DOT 2
#define ST_DOT2 3
#define ST_SLASH 4
#define ST_NORMAL 5

static const char *next_path_comp(lua_State *L, const char *path, int *type) {
    const char *p = path;
    const char *p2;
    assert(*p == '/');
    p++;
    int ch = 0;
    int st = ST_START;
    while (*p) {
        p2 = utf8_decode(p, &ch);
        if (p2 == NULL) {
            luaL_error(L, "invalid UTF-8 code");
            return NULL;
        }
        switch (st) {
            case ST_START:
                if (ch == '.') {
                    st = ST_DOT;
                } else if (ch == '/') {  // //
                    *type = 0;
                    return p;
                } else {
                    st = ST_NORMAL;
                }
                break;
            case ST_DOT:
                if (ch == '.') {  //  /..
                    st = ST_DOT2;
                } else if (ch == '/') {  //  /./
                    *type = 0;
                    return p;
                } else {
                    st = ST_NORMAL;
                }
                break;
            case ST_DOT2:
                if (ch == '/') {  //  /../
                    *type = -1;
                    return p;
                } else {
                    st = ST_NORMAL;
                }
                break;
            case ST_NORMAL:
                if (ch == '/') {
                    *type = p - path;
                    return p;
                }
                break;
        }
        p = p2;
    }
    if (st == ST_DOT || st == ST_START) 
        *type = 0;
    else if (st == ST_DOT2)
        *type = -1;
    else
        *type = p - path;
    return NULL;
}

static int parse_path_comp(lua_State *L, const char *path, int hasn) {
    int maxn = hasn;
    int type = 0;
    while (path) {
        if (hasn == maxn) {
            maxn += 10;
            lua_checkstack(L, maxn);
        }
        const char *nextp = next_path_comp(L, path, &type);
        if (type == -1) {
            if (hasn == 0) {
                return -1;
            } else {
                lua_pop(L, 1);
                hasn--;
            }
        } else if (type > 0) {
            lua_pushlstring(L, path, (size_t)type);
            hasn++;
        }
        path = nextp;
    }
    return hasn;
}

static int abspath(lua_State *L) {
    if (lua_type(L, -1) != LUA_TSTRING)
        return 1; 
    size_t len;
    const char *path = lua_tolstring(L, 1, &len);
    if (len == 0)
        return 1;

    int n;
    if (path[0] != '/') {
        getcurrentdir(L);   // <path|workdir>
        if (lua_type(L, -1) == LUA_TNIL) 
            return 1;
        const char *workdir = lua_tolstring(L, -1, &len);
        n = 2;
        if (len && workdir[len-1] != '/') {
            lua_pushstring(L, "/");
            n = 3;
        }
        lua_pushvalue(L, 1);        // <path|workdir|/|path>
        lua_concat(L, n);       // <abspath>
    }

    // normolize path
    n = parse_path_comp(L, lua_tostring(L, -1), 0);
    if (n < 0) {
        lua_pushnil(L);
        return 1;
    }

    lua_concat(L, n);
    return 1;
}

static const luaL_Reg l[] = {
    {"sethook", sethook}, 
    {"nextseq", nextseq}, 
    {"getcwd", getcurrentdir},
    {"abspath", abspath}, 
    {NULL, NULL},
};

int luaopen_skynet_vscdebugaux(lua_State *L) {
    luaL_newlib(L, l);
    return 1;
}