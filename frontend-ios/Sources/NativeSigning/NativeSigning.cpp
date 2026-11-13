#include "NativeSigning.h"
#include <ZSignLibrary.h>

int nx_shell_sign_library(const char *path, const char *pkcs12, const char *password,
    const char *profile, const char *team, const char *identifier, char *error, size_t capacity) {
    return zsign_sign_library(path, pkcs12, password, profile, team, identifier, error, capacity);
}
