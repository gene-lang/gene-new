#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <pthread.h>
#include "gene_native_api.h"

typedef struct ModuleContext {
  uint32_t marker;
  uint32_t operation;
} ModuleContext;
static atomic_uint live_contexts;
static atomic_uint retired_contexts;
static const GeneApi *pending_api;
static uint32_t worker_supported;
static GeneProducer pending_producer;

typedef struct CopyWorker {
  const GeneApi *api;
  GeneProducer producer;
} CopyWorker;

uint32_t gene_test_module_supports_copy_worker(void) {
  return worker_supported;
}

static void *submit_copy_worker(void *raw) {
  CopyWorker *worker = raw;
  GeneOutBytes diagnostic = {0};
  uint64_t attachment = 0;
  if (worker->api->attach_thread(worker->api->runtime_context,
                                  &attachment, &diagnostic) == GENE_API_OK) {
    const uint8_t text[] = "worker-copy";
    GeneCopiedResult value = {
      .kind = GENE_COPY_BYTES, .data = text, .length = sizeof(text) - 1};
    uint32_t status = worker->api->task_submit_copy(
      worker->api->runtime_context, worker->producer, &value, &diagnostic);
    if (status != GENE_API_OK) {
      uint8_t ignored = 0;
      worker->api->task_retire(worker->api->runtime_context,
                               worker->producer, &ignored, &diagnostic);
    }
    worker->api->detach_thread(worker->api->runtime_context, attachment,
                               &diagnostic);
  }
  free(worker);
  return NULL;
}

uint32_t gene_test_module_complete_task(void) {
  if (!pending_api || !pending_producer) return GENE_API_ERROR;
  GeneOutBytes diagnostic = {0};
  uint8_t accepted = 0;
  uint32_t status = pending_api->task_complete(pending_api->runtime_context,
                                               pending_producer, 0,
                                               &accepted, &diagnostic);
  pending_api = NULL;
  pending_producer = 0;
  return status == GENE_API_OK && accepted ? GENE_API_OK : GENE_API_ERROR;
}

uint32_t gene_test_module_submit_copy(void) {
  if (!pending_api || !pending_producer) return GENE_API_ERROR;
  const uint8_t text[] = "installed-copy";
  GeneCopiedResult value = {
    .kind = GENE_COPY_TEXT, .data = text, .length = sizeof(text) - 1};
  GeneOutBytes diagnostic = {0};
  uint32_t status = pending_api->task_submit_copy(
    pending_api->runtime_context, pending_producer, &value, &diagnostic);
  if (status == GENE_API_OK) {
    pending_api = NULL;
    pending_producer = 0;
  }
  return status;
}

uint32_t gene_test_module_live_contexts(void) {
  return atomic_load(&live_contexts);
}
uint32_t gene_test_module_retired_contexts(void) {
  return atomic_load(&retired_contexts);
}

static void retire_context(void *raw) {
  ModuleContext *context = raw;
  if (context && context->marker == 0x72) {
    atomic_fetch_sub(&live_contexts, 1);
    atomic_fetch_add(&retired_contexts, 1);
  }
  free(context);
}

