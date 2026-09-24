#ifndef GENE_NATIVE_API_V5_H
#define GENE_NATIVE_API_V5_H

#include <stddef.h>
#include <stdint.h>

#define GENE_API_V5_VERSION 5u
#define GENE_API_V5_FEATURE_INGRESS UINT64_C(1)
#define GENE_INGRESS_ACCEPTED 0
#define GENE_INGRESS_CLOSED -1
#define GENE_INGRESS_OVERFLOW -2
#define GENE_INGRESS_ALLOCATION_FAILED -3
#define GENE_INGRESS_ENTRY_MISSING -4

typedef int32_t (*GeneIngressBegin)(void *context, uint64_t generation);
typedef int32_t (*GeneIngressEnqueue)(void *context, const void *data,
                                      size_t length);
typedef void (*GeneIngressEnd)(void *context);
struct GeneApiV5;
typedef int32_t (*GeneIngressRegister)(const struct GeneApiV5 *api,
                                       void *context, uint64_t generation,
                                       void **native_context);
typedef int32_t (*GeneIngressUnregister)(void *native_context);

typedef struct GeneApiV5 {
  uint32_t version;
  uint32_t struct_size;
  uint64_t feature_bits;
  GeneIngressBegin ingress_begin;
  GeneIngressEnqueue ingress_enqueue;
  GeneIngressEnd ingress_end;
} GeneApiV5;

typedef int32_t (*GeneModuleInitV5)(const GeneApiV5 *api, void *module);

#endif
