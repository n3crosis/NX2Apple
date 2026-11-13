// Route C shell (docs/launcher-c-plan.md M2, LNPANDY/NX2Apple#451): the app that hosts several games' frameworks. It starts on the
// library (frontend-ios's ShellHost views, ShellApp.swift) instead of booting a game at launch as dm/ios/Sources/main.m does, and
// when the player presses Play, dm_shell_start_game() sets the log and the environment (EngineLaunchPlan in ShellHost computes it),
// dlopens the chosen game's DmGame<title ID>.framework (which links its own dm/host, front_ios.m and shaders), and calls its
// dm_glue_start_game() entry point (ShellGlue.h, framework/ShellGlue.m). dm_shell_present_game() then hands the window to the
// framework's dm_glue_present_game(), which shows front_ios.m's game view and starts dm_main on the big-stack thread.
// When the player quits from the in-game prompt, dm_shell_return_to_library() restores the framework's writable data segments and returns the window to the library.
#import <UIKit/UIKit.h>
#include <TargetConditionals.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/fat.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "SegSnap.h"
#include "ShellEngine.h"
#include "ShellGlue.h"
#include "SharedRuntimeChecks.h"
#import "DmShell-Swift.h"

_Static_assert(DM_SHELL_GLUE_VERSION == DM_GLUE_VERSION, "DM_SHELL_GLUE_VERSION must match DM_GLUE_VERSION");

extern char **environ;

typedef struct {
    const void *fbase;
    char marker[64];
    char exe_path[1024];
    time_t mtime;
    DmSegSnap seg[2];
} DmFwSnap;

static dm_glue_present_fn g_present;
static dm_glue_focus_fn g_focus;
static UIViewController *g_library_vc;
static char g_active_exe[1024];
static const void *g_active_fbase;
static const void *g_active_runtime_base;
static DmFwSnap g_fw_snaps[64];
static int g_nfw_snaps;
static int g_boot_ok;

static NSString *documents(void) { return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]; }

static void clear_game_env(void) {
    if (!environ) return;
    char names[256][128];
    int count = 0;
    for (char **ep = environ; *ep && count < 256; ep++) {
        const char *kv = *ep;
        if (strncmp(kv, "DM_", 3) != 0) continue;
        const char *eq = strchr(kv, '=');
        if (!eq) continue;
        size_t len = (size_t)(eq - kv);
        if (len == 0 || len >= sizeof(names[0])) continue;
        if ((len == strlen("DM_HUD_PER_LAYER") && !strncmp(kv, "DM_HUD_PER_LAYER", len)) ||
            (len == strlen("DM_SHELL_PLAY") && !strncmp(kv, "DM_SHELL_PLAY", len))) {
            continue;
        }
        memcpy(names[count], kv, len);
        names[count][len] = '\0';
        count++;
    }
    for (int i = 0; i < count; i++) unsetenv(names[i]);
}

static int save_framework_data(const void *fbase, const char *marker, const char *executable, time_t mtime) {
    if (!fbase || fbase == (const void *)&_mh_execute_header) return 0;
    for (int i = 0; i < g_nfw_snaps; i++) if (g_fw_snaps[i].fbase == fbase) return 1;
    if (g_nfw_snaps >= 64) return 0;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)fbase;
    DmFwSnap *s = &g_fw_snaps[g_nfw_snaps];
    memset(s, 0, sizeof *s);
    s->fbase = fbase;
    if (marker) strlcpy(s->marker, marker, sizeof s->marker);
    if (executable) strlcpy(s->exe_path, executable, sizeof s->exe_path);
    s->mtime = mtime;
    dm_seg_snap_save(mh, "__DATA", &s->seg[0]);
    dm_seg_snap_save(mh, "__DATA_DIRTY", &s->seg[1]);
    if (!s->seg[0].complete || !s->seg[1].complete) {
        dm_seg_snap_free(&s->seg[0]); dm_seg_snap_free(&s->seg[1]);
        memset(s, 0, sizeof *s);
        return 0;
    }
    g_nfw_snaps++;
    fprintf(stderr, "shell: saved framework state for %p (__data=%#zx, __common=%#zx, __bss=%#zx with %zu initial non-zero words)\n",
            fbase, s->seg[0].data_sz + s->seg[1].data_sz, s->seg[0].common_sz + s->seg[1].common_sz,
            s->seg[0].bss_sz + s->seg[1].bss_sz, s->seg[0].bss_nnz + s->seg[1].bss_nnz);
    return 1;
}

