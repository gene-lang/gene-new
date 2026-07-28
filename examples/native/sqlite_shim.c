/* Thin C adapters for the SQLite calls the typed_native subset cannot express
 * directly. This is the "foreign library" the Gene module binds to with
 * ffi/fn; nothing here is generated.
 *
 * Two gaps make these necessary, both honest limits of the current subset
 * rather than workarounds for bugs:
 *
 *   1. Out-parameters. sqlite3_open_v2 and sqlite3_prepare_v2 return their
 *      handle through a sqlite3** / sqlite3_stmt**. Typed-native Gene has no
 *      way to take the address of a local, so acquisition happens here and
 *      Gene receives an already-open pointer.
 *
 *   2. int-typed parameters. sqlite3_column_int64 takes `int` for the column
 *      index, and a Gene I64 cannot narrow into it (correctly — int is 32-bit
 *      here). These adapters take int64_t and narrow explicitly.
 */

#include <sqlite3.h>
#include <stddef.h>
#include <stdint.h>

sqlite3 *gene_sqlite_open_memory(void) {
  sqlite3 *db = NULL;
  if (sqlite3_open(":memory:", &db) != SQLITE_OK) {
    if (db != NULL) sqlite3_close(db);
    return NULL;
  }
  return db;
}

int gene_sqlite_exec(sqlite3 *db, const char *sql) {
  return sqlite3_exec(db, sql, NULL, NULL, NULL);
}

sqlite3_stmt *gene_sqlite_prepare(sqlite3 *db, const char *sql) {
  sqlite3_stmt *stmt = NULL;
  if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) return NULL;
  return stmt;
}

int64_t gene_sqlite_column_i64(sqlite3_stmt *stmt, int64_t column) {
  return sqlite3_column_int64(stmt, (int)column);
}

void gene_sqlite_close(sqlite3 *db) { sqlite3_close(db); }
