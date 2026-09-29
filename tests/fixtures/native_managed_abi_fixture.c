#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sched.h>
#include "native_api.h"

static uint32_t mode;
static uint32_t calls;
static const GeneApi *saved_api;
static GeneHandle saved_map;

void gene_test_api_set_mode(uint32_t value) { mode = value; }
uint32_t gene_test_api_calls(void) { return calls; }

typedef struct ForeignRead {
  GeneHandle root;
  GeneHandle traversed;
  int ok;
} ForeignRead;

static void *read_on_foreign_lane(void *raw) {
  ForeignRead *read = raw;
  const GeneApi *api = saved_api;
  uint64_t token = 0;
  GeneHandle retained = 0;
  GeneHandle map_child = 0;
  uint32_t kind = 255;
  int64_t number = 0;
  uint8_t key_copy[16] = {0};
  GeneOutBytes key_out = {key_copy, sizeof(key_copy), 0};
  int before_rejected = api->kind(api->runtime_context, read->root,
                                   &kind, NULL) == GENE_API_ERROR;
  read->ok = before_rejected &&
      api->attach_thread(api->runtime_context, &token, NULL) == GENE_API_OK &&
      token != 0 &&
      api->kind(api->runtime_context, read->root, &kind, NULL) == GENE_API_OK &&
      kind == 2 &&
      api->copy_i64(api->runtime_context, read->root, &number, NULL) == GENE_API_OK &&
      number == 99 &&
      api->retain(api->runtime_context, read->root, &retained, NULL) == GENE_API_OK &&
      retained != 0 &&
      api->release(api->runtime_context, retained, NULL) == GENE_API_OK &&
      api->copy_key(api->runtime_context, saved_map, GENE_MAP_ENTRY, 0,
                    &key_out, NULL) == GENE_API_OK &&
      key_out.required == sizeof("map_key") - 1 &&
      memcmp(key_copy, "map_key", sizeof("map_key") - 1) == 0 &&
      api->traverse(api->runtime_context, saved_map, GENE_MAP_ENTRY, 0,
                    &map_child, NULL) == GENE_API_OK &&
      api->copy_i64(api->runtime_context, map_child, &number, NULL) == GENE_API_OK &&
      number == 4 &&
      api->release(api->runtime_context, map_child, NULL) == GENE_API_OK &&
      api->traverse(api->runtime_context, saved_map, GENE_MAP_ENTRY, 0,
                    &read->traversed, NULL) == GENE_API_OK &&
      api->detach_thread(api->runtime_context, token, NULL) == GENE_API_OK;
  if (read->ok)
    read->ok = api->kind(api->runtime_context, read->root,
                          &kind, NULL) == GENE_API_ERROR;
  if (!read->ok && token) api->detach_thread(api->runtime_context, token, NULL);
  return NULL;
}

int gene_test_api_try_foreign(void) {
  const GeneApi *api = saved_api;
  if (!api || !(api->feature_bits & GENE_API_ATTACHED_FEATURE) ||
      !(api->feature_bits & GENE_API_FOREIGN_ROOTS_FEATURE) ||
      !api->attach_thread || !api->detach_thread ||
      !api->reserve_foreign_roots) return -1;
  if (api->reserve_foreign_roots(api->runtime_context, 2048, NULL) !=
      GENE_API_OK) return 4;
  ForeignRead read = {0, 0};
  if (api->new_i64(api->runtime_context, 99, &read.root, NULL) != GENE_API_OK)
    return 1;
  pthread_t thread;
  if (pthread_create(&thread, NULL, read_on_foreign_lane, &read) != 0) {
    api->release(api->runtime_context, read.root, NULL);
    return 2;
  }
  pthread_join(thread, NULL);
  int released = api->release(api->runtime_context, read.root, NULL) == GENE_API_OK;
  int map_released = api->release(api->runtime_context, saved_map,
                                   NULL) == GENE_API_OK;
  int64_t transferred_value = 0;
  int traversed_ok = 0;
  if (read.traversed) {
    traversed_ok = api->copy_i64(api->runtime_context, read.traversed,
                                 &transferred_value, NULL) == GENE_API_OK &&
      transferred_value == 4;
    traversed_ok = api->release(api->runtime_context, read.traversed,
                                NULL) == GENE_API_OK && traversed_ok;
  }
  saved_map = 0;
  return read.ok && released && map_released && traversed_ok ? 0 : 3;
}

typedef struct TransferMany {
  GeneHandle source;
  GeneHandle *ids;
  uint32_t count;
  int reserve_rejected;
  int ok;
} TransferMany;

