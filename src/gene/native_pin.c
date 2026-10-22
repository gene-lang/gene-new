/* Process-lifetime pinning of a native extension image. dladdr is a GNU
 * extension on glibc, so this file defines _GNU_SOURCE before any include. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>

/* 0: pinned; 1: no loaded image contains symbol; 2: the loader refused.
 * Linux requires RTLD_LAZY or RTLD_NOW alongside RTLD_NOLOAD. The returned
 * handle is never closed: RTLD_NODELETE already keeps the image mapped, and
 * the extra reference documents the intent. */
int gene_native_pin_image(const void *symbol, int refuse) {
  Dl_info info;
  if (!symbol || !dladdr(symbol, &info) || !info.dli_fname) return 1;
  if (refuse) return 2;
  void *handle = dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD | RTLD_NODELETE);
  return handle ? 0 : 2;
}
