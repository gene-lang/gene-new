#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "native_api.h"

/* Producer threads for the async ABI tests. Thread modes: 0 runs on the
 * caller (the runtime root lane), 1 attaches first, 2 never attaches. */

#define MAX_JOBS 4096u
#define OPT_PIN 1u
#define OPT_TWO_PHASE 2u
#define OPT_JOIN_ON_RETIRE 4u

typedef struct Registration { int marker; } Registration;

static const GeneApi *api;
static GeneHandle environment;
static GeneHandle callables[3];
static GeneRegistration registrations[3];
static GeneHandle factory;
static GeneProducer producers[MAX_JOBS];
static uint32_t options;
static atomic_uint context_retires;

static GeneOutBytes no_diagnostic(void) {
  GeneOutBytes diagnostic = {0};
  return diagnostic;
}

/* ---- callbacks ---------------------------------------------------------- */

static uint32_t start_task(const GeneApi *table, void *raw,
                           const GeneHandle *args, size_t count,
                           const GeneNamedArg *named, size_t named_count,
                           GeneHandle env, GeneHandle *out, GeneHandle *error,
                           GeneOutBytes *diagnostic) {
  (void)raw; (void)named; (void)named_count; (void)error;
  int64_t index = -1;
  if (count != 1 || table->copy_i64(table->runtime_context, args[0], &index,
                                    diagnostic) != GENE_API_OK ||
      index < 0 || (uint64_t)index >= MAX_JOBS) return GENE_API_ERROR;
  return table->new_task(table->runtime_context, env, out,
                         &producers[index], diagnostic);
}

static uint32_t settle_task(const GeneApi *table, void *raw,
                            const GeneHandle *args, size_t count,
                            const GeneNamedArg *named, size_t named_count,
                            GeneHandle env, GeneHandle *out, GeneHandle *error,
                            GeneOutBytes *diagnostic) {
  (void)raw; (void)named; (void)named_count; (void)env; (void)error;
  int64_t index = -1;
  uint8_t accepted = 0;
  if (count != 2 || table->copy_i64(table->runtime_context, args[0], &index,
                                    diagnostic) != GENE_API_OK ||
      index < 0 || (uint64_t)index >= MAX_JOBS) return GENE_API_ERROR;
  uint32_t status = table->task_complete(table->runtime_context,
                                         producers[index], args[1],
                                         &accepted, diagnostic);
  if (status == GENE_API_OK) producers[index] = 0;
  *out = 0;
  return status;
}

static uint32_t register_factory(const GeneApi *table, void *raw,
                                 const GeneHandle *args, size_t count,
                                 const GeneNamedArg *named, size_t named_count,
                                 GeneHandle env, GeneHandle *out,
                                 GeneHandle *error, GeneOutBytes *diagnostic) {
  (void)raw; (void)named; (void)named_count; (void)env; (void)error;
  if (count != 1) return GENE_API_ERROR;
  if (factory) table->release(table->runtime_context, factory, diagnostic);
  factory = 0;
  *out = 0;
  return table->retain(table->runtime_context, args[0], &factory, diagnostic);
}

/* ---- worker threads ----------------------------------------------------- */

static pthread_t workers[64];
static atomic_uint worker_count;

static void join_workers(void) {
  uint32_t count = atomic_exchange(&worker_count, 0);
  for (uint32_t i = 0; i < count; ++i) pthread_join(workers[i], NULL);
}

static void retire_registration(void *raw) {
  /* Under two-phase close no producer remains, so joining cannot wait on
   * the root lane. */
  if (options & OPT_JOIN_ON_RETIRE) join_workers();
  free(raw);
  atomic_fetch_add(&context_retires, 1);
}

enum { OP_SUBMIT, OP_FAIL, OP_RETIRE_QUEUED, OP_CANCEL_QUERY, OP_SYNC,
       OP_CLOSING };

typedef struct Op {
  uint32_t op, index, which, use_factory, has_detail;
  GeneCopiedResult value, detail;
  const uint8_t *message;
  size_t message_length;
  uint8_t flag;
  uint32_t status;
} Op;

