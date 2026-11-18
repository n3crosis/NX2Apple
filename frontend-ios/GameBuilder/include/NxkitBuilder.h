#ifndef NXKIT_BUILDER_H
#define NXKIT_BUILDER_H
#include <stddef.h>
// Synchronous; call off the UI thread. UTF-8 JSON paths must remain accessible
// until completion. Creates a new unsigned NXB; never overwrites an output.
// Returns 0 on success, 1 on failure and a bounded, NUL-terminated UTF-8 error.
// Reports stage transitions on the calling thread. stage is valid only during
// the callback; context stays caller-owned. Neither pointer is retained.
// Return 0 to cancel before this stage, nonzero to continue. Cancellation waits
// for the current stage to finish; native scratch is released before returning.
typedef int (*nxkit_build_progress)(const char *stage, void *context);
int nxkit_prepare_nxb(const char *request_json, char *error, size_t capacity,
                      nxkit_build_progress progress, void *context);
#endif
