#pragma once
#include <stddef.h>

// Ask the kernel to attach the file's own signature and enforce this process's
// library validation policy. This never disables or patches code signing.
#ifdef __cplusplus
extern "C" {
#endif
int nx_shell_validate(const char *path, char *error, size_t capacity);

#ifdef __cplusplus
}
#endif
