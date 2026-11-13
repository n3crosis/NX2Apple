# Re-sign imported games on iOS

Import a P12 certificate/private key and provisioning profile through
**Settings → Signing identity**. Import checks the private key, certificate dates,
exact certificate match with the installed host executable's CMS signer, profile
certificate membership and host/profile team. Profiles must contain CMS SignedData;
raw plists are rejected. It is not a team-only match. Missing
or ad-hoc host signatures are rejected. The identity is saved only in this
device's non-synchronizing, unlocked-only Keychain. The library's
**Re-sign imported game** button selects a writable imported game.
No Apple account login or network signing service is used.

This integration supports the shell's existing `Documents/Frameworks` imports.
It introduces no NXB format, does not require future NXB games to be frameworks,
and does not renew the shell app or install a standalone IPA. Only thin arm64
libraries with sufficient signature reservation are supported, including the main
executable named by both the manifest and Info.plist. There is no
ad-hoc, JIT, resizing or privilege fallback.

Signing runs on a private copy off the UI thread. Every native image must pass
the host-team check and kernel signature/library validation before an atomic
directory exchange replaces the installed copy. Failure leaves the original
intact. There is no two-rename/delete fallback. Restart reloads the signed game.
Signing is refused after any game-launch attempt across all windows. Play,
delete and catalogue reload are blocked during signing and until restart.
Interrupted private stages are cleaned on the next signing operation. Saves and
game data are not changed.

## Default build integration

The normal `frontend-ios/Package.swift` dependency graph includes the signing
backend. The existing shell and demo Xcode projects consume that package, so no
environment flags, locally built crypto prefix or manual dependency preparation
are required. SwiftPM resolves the checksum-pinned OpenSSL XCFramework and Xcode
must embed/sign its dynamic framework as part of the app's dependency graph.

- External zsign Swift package: `ccfe8f7fe273d63568ffb9e7fd494d95e3ddd812`, MIT.
- zsign dependency URL: https://github.com/n3crosis/zsign.git
- Native product: `zsignc`, public standalone-library API: `ZSignLibrary.h`.
- OpenSSL-Package: `e61a288a9bc49a0358ab61614cac3d0553472254`, tag 3.6.5000.
- OpenSSL 3.6.5 binary SHA256: `f50188506490c643715489217d32e458d06cee5579399ff616f0ce2038169fea`.
- Dependency URL: https://github.com/krzyzanowskim/OpenSSL-Package.git
- The third-party OpenSSL distributor builds from checksum-verified official
  OpenSSL source. It is not an OpenSSL-project-operated package.

The actual release ZIP was checksum-verified. It contains iOS arm64, simulator
arm64/x86_64 and macOS arm64/x86_64 slices. Its device binary exports the required
CMS, PKCS12 and provider functions, including the legacy provider implementation.
Apple framework includes are adapted to the exact `OpenSSL` namespace.

The zsign MIT license and OpenSSL Apache-2.0 licenses remain bundled with
ShellHost resources. NX2Apple contains only a forwarding bridge to the pinned
package's public API, not a copy of zsign's implementation. The package owns
signing serialization, credential checks and bounded Mach-O signing. NX2Apple
owns host-identity matching, private staging, kernel validation and replacement.
No upstream LiveContainer app-loader or AGPL code is included.

## Verification and remaining device gate

To exercise the real bridge against an external zsign checkout, first build that
package's standalone C API into a Linux shared library. With `ZSIGN` pointing to
the matching checkout and `ZSIGN_LIBRARY` to that shared library:

```
V=frontend-ios/Sources/NativeSigning
c++ -std=c++17 -fPIC -shared -I"$V/include" -I"$ZSIGN/src/include" "$V/NativeSigning.cpp" "$ZSIGN_LIBRARY" -Wl,-rpath,"$(dirname "$ZSIGN_LIBRARY")" -o /tmp/lib-shell-signing.so
python3 frontend-ios/Signing/test_signer_bridge.py /tmp/lib-shell-signing.so
python3 -m unittest discover -s tools/tests -p 'test_ios_identity_validation.py'
```

There is no optional/unavailable signer build. A missing dependency is a build
error. The external package and NX2Apple use the same pinned OpenSSL package to
avoid linking conflicting distributions.

Linux checks use disposable synthetic certificates and system OpenSSL. They
verify actual code-page hashes/CMS signatures, wrong password/team/certificate,
malformed input, full-width section names, insufficient reservation and repeat
signing. They do not test the Apple XCFramework or establish Apple trust. The profile
parser does not authenticate Apple's profile CMS signature; membership/team checks
are not trust, revocation or device-eligibility checks. Kernel acceptance remains
a required gate before replacing the game.
Swift tests cover rollback, atomic replacement, links and identity import bounds.

SwiftPM resolution, Apple SDK compilation/linking, app framework embedding,
Keychain/UI, provider runtime behavior and physical-device acceptance remain
unverified. This Linux environment has no Swift compiler, Xcode or iOS SDK, and
no Mac or CI was used. An authorized Apple build and device run are required
before claiming this works on a phone.

Credential files are protected and removed after use. A later operation cleans
crash leftovers. Passwords are never logged, but Swift String copies cannot
promise memory zeroization. Removing an identity prevents later signing only.
