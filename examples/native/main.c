/* Driver for the typed_native SQLite example.
 *
 * Everything here is ordinary C. The row loop calls into functions that were
 * written in Gene (sqlite_rows.gene) and compiled to C by
 * `gene compile --target c` — they take the sqlite3_stmt* unboxed, in a
 * register, and call SQLite directly.
 *
 * The loop lives in C rather than Gene because the typed_native subset has no
 * loop or arithmetic forms yet; see README.md.
 */

#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>

/* From sqlite_shim.c */
sqlite3 *gene_sqlite_open_memory(void);
int gene_sqlite_exec(sqlite3 *db, const char *sql);
sqlite3_stmt *gene_sqlite_prepare(sqlite3 *db, const char *sql);
void gene_sqlite_close(sqlite3 *db);

/* Compiled from sqlite_rows.gene. The generated header-less C exposes these
 * with the gene_native_ prefix and unboxed machine types. */
int64_t gene_native_step_row(sqlite3_stmt *stmt);
int64_t gene_native_reset_stmt(sqlite3_stmt *stmt);
int64_t gene_native_column_count(sqlite3_stmt *stmt);
int64_t gene_native_column_i64(sqlite3_stmt *stmt, int64_t column);
int64_t gene_native_read_first(sqlite3_stmt *stmt, int64_t first_column);
int64_t gene_native_row_total(sqlite3_stmt *stmt, int64_t amount_column,
                              int64_t quantity_column);
int64_t gene_native_row_total_capped(sqlite3_stmt *stmt, int64_t amount_column,
                                     int64_t quantity_column, int64_t cap);

#define ROW 100 /* SQLITE_ROW */

int main(void) {
  sqlite3 *db = gene_sqlite_open_memory();
  if (db == NULL) {
    fprintf(stderr, "could not open in-memory database\n");
    return 1;
  }

  if (gene_sqlite_exec(db,
        "create table orders (amount integer, quantity integer);"
        "insert into orders values (10, 3), (20, 5), (30, 7);") != SQLITE_OK) {
    fprintf(stderr, "could not seed database\n");
    gene_sqlite_close(db);
    return 1;
  }

  sqlite3_stmt *stmt =
      gene_sqlite_prepare(db, "select amount, quantity from orders");
  if (stmt == NULL) {
    fprintf(stderr, "could not prepare statement\n");
    gene_sqlite_close(db);
    return 1;
  }

  printf("columns: %lld\n", (long long)gene_native_column_count(stmt));

  int64_t rows = 0;
  int64_t total = 0;
  int64_t capped = 0;
  /* The per-row work is compiled: row_total does both column reads and the
   * multiply inside one Gene-compiled C function. Only the loop is here,
   * because the subset still has no loop form. */
  while (gene_native_step_row(stmt) == ROW) {
    total += gene_native_row_total(stmt, 0, 1);
    capped += gene_native_row_total_capped(stmt, 0, 1, 120);
    rows += 1;
  }

  printf("rows: %lld\n", (long long)rows);
  printf("total: %lld\n", (long long)total);
  printf("capped: %lld\n", (long long)capped);

  gene_native_reset_stmt(stmt);
  sqlite3_finalize(stmt);
  gene_sqlite_close(db);
  return 0;
}
