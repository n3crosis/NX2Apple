#ifndef NX_GAME_TUNNEL_H
#define NX_GAME_TUNNEL_H
#include <stddef.h>
#include <stdint.h>

typedef struct NxGameTunnel NxGameTunnel;
// Starts provisioning asynchronously. Call only after the user enables remote sharing.
NxGameTunnel *nx_game_tunnel_start(uint16_t loopback_port);
// 0: connecting, 1: ready (URL), -1: failed, -2: buffer too small.
// The buffer receives a NUL-terminated string. No credentials are returned.
int32_t nx_game_tunnel_poll(const NxGameTunnel *, char *text, size_t capacity);
// Consumes the handle. Call on a worker, serialized with poll. NULL is allowed.
void nx_game_tunnel_stop(NxGameTunnel *);
#endif
