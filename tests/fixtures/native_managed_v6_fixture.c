#include <string.h>
#include "native_api_v6.h"

static uint32_t mode;
static uint32_t calls;

void gene_test_v6_set_mode(uint32_t value) { mode = value; }
uint32_t gene_test_v6_calls(void) { return calls; }

#ifndef GENE_V6_NO_INIT
uint32_t gene_module_init_v6(const GeneApiV6 *api,
                             GeneHandleV6 environment,
                             GeneOutBytesV6 *diagnostic) {
  ++calls;
  if (!api || api->version != GENE_API_V6_VERSION ||
      api->struct_size != sizeof(GeneApiV6) ||
      !api->runtime_context || !environment) return GENE_API_V6_ERROR;
  if (!(api->feature_bits & GENE_API_V6_IDENTITY_FEATURE) ||
      !api->new_i64 || !api->kind || !api->retain || !api->release)
    return GENE_API_V6_ERROR;
  if (mode == 1) {
    const char message[] = "rejected";
    if (diagnostic) {
      diagnostic->required = sizeof(message) - 1;
      if (diagnostic->data && diagnostic->capacity >= sizeof(message) - 1)
        memcpy(diagnostic->data, message, sizeof(message) - 1);
    }
    return GENE_API_V6_ERROR;
  }
  GeneHandleV6 original = 0, retained = 0;
  uint32_t kind = 255;
  uint8_t message[64];
  GeneOutBytesV6 operation_diag = {message, sizeof(message), 99};
  if (api->new_i64(api->runtime_context, 42, &original,
                   &operation_diag) != GENE_API_V6_OK ||
      operation_diag.required != 0 ||
      !original ||
      api->kind(api->runtime_context, original, &kind, NULL) != GENE_API_V6_OK ||
      kind != 2 ||
      api->retain(api->runtime_context, original, &retained, NULL) != GENE_API_V6_OK ||
      !retained || retained == original ||
      api->release(api->runtime_context, original, NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, retained, NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, original,
                   &operation_diag) != GENE_API_V6_ERROR ||
      operation_diag.required == 0)
    return GENE_API_V6_ERROR;
  if (diagnostic) diagnostic->required = 0;
  return GENE_API_V6_OK;
}
#endif
