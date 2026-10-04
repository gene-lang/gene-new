#include "gene/native_integer.h"
#include <assert.h>
#include <errno.h>
#include <string.h>
#ifdef NDEBUG
#error This regression fixture requires active assertions.
#endif

static void print_integer(const GeneNativeInt *value) {
  char *text = gene_native_int_decimal(value);
  assert(text != NULL);
  puts(text);
  free(text);
}

int main(int argc, char **argv) {
  GeneNativeInt a = gene_native_int(INT64_MAX), b = gene_native_int(1);
  GeneNativeInt sum = gene_native_int(0), diff = gene_native_int(0);
  GeneNativeInt product = gene_native_int(0), copy = gene_native_int(0);
  if (argc == 3) {
    char *end;
    errno = 0;
    a.small = (int64_t)strtoll(argv[1], &end, 10);
    assert(errno == 0 && *end == '\0');
    b.small = (int64_t)strtoll(argv[2], &end, 10);
    assert(errno == 0 && *end == '\0');
    assert(gene_native_int_add(&sum, &a, &b));
    assert(gene_native_int_sub(&diff, &a, &b));
    assert(gene_native_int_mul(&product, &sum, &diff));
    print_integer(&sum);
    print_integer(&diff);
    print_integer(&product);
    assert(gene_native_int_add(&sum, &sum, &product));
    assert(gene_native_int_sub(&sum, &sum, &diff));
    print_integer(&sum);
  } else {
    assert(argc == 1);
    assert(gene_native_int_add(&a, &a, &b));
    assert(a.big != NULL);
    gene_native_int_copy(&copy, &a);
    assert(gene_native_int_sub(&a, &a, &b));
    assert(a.big == NULL && a.small == INT64_MAX);
    assert(gene_native_int_compare(&copy, &a) > 0);
    gene_native_int_drop(&a);
    a = gene_native_int(INT64_MIN);
    assert(gene_native_int_sub(&a, &a, &b));
    assert(a.big != NULL);
    assert(gene_native_int_add(&a, &a, &b));
    assert(a.big == NULL && a.small == INT64_MIN);
    assert(gene_native_int_mul(&product, &a, &a));
    assert(product.big != NULL);
    assert(gene_native_int_sub(&product, &product, &product));
    assert(product.big == NULL && product.small == 0);
    gene_native_int_drop(&a);
    a = gene_native_int(1);
    for (int i = 0; i < 1000; ++i)
      assert(gene_native_int_add(&a, &a, &a));
    char *text = gene_native_int_decimal(&a);
    assert(text != NULL && strlen(text) == 302);
    assert(strncmp(text, "107150860718626732094842504906", 30) == 0);
    free(text);
    gene_native_int_drop(&b);
    assert(gene_native_int_mul(&a, &a, &b));
    assert(a.big == NULL && a.small == 0);
    puts("ownership and promotion: ok");
  }
  gene_native_int_drop(&a);
  gene_native_int_drop(&b);
  gene_native_int_drop(&sum);
  gene_native_int_drop(&diff);
  gene_native_int_drop(&product);
  gene_native_int_drop(&copy);
  return 0;
}
