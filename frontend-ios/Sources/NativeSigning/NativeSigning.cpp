#include "NativeSigning.h"
#include <cstdio>
#ifdef NX_SHELL_ENABLE_ZSIGN
#include "common.h"
#include "macho.h"
#include "openssl.h"
#include <mutex>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
static std::mutex signingMutex;
static uint32_t u32(const unsigned char *p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
static uint64_t u64(const unsigned char *p) { return u32(p) | uint64_t(u32(p + 4)) << 32; }
static bool bounded(uint64_t offset, uint64_t size, uint64_t total) {
    return offset <= total && size <= total - offset;
}
static bool library(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return false;
    struct Handle { int fd; ~Handle() { close(fd); } } handle{fd};
    unsigned char h[32] = {};
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size < 32 ||
        st.st_size > 1024LL * 1024 * 1024 || pread(fd, h, sizeof h, 0) != sizeof h) return false;
    if (u32(h) != 0xfeedfacf || u32(h + 4) != 0x0100000c ||
        (u32(h + 12) != 6 && u32(h + 12) != 8)) return false;
    uint32_t count = u32(h + 16), bytes = u32(h + 20);
    if (bytes > 16 * 1024 * 1024 || count > bytes / 8 || !bounded(32, bytes, st.st_size)) return false;
    std::vector<unsigned char> commands(bytes);
    if (pread(fd, commands.data(), bytes, 32) != bytes) return false;
    size_t offset = 0;
    bool signature = false, text = false, linkedit = false;
    for (uint32_t i = 0; i < count; ++i) {
        if (!bounded(offset, 8, bytes)) return false;
        const auto *p = commands.data() + offset;
        uint32_t cmd = u32(p), length = u32(p + 4);
        if (length < 8 || length % 8 || !bounded(offset, length, bytes)) return false;
        if (cmd == 1) return false; // No 32-bit segments in the arm64 ABI.
        if (cmd == 0x19) {
            if (length < 72 ||
                !bounded(u64(p + 40), u64(p + 48), st.st_size)) return false;
            uint32_t sections = u32(p + 64);
            if (sections > (length - 72) / 80) return false;
            if (!strncmp((const char *)p + 8, "__TEXT", 16)) text = true;
            if (!strncmp((const char *)p + 8, "__LINKEDIT", 16)) linkedit = true;
            for (uint32_t j = 0; j < sections; ++j) {
                const auto *section = p + 72 + j * 80;
                if (!strncmp((const char *)section, "__info_plist", 16) &&
                    (u64(section + 40) > 1024 * 1024 ||
                     !bounded(u32(section + 48), u64(section + 40), st.st_size))) return false;
                uint32_t type = u32(section + 64) & 0xff;
                if (type != 1 && type != 12 && type != 18 &&
                    !bounded(u32(section + 48), u64(section + 40), st.st_size)) return false;
            }
        } else if (cmd == 0x21 || cmd == 0x2c) {
            if (length < 24 || u32(p + 16)) return false;
        } else if (cmd == 0x1d) {
            if (signature || length != 16) return false;
            uint32_t start = u32(p + 8), size = u32(p + 12);
            // Reserved signature space is required. Do not resize arbitrary images.
            if (start < 32 + bytes || size < 12 || start % 16 ||
                !bounded(start, size, st.st_size) || uint64_t(start) + size != uint64_t(st.st_size)) return false;
            signature = true;
        }
        offset += length;
    }
    return offset == bytes && signature && text && linkedit;
}
#endif
static int fail(char *error, size_t capacity, const char *message) {
    if (error && capacity) std::snprintf(error, capacity, "%s", message);
    return -1;
}
int nx_shell_signer_available(void) {
#ifdef NX_SHELL_ENABLE_ZSIGN
    return 1;
#else
    return 0;
#endif
}
int nx_shell_check_identity(const char *pkcs12, const char *password, const char *profile,
    const char *team, char *error, size_t capacity) {
#ifdef NX_SHELL_ENABLE_ZSIGN
    std::lock_guard<std::mutex> guard(signingMutex);
    if (!pkcs12 || !password || !profile || !team || !*team || strlen(team) > 128)
        return fail(error, capacity, "invalid signing identity request");
    ZLog::SetLogLever(ZLog::E_NONE);
    try {
        for (const char *credential : {pkcs12, profile}) {
            struct stat st;
            if (lstat(credential, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 16 * 1024 * 1024)
                return fail(error, capacity, "invalid local signing identity file");
        }
        ZSignAsset asset;
        if (!asset.Init("", pkcs12, profile, "", password, false, true, true))
            return fail(error, capacity, "signing identity unavailable or invalid");
        if (asset.m_strTeamId != team)
            return fail(error, capacity, "signing identity does not match host team");
        return 0;
    } catch (...) { return fail(error, capacity, "signing identity unavailable or invalid"); }
#else
    (void)pkcs12; (void)password; (void)profile; (void)team;
    return fail(error, capacity, "embedded zsign/OpenSSL backend is not included in this build");
#endif
}
int nx_shell_sign_library(const char *path, const char *pkcs12, const char *password,
    const char *profile, const char *team, const char *identifier, char *error, size_t capacity) {
#ifdef NX_SHELL_ENABLE_ZSIGN
    std::lock_guard<std::mutex> guard(signingMutex); // zsign has process-global state.
    if (!path || !pkcs12 || !password || !profile || !team || !*team || !identifier || !*identifier)
        return fail(error, capacity, "invalid signing request");
    // Never log credential paths, profile contents, or password via zsign.
    ZLog::SetLogLever(ZLog::E_NONE);
    try {
        if (!library(path)) return fail(error, capacity, "expected staged thin arm64 library with signature reservation");
        for (const char *credential : {pkcs12, profile}) {
            struct stat st;
            if (lstat(credential, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 16 * 1024 * 1024)
                return fail(error, capacity, "invalid local signing identity file");
        }
        if (strlen(team) > 128 || strlen(identifier) > 255)
            return fail(error, capacity, "invalid signing identifier");
        ZSignAsset asset;
        if (!asset.Init("", pkcs12, profile, "", password, false, true, true))
            return fail(error, capacity, "signing identity unavailable or invalid");
        if (asset.m_strTeamId != team)
            return fail(error, capacity, "signing identity does not match host team");
        // A framework library must not inherit app entitlements from the profile.
        asset.m_strEntitleData.clear();
        ZMachO image;
        if (!image.Init(path)) return fail(error, capacity, "cannot open staged native image");
        bool signedImage = image.Sign(&asset, true, identifier, "", "", "");
        if (!signedImage) image.Free(); // Sign flushes/unmaps on success.
        if (!signedImage) return fail(error, capacity, "native signing failed");
        return 0; // Caller must still require kernel validation, never trust this alone.
    } catch (...) {
        return fail(error, capacity, "native signing failed");
    }
#else
    (void)path; (void)pkcs12; (void)password; (void)profile; (void)team; (void)identifier;
    return fail(error, capacity, "embedded zsign/OpenSSL backend is not included in this build");
#endif
}