static void *retain_many_on_foreign_lane(void *raw) {
  TransferMany *state = raw;
  const GeneApi *api = saved_api;
  uint64_t attachment = 0;
  state->ok = api->attach_thread(api->runtime_context, &attachment, NULL) ==
    GENE_API_OK;
  if (state->ok) {
    state->reserve_rejected =
      api->reserve_foreign_roots(api->runtime_context,
                                 state->count + 1, NULL) == GENE_API_ERROR;
    for (uint32_t i = 0; i < state->count; ++i) {
      if (api->retain(api->runtime_context, state->source,
                      &state->ids[i], NULL) != GENE_API_OK) {
        state->ok = 0;
        break;
      }
    }
    if (api->detach_thread(api->runtime_context, attachment, NULL) !=
        GENE_API_OK) state->ok = 0;
  }
  return NULL;
}

int gene_test_api_transfer_many(uint32_t count) {
  if (!saved_api || count == 0 || count > 10000) return 1;
  GeneHandle source = 0;
  if (saved_api->new_i64(saved_api->runtime_context, 77, &source,
                          NULL) != GENE_API_OK) return 2;
  if (!saved_api->reserve_foreign_roots ||
      saved_api->reserve_foreign_roots(saved_api->runtime_context, count,
                                       NULL) != GENE_API_OK) {
    saved_api->release(saved_api->runtime_context, source, NULL);
    return 5;
  }
  TransferMany state = {0};
  state.source = source;
  state.count = count;
  state.ids = calloc(count, sizeof(*state.ids));
  if (!state.ids) {
    saved_api->release(saved_api->runtime_context, source, NULL);
    return 3;
  }
  pthread_t thread;
  if (pthread_create(&thread, NULL, retain_many_on_foreign_lane,
                     &state) != 0) state.ok = 0;
  else pthread_join(thread, NULL);
  uint32_t released = 0;
  for (uint32_t i = 0; i < count; ++i) {
    if (!state.ids[i]) continue;
    if (saved_api->release(saved_api->runtime_context, state.ids[i],
                            NULL) == GENE_API_OK) ++released;
  }
  free(state.ids);
  int source_released = saved_api->release(saved_api->runtime_context,
                                           source, NULL) == GENE_API_OK;
  return state.ok && state.reserve_rejected && released == count &&
    source_released ? 0 : 4;
}

int gene_test_api_transfer_concurrent(uint32_t workers, uint32_t each) {
  if (!saved_api || workers == 0 || workers > 8 || each == 0 ||
      each > 10000 / workers) return 1;
  uint32_t total = workers * each;
  if (!saved_api->reserve_foreign_roots ||
      saved_api->reserve_foreign_roots(saved_api->runtime_context,
                                       total, NULL) != GENE_API_OK) return 2;
  GeneHandle source = 0;
  if (saved_api->new_i64(saved_api->runtime_context, 88,
                          &source, NULL) != GENE_API_OK) return 3;
  GeneHandle *ids = calloc(total, sizeof(*ids));
  TransferMany *states = calloc(workers, sizeof(*states));
  pthread_t *threads = calloc(workers, sizeof(*threads));
  if (!ids || !states || !threads) {
    free(threads);
    free(states);
    free(ids);
    saved_api->release(saved_api->runtime_context, source, NULL);
    return 4;
  }
  uint32_t started = 0;
  for (uint32_t i = 0; i < workers; ++i) {
    states[i].source = source;
    states[i].count = each;
    states[i].ids = ids + i * each;
    if (pthread_create(&threads[i], NULL, retain_many_on_foreign_lane,
                       &states[i]) != 0) break;
    ++started;
  }
  for (uint32_t i = 0; i < started; ++i) pthread_join(threads[i], NULL);
  int ok = started == workers;
  for (uint32_t i = 0; i < started; ++i)
    ok = ok && states[i].ok && states[i].reserve_rejected;
  uint32_t released = 0;
  for (uint32_t i = 0; i < total; ++i) {
    if (ids[i] && saved_api->release(saved_api->runtime_context,
                                      ids[i], NULL) == GENE_API_OK)
      ++released;
  }
  int source_released = saved_api->release(saved_api->runtime_context,
                                           source, NULL) == GENE_API_OK;
  free(threads);
  free(states);
  free(ids);
  return ok && released == total && source_released ? 0 : 5;
}

static GeneHandle held_foreign_id;

int gene_test_api_hold_foreign_id(void) {
  const GeneApi *api = saved_api;
  if (!api || !api->reserve_foreign_roots || held_foreign_id ||
      api->reserve_foreign_roots(api->runtime_context, 1,
                                 NULL) != GENE_API_OK) return 1;
  GeneHandle source = 0;
  if (api->new_i64(api->runtime_context, 123,
                   &source, NULL) != GENE_API_OK) return 2;
  TransferMany state = {0};
  state.source = source;
  state.ids = &held_foreign_id;
  state.count = 1;
  pthread_t thread;
  if (pthread_create(&thread, NULL, retain_many_on_foreign_lane,
                     &state) != 0) return 3;
  pthread_join(thread, NULL);
  int released = api->release(api->runtime_context, source,
                               NULL) == GENE_API_OK;
  return state.ok && state.reserve_rejected && held_foreign_id &&
    released ? 0 : 4;
}