static void restore_framework_data(const void *fbase) {
    if (!fbase) return;
    DmFwSnap *s = NULL;
    for (int i = 0; i < g_nfw_snaps; i++) if (g_fw_snaps[i].fbase == fbase) { s = &g_fw_snaps[i]; break; }
    if (!s) return;
    dm_seg_snap_restore(&s->seg[0]);
    dm_seg_snap_restore(&s->seg[1]);
    fprintf(stderr, "shell: restored framework state for %p\n", fbase);
}

__attribute__((used, visibility("default")))
void dm_shell_return_to_library(void) {
    dispatch_block_t work = ^{
        char finished_exe[1024];
        strlcpy(finished_exe, g_active_exe, sizeof finished_exe);
        const void *fbase = g_active_fbase;
        const void *runtime_base = g_active_runtime_base;
        g_active_fbase = NULL;
        g_active_runtime_base = NULL;
        g_active_exe[0] = '\0';
        g_focus = NULL;
        g_present = NULL;
        g_boot_ok = 0;
        // The runtime invokes this only after all guest/GPU/audio/host work has stopped.
        // Restore host profile caches and game sections separately; neither is the shell.
        if (runtime_base) restore_framework_data(runtime_base);
        if (fbase) restore_framework_data(fbase);
        UIWindow *window = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow || !window) window = w;
        if (window && g_library_vc) {
            window.traitOverrides.preferredContentSizeCategory = UIContentSizeCategoryUnspecified;
            window.rootViewController = g_library_vc;
            [g_library_vc setNeedsUpdateOfSupportedInterfaceOrientations];
            if (@available(iOS 16.0, *)) {
                [window.windowScene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskAllButUpsideDown] errorHandler:nil];
            }
        }
        NSString *slog = [documents() stringByAppendingPathComponent:@"shell-log.txt"];
        fflush(stderr);
        if (freopen(slog.fileSystemRepresentation, "a", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
        fprintf(stderr, "shell: returned to library from %s\n", finished_exe);
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

// One log file per run, the previous one kept beside it (<name>.prev.txt): the shell's own lines go to Documents/shell-log.txt until a
// game starts, the game's (the host's stderr) to Documents/log.txt, the file the per-game app writes and the issue forms ask for.
static void log_to(NSString *log) {
    NSString *prev = [[log stringByDeletingPathExtension] stringByAppendingString:@".prev.txt"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:prev error:nil]; [fm moveItemAtPath:log toPath:prev error:nil];
    fflush(stderr);
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    NSString *fork_patches = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DMForkPatches"];
    fprintf(stderr, "fork patches: %s\n", [fork_patches isKindOfClass:NSString.class] && fork_patches.length ? fork_patches.UTF8String : "none");
}

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
static const char *register_external_signature(const char *executable) {
    NSString *bundlePrefix = [[NSBundle.mainBundle.bundlePath stringByStandardizingPath] stringByAppendingString:@"/"];
    NSString *exeStd = [@(executable) stringByStandardizingPath];
    if ([exeStd hasPrefix:bundlePrefix]) return NULL;

    int fd = open(executable, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return "The game's framework executable could not be opened.";
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(fd);
        return "The game's framework executable is missing or incomplete.";
    }
    uint64_t fsize = (uint64_t)st.st_size;
    uint8_t head[544];
    ssize_t nhead = pread(fd, head, sizeof head < fsize ? sizeof head : (size_t)fsize, 0);
    if (nhead < 32) { close(fd); return "The game's framework executable could not be read."; }

    uint64_t slice_off = 0, slice_sz = fsize;
    uint32_t magic_be = 0;
    memcpy(&magic_be, head, 4);
    magic_be = ntohl(magic_be);
    if (magic_be == FAT_MAGIC || magic_be == FAT_MAGIC_64) {
        uint32_t nfat = 0;
        memcpy(&nfat, head + 4, 4);
        nfat = ntohl(nfat);
        size_t stride = (magic_be == FAT_MAGIC_64) ? 32 : 20;
        if (nfat == 0 || nfat > 16 || (size_t)nhead < 8 + (size_t)nfat * stride) {
            close(fd);
            return "The game's universal framework header is damaged.";
        }
        int found = 0;
        for (uint32_t i = 0; i < nfat; i++) {
            const uint8_t *p = head + 8 + (size_t)i * stride;
            uint32_t cputype = 0;
            memcpy(&cputype, p, 4);
            cputype = ntohl(cputype);
            uint64_t off = 0, sz = 0;
            if (magic_be == FAT_MAGIC_64) {
                uint32_t hi = 0, lo = 0;
                memcpy(&hi, p + 8, 4); memcpy(&lo, p + 12, 4);
                off = ((uint64_t)ntohl(hi) << 32) | ntohl(lo);
                memcpy(&hi, p + 16, 4); memcpy(&lo, p + 20, 4);
                sz = ((uint64_t)ntohl(hi) << 32) | ntohl(lo);
            } else {
                uint32_t o32 = 0, s32 = 0;
                memcpy(&o32, p + 8, 4); memcpy(&s32, p + 12, 4);
                off = ntohl(o32); sz = ntohl(s32);
            }
            if (off <= fsize && sz >= sizeof(struct mach_header_64) && sz <= fsize - off &&
                (cputype == CPU_TYPE_ARM64 || !found)) {
                slice_off = off; slice_sz = sz; found = 1;
                if (cputype == CPU_TYPE_ARM64) break;
            }
        }
        if (!found) { close(fd); return "The game's framework has no usable arm64 slice."; }
    }

    struct mach_header_64 mh;
    if (pread(fd, &mh, sizeof mh, (off_t)slice_off) != (ssize_t)sizeof mh || mh.magic != MH_MAGIC_64 ||
        mh.ncmds > 4096 || mh.sizeofcmds > slice_sz - sizeof mh || mh.sizeofcmds > 4 * 1024 * 1024) {
        close(fd);
        return "The game's framework is not a valid 64-bit Mach-O image.";
    }
    uint8_t *cmds = malloc(mh.sizeofcmds);
    if (!cmds) { close(fd); return "Out of memory checking framework signature."; }
    if (pread(fd, cmds, mh.sizeofcmds, (off_t)(slice_off + sizeof mh)) != (ssize_t)mh.sizeofcmds) {
        free(cmds); close(fd);
        return "The game's Mach-O load commands could not be read.";
    }
    uint32_t sig_off = 0, sig_sz = 0;
    size_t cur = 0;
    for (uint32_t i = 0; i < mh.ncmds && cur + sizeof(struct load_command) <= mh.sizeofcmds; i++) {
        const struct load_command *lc = (const struct load_command *)(cmds + cur);
        if (lc->cmdsize < sizeof(struct load_command) || lc->cmdsize > mh.sizeofcmds - cur) break;
        if (lc->cmd == LC_CODE_SIGNATURE && lc->cmdsize >= sizeof(struct linkedit_data_command)) {
            const struct linkedit_data_command *cs = (const struct linkedit_data_command *)lc;
            sig_off = cs->dataoff;
            sig_sz = cs->datasize;
            break;
        }
        cur += lc->cmdsize;
    }
    free(cmds);
    if (sig_off == 0 || sig_sz < 12 || sig_off > slice_sz || sig_sz > slice_sz - sig_off || sig_sz > 16 * 1024 * 1024) {
        close(fd);
        return "This game's framework in Documents/Frameworks is unsigned. Install the game again from NX2Apple.";
    }
    void *blob = malloc(sig_sz);
    if (!blob) { close(fd); return "Out of memory reading framework signature."; }
    if (pread(fd, blob, sig_sz, (off_t)(slice_off + sig_off)) != (ssize_t)sig_sz) {
        free(blob); close(fd);
        return "The game's code signature could not be read.";
    }
    fsignatures_t fsig;
    memset(&fsig, 0, sizeof fsig);
    fsig.fs_file_start = (off_t)slice_off;
    fsig.fs_blob_start = blob;
    fsig.fs_blob_size = sig_sz;
    int rc = fcntl(fd, F_ADDFILESIGS_RETURN, &fsig);
    int saved_errno = errno;
    free(blob);
    close(fd);
    if (rc < 0 && saved_errno != EEXIST) {
        fprintf(stderr, "[RED] boot: F_ADDFILESIGS_RETURN failed for %s: errno=%d (%s)\n",
                executable, saved_errno, strerror(saved_errno));
        return "iOS refused the code signature of this game's framework. Install the game again from NX2Apple.";
    }
    return NULL;
}
#endif

// Discovery is metadata-only: opening the library must not initialize the runtime.
static NSBundle *shared_runtime_bundle(void) {
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"DmSharedRuntime.framework"];
    return path ? [NSBundle bundleWithPath:path] : nil;
}

int dm_shell_shared_runtime_abi(void) {
    id value = [shared_runtime_bundle() objectForInfoDictionaryKey:@"DMSharedRuntimeABI"];
    return [value isKindOfClass:NSNumber.class] ? [value intValue] : 0;
}

int dm_shell_shared_profile_abi(void) {
    id value = [shared_runtime_bundle() objectForInfoDictionaryKey:@"DMSharedProfileABI"];
    return [value isKindOfClass:NSNumber.class] ? [value intValue] : 0;
}

const char *dm_shell_shared_runtime_version(void) {
    static NSString *version;
    id value = [shared_runtime_bundle() objectForInfoDictionaryKey:@"DMSharedRuntimeVersion"];
    version = [value isKindOfClass:NSString.class] && [value length] ? value : nil;
    return version.UTF8String;
}

static const dm_shared_descriptor *shared_runtime(void **handle, const void **image) {
    NSBundle *bundle = shared_runtime_bundle();
    NSString *path = bundle.executablePath;
    if (!path.length) return NULL;
    void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!h) return NULL;
    const dm_shared_descriptor *d = dlsym(h, "dm_shared_runtime_descriptor");
    Dl_info di;
    if (!d || !dladdr(d, &di) || !di.dli_fbase ||
        di.dli_fbase == (const void *)&_mh_execute_header || !di.dli_fname) return NULL;
    // A dependency must not supply the descriptor or any of the entry points.
    NSString *owner = [@(di.dli_fname) stringByResolvingSymlinksInPath];
    if (![owner isEqualToString:[path stringByResolvingSymlinksInPath]]) return NULL;
    const char *version = dm_shell_shared_runtime_version();
    id chain = [bundle objectForInfoDictionaryKey:@"DMChain"];
    if (!shared_descriptor_valid(d) || d->abi != (uint32_t)dm_shell_shared_runtime_abi() ||
        d->profile_abi != (uint32_t)dm_shell_shared_profile_abi() ||
        !version || strcmp(d->runtime_version, version) ||
        ![chain isKindOfClass:NSString.class] || strcmp(d->shader_chain, [chain UTF8String])) return NULL;
    *handle = h;
    *image = di.dli_fbase;
    return d; // Images remain loaded for process lifetime, as on the legacy FH path.
}

