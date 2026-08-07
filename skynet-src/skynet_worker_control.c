#include "skynet_worker_control.h"

#include "atomic.h"
#include "skynet.h"
#include "skynet_mq.h"
#include "skynet_server.h"

#include <lstate.h>
#include <ltable.h>
#include <ltm.h>

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define WORKER_STOP_TIMEOUT_US UINT64_C(2000000)
#define MICROSECONDS_PER_SECOND UINT64_C(1000000)

static uint64_t
monotonic_time_us(void) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint64_t)now.tv_sec * MICROSECONDS_PER_SECOND +
		(uint64_t)now.tv_nsec / UINT64_C(1000);
}

struct worker_control {
	int worker_count;
	int registered_count;

	pthread_mutex_t mutex;
	pthread_cond_t cond;
	skynet_worker_control_wake_all wake_all;
	void *wake_ud;

	ATOM_INT stop_requested;
	bool thread_ready;
	bool shutdown;

	enum skynet_worker_control_state state;
	int parked_count;
	struct skynet_worker_control_task task;
};

static struct worker_control *CONTROL;

static void
abort_initialization(const char *message) {
	fputs(message, stderr);
	abort();
}

static void
check_pthread_initialization(int err, const char *message) {
	if (err != 0)
		abort_initialization(message);
}

void
skynet_worker_control_init(int worker_count,
		skynet_worker_control_wake_all wake_all, void *wake_ud) {
	if (worker_count <= 0)
		abort_initialization("invalid worker controller initialization\n");

	struct worker_control *c = skynet_calloc(1, sizeof(*c));
	c->worker_count = worker_count;
	c->wake_all = wake_all;
	c->wake_ud = wake_ud;
	c->state = SKYNET_WORKER_CONTROL_EMPTY;
	ATOM_INIT(&c->stop_requested, false);

	check_pthread_initialization(pthread_mutex_init(&c->mutex, NULL),
		"worker controller mutex init failed\n");
#if defined(__APPLE__) || defined(_WIN32)
	check_pthread_initialization(pthread_cond_init(&c->cond, NULL),
		"worker controller cond init failed\n");
#else
	pthread_condattr_t attr;
	check_pthread_initialization(pthread_condattr_init(&attr),
		"worker controller condattr init failed\n");
	check_pthread_initialization(
		pthread_condattr_setclock(&attr, CLOCK_MONOTONIC),
		"worker controller cond clock init failed\n");
	check_pthread_initialization(pthread_cond_init(&c->cond, &attr),
		"worker controller cond init failed\n");
	pthread_condattr_destroy(&attr);
#endif
	CONTROL = c;
}

void
skynet_worker_control_destroy(void) {
	struct worker_control *c = CONTROL;
	pthread_cond_destroy(&c->cond);
	pthread_mutex_destroy(&c->mutex);
	skynet_free(c);
	CONTROL = NULL;
}

void
skynet_worker_control_register_worker(void) {
	struct worker_control *c = CONTROL;
	pthread_mutex_lock(&c->mutex);
	c->registered_count++;
	pthread_mutex_unlock(&c->mutex);
}

int
skynet_worker_control_stop_requested(void) {
	return ATOM_LOAD(&CONTROL->stop_requested);
}

void
skynet_worker_control_checkpoint(void) {
	struct worker_control *c = CONTROL;
	if (!ATOM_LOAD(&c->stop_requested))
		return;

	pthread_mutex_lock(&c->mutex);
	if (c->state != SKYNET_WORKER_CONTROL_STOPPING) {
		pthread_mutex_unlock(&c->mutex);
		return;
	}

	c->parked_count++;
	if (c->parked_count == c->worker_count)
		pthread_cond_broadcast(&c->cond);
	while (c->state == SKYNET_WORKER_CONTROL_STOPPING ||
		c->state == SKYNET_WORKER_CONTROL_EXECUTING) {
		pthread_cond_wait(&c->cond, &c->mutex);
	}
	c->parked_count--;
	pthread_cond_signal(&c->cond);
	pthread_mutex_unlock(&c->mutex);
}

enum skynet_worker_control_submit_result
skynet_worker_control_try_submit(const struct skynet_worker_control_task *task) {
	struct worker_control *c = CONTROL;
	pthread_mutex_lock(&c->mutex);

	enum skynet_worker_control_submit_result result;
	if (c->shutdown) {
		result = SKYNET_WORKER_CONTROL_SHUTDOWN;
	} else if (!c->thread_ready ||
		c->registered_count != c->worker_count) {
		result = SKYNET_WORKER_CONTROL_NOT_READY;
	} else if (c->state != SKYNET_WORKER_CONTROL_EMPTY) {
		result = SKYNET_WORKER_CONTROL_BUSY;
	} else {
		c->task = *task;
		c->state = SKYNET_WORKER_CONTROL_PENDING;
		result = SKYNET_WORKER_CONTROL_ACCEPTED;
		pthread_cond_signal(&c->cond);
	}

	pthread_mutex_unlock(&c->mutex);
	return result;
}

void
skynet_worker_control_request_shutdown(void) {
	struct worker_control *c = CONTROL;
	pthread_mutex_lock(&c->mutex);
	c->shutdown = true;
	pthread_cond_signal(&c->cond);
	pthread_mutex_unlock(&c->mutex);
}

