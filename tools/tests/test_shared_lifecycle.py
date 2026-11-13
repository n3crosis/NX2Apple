#!/usr/bin/env python3
"""Portable reset/ABI unit tests. These do not replace an Apple A -> B -> A gameplay test."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

IOS = Path(__file__).resolve().parents[2] / 'frontend-ios/Shell'


class SharedLifecycleTests(unittest.TestCase):
    def test_snapshot_and_compatibility(self):
        cc = os.environ.get('CC', 'cc')
        if not shutil.which(cc):
            self.skipTest('C compiler unavailable')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'mach-o').mkdir()
            (root / 'mach-o/loader.h').write_text('#pragma once\nstruct mach_header_64 { int unused; };\n')
            (root / 'mach-o/getsect.h').write_text('''#pragma once
#include <stdint.h>
#include "loader.h"
static inline uint8_t *getsectiondata(const struct mach_header_64 *h, const char *s, const char *n, unsigned long *z) {
    (void)h; (void)s; (void)n; *z = 0; return 0;
}
''')
            # Exercise the production ABI and snapshot helpers with portable Mach-O discovery stubs.
            source = root / 'test.c'
            source.write_text(r'''
#define _DEFAULT_SOURCE 1
#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
static int fail_malloc, fail_realloc;
static void *test_malloc(size_t n) { return fail_malloc ? NULL : malloc(n); }
static void *test_realloc(void *p, size_t n) { return fail_realloc ? NULL : realloc(p, n); }
// Reading a small, fully mapped test span does not require Darwin's page residency bits.
static int test_mincore(const void *p, size_t n, void *v) { (void)p; (void)n; (void)v; return -1; }
#include <sys/mman.h>
#define malloc test_malloc
#define realloc test_realloc
#define mincore test_mincore
#ifndef MINCORE_INCORE
#define MINCORE_INCORE 1
#endif
#ifndef MINCORE_PAGED_OUT
#define MINCORE_PAGED_OUT 2
#endif
#include "SegSnap.h"
#undef malloc
#undef realloc
#undef mincore
#include "SharedRuntimeChecks.h"

int main(void) {
    dm_shared_descriptor runtime = {DM_SHARED_RUNTIME_ABI, DM_SHARED_PROFILE_ABI, "engine-and-patches-a", "chain-a"};
    dm_shared_descriptor game = runtime;
    assert(shared_descriptors_match(&game, &runtime));
    assert(!shared_descriptors_match(NULL, &runtime));
    game.abi++; assert(!shared_descriptors_match(&game, &runtime)); game = runtime;
    game.profile_abi++; assert(!shared_descriptors_match(&game, &runtime)); game = runtime;
    game.runtime_version = "engine-and-patches-b"; assert(!shared_descriptors_match(&game, &runtime)); game = runtime;
    game.shader_chain = "chain-b"; assert(!shared_descriptors_match(&game, &runtime)); game = runtime;
    game.runtime_version = NULL; assert(!shared_descriptors_match(&game, &runtime)); game = runtime;
    game.shader_chain = ""; assert(!shared_descriptors_match(&game, &runtime));

    // Each image has independent initialized/common/BSS state. Host BSS stands for profile caches.
    uint8_t host_data[16] = {4}, host_common[16] = {5}, host_bss[40] = {6};
    uint8_t a_data[16] = {10}, a_bss[40] = {11};
    uint8_t b_data[16] = {20}, b_bss[40] = {21};
    int shell_library_state = 77; // Shell state is never part of either snapshot.
    DmSegSnap host, a, b;
    dm_seg_snap_save_raw(&host, host_data, sizeof host_data, host_common, sizeof host_common, host_bss, sizeof host_bss);
    dm_seg_snap_save_raw(&a, a_data, sizeof a_data, NULL, 0, a_bss, sizeof a_bss);
    dm_seg_snap_save_raw(&b, b_data, sizeof b_data, NULL, 0, b_bss, sizeof b_bss);
    assert(host.complete && a.complete && b.complete);
    for (int launch = 0; launch < 3; launch++) {
        DmSegSnap *active = launch == 1 ? &b : &a;
        uint8_t expected = launch == 1 ? 20 : 10;
        assert(host_data[0] == 4 && host_common[0] == 5 && host_bss[0] == 6);
        assert(active->data_ptr[0] == expected);
        memset(host_data, 90 + launch, sizeof host_data);
        memset(host_common, 90 + launch, sizeof host_common);
        memset(host_bss, 90 + launch, sizeof host_bss);
        memset(active->data_ptr, 90 + launch, active->data_sz);
        memset(active->bss_ptr, 90 + launch, active->bss_sz);
        dm_seg_snap_restore(&host);
        dm_seg_snap_restore(active);
        assert(shell_library_state == 77);
    }
    dm_seg_snap_free(&host); dm_seg_snap_free(&a); dm_seg_snap_free(&b);

    // Allocation failure cannot silently register a corrupt baseline or restore partial data.
    DmSegSnap failed;
    fail_malloc = 1;
    dm_seg_snap_save_raw(&failed, a_data, sizeof a_data, NULL, 0, NULL, 0);
    assert(!failed.complete);
    a_data[0] = 99; dm_seg_snap_restore(&failed); assert(a_data[0] == 99);
    dm_seg_snap_free(&failed); fail_malloc = 0;
    fail_realloc = 1;
    dm_seg_snap_save_raw(&failed, NULL, 0, NULL, 0, a_bss, sizeof a_bss);
    assert(!failed.complete); dm_seg_snap_free(&failed); fail_realloc = 0;
    dm_seg_snap_save_raw(&failed, NULL, 1, NULL, 0, NULL, 0);
    assert(!failed.complete); dm_seg_snap_free(&failed);
    return 0;
}
''')
            binary = root / 'test'
            subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(root),
                            '-I', str(IOS / 'App'), str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_native_routes_keep_images_separate(self):
        source = (IOS / 'App/ShellMain.m').read_text()
        self.assertIn('fbase == (const void *)&_mh_execute_header', source)
        self.assertIn('runtime_base == info.dli_fbase', source)
        self.assertIn('game_desc_info.dli_fbase != info.dli_fbase', source)
        self.assertIn('restore_framework_data(runtime_base)', source)
        self.assertIn('restore_framework_data(fbase)', source)
        self.assertLess(source.index('shared_descriptors_match(game, runtime)'), source.index('start(argv, argc, info.dli_fbase)'))
        self.assertLess(source.index('save_framework_data(runtime_base, NULL, NULL, 0)'), source.index('start(argv, argc, info.dli_fbase)'))
        self.assertIn('void *host = h;', source)  # Legacy FH still uses its own host.
        discovery = source[source.index('int dm_shell_shared_runtime_abi'):source.index('static const dm_shared_descriptor *shared_runtime(')]
        self.assertNotIn('dlopen(', discovery)


if __name__ == '__main__':
    unittest.main()
