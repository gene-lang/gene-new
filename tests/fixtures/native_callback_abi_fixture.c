#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include "native_api.h"

typedef struct CallbackState { int marker; } CallbackState;

static const GeneApi *api;
static GeneHandle environment;
static GeneHandle callable;
static GeneHandle retained_argument;
static GeneHandle last_temporary_argument;
static GeneHandle last_temporary_environment;
static GeneRegistration registration;
static GeneHandle waiter_task;
static GeneProducer task_producer;
static GeneProducer *stress_producers;
static pthread_t *stress_threads;
static uint32_t stress_count;
static uint32_t stress_workers;
static atomic_uint stress_next;
static atomic_uint stress_attached;
static atomic_uint stress_go;
static atomic_uint stress_failures;
static atomic_uint stress_completed;
static atomic_uint stress_retired;
static atomic_uint stress_accepted;
static atomic_uint stress_late;
static uint32_t callback_mode;
static uint32_t fail_initializer;
static uint32_t duplicate_registration;
static uint32_t duplicate_status;
static uint32_t caller_freed_contexts;
static uint32_t calls;
static uint32_t retires;
static uint32_t close_inside_status;
static uint32_t retire_reentry_status;
static uint32_t pending_wait_status;

static void retire_context(void *raw) {
  CallbackState *state = raw;
  GeneOutBytes diagnostic = {0};
  retire_reentry_status = api->request_close(api->runtime_context,
                                               registration, &diagnostic);
  if (state && state->marker == 0x71) ++retires;
  free(state);
}

static uint32_t callback(const GeneApi *table, void *raw,
                         const GeneHandle *args, size_t arg_count,
                         const GeneNamedArg *named, size_t named_count,
                         GeneHandle invocation_environment,
                         GeneHandle *out_value, GeneHandle *out_error,
                         GeneOutBytes *diagnostic) {
  CallbackState *state = raw;
  if (!state || state->marker != 0x71 || !table ||
      !invocation_environment || arg_count != 1 || !args ||
      !out_value || !out_error) return 1;
  if (callback_mode == 6) {
    if (named_count != 1 || !named || named[0].name_len != 4 ||
        memcmp(named[0].name, "step", 4) != 0) return 1;
  } else if (named_count != 0 || named) return 1;
  ++calls;
  last_temporary_argument = args[0];
  last_temporary_environment = invocation_environment;
  if (retained_argument == 0 &&
      table->retain(table->runtime_context, args[0], &retained_argument,
                    diagnostic) != GENE_API_OK) return 1;
  int64_t input = 0;
  if (table->copy_i64(table->runtime_context, args[0], &input,
                      diagnostic) != GENE_API_OK) return 1;
  if (callback_mode == 6) {
    int64_t step = 0;
    if (table->copy_i64(table->runtime_context, named[0].value,
                        &step, diagnostic) != GENE_API_OK) return 1;
    return table->new_i64(table->runtime_context, input + step,
                          out_value, diagnostic);
  }
  if (callback_mode == 1 || callback_mode == 2) {
    const uint8_t typed[] = "typed error";
    if (table->new_text(table->runtime_context, typed, sizeof(typed) - 1,
                        out_error, diagnostic) != GENE_API_OK) return 1;
    const char *message = callback_mode == 1 ? "ordinary failure" : "panic failure";
    size_t length = strlen(message);
    diagnostic->required = length;
    if (diagnostic->data && diagnostic->capacity >= length)
      memcpy(diagnostic->data, message, length);
    return callback_mode == 1 ? GENE_API_ERROR : GENE_API_PANIC;
  }
  if (callback_mode == 3) return GENE_API_CANCELLED;
  if (callback_mode == 4 || callback_mode == 7 || callback_mode == 8) {
    close_inside_status = table->request_close(table->runtime_context,
                                                registration, diagnostic);
    if (callback_mode == 7 || callback_mode == 8)
      pending_wait_status = table->wait_closed(table->runtime_context,
                                               registration, &waiter_task,
                                               diagnostic);
    if (callback_mode == 8 && pending_wait_status == GENE_API_OK) {
      const uint8_t name[] = "cancel_waiter";
      GeneHandle function = 0, output = 0, error = 0;
      if (table->lookup(table->runtime_context, invocation_environment,
                        name, sizeof(name) - 1, &function,
                        diagnostic) == GENE_API_OK) {
        table->call(table->runtime_context, function, &waiter_task, 1,
                    invocation_environment, &output, &error, diagnostic);
      }
      if (function) table->release(table->runtime_context, function, diagnostic);
      if (output) table->release(table->runtime_context, output, diagnostic);
      if (error) table->release(table->runtime_context, error, diagnostic);
    }
  }
  if (callback_mode == 5) {
    *out_value = args[0]; /* illegal borrowed return, checked by host */
    return GENE_API_OK;
  }
  if (callback_mode == 9 || callback_mode == 11) {
    if (!(table->feature_bits & GENE_API_TASK_PRODUCER_FEATURE) ||
        !table->new_task || !table->task_complete || !table->task_fail ||
        !table->task_cancel || !table->task_retire) return GENE_API_ERROR;
    return table->new_task(table->runtime_context, invocation_environment,
                           out_value, &task_producer, diagnostic);
  }
  if (callback_mode == 10) {
    if (!stress_producers || input < 0 ||
        (uint64_t)input >= stress_count || stress_producers[input])
      return GENE_API_ERROR;
    return table->new_task(table->runtime_context, invocation_environment,
                           out_value, &stress_producers[input], diagnostic);
  }
  return table->new_i64(table->runtime_context, input + 1,
                        out_value, diagnostic);
}

