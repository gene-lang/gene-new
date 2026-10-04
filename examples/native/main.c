/* Direct C caller of Gene's checked native ABI. The same row loop is also
 * compiled from Gene by scan_total; this driver demonstrates both paths.
 */
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include "gene_native.h"

GeneNativeStatus gene_native_open_db(GeneNativeError *, const char *, sqlite3 **);
GeneNativeStatus gene_native_exec(GeneNativeError *, sqlite3 *, const char *, int64_t *);
GeneNativeStatus gene_native_prepare(GeneNativeError *, sqlite3 *, const char *, sqlite3_stmt **);
GeneNativeStatus gene_native_close_db(GeneNativeError *, sqlite3 *, int64_t *);
GeneNativeStatus gene_native_step_row(GeneNativeError *, sqlite3_stmt *, int64_t *);
GeneNativeStatus gene_native_reset_stmt(GeneNativeError *, sqlite3_stmt *, int64_t *);
GeneNativeStatus gene_native_column_count(GeneNativeError *, sqlite3_stmt *, int64_t *);
GeneNativeStatus gene_native_row_total(GeneNativeError *, sqlite3_stmt *, int32_t, int32_t, int64_t *);
GeneNativeStatus gene_native_row_total_capped(GeneNativeError *, sqlite3_stmt *, int32_t, int32_t, int64_t, int64_t *);
GeneNativeStatus gene_native_scan_total(GeneNativeError *, sqlite3_stmt *, int32_t, int32_t, int64_t, int64_t *);

static int checked(GeneNativeStatus status, GeneNativeError *error) {
  if (status == GENE_NATIVE_OK) return 1;
  fprintf(stderr, "native error %d: %s%s%s\n", (int)status,
    error->where ? error->where : "unknown",
    error->expected && *error->expected ? " expected " : "",
    error->expected ? error->expected : "");
  gene_aot_error_clear(error);
  return 0;
}

#define CHECK(call) do { if (!checked((call), &error)) goto cleanup; } while (0)

int main(void) {
  GeneNativeError error = {0};
  sqlite3 *db = NULL;
  sqlite3_stmt *stmt = NULL;
  int exit_status = 1;
  int64_t code = 0, columns = 0, rows = 0, total = 0, capped = 0;
  CHECK(gene_native_open_db(&error, ":memory:", &db));
  if (db == NULL) { fputs("could not open database\n", stderr); goto cleanup; }
  CHECK(gene_native_exec(&error, db,
    "create table orders (amount integer, quantity integer);"
    "insert into orders values (10, 3), (20, 5), (30, 7);", &code));
  if (code != SQLITE_OK) goto cleanup;
  CHECK(gene_native_prepare(&error, db, "select amount, quantity from orders", &stmt));
  if (stmt == NULL) goto cleanup;
  CHECK(gene_native_column_count(&error, stmt, &columns));
  printf("columns: %lld\n", (long long)columns);
  for (;;) {
    CHECK(gene_native_step_row(&error, stmt, &code));
    if (code != SQLITE_ROW) break;
    int64_t row = 0, limited = 0;
    CHECK(gene_native_row_total(&error, stmt, 0, 1, &row));
    CHECK(gene_native_row_total_capped(&error, stmt, 0, 1, 120, &limited));
    total += row;
    capped += limited;
    ++rows;
  }
  printf("rows: %lld\ntotal: %lld\ncapped: %lld\n",
    (long long)rows, (long long)total, (long long)capped);
  CHECK(gene_native_reset_stmt(&error, stmt, &code));
  CHECK(gene_native_scan_total(&error, stmt, 0, 1, SQLITE_ROW, &total));
  printf("scanned: %lld\n", (long long)total);
  exit_status = 0;
cleanup:
  if (stmt != NULL) sqlite3_finalize(stmt);
  if (db != NULL && !checked(gene_native_close_db(&error, db, &code), &error))
    exit_status = 1;
  gene_aot_error_clear(&error);
  return exit_status;
}
