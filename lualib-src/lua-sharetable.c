#define LUA_LIB

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <math.h>
#include <string.h>

#include "lapi.h"
#include "lgc.h"
#include "lobject.h"
#include "lstate.h"
#include "ltable.h"

#include "lua-seri.h"
#include "skynet_malloc.h"
#include "skynet_worker_control.h"

#ifdef makeshared

static void
mark_shared(lua_State *L) {
	if (lua_type(L, -1) != LUA_TTABLE) {
		luaL_error(L, "Not a table, it's a %s.", lua_typename(L, lua_type(L, -1)));
	}
	Table * t = (Table *)lua_topointer(L, -1);
	if (isshared(t))
		return;
	makeshared(t);
	luaL_checkstack(L, 4, NULL);
	if (lua_getmetatable(L, -1)) {
		luaL_error(L, "Can't share metatable");
	}
	lua_pushnil(L);
	while (lua_next(L, -2) != 0) {
		int i;
		for (i=0;i<2;i++) {
			int idx = -i-1;
			int t = lua_type(L, idx);
			switch (t) {
			case LUA_TTABLE:
				mark_shared(L);
				break;
			case LUA_TNUMBER:
			case LUA_TBOOLEAN:
			case LUA_TLIGHTUSERDATA:
				break;
			case LUA_TSTRING:
				lua_sharestring(L, idx);
				break;
			default:
				luaL_error(L, "Invalid type [%s]", lua_typename(L, t));
				break;
			}
		}
		lua_pop(L, 1);
	}
}

static int
lis_sharedtable(lua_State* L) {
	int b = 0;
	if(lua_type(L, 1) == LUA_TTABLE) {
		Table * t = (Table *)lua_topointer(L, 1);
		b = isshared(t);
	}
	lua_pushboolean(L, b);
	return 1;
}

static int
clone_table(lua_State *L) {
	lua_clonetable(L, lua_touserdata(L, 1));

	return 1;
}

struct state_ud {
	lua_State *L;
	unsigned int lease;
};

static int
close_state(lua_State *L) {
	struct state_ud *ud = (struct state_ud *)luaL_checkudata(L, 1, "BOXMATRIXSTATE");
	if (ud->lease != 0)
		return luaL_error(L, "matrix update is in progress");
	if (ud->L) {
		lua_close(ud->L);
		ud->L = NULL;
	}
	return 0;
}

static int
get_matrix(lua_State *L) {
	struct state_ud *ud = (struct state_ud *)luaL_checkudata(L, 1, "BOXMATRIXSTATE");
	if (ud->L) {
		const void * v = lua_topointer(ud->L, 1);
		lua_pushlightuserdata(L, (void *)v);
		return 1;
	}
	return 0;
}

static int
get_size(lua_State *L) {
	struct state_ud *ud = (struct state_ud *)luaL_checkudata(L, 1, "BOXMATRIXSTATE");
	if (ud->L) {
		lua_Integer sz = lua_gc(ud->L, LUA_GCCOUNT, 0);
		sz *= 1024;
		sz += lua_gc(ud->L, LUA_GCCOUNTB, 0);
		lua_pushinteger(L, sz);
	} else {
		lua_pushinteger(L, 0);
	}
	return 1;
}

struct merge_plan {
	struct state_ud **matrices;
	size_t matrix_count;
	size_t matrix_capacity;
	struct skynet_sharetable_storage_swap *swaps;
	size_t swap_count;
	size_t swap_capacity;
};

struct merge_job {
	struct merge_plan *plan;
	Table *stable;
	const void **seen_tables;
	size_t seen_count;
	size_t seen_capacity;
	int seen_index;  // 0 when candidate transport already guarantees a tree
	const char *error;
};

static int
merge_fail(struct merge_job *job, const char *error) {
	job->error = error;
	return 0;
}