const char *dm_shell_start_game(const char *const *keys, const char *const *values, int n, const char *const *argv, int argc,
                                const char *executable, const char *marker, const char *log_path, const char *cwd) {
    static char err[512];
    if (g_boot_ok) return "A game is already running.";
    if (argc < 2 || !executable || !marker) return "The game's start arguments are incomplete.";
    struct stat exe_st;
    memset(&exe_st, 0, sizeof exe_st);
    if (stat(executable, &exe_st) == 0) {
        for (int i = 0; i < g_nfw_snaps; i++) {
            if (strcmp(g_fw_snaps[i].marker, marker) == 0 &&
                (strcmp(g_fw_snaps[i].exe_path, executable) != 0 || g_fw_snaps[i].mtime != exe_st.st_mtime)) {
                return "This game was updated while the app was open. Close and reopen the app to load the new build.";
            }
        }
    }
    clear_game_env();
    log_to(@(log_path));
    fprintf(stderr, "shell: starting %s (%s)\n", argv[1], executable);
    for (int i = 0; i < n; i++) {
        setenv(keys[i], values[i], 1);
        fprintf(stderr, "boot: %s=%s\n", keys[i], values[i]);   // every one: a report then shows which of the game's settings reached the engine
    }
    if (cwd && *cwd) chdir(cwd);
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    const char *sig_err = register_external_signature(executable);
    if (sig_err) {
        snprintf(err, sizeof err, "%s", sig_err);
        fprintf(stderr, "[RED] boot: %s: %s\n", executable, err);
        return err;
    }
#endif
    // The native boundary independently verifies FS mode and its immutable profile.
    // Legacy frameworks without FS metadata keep the existing FH route.
    NSString *framework = [[@(executable) stringByDeletingLastPathComponent] stringByResolvingSymlinksInPath];
    NSData *manifest_data = [NSData dataWithContentsOfFile:[framework stringByAppendingPathComponent:@"game.manifest.json"]];
    id manifest_json = manifest_data ? [NSJSONSerialization JSONObjectWithData:manifest_data options:0 error:nil] : nil;
    NSDictionary *manifest = [manifest_json isKindOfClass:NSDictionary.class] ? manifest_json : nil;
    BOOL shared = [manifest[@"loader"] isEqual:@"FS"];
    BOOL requested_shared = getenv("DM_SHARED_RUNTIME") && !strcmp(getenv("DM_SHARED_RUNTIME"), "1");
    if (shared != requested_shared) return "The game's runtime mode does not match its manifest.";
    NSDictionary *shared_manifest = nil;
    if (shared) {
        id descriptor = manifest[@"shared_runtime"];
        id profile = manifest[@"profile"];
        if (![descriptor isKindOfClass:NSDictionary.class] || ![profile isKindOfClass:NSString.class] ||
            ![profile length] || [profile isAbsolutePath]) return "The shared runtime manifest is incomplete.";
        shared_manifest = descriptor;
        NSString *profile_path = [[framework stringByAppendingPathComponent:profile] stringByResolvingSymlinksInPath];
        BOOL directory = NO;
        if (![profile_path hasPrefix:[framework stringByAppendingString:@"/"]] ||
            ![NSFileManager.defaultManager fileExistsAtPath:profile_path isDirectory:&directory] || directory ||
            ![NSFileManager.defaultManager isReadableFileAtPath:profile_path])
            return "The shared runtime game profile is missing or outside its framework.";
        if (setenv("DM_PROFILE", profile_path.fileSystemRepresentation, 1)) return "Could not select the game's runtime profile.";
    }
    // dlopen + dlsym + dladdr verify the framework's image and find its own host's entry points (ShellGlue.h, framework/ShellGlue.m),
    // after the environment is set and before the framework's host starts loading.
    void *h = dlopen(executable, RTLD_LAZY | RTLD_LOCAL);
    if (!h) {
        snprintf(err, sizeof err, "The game's code could not be loaded: %s", dlerror() ?: "no reason given");
        fprintf(stderr, "[RED] boot: dlopen %s failed: %s\n", executable, err);
        return err;
    }
    dlerror();
    void *sym = dlsym(h, marker);
    Dl_info info;
    if (!sym || !dladdr(sym, &info) || !info.dli_fbase) {
        snprintf(err, sizeof err, "The game's code is damaged (no %s symbol). Install the game again.", marker);
        fprintf(stderr, "[RED] boot: %s: %s\n", executable, err);
        return err;
    }
    void *host = h;
    const void *runtime_base = NULL;
    if (shared) {
        const dm_shared_descriptor *game = dlsym(h, "dm_shared_game_descriptor");
        Dl_info game_desc_info;
        const dm_shared_descriptor *runtime = shared_runtime(&host, &runtime_base);
        if (!game || !dladdr(game, &game_desc_info) || game_desc_info.dli_fbase != info.dli_fbase ||
            !runtime || runtime_base == info.dli_fbase || !shared_descriptors_match(game, runtime))
            return "This game does not match the bundled shared runtime. Rebuild the game and shell together.";
        id abi = shared_manifest[@"abi"], profile_abi = shared_manifest[@"profile_abi"];
        id version = shared_manifest[@"runtime_version"], chain = manifest[@"chain"];
        if (![abi isKindOfClass:NSNumber.class] || [abi unsignedIntValue] != game->abi ||
            ![profile_abi isKindOfClass:NSNumber.class] || [profile_abi unsignedIntValue] != game->profile_abi ||
            ![version isKindOfClass:NSString.class] || strcmp([version UTF8String], game->runtime_version) ||
            ![chain isKindOfClass:NSString.class] || strcmp([chain UTF8String], game->shader_chain))
            return "The shared runtime manifest does not match the game's compiled descriptor.";
    }
    const int *ver = dlsym(host, "dm_glue_version");
    dm_glue_start_fn start = (dm_glue_start_fn)dlsym(host, "dm_glue_start_game");
    dm_glue_present_fn present = (dm_glue_present_fn)dlsym(host, "dm_glue_present_game");
    dm_glue_focus_fn focus = (dm_glue_focus_fn)dlsym(host, "dm_glue_focus_event");
    if (!ver || *ver != DM_GLUE_VERSION || !start || !present || !focus) {
        snprintf(err, sizeof err, "This game's framework was built without its host (glue version %d, expected %d). Rebuild the game in the launcher.",
                 ver ? *ver : 0, DM_GLUE_VERSION);
        fprintf(stderr, "[RED] boot: %s: %s\n", executable, err);
        return err;
    }
    fprintf(stderr, "boot: game framework %s (handle %p, image base %p, glue v%d)\n", executable, h, info.dli_fbase, *ver);
    if (runtime_base) {
        Dl_info si, pi, fi, vi;
        if (!dladdr((const void *)start, &si) || !dladdr((const void *)present, &pi) ||
            !dladdr((const void *)focus, &fi) || !dladdr(ver, &vi) ||
            si.dli_fbase != runtime_base || pi.dli_fbase != runtime_base ||
            fi.dli_fbase != runtime_base || vi.dli_fbase != runtime_base)
            return "The shared runtime entry points belong to a different image.";
    }
    if (!save_framework_data(info.dli_fbase, marker, executable, exe_st.st_mtime) || (runtime_base && !save_framework_data(runtime_base, NULL, NULL, 0)))
        return "Could not preserve runtime state for a safe game switch.";
    const char *why = start(argv, argc, info.dli_fbase);
    if (why) {
        snprintf(err, sizeof err, "%s", why);
        fprintf(stderr, "[RED] boot: %s: %s\n", executable, err);
        if (runtime_base) restore_framework_data(runtime_base);
        restore_framework_data(info.dli_fbase);
        return err;
    }
    strlcpy(g_active_exe, executable, sizeof g_active_exe);
    g_active_fbase = info.dli_fbase;
    g_active_runtime_base = runtime_base;
    g_present = present;
    g_focus = focus;
    g_boot_ok = 1;
    return NULL;
}

