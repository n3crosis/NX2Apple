"""Portable launcher registration contract, not an Apple kernel/signature test.

Compile the production C body after its Objective-C bundle-path guard. A mocked
fcntl checks the file offsets passed to F_ADDFILESIGS_RETURN on synthetic images.
"""
from pathlib import Path
import errno
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "frontend-ios/Shell/App/ShellMain.m"

SHIM = r"""
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define FAT_MAGIC 0xcafebabe
#define FAT_MAGIC_64 0xcafebabf
#define MH_MAGIC_64 0xfeedfacf
#define CPU_TYPE_ARM64 0x0100000c
#define LC_CODE_SIGNATURE 0x1d
#ifndef F_ADDFILESIGS_RETURN
#define F_ADDFILESIGS_RETURN 97
#endif
struct mach_header_64 {
    uint32_t magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved;
};
struct load_command { uint32_t cmd, cmdsize; };
struct linkedit_data_command { uint32_t cmd, cmdsize, dataoff, datasize; };
typedef struct {
    off_t fs_file_start;
    void *fs_blob_start;
    size_t fs_blob_size;
} harness_fsignatures_t;
// Keep the mock independent of a platform header's real fsignatures_t ABI.
#define fsignatures_t harness_fsignatures_t
static unsigned long long expected_slice, expected_signature, expected_size;
static int calls, mismatch, kernel_errno;
static int mock_fcntl(int fd, int command, fsignatures_t *signature) {
    calls++;
    mismatch = fd < 0 || command != F_ADDFILESIGS_RETURN ||
        (unsigned long long)signature->fs_file_start != expected_slice ||
        (uintptr_t)signature->fs_blob_start != expected_signature ||
        signature->fs_blob_size != expected_size;
    errno = kernel_errno;
    return kernel_errno ? -1 : 0;
}
#define fcntl mock_fcntl
"""

MAIN = r"""
int main(int argc, char **argv) {
    if (argc != 8) return 2;
    expected_slice = strtoull(argv[2], NULL, 10);
    expected_signature = strtoull(argv[3], NULL, 10);
    expected_size = strtoull(argv[4], NULL, 10);
    kernel_errno = atoi(argv[5]);
    const char *error = register_external_signature(argv[1]);
    if (mismatch || calls != atoi(argv[6]) || (error != NULL) != atoi(argv[7])) {
        fprintf(stderr, "registration contract: mismatch=%d calls=%d error=%s\n",
            mismatch, calls, error ? error : "none");
        return 1;
    }
    return 0;
}
"""


@unittest.skipUnless(shutil.which("cc"), "requires a C compiler")
class ExternalSignatureRegistrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="nx-registration-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        source = SOURCE.read_text()
        function = source.index("static const char *register_external_signature(")
        start = source.index("    int fd = open(", function)
        end = source.index("\n}\n#endif", start)
        harness = cls.directory / "registration.c"
        harness.write_text(SHIM + "\nstatic const char *register_external_signature(const char *executable) {\n"
                           + source[start:end] + "\n}\n" + MAIN)
        cls.executable = cls.directory / "registration"
        subprocess.run(["cc", "-std=c11", "-D_DEFAULT_SOURCE", "-Wall", "-Wextra", "-Werror",
                        str(harness), "-o", str(cls.executable)], check=True, capture_output=True)

    @staticmethod
    def image(signature_offset=256, signature_size=32):
        header = struct.pack("<8I", 0xfeedfacf, 0x0100000c, 0, 6, 1, 16, 0, 0)
        command = struct.pack("<4I", 0x1d, 16, signature_offset, signature_size)
        # Placeholder signature bytes: no cryptographic validity is implied.
        return (header + command).ljust(256, b"\0") + b"s" * 32

    def check(self, image, slice_offset=0, signature_offset=256, signature_size=32,
              kernel_errno=0, calls=1, error=False):
        path = self.directory / "image"
        path.write_bytes(image)
        result = subprocess.run([str(self.executable), str(path), str(slice_offset),
                                 str(signature_offset), str(signature_size), str(kernel_errno),
                                 str(calls), str(int(error))], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_thin_image_uses_signature_file_offset(self):
        self.check(self.image())

    def test_fat_images_keep_slice_and_signature_offsets_separate(self):
        thin = self.image()
        offset = 4096
        for wide in (False, True):
            with self.subTest(fat64=wide):
                magic = 0xcafebabf if wide else 0xcafebabe
                arch = (struct.pack(">IIQQII", 0x0100000c, 0, offset, len(thin), 12, 0) if wide
                        else struct.pack(">5I", 0x0100000c, 0, offset, len(thin), 12))
                image = (struct.pack(">II", magic, 1) + arch).ljust(offset, b"\0") + thin
                self.check(image, slice_offset=offset)

    def test_invalid_signature_bounds_never_call_fcntl(self):
        for offset, size in ((0, 32), (256, 11), (289, 12), (280, 32)):
            with self.subTest(offset=offset, size=size):
                self.check(self.image(offset, size), calls=0, error=True)

    def test_kernel_error_is_reported_except_existing_signature(self):
        self.check(self.image(), kernel_errno=errno.EINVAL, error=True)
        self.check(self.image(), kernel_errno=errno.EEXIST)


if __name__ == "__main__":
    unittest.main()