int gene_test_api_release_held_foreign_id(void) {
  if (!saved_api || !held_foreign_id) return 1;
  int result = saved_api->release(saved_api->runtime_context,
                                   held_foreign_id, NULL) == GENE_API_OK;
  held_foreign_id = 0;
  if (saved_map) {
    result = saved_api->release(saved_api->runtime_context,
                                 saved_map, NULL) == GENE_API_OK && result;
    saved_map = 0;
  }
  return result ? 0 : 2;
}

int gene_test_api_foreign_capacity_control(void) {
  const GeneApi *api = saved_api;
  if (!api || !api->reserve_foreign_roots ||
      api->reserve_foreign_roots(api->runtime_context,
        GENE_FOREIGN_ROOT_MAX_CAPACITY + 1, NULL) != GENE_API_ERROR ||
      api->reserve_foreign_roots(api->runtime_context, 2, NULL) != GENE_API_OK)
    return 1;
  GeneHandle source = 0;
  if (api->new_i64(api->runtime_context, 91, &source, NULL) != GENE_API_OK)
    return 2;
  GeneHandle ids[3] = {0};
  TransferMany state = {0};
  state.source = source;
  state.ids = ids;
  state.count = 3;
  pthread_t thread;
  if (pthread_create(&thread, NULL, retain_many_on_foreign_lane,
                     &state) != 0) return 3;
  pthread_join(thread, NULL);
  int bounded = !state.ok && state.reserve_rejected &&
    ids[0] && ids[1] && !ids[2];
  GeneHandle stale = ids[0];
  if (ids[0]) api->release(api->runtime_context, ids[0], NULL);
  if (ids[1]) api->release(api->runtime_context, ids[1], NULL);
  memset(ids, 0, sizeof(ids));
  state.ok = 0;
  state.count = 2;
  if (pthread_create(&thread, NULL, retain_many_on_foreign_lane,
                     &state) != 0) return 4;
  pthread_join(thread, NULL);
  uint32_t kind = 255;
  int stale_rejected = api->kind(api->runtime_context, stale,
                                  &kind, NULL) == GENE_API_ERROR;
  if (ids[0]) api->release(api->runtime_context, ids[0], NULL);
  if (ids[1]) api->release(api->runtime_context, ids[1], NULL);
  int source_released = api->release(api->runtime_context, source,
                                     NULL) == GENE_API_OK;
  return bounded && state.ok && state.reserve_rejected && ids[0] && ids[1] &&
    stale_rejected && source_released ? 0 : 5;
}

int gene_test_api_foreign_growth_control(void) {
  const GeneApi *api = saved_api;
  if (!api || !api->reserve_foreign_roots ||
      api->reserve_foreign_roots(api->runtime_context, 2, NULL) != GENE_API_OK)
    return 1;
  GeneHandle source = 0;
  if (api->new_i64(api->runtime_context, 92, &source, NULL) != GENE_API_OK)
    return 2;
  GeneHandle first[2] = {0};
  TransferMany state = {0};
  state.source = source;
  state.ids = first;
  state.count = 2;
  pthread_t thread;
  if (pthread_create(&thread, NULL, retain_many_on_foreign_lane,
                     &state) != 0) return 3;
  pthread_join(thread, NULL);
  int ok = state.ok && first[0] && first[1];
  if (api->reserve_foreign_roots(api->runtime_context, 8,
                                 NULL) != GENE_API_OK) ok = 0;
  GeneHandle later[6] = {0};
  state.ids = later;
  state.count = 6;
  state.ok = 0;
  if (pthread_create(&thread, NULL, retain_many_on_foreign_lane,
                     &state) != 0) return 4;
  pthread_join(thread, NULL);
  ok = ok && state.ok;
  int64_t value = 0;
  for (uint32_t i = 0; i < 2; ++i) {
    ok = ok && first[i] &&
      api->copy_i64(api->runtime_context, first[i], &value,
                     NULL) == GENE_API_OK && value == 92;
    if (first[i]) api->release(api->runtime_context, first[i], NULL);
  }
  for (uint32_t i = 0; i < 6; ++i) {
    ok = ok && later[i] &&
      api->copy_i64(api->runtime_context, later[i], &value,
                     NULL) == GENE_API_OK && value == 92;
    if (later[i]) api->release(api->runtime_context, later[i], NULL);
  }
  ok = api->release(api->runtime_context, source, NULL) == GENE_API_OK && ok;
  return ok ? 0 : 5;
}

typedef struct RetainChain {
  GeneHandle source, first, second;
  int ok;
} RetainChain;