void dm_shell_present_game(void) {
    UIWindow *window = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow || !window) window = w;
    if (!window || !g_present) { fprintf(stderr, "[RED] shell: no window for the game view\n"); return; }
    g_present((__bridge void *)window);
}

@interface App : UIResponder <UIApplicationDelegate>
@end
// Browsing may be portrait; phone gameplay stays landscape. UIKit manages unrestricted rotation on the Duo inner display.
static UIInterfaceOrientationMask shell_orientations(UITraitCollection *traits) {
    if (traits.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return UIInterfaceOrientationMaskAll;
    return g_boot_ok ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskAllButUpsideDown;
}
@implementation App
- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    return shell_orientations(window.traitCollection);   // iOS 26
}
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindowScene:(UIWindowScene *)windowScene {
    return shell_orientations(windowScene.traitCollection);   // iOS 27 and later
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    g_library_vc = [ShellLibrary makeController];
    self.window.rootViewController = g_library_vc;
    [self.window makeKeyAndVisible];
}
// Forwarded to the running game framework's front_ios.m once a game has started
- (void)sceneWillResignActive:(UIScene *)s { (void)s; if (g_focus) g_focus(0); }
- (void)sceneDidEnterBackground:(UIScene *)s { (void)s; if (g_focus) g_focus(1); }
- (void)sceneWillEnterForeground:(UIScene *)s { (void)s; if (g_focus) g_focus(2); }
- (void)sceneDidBecomeActive:(UIScene *)s { (void)s; if (g_focus) g_focus(3); }
@end