void gene_test_api_set_callback_mode(uint32_t value) { callback_mode = value; }
void gene_test_api_fail_initializer(uint32_t value) { fail_initializer = value; }
void gene_test_api_duplicate_registration(uint32_t value) {
  duplicate_registration = value;
}
uint32_t gene_test_api_duplicate_status(void) { return duplicate_status; }
uint32_t gene_test_api_caller_freed_contexts(void) {
  return caller_freed_contexts;
}
uint32_t gene_test_api_calls(void) { return calls; }
uint32_t gene_test_api_retires(void) { return retires; }
uint32_t gene_test_api_close_inside_status(void) { return close_inside_status; }
uint32_t gene_test_api_retire_reentry_status(void) { return retire_reentry_status; }
uint32_t gene_test_api_pending_wait_status(void) { return pending_wait_status; }
uint64_t gene_test_api_registration_id(void) { return registration; }

uint32_t gene_test_api_stress_prepare(uint32_t count) {
  if (count == 0 || count > 200000 || stress_producers ||
      !api->attach_thread || !api->detach_thread) return GENE_API_ERROR;
  stress_producers = calloc(count, sizeof(*stress_producers));
  if (!stress_producers) return GENE_API_ERROR;
  stress_count = count;
  atomic_store(&stress_next, 0);
  atomic_store(&stress_attached, 0);
  atomic_store(&stress_go, 0);
  atomic_store(&stress_failures, 0);
  atomic_store(&stress_completed, 0);
  atomic_store(&stress_retired, 0);
  atomic_store(&stress_accepted, 0);
  atomic_store(&stress_late, 0);
  return GENE_API_OK;
}

static void *stress_worker(void *unused) {
  (void)unused;
  GeneOutBytes diagnostic = {0};
  uint64_t attachment = 0;
  uint32_t status = api->attach_thread(api->runtime_context, &attachment,
                                        &diagnostic);
  if (status != GENE_API_OK) atomic_fetch_add(&stress_failures, 1);
  atomic_fetch_add(&stress_attached, 1);
  while (!atomic_load(&stress_go)) sched_yield();
  if (status != GENE_API_OK) return NULL;
  for (;;) {
    uint32_t index = atomic_fetch_add(&stress_next, 1);
    if (index >= stress_count) break;
    uint8_t accepted = 0;
    if (index % 11 == 0) {
      status = api->task_retire(api->runtime_context,
                                stress_producers[index], &accepted,
                                &diagnostic);
      if (status == GENE_API_OK) atomic_fetch_add(&stress_retired, 1);
    } else {
      status = api->task_complete(api->runtime_context,
                                  stress_producers[index], 0, &accepted,
                                  &diagnostic);
      if (status == GENE_API_OK) atomic_fetch_add(&stress_completed, 1);
    }
    if (status != GENE_API_OK) atomic_fetch_add(&stress_failures, 1);
    else {
      stress_producers[index] = 0;
      if (accepted) atomic_fetch_add(&stress_accepted, 1);
      else atomic_fetch_add(&stress_late, 1);
    }
    if ((index & 7u) == 0) sched_yield();
  }
  if (api->detach_thread(api->runtime_context, attachment,
                          &diagnostic) != GENE_API_OK)
    atomic_fetch_add(&stress_failures, 1);
  return NULL;
}

