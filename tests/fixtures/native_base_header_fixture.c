#include <stdint.h>
#include <stdlib.h>
#include "native_api_v6_base.h"

/* Built against the GeneApi header from before task_fail_copy and the later
 * entries were appended: the runtime's larger table must still serve it. */

static const GeneApi *api;
static GeneProducer producer;
static GeneHandle callable;
static GeneRegistration registration;

static uint32_t start(const GeneApi *table, void *raw, const GeneHandle *args,
                      size_t count, const GeneNamedArg *named,
                      size_t named_count, GeneHandle env, GeneHandle *out,
                      GeneHandle *error, GeneOutBytes *diagnostic) {
  (void)raw; (void)args; (void)count; (void)named; (void)named_count;
  (void)error;
  return table->new_task(table->runtime_context, env, out, &producer,
                         diagnostic);
}

static void retire(void *raw) { free(raw); }

uint32_t gene_module_init(const GeneApi *table, GeneHandle env,
                          GeneOutBytes *diagnostic) {
  if (!table || table->version != GENE_API_VERSION ||
      table->struct_size < sizeof(GeneApi) ||
      !(table->feature_bits & GENE_API_TASK_COPY_FEATURE) ||
      !table->copy_f64 || !table->new_f64) return GENE_API_ERROR;
  api = table;
  void *context = malloc(1);
  if (!context) return GENE_API_ERROR;
  const uint8_t name[] = "start";
  uint32_t status = table->register_callback(table->runtime_context, env,
      name, sizeof(name) - 1, start, context, retire, &callable,
      &registration, diagnostic);
  if (status != GENE_API_OK) free(context);
  return status;
}

uint32_t gene_base_submit(int64_t value) {
  GeneOutBytes diagnostic = {0};
  GeneCopiedResult result = {.kind = GENE_COPY_I64, .scalar = value};
  return api->task_submit_copy(api->runtime_context, producer, &result,
                               &diagnostic);
}

uint32_t gene_base_float_roundtrip(double input, double *output) {
  GeneOutBytes diagnostic = {0};
  GeneHandle root = 0;
  uint32_t status = api->new_f64(api->runtime_context, input, &root,
                                 &diagnostic);
  if (status != GENE_API_OK) return status;
  status = api->copy_f64(api->runtime_context, root, output, &diagnostic);
  api->release(api->runtime_context, root, &diagnostic);
  return status;
}

uint32_t gene_base_close(void) {
  GeneOutBytes diagnostic = {0};
  GeneHandle task = 0;
  api->release(api->runtime_context, callable, &diagnostic);
  if (api->request_close(api->runtime_context, registration,
                         &diagnostic) > GENE_API_PENDING) return GENE_API_ERROR;
  uint32_t status = api->wait_closed(api->runtime_context, registration,
                                     &task, &diagnostic);
  if (task) api->release(api->runtime_context, task, &diagnostic);
  return status;
}