static void perform(Op *op) {
  GeneOutBytes diagnostic = no_diagnostic();
  void *context = api->runtime_context;
  GeneProducer producer = producers[op->index];
  switch (op->op) {
  case OP_SUBMIT:
    op->status = api->task_submit_copy(context, producer, &op->value,
                                       &diagnostic);
    break;
  case OP_FAIL:
    op->status = api->task_fail_copy(context, producer,
                                     op->use_factory ? factory : 0,
                                     op->message, op->message_length,
                                     op->has_detail ? &op->detail : NULL,
                                     &diagnostic);
    break;
  case OP_RETIRE_QUEUED:
    op->status = api->task_retire_queued(context, producer, &diagnostic);
    break;
  case OP_CANCEL_QUERY:
    op->status = api->task_cancel_requested(context, producer, &op->flag,
                                            &diagnostic);
    break;
  case OP_CLOSING:
    op->status = api->module_closing(context, &op->flag, &diagnostic);
    break;
  case OP_SYNC: {
    uint8_t accepted = 0;
    const uint8_t text[] = "sync";
    if (op->which == 0)
      op->status = api->task_complete(context, producer, 0, &accepted,
                                      &diagnostic);
    else if (op->which == 1)
      op->status = api->task_fail(context, producer, text, 4, 0, &accepted,
                                  &diagnostic);
    else if (op->which == 2)
      op->status = api->task_cancel(context, producer, &accepted,
                                    &diagnostic);
    else
      op->status = api->task_retire(context, producer, &accepted,
                                    &diagnostic);
    break;
  }
  }
  if (op->status == GENE_API_OK &&
      (op->op == OP_SUBMIT || op->op == OP_FAIL || op->op == OP_RETIRE_QUEUED))
    producers[op->index] = 0;
}

static void *attached_op(void *raw) {
  Op *op = raw;
  GeneOutBytes diagnostic = no_diagnostic();
  uint64_t attachment = 0;
  op->status = api->attach_thread(api->runtime_context, &attachment,
                                  &diagnostic);
  if (op->status != GENE_API_OK) return NULL;
  perform(op);
  if (api->detach_thread(api->runtime_context, attachment,
                         &diagnostic) != GENE_API_OK)
    op->status = GENE_API_ERROR;
  return NULL;
}

static void *unattached_op(void *raw) {
  perform(raw);
  return NULL;
}

static uint32_t run(Op *op, uint32_t mode) {
  if (mode == 0) {
    perform(op);
    return op->status;
  }
  if (mode == 1 && !api->attach_thread) return GENE_API_ERROR;
  pthread_t thread;
  if (pthread_create(&thread, NULL, mode == 1 ? attached_op : unattached_op,
                     op) != 0) return GENE_API_ERROR;
  pthread_join(thread, NULL); /* the thread has exited before the root drains */
  return op->status;
}

uint32_t gene_async_submit(uint32_t index, uint32_t kind, int64_t scalar,
                           const uint8_t *data, size_t length, uint32_t mode) {
  Op op = {.op = OP_SUBMIT, .index = index,
           .value = {.kind = kind, .scalar = scalar, .data = data,
                     .length = length},
           .status = GENE_API_ERROR};
  return run(&op, mode);
}

uint32_t gene_async_fail(uint32_t index, uint32_t use_factory,
                         const uint8_t *message, size_t message_length,
                         uint32_t detail_kind, int64_t detail_scalar,
                         const uint8_t *detail_data, size_t detail_length,
                         uint32_t mode) {
  Op op = {.op = OP_FAIL, .index = index, .use_factory = use_factory,
           .has_detail = detail_kind != UINT32_MAX,
           .detail = {.kind = detail_kind == UINT32_MAX ? 0 : detail_kind,
                      .scalar = detail_scalar, .data = detail_data,
                      .length = detail_length},
           .message = message, .message_length = message_length,
           .status = GENE_API_ERROR};
  return run(&op, mode);
}

uint32_t gene_async_retire_queued(uint32_t index, uint32_t mode) {
  Op op = {.op = OP_RETIRE_QUEUED, .index = index, .status = GENE_API_ERROR};
  return run(&op, mode);
}

uint32_t gene_async_cancel_requested(uint32_t index, uint32_t mode,
                                     uint8_t *flag) {
  Op op = {.op = OP_CANCEL_QUERY, .index = index, .status = GENE_API_ERROR};
  uint32_t status = run(&op, mode);
  *flag = op.flag;
  return status;
}

