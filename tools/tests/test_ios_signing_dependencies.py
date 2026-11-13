"""Offline regression checks for the default shell signing dependency graph."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "frontend-ios"


class IOSSigningDependenciesTests(unittest.TestCase):
    def test_default_backend_has_no_environment_opt_in(self):
        manifest = (IOS / "Package.swift").read_text()
        self.assertIn('.define("NX_SHELL_ENABLE_ZSIGN")', manifest)
        self.assertNotIn("ProcessInfo", manifest)
        self.assertNotIn("NX_SHELL_OPENSSL_PREFIX", manifest)
        self.assertIn('dependencies: [.product(name: "OpenSSL", package: "OpenSSL-Package")]', manifest)
        self.assertIn('revision: "e61a288a9bc49a0358ab61614cac3d0553472254"', manifest)

    def test_required_core_sources_are_committed_inputs(self):
        vendor = IOS / "Sources/NativeSigning/Vendor"
        for name in ["archo.cpp", "macho.cpp", "openssl.cpp", "signing.cpp", "common/json.cpp"]:
            self.assertTrue((vendor / name).is_file(), name)
        self.assertIn("9299685bab7ef99827e06e5dfda93af747386590", (vendor / "UPSTREAM.txt").read_text())

    def test_apple_headers_use_exact_framework_name(self):
        crypto = (IOS / "Sources/NativeSigning/Vendor/openssl.cpp").read_text()
        self.assertIn('#if defined(__APPLE__)\n#include <OpenSSL/cms.h>', crypto)
        self.assertIn('#else\n#include <openssl/cms.h>', crypto)

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
