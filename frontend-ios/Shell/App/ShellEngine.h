// Route C shell: the engine side of Play (ShellMain.m), called by ShellApp.swift's EngineGameLauncher. See ShellMain.m.
#pragma once
#include <stdint.h>

#define DM_SHELL_GLUE_VERSION 1

// Sets the log, the environment (keys[i]=values[i], overwriting) and the working folder, dlopens the game's framework, hands its mach
// header to the loader and starts the host's early loading with argv. NULL on success, else a message for the player (the log has
// the details). At most one game is active until return-to-library completes.
const char *dm_shell_start_game(const char *const *keys, const char *const *values, int n, const char *const *argv, int argc,
                                const char *executable, const char *marker, const char *log_path, const char *cwd,
                                const char *game_id);
// After a successful start: the window shows front_ios.m's game view, which starts the game.
void dm_shell_present_game(void);
// Title ID of the currently running game, or NULL when back in the library.
const char *dm_shell_active_game_id(void);
// Requests the running game framework to quit gracefully back to the library.
void dm_shell_request_stop_game(void);

// Read and acknowledge on the main thread, while the host reserves launch/signing.
typedef struct {
    uint64_t device, inode;
    int64_t size;
    int64_t modification_seconds, modification_nanoseconds;
    int64_t change_seconds, change_nanoseconds;
} DmShellFileIdentity;

int dm_shell_is_game_running(void);
// Only for a kernel-accepted, verified signature-only atomic replacement.
void dm_shell_did_resign_game(const char *game_id, const char *executable,
                             int64_t previous_modification_seconds, DmShellFileIdentity expected);