uint32_t gene_async_sync(uint32_t index, uint32_t which, uint32_t mode) {
  Op op = {.op = OP_SYNC, .index = index, .which = which,
           .status = GENE_API_ERROR};
  return run(&op, mode);
}

uint32_t gene_async_module_closing(uint32_t mode, uint8_t *flag) {
  Op op = {.op = OP_CLOSING, .status = GENE_API_ERROR};
  uint32_t status = run(&op, mode);
  *flag = op.flag;
  return status;
}

uint64_t gene_async_producer(uint32_t index) { return producers[index]; }

/* Burst: unattached threads settle a range of producers concurrently, mixing
 * results, queued failures and queued retirements, retrying a full queue. */
typedef struct Burst {
  uint32_t first, count;
  atomic_uint next, failures;
} Burst;

static Burst burst;

static void *burst_worker(void *unused) {
  (void)unused;
  GeneOutBytes diagnostic = no_diagnostic();
  for (;;) {
    uint32_t offset = atomic_fetch_add(&burst.next, 1);
    if (offset >= burst.count) break;
    uint32_t index = burst.first + offset;
    /* A burst holds at most 256 budgeted entries after the previous drain,
     * and retirements are outside the budget, so no entry is rejected. */
    uint32_t status;
    if (index % 7 == 0) {
      status = api->task_retire_queued(api->runtime_context, producers[index],
                                       &diagnostic);
    } else if (index % 3 == 0) {
      const uint8_t text[] = "burst failure";
      status = api->task_fail_copy(api->runtime_context, producers[index], 0,
                                   text, sizeof(text) - 1, NULL, &diagnostic);
    } else {
      GeneCopiedResult value = {.kind = GENE_COPY_I64, .scalar = index};
      status = api->task_submit_copy(api->runtime_context, producers[index],
                                     &value, &diagnostic);
    }
    if (status != GENE_API_OK) atomic_fetch_add(&burst.failures, 1);
    else producers[index] = 0;
  }
  return NULL;
}

uint32_t gene_async_burst(uint32_t first, uint32_t count, uint32_t threads) {
  if (threads == 0 || threads > 16 || first + count > MAX_JOBS)
    return GENE_API_ERROR;
  burst.first = first;
  burst.count = count;
  atomic_store(&burst.next, 0);
  atomic_store(&burst.failures, 0);
  pthread_t pool[16];
  for (uint32_t i = 0; i < threads; ++i)
    if (pthread_create(&pool[i], NULL, burst_worker, NULL) != 0)
      return GENE_API_ERROR;
  for (uint32_t i = 0; i < threads; ++i) pthread_join(pool[i], NULL);
  return atomic_load(&burst.failures) == 0 ? GENE_API_OK : GENE_API_ERROR;
}

/* Background producers whose completion needs root-lane draining: the root
 * must keep polling while they retry a full queue. */
static atomic_uint background_done;

static void *background_worker(void *raw) {
  uint32_t index = (uint32_t)(uintptr_t)raw;
  GeneOutBytes diagnostic = no_diagnostic();
  GeneCopiedResult value = {.kind = GENE_COPY_I64, .scalar = index};
  while (api->task_submit_copy(api->runtime_context, producers[index],
                               &value, &diagnostic) != GENE_API_OK)
    usleep(200);
  producers[index] = 0;
  atomic_fetch_add(&background_done, 1);
  return NULL;
}

uint32_t gene_async_background(uint32_t first, uint32_t count) {
  if (count > 64 || first + count > MAX_JOBS) return GENE_API_ERROR;
  for (uint32_t i = 0; i < count; ++i) {
    uint32_t slot = atomic_fetch_add(&worker_count, 1);
    if (pthread_create(&workers[slot], NULL, background_worker,
                       (void *)(uintptr_t)(first + i)) != 0)
      return GENE_API_ERROR;
  }
  return GENE_API_OK;
}

uint32_t gene_async_background_done(void) {
  return atomic_load(&background_done);
}

void gene_async_join_workers(void) { join_workers(); }

/* Held attacher: a worker that attaches only after module close began. */
static pthread_t held_thread;
static atomic_uint held_go;
static uint32_t held_status;