uint32_t gene_test_api_stress_start(uint32_t workers) {
  if (!stress_producers || stress_threads || workers == 0 || workers > 32)
    return GENE_API_ERROR;
  for (uint32_t i = 0; i < stress_count; ++i)
    if (!stress_producers[i]) return GENE_API_ERROR;
  stress_threads = calloc(workers, sizeof(*stress_threads));
  if (!stress_threads) return GENE_API_ERROR;
  for (uint32_t i = 0; i < workers; ++i) {
    if (pthread_create(&stress_threads[i], NULL, stress_worker, NULL) != 0) {
      stress_workers = i;
      atomic_store(&stress_go, 1);
      for (uint32_t j = 0; j < i; ++j) pthread_join(stress_threads[j], NULL);
      free(stress_threads);
      stress_threads = NULL;
      return GENE_API_ERROR;
    }
  }
  stress_workers = workers;
  while (atomic_load(&stress_attached) != workers) sched_yield();
  return atomic_load(&stress_failures) == 0 ? GENE_API_OK : GENE_API_ERROR;
}

void gene_test_api_stress_release(void) {
  atomic_store(&stress_go, 1);
}

uint32_t gene_test_api_stress_join(uint32_t *completed, uint32_t *retired,
                                  uint32_t *accepted, uint32_t *late) {
  if (!stress_threads || !completed || !retired || !accepted || !late)
    return GENE_API_ERROR;
  atomic_store(&stress_go, 1);
  for (uint32_t i = 0; i < stress_workers; ++i)
    pthread_join(stress_threads[i], NULL);
  free(stress_threads);
  stress_threads = NULL;
  *completed = atomic_load(&stress_completed);
  *retired = atomic_load(&stress_retired);
  *accepted = atomic_load(&stress_accepted);
  *late = atomic_load(&stress_late);
  GeneOutBytes diagnostic = {0};
  for (uint32_t i = 0; i < stress_count; ++i) {
    if (!stress_producers[i]) continue;
    uint8_t ignored = 0;
    api->task_retire(api->runtime_context, stress_producers[i],
                     &ignored, &diagnostic);
  }
  free(stress_producers);
  stress_producers = NULL;
  stress_count = 0;
  return atomic_load(&stress_failures) == 0 ? GENE_API_OK : GENE_API_ERROR;
}

uint32_t gene_test_api_new_task_outside_callback(void) {
  GeneOutBytes diagnostic = {0};
  GeneHandle task = 0;
  GeneProducer producer = 0;
  return api->new_task(api->runtime_context, environment, &task,
                       &producer, &diagnostic);
}

uint32_t gene_test_api_task_complete(int64_t value, uint8_t *accepted) {
  GeneOutBytes diagnostic = {0};
  GeneHandle payload = 0;
  uint32_t status = api->new_i64(api->runtime_context, value, &payload,
                                  &diagnostic);
  if (status != GENE_API_OK) return status;
  status = api->task_complete(api->runtime_context, task_producer, payload,
                              accepted, &diagnostic);
  api->release(api->runtime_context, payload, &diagnostic);
  return status;
}

typedef struct TaskThreadResult {
  GeneHandle payload;
  uint32_t status;
  uint8_t accepted;
} TaskThreadResult;