static void *retain_chain_on_foreign_lane(void *raw) {
  RetainChain *state = raw;
  const GeneApi *api = saved_api;
  uint64_t attachment = 0;
  state->ok = api->attach_thread(api->runtime_context,
                                  &attachment, NULL) == GENE_API_OK;
  if (state->ok) {
    state->ok = api->retain(api->runtime_context, state->source,
                            &state->first, NULL) == GENE_API_OK &&
      api->retain(api->runtime_context, state->first,
                   &state->second, NULL) == GENE_API_OK;
    if (api->detach_thread(api->runtime_context, attachment,
                           NULL) != GENE_API_OK) state->ok = 0;
  }
  return NULL;
}

int gene_test_api_foreign_retain_chain(void) {
  const GeneApi *api = saved_api;
  if (!api || !api->reserve_foreign_roots ||
      api->reserve_foreign_roots(api->runtime_context, 2, NULL) != GENE_API_OK)
    return 1;
  RetainChain state = {0};
  if (api->new_i64(api->runtime_context, 93,
                   &state.source, NULL) != GENE_API_OK) return 2;
  pthread_t thread;
  if (pthread_create(&thread, NULL, retain_chain_on_foreign_lane,
                     &state) != 0) return 3;
  pthread_join(thread, NULL);
  int ok = state.ok && state.first && state.second &&
    state.first != state.second;
  api->release(api->runtime_context, state.source, NULL);
  if (state.first) api->release(api->runtime_context, state.first, NULL);
  int64_t value = 0;
  ok = ok && api->copy_i64(api->runtime_context, state.second,
                           &value, NULL) == GENE_API_OK && value == 93;
  if (state.second) api->release(api->runtime_context, state.second, NULL);
  return ok ? 0 : 4;
}

int gene_test_api_attachment_limits(void) {
  const GeneApi *api = saved_api;
  if (!api || !(api->feature_bits & GENE_API_ATTACHED_FEATURE)) return -1;
  uint64_t tokens[256] = {0};
  size_t count = 0;
  int ok = 1;
  for (; count < 256; ++count) {
    if (api->attach_thread(api->runtime_context,
                           &tokens[count], NULL) != GENE_API_OK ||
        tokens[count] == 0) {
      ok = 0;
      break;
    }
  }
  uint64_t overflow = 0;
  if (ok && (api->attach_thread(api->runtime_context, &overflow,
                                NULL) != GENE_API_ERROR || overflow != 0))
    ok = 0;
  while (count > 0) {
    --count;
    if (api->detach_thread(api->runtime_context, tokens[count],
                           NULL) != GENE_API_OK) ok = 0;
  }
  if (api->detach_thread(api->runtime_context, tokens[0],
                         NULL) != GENE_API_ERROR) ok = 0;
  uint64_t next = 0;
  if (api->attach_thread(api->runtime_context, &next,
                         NULL) != GENE_API_OK || next <= tokens[255])
    ok = 0;
  if (next && api->detach_thread(api->runtime_context, next,
                                 NULL) != GENE_API_OK) ok = 0;
  return ok ? 0 : 1;
}

static pthread_t key_reader_thread;
static atomic_int key_reader_stop;
static atomic_int key_reader_reads;
static atomic_int key_reader_bad;

static void *read_keys_on_foreign_lane(void *unused) {
  (void)unused;
  const GeneApi *api = saved_api;
  uint64_t token = 0;
  if (api->attach_thread(api->runtime_context, &token, NULL) != GENE_API_OK) {
    atomic_store(&key_reader_bad, 1);
    return NULL;
  }
  while (!atomic_load(&key_reader_stop)) {
    uint8_t key[16] = {0};
    GeneOutBytes out = {key, sizeof(key), 0};
    if (api->copy_key(api->runtime_context, saved_map,
                      GENE_MAP_ENTRY, 0, &out, NULL) != GENE_API_OK ||
        out.required != sizeof("map_key") - 1 ||
        memcmp(key, "map_key", sizeof("map_key") - 1) != 0) {
      atomic_store(&key_reader_bad, 1);
      break;
    }
    atomic_fetch_add(&key_reader_reads, 1);
  }
  if (api->detach_thread(api->runtime_context, token,
                         NULL) != GENE_API_OK)
    atomic_store(&key_reader_bad, 1);
  return NULL;
}

int gene_test_api_begin_key_reader(void) {
  if (!saved_api || !saved_map ||
      !(saved_api->feature_bits & GENE_API_ATTACHED_FEATURE)) return -1;
  atomic_store(&key_reader_stop, 0);
  atomic_store(&key_reader_reads, 0);
  atomic_store(&key_reader_bad, 0);
  if (pthread_create(&key_reader_thread, NULL,
                      read_keys_on_foreign_lane, NULL) != 0) return 1;
  for (int i = 0; i < 1000000 && !atomic_load(&key_reader_reads) &&
                      !atomic_load(&key_reader_bad); ++i)
    sched_yield();
  return atomic_load(&key_reader_reads) > 0 ? 0 : 2;
}