static void *held_worker(void *raw) {
  uint32_t index = (uint32_t)(uintptr_t)raw;
  while (!atomic_load(&held_go)) usleep(100);
  GeneOutBytes diagnostic = no_diagnostic();
  uint64_t attachment = 0;
  uint8_t accepted = 0;
  held_status = api->attach_thread(api->runtime_context, &attachment,
                                   &diagnostic);
  if (held_status != GENE_API_OK) return NULL;
  held_status = index % 2
      ? api->task_retire(api->runtime_context, producers[index], &accepted,
                         &diagnostic)
      : api->task_complete(api->runtime_context, producers[index], 0,
                           &accepted, &diagnostic);
  if (held_status == GENE_API_OK) producers[index] = 0;
  if (api->detach_thread(api->runtime_context, attachment,
                         &diagnostic) != GENE_API_OK)
    held_status = GENE_API_ERROR;
  return NULL;
}

uint32_t gene_async_hold_attacher(uint32_t index) {
  atomic_store(&held_go, 0);
  held_status = GENE_API_ERROR;
  return pthread_create(&held_thread, NULL, held_worker,
                        (void *)(uintptr_t)index) == 0
             ? GENE_API_OK : GENE_API_ERROR;
}

uint32_t gene_async_release_attacher(void) {
  atomic_store(&held_go, 1);
  pthread_join(held_thread, NULL);
  return held_status;
}

/* Cancellation callbacks with per-job order checks. */
typedef struct CancelState { atomic_uint fired, retired, violations; } CancelState;
static CancelState cancel_state[MAX_JOBS];
static atomic_uint cancel_fired_total, cancel_retired_total;

typedef struct CancelContext { uint32_t index; int marker; } CancelContext;

static void on_cancel(void *raw) {
  CancelContext *context = raw;
  CancelState *state = &cancel_state[context->index];
  if (context->marker != 0x5a || atomic_load(&state->retired))
    atomic_fetch_add(&state->violations, 1);
  if (atomic_fetch_add(&state->fired, 1) != 0)
    atomic_fetch_add(&state->violations, 1);
  atomic_fetch_add(&cancel_fired_total, 1);
}

static void retire_cancel(void *raw) {
  CancelContext *context = raw;
  CancelState *state = &cancel_state[context->index];
  if (atomic_fetch_add(&state->retired, 1) != 0)
    atomic_fetch_add(&state->violations, 1);
  atomic_fetch_add(&cancel_retired_total, 1);
  context->marker = 0;
  free(context);
}

uint32_t gene_async_on_cancel(uint32_t index) {
  CancelContext *context = calloc(1, sizeof(*context));
  if (!context) return GENE_API_ERROR;
  context->index = index;
  context->marker = 0x5a;
  memset(&cancel_state[index], 0, sizeof(cancel_state[index]));
  GeneOutBytes diagnostic = no_diagnostic();
  uint32_t status = api->task_on_cancel(api->runtime_context, producers[index],
                                        on_cancel, context, retire_cancel,
                                        &diagnostic);
  if (status != GENE_API_OK) free(context); /* failure keeps ownership here */
  return status;
}

void gene_async_cancel_counts(uint32_t index, uint32_t *fired,
                              uint32_t *retired, uint32_t *violations) {
  *fired = atomic_load(&cancel_state[index].fired);
  *retired = atomic_load(&cancel_state[index].retired);
  *violations = atomic_load(&cancel_state[index].violations);
}

uint32_t gene_async_cancel_totals(uint32_t *retired) {
  *retired = atomic_load(&cancel_retired_total);
  return atomic_load(&cancel_fired_total);
}

/* A delayed settlement racing a root-lane cancel: sleeps `delay_us`, then
 * queues a result from a thread that never attached. */
static void *delayed_submit(void *raw) {
  uintptr_t packed = (uintptr_t)raw;
  uint32_t index = (uint32_t)(packed & 0xffffu);
  uint32_t delay = (uint32_t)(packed >> 16);
  if (delay) usleep(delay);
  GeneOutBytes diagnostic = no_diagnostic();
  GeneCopiedResult value = {.kind = GENE_COPY_I64, .scalar = index};
  while (api->task_submit_copy(api->runtime_context, producers[index],
                               &value, &diagnostic) != GENE_API_OK)
    usleep(100);
  producers[index] = 0;
  return NULL;
}

