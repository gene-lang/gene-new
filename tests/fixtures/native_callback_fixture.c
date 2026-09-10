#include <stdint.h>

typedef int (*GeneVisitCallback)(void *, int64_t);

/* The callback and context are borrowed only until this function returns. */
int gene_test_callback_visit(int count, GeneVisitCallback callback, void *context,
                             int *returned_from_callback) {
  for (int i = 0; i < count; ++i) {
    int stop = callback(context, (int64_t)i);
    ++*returned_from_callback;
    if (stop) return 1;
  }
  return 0;
}

#ifndef _WIN32
#include <pthread.h>
struct ForeignVisit {
  GeneVisitCallback callback;
  void *context;
  int result;
};
static void *foreign_visit(void *raw) {
  struct ForeignVisit *visit = raw;
  visit->result = visit->callback(visit->context, 7);
  return 0;
}
int gene_test_callback_foreign(GeneVisitCallback callback, void *context) {
  struct ForeignVisit visit = {callback, context, -1};
  pthread_t thread;
  if (pthread_create(&thread, 0, foreign_visit, &visit)) return -2;
  if (pthread_join(thread, 0)) return -3;
  return visit.result;
}
#endif
