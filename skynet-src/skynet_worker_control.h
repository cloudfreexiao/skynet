#ifndef SKYNET_WORKER_CONTROL_H
#define SKYNET_WORKER_CONTROL_H

#include <lobject.h>

#include <stddef.h>
#include <stdint.h>

enum skynet_worker_control_submit_result {
	SKYNET_WORKER_CONTROL_ACCEPTED = 0,
	SKYNET_WORKER_CONTROL_BUSY = 1,
	SKYNET_WORKER_CONTROL_SHUTDOWN = 2,
	SKYNET_WORKER_CONTROL_NOT_READY = 3,
};

enum skynet_worker_control_completion_status {
	SKYNET_WORKER_CONTROL_COMMITTED = 0,
	SKYNET_WORKER_CONTROL_TIMED_OUT = 1,
};

enum skynet_worker_control_state {
	SKYNET_WORKER_CONTROL_EMPTY = 0,
	SKYNET_WORKER_CONTROL_PENDING,
	SKYNET_WORKER_CONTROL_STOPPING,
	SKYNET_WORKER_CONTROL_EXECUTING,
	SKYNET_WORKER_CONTROL_RELEASING,
};

struct skynet_sharetable_storage_swap {
	Table *stable;
	Table *staging;
};

/* PTYPE_SYSTEM payload delivered after all parked workers leave the safe point. */
struct skynet_worker_control_completion {
	void *plan;
	uint32_t status;
};

/* A successful submit keeps swaps and plan alive until completion delivery.
 * They are deliberately abandoned if the destination service is retired. */
struct skynet_worker_control_task {
	const struct skynet_sharetable_storage_swap *swaps;
	size_t swap_count;
	uint32_t destination;
	struct skynet_worker_control_completion *completion;
};

typedef void (*skynet_worker_control_wake_all)(void *ud);

void skynet_worker_control_init(int worker_count,
		skynet_worker_control_wake_all wake_all, void *wake_ud);
void skynet_worker_control_destroy(void);

/* Called only by the dedicated THREAD_WORKER_CONTROL thread. */
void skynet_worker_control_run(void);

void skynet_worker_control_register_worker(void);
void skynet_worker_control_checkpoint(void);
int skynet_worker_control_stop_requested(void);

enum skynet_worker_control_submit_result
skynet_worker_control_try_submit(const struct skynet_worker_control_task *task);

void skynet_worker_control_request_shutdown(void);

#endif