uint32_t gene_async_delayed_submit(uint32_t index, uint32_t delay_us) {
  if (index > 0xffffu) return GENE_API_ERROR;
  uint32_t slot = atomic_fetch_add(&worker_count, 1);
  return pthread_create(&workers[slot], NULL, delayed_submit,
                        (void *)(((uintptr_t)delay_us << 16) | index)) == 0
             ? GENE_API_OK : GENE_API_ERROR;
}

/* Code still running in the library: a worker that keeps executing library
 * code after its last runtime call, and a driver callback entered later. */
static atomic_uint tail_done;

static void *tail_worker(void *raw) {
  uint32_t index = (uint32_t)(uintptr_t)raw;
  GeneOutBytes diagnostic = no_diagnostic();
  GeneCopiedResult value = {.kind = GENE_COPY_I64, .scalar = 7};
  api->task_submit_copy(api->runtime_context, producers[index], &value,
                        &diagnostic);
  producers[index] = 0;
  usleep(300000); /* library code after the last runtime call */
  atomic_fetch_add(&tail_done, 1);
  return NULL;
}

uint32_t gene_async_tail_worker(uint32_t index) {
  pthread_t thread;
  if (pthread_create(&thread, NULL, tail_worker,
                     (void *)(uintptr_t)index) != 0) return GENE_API_ERROR;
  pthread_detach(thread);
  return GENE_API_OK;
}

void gene_async_driver_callback(void) {
  usleep(300000);
  atomic_fetch_add(&tail_done, 1);
}

uint32_t gene_async_tail_done(void) { return atomic_load(&tail_done); }

/* Job memory owned independently of the Task: the Gene side and the job
 * each hold a reference; the last one frees. */
typedef struct JobBuffer { atomic_uint references; uint8_t bytes[4096]; } JobBuffer;
static JobBuffer *job_buffer;
static atomic_uint buffers_freed;

static void release_buffer(JobBuffer *buffer) {
  if (atomic_fetch_sub(&buffer->references, 1) == 1) {
    free(buffer);
    atomic_fetch_add(&buffers_freed, 1);
  }
}

static void *buffer_job(void *raw) {
  uint32_t index = (uint32_t)(uintptr_t)raw;
  JobBuffer *buffer = job_buffer;
  for (int round = 0; round < 50; ++round) {
    memset(buffer->bytes, round, sizeof(buffer->bytes));
    usleep(1000);
  }
  GeneOutBytes diagnostic = no_diagnostic();
  GeneCopiedResult value = {.kind = GENE_COPY_I64, .scalar = buffer->bytes[0]};
  api->task_submit_copy(api->runtime_context, producers[index], &value,
                        &diagnostic);
  producers[index] = 0;
  release_buffer(buffer);
  return NULL;
}

uint32_t gene_async_buffer_job(uint32_t index) {
  job_buffer = calloc(1, sizeof(*job_buffer));
  if (!job_buffer) return GENE_API_ERROR;
  atomic_store(&job_buffer->references, 2);
  uint32_t slot = atomic_fetch_add(&worker_count, 1);
  return pthread_create(&workers[slot], NULL, buffer_job,
                        (void *)(uintptr_t)index) == 0
             ? GENE_API_OK : GENE_API_ERROR;
}

void gene_async_drop_buffer(void) { release_buffer(job_buffer); }
uint32_t gene_async_buffers_freed(void) { return atomic_load(&buffers_freed); }

/* ---- module ------------------------------------------------------------- */

void gene_async_set_options(uint32_t value) { options = value; }
uint32_t gene_async_context_retires(void) {
  return atomic_load(&context_retires);
}