int gene_test_api_end_key_reader(void) {
  atomic_store(&key_reader_stop, 1);
  pthread_join(key_reader_thread, NULL);
  return atomic_load(&key_reader_bad) == 0 &&
         atomic_load(&key_reader_reads) > 0 ? 0 : 1;
}

static pthread_mutex_t hold_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t hold_cond = PTHREAD_COND_INITIALIZER;
static pthread_t hold_thread_id;
static const GeneApi *hold_api;
static GeneHandle hold_root;
static uint64_t hold_token;
static int hold_ready, hold_proceed, hold_result;

static void *hold_foreign_lane(void *unused) {
  (void)unused;
  const GeneApi *api = hold_api;
  uint64_t token = 0;
  int attached = api->attach_thread(api->runtime_context,
                                     &token, NULL) == GENE_API_OK;
  pthread_mutex_lock(&hold_lock);
  hold_token = token;
  hold_ready = 1;
  pthread_cond_broadcast(&hold_cond);
  while (!hold_proceed) pthread_cond_wait(&hold_cond, &hold_lock);
  pthread_mutex_unlock(&hold_lock);
  uint32_t kind = 255;
  int closed_read = api->kind(api->runtime_context, hold_root,
                               &kind, NULL) == GENE_API_ERROR;
  int released = api->release(api->runtime_context, hold_root,
                               NULL) == GENE_API_OK;
  int detached = attached &&
      api->detach_thread(api->runtime_context, token, NULL) == GENE_API_OK;
  pthread_mutex_lock(&hold_lock);
  hold_result = attached && closed_read && released && detached ? 0 : 1;
  pthread_mutex_unlock(&hold_lock);
  return NULL;
}

int gene_test_api_begin_hold(void) {
  const GeneApi *api = saved_api;
  if (!api || !(api->feature_bits & GENE_API_ATTACHED_FEATURE)) return -1;
  if (saved_map) {
    if (api->release(api->runtime_context, saved_map,
                     NULL) != GENE_API_OK) return 4;
    saved_map = 0;
  }
  hold_api = api;
  hold_root = 0;
  if (api->new_i64(api->runtime_context, 13,
                   &hold_root, NULL) != GENE_API_OK) return 1;
  pthread_mutex_lock(&hold_lock);
  hold_token = 0;
  hold_ready = hold_proceed = 0;
  hold_result = 1;
  pthread_mutex_unlock(&hold_lock);
  if (pthread_create(&hold_thread_id, NULL, hold_foreign_lane, NULL) != 0) {
    api->release(api->runtime_context, hold_root, NULL);
    return 2;
  }
  pthread_mutex_lock(&hold_lock);
  while (!hold_ready) pthread_cond_wait(&hold_cond, &hold_lock);
  int ready = hold_token != 0;
  pthread_mutex_unlock(&hold_lock);
  return ready ? 0 : 3;
}

int gene_test_api_wrong_lane_detach(void) {
  pthread_mutex_lock(&hold_lock);
  uint64_t token = hold_token;
  const GeneApi *api = hold_api;
  pthread_mutex_unlock(&hold_lock);
  return api && token &&
      api->detach_thread(api->runtime_context, token,
                         NULL) == GENE_API_ERROR ? 0 : 1;
}

int gene_test_api_end_hold(void) {
  pthread_mutex_lock(&hold_lock);
  hold_proceed = 1;
  pthread_cond_broadcast(&hold_cond);
  pthread_mutex_unlock(&hold_lock);
  pthread_join(hold_thread_id, NULL);
  pthread_mutex_lock(&hold_lock);
  int result = hold_result;
  pthread_mutex_unlock(&hold_lock);
  return result;
}

