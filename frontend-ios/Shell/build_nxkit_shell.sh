#!/bin/bash
# Build the shared Rust runtime locally and prepare the existing iOS shell without game frameworks.
# Requires macOS/Xcode, Rust's aarch64-apple-ios target and xcodegen.
# NXKIT_SOURCE: optional local public-upstream checkout, used only to read the pinned revision.
# NXKIT_RUNTIME_ABI: the compatibility ABI used by the producer. Revision identifies the patched source tree.
# SHELL_DIR: generated project/artifacts outside the repository. No engine or game data is copied.
# --prepare-xcode builds Rust and generates the project; --build also packages an unsigned device IPA for signing/sideloading.
# SHELL_PLATFORM=maccatalyst builds the same UIKit shell as a native Mac app.
# --build-unsigned checks a Catalyst build without signing or exporting a distributable app.
# A signed Mac --build requires DM_TEAM_ID and DM_SIGNING_IDENTITY; game payloads remain separate.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-}
case "$MODE" in --prepare-xcode|--build|--build-unsigned) ;; *) echo "usage: $0 --prepare-xcode | --build | --build-unsigned" >&2; exit 1;; esac
: "${NXKIT_RUNTIME_ABI:?set the producer/runtime ABI}"
: "${SHELL_DIR:?set SHELL_DIR outside the repository}"
[ "$(uname -s)" = Darwin ] || { echo 'An Apple SDK is required to build the runtime and shell.' >&2; exit 1; }
[ -z "${DOCS_RS:-}" ] || { echo 'DOCS_RS skips native helpers and cannot build a runnable app.' >&2; exit 1; }
export DM_SHELL_PACKAGE=${DM_SHELL_PACKAGE:-$(cd "$ROOT/.." && pwd)}
export DM_BUNDLE_ID=${DM_BUNDLE_ID:-org.nxnative.shell} DM_TEAM_ID=${DM_TEAM_ID:-0000000000}
export DM_SHELL_NAME=${DM_SHELL_NAME:-NX2Apple} DM_APP_VERSION=${DM_APP_VERSION:-1.0}
export NXKIT_RUNTIME_ABI
export SHELL_PLATFORM=${SHELL_PLATFORM:-ios}
case "$SHELL_PLATFORM" in
  ios) RUST_TARGET=aarch64-apple-ios; APPLE_SDK=iphoneos; DESTINATION='generic/platform=iOS' ;;
  maccatalyst)
    RUST_TARGET=aarch64-apple-ios-macabi; APPLE_SDK=macosx
    DESTINATION='generic/platform=macOS,variant=Mac Catalyst'
    if [ "$MODE" = --build ]; then
      : "${DM_SIGNING_IDENTITY:?set a certificate signing identity for the Mac shell}"
      [ "$DM_TEAM_ID" != 0000000000 ] || { echo 'Set DM_TEAM_ID for the Mac shell.' >&2; exit 1; }
    fi
    ;;
  *) echo 'SHELL_PLATFORM must be ios or maccatalyst.' >&2; exit 1 ;;
esac
[ "$MODE" != --build-unsigned ] || [ "$SHELL_PLATFORM" = maccatalyst ] || { echo '--build-unsigned is for Catalyst validation only.' >&2; exit 1; }
mkdir -p "$SHELL_DIR"
S=$(cd "$SHELL_DIR" && pwd)
REPO=$(cd "$ROOT/../.." && pwd)
case "$S/" in "$REPO/"*) echo 'SHELL_DIR must be outside the repository.' >&2; exit 1;; esac
PIN=5e84a342486131bbc2d9397424efb105c6150584
UPSTREAM=${NXKIT_SOURCE:-$S/Upstream}
if [ ! -d "$UPSTREAM/.git" ]; then
  [ -z "${NXKIT_SOURCE:-}" ] || { echo 'NXKIT_SOURCE must be a git checkout.' >&2; exit 1; }
  git clone --filter=blob:none --no-checkout https://github.com/v0lumehi/nxkit "$UPSTREAM"
