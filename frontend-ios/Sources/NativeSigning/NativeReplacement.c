#include "NativeReplacement.h"
#include <stdio.h>
#include <fcntl.h>

int nx_shell_exchange_directories(const char *installed, const char *staged) {
    // Both directories reside on the app's data volume. No delete/rename
    // fallback: a failed exchange must leave the installed framework untouched.
    return renameatx_np(AT_FDCWD, installed, AT_FDCWD, staged, RENAME_SWAP);
}