static int
remember_table(lua_State *L, struct merge_job *job, const void *table) {
	if (job->seen_index != 0) {
		lua_pushlightuserdata(L, (void *)table);
		lua_rawget(L, job->seen_index);
		if (!lua_isnil(L, -1)) {
			lua_pop(L, 1);
			return 0;
		}
		lua_pop(L, 1);
		lua_pushlightuserdata(L, (void *)table);
		lua_pushboolean(L, 1);
		lua_rawset(L, job->seen_index);
		return 1;
	}
	if (job->seen_count == job->seen_capacity) {
		size_t capacity = job->seen_capacity == 0 ? 64 :
			job->seen_capacity * 2;
		const void **tables = skynet_realloc(job->seen_tables,
			capacity * sizeof(*tables));
		job->seen_tables = tables;
		job->seen_capacity = capacity;
	}
	job->seen_tables[job->seen_count++] = table;
	return 1;
}

static int
validate_scalar(lua_State *L, int index, struct merge_job *job, int key) {
	switch (lua_type(L, index)) {
	case LUA_TBOOLEAN:
	case LUA_TSTRING:
	case LUA_TLIGHTUSERDATA:
		return 1;
	case LUA_TNUMBER:
		if (!lua_isinteger(L, index) &&
			!isfinite((double)lua_tonumber(L, index)))
			return merge_fail(job, "ShareTable numbers must be finite");
		return 1;
	default:
		return merge_fail(job, key ? "invalid ShareTable key" :
			"invalid ShareTable value");
	}
}

static int
validate_table(lua_State *L, int index, struct merge_job *job) {
	index = lua_absindex(L, index);
	if (!lua_checkstack(L, 4))
		return merge_fail(job, "ShareTable tree is too deep");
	if (lua_getmetatable(L, index)) {
		lua_pop(L, 1);
		return merge_fail(job, "ShareTable tables cannot have metatables");
	}
	Table *table = (Table *)lua_topointer(L, index);
	if (isshared(table))
		return merge_fail(job, "ShareTable source must build a fresh table tree");
	int seen = remember_table(L, job, table);
	if (seen == 0)
		return merge_fail(job, "ShareTable cannot contain aliases or cycles");

	lua_pushnil(L);
	while (lua_next(L, index) != 0) {
		if (!validate_scalar(L, -2, job, 1)) {
			lua_pop(L, 2);
			return 0;
		}
		if (lua_type(L, -1) == LUA_TTABLE) {
			if (!validate_table(L, -1, job)) {
				lua_pop(L, 2);
				return 0;
			}
		} else if (!validate_scalar(L, -1, job, 0)) {
			lua_pop(L, 2);
			return 0;
		}
		lua_pop(L, 1);
	}
	return 1;
}

static int
make_matrix(lua_State *L) {
	lua_newtable(L);
	struct merge_job job;
	memset(&job, 0, sizeof(job));
	job.seen_index = lua_absindex(L, -1);
	if (!validate_table(L, -2, &job))
		return luaL_error(L, "%s", job.error);
	lua_pop(L, 1);
	lua_gc(L, LUA_GCCOLLECT, 0);
	// turn off gc , because marking shared will prevent gc mark.
	lua_gc(L, LUA_GCSTOP, 0);
	G(L)->gcstopem = 1;
	mark_shared(L);
	Table * t = (Table *)lua_topointer(L, -1);
	lua_pushlightuserdata(L, t);
	return 1;
}

static void
plan_add_swap(struct merge_job *job, Table *stable, Table *staging) {
	struct merge_plan *plan = job->plan;
	if (plan->swap_count == plan->swap_capacity) {
		size_t capacity = plan->swap_capacity == 0 ? 64 :
			plan->swap_capacity * 2;
		struct skynet_sharetable_storage_swap *swaps = skynet_realloc(
			plan->swaps, capacity * sizeof(*swaps));
		plan->swaps = swaps;
		plan->swap_capacity = capacity;
	}
	plan->swaps[plan->swap_count].stable = stable;
	plan->swaps[plan->swap_count].staging = staging;
	plan->swap_count++;
}

static void
plan_add_matrix(struct merge_plan *plan, struct state_ud *matrix) {
	if (plan->matrix_count == plan->matrix_capacity) {
		size_t capacity = plan->matrix_capacity == 0 ? 4 :
			plan->matrix_capacity * 2;
		struct state_ud **matrices = skynet_realloc(plan->matrices,
			capacity * sizeof(*matrices));
		plan->matrices = matrices;
		plan->matrix_capacity = capacity;
	}
	plan->matrices[plan->matrix_count++] = matrix;
}

