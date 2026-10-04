/* Exact integer temporaries for the checked C backend.
 * I64 parameters/results stay unboxed. Arithmetic promotes only when needed;
 * intermediates must not wrap merely because a later boundary requires I64.
 * Operations borrow inputs, own their output, and leave it intact on OOM.
 * Initialize every output with gene_native_int(0); use copy/drop for ownership.
 */
#ifndef GENE_NATIVE_INTEGER_H
#define GENE_NATIVE_INTEGER_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <inttypes.h>
#include <limits.h>

#define GENE_NATIVE_BASE UINT32_C(1000000000)

typedef struct GeneNativeBigInt {
  size_t refs;
  size_t len;
  int sign;
  /* Release through the allocating module's C runtime. */
  void (*destroy)(struct GeneNativeBigInt *);
  uint32_t digits[];
} GeneNativeBigInt;

typedef struct GeneNativeInt {
  int64_t small;
  GeneNativeBigInt *big;
} GeneNativeInt;

static inline GeneNativeInt gene_native_int(int64_t value) {
  GeneNativeInt result = {value, NULL};
  return result;
}

static inline void gene_native_big_destroy(GeneNativeBigInt *value) {
  free(value);
}

static inline void gene_native_int_drop(GeneNativeInt *value) {
  if (value->big != NULL && --value->big->refs == 0)
    value->big->destroy(value->big);
  *value = gene_native_int(0);
}

static inline void gene_native_int_copy(GeneNativeInt *out,
                                        const GeneNativeInt *value) {
  if (out == value) return;
  GeneNativeInt copied = *value;
  if (copied.big != NULL) ++copied.big->refs;
  gene_native_int_drop(out);
  *out = copied;
}

static inline GeneNativeBigInt *gene_native_big_alloc(size_t length, int sign) {
  if (length > (SIZE_MAX - sizeof(GeneNativeBigInt)) / sizeof(uint32_t))
    return NULL;
  GeneNativeBigInt *result = (GeneNativeBigInt *)calloc(
    1, sizeof(GeneNativeBigInt) + length * sizeof(uint32_t));
  if (result != NULL) {
    result->refs = 1;
    result->len = length;
    result->sign = sign;
    result->destroy = gene_native_big_destroy;
  }
  return result;
}

static inline uint64_t gene_native_magnitude(int64_t value) {
  return value < 0 ? UINT64_C(0) - (uint64_t)value : (uint64_t)value;
}

typedef struct GeneNativeMagnitude {
  size_t len;
  int sign;
  const uint32_t *digits;
  uint32_t local[3];
} GeneNativeMagnitude;

static inline void gene_native_int_view(const GeneNativeInt *value,
                                        GeneNativeMagnitude *out) {
  if (value->big != NULL) {
    out->len = value->big->len;
    out->sign = value->big->sign;
    out->digits = value->big->digits;
  } else {
    uint64_t magnitude = gene_native_magnitude(value->small);
    out->len = 0;
    out->sign = value->small < 0 ? -1 : (value->small > 0 ? 1 : 0);
    while (magnitude != 0) {
      out->local[out->len++] = (uint32_t)(magnitude % GENE_NATIVE_BASE);
      magnitude /= GENE_NATIVE_BASE;
    }
    out->digits = out->local;
  }
}

static inline int gene_native_magnitude_compare(const GeneNativeMagnitude *a,
                                                const GeneNativeMagnitude *b) {
  if (a->len != b->len) return a->len < b->len ? -1 : 1;
  for (size_t i = a->len; i > 0; --i)
    if (a->digits[i - 1] != b->digits[i - 1])
      return a->digits[i - 1] < b->digits[i - 1] ? -1 : 1;
  return 0;
}

static inline int gene_native_int_compare(const GeneNativeInt *a,
                                          const GeneNativeInt *b) {
  if (a->big == NULL && b->big == NULL)
    return a->small < b->small ? -1 : (a->small > b->small ? 1 : 0);
  GeneNativeMagnitude x, y;
  gene_native_int_view(a, &x);
  gene_native_int_view(b, &y);
  if (x.sign != y.sign) return x.sign < y.sign ? -1 : 1;
  return x.sign * gene_native_magnitude_compare(&x, &y);
}

static inline void gene_native_int_take(GeneNativeInt *out, GeneNativeBigInt *big) {
  while (big->len > 0 && big->digits[big->len - 1] == 0) --big->len;
  uint64_t limit = big->sign < 0 ? (UINT64_C(1) << 63) : (uint64_t)INT64_MAX;
  uint64_t magnitude = 0;
  bool fits = true;
  for (size_t i = big->len; i > 0; --i) {
    uint32_t digit = big->digits[i - 1];
    if (magnitude > limit / GENE_NATIVE_BASE ||
        (magnitude == limit / GENE_NATIVE_BASE && digit > limit % GENE_NATIVE_BASE)) {
      fits = false;
      break;
    }
    magnitude = magnitude * GENE_NATIVE_BASE + digit;
  }
  GeneNativeInt result;
  if (fits) {
    int64_t value = big->sign < 0
      ? (magnitude == (UINT64_C(1) << 63) ? INT64_MIN : -(int64_t)magnitude)
      : (int64_t)magnitude;
    result = gene_native_int(value);
    big->destroy(big);
  } else {
    result.small = 0;
    result.big = big;
  }
  gene_native_int_drop(out);
  *out = result;
}

