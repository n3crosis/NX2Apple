// Strict shared-runtime compatibility gates. FH uses its existing glue version check.
#ifndef DM_SHARED_RUNTIME_CHECKS_H
#define DM_SHARED_RUNTIME_CHECKS_H
#include "SharedRuntime.h"
#include <string.h>
static inline int shared_descriptor_valid(const dm_shared_descriptor *d) {
    return d && d->abi == DM_SHARED_RUNTIME_ABI && d->profile_abi == DM_SHARED_PROFILE_ABI &&
        d->runtime_version && d->runtime_version[0] && d->shader_chain && d->shader_chain[0];
}
static inline int shared_descriptors_match(const dm_shared_descriptor *game, const dm_shared_descriptor *runtime) {
    return shared_descriptor_valid(game) && shared_descriptor_valid(runtime) &&
        !strcmp(game->runtime_version, runtime->runtime_version) &&
        !strcmp(game->shader_chain, runtime->shader_chain);
}
#endif