static int
same_value(lua_State *L, int left, int right) {
	if (lua_type(L, left) == LUA_TNUMBER &&
		lua_type(L, right) == LUA_TNUMBER &&
		lua_isinteger(L, left) != lua_isinteger(L, right))
		return 0;
	return lua_rawequal(L, left, right);
}

static int
build_swaps(lua_State *L, int stable_index, int staging_index,
		struct merge_job *job) {
	stable_index = lua_absindex(L, stable_index);
	staging_index = lua_absindex(L, staging_index);
	if (!lua_checkstack(L, 4))
		return merge_fail(job, "ShareTable tree is too deep");
	Table *stable = (Table *)lua_topointer(L, stable_index);
	Table *staging = (Table *)lua_topointer(L, staging_index);
	int direct_changed = 0;

	lua_pushnil(L);
	while (lua_next(L, staging_index) != 0) {
		lua_pushvalue(L, -2);
		lua_rawget(L, stable_index);
		if (lua_type(L, -1) == LUA_TTABLE &&
			lua_type(L, -2) == LUA_TTABLE) {
			if (!build_swaps(L, -1, -2, job)) {
				lua_pop(L, 3);
				return 0;
			}
			lua_pushvalue(L, -3);
			lua_pushvalue(L, -2);
			lua_rawset(L, staging_index);
		} else if (!same_value(L, -1, -2)) {
			direct_changed = 1;
		}
		lua_pop(L, 2);
	}

	lua_pushnil(L);
	while (lua_next(L, stable_index) != 0) {
		lua_pushvalue(L, -2);
		lua_rawget(L, staging_index);
		if (lua_isnil(L, -1))
			direct_changed = 1;
		lua_pop(L, 2);
	}

	if (direct_changed)
		plan_add_swap(job, stable, staging);
	return 1;
}

static void
mark_shared_direct(lua_State *L, int index) {
	index = lua_absindex(L, index);
	lua_pushnil(L);
	while (lua_next(L, index) != 0) {
		if (lua_type(L, -2) == LUA_TSTRING)
			lua_sharestring(L, -2);
		if (lua_type(L, -1) == LUA_TSTRING)
			lua_sharestring(L, -1);
		lua_pop(L, 1);
	}
	makeshared((Table *)lua_topointer(L, index));
}

static void
mark_candidate_shared(lua_State *L, const struct merge_job *job) {
	for (size_t i = 0; i < job->seen_count; i++) {
		Table *table = (Table *)job->seen_tables[i];
		sethvalue2s(L, L->top.p, table);
		api_incr_top(L);
		mark_shared_direct(L, -1);
		lua_pop(L, 1);
	}
}

static int
prepare_merge_entry(lua_State *L) {
	struct merge_job *job = lua_touserdata(L, 1);
	luaL_checktype(L, 2, LUA_TTABLE);
	lua_settop(L, 2);

	int candidate = 2;
	if (!validate_table(L, candidate, job))
		return luaL_error(L, "%s", job->error);
	lua_clonetable(L, job->stable);
	if (!build_swaps(L, -1, candidate, job))
		return luaL_error(L, "%s", job->error);
	lua_pop(L, 1);
	mark_candidate_shared(L, job);
	return 0;
}

static int
raise_matrix_error(lua_State *L, lua_State *mL, const char *fallback) {
	const char *error = lua_tostring(mL, -1);
	lua_pushstring(L, error == NULL ? fallback : error);
	lua_settop(mL, 1);
	return lua_error(L);
}

static struct merge_plan *
check_merge_plan(lua_State *L, int index);