static inline bool gene_native_int_sum(GeneNativeInt *out,
                                       const GeneNativeInt *a,
                                       const GeneNativeInt *b, bool subtract) {
  if (a->big == NULL && b->big == NULL) {
    int64_t x = a->small, y = b->small;
    bool overflow = subtract
      ? ((y > 0 && x < INT64_MIN + y) || (y < 0 && x > INT64_MAX + y))
      : ((y > 0 && x > INT64_MAX - y) || (y < 0 && x < INT64_MIN - y));
    if (!overflow) {
      int64_t result = subtract ? x - y : x + y;
      gene_native_int_drop(out);
      *out = gene_native_int(result);
      return true;
    }
  }
  GeneNativeMagnitude x, y;
  gene_native_int_view(a, &x);
  gene_native_int_view(b, &y);
  if (subtract) y.sign = -y.sign;
  size_t length = x.len > y.len ? x.len : y.len;
  if (length == SIZE_MAX) return false;
  GeneNativeBigInt *result = gene_native_big_alloc(length + 1, x.sign);
  if (result == NULL) return false;
  if (x.sign == y.sign) {
    uint64_t carry = 0;
    for (size_t i = 0; i < length; ++i) {
      uint64_t digit = carry + (i < x.len ? x.digits[i] : 0) +
        (uint64_t)(i < y.len ? y.digits[i] : 0);
      result->digits[i] = (uint32_t)(digit % GENE_NATIVE_BASE);
      carry = digit / GENE_NATIVE_BASE;
    }
    result->digits[length] = (uint32_t)carry;
  } else {
    int order = gene_native_magnitude_compare(&x, &y);
    const GeneNativeMagnitude *large = order >= 0 ? &x : &y;
    const GeneNativeMagnitude *small = order >= 0 ? &y : &x;
    result->sign = large->sign;
    int64_t borrow = 0;
    for (size_t i = 0; i < large->len; ++i) {
      int64_t digit = (int64_t)large->digits[i] - borrow -
        (i < small->len ? small->digits[i] : 0);
      borrow = digit < 0;
      if (borrow) digit += GENE_NATIVE_BASE;
      result->digits[i] = (uint32_t)digit;
    }
  }
  gene_native_int_take(out, result);
  return true;
}

static inline bool gene_native_int_add(GeneNativeInt *out,
                                       const GeneNativeInt *a, const GeneNativeInt *b) {
  return gene_native_int_sum(out, a, b, false);
}

static inline bool gene_native_int_sub(GeneNativeInt *out,
                                       const GeneNativeInt *a, const GeneNativeInt *b) {
  return gene_native_int_sum(out, a, b, true);
}

static inline bool gene_native_int_mul(GeneNativeInt *out,
                                       const GeneNativeInt *a, const GeneNativeInt *b) {
  if (a->big == NULL && b->big == NULL) {
    bool negative = (a->small < 0) != (b->small < 0);
    uint64_t x = gene_native_magnitude(a->small), y = gene_native_magnitude(b->small);
    uint64_t limit = negative ? (UINT64_C(1) << 63) : (uint64_t)INT64_MAX;
    if (y == 0 || x <= limit / y) {
      uint64_t magnitude = x * y;
      int64_t value = negative
        ? (magnitude == (UINT64_C(1) << 63) ? INT64_MIN : -(int64_t)magnitude)
        : (int64_t)magnitude;
      gene_native_int_drop(out);
      *out = gene_native_int(value);
      return true;
    }
  }
  GeneNativeMagnitude x, y;
  gene_native_int_view(a, &x);
  gene_native_int_view(b, &y);
  if (x.len > SIZE_MAX - y.len) return false;
  GeneNativeBigInt *result = gene_native_big_alloc(x.len + y.len, x.sign * y.sign);
  if (result == NULL) return false;
  for (size_t i = 0; i < x.len; ++i) {
    uint64_t carry = 0;
    for (size_t j = 0; j < y.len; ++j) {
      uint64_t digit = (uint64_t)x.digits[i] * y.digits[j] + result->digits[i + j] + carry;
      result->digits[i + j] = (uint32_t)(digit % GENE_NATIVE_BASE);
      carry = digit / GENE_NATIVE_BASE;
    }
    result->digits[i + y.len] = (uint32_t)carry;
  }
  gene_native_int_take(out, result);
  return true;
}

/* Caller owns the returned decimal string. */
static inline char *gene_native_int_decimal(const GeneNativeInt *value) {
  if (value->big == NULL) {
    char *result = (char *)malloc(22);
    if (result != NULL) snprintf(result, 22, "%" PRId64, value->small);
    return result;
  }
  const GeneNativeBigInt *big = value->big;
  if (big->len > (SIZE_MAX - 2) / 9) return NULL;
  size_t capacity = big->len * 9 + 2;
  char *result = (char *)malloc(capacity);
  if (result == NULL) return NULL;
  size_t used = 0;
  if (big->sign < 0) result[used++] = '-';
  used += (size_t)snprintf(result + used, capacity - used, "%" PRIu32,
                           big->digits[big->len - 1]);
  for (size_t i = big->len - 1; i > 0; --i)
    used += (size_t)snprintf(result + used, capacity - used, "%09" PRIu32,
                             big->digits[i - 1]);
  return result;
}
#endif
