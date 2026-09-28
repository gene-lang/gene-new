#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <uv.h>

#include "gene_native_api.h"

/* The owner thread creates, runs, and closes both libuv handles. The only
 * cross-thread libuv operation is uv_async_send, which libuv permits. */
typedef struct GeneTimer {
  GeneApi api;
  void *ingress;
  uint64_t generation;
  pthread_t thread;
  pthread_mutex_t mutex;
  pthread_cond_t ready_cond;
  int thread_started;
  int ready;
  int start_error;
  int close_error;
  int closed_handles;
  uv_loop_t loop;
  uv_timer_t timer;
  uv_async_t stop;
} GeneTimer;

static atomic_uint_fast64_t live_contexts;
static atomic_uint_fast64_t live_handles;
static atomic_uint_fast64_t closed_handles;

uint64_t gene_timer_live_contexts(void) {
  return atomic_load(&live_contexts);
}

uint64_t gene_timer_live_handles(void) {
  return atomic_load(&live_handles);
}

uint64_t gene_timer_closed_handles(void) {
  return atomic_load(&closed_handles);
}

uint32_t gene_module_init(const GeneApi *api, GeneHandle environment,
                          GeneOutBytes *diagnostic) {
  (void)diagnostic;
  if (!environment || !api || api->version != GENE_API_VERSION ||
      api->struct_size != sizeof(GeneApi) ||
      !(api->feature_bits & GENE_API_INGRESS_FEATURE) ||
      !api->ingress_begin || !api->ingress_enqueue || !api->ingress_end)
    return 1;
  return 0;
}

static void timer_notify(uv_timer_t *handle) {
  GeneTimer *state = handle->data;
  if (state->api.ingress_begin(state->ingress, state->generation)) {
    /* The ingress API copies these four bytes before returning. */
    (void)state->api.ingress_enqueue(state->ingress, "tick", 4);
    state->api.ingress_end(state->ingress);
  }
}

static void handle_closed(uv_handle_t *handle) {
  GeneTimer *state = handle->data;
  state->closed_handles++;
  atomic_fetch_sub(&live_handles, 1);
  atomic_fetch_add(&closed_handles, 1);
}

static void stop_timer(uv_async_t *handle) {
  GeneTimer *state = handle->data;
  uv_timer_stop(&state->timer);
  uv_close((uv_handle_t *)&state->timer, handle_closed);
  uv_close((uv_handle_t *)&state->stop, handle_closed);
}

static void *timer_thread(void *raw) {
  GeneTimer *state = raw;
  int error = uv_loop_init(&state->loop);
  int timer_ready = 0;
  int async_ready = 0;
  if (!error) {
    error = uv_timer_init(&state->loop, &state->timer);
    if (!error) {
      timer_ready = 1;
      atomic_fetch_add(&live_handles, 1);
      state->timer.data = state;
      error = uv_async_init(&state->loop, &state->stop, stop_timer);
      if (!error) {
        async_ready = 1;
        atomic_fetch_add(&live_handles, 1);
        state->stop.data = state;
        error = uv_timer_start(&state->timer, timer_notify, 10, 10);
      }
    }
    if (error) {
      if (timer_ready) uv_close((uv_handle_t *)&state->timer, handle_closed);
      if (async_ready) uv_close((uv_handle_t *)&state->stop, handle_closed);
      uv_run(&state->loop, UV_RUN_DEFAULT);
      state->close_error = uv_loop_close(&state->loop);
    }
  }
  pthread_mutex_lock(&state->mutex);
  state->start_error = error;
  state->ready = 1;
  pthread_cond_signal(&state->ready_cond);
  pthread_mutex_unlock(&state->mutex);
  if (!error) {
    uv_run(&state->loop, UV_RUN_DEFAULT);
    if (state->closed_handles != 2)
      state->close_error = 1;
    else
      state->close_error = uv_loop_close(&state->loop);
  }
  return NULL;
}

int gene_timer_register(const GeneApi *api, void *ingress,
                        uint64_t generation, void **native_context) {
  if (!api || !ingress || !native_context ||
      api->version != GENE_API_VERSION ||
      api->struct_size != sizeof(GeneApi)) return 1;
  *native_context = NULL;
  GeneTimer *state = calloc(1, sizeof(*state));
  if (!state) return 2;
  atomic_fetch_add(&live_contexts, 1);
  state->api = *api;
  state->ingress = ingress;
  state->generation = generation;
  if (pthread_mutex_init(&state->mutex, NULL)) {
    atomic_fetch_sub(&live_contexts, 1);
    free(state);
    return 3;
  }
  if (pthread_cond_init(&state->ready_cond, NULL)) {
    pthread_mutex_destroy(&state->mutex);
    atomic_fetch_sub(&live_contexts, 1);
    free(state);
    return 4;
  }
  /* Even a failed start returns an unregisterable context to the runtime. */
  *native_context = state;
  if (pthread_create(&state->thread, NULL, timer_thread, state)) return 5;
  state->thread_started = 1;
  pthread_mutex_lock(&state->mutex);
  while (!state->ready) pthread_cond_wait(&state->ready_cond, &state->mutex);
  int error = state->start_error;
  pthread_mutex_unlock(&state->mutex);
  return error;
}

int gene_timer_unregister(void *native_context) {
  GeneTimer *state = native_context;
  if (!state) return 1;
  if (state->thread_started) {
    if (!state->start_error) {
      int error = uv_async_send(&state->stop);
      if (error) return error;
    }
    if (pthread_join(state->thread, NULL)) return 2;
  }
  if (state->close_error) return state->close_error;
  pthread_cond_destroy(&state->ready_cond);
  pthread_mutex_destroy(&state->mutex);
  atomic_fetch_sub(&live_contexts, 1);
  free(state);
  return 0;
}
