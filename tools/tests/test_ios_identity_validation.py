"""Portable import checks with disposable certificates, never real credentials."""
import ctypes
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "frontend-ios/Sources/NativeSigning"


@unittest.skipUnless(shutil.which("g++") and shutil.which("openssl") and
                     Path("/usr/include/openssl/cms.h").exists(),
                     "requires a C++ compiler and OpenSSL development headers")
class ImportedIdentityValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="nx-disposable-identity-")
        cls.directory = Path(cls.temp.name)
        def run(*args):
            subprocess.run(args, cwd=cls.directory, check=True, capture_output=True)
        run("g++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
            "-I" + str(SOURCE / "include"), str(SOURCE / "NativeIdentityValidation.cpp"),
            "-lcrypto", "-o", "validator.so")
        (cls.directory / "content").write_bytes(b"disposable synthetic code directory")
        for name in ("host", "other"):
            run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=" + name + "/OU=TESTTEAM01", "-keyout", name + ".key",
                "-out", name + ".pem")
            run("openssl", "pkcs12", "-export", "-inkey", name + ".key", "-in", name + ".pem",
                "-passout", "pass:disposable", "-out", name + ".p12")
        run("openssl", "pkcs12", "-export", "-legacy", "-inkey", "host.key", "-in", "host.pem",
            "-passout", "pass:disposable", "-out", "legacy.p12")
        run("openssl", "cms", "-sign", "-binary", "-in", "content", "-signer", "host.pem",
            "-inkey", "host.key", "-outform", "DER", "-out", "host.cms")
        run("openssl", "x509", "-in", "host.pem", "-outform", "DER", "-out", "host.der")
        run("openssl", "pkcs12", "-export", "-nokeys", "-in", "host.pem",
            "-passout", "pass:disposable", "-out", "keyless.p12")
        cls.library = ctypes.CDLL(str(cls.directory / "validator.so"))
        cls.validate = cls.library.nx_shell_validate_imported_identity
        cls.validate.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p,
                                 ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p,
                                 ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
        cls.validate.restype = ctypes.c_int

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def check(self, name="host", password=b"disposable", cms=None):
        p12 = (self.directory / (name + ".p12")).read_bytes()
        if cms is None:
            cms = (self.directory / "host.cms").read_bytes()
        output = ctypes.create_string_buffer(65536)
        length = ctypes.c_size_t()
        result = self.validate(p12, len(p12), password, cms, len(cms), output,
                               len(output), ctypes.byref(length))
        return result, output.raw[:length.value]

    def test_matching_host_returns_exact_certificate(self):
        self.assertEqual(self.check(), (0, (self.directory / "host.der").read_bytes()))

    def test_legacy_encrypted_identity_matches_host(self):
        self.assertEqual(self.check("legacy"), (0, (self.directory / "host.der").read_bytes()))

    def test_same_team_different_certificate_is_rejected(self):
        self.assertEqual(self.check("other"), (3, b""))

    def test_wrong_password_and_missing_private_key_are_rejected(self):
        self.assertEqual(self.check(password=b"wrong"), (1, b""))
        self.assertEqual(self.check("keyless"), (1, b""))

    def test_missing_malformed_and_trailing_cms_are_rejected(self):
        for cms in (b"", b"not cms", (self.directory / "host.cms").read_bytes() + b"extra"):
            with self.subTest(cms_length=len(cms)):
                self.assertEqual(self.check(cms=cms), (2, b""))