fi
git -C "$UPSTREAM" cat-file -e "$PIN^{commit}" 2>/dev/null || git -C "$UPSTREAM" fetch https://github.com/v0lumehi/nxkit "$PIN"
# Prepare a fresh source tree; never reset or modify a developer's checkout.
export NXKIT_SOURCE=$(mktemp -d "$S/nxkit.XXXXXX")
git -C "$UPSTREAM" archive "$PIN" | tar -x -C "$NXKIT_SOURCE"
git -C "$NXKIT_SOURCE" init -q
git -C "$NXKIT_SOURCE" apply "$DM_SHELL_PACKAGE/GameRuntime/nxkit-runtime.patch"
git -C "$NXKIT_SOURCE" apply "$DM_SHELL_PACKAGE/GameBuilder/nxkit-producer.patch"
git -C "$NXKIT_SOURCE" add -f .
export NXKIT_RUNTIME_REVISION=$(git -C "$NXKIT_SOURCE" write-tree)
export NXKIT_BUILDER_SOURCE="$S/GameBuilder"
mkdir -p "$NXKIT_BUILDER_SOURCE/src" "$NXKIT_BUILDER_SOURCE/include"
cp "$DM_SHELL_PACKAGE/GameBuilder/src/lib.rs" "$NXKIT_BUILDER_SOURCE/src/"
cp "$DM_SHELL_PACKAGE/GameBuilder/include/"* "$NXKIT_BUILDER_SOURCE/include/"
python3 -I - "$DM_SHELL_PACKAGE/GameBuilder/Cargo.toml" "$NXKIT_BUILDER_SOURCE/Cargo.toml" <<'BRIDGE'
import os, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
text = text.replace('../nxkit/crates/nxb-build', os.environ['NXKIT_SOURCE'] + '/crates/nxb-build')
pathlib.Path(sys.argv[2]).write_text(text)
BRIDGE
export NXKIT_ARTIFACT_DIR="$S/Rust/$RUST_TARGET/release"
export SDKROOT=$(xcrun --sdk "$APPLE_SDK" --show-sdk-path)
export IPHONEOS_DEPLOYMENT_TARGET=26.0
export MACOSX_DEPLOYMENT_TARGET=26.0
# One staticlib owns the Rust runtime/allocator for producer, player and optional tunnel.
# The local crate is build glue, not a vendored copy or a remote fork dependency.
python3 -I - "$S/Native" <<'NATIVE'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
(root / 'src').mkdir(parents=True, exist_ok=True)
runtime = json.dumps(os.environ['NXKIT_SOURCE'] + '/crates/nxkit-host')
producer = json.dumps(os.environ['NXKIT_BUILDER_SOURCE'])
tunnel = json.dumps(os.environ['DM_SHELL_PACKAGE'] + '/GameTunnel')
(root / 'Cargo.toml').write_text(f'''[package]
name = "nxkit-shell-native"
version = "0.1.0"
edition = "2024"
publish = false
[workspace]
[lib]
name = "nxkit_host"
crate-type = ["staticlib"]
[dependencies]
nxkit-runtime = {{ package = "nxkit-host", path = {runtime} }}
nxkit-producer-ffi = {{ path = {producer} }}
nx-game-tunnel = {{ path = {tunnel} }}
''')
(root / 'src/lib.rs').write_text('extern crate nxkit_runtime;\nextern crate nxkit_producer_ffi;\nextern crate nx_game_tunnel;\n')
NATIVE
# Seed dependency versions from the patched upstream lock, then resolve local wrapper packages.
cp "$NXKIT_SOURCE/Cargo.lock" "$S/Native/Cargo.lock"
cargo metadata --manifest-path "$S/Native/Cargo.toml" --format-version 1 > /dev/null
# Rust reports transitive Apple frameworks and native libraries; do not maintain a second list.
cargo rustc --manifest-path "$S/Native/Cargo.toml" --locked --release \
  --target "$RUST_TARGET" --target-dir "$S/Rust" --lib \
  -- --print native-static-libs 2>&1 | tee "$S/runtime-build.log"
[ -s "$NXKIT_ARTIFACT_DIR/libnxkit_host.a" ]
mkdir -p "$S/Gen/dm" "$S/Gen/Assets.xcassets"
printf '{"info":{"author":"xcode","version":1}}\n' > "$S/Gen/Assets.xcassets/Contents.json"
ln -sfn "$ROOT/App" "$S/Shell"
python3 -I - "$ROOT/project-shell.yml" "$S" <<'PY'
import json, os, pathlib, re, sys
source, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
revision = os.environ['NXKIT_RUNTIME_REVISION']
abi = int(os.environ['NXKIT_RUNTIME_ABI'])
if not re.fullmatch(r'[0-9a-f]{40}', revision) or abi <= 0:
    sys.exit('Runtime identity must be a 40-character revision and a positive ABI.')
flags = re.findall(r'native-static-libs: (.+)', (out / 'runtime-build.log').read_text())
if not flags:
    sys.exit('Rust did not report native-static-libs; cannot link the runtime safely.')
text = source.read_text()
text = text.replace('      - path: Gen/Assets.xcassets',
    '      - path: ${DM_SHELL_PACKAGE}/GameTunnel/Notices\n'
    '        type: folder\n'
    '        buildPhase: resources\n'
    '      - path: Gen/Assets.xcassets')