#ifndef GENE_NO_INIT
uint32_t gene_module_init(const GeneApi *api,
                             GeneHandle environment,
                             GeneOutBytes *diagnostic) {
  ++calls;
  if (!api || api->version != GENE_API_VERSION ||
      api->struct_size != sizeof(GeneApi) ||
      !api->runtime_context || !environment) return GENE_API_ERROR;
  if (!(api->feature_bits & GENE_API_IDENTITY_FEATURE) ||
      !api->new_i64 || !api->kind || !api->retain || !api->release)
    return GENE_API_ERROR;
  if (!(api->feature_bits & GENE_API_SCALAR_FEATURE) ||
      !api->new_bool || !api->copy_bool || !api->copy_i64 ||
      !api->new_text || !api->copy_text ||
      !api->new_bytes || !api->copy_bytes)
    return GENE_API_ERROR;
  if (!(api->feature_bits & GENE_API_CALL_DEFINE_FEATURE) ||
      !api->lookup || !api->call || !api->define)
    return GENE_API_ERROR;
  if (!(api->feature_bits & GENE_API_FROZEN_FEATURE) ||
      !api->length || !api->copy_key || !api->traverse)
    return GENE_API_ERROR;
  if (!(api->feature_bits & GENE_API_INGRESS_FEATURE) ||
      !api->ingress_begin || !api->ingress_enqueue || !api->ingress_end)
    return GENE_API_ERROR;
  if (mode == 1) {
    const char message[] = "rejected";
    if (diagnostic) {
      diagnostic->required = sizeof(message) - 1;
      if (diagnostic->data && diagnostic->capacity >= sizeof(message) - 1)
        memcpy(diagnostic->data, message, sizeof(message) - 1);
    }
    return GENE_API_ERROR;
  }
  saved_api = api;
  GeneHandle original = 0, retained = 0;
  uint32_t kind = 255;
  int64_t integer = 0;
  uint8_t message[64];
  GeneOutBytes operation_diag = {message, sizeof(message), 99};
  if (api->new_i64(api->runtime_context, 42, &original,
                   &operation_diag) != GENE_API_OK ||
      operation_diag.required != 0 ||
      !original ||
      api->kind(api->runtime_context, original, &kind, NULL) != GENE_API_OK ||
      kind != 2 ||
      api->copy_i64(api->runtime_context, original, &integer, NULL) != GENE_API_OK ||
      integer != 42 ||
      api->retain(api->runtime_context, original, &retained, NULL) != GENE_API_OK ||
      !retained || retained == original ||
      api->release(api->runtime_context, original, NULL) != GENE_API_OK ||
      api->release(api->runtime_context, retained, NULL) != GENE_API_OK ||
      api->release(api->runtime_context, original,
                   &operation_diag) != GENE_API_ERROR ||
      operation_diag.required == 0)
    return GENE_API_ERROR;

  GeneHandle boolean = 0;
  uint8_t bool_value = 0;
  if (api->new_bool(api->runtime_context, 1, &boolean, NULL) != GENE_API_OK ||
      api->copy_bool(api->runtime_context, boolean, &bool_value, NULL) != GENE_API_OK ||
      bool_value != 1 ||
      api->release(api->runtime_context, boolean, NULL) != GENE_API_OK ||
      api->new_bool(api->runtime_context, 2, &boolean, NULL) != GENE_API_ERROR ||
      boolean != 0)
    return GENE_API_ERROR;

  const uint8_t text[] = {'A', 0, 'B'};
  uint8_t text_copy[sizeof(text)] = {0};
  GeneHandle text_id = 0;
  GeneOutBytes text_out = {NULL, 0, 99};
  if (api->new_text(api->runtime_context, text, sizeof(text),
                    &text_id, NULL) != GENE_API_OK ||
      api->copy_text(api->runtime_context, text_id,
                     &text_out, NULL) != GENE_API_OK ||
      text_out.required != sizeof(text))
    return GENE_API_ERROR;
  text_out.data = text_copy;
  text_out.capacity = sizeof(text_copy);
  if (api->copy_text(api->runtime_context, text_id,
                     &text_out, NULL) != GENE_API_OK ||
      memcmp(text, text_copy, sizeof(text)) != 0 ||
      api->release(api->runtime_context, text_id, NULL) != GENE_API_OK)
    return GENE_API_ERROR;

  const uint8_t octets[] = {0, 255, 1};
  uint8_t bytes_copy[sizeof(octets)] = {0};
  GeneHandle bytes_id = 0;
  GeneOutBytes bytes_out = {bytes_copy, sizeof(bytes_copy), 0};
  if (api->new_bytes(api->runtime_context, octets, sizeof(octets),
                     &bytes_id, NULL) != GENE_API_OK ||
      api->copy_bytes(api->runtime_context, bytes_id,
                      &bytes_out, NULL) != GENE_API_OK ||
      bytes_out.required != sizeof(octets) ||
      memcmp(octets, bytes_copy, sizeof(octets)) != 0 ||
      api->release(api->runtime_context, bytes_id, NULL) != GENE_API_OK)
    return GENE_API_ERROR;

  const uint8_t invalid_utf8[] = {255};
  GeneHandle invalid_id = 0;
  if (api->new_text(api->runtime_context, invalid_utf8,
                    sizeof(invalid_utf8), &invalid_id,
                    &operation_diag) != GENE_API_ERROR ||
      invalid_id != 0 || operation_diag.required == 0)
    return GENE_API_ERROR;
  if (api->new_bytes(api->runtime_context, octets,
                     GENE_API_MAX_COPY_BYTES + 1,
                     &invalid_id, &operation_diag) != GENE_API_ERROR ||
      invalid_id != 0 || operation_diag.required == 0)
    return GENE_API_ERROR;

  const uint8_t callable_name[] = "abi_plus_one";
  const uint8_t function_name[] = "module_function";
  GeneHandle callable = 0, arg = 0, returned = 0, error = 0;
  GeneHandle function_definition = 0;
  int64_t answer = 0;
  if (api->lookup(api->runtime_context, environment, callable_name,
                  sizeof(callable_name) - 1, &callable, NULL) != GENE_API_OK ||
      api->new_i64(api->runtime_context, 41, &arg, NULL) != GENE_API_OK ||
      api->call(api->runtime_context, callable, &arg, 1, environment,
                &returned, &error, NULL) != GENE_API_OK ||
      !returned || error ||
      api->copy_i64(api->runtime_context, returned, &answer, NULL) != GENE_API_OK ||
      answer != 42 ||
      api->define(api->runtime_context, environment, function_name,
                  sizeof(function_name) - 1, callable,
                  &function_definition, &operation_diag) != GENE_API_OK ||
      !function_definition || operation_diag.required != 0 ||
      api->release(api->runtime_context, callable, NULL) != GENE_API_OK ||
      api->release(api->runtime_context, function_definition,
                   NULL) != GENE_API_OK ||
      api->release(api->runtime_context, arg, NULL) != GENE_API_OK ||
      api->release(api->runtime_context, returned, NULL) != GENE_API_OK)
    return GENE_API_ERROR;

  GeneHandle exported_fn = 0;
  if (api->lookup(api->runtime_context, environment, function_name,
                  sizeof(function_name) - 1, &exported_fn,
                  NULL) != GENE_API_OK ||
      api->release(api->runtime_context, exported_fn,
                   NULL) != GENE_API_OK)
    return GENE_API_ERROR;

  const uint8_t failing_name[] = "abi_fail";
  GeneHandle failing = 0;
  returned = 0;
  error = 0;
  if (api->lookup(api->runtime_context, environment, failing_name,
                  sizeof(failing_name) - 1,
                  &failing, NULL) != GENE_API_OK ||
      api->call(api->runtime_context, failing, NULL, 0, environment,
                &returned, &error, &operation_diag) != GENE_API_ERROR ||
      returned || !error || operation_diag.required == 0 ||
      api->release(api->runtime_context, failing, NULL) != GENE_API_OK ||
      api->release(api->runtime_context, error, NULL) != GENE_API_OK)
    return GENE_API_ERROR;

  const uint8_t export_name[] = "native_answer";
  GeneHandle stored = 0, defined = 0, found = 0;
  if (api->new_i64(api->runtime_context, 7, &stored, NULL) != GENE_API_OK ||
      api->define(api->runtime_context, environment, export_name,
                  sizeof(export_name) - 1, stored,
                  &defined, NULL) != GENE_API_OK ||
      api->lookup(api->runtime_context, environment, export_name,
                  sizeof(export_name) - 1, &found, NULL) != GENE_API_OK ||
      api->copy_i64(api->runtime_context, found, &answer, NULL) != GENE_API_OK ||
      answer != 7 ||
      api->release(api->runtime_context, stored, NULL) != GENE_API_OK ||
      api->release(api->runtime_context, defined, NULL) != GENE_API_OK ||
      api->release(api->runtime_context, found, NULL) != GENE_API_OK)
    return GENE_API_ERROR;

  const uint8_t list_name[] = "abi_frozen_list";
  GeneHandle list = 0, child = 0;
  size_t length = 0;
  if (api->lookup(api->runtime_context, environment, list_name,
                  sizeof(list_name) - 1, &list, NULL) != GENE_API_OK ||
      api->length(api->runtime_context, list, GENE_LIST_ITEM,
                  &length, NULL) != GENE_API_OK || length != 2 ||
      api->traverse(api->runtime_context, list, GENE_LIST_ITEM, 0,
                    &child, NULL) != GENE_API_OK ||
      api->copy_i64(api->runtime_context, child, &answer,
                    NULL) != GENE_API_OK || answer != 3 ||
      api->release(api->runtime_context, child, NULL) != GENE_API_OK ||
      api->traverse(api->runtime_context, list, GENE_LIST_ITEM, 2,
                    &child, NULL) != GENE_API_ERROR || child != 0 ||
      api->copy_key(api->runtime_context, list, GENE_LIST_ITEM, 0,
                    &operation_diag, NULL) != GENE_API_ERROR ||
      api->traverse(api->runtime_context, list, GENE_LIST_ITEM, 1,
                    &child, NULL) != GENE_API_OK || !child ||
      api->release(api->runtime_context, list, NULL) != GENE_API_OK ||
      api->traverse(api->runtime_context, list, GENE_LIST_ITEM, 0,
                    &original, NULL) != GENE_API_ERROR)
    return GENE_API_ERROR;
  uint8_t child_text[4] = {0};
  GeneOutBytes child_out = {child_text, sizeof(child_text), 0};
  if (api->copy_text(api->runtime_context, child,
                     &child_out, NULL) != GENE_API_OK ||
      child_out.required != sizeof(child_text) ||
      memcmp(child_text, "item", sizeof(child_text)) != 0 ||
      api->release(api->runtime_context, child, NULL) != GENE_API_OK)
    return GENE_API_ERROR;

  const uint8_t map_name[] = "abi_frozen_map";
  GeneHandle map = 0;
  uint8_t key_copy[16] = {0};
  GeneOutBytes key_out = {NULL, 0, 0};
  if (api->lookup(api->runtime_context, environment, map_name,
                  sizeof(map_name) - 1, &map, NULL) != GENE_API_OK ||
      api->length(api->runtime_context, map, GENE_MAP_ENTRY,
                  &length, NULL) != GENE_API_OK || length != 1 ||
      api->copy_key(api->runtime_context, map, GENE_MAP_ENTRY, 0,
                    &key_out, NULL) != GENE_API_OK ||
      key_out.required != sizeof("map_key") - 1)
    return GENE_API_ERROR;
  key_out.data = key_copy;
  key_out.capacity = sizeof(key_copy);
  if (api->copy_key(api->runtime_context, map, GENE_MAP_ENTRY, 0,
                    &key_out, NULL) != GENE_API_OK ||
      memcmp(key_copy, "map_key", sizeof("map_key") - 1) != 0 ||
      api->traverse(api->runtime_context, map, GENE_MAP_ENTRY, 0,
                    &child, NULL) != GENE_API_OK ||
      api->copy_i64(api->runtime_context, child, &answer,
                    NULL) != GENE_API_OK || answer != 4 ||
      api->release(api->runtime_context, child, NULL) != GENE_API_OK ||
      api->release(api->runtime_context, map, NULL) != GENE_API_OK)
    return GENE_API_ERROR;

  const uint8_t node_name[] = "abi_frozen_node";
  GeneHandle node = 0;
  if (api->lookup(api->runtime_context, environment, node_name,
                  sizeof(node_name) - 1, &node, NULL) != GENE_API_OK ||
      api->length(api->runtime_context, node, GENE_NODE_BODY,
                  &length, NULL) != GENE_API_OK || length != 1 ||
      api->length(api->runtime_context, node, GENE_NODE_PROP,
                  &length, NULL) != GENE_API_OK || length != 1 ||
      api->length(api->runtime_context, node, GENE_NODE_HEAD,
                  &length, NULL) != GENE_API_OK || length != 1 ||
      api->traverse(api->runtime_context, node, GENE_NODE_BODY, 0,
                    &child, NULL) != GENE_API_OK ||
      api->copy_i64(api->runtime_context, child, &answer,
                    NULL) != GENE_API_OK || answer != 6 ||
      api->release(api->runtime_context, child, NULL) != GENE_API_OK ||
      api->copy_key(api->runtime_context, node, GENE_NODE_PROP, 0,
                    &key_out, NULL) != GENE_API_OK ||
      key_out.required != sizeof("node_key") - 1 ||
      memcmp(key_copy, "node_key", sizeof("node_key") - 1) != 0 ||
      api->traverse(api->runtime_context, node, GENE_NODE_PROP, 0,
                    &child, NULL) != GENE_API_OK ||
      api->copy_i64(api->runtime_context, child, &answer,
                    NULL) != GENE_API_OK || answer != 5 ||
      api->release(api->runtime_context, child, NULL) != GENE_API_OK ||
      api->traverse(api->runtime_context, node, GENE_NODE_HEAD, 0,
                    &child, NULL) != GENE_API_OK || !child ||
      api->release(api->runtime_context, child, NULL) != GENE_API_OK ||
      api->release(api->runtime_context, node, NULL) != GENE_API_OK)
    return GENE_API_ERROR;

  const uint8_t mutable_name[] = "abi_mutable_list";
  GeneHandle mutable = 0;
  if (api->lookup(api->runtime_context, environment, mutable_name,
                  sizeof(mutable_name) - 1, &mutable, NULL) != GENE_API_OK ||
      api->length(api->runtime_context, mutable, GENE_LIST_ITEM,
                  &length, &operation_diag) != GENE_API_ERROR ||
      operation_diag.required == 0 ||
      api->release(api->runtime_context, mutable, NULL) != GENE_API_OK)
    return GENE_API_ERROR;
  if (api->feature_bits & GENE_API_ATTACHED_FEATURE) {
    if (api->lookup(api->runtime_context, environment, map_name,
                    sizeof(map_name) - 1, &saved_map,
                    NULL) != GENE_API_OK || !saved_map)
      return GENE_API_ERROR;
  }
  if (diagnostic) diagnostic->required = 0;
  return GENE_API_OK;
}
#endif
