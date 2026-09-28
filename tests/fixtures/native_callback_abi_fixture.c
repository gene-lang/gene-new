#include <stdint.h>
#include <stdlib.h>
#include <string.h>
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
