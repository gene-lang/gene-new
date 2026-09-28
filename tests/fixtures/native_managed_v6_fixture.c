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
  if (!(api->feature_bits & GENE_API_V6_SCALAR_FEATURE) ||
      !api->new_bool || !api->copy_bool || !api->copy_i64 ||
      !api->new_text || !api->copy_text ||
      !api->new_bytes || !api->copy_bytes)
    return GENE_API_V6_ERROR;
  if (!(api->feature_bits & GENE_API_V6_CALL_DEFINE_FEATURE) ||
      !api->lookup || !api->call || !api->define)
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
  int64_t integer = 0;
  uint8_t message[64];
  GeneOutBytesV6 operation_diag = {message, sizeof(message), 99};
  if (api->new_i64(api->runtime_context, 42, &original,
                   &operation_diag) != GENE_API_V6_OK ||
      operation_diag.required != 0 ||
      !original ||
      api->kind(api->runtime_context, original, &kind, NULL) != GENE_API_V6_OK ||
      kind != 2 ||
      api->copy_i64(api->runtime_context, original, &integer, NULL) != GENE_API_V6_OK ||
      integer != 42 ||
      api->retain(api->runtime_context, original, &retained, NULL) != GENE_API_V6_OK ||
      !retained || retained == original ||
      api->release(api->runtime_context, original, NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, retained, NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, original,
                   &operation_diag) != GENE_API_V6_ERROR ||
      operation_diag.required == 0)
    return GENE_API_V6_ERROR;

  GeneHandleV6 boolean = 0;
  uint8_t bool_value = 0;
  if (api->new_bool(api->runtime_context, 1, &boolean, NULL) != GENE_API_V6_OK ||
      api->copy_bool(api->runtime_context, boolean, &bool_value, NULL) != GENE_API_V6_OK ||
      bool_value != 1 ||
      api->release(api->runtime_context, boolean, NULL) != GENE_API_V6_OK ||
      api->new_bool(api->runtime_context, 2, &boolean, NULL) != GENE_API_V6_ERROR ||
      boolean != 0)
    return GENE_API_V6_ERROR;

  const uint8_t text[] = {'A', 0, 'B'};
  uint8_t text_copy[sizeof(text)] = {0};
  GeneHandleV6 text_id = 0;
  GeneOutBytesV6 text_out = {NULL, 0, 99};
  if (api->new_text(api->runtime_context, text, sizeof(text),
                    &text_id, NULL) != GENE_API_V6_OK ||
      api->copy_text(api->runtime_context, text_id,
                     &text_out, NULL) != GENE_API_V6_OK ||
      text_out.required != sizeof(text))
    return GENE_API_V6_ERROR;
  text_out.data = text_copy;
  text_out.capacity = sizeof(text_copy);
  if (api->copy_text(api->runtime_context, text_id,
                     &text_out, NULL) != GENE_API_V6_OK ||
      memcmp(text, text_copy, sizeof(text)) != 0 ||
      api->release(api->runtime_context, text_id, NULL) != GENE_API_V6_OK)
    return GENE_API_V6_ERROR;

  const uint8_t octets[] = {0, 255, 1};
  uint8_t bytes_copy[sizeof(octets)] = {0};
  GeneHandleV6 bytes_id = 0;
  GeneOutBytesV6 bytes_out = {bytes_copy, sizeof(bytes_copy), 0};
  if (api->new_bytes(api->runtime_context, octets, sizeof(octets),
                     &bytes_id, NULL) != GENE_API_V6_OK ||
      api->copy_bytes(api->runtime_context, bytes_id,
                      &bytes_out, NULL) != GENE_API_V6_OK ||
      bytes_out.required != sizeof(octets) ||
      memcmp(octets, bytes_copy, sizeof(octets)) != 0 ||
      api->release(api->runtime_context, bytes_id, NULL) != GENE_API_V6_OK)
    return GENE_API_V6_ERROR;

  const uint8_t invalid_utf8[] = {255};
  GeneHandleV6 invalid_id = 0;
  if (api->new_text(api->runtime_context, invalid_utf8,
                    sizeof(invalid_utf8), &invalid_id,
                    &operation_diag) != GENE_API_V6_ERROR ||
      invalid_id != 0 || operation_diag.required == 0)
    return GENE_API_V6_ERROR;
  if (api->new_bytes(api->runtime_context, octets,
                     GENE_API_V6_MAX_COPY_BYTES + 1,
                     &invalid_id, &operation_diag) != GENE_API_V6_ERROR ||
      invalid_id != 0 || operation_diag.required == 0)
    return GENE_API_V6_ERROR;

  const uint8_t callable_name[] = "v6_plus_one";
  const uint8_t function_name[] = "module_function";
  GeneHandleV6 callable = 0, arg = 0, returned = 0, error = 0;
  GeneHandleV6 function_definition = 0;
  int64_t answer = 0;
  if (api->lookup(api->runtime_context, environment, callable_name,
                  sizeof(callable_name) - 1, &callable, NULL) != GENE_API_V6_OK ||
      api->new_i64(api->runtime_context, 41, &arg, NULL) != GENE_API_V6_OK ||
      api->call(api->runtime_context, callable, &arg, 1, environment,
                &returned, &error, NULL) != GENE_API_V6_OK ||
      !returned || error ||
      api->copy_i64(api->runtime_context, returned, &answer, NULL) != GENE_API_V6_OK ||
      answer != 42 ||
      api->define(api->runtime_context, environment, function_name,
                  sizeof(function_name) - 1, callable,
                  &function_definition, &operation_diag) != GENE_API_V6_OK ||
      !function_definition || operation_diag.required != 0 ||
      api->release(api->runtime_context, callable, NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, function_definition,
                   NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, arg, NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, returned, NULL) != GENE_API_V6_OK)
    return GENE_API_V6_ERROR;

  GeneHandleV6 exported_fn = 0;
  if (api->lookup(api->runtime_context, environment, function_name,
                  sizeof(function_name) - 1, &exported_fn,
                  NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, exported_fn,
                   NULL) != GENE_API_V6_OK)
    return GENE_API_V6_ERROR;

  const uint8_t failing_name[] = "v6_fail";
  GeneHandleV6 failing = 0;
  returned = 0;
  error = 0;
  if (api->lookup(api->runtime_context, environment, failing_name,
                  sizeof(failing_name) - 1,
                  &failing, NULL) != GENE_API_V6_OK ||
      api->call(api->runtime_context, failing, NULL, 0, environment,
                &returned, &error, &operation_diag) != GENE_API_V6_ERROR ||
      returned || !error || operation_diag.required == 0 ||
      api->release(api->runtime_context, failing, NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, error, NULL) != GENE_API_V6_OK)
    return GENE_API_V6_ERROR;

  const uint8_t export_name[] = "native_answer";
  GeneHandleV6 stored = 0, defined = 0, found = 0;
  if (api->new_i64(api->runtime_context, 7, &stored, NULL) != GENE_API_V6_OK ||
      api->define(api->runtime_context, environment, export_name,
                  sizeof(export_name) - 1, stored,
                  &defined, NULL) != GENE_API_V6_OK ||
      api->lookup(api->runtime_context, environment, export_name,
                  sizeof(export_name) - 1, &found, NULL) != GENE_API_V6_OK ||
      api->copy_i64(api->runtime_context, found, &answer, NULL) != GENE_API_V6_OK ||
      answer != 7 ||
      api->release(api->runtime_context, stored, NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, defined, NULL) != GENE_API_V6_OK ||
      api->release(api->runtime_context, found, NULL) != GENE_API_V6_OK)
    return GENE_API_V6_ERROR;
  if (diagnostic) diagnostic->required = 0;
  return GENE_API_V6_OK;
}
#endif
