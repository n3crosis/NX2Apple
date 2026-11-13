"""Offline regression checks for the default shell signing dependency graph."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "frontend-ios"


class IOSSigningDependenciesTests(unittest.TestCase):
    def test_default_backend_has_no_environment_opt_in(self):
        manifest = (IOS / "Package.swift").read_text()
        self.assertNotIn("NX_SHELL_ENABLE_ZSIGN", manifest)
        self.assertNotIn("ProcessInfo", manifest)
        self.assertNotIn("NX_SHELL_OPENSSL_PREFIX", manifest)
        self.assertIn('.product(name: "zsignc", package: "zsign")', manifest)
        self.assertIn('https://github.com/n3crosis/zsign.git', manifest)
        self.assertIn('.product(name: "OpenSSL", package: "OpenSSL-Package")', manifest)
        self.assertIn('revision: "e61a288a9bc49a0358ab61614cac3d0553472254"', manifest)

    def test_no_copied_signer_or_preparation_step(self):
        self.assertFalse((IOS / "Sources/NativeSigning/Vendor").exists())
        self.assertFalse((IOS / "Signing/prepare_signer.py").exists())
        manifest = (IOS / "Package.swift").read_text()
        self.assertNotIn("Vendor", manifest)

    def test_bridge_uses_only_public_external_api(self):
        bridge = (IOS / "Sources/NativeSigning/NativeSigning.cpp").read_text()
        self.assertIn("#include <ZSignLibrary.h>", bridge)
        self.assertIn("return zsign_check_identity(pkcs12, password, profile, team, error, capacity);", bridge)
        self.assertIn("return zsign_sign_library(path, pkcs12, password, profile, team, identifier, error, capacity);", bridge)
        self.assertIn("nx_shell_signer_available(void) { return 1; }", bridge)
        for internal in ("ZSignAsset", "ZMachO", "NX_SHELL_ENABLE_ZSIGN", "openssl.h"):
            self.assertNotIn(internal, bridge)

    def test_licenses_ship_in_host_resources(self):
        resources = IOS / "Sources/ShellHost/Resources/SigningLicenses"
        self.assertIn("zhlynn", (resources / "zsign-MIT.txt").read_text())
        for name in ["OpenSSL-Apache-2.0.txt", "OpenSSL-Package-Apache-2.0.txt"]:
            self.assertIn("Apache License", (resources / name).read_text())
        self.assertIn('.process("Resources")', (IOS / "Package.swift").read_text())

    def test_shell_consumes_the_package(self):
        project = (IOS / "Shell/project-shell.yml").read_text()
        self.assertIn("path: ${DM_SHELL_PACKAGE}", project)
        self.assertIn("product: ShellHost", project)


if __name__ == "__main__":
    unittest.main()
