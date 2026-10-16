#ifndef GENE_NATIVE_WAKE_H
#define GENE_NATIVE_WAKE_H
#include <stdint.h>
typedef struct GeneNativeWake GeneNativeWake;
GeneNativeWake *gene_wake_new(int64_t lane, const void *key);
void gene_wake_retain(GeneNativeWake *wake);
void gene_wake_release(GeneNativeWake *wake);
void gene_wake_signal(GeneNativeWake *wake);
void gene_wake_signal_lanes(void);
void gene_wake_signal_key(const void *key);
int gene_wake_fd(GeneNativeWake *wake);
void gene_wake_drain(GeneNativeWake *wake);
int gene_wake_wait(int64_t lane, int timeout_ms);
#ifdef GENE_EXEC_TESTS
uint64_t gene_wake_test_waits(void);
#endif
#endif