static void *complete_on_attached_thread(void *raw) {
  TaskThreadResult *result = raw;
  GeneOutBytes diagnostic = {0};
  uint64_t attachment = 0;
  result->status = api->attach_thread(api->runtime_context, &attachment,
                                       &diagnostic);
  if (result->status == GENE_API_OK) {
    result->status = api->task_complete(api->runtime_context, task_producer,
                                        result->payload, &result->accepted,
                                        &diagnostic);
    if (result->payload)
      api->release(api->runtime_context, result->payload, &diagnostic);
    if (api->detach_thread(api->runtime_context, attachment,
                           &diagnostic) != GENE_API_OK)
      result->status = GENE_API_ERROR;
  }
  return NULL;
}

uint32_t gene_test_api_task_complete_attached(int64_t value,
                                               uint8_t *accepted) {
  if (!api->attach_thread || !api->detach_thread) return GENE_API_ERROR;
  GeneOutBytes diagnostic = {0};
  TaskThreadResult result = {0};
  result.status = api->new_i64(api->runtime_context, value, &result.payload,
                                &diagnostic);
  if (result.status != GENE_API_OK) return result.status;
  pthread_t thread;
  if (pthread_create(&thread, NULL, complete_on_attached_thread,
                     &result) != 0) {
    api->release(api->runtime_context, result.payload, &diagnostic);
    return GENE_API_ERROR;
  }
  pthread_join(thread, NULL);
  *accepted = result.accepted;
  return result.status;
}

uint32_t gene_test_api_task_complete_nil(uint8_t *accepted) {
  GeneOutBytes diagnostic = {0};
  return api->task_complete(api->runtime_context, task_producer, 0,
                            accepted, &diagnostic);
}

uint32_t gene_test_api_task_complete_nil_attached(uint8_t *accepted) {
  if (!api->attach_thread || !api->detach_thread) return GENE_API_ERROR;
  TaskThreadResult result = {0};
  pthread_t thread;
  if (pthread_create(&thread, NULL, complete_on_attached_thread,
                     &result) != 0) return GENE_API_ERROR;
  pthread_join(thread, NULL);
  *accepted = result.accepted;
  return result.status;
}

typedef struct CopyThreadResult {
  GeneCopiedResult value;
  uint32_t status;
} CopyThreadResult;

static void *submit_copy_on_attached_thread(void *raw) {
  CopyThreadResult *result = raw;
  GeneOutBytes diagnostic = {0};
  uint64_t attachment = 0;
  result->status = api->attach_thread(api->runtime_context, &attachment,
                                      &diagnostic);
  if (result->status == GENE_API_OK) {
    result->status = api->task_submit_copy(api->runtime_context,
                                           task_producer, &result->value,
                                           &diagnostic);
    if (api->detach_thread(api->runtime_context, attachment,
                           &diagnostic) != GENE_API_OK)
      result->status = GENE_API_ERROR;
  }
  return NULL;
}

uint32_t gene_test_api_task_submit_copy(uint32_t kind, int64_t scalar,
                                         const uint8_t *data, size_t length,
                                         uint8_t attached) {
  if (!api->task_submit_copy ||
      !(api->feature_bits & GENE_API_TASK_COPY_FEATURE)) return GENE_API_ERROR;
  CopyThreadResult result = {{kind, scalar, data, length}, GENE_API_ERROR};
  if (!attached) {
    GeneOutBytes diagnostic = {0};
    return api->task_submit_copy(api->runtime_context, task_producer,
                                  &result.value, &diagnostic);
  }
  pthread_t thread;
  if (pthread_create(&thread, NULL, submit_copy_on_attached_thread,
                     &result) != 0) return GENE_API_ERROR;
  pthread_join(thread, NULL);
  return result.status;
}

static pthread_t copy_async_thread;
static uint32_t copy_async_status;
static uint32_t copy_async_running;

