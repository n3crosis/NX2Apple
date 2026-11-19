# Catalyst end-to-end NXB build and import

Use the signed Catalyst `DmShell.app` from the checkout under test. The bundled Terminal script delegates to the app's own executable, so no wrapper installation, Xcode, or source checkout is needed to invoke a built app. The desktop `nxb` tool does not exercise the Catalyst importer.

On an approved Mac, quit the GUI app before using these commands. They share the same library and signing storage. Use a test library and an unlocked login session. Define the Terminal command:

```sh
bundle="/Applications/NX2Apple.app"  # Use the actual path for an unpacked DmShell.app.
cli() { /bin/sh "$bundle/Contents/Resources/nx2apple.sh" "$@"; }
cli --help
```

Before using credentials, verify the exact distributed app's file access with a harmless probe. Replace the probe directory with the one you intend to use for inputs:

```sh
codesign -d --entitlements :- "$bundle"
probe_dir=$(mktemp -d "$HOME/Downloads/nx2apple-probe.XXXXXX")
printf 'not an NXB\n' > "$probe_dir/probe.nxb"
cli import "$probe_dir/probe.nxb" --json
rm "$probe_dir/probe.nxb"
rmdir "$probe_dir"
```

On a runtime-enabled build, expect `invalid_package` for the readable probe. `input_unreadable` means the app could not open a regular file at that path. Terminal access is not app access. If the signed build has App Sandbox enabled, paths passed as arguments do not receive the file access grants that a system file picker can provide. Do not disable sandboxing just to make the probe pass.

Configure signing and keys in the app or run:

```sh
cli set-signing "/path/to/identity.p12" "/path/to/profile.mobileprovision"
cli set-prod-keys "/path/to/prod.keys"
cli build "/path/to/base-game.nsp" "/path/to/new-game.nxb" --json
```

The app prompts for the P12 password without echo. Never pass the password in arguments or the environment. The signing identity must match the certificate that signed this app. `prod.keys` is not needed to import a prebuilt package.

The build also accepts a base `.xci`. It uses the same builder and runtime identity as the GUI. Build reports phases and substeps. Watch shader resource indexing, module and resource scans, shader-job preparation, and actual completed shader jobs. The resource-copy and archive-write steps also have real counts. A single operation without an exposed total shows a label instead of a guessed percentage. JSON progress includes `stage`, optional `detail`, and measured `completed` / `total` when available. A final `built` event and exit status 0 mean a publisher-signed NXB was written. Nothing is added to the library until import. Use an output folder the app can write to on a filesystem that supports hard links. The app checks this before building or exporting and reports `output_unavailable` if the folder cannot publish safely. A build must not overwrite an existing file or alter a saved GUI build job. Press Ctrl-C during a build to cancel at a safe stage boundary. Check for exit 130 and no new output file. A native stage already in progress may need to finish first.

```sh
cli import "/path/to/new-game.nxb"
cli import "/path/to/another-test-game.nxb" --json
```

Terminal verification progress uses measured bytes. Signing and installation report real stage changes without inventing a percentage. With `--json`, standard output contains one JSON object per line and ends with an `installed` or `error` event for a started import. Success means the normal installer has activated the game, not just started reading it. Unsigned packages and packages from unknown publishers are rejected unless explicitly allowed with `--allow-untrusted`. Only use that flag for a known local test package. Import never replaces an installed game.

For the signed release smoke test, use the unpacked app from a path that contains spaces. First configure an identity in the GUI, quit, and verify that separate Terminal build and import invocations reuse that saved identity without setup. Check a valid compatible package, a duplicate, and an invalid or incompatible package. For the no-overwrite check, point a build at a disposable existing .nxb containing a sentinel, expect `output_exists`, and verify the sentinel is unchanged. For the output-folder check, target a writable volume without hard-link support and expect `output_unavailable` before any build progress. Verify a failure leaves the library unchanged, then reopen the GUI to check the new entry. Finder opens still show the normal import preview. Launching the imported game on an iPhone is a separate check. Never commit or log keys, credential paths, or game files. Do not run on the user's Mac, in CI, or in the simulator against their current instructions.


## List, export, and share

```sh
cli list --json
cli export 010020D01AD24000 "/path/to/animal-well.nxb"
cli share 010020D01AD24000
cli share "/path/to/animal-well.nxb" --external
```

List and export work on installed NXB games, not legacy framework-only titles. Export signs a new archive and never overwrites an existing file. Share accepts an installed title ID or a signed standalone NXB. Local sharing is the default. External sharing uses Cloudflare and must be requested explicitly. The App-opening QR code and pasteable link are separate. Links and QR codes include the credential: do not pipe or log them unless the recipient is authorized. The Terminal process must remain running. Ctrl-C revokes the invitation, and links expire after at most one hour. Scanning opens the receiving sheet with the link filled in. It does not start a transfer.


## Read-only diagnostics and receive

```sh
cli version --json
cli status --json
cli inspect "/path/to/new-game.nxb"
cli verify "/path/to/new-game.nxb" --require-compatible --json
cli build "/path/to/base.nsp" "/path/to/new-output.nxb" --update "/path/to/update.nsp" --dlc "/path/to/add-on.nsp"
cli receive - --json < "/path/to/private-invitation.txt"
```

`status` reports whether the saved signing identity is valid, whether the build keys are accessible, and which runtime is embedded. It does not print secrets or paths. `inspect` reads package metadata, while `verify` reads and hashes the payload without installing. Verification reports trust and compatibility separately. With `--require-compatible`, it returns nonzero when this runtime cannot load the package. An unsigned or unknown publisher is not described as trusted just because its payload matches its manifest.

`receive` accepts a pasteable invitation or an NX2Apple receive link. Using `-` with a pipe or redirected private file keeps the link out of process arguments. Add `--external` only for an internet link. Publisher trust and runtime compatibility are checked before downloading the payload. An unknown or unsigned publisher requires `--allow-untrusted`; only use it for a known source. Received files are verified and installed directly without creating an intermediate NXB. No existing title is replaced. Ctrl-C stops a long operation at a safe boundary. JSON events go to stdout.
