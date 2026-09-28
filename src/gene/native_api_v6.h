#ifndef GENE_NATIVE_API_V6_H
#define GENE_NATIVE_API_V6_H

#include <stddef.h>
#include <stdint.h>

#define GENE_API_V6_VERSION UINT32_C(6)
#define GENE_API_V6_OK UINT32_C(0)
#define GENE_API_V6_ERROR UINT32_C(1)
#define GENE_API_V6_PANIC UINT32_C(2)
#define GENE_API_V6_CANCELLED UINT32_C(3)
#define GENE_API_V6_PENDING UINT32_C(4)

typedef uint64_t GeneHandleV6;
typedef uint64_t GeneRegistrationV6;

typedef struct GeneOutBytesV6 {
  uint8_t *data;
  size_t capacity;
  size_t required;
} GeneOutBytesV6;

typedef struct GeneNamedArgV6 {
  const uint8_t *name;
  size_t name_len;
  GeneHandleV6 value;
} GeneNamedArgV6;

struct GeneApiV6;
typedef uint32_t (*GeneNativeCallbackV6)(
    const struct GeneApiV6 *api, void *user_context,
    const GeneHandleV6 *args, size_t arg_count,
    const GeneNamedArgV6 *named, size_t named_count,
    GeneHandleV6 environment, GeneHandleV6 *out_value,
    GeneHandleV6 *out_error, GeneOutBytesV6 *diagnostic);
typedef void (*GeneContextRetireV6)(void *user_context);

typedef struct GeneApiV6 {
  uint32_t version;
  uint32_t struct_size;
  uint64_t feature_bits;
  void *runtime_context;
  uint32_t (*attach_thread)(void *, uint64_t *, GeneOutBytesV6 *);
  uint32_t (*detach_thread)(void *, uint64_t, GeneOutBytesV6 *);
  uint32_t (*retain)(void *, GeneHandleV6, GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*release)(void *, GeneHandleV6, GeneOutBytesV6 *);
  uint32_t (*kind)(void *, GeneHandleV6, uint32_t *, GeneOutBytesV6 *);
  uint32_t (*copy_bool)(void *, GeneHandleV6, uint8_t *, GeneOutBytesV6 *);
  uint32_t (*copy_i64)(void *, GeneHandleV6, int64_t *, GeneOutBytesV6 *);
  uint32_t (*copy_text)(void *, GeneHandleV6, GeneOutBytesV6 *, GeneOutBytesV6 *);
  uint32_t (*copy_bytes)(void *, GeneHandleV6, GeneOutBytesV6 *, GeneOutBytesV6 *);
  uint32_t (*new_bool)(void *, uint8_t, GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*new_i64)(void *, int64_t, GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*new_text)(void *, const uint8_t *, size_t,
                       GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*new_bytes)(void *, const uint8_t *, size_t,
                        GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*length)(void *, GeneHandleV6, uint32_t, size_t *, GeneOutBytesV6 *);
  uint32_t (*copy_key)(void *, GeneHandleV6, uint32_t, size_t,
                       GeneOutBytesV6 *, GeneOutBytesV6 *);
  uint32_t (*traverse)(void *, GeneHandleV6, uint32_t, size_t,
                       GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*call)(void *, GeneHandleV6, const GeneHandleV6 *, size_t,
                   GeneHandleV6, GeneHandleV6 *, GeneHandleV6 *,
                   GeneOutBytesV6 *);
  uint32_t (*define)(void *, GeneHandleV6, const uint8_t *, size_t,
                     GeneHandleV6, GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*register_callback)(
      void *, GeneHandleV6, const uint8_t *, size_t,
      GeneNativeCallbackV6, void *, GeneContextRetireV6,
      GeneHandleV6 *, GeneRegistrationV6 *, GeneOutBytesV6 *);
  uint32_t (*request_close)(void *, GeneRegistrationV6, GeneOutBytesV6 *);
  uint32_t (*wait_closed)(void *, GeneRegistrationV6, GeneHandleV6 *,
                          GeneOutBytesV6 *);
} GeneApiV6;

typedef uint32_t (*GeneModuleInitV6)(const GeneApiV6 *api,
                                     GeneHandleV6 environment,
                                     GeneOutBytesV6 *diagnostic);

#endif
