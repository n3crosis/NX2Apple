#ifndef NXKIT_BUILDER_H
#define NXKIT_BUILDER_H
#include <stddef.h>
// Synchronous; call off the UI thread. UTF-8 JSON paths must remain accessible
// until completion. Creates a new unsigned NXB; never overwrites an output.
// Returns 0 on success, 1 on failure and a bounded, NUL-terminated UTF-8 error.
int nxkit_prepare_nxb(const char *request_json, char *error, size_t capacity);
#endif
