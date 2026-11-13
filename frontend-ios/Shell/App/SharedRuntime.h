// New shell games use FS. Existing FH games keep their ShellGlue.h ABI and embedded host.
#pragma once
#include <stdint.h>
#define DM_SHARED_RUNTIME_ABI 1u
#define DM_SHARED_PROFILE_ABI 1u
// The pointed-to strings and this descriptor live for the lifetime of their image.
// Validate all fields before entering host code. runtime_version identifies the
// exact runtime sources, not just the public function signatures.
typedef struct dm_shared_descriptor {
    uint32_t abi;
    uint32_t profile_abi;
    const char *runtime_version;
    const char *shader_chain;
} dm_shared_descriptor;