static void *submit_async_copy(void *unused) {
  (void)unused;
  GeneOutBytes diagnostic = {0};
  uint64_t attachment = 0;
  copy_async_status = api->attach_thread(api->runtime_context, &attachment,
                                          &diagnostic);
  if (copy_async_status == GENE_API_OK) {
    const uint8_t text[] = "async-copy";
    GeneCopiedResult value = {GENE_COPY_TEXT, 0, text, sizeof(text) - 1};
    copy_async_status = api->task_submit_copy(api->runtime_context,
                                               task_producer, &value,
                                               &diagnostic);
    if (api->detach_thread(api->runtime_context, attachment,
                           &diagnostic) != GENE_API_OK)
      copy_async_status = GENE_API_ERROR;
  }
  return NULL;
}

uint32_t gene_test_api_start_async_copy(void) {
  if (copy_async_running) return GENE_API_ERROR;
  copy_async_running = 1;
  copy_async_status = GENE_API_ERROR;
  if (pthread_create(&copy_async_thread, NULL, submit_async_copy, NULL) != 0) {
    copy_async_running = 0;
    return GENE_API_ERROR;
  }
  return GENE_API_OK;
}

uint32_t gene_test_api_join_async_copy(void) {
  if (!copy_async_running) return GENE_API_ERROR;
  pthread_join(copy_async_thread, NULL);
  copy_async_running = 0;
  return copy_async_status;
}

uint32_t gene_test_api_task_fail(uint8_t *accepted) {
  const uint8_t message[] = "native producer failure";
  GeneOutBytes diagnostic = {0};
  return api->task_fail(api->runtime_context, task_producer, message,
                        sizeof(message) - 1, 0, accepted, &diagnostic);
}

uint32_t gene_test_api_task_cancel(uint8_t *accepted) {
  GeneOutBytes diagnostic = {0};
  return api->task_cancel(api->runtime_context, task_producer,
                          accepted, &diagnostic);
}

uint32_t gene_test_api_task_retire(uint8_t *accepted) {
  GeneOutBytes diagnostic = {0};
  return api->task_retire(api->runtime_context, task_producer,
                          accepted, &diagnostic);
}

uint32_t gene_module_init(const GeneApi *table, GeneHandle env,
                          GeneOutBytes *diagnostic) {
  if (!table || table->version != GENE_API_VERSION ||
      table->struct_size != sizeof(GeneApi) || !env ||
      !(table->feature_bits & GENE_API_CALLBACK_FEATURE) ||
      !table->register_callback || !table->request_close ||
      !table->wait_closed) return GENE_API_ERROR;
  api = table;
  CallbackState *state = calloc(1, sizeof(*state));
  if (!state) return GENE_API_ERROR;
  state->marker = 0x71;
  const uint8_t name[] = "native_plus_one";
  uint32_t status = table->register_callback(table->runtime_context, env,
      name, sizeof(name) - 1, callback, state, retire_context,
      &callable, &registration, diagnostic);
  if (status != GENE_API_OK) {
    free(state); /* registration failure leaves context with caller */
    return status;
  }
  status = table->retain(table->runtime_context, env, &environment, diagnostic);
  if (status != GENE_API_OK) return status;
  if (duplicate_registration) {
    CallbackState *second = calloc(1, sizeof(*second));
    if (!second) return GENE_API_ERROR;
    second->marker = 0x71;
    GeneHandle second_callable = 0;
    GeneRegistration second_registration = 0;
    duplicate_status = table->register_callback(table->runtime_context, env,
        name, sizeof(name) - 1, callback, second, retire_context,
        &second_callable, &second_registration, diagnostic);
    if (duplicate_status == GENE_API_OK)
      return GENE_API_ERROR; /* loader rolls back both registrations */
    free(second); /* failed registration keeps context with the caller */
    ++caller_freed_contexts;
  }
  if (fail_initializer) return GENE_API_ERROR;
  return GENE_API_OK;
}