static void
swap_sharetable_storage(Table *stable, Table *staging) {
	const lu_byte lsizenode = stable->lsizenode;
	Node *node = stable->node;

#if LUA_VERSION_NUM == 504
	Node *lastfree = stable->lastfree;
	const unsigned int alimit = stable->alimit;
	TValue *array = stable->array;
	const int bitras = stable->flags & BITRAS;
	stable->lastfree = staging->lastfree;
	stable->alimit = staging->alimit;
	stable->array = staging->array;
	stable->flags = cast_byte((stable->flags & ~BITRAS) |
		(staging->flags & BITRAS));
	staging->lastfree = lastfree;
	staging->alimit = alimit;
	staging->array = array;
	staging->flags = cast_byte((staging->flags & ~BITRAS) | bitras);
#elif LUA_VERSION_NUM == 505
	const unsigned int asize = stable->asize;
	Value *array = stable->array;
	const int bitdummy = stable->flags & BITDUMMY;
	stable->asize = staging->asize;
	stable->array = staging->array;
	stable->flags = cast_byte((stable->flags & NOTBITDUMMY) |
		(staging->flags & BITDUMMY));
	staging->asize = asize;
	staging->array = array;
	staging->flags = cast_byte((staging->flags & NOTBITDUMMY) | bitdummy);
#else
#error unsupported Lua version
#endif

	stable->lsizenode = staging->lsizenode;
	stable->node = staging->node;
	staging->lsizenode = lsizenode;
	staging->node = node;
	invalidateTMcache(stable);
}

static void
handoff_completion(const struct skynet_worker_control_task *task,
		enum skynet_worker_control_completion_status status) {
	task->completion->status = (uint32_t)status;
	struct skynet_message message;
	message.source = 0;
	message.session = 0;
	message.data = task->completion;
	message.sz = sizeof(*task->completion) |
		((size_t)PTYPE_SYSTEM << MESSAGE_TYPE_SHIFT);
	if (skynet_context_push(task->destination, &message) != 0) {
		skynet_error(NULL, "ERROR: Worker controller completion handoff "
			"failed; ShareTable service is unavailable");
		/*
		 * All parked workers have already been released and the task slot is
		 * empty. The retired owner can no longer finalize its plan or submit
		 * more work, so abandon that plan and keep the process available.
		 */
		skynet_free(task->completion);
	}
}

static int
wait_until_locked(struct worker_control *c, uint64_t deadline_us) {
#if defined(__APPLE__) || defined(_WIN32)
	const uint64_t now_us = monotonic_time_us();
	if (deadline_us <= now_us)
		return ETIMEDOUT;
	const uint64_t remaining_us = deadline_us - now_us;
	struct timespec timeout;
	timeout.tv_sec = (time_t)(remaining_us / UINT64_C(1000000));
	timeout.tv_nsec = (long)((remaining_us % UINT64_C(1000000)) * 1000);
	return pthread_cond_timedwait_relative_np(&c->cond, &c->mutex, &timeout);
#else
	struct timespec deadline;
	deadline.tv_sec = (time_t)(deadline_us / UINT64_C(1000000));
	deadline.tv_nsec = (long)((deadline_us % UINT64_C(1000000)) * 1000);
	return pthread_cond_timedwait(&c->cond, &c->mutex, &deadline);
#endif
}

void
skynet_worker_control_run(void) {
	struct worker_control *c = CONTROL;
	pthread_mutex_lock(&c->mutex);
	c->thread_ready = true;

	for (;;) {
		while (c->state == SKYNET_WORKER_CONTROL_EMPTY && !c->shutdown)
			pthread_cond_wait(&c->cond, &c->mutex);
		if (c->state == SKYNET_WORKER_CONTROL_EMPTY && c->shutdown) {
			pthread_mutex_unlock(&c->mutex);
			return;
		}

		c->parked_count = 0;
		c->state = SKYNET_WORKER_CONTROL_STOPPING;
		ATOM_STORE(&c->stop_requested, true);
		const uint64_t deadline_us =
			monotonic_time_us() + WORKER_STOP_TIMEOUT_US;

		/* Never hold controller.mutex while acquiring monitor.mutex. */
		pthread_mutex_unlock(&c->mutex);
		c->wake_all(c->wake_ud);
		pthread_mutex_lock(&c->mutex);

		while (c->parked_count != c->worker_count) {
			if (wait_until_locked(c, deadline_us) != 0)
				break;
		}

		enum skynet_worker_control_completion_status status;
		if (c->parked_count == c->worker_count) {
			c->state = SKYNET_WORKER_CONTROL_EXECUTING;
			pthread_mutex_unlock(&c->mutex);
			for (size_t i = 0; i < c->task.swap_count; i++) {
				const struct skynet_sharetable_storage_swap *swap =
					&c->task.swaps[i];
				swap_sharetable_storage(swap->stable, swap->staging);
			}
			pthread_mutex_lock(&c->mutex);
			status = SKYNET_WORKER_CONTROL_COMMITTED;
		} else {
			status = SKYNET_WORKER_CONTROL_TIMED_OUT;
		}

		c->state = SKYNET_WORKER_CONTROL_RELEASING;
		ATOM_STORE(&c->stop_requested, false);
		pthread_cond_broadcast(&c->cond);
		while (c->parked_count != 0)
			pthread_cond_wait(&c->cond, &c->mutex);
		const struct skynet_worker_control_task task = c->task;
		memset(&c->task, 0, sizeof(c->task));
		c->state = SKYNET_WORKER_CONTROL_EMPTY;
		pthread_mutex_unlock(&c->mutex);

		/* Completion is a normal MQ message and must be sent after STW release. */
		handoff_completion(&task, status);
		c->wake_all(c->wake_ud);

		pthread_mutex_lock(&c->mutex);
	}
}
