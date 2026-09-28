#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include "gene_native_api.h"

typedef struct ModuleContext {
  uint32_t marker;
  uint32_t operation;
} ModuleContext;
static atomic_uint live_contexts;
static atomic_uint retired_contexts;

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
