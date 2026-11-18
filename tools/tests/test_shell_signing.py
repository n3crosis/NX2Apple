"""Portable regressions for acknowledging signature-only shell replacements.

These exercise the actual C helpers, not a Python copy. UIKit/dyld and device
signature acceptance still require the iOS build and device lifecycle tests.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADERS = ROOT / 'frontend-ios/Shell/App'
CC = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')


@unittest.skipUnless(CC, 'requires a C compiler')
class ShellSigningTests(unittest.TestCase):
    def run_c(self, body):
        source = '#include <assert.h>\n#include "ShellSnap.h"\nint main(void) {\n' + body + '\nreturn 0;\n}\n'
        with tempfile.TemporaryDirectory(prefix='shell-signing-') as directory:
            src = Path(directory) / 'test.c'
            exe = Path(directory) / 'test'
            src.write_text(source)
            subprocess.run([CC, '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-I', str(HEADERS), str(src), '-o', str(exe)], check=True,
                           capture_output=True, text=True)
            subprocess.run([str(exe)], check=True, capture_output=True, text=True)

    def test_signature_replacement_replays_and_can_repeat(self):
        self.run_c(r'''
            time_t stamp = 10;
            assert(dm_snap_conflicts("game", "/game", stamp, "game", "/game", 20));
            assert(dm_snap_acknowledge_resign("game", "/game", &stamp, "game", "/game", 10, 20));
            assert(stamp == 20);
            assert(!dm_snap_conflicts("game", "/game", stamp, "game", "/game", 20));
            assert(dm_snap_acknowledge_resign("game", "/game", &stamp, "game", "/game", 20, 30));
            assert(stamp == 30);
            assert(dm_snap_conflicts("game", "/game", stamp, "game", "/game", 40));
        ''')

    def test_prior_real_update_and_path_change_stay_blocked(self):
        self.run_c(r'''
            time_t stamp = 10;
            assert(!dm_snap_acknowledge_resign("game", "/game", &stamp, "game", "/game", 15, 20));
            assert(stamp == 10);
            assert(dm_snap_conflicts("game", "/game", stamp, "game", "/game", 20));
            assert(!dm_snap_acknowledge_resign("game", "/old", &stamp, "game", "/new", 10, 20));
            assert(stamp == 10);
            assert(dm_snap_conflicts("game", "/old", stamp, "game", "/new", 20));
        ''')

    def test_unrelated_snapshots_are_untouched(self):
        self.run_c(r'''
            time_t target = 10, other = 10;
            assert(dm_snap_acknowledge_resign("game", "/game", &target, "game", "/game", 10, 20));
            assert(!dm_snap_acknowledge_resign("other", "/game", &other, "game", "/game", 10, 20));
            assert(target == 20 && other == 10);
        ''')

    def test_empty_or_missing_identity_cannot_acknowledge(self):
        self.run_c(r'''
            time_t stamp = 10;
            assert(!dm_snap_acknowledge_resign("", "/game", &stamp, "", "/game", 10, 20));
            assert(!dm_snap_acknowledge_resign("game", "", &stamp, "game", "", 10, 20));
            assert(!dm_snap_acknowledge_resign(NULL, "/game", &stamp, "game", "/game", 10, 20));
            assert(!dm_snap_acknowledge_resign("game", NULL, &stamp, "game", "/game", 10, 20));
            assert(!dm_snap_acknowledge_resign("game", "/game", NULL, "game", "/game", 10, 20));
            assert(!dm_snap_acknowledge_resign("game", "/game", &stamp, NULL, "/game", 10, 20));
            assert(!dm_snap_acknowledge_resign("game", "/game", &stamp, "game", NULL, 10, 20));
            assert(stamp == 10);
        ''')

    def test_every_installed_identity_field_must_match(self):
        self.run_c(r'''
            DmShellFileIdentity expected = {1, 2, 3, 4, 5, 6, 7};
            DmShellFileIdentity actual = expected;
            assert(dm_snap_file_identity_matches(actual, expected));
            #define CHECK_FIELD(field) actual = expected; actual.field++; assert(!dm_snap_file_identity_matches(actual, expected))
            CHECK_FIELD(device);
            CHECK_FIELD(inode);
            CHECK_FIELD(size);
            CHECK_FIELD(modification_seconds);
            CHECK_FIELD(modification_nanoseconds);
            CHECK_FIELD(change_seconds);
            CHECK_FIELD(change_nanoseconds);
            #undef CHECK_FIELD
        ''')

class ShellSigningViewWiringTests(unittest.TestCase):
    def test_shared_signing_busy_state_disables_touch_in_every_host_view(self):
        # Source wiring regression only. Actual sheet/touch behavior needs an iOS Simulator.
        source = (ROOT / 'frontend-ios/Sources/ShellHost/ShellHostView.swift').read_text()
        self.assertRegex(source, r'\.disabled\(\s*model\.launchingGame\s*\|\|\s*model\.resigningGame\s*\)')


if __name__ == '__main__':
    unittest.main()
