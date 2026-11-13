#ifndef NX_PAYLOAD_SIGNING_H
#define NX_PAYLOAD_SIGNING_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Mutates one private staged thin arm64 library. No subprocess, network or JIT.
// Credential paths/password are caller-owned and are never persisted by this API.
int nx_shell_sign_library(const char *path, const char *pkcs12_path,
    const char *password, const char *profile_path, const char *expected_team,
    const char *identifier, char *error, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
