#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "native_api.h"

/* The "What works today" completion pattern from tmp/async-improvements.md:
 * driver threads report through byte ingress, a Gene handler builds typed
 * errors and settles on the root lane, records stay stored until settled,
 * and an independent retry timer re-enqueues undelivered records. */

#define MAX_JOBS 64u
enum { EMPTY, UNDELIVERED, DELIVERED };
enum { KIND_OK, KIND_ERROR, KIND_MALFORMED, KIND_PANIC, KIND_CANCEL };

typedef struct Record {
  uint32_t state, kind, deliveries, rejections, retry_delivered;
  int64_t value;
} Record;

typedef struct Binding { void *context; } Binding;

static const GeneApi *api;
static GeneHandle environment;
static GeneHandle callables[8];
static GeneRegistration registrations[8];
static GeneProducer producers[MAX_JOBS];
static Record records[MAX_JOBS];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static GeneApi ingress_table;
static void *ingress_context;
static uint64_t ingress_generation;
static atomic_uint rejected, retry_stop, drivers_active, driver_completions;
static pthread_t retry_thread;
static int retry_started;
static pthread_t drivers[MAX_JOBS];
static atomic_uint driver_count;

/* Caller holds `lock`. */
static void deliver_locked(uint32_t index, int from_retry) {
  Record *record = &records[index];
  if (record->state != UNDELIVERED || !ingress_context) return;
  /* ingress_begin returns 1 when it admits this entry and 0 when the
   * subscription is closed; every admitted entry ends with ingress_end. */
  if (!ingress_table.ingress_begin(ingress_context, ingress_generation))
    return;
  uint8_t bytes[12];
  memcpy(bytes, &index, 4);
  memcpy(bytes + 4, &record->value, 8);
  if (ingress_table.ingress_enqueue(ingress_context, bytes, sizeof(bytes)) ==
      GENE_INGRESS_ACCEPTED) {
    record->state = DELIVERED;
    ++record->deliveries;
    if (from_retry) record->retry_delivered = 1;
  } else {
    ++record->rejections;
    atomic_fetch_add(&rejected, 1); /* stays stored for the retry timer */
  }
  ingress_table.ingress_end(ingress_context);
}

static void *retry_loop(void *unused) {
  (void)unused;
  while (!atomic_load(&retry_stop)) {
    /* One record per tick: retrying a whole backlog at once would overflow a
     * small queue again and fail the subscription it just reopened. */
    pthread_mutex_lock(&lock);
    for (uint32_t i = 0; i < MAX_JOBS; ++i) {
      if (records[i].state != UNDELIVERED) continue;
      deliver_locked(i, 1);
      break;
    }
    pthread_mutex_unlock(&lock);
    usleep(2000);
  }
  return NULL;
}

int32_t gene_pattern_register(const GeneApi *table, void *context,
                              uint64_t generation, void **native_context) {
  Binding *binding = calloc(1, sizeof(*binding));
  if (!binding) return -1;
  binding->context = context;
  pthread_mutex_lock(&lock);
  ingress_table = *table; /* the ingress view is valid only during this call */
  ingress_context = context;
  ingress_generation = generation;
  pthread_mutex_unlock(&lock);
  *native_context = binding;
  return 0;
}

int32_t gene_pattern_unregister(void *raw) {
  Binding *binding = raw;
  pthread_mutex_lock(&lock);
  if (binding && ingress_context == binding->context) ingress_context = NULL;
  pthread_mutex_unlock(&lock);
  free(binding); /* no future enqueue can reach this context */
  return 0;
}

void gene_pattern_complete(uint32_t index, uint32_t kind, int64_t value) {
  pthread_mutex_lock(&lock);
  records[index] = (Record){.state = UNDELIVERED, .kind = kind,
                            .value = value};
  deliver_locked(index, 0);
  pthread_mutex_unlock(&lock);
}

typedef struct Later { uint32_t index, delay_ms; } Later;

static void *complete_later(void *raw) {
  Later later = *(Later *)raw;
  free(raw);
  usleep(later.delay_ms * 1000);
  gene_pattern_complete(later.index, KIND_OK, later.index);
  atomic_fetch_add(&driver_completions, 1);
  atomic_fetch_sub(&drivers_active, 1); /* the driver's last library code */
  return NULL;
}

uint32_t gene_pattern_complete_later(uint32_t index, uint32_t delay_ms) {
  Later *later = malloc(sizeof(*later));
  if (!later) return GENE_API_ERROR;
  *later = (Later){index, delay_ms};
  atomic_fetch_add(&drivers_active, 1);
  uint32_t slot = atomic_fetch_add(&driver_count, 1);
  return pthread_create(&drivers[slot], NULL, complete_later, later) == 0
             ? GENE_API_OK : GENE_API_ERROR;
}