static int
prepare_merge(lua_State *L) {
	struct state_ud *ud = (struct state_ud *)luaL_checkudata(L, 1,
		"BOXMATRIXSTATE");
	if (ud->L == NULL)
		return luaL_error(L, "matrix is closed");
	if (ud->lease != 0)
		return luaL_error(L, "matrix update is in progress");
	void *buffer = lua_touserdata(L, 2);
	lua_Integer size = luaL_checkinteger(L, 3);
	lua_State *mL = ud->L;
	lua_settop(mL, 1);
	if (!lua_checkstack(mL, 3))
		return luaL_error(L, "not enough stack for ShareTable candidate");
	lua_pushcfunction(mL, luaseri_unpack);
	lua_pushlightuserdata(mL, buffer);
	lua_pushinteger(mL, size);
	int status = lua_pcall(mL, 2, 1, 0);
	lua_gc(mL, LUA_GCSTOP, 0);
	G(mL)->gcstopem = 1;
	if (status != LUA_OK)
		return raise_matrix_error(L, mL, "ShareTable build failed");

	const int new_plan = lua_isnoneornil(L, 4);
	struct merge_plan *plan = new_plan ?
		skynet_calloc(1, sizeof(*plan)) : check_merge_plan(L, 4);
	const size_t initial_swap_count = plan->swap_count;
	struct merge_job job;
	memset(&job, 0, sizeof(job));
	job.plan = plan;
	job.stable = (Table *)lua_touserdata(mL, 1);
	lua_pushcfunction(mL, prepare_merge_entry);
	lua_pushlightuserdata(mL, &job);
	lua_pushvalue(mL, 2);
	if (lua_pcall(mL, 2, 0, 0) != LUA_OK) {
		skynet_free(job.seen_tables);
		plan->swap_count = initial_swap_count;
		if (new_plan) {
			skynet_free(plan->swaps);
			skynet_free(plan);
		}
		return raise_matrix_error(L, mL, "ShareTable merge preparation failed");
	}
	lua_settop(mL, 1);
	skynet_free(job.seen_tables);
	plan_add_matrix(plan, ud);
	ud->lease = 1;
	lua_pushlightuserdata(L, plan);
	lua_pushboolean(L, plan->swap_count != 0);
	return 2;
}

static struct merge_plan *
check_merge_plan(lua_State *L, int index) {
	struct merge_plan *plan = lua_touserdata(L, index);
	if (plan == NULL)
		luaL_argerror(L, index, "merge plan expected");
	return plan;
}

static int
submit_merge(lua_State *L) {
	struct merge_plan *plan = check_merge_plan(L, 1);
	uint32_t destination = (uint32_t)luaL_checkinteger(L, 2);
	struct skynet_worker_control_completion *completion =
		skynet_malloc(sizeof(*completion));
	completion->plan = plan;
	struct skynet_worker_control_task task = {
		.swaps = plan->swaps,
		.swap_count = plan->swap_count,
		.destination = destination,
		.completion = completion,
	};
	enum skynet_worker_control_submit_result result =
		skynet_worker_control_try_submit(&task);
	if (result == SKYNET_WORKER_CONTROL_ACCEPTED) {
		lua_pushboolean(L, 1);
		return 1;
	}
	skynet_free(completion);
	lua_pushboolean(L, 0);
	if (result == SKYNET_WORKER_CONTROL_SHUTDOWN)
		lua_pushliteral(L, "Worker Controller is shutting down");
	else if (result == SKYNET_WORKER_CONTROL_NOT_READY)
		lua_pushliteral(L, "Worker Controller is not ready");
	else
		lua_pushliteral(L, "Worker Controller is busy");
	return 2;
}

static int
finalize_merge(lua_State *L) {
	struct merge_plan *plan = check_merge_plan(L, 1);
	for (size_t i = 0; i < plan->matrix_count; i++)
		plan->matrices[i]->lease = 0;
	skynet_free(plan->matrices);
	skynet_free(plan->swaps);
	skynet_free(plan);
	return 0;
}

static int
unpack_completion(lua_State *L) {
	const void *message = lua_touserdata(L, 1);
	size_t size = (size_t)luaL_checkinteger(L, 2);
	if (message == NULL || size != sizeof(struct skynet_worker_control_completion))
		return luaL_error(L, "invalid Worker Controller completion");
	const struct skynet_worker_control_completion *completion = message;
	lua_pushlightuserdata(L, completion->plan);
	if (completion->status == SKYNET_WORKER_CONTROL_COMMITTED) {
		lua_pushboolean(L, 1);
	} else if (completion->status == SKYNET_WORKER_CONTROL_TIMED_OUT) {
		lua_pushboolean(L, 0);
	} else {
		return luaL_error(L, "invalid Worker Controller completion status");
	}
	return 2;
}

