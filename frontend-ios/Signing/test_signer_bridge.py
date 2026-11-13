#!/usr/bin/env python3
"""Linux bridge smoke test. Synthetic identity only, never Apple credentials.
Usage: test_signer_bridge.py /tmp/lib-shell-signing.so
Does not establish kernel trust or iOS loadability.
"""
import ctypes
import hashlib
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile


def openssl(root, *args):
    return subprocess.run(["openssl", *args], cwd=root, check=True, capture_output=True)


def image():
    text = struct.pack("<II16sQQQQIIII", 0x19, 72, b"__TEXT", 0, 4096, 0, 4096, 5, 5, 0, 0)
    link = struct.pack("<II16sQQQQIIII", 0x19, 72, b"__LINKEDIT", 4096, 32768, 4096, 32768, 1, 1, 0, 0)
    signature = struct.pack("<IIII", 0x1d, 16, 4096, 32768)
    header = struct.pack("<8I", 0xfeedfacf, 0x0100000c, 0, 6, 3, 160, 0, 0)
    return (header + text + link + signature).ljust(36864, b"\0")


def load(path):
    library = ctypes.CDLL(str(Path(path).resolve()))
    library.nx_shell_sign_library.argtypes = [ctypes.c_char_p] * 7 + [ctypes.c_size_t]
    return library


def main():
    enabled = load(sys.argv[1])
    message = ctypes.create_string_buffer(1024)
    with tempfile.TemporaryDirectory(prefix="shell-synthetic-signing-") as temporary:
        root = Path(temporary)
        openssl(root, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Shell Synthetic Test CA", "-days", "1", "-keyout", "ca.key", "-out", "ca.pem")
        openssl(root, "req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Shell Synthetic Test Leaf/OU=TESTTEAM01", "-keyout", "leaf.key", "-out", "leaf.csr")
        openssl(root, "x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "1", "-out", "leaf.pem")
        openssl(root, "pkcs12", "-export", "-inkey", "leaf.key", "-in", "leaf.pem", "-certfile", "ca.pem", "-passout", "pass:test-only", "-out", "identity.p12")
        certificate = openssl(root, "x509", "-in", "leaf.pem", "-outform", "DER").stdout
        (root / "profile.plist").write_bytes(plistlib.dumps({"TeamIdentifier": ["TESTTEAM01"], "DeveloperCertificates": [certificate], "Entitlements": {"application-identifier": "TESTTEAM01.org.test"}}))
        openssl(root, "cms", "-sign", "-binary", "-nodetach", "-in", "profile.plist", "-signer", "leaf.pem", "-inkey", "leaf.key", "-outform", "DER", "-out", "profile.cms")
        native = root / "native"

        def sign(team=b"TESTTEAM01", password=b"test-only", p12="identity.p12"):
            return enabled.nx_shell_sign_library(str(native).encode(), str(root / p12).encode(), password,
                str(root / "profile.cms").encode(), team, b"org.test", message, 1024)

        # Same team is insufficient when the certificate is absent from the profile.
        openssl(root, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Other/OU=TESTTEAM01", "-days", "1", "-keyout", "other.key", "-out", "other.pem")
        openssl(root, "pkcs12", "-export", "-inkey", "other.key", "-in", "other.pem", "-passout", "pass:test-only", "-out", "other.p12")
        native.write_bytes(image())
        assert sign(p12="other.p12") != 0
        assert native.read_bytes() == image()
        native.write_bytes(image())
        assert sign(b"OTHERTEAM1") != 0 and b"host team" in message.value
        assert native.read_bytes() == image()
        assert sign(password=b"wrong") != 0
        assert native.read_bytes() == image()
        for offset, value in [(16, 0xffffffff), (20, 0xffffffff), (36, 0), (104, 1), (188, 0xffffffff), (4, 19)]:
            malformed = bytearray(image())
            struct.pack_into("<I", malformed, offset, value)
            native.write_bytes(malformed)
            assert sign() != 0, (offset, message.value)
            assert native.read_bytes() == malformed
        tiny = bytearray(image()[:4108])
        struct.pack_into("<I", tiny, 188, 12)
        struct.pack_into("<Q", tiny, 152, 12) # __LINKEDIT filesize
        native.write_bytes(tiny)
        assert sign() != 0 # No automatic resizing when CMS exceeds reservation.
        assert native.read_bytes() == tiny
        # Valid full-width section names must not be rejected as unterminated.
        full = bytearray(image())
        section = struct.pack("<16s16sQQIIIIIIII", b"__swift5_capture", b"__TEXT", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        full[104:264] = section + full[104:184]
        full[264:280] = image()[184:200]
        struct.pack_into("<I", full, 20, 240)
        struct.pack_into("<I", full, 36, 152)
        struct.pack_into("<I", full, 96, 1)
        native.write_bytes(full)
        assert sign() == 0, message.value
        native.write_bytes(image())
        assert sign() == 0, message.value
        data = native.read_bytes()[4096:]
        magic, length, count = struct.unpack_from(">III", data)
        assert magic == 0xfade0cc0 and length <= 32768
        slots = {}
        for i in range(count):
            kind, offset = struct.unpack_from(">II", data, 12 + 8 * i)
            size = struct.unpack_from(">I", data, offset + 4)[0]
            slots[kind] = data[offset:offset + size]
        cd = slots[0]
        hash_offset = struct.unpack_from(">I", cd, 16)[0]
        page_count, code_limit = struct.unpack_from(">II", cd, 28)
        hash_size, hash_type, _, page_power = cd[36:40]
        assert code_limit == 4096 and hash_type == 2 and hash_size == 32
        signed_bytes = native.read_bytes()[:code_limit]
        for page in range(page_count):
            chunk = signed_bytes[page * (1 << page_power):(page + 1) * (1 << page_power)]
            assert cd[hash_offset + page * hash_size:hash_offset + (page + 1) * hash_size] == hashlib.sha256(chunk).digest()
        team_offset = struct.unpack_from(">I", cd, 48)[0]
        assert cd[team_offset:].split(b"\0", 1)[0] == b"TESTTEAM01"
        (root / "cd").write_bytes(cd)
        (root / "cms").write_bytes(slots[0x10000][8:])
        openssl(root, "cms", "-verify", "-binary", "-inform", "DER", "-in", "cms", "-content", "cd", "-noverify", "-out", "verified")
        assert (root / "verified").read_bytes() == cd
        assert sign() == 0, message.value # Re-sign existing CMS without resizing.
    print("PASS: external backend, team/password failures, malformed bounds, synthetic CMS signing/verification, re-signing")



if __name__ == "__main__":
    main()