// The performance HUD (the per-game setting DM_METAL_HUD) needs MTL_HUD_ENABLED in the environment before Metal starts in this
// process, and the library's views start it long before Play: set at Play it comes too late and the HUD stays off. So the shell turns
// Metal's HUD on for every start, here before UIApplicationMain, and the game's own setting decides at Play: front_ios.m sets the game
// layer's developerHUDProperties mode to default, or with DM_HUD_PER_LAYER to disabled. A change of the setting in the library applies
// at the next Play, as every other setting does (verified on an iPhone 2026-10-30: on and off in one start each, no HUD over the
// library). MTL_HUD_HIDE_METALFX_METRICS stays unset, so the HUD shows MetalFX's rows (input and output size) while the Upscaling
// setting MetalFX scales the picture.
static void metal_hud_per_layer(void) {
    if (getenv("MTL_HUD_ENABLED")) { fprintf(stderr, "shell: MTL_HUD_ENABLED given at launch, the HUD follows it\n"); return; }   // Xcode, devicectl: it wins
    setenv("MTL_HUD_ENABLED", "1", 1);
    setenv("DM_HUD_PER_LAYER", "1", 1);
    fprintf(stderr, "shell: Metal's HUD is ready, each game's Performance HUD setting turns it on at Play\n");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        log_to([documents() stringByAppendingPathComponent:@"shell-log.txt"]);
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        fprintf(stderr, "shell: %s %s, commit %s, shader chain %s, iOS %s\n", [info[@"CFBundleIdentifier"] UTF8String], [info[@"CFBundleShortVersionString"] UTF8String] ?: "?",
                [info[@"DMCommit"] UTF8String] ?: "not recorded", [info[@"DMChain"] UTF8String] ?: "?", UIDevice.currentDevice.systemVersion.UTF8String);
        // Free space where the game data goes: the Mac launcher reads this line before it copies a game's data (many GB)
        NSNumber *avail = [[NSURL fileURLWithPath:documents()] resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:nil][NSURLVolumeAvailableCapacityForImportantUsageKey];
        fprintf(stderr, "shell: free space %lld bytes\n", avail ? avail.longLongValue : -1LL);
        for (NSString *fw in [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSBundle.mainBundle.privateFrameworksPath error:nil])
            fprintf(stderr, "shell: framework %s\n", fw.UTF8String);
        NSString *hotPath = [documents() stringByAppendingPathComponent:@"Frameworks"];
        for (NSString *fw in [NSFileManager.defaultManager contentsOfDirectoryAtPath:hotPath error:nil])
            if ([fw hasSuffix:@".framework"]) fprintf(stderr, "shell: hot-framework %s\n", fw.UTF8String);
        metal_hud_per_layer();
    }
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