void gene_pattern_join_drivers(void) {
  uint32_t count = atomic_exchange(&driver_count, 0);
  for (uint32_t i = 0; i < count; ++i) pthread_join(drivers[i], NULL);
}

uint32_t gene_pattern_drivers_active(void) {
  return atomic_load(&drivers_active);
}
uint32_t gene_pattern_rejected(void) { return atomic_load(&rejected); }
uint32_t gene_pattern_driver_completions(void) {
  return atomic_load(&driver_completions);
}
uint32_t gene_pattern_rejections(uint32_t index) {
  pthread_mutex_lock(&lock);
  uint32_t count = records[index].rejections;
  pthread_mutex_unlock(&lock);
  return count;
}
uint32_t gene_pattern_retry_delivered(uint32_t index) {
  pthread_mutex_lock(&lock);
  uint32_t delivered = records[index].retry_delivered;
  pthread_mutex_unlock(&lock);
  return delivered;
}

void gene_pattern_start_retry(void) {
  atomic_store(&retry_stop, 0);
  retry_started = pthread_create(&retry_thread, NULL, retry_loop, NULL) == 0;
}

void gene_pattern_stop_retry(void) {
  atomic_store(&retry_stop, 1);
  if (retry_started) pthread_join(retry_thread, NULL);
  retry_started = 0;
}

/* ---- callbacks ---------------------------------------------------------- */

static uint32_t read_record(const GeneApi *table, GeneHandle bytes,
                            uint32_t *index, int64_t *value,
                            GeneOutBytes *diagnostic) {
  uint8_t buffer[12];
  GeneOutBytes output = {buffer, sizeof(buffer), 0};
  if (table->copy_bytes(table->runtime_context, bytes, &output,
                        diagnostic) != GENE_API_OK ||
      output.required != sizeof(buffer)) return GENE_API_ERROR;
  memcpy(index, buffer, 4);
  memcpy(value, buffer + 4, 8);
  return *index < MAX_JOBS ? GENE_API_OK : GENE_API_ERROR;
}

static uint32_t fail_with(GeneOutBytes *diagnostic, const char *message) {
  size_t length = strlen(message);
  diagnostic->required = length;
  if (diagnostic->data && diagnostic->capacity >= length)
    memcpy(diagnostic->data, message, length);
  return GENE_API_ERROR;
}

#define CALLBACK(name) \
  static uint32_t name(const GeneApi *table, void *raw, \
                       const GeneHandle *args, size_t count, \
                       const GeneNamedArg *named, size_t named_count, \
                       GeneHandle env, GeneHandle *out, GeneHandle *error, \
                       GeneOutBytes *diagnostic)
#define UNUSED (void)raw; (void)named; (void)named_count; (void)error

CALLBACK(start_task) {
  UNUSED;
  int64_t index = -1;
  if (count != 1 || table->copy_i64(table->runtime_context, args[0], &index,
                                    diagnostic) != GENE_API_OK ||
      index < 0 || (uint64_t)index >= MAX_JOBS) return GENE_API_ERROR;
  return table->new_task(table->runtime_context, env, out, &producers[index],
                         diagnostic);
}

static void forget(uint32_t index) {
  pthread_mutex_lock(&lock);
  records[index].state = EMPTY; /* only settlement deletes a record */
  pthread_mutex_unlock(&lock);
  producers[index] = 0;
}

CALLBACK(settle_ok) {
  UNUSED; (void)env;
  int64_t index = -1;
  uint8_t accepted = 0;
  if (count != 2 || table->copy_i64(table->runtime_context, args[0], &index,
                                    diagnostic) != GENE_API_OK) return 1;
  uint32_t status = table->task_complete(table->runtime_context,
                                         producers[index], args[1],
                                         &accepted, diagnostic);
  if (status == GENE_API_OK) forget((uint32_t)index);
  *out = 0;
  return status;
}

CALLBACK(settle_err) {
  UNUSED; (void)env;
  int64_t index = -1;
  uint8_t accepted = 0;
  const uint8_t message[] = "native job failed";
  if (count != 2 || table->copy_i64(table->runtime_context, args[0], &index,
                                    diagnostic) != GENE_API_OK) return 1;
  /* A typed error ID is accepted here because this runs on the root lane. */
  uint32_t status = table->task_fail(table->runtime_context, producers[index],
                                     message, sizeof(message) - 1, args[1],
                                     &accepted, diagnostic);
  if (status == GENE_API_OK) forget((uint32_t)index);
  *out = 0;
  return status;
}

