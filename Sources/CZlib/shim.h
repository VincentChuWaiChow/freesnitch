// System-library shim for zlib so that Swift can import zlib headers.
// This module map pattern is reusable for other system C libraries
// that lack built-in Swift modules (e.g., SQLite3 in later phases).

#include <zlib.h>
