# Re-sign imported games on iOS

The library's **Re-sign imported game** button opens local identity setup and the
list of writable imported games. Import a P12 certificate/private key and a
matching provisioning profile. The identity must match the team signing the host
app. It is saved only in this device's non-synchronizing, unlocked-only Keychain.
No Apple account login or network signing service is used.

This integration supports the shell's existing `Documents/Frameworks` imports.
It introduces no NXB format, does not require future NXB games to be frameworks,
and does not renew the shell app or install a standalone IPA. Only thin arm64
libraries with sufficient signature reservation are supported. There is no
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

- Vendored zsign 1.1.3: `9299685bab7ef99827e06e5dfda93af747386590`, MIT.
- OpenSSL-Package: `e61a288a9bc49a0358ab61614cac3d0553472254`, tag 3.6.5000.
- OpenSSL 3.6.5 binary SHA256: `f50188506490c643715489217d32e458d06cee5579399ff616f0ce2038169fea`.
- Dependency URL: https://github.com/krzyzanowskim/OpenSSL-Package.git
- The third-party OpenSSL distributor builds from checksum-verified official
  OpenSSL source. It is not an OpenSSL-project-operated package.

The actual release ZIP was checksum-verified. It contains iOS arm64, simulator
arm64/x86_64 and macOS arm64/x86_64 slices. Its device binary exports the required
CMS, PKCS12 and provider functions, including the legacy provider implementation.
Apple framework includes are adapted to the exact `OpenSSL` namespace.

The vendored MIT license and OpenSSL Apache-2.0 license are retained and bundled
with ShellHost resources. `Vendor/UPSTREAM.txt` records all source adaptations.
To verify the vendored core against a local zsign checkout containing the pin:

```
python3 frontend-ios/Signing/prepare_signer.py /path/to/zsign-checkout
```

The helper only reads immutable git objects. `--output <new-directory>` generates
a review copy. No upstream LiveContainer app-loader or AGPL code is included.

## Verification and remaining device gate

```
V=frontend-ios/Sources/NativeSigning
c++ -std=c++17 -fPIC -shared -I$V/include $V/NativeSigning.cpp -o /tmp/lib-shell-unavailable.so
c++ -std=c++17 -fPIC -shared -DNX_SHELL_ENABLE_ZSIGN -I$V/include -I$V/Vendor -I$V/Vendor/common $V/NativeSigning.cpp $V/Vendor/*.cpp $V/Vendor/common/*.cpp -lcrypto -o /tmp/lib-shell-signing.so
python3 frontend-ios/Signing/test_signer_bridge.py /tmp/lib-shell-signing.so /tmp/lib-shell-unavailable.so
```

Linux checks use disposable synthetic certificates and system OpenSSL. They
verify actual code-page hashes/CMS signatures, wrong password/team/certificate,
malformed input, full-width section names, insufficient reservation and repeat
signing. They do not test the Apple XCFramework or establish Apple trust.
Swift tests cover rollback, atomic replacement, links and identity import bounds.

SwiftPM resolution, Apple SDK compilation/linking, app framework embedding,
Keychain/UI, provider runtime behavior and physical-device acceptance remain
unverified. This Linux environment has no Swift compiler, Xcode or iOS SDK, and
no Mac or CI was used. An authorized Apple build and device run are required
before claiming this works on a phone.

Credential files are protected and removed after use. A later operation cleans
crash leftovers. Passwords are never logged, but Swift String copies cannot
promise memory zeroization. Removing an identity prevents later signing only.