uint32_t gene_test_api_invoke(int64_t input, int64_t *value,
                              uint32_t *call_status,
                              uint32_t *has_error) {
  if (!api || !value || !call_status || !has_error) return GENE_API_ERROR;
  GeneHandle argument = 0, output = 0, error = 0;
  GeneOutBytes diagnostic = {0};
  uint32_t status = api->new_i64(api->runtime_context, input, &argument,
                                  &diagnostic);
  if (status != GENE_API_OK) return status;
  *call_status = api->call(api->runtime_context, callable, &argument, 1,
                           environment, &output, &error, &diagnostic);
  *has_error = error != 0;
  if (*call_status == GENE_API_OK && output)
    status = api->copy_i64(api->runtime_context, output, value, &diagnostic);
  if (output) api->release(api->runtime_context, output, &diagnostic);
  if (error) api->release(api->runtime_context, error, &diagnostic);
  api->release(api->runtime_context, argument, &diagnostic);
  return status;
}

uint32_t gene_test_api_temporary_is_stale(void) {
  uint32_t kind = 0;
  GeneOutBytes diagnostic = {0};
  return api->kind(api->runtime_context, last_temporary_argument,
                   &kind, &diagnostic);
}

uint32_t gene_test_api_environment_is_stale(void) {
  uint32_t kind = 0;
  GeneOutBytes diagnostic = {0};
  return api->kind(api->runtime_context, last_temporary_environment,
                   &kind, &diagnostic);
}

uint32_t gene_test_api_retained_argument(int64_t *value) {
  GeneOutBytes diagnostic = {0};
  if (!retained_argument) return GENE_API_ERROR;
  return api->copy_i64(api->runtime_context, retained_argument,
                       value, &diagnostic);
}

uint32_t gene_test_api_close(void) {
  GeneOutBytes diagnostic = {0};
  return api->request_close(api->runtime_context, registration, &diagnostic);
}

uint32_t gene_test_api_wait(void) {
  GeneHandle task = 0;
  GeneOutBytes diagnostic = {0};
  uint32_t status = api->wait_closed(api->runtime_context, registration,
                                     &task, &diagnostic);
  if (status != GENE_API_OK) return status;
  uint32_t kind = 0;
  status = api->kind(api->runtime_context, task, &kind, &diagnostic);
  api->release(api->runtime_context, task, &diagnostic);
  return status == GENE_API_OK && kind == 9 ? GENE_API_OK : GENE_API_ERROR;
}

uint32_t gene_test_api_wait_without_kind(void) {
  GeneHandle task = 0;
  GeneOutBytes diagnostic = {0};
  uint32_t status = api->wait_closed(api->runtime_context, registration,
                                     &task, &diagnostic);
  if (task) api->release(api->runtime_context, task, &diagnostic);
  return status;
}

uint32_t gene_test_api_await_waiter(void) {
  if (!waiter_task) return GENE_API_ERROR;
  GeneOutBytes diagnostic = {0};
  uint32_t kind = 0;
  if (api->kind(api->runtime_context, waiter_task, &kind, &diagnostic) ||
      kind != 9) return GENE_API_ERROR;
  const uint8_t name[] = "await_close";
  GeneHandle function = 0, output = 0, error = 0;
  uint32_t status = api->lookup(api->runtime_context, environment,
                                name, sizeof(name) - 1, &function,
                                &diagnostic);
  if (status == GENE_API_OK)
    status = api->call(api->runtime_context, function, &waiter_task, 1,
                       environment, &output, &error, &diagnostic);
  if (function) api->release(api->runtime_context, function, &diagnostic);
  if (output) api->release(api->runtime_context, output, &diagnostic);
  if (error) api->release(api->runtime_context, error, &diagnostic);
  api->release(api->runtime_context, waiter_task, &diagnostic);
  waiter_task = 0;
  return status;
}

void gene_test_api_release_saved(void) {
  GeneOutBytes diagnostic = {0};
  if (waiter_task) {
    api->release(api->runtime_context, waiter_task, &diagnostic);
    waiter_task = 0;
  }
  if (retained_argument) {
    api->release(api->runtime_context, retained_argument, &diagnostic);
    retained_argument = 0;
  }
  if (callable) {
    api->release(api->runtime_context, callable, &diagnostic);
    callable = 0;
  }
  if (environment) {
    api->release(api->runtime_context, environment, &diagnostic);
    environment = 0;
  }
}
