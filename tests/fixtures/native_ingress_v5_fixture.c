#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include "native_api_v5.h"

static GeneApiV5 api;

int gene_test_v5_register(const GeneApiV5 *incoming, void *context,
                          uint64_t generation, void **native_context) {
  if (!incoming || incoming->version != GENE_API_V5_VERSION ||
      incoming->struct_size != sizeof(GeneApiV5) || !context ||
      !native_context) return 7;
  *native_context = context;
  if (!incoming->ingress_begin(context, generation)) return 8;
  int accepted = incoming->ingress_enqueue(context, "registered", 10);
  incoming->ingress_end(context);
  return accepted;
}

int gene_test_v5_register_fail(const GeneApiV5 *incoming, void *context,
                               uint64_t generation, void **native_context) {
  (void)incoming;
  (void)generation;
  if (!context || !native_context) return 7;
  *native_context = context; /* unregister still owns the failed attempt */
  return 17;
}

int gene_test_v5_register_no_context(const GeneApiV5 *incoming,
                                     void *context, uint64_t generation,
                                     void **native_context) {
  (void)incoming;
  (void)context;
  (void)generation;
  (void)native_context;
  return 0;
}

int gene_module_init_v5(const GeneApiV5 *incoming, void *module) {
  if (!incoming || !module || incoming->version != 5 ||
      incoming->struct_size != sizeof(GeneApiV5) ||
      !(incoming->feature_bits & 1) || !incoming->ingress_begin ||
      !incoming->ingress_enqueue || !incoming->ingress_end) {
    return 7;
  }
  api = *incoming;
  return 0;
}

typedef struct ForeignEmit {
  void *context;
  uint64_t generation;
  const void *data;
  size_t length;
  int began;
  int enqueued;
} ForeignEmit;

static void *emit_foreign(void *raw) {
  ForeignEmit *emit = raw;
  emit->began = api.ingress_begin(emit->context, emit->generation);
  emit->enqueued = emit->began
      ? api.ingress_enqueue(emit->context, emit->data, emit->length) : -4;
  if (emit->began) api.ingress_end(emit->context);
  return NULL;
}

int gene_test_v5_emit_foreign(void *context, uint64_t generation,
                              const void *data, size_t length,
                              int *began, int *enqueued) {
  ForeignEmit emit = {context, generation, data, length, 0, -4};
  pthread_t thread;
  if (pthread_create(&thread, NULL, emit_foreign, &emit)) return -10;
  if (pthread_join(thread, NULL)) return -11;
  *began = emit.began;
  *enqueued = emit.enqueued;
  return 0;
}

typedef struct HeldEmit {
  void *context;
  uint64_t generation;
  atomic_int started;
  atomic_int release;
  int began;
  int enqueued;
  pthread_t thread;
} HeldEmit;

static HeldEmit held;

static void *emit_held(void *raw) {
  HeldEmit *entry = raw;
  entry->began = api.ingress_begin(entry->context, entry->generation);
  atomic_store(&entry->started, 1);
  while (!atomic_load(&entry->release)) { /* short test-only wait */ }
  entry->enqueued = entry->began
      ? api.ingress_enqueue(entry->context, "late", 4) : -4;
  if (entry->began) api.ingress_end(entry->context);
  return NULL;
}

int gene_test_v5_hold_start(void *context, uint64_t generation) {
  held.context = context;
  held.generation = generation;
  held.began = 0;
  held.enqueued = -4;
  atomic_store(&held.started, 0);
  atomic_store(&held.release, 0);
  if (pthread_create(&held.thread, NULL, emit_held, &held)) return -10;
  while (!atomic_load(&held.started)) { /* entry has begun before return */ }
  return held.began;
}

int gene_test_v5_hold_finish(void) {
  atomic_store(&held.release, 1);
  if (pthread_join(held.thread, NULL)) return -11;
  return held.enqueued;
}

int gene_test_v5_unregister_slow(void *context) {
  (void)context;
  struct timespec delay = {0, 150000000};
  nanosleep(&delay, NULL);
  return 0;
}

int gene_test_v5_unregister_fail(void *context) {
  (void)context;
  return 17;
}
