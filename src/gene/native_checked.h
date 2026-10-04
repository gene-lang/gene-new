/* Checked native ABI version 2. Initialize errors with {0}, then clear them
 * after use. Results are written only on success. Error values own any wide
 * integer storage; generated functions clean their temporaries on all exits.
 */
#ifndef GENE_NATIVE_CHECKED_H
#define GENE_NATIVE_CHECKED_H
#include "native_integer.h"
#define GENE_NATIVE_ABI_VERSION 2

typedef enum GeneNativeStatus {
  GENE_NATIVE_OK = 0,
  GENE_NATIVE_TYPE_ERROR = 1,
  GENE_NATIVE_NO_MEMORY = 2,
  GENE_NATIVE_NULL_FIELD = 3,
  GENE_NATIVE_BAD_ARGUMENT = 4,
  GENE_NATIVE_RUNTIME_ERROR = 5,
  GENE_NATIVE_ORDER_ERROR = 6
} GeneNativeStatus;

typedef enum GeneNativeValueKind {
  GENE_NATIVE_INT = 0,
  GENE_NATIVE_FLOAT = 1,
  GENE_NATIVE_BOOL = 2,
  GENE_NATIVE_STRING = 3,
  GENE_NATIVE_NIL = 4,
  GENE_NATIVE_POINTER = 5,
  GENE_NATIVE_CHAR = 6
} GeneNativeValueKind;

typedef struct GeneNativeTraceFrame {
  const char *function;
  const char *source;
  int line;
  int column;
} GeneNativeTraceFrame;

typedef struct GeneNativeError {
  GeneNativeStatus status;
  const char *where;
  const char *expected;
  GeneNativeValueKind actual_kind;
  GeneNativeInt actual_int;
  double actual_float;
  bool actual_bool;
  const char *actual_string;
  char message[192];
  GeneNativeTraceFrame *frames;
  size_t frame_count;
  size_t frame_capacity;
  size_t omitted_frames;
  void *(*resize_frames)(void *, size_t);
  void (*free_frames)(void *);
} GeneNativeError;

GENE_AOT_INLINE void gene_aot_error_clear(GeneNativeError *error) {
  if (error == NULL) return;
  gene_aot_int_drop(&error->actual_int);
  if (error->frames != NULL) error->free_frames(error->frames);
  *error = (GeneNativeError){0};
}

GENE_AOT_INLINE GeneNativeStatus gene_aot_error_set(GeneNativeError *error,
    GeneNativeStatus status, const char *where, const char *expected) {
  if (error != NULL) {
    gene_aot_error_clear(error);
    error->status = status;
    error->where = where;
    error->expected = expected;
    error->actual_kind = GENE_NATIVE_NIL;
  }
  return status;
}

GENE_AOT_INLINE GeneNativeStatus gene_aot_error_integer(GeneNativeError *error,
    const char *where, const char *expected, const GeneNativeInt *value) {
  GeneNativeInt retained = gene_aot_int(0);
  if (error != NULL) gene_aot_int_copy(&retained, value);
  gene_aot_error_set(error, GENE_NATIVE_TYPE_ERROR, where, expected);
  if (error != NULL) {
    error->actual_kind = GENE_NATIVE_INT;
    error->actual_int = retained;
  }
  return GENE_NATIVE_TYPE_ERROR;
}

GENE_AOT_INLINE const char *gene_aot_kind_label(GeneNativeValueKind kind) {
  switch (kind) {
    case GENE_NATIVE_INT: return "vkInt";
    case GENE_NATIVE_BOOL: return "vkBool";
    case GENE_NATIVE_CHAR: return "vkChar";
    case GENE_NATIVE_FLOAT: return "vkFloat";
    case GENE_NATIVE_STRING: return "vkString";
    case GENE_NATIVE_NIL: return "vkNil";
    default: return "vkCPtr";
  }
}

GENE_AOT_INLINE GeneNativeStatus gene_aot_operator_error(GeneNativeError *error,
    const char *operation, GeneNativeValueKind left, GeneNativeValueKind right,
    bool ordering) {
  GeneNativeStatus status = ordering ? GENE_NATIVE_ORDER_ERROR : GENE_NATIVE_RUNTIME_ERROR;
  gene_aot_error_set(error, status, "", "");
  if (error != NULL) {
    if (ordering)
      snprintf(error->message, sizeof(error->message),
        "values have no common default ordering: %s and %s",
        gene_aot_kind_label(left), gene_aot_kind_label(right));
    else
      snprintf(error->message, sizeof(error->message), "%s expects numbers, got %s",
        operation, gene_aot_kind_label(left != GENE_NATIVE_INT ? left : right));
    error->where = error->message;
  }
  return status;
}

GENE_AOT_INLINE void gene_aot_error_frame(GeneNativeError *error,
    const char *function, const char *source, int line, int column) {
  if (error == NULL) return;
  if (error->frame_count == error->frame_capacity) {
    size_t capacity = error->frame_capacity == 0 ? 8 : error->frame_capacity * 2;
    if (capacity < error->frame_capacity ||
        capacity > SIZE_MAX / sizeof(GeneNativeTraceFrame)) {
      ++error->omitted_frames;
      return;
    }
    if (error->resize_frames == NULL) {
      error->resize_frames = realloc;
      error->free_frames = free;
    }
    void *grown = error->resize_frames(error->frames,
      capacity * sizeof(GeneNativeTraceFrame));
    if (grown == NULL) { ++error->omitted_frames; return; }
    error->frames = (GeneNativeTraceFrame *)grown;
    error->frame_capacity = capacity;
  }
  error->frames[error->frame_count++] =
    (GeneNativeTraceFrame){function, source, line, column};
}

GENE_AOT_INLINE GeneNativeStatus gene_aot_require_i64(GeneNativeError *error,
    const GeneNativeInt *value, const char *where, int64_t *out) {
  if (value->big != NULL) return gene_aot_error_integer(error, where, "I64", value);
  *out = value->small;
  return GENE_NATIVE_OK;
}

GENE_AOT_INLINE GeneNativeStatus gene_aot_require_i32(GeneNativeError *error,
    const GeneNativeInt *value, const char *where, int32_t *out) {
  if (value->big != NULL || value->small < INT32_MIN || value->small > INT32_MAX)
    return gene_aot_error_integer(error, where, "I32", value);
  *out = (int32_t)value->small;
  return GENE_NATIVE_OK;
}
#endif
