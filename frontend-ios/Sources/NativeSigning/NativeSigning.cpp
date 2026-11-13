#include "NativeSigning.h"
#include <ZSignLibrary.h>

// The pinned Swift package supplies the backend in every supported build.
int nx_shell_signer_available(void) { return 1; }

int nx_shell_check_identity(const char *pkcs12, const char *password,
    const char *profile, const char *team, char *error, size_t capacity) {
    return zsign_check_identity(pkcs12, password, profile, team, error, capacity);
}

int nx_shell_sign_library(const char *path, const char *pkcs12, const char *password,
    const char *profile, const char *team, const char *identifier, char *error, size_t capacity) {
    return zsign_sign_library(path, pkcs12, password, profile, team, identifier, error, capacity);
}
