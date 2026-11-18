#ifndef NXKIT_GAME_RUNTIME_H
#define NXKIT_GAME_RUNTIME_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* prepare runs off the main thread. Other calls run on the main thread. Error buffers have capacity writable bytes.
 * Functions return 0 on success, 1 on failure and write a NUL-terminated error.
 * root is a UTF-8 path containing game.json and the producer's run files.
 * layer is a live CAMetalLayer, retained by the runtime. Validate the native
 * library's signature before start. No signing occurs in this API.
 * One launch attempt per process. Failure may leave initialized global state.
 * Detach stops presentation, NOT guest threads. It does not permit another
 * launch. No call here exits the application. */
/* writable_root is a per-game device-local folder outside root. */
int32_t nxkit_ios_prepare(const char *root, const char *writable_root, char *error, size_t capacity);
int32_t nxkit_ios_attach(void *layer, uint32_t width, uint32_t height,
                        uint32_t max_fps, int32_t adaptive, char *error, size_t capacity);
/* Nintendo button bits 0..15, axes -1..1, positive y up. */
int32_t nxkit_ios_set_pad(uint64_t buttons, float lx, float ly, float rx, float ry,
                         char *error, size_t capacity);
int32_t nxkit_ios_resize(uint32_t width, uint32_t height, char *error, size_t capacity);
int32_t nxkit_ios_set_active(int32_t active, char *error, size_t capacity);
/* Stop output before deactivating AVAudioSession; resume only after activating it. */
int32_t nxkit_ios_set_audio_paused(int32_t paused, char *error, size_t capacity);
typedef struct { uint32_t id; float x; float y; } NXKitTouch;
/* Up to 16 points, normalized to the game view. NULL is valid only with count=0. */
int32_t nxkit_ios_set_touches(const NXKitTouch *points, size_t count, char *error, size_t capacity);
int32_t nxkit_ios_detach(char *error, size_t capacity);
/* 0: detached, 1: attached, 2: guest requested stop, -1: wrong thread.
 * A stopped guest does not imply that all its threads have exited. */
int32_t nxkit_ios_state(void);
#ifdef __cplusplus
}
#endif
#endif
