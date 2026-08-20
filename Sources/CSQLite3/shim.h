// System-library shim for SQLite3 so that Swift can import SQLite3 headers.
// This module must be named 'SQLite3' (not 'CSQLite3') to match the import
// statements throughout the codebase. The directory name is free; the module
// name in the map is what the Swift compiler looks up and must be SQLite3.

#include <sqlite3.h>