text = text.replace('packages:\n', 'packages:\n  GameRuntime:\n    path: ${DM_SHELL_PACKAGE}/GameRuntime\n')
text = text.replace('    dependencies:\n', '    dependencies:\n      - package: GameRuntime\n        product: GameRuntime\n')
text = text.replace('        CFBundleDisplayName:', '''        CFBundleDocumentTypes:
          - CFBundleTypeName: NX Binary
            CFBundleTypeRole: Viewer
            LSHandlerRank: Owner
            LSItemContentTypes: [org.nxkit.nxb]
        UTExportedTypeDeclarations:
          - UTTypeIdentifier: org.nxkit.nxb
            UTTypeDescription: NX Binary
            UTTypeConformsTo: [public.data, public.archive]
            UTTypeTagSpecification:
              public.filename-extension: [nxb]
        CFBundleDisplayName:''')
text = text.replace('        CFBundleDisplayName:', f'        NXKitRuntimeRevision: "{revision}"\n        NXKitRuntimeABI: {abi}\n        CFBundleDisplayName:')
text = '\n'.join(line for line in text.splitlines() if '# @FRAMEWORKS@' not in line) + '\n'
if os.environ['SHELL_PLATFORM'] == 'maccatalyst':
    # Xcode resolves the default Keychain group from the selected signing profile.
    text = text.replace('    settings:\n',
        '    entitlements:\n'
        '      path: Gen/DmShell.entitlements\n'
        '      properties:\n'
        '        keychain-access-groups: ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"]\n'
        '    settings:\n')
    text = text.replace('@executable_path/Frameworks', '@executable_path/../Frameworks')
    text = text.replace('-mcpu=apple-a18', '-mcpu=apple-m1')
    text = text.replace('      TARGETED_DEVICE_FAMILY:',
        '      SUPPORTS_MACCATALYST: YES\n'
        '      DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO\n'
        '      MACOSX_DEPLOYMENT_TARGET: "26.0"\n'
        '      ARCHS: arm64\n'
        '      TARGETED_DEVICE_FAMILY:')
(out / 'project.yml').write_text(text)
archive_dir = os.environ['NXKIT_ARTIFACT_DIR']
(out / 'Gen/dm.xcconfig').write_text(
    f'LIBRARY_SEARCH_PATHS = $(inherited) "{archive_dir}"\n'
    f'OTHER_LDFLAGS = $(inherited) -lnxkit_host {flags[-1]}\n'
    f'SWIFT_INCLUDE_PATHS = $(inherited) "{os.environ["NXKIT_BUILDER_SOURCE"]}/include" "{os.environ["DM_SHELL_PACKAGE"]}/GameTunnel/include"\n')
PY
cd "$S"
xcodegen generate
if [ "$MODE" != --prepare-xcode ]; then
  SIGNING=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
  if [ "$SHELL_PLATFORM" = maccatalyst ] && [ "$MODE" = --build ]; then
    SIGNING=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES "CODE_SIGN_IDENTITY=$DM_SIGNING_IDENTITY")
  fi
  xcodebuild -project DmShell.xcodeproj -scheme DmShell -configuration Release \
    -destination "$DESTINATION" -derivedDataPath "$S/dd" \
    "${SIGNING[@]}" build \
    > "$S/build.log" 2>&1
  if [ "$SHELL_PLATFORM" = maccatalyst ]; then
    APP="$S/dd/Build/Products/Release-maccatalyst/DmShell.app"
    if [ "$MODE" = --build-unsigned ]; then
      echo "Unsigned validation build only: $APP (not for installation or distribution)"
      exit 0
    fi
    codesign --verify --strict "$APP"
    ditto --norsrc "$APP" "$S/DmShell.app"
    echo "Signed Mac shell: $S/DmShell.app"
    echo 'Payload signing and loading still require validation on the target Mac.'
    exit 0
  fi
  APP="$S/dd/Build/Products/Release-iphoneos/DmShell.app"
  STAGE=$(mktemp -d "$S/ipa.XXXXXX")
  trap 'rm -rf "$STAGE"' EXIT
  mkdir "$STAGE/Payload"
  ditto --norsrc "$APP" "$STAGE/Payload/DmShell.app"
  ditto -c -k --norsrc --keepParent "$STAGE/Payload" "$STAGE/DmShell.ipa"
  mv "$STAGE/DmShell.ipa" "$S/DmShell.ipa"
  echo "Unsigned app: $APP"
  echo "Unsigned IPA (sign before installing): $S/DmShell.ipa"
else
  echo "Prepared: $S/DmShell.xcodeproj (select your signing team and device in Xcode)"
fi
