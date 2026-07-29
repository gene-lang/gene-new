/* Thin C adapters for the SQLite calls the typed_native subset cannot express
 * directly. This is the "foreign library" the Gene module binds to with
 * ffi/fn; nothing here is generated.
 *
 * One gap makes these necessary, an honest limit of the current subset rather
 * than a workaround for a bug:
 *
 *   Out-parameters. sqlite3_open_v2 and sqlite3_prepare_v2 return their
 *      handle through a sqlite3** / sqlite3_stmt**. Typed-native Gene has no
 *      way to take the address of a local, so acquisition happens here and
 *      Gene receives an already-open pointer.
 *
 * Column-indexed calls used to need an adapter too, because a Gene I64 will
 * not narrow into sqlite3_column_int64's `int`. Declaring the index as `I32`
 * makes that signature expressible directly, so sqlite3_column_int64 is now
 * bound with no wrapper at all.
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

void gene_sqlite_close(sqlite3 *db) { sqlite3_close(db); }
