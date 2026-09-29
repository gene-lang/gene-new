#ifndef GENE_NATIVE_API_H
#define GENE_NATIVE_API_H

#include <stddef.h>
#include <stdint.h>

#define GENE_API_VERSION UINT32_C(6)
#define GENE_API_OK UINT32_C(0)
#define GENE_API_ERROR UINT32_C(1)
#define GENE_API_PANIC UINT32_C(2)
#define GENE_API_CANCELLED UINT32_C(3)
#define GENE_API_PENDING UINT32_C(4)
#define GENE_API_IDENTITY_FEATURE UINT64_C(1)
#define GENE_API_SCALAR_FEATURE UINT64_C(2)
#define GENE_API_CALL_DEFINE_FEATURE UINT64_C(4)
#define GENE_API_FROZEN_FEATURE UINT64_C(8)
#define GENE_API_ATTACHED_FEATURE UINT64_C(16)
#define GENE_API_INGRESS_FEATURE UINT64_C(32)
#define GENE_API_CALLBACK_FEATURE UINT64_C(64)
#define GENE_API_TASK_PRODUCER_FEATURE UINT64_C(128)
#define GENE_API_TASK_COPY_FEATURE UINT64_C(256)
#define GENE_API_FLOAT_FEATURE UINT64_C(512)
#define GENE_API_FOREIGN_ROOTS_FEATURE UINT64_C(1024)
#define GENE_API_MAX_COPY_BYTES (64u * 1024u * 1024u)
#define GENE_FOREIGN_ROOT_MAX_CAPACITY UINT32_C(65536)
#define GENE_LIST_ITEM UINT32_C(0)
#define GENE_MAP_ENTRY UINT32_C(1)
#define GENE_NODE_BODY UINT32_C(2)
#define GENE_NODE_PROP UINT32_C(3)
#define GENE_NODE_HEAD UINT32_C(4)

typedef uint64_t GeneHandle;
typedef uint64_t GeneRegistration;
typedef uint64_t GeneProducer;

/* reserve_foreign_roots runs on the root lane before an attached C lane
 * creates owning IDs. Capacity is absolute, bounded, and retryable after
 * root polling retires released IDs and active borrows. */

#define GENE_COPY_NIL UINT32_C(0)
#define GENE_COPY_BOOL UINT32_C(1)
#define GENE_COPY_I64 UINT32_C(2)
#define GENE_COPY_TEXT UINT32_C(3)
#define GENE_COPY_BYTES UINT32_C(4)
#define GENE_COPY_F64 UINT32_C(5)

typedef struct GeneCopiedResult {
  uint32_t kind;
  int64_t scalar;
  double real;
  const uint8_t *data;
  size_t length;
} GeneCopiedResult;

/* task_submit_copy copies Text/Bytes before return and consumes its producer
 * only on queue admission. OK means queued, not user Task acceptance. A failed
 * admission leaves the producer token valid. The runtime builds the Gene
 * value and retires the producer on its root lane. */

typedef struct GeneOutBytes {
  uint8_t *data;
  size_t capacity;
  size_t required;
} GeneOutBytes;

typedef struct GeneNamedArg {
  const uint8_t *name;
  size_t name_len;
  GeneHandle value;
} GeneNamedArg;

struct GeneApi;
typedef uint32_t (*GeneNativeCallback)(
    const struct GeneApi *api, void *user_context,
    const GeneHandle *args, size_t arg_count,
    const GeneNamedArg *named, size_t named_count,
    GeneHandle environment, GeneHandle *out_value,
    GeneHandle *out_error, GeneOutBytes *diagnostic);
typedef void (*GeneContextRetire)(void *user_context);

/* Callback arguments and environment are valid only during the C call;
 * retain an ID before storing it. On OK, out_value 0 means Gene nil,
 * otherwise it is an owning ID. On failure, out_value must be 0 and
 * out_error may contain an owning typed error ID. A callback may return a
 * Task; native work behind it must keep a producer ticket
 * until physical retirement. Registration is available during module initialization.
 * request_close denies new calls and may return PENDING during an active call.
 * wait_closed consumes the registration token and returns an owning Task ID;
 * the Task settles after user_context retirement and library release. */