CALLBACK(reenqueue) {
  UNUSED; (void)env; (void)args; (void)count; (void)diagnostic;
  /* A closed subscription discarded its queue: resend what never settled. */
  pthread_mutex_lock(&lock);
  for (uint32_t i = 0; i < MAX_JOBS; ++i)
    if (records[i].state == DELIVERED) records[i].state = UNDELIVERED;
  pthread_mutex_unlock(&lock);
  *out = 0;
  return GENE_API_OK;
}

CALLBACK(retire_all) {
  UNUSED; (void)env; (void)args; (void)count;
  /* Called only after every job has physically ended. */
  for (uint32_t i = 0; i < MAX_JOBS; ++i) {
    if (!producers[i]) continue;
    uint8_t accepted = 0;
    if (table->task_retire(table->runtime_context, producers[i], &accepted,
                           diagnostic) == GENE_API_OK) forget(i);
  }
  *out = 0;
  return GENE_API_OK;
}

CALLBACK(record_index) {
  UNUSED; (void)env;
  uint32_t index = 0;
  int64_t value = 0;
  if (count != 1 || read_record(table, args[0], &index, &value, diagnostic))
    return fail_with(diagnostic, "unreadable record");
  return table->new_i64(table->runtime_context, index, out, diagnostic);
}

CALLBACK(record_kind) {
  UNUSED; (void)env;
  uint32_t index = 0;
  int64_t value = 0;
  if (count != 1 || read_record(table, args[0], &index, &value, diagnostic))
    return fail_with(diagnostic, "unreadable record");
  pthread_mutex_lock(&lock);
  uint32_t kind = records[index].kind;
  /* A panicking or cancelled handler is a first-delivery fault only, so the
   * redelivered record settles normally. */
  if ((kind == KIND_PANIC || kind == KIND_CANCEL) &&
      records[index].deliveries > 1) kind = KIND_OK;
  pthread_mutex_unlock(&lock);
  return table->new_i64(table->runtime_context, kind, out, diagnostic);
}

CALLBACK(record_value) {
  UNUSED; (void)env;
  uint32_t index = 0;
  int64_t value = 0;
  if (count != 1 || read_record(table, args[0], &index, &value, diagnostic))
    return fail_with(diagnostic, "unreadable record");
  pthread_mutex_lock(&lock);
  uint32_t kind = records[index].kind;
  pthread_mutex_unlock(&lock);
  if (kind == KIND_MALFORMED) return fail_with(diagnostic, "malformed value");
  return table->new_i64(table->runtime_context, value, out, diagnostic);
}

static void retire_registration(void *raw) { free(raw); }

static uint32_t two_phase;
void gene_pattern_set_two_phase(uint32_t value) { two_phase = value; }

uint32_t gene_module_init(const GeneApi *table, GeneHandle env,
                          GeneOutBytes *diagnostic) {
  if (!table || table->version != GENE_API_VERSION ||
      table->struct_size < sizeof(GeneApi) || !env ||
      !(table->feature_bits & GENE_API_TASK_PRODUCER_FEATURE))
    return GENE_API_ERROR;
  api = table;
  if (two_phase) {
    uint32_t status = table->enable_two_phase_close(table->runtime_context,
                                                    diagnostic);
    if (status != GENE_API_OK) return status;
  }
  static const char *names[8] = {"start", "settle_ok", "settle_err",
                                 "reenqueue", "retire_all", "record_index",
                                 "record_kind", "record_value"};
  GeneNativeCallback callbacks[8] = {start_task, settle_ok, settle_err,
                                     reenqueue, retire_all, record_index,
                                     record_kind, record_value};
  for (int i = 0; i < 8; ++i) {
    void *context = calloc(1, 1);
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

uint32_t gene_pattern_teardown(void) {
  GeneOutBytes diagnostic = {0};
  uint32_t result = GENE_API_OK;
  for (int i = 0; i < 8; ++i) {
    GeneHandle task = 0;
    api->release(api->runtime_context, callables[i], &diagnostic);
    if (api->request_close(api->runtime_context, registrations[i],
                           &diagnostic) > GENE_API_PENDING ||
        api->wait_closed(api->runtime_context, registrations[i], &task,
                         &diagnostic) != GENE_API_OK)
      result = GENE_API_ERROR;
    if (task) api->release(api->runtime_context, task, &diagnostic);
  }
  api->release(api->runtime_context, environment, &diagnostic);
  return result;
}