uint32_t gene_module_init(const GeneApi *table, GeneHandle env,
                          GeneOutBytes *diagnostic) {
  if (!table || table->version != GENE_API_VERSION ||
      table->struct_size < sizeof(GeneApi) || !env) return GENE_API_ERROR;
  const uint64_t required = GENE_API_CALLBACK_FEATURE |
      GENE_API_TASK_PRODUCER_FEATURE | GENE_API_TASK_COPY_FEATURE |
      GENE_API_TASK_FAIL_COPY_FEATURE | GENE_API_UNATTACHED_SUBMIT_FEATURE |
      GENE_API_TASK_CANCEL_FLAG_FEATURE |
      GENE_API_TASK_CANCEL_CALLBACK_FEATURE | GENE_API_TWO_PHASE_CLOSE_FEATURE;
  if ((table->feature_bits & required) != required) return GENE_API_ERROR;
  api = table;
  if (options & OPT_PIN) {
    if (!(table->feature_bits & GENE_API_PIN_IMAGE_FEATURE)) return GENE_API_ERROR;
    uint32_t status = table->pin_module_image(table->runtime_context,
                                              (const void *)&gene_module_init,
                                              diagnostic);
    if (status != GENE_API_OK) return status; /* a failed pin fails init */
  }
  if (options & OPT_TWO_PHASE) {
    uint32_t status = table->enable_two_phase_close(table->runtime_context,
                                                    diagnostic);
    if (status != GENE_API_OK) return status;
  }
  static const char *names[3] = {"start", "settle", "register_factory"};
  GeneNativeCallback callbacks[3] = {start_task, settle_task, register_factory};
  for (int i = 0; i < 3; ++i) {
    Registration *context = calloc(1, sizeof(*context));
    if (!context) return GENE_API_ERROR;
    uint32_t status = table->register_callback(
        table->runtime_context, env, (const uint8_t *)names[i],
        strlen(names[i]), callbacks[i], context, retire_registration,
        &callables[i], &registrations[i], diagnostic);
    if (status != GENE_API_OK) {
      free(context);
      return status;
    }
  }
  return table->retain(table->runtime_context, env, &environment, diagnostic);
}

void gene_async_release_saved(void) {
  GeneOutBytes diagnostic = no_diagnostic();
  if (factory) api->release(api->runtime_context, factory, &diagnostic);
  factory = 0;
  for (int i = 0; i < 3; ++i) {
    if (callables[i]) api->release(api->runtime_context, callables[i],
                                   &diagnostic);
    callables[i] = 0;
  }
  if (environment) api->release(api->runtime_context, environment,
                                &diagnostic);
  environment = 0;
}

uint32_t gene_async_close_registrations(void) {
  GeneOutBytes diagnostic = no_diagnostic();
  uint32_t result = GENE_API_OK;
  for (int i = 0; i < 3; ++i) {
    GeneHandle task = 0;
    if (api->request_close(api->runtime_context, registrations[i],
                           &diagnostic) > GENE_API_PENDING ||
        api->wait_closed(api->runtime_context, registrations[i], &task,
                         &diagnostic) != GENE_API_OK)
      result = GENE_API_ERROR;
    if (task) api->release(api->runtime_context, task, &diagnostic);
  }
  return result;
}

/* Synchronous completion on the root lane, reporting user acceptance. */
uint32_t gene_async_complete_accepted(uint32_t index, uint8_t *accepted) {
  GeneOutBytes diagnostic = no_diagnostic();
  uint32_t status = api->task_complete(api->runtime_context, producers[index],
                                       0, accepted, &diagnostic);
  if (status == GENE_API_OK) producers[index] = 0;
  return status;
}

/* ORC has no attachment: a held worker that never attached finishes its
 * producer through the queued entries after module close begins. */
static void *held_unattached(void *raw) {
  uint32_t index = (uint32_t)(uintptr_t)raw;
  while (!atomic_load(&held_go)) usleep(100);
  GeneOutBytes diagnostic = no_diagnostic();
  GeneCopiedResult value = {.kind = GENE_COPY_NIL};
  held_status = index % 2
      ? api->task_retire_queued(api->runtime_context, producers[index],
                                &diagnostic)
      : api->task_submit_copy(api->runtime_context, producers[index], &value,
                              &diagnostic);
  if (held_status == GENE_API_OK) producers[index] = 0;
  return NULL;
}

uint32_t gene_async_hold_unattached(uint32_t index) {
  atomic_store(&held_go, 0);
  held_status = GENE_API_ERROR;
  return pthread_create(&held_thread, NULL, held_unattached,
                        (void *)(uintptr_t)index) == 0
             ? GENE_API_OK : GENE_API_ERROR;
}