static int
box_state(lua_State *L, lua_State *mL) {
	struct state_ud *ud = (struct state_ud *)lua_newuserdatauv(L, sizeof(*ud), 0);
	ud->L = mL;
	ud->lease = 0;
	if (luaL_newmetatable(L, "BOXMATRIXSTATE")) {
		lua_pushvalue(L, -1);
		lua_setfield(L, -2, "__index");
		lua_pushcfunction(L, close_state);
		lua_setfield(L, -2, "close");
		lua_pushcfunction(L, get_matrix);
		lua_setfield(L, -2, "getptr");
		lua_pushcfunction(L, get_size);
		lua_setfield(L, -2, "size");
		lua_pushcfunction(L, prepare_merge);
		lua_setfield(L, -2, "prepare_merge");
	}
	lua_setmetatable(L, -2);

	return 1;
}

static int
load_matrixfile(lua_State *L) {
	luaL_openlibs(L);
	const char * source = (const char *)lua_touserdata(L, 1);
	if (source[0] == '@') {
		if (luaL_loadfilex_(L, source+1, NULL) != LUA_OK)
			lua_error(L);
	} else {
		if (luaL_loadstring(L, source) != LUA_OK)
			lua_error(L);
	}
	lua_replace(L, 1);
	if (lua_pcall(L, lua_gettop(L) - 1, 1, 0) != LUA_OK)
		lua_error(L);
	lua_pushcfunction(L, make_matrix);
	lua_insert(L, -2);
	lua_call(L, 1, 1);
	return 1;
}

static int
matrix_from_file(lua_State *L) {
#if LUA_VERSION_NUM >= 505
	lua_State *mL = lua_newstate(luaL_alloc, NULL, G(L)->seed);
#else
	lua_State *mL = luaL_newstate();
#endif
	if (mL == NULL) {
		return luaL_error(L, "luaL_newstate failed");
	}
	const char * source = luaL_checkstring(L, 1);
	int top = lua_gettop(L);
	lua_pushcfunction(mL, load_matrixfile);
	lua_pushlightuserdata(mL, (void *)source);
	if (top > 1) {
		if (!lua_checkstack(mL, top + 1)) {
			return luaL_error(L, "Too many argument %d", top);
		}
		int i;
		for (i=2;i<=top;i++) {
			switch(lua_type(L, i)) {
			case LUA_TBOOLEAN:
				lua_pushboolean(mL, lua_toboolean(L, i));
				break;
			case LUA_TNUMBER:
				if (lua_isinteger(L, i)) {
					lua_pushinteger(mL, lua_tointeger(L, i));
				} else {
					lua_pushnumber(mL, lua_tonumber(L, i));
				}
				break;
			case LUA_TLIGHTUSERDATA:
				lua_pushlightuserdata(mL, lua_touserdata(L, i));
				break;
			case LUA_TFUNCTION:
				if (lua_iscfunction(L, i) && lua_getupvalue(L, i, 1) == NULL) {
					lua_pushcfunction(mL, lua_tocfunction(L, i));
					break;
				}
				return luaL_argerror(L, i, "Only support light C function");
			default:
				return luaL_argerror(L, i, "Type invalid");
			}
		}
	}
	int ok = lua_pcall(mL, top, 1, 0);
	if (ok != LUA_OK) {
		lua_pushstring(L, lua_tostring(mL, -1));
		lua_close(mL);
		lua_error(L);
	}
	return box_state(L, mL);
}

LUAMOD_API int
luaopen_skynet_sharetable_core(lua_State *L) {
	luaL_checkversion(L);
	luaL_Reg l[] = {
		{ "clone", clone_table },
		{ "matrix", matrix_from_file },
		{ "is_sharedtable", lis_sharedtable },
		{ "submit_merge", submit_merge },
		{ "finalize_merge", finalize_merge },
		{ "unpack_completion", unpack_completion },
		{ NULL, NULL },
	};
	luaL_newlib(L, l);
	return 1;
}

#else

LUAMOD_API int
luaopen_skynet_sharetable_core(lua_State *L) {
	return luaL_error(L, "No share string table support");
}

#endif