static uint32_t module_callback(const GeneApi *api, void *raw,
                          const GeneHandle *args, size_t arg_count,
                          const GeneNamedArg *named, size_t named_count,
                          GeneHandle environment, GeneHandle *out_value,
                          GeneHandle *out_error, GeneOutBytes *diagnostic) {
  ModuleContext *context = raw;
  (void)out_error;
  if (!context || context->marker != 0x72 || !api || !environment ||
      !args || arg_count < 1 || arg_count > 2 ||
      named || named_count || !out_value)
    return GENE_API_ERROR;
  int64_t value = 0;
  uint32_t status = api->copy_i64(api->runtime_context, args[0],
                                   &value, diagnostic);
  if (status != GENE_API_OK) return status;
  if ((value != 99 || context->operation != 1) && arg_count != 1)
    return GENE_API_ERROR;
  if (value == 96 && context->operation == 1) {
    if (!(api->feature_bits & GENE_API_ATTACHED_FEATURE))
      return GENE_API_ERROR;
    GeneProducer producer = 0;
    status = api->new_task(api->runtime_context, environment, out_value,
                            &producer, diagnostic);
    if (status != GENE_API_OK) return status;
    CopyWorker *worker = calloc(1, sizeof(*worker));
    if (!worker) {
      uint8_t ignored = 0;
      api->task_retire(api->runtime_context, producer, &ignored, diagnostic);
      api->release(api->runtime_context, *out_value, diagnostic);
      *out_value = 0;
      return GENE_API_ERROR;
    }
    worker->api = api;
    worker->producer = producer;
    pthread_t thread;
    if (pthread_create(&thread, NULL, submit_copy_worker, worker) != 0) {
      free(worker);
      uint8_t ignored = 0;
      api->task_retire(api->runtime_context, producer, &ignored, diagnostic);
      api->release(api->runtime_context, *out_value, diagnostic);
      *out_value = 0;
      return GENE_API_ERROR;
    }
    pthread_detach(thread);
    return GENE_API_OK;
  }
  if ((value == 97 || value == 98) && context->operation == 1) {
    if (pending_producer) return GENE_API_ERROR;
    status = api->new_task(api->runtime_context, environment, out_value,
                            &pending_producer, diagnostic);
    if (status != GENE_API_OK) return status;
    pending_api = api;
    return GENE_API_OK;
  }
  if (value == 99 && context->operation == 1) {
    if (arg_count != 2) return GENE_API_ERROR;
    GeneHandle output = 0, error = 0;
    status = api->call(api->runtime_context, args[1], NULL, 0,
                       environment, &output, &error, diagnostic);
    if (output) api->release(api->runtime_context, output, diagnostic);
    if (error) api->release(api->runtime_context, error, diagnostic);
    if (status != GENE_API_OK) return status;
  }
  return api->new_i64(api->runtime_context,
                      context->operation == 1 ? value + 1 : value * 2,
                      out_value, diagnostic);
}

uint32_t gene_module_init(const GeneApi *api, GeneHandle environment,
                          GeneOutBytes *diagnostic) {
  if (!api || api->version != GENE_API_VERSION ||
      api->struct_size != sizeof(GeneApi) || !environment ||
      !(api->feature_bits & GENE_API_CALLBACK_FEATURE) ||
      !api->register_callback || !api->request_close || !api->wait_closed)
    return GENE_API_ERROR;
  if (!(api->feature_bits & GENE_API_TASK_PRODUCER_FEATURE) ||
      !(api->feature_bits & GENE_API_TASK_COPY_FEATURE) ||
      !api->new_task || !api->task_complete || !api->task_submit_copy)
    return GENE_API_ERROR;
  worker_supported = (api->feature_bits & GENE_API_ATTACHED_FEATURE) ? 1 : 0;
  ModuleContext *context = calloc(1, sizeof(*context));
  if (!context) return GENE_API_ERROR;
  context->marker = 0x72;
  context->operation = 1;
  atomic_fetch_add(&live_contexts, 1);
  const uint8_t name[] = "increment";
  GeneHandle callable = 0;
  GeneRegistration token = 0;
  uint32_t status = api->register_callback(api->runtime_context,
    environment, name, sizeof(name) - 1, module_callback, context,
    retire_context, &callable, &token, diagnostic);
  if (status != GENE_API_OK) {
    atomic_fetch_sub(&live_contexts, 1);
    free(context); /* failed registration retains caller ownership */
    return status;
  }
  api->release(api->runtime_context, callable, diagnostic);
  ModuleContext *second = calloc(1, sizeof(*second));
  if (!second) return GENE_API_ERROR;
  second->marker = 0x72;
  second->operation = 2;
  atomic_fetch_add(&live_contexts, 1);
  const uint8_t second_name[] = "double_value";
  GeneHandle second_callable = 0;
  GeneRegistration second_token = 0;
  status = api->register_callback(api->runtime_context, environment,
    second_name, sizeof(second_name) - 1, module_callback, second,
    retire_context, &second_callable, &second_token, diagnostic);
  if (status != GENE_API_OK) {
    atomic_fetch_sub(&live_contexts, 1);
    free(second);
    return status; /* loader rolls back the first registration */
  }
  api->release(api->runtime_context, second_callable, diagnostic);
#ifdef GENE_FAIL_INIT
  return GENE_API_ERROR;
#else
  return GENE_API_OK;
#endif
}