typedef struct GeneApi {
  uint32_t version;
  uint32_t struct_size;
  uint64_t feature_bits;
  void *runtime_context;
  uint32_t (*attach_thread)(void *, uint64_t *, GeneOutBytes *);
  uint32_t (*detach_thread)(void *, uint64_t, GeneOutBytes *);
  uint32_t (*retain)(void *, GeneHandle, GeneHandle *, GeneOutBytes *);
  uint32_t (*release)(void *, GeneHandle, GeneOutBytes *);
  uint32_t (*kind)(void *, GeneHandle, uint32_t *, GeneOutBytes *);
  uint32_t (*copy_bool)(void *, GeneHandle, uint8_t *, GeneOutBytes *);
  uint32_t (*copy_i64)(void *, GeneHandle, int64_t *, GeneOutBytes *);
  uint32_t (*copy_text)(void *, GeneHandle, GeneOutBytes *, GeneOutBytes *);
  uint32_t (*copy_bytes)(void *, GeneHandle, GeneOutBytes *, GeneOutBytes *);
  uint32_t (*new_bool)(void *, uint8_t, GeneHandle *, GeneOutBytes *);
  uint32_t (*new_i64)(void *, int64_t, GeneHandle *, GeneOutBytes *);
  uint32_t (*new_text)(void *, const uint8_t *, size_t,
                       GeneHandle *, GeneOutBytes *);
  uint32_t (*new_bytes)(void *, const uint8_t *, size_t,
                        GeneHandle *, GeneOutBytes *);
  uint32_t (*length)(void *, GeneHandle, uint32_t, size_t *, GeneOutBytes *);
  uint32_t (*copy_key)(void *, GeneHandle, uint32_t, size_t,
                       GeneOutBytes *, GeneOutBytes *);
  uint32_t (*traverse)(void *, GeneHandle, uint32_t, size_t,
                       GeneHandle *, GeneOutBytes *);
  uint32_t (*call)(void *, GeneHandle, const GeneHandle *, size_t,
                   GeneHandle, GeneHandle *, GeneHandle *,
                   GeneOutBytes *);
  uint32_t (*define)(void *, GeneHandle, const uint8_t *, size_t,
                     GeneHandle, GeneHandle *, GeneOutBytes *);
  uint32_t (*register_callback)(
      void *, GeneHandle, const uint8_t *, size_t,
      GeneNativeCallback, void *, GeneContextRetire,
      GeneHandle *, GeneRegistration *, GeneOutBytes *);
  uint32_t (*request_close)(void *, GeneRegistration, GeneOutBytes *);
  uint32_t (*wait_closed)(void *, GeneRegistration, GeneHandle *,
                          GeneOutBytes *);
  uint32_t (*lookup)(void *, GeneHandle, const uint8_t *, size_t,
                     GeneHandle *, GeneOutBytes *);
  int32_t (*ingress_begin)(void *context, uint64_t generation);
  int32_t (*ingress_enqueue)(void *context, const void *data, size_t length);
  void (*ingress_end)(void *context);
  uint32_t (*new_task)(void *, GeneHandle, GeneHandle *, GeneProducer *,
                       GeneOutBytes *);
  uint32_t (*task_complete)(void *, GeneProducer, GeneHandle, uint8_t *,
                            GeneOutBytes *);
  uint32_t (*task_fail)(void *, GeneProducer, const uint8_t *, size_t,
                        GeneHandle, uint8_t *, GeneOutBytes *);
  uint32_t (*task_cancel)(void *, GeneProducer, uint8_t *, GeneOutBytes *);
  uint32_t (*task_retire)(void *, GeneProducer, uint8_t *, GeneOutBytes *);
  uint32_t (*task_submit_copy)(void *, GeneProducer,
                               const GeneCopiedResult *, GeneOutBytes *);
  uint32_t (*copy_f64)(void *, GeneHandle, double *, GeneOutBytes *);
  uint32_t (*new_f64)(void *, double, GeneHandle *, GeneOutBytes *);
  uint32_t (*reserve_foreign_roots)(void *, size_t, GeneOutBytes *);
} GeneApi;

#define GENE_INGRESS_ACCEPTED 0
#define GENE_INGRESS_CLOSED -1
#define GENE_INGRESS_OVERFLOW -2
#define GENE_INGRESS_ALLOCATION_FAILED -3
#define GENE_INGRESS_ENTRY_MISSING -4

typedef int32_t (*GeneIngressRegister)(const GeneApi *api, void *context,
                                       uint64_t generation,
                                       void **native_context);
typedef int32_t (*GeneIngressUnregister)(void *native_context);

typedef uint32_t (*GeneModuleInit)(const GeneApi *api,
                                     GeneHandle environment,
                                     GeneOutBytes *diagnostic);

#endif
