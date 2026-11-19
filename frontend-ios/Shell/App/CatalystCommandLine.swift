#if targetEnvironment(macCatalyst)
import Darwin
import Dispatch
import Foundation
import ShellHost

/// Terminal commands enter the same signed executable, not a second signing tool.
@objc(ShellCommandLine)
@MainActor final class ShellCommandLine: NSObject {
    private enum Command {
        case importGame(URL, json: Bool, allowUntrusted: Bool)
        case build(URL, output: URL, updates: [URL], dlc: [URL], json: Bool)
        case inspect(URL, verify: Bool, requireCompatible: Bool, json: Bool)
        case receive(String, external: Bool, allowUntrusted: Bool, json: Bool)
        case status(json: Bool)
        case version(json: Bool)
        case list(json: Bool)
        case export(String, output: URL, json: Bool)
        case share(String, remote: Bool, json: Bool)
        case signing(URL, URL)
        case keys(URL)

        var requiresLibraryLock: Bool {
            switch self {
            case .inspect, .status, .version: false
            default: true
            }
        }
    }

    /// Held for both GUI and command-line sessions so neither races a live library.
    private static var libraryLock: Int32 = -1
    private static var commandInterrupt: (any DispatchSourceSignal)?

    @objc static func handleLaunch() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let verb = arguments.first
        if verb == "--help" || verb == "-h" || verb == "help" {
            output(usage, to: .standardOutput)
            exit(0)
        }
        let cli = ["import", "build", "list", "export", "share", "inspect", "verify", "receive", "status", "version", "--version", "set-signing", "set-prod-keys"].contains(verb ?? "")
        if cli { _ = signal(SIGPIPE, SIG_IGN) }
        let command = cli ? parse(arguments) : nil
        let wantsJSON = cli && arguments.dropFirst().contains("--json")
        if cli && command == nil {
            if wantsJSON {
                Reporter(json: true).failure("invalid_arguments", "Invalid arguments. Run nx2apple.sh --help.")
            } else {
                output(usage, to: .standardError)
            }
            exit(64)
        }
        do { if command?.requiresLibraryLock != false { try lockLibrary() } }
        catch {
            Reporter(json: wantsJSON).failure("library_unavailable",
                "NX2Apple is already open or its library is unavailable. Quit the app and retry.")
            exit(75)
        }
        guard let command else { return }
        let task = Task { @MainActor in
            let code = await run(command)
            exit(code)
        }
        switch command {
        case .build, .export, .share, .inspect, .receive, .importGame:
            // Cancel cooperatively so writers can remove staging and a share
            // can revoke its invitation before this process exits.
            _ = signal(SIGINT, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            interrupt.setEventHandler { task.cancel() }
            commandInterrupt = interrupt
            interrupt.resume()
        default: break
        }
        dispatchMain()
    }

    private static let usage = """
    NX2Apple commands (quit the app before running):
      DmShell help | version [--json]
      DmShell status [--json]
      DmShell build <game.nsp|game.xci|game.nsz|game.xcz|game.nup> <output.nxb> [--update <file>] [--dlc <file>] [--json]
      DmShell inspect <game.nxb> [--json]
      DmShell verify <game.nxb> [--require-compatible] [--json]
      DmShell import <game.nxb> [--json] [--allow-untrusted]
      DmShell list [--json]
      DmShell export <title-id> <output.nxb> [--json]
      DmShell share <title-id|game.nxb> [--local|--external] [--json]
      DmShell receive <link|-> [--external] [--allow-untrusted] [--json]
      DmShell set-signing <identity.p12> <profile.mobileprovision>
      DmShell set-prod-keys <prod.keys>
    """

    private static func parse(_ arguments: [String]) -> Command? {
        func file(_ path: String) -> URL { URL(fileURLWithPath: path).standardizedFileURL }
        switch arguments.first {
        case "import" where arguments.count >= 2:
            let flags = Set(arguments.dropFirst(2))
            guard !arguments[1].hasPrefix("-"), file(arguments[1]).pathExtension.lowercased() == "nxb",
                  flags.count == arguments.count - 2,
                  flags.isSubset(of: ["--json", "--allow-untrusted"]) else { return nil }
            return .importGame(file(arguments[1]), json: flags.contains("--json"),
                               allowUntrusted: flags.contains("--allow-untrusted"))
        case "build" where arguments.count >= 3:
            let source = file(arguments[1]), target = file(arguments[2])
            guard !arguments[1].hasPrefix("-"), !arguments[2].hasPrefix("-"),
                  buildExtensions.contains(source.pathExtension.lowercased()),
                  target.pathExtension.lowercased() == "nxb" else { return nil }
            var updates: [URL] = [], dlc: [URL] = []
            var json = false
            var index = 3
            while index < arguments.count {
                let option = arguments[index]
                if option == "--json", !json {
                    json = true
                    index += 1
                } else {
                    guard (option == "--update" || option == "--dlc"), index + 1 < arguments.count,
                          updates.count + dlc.count < 128, !arguments[index + 1].hasPrefix("-") else { return nil }
                    let input = file(arguments[index + 1])
                    guard buildExtensions.contains(input.pathExtension.lowercased()) else { return nil }
                    if option == "--update" { updates.append(input) } else { dlc.append(input) }
                    index += 2
                }
            }
            return .build(source, output: target, updates: updates, dlc: dlc, json: json)
        case "inspect", "verify":
            guard arguments.count >= 2, !arguments[1].hasPrefix("-"),
                  file(arguments[1]).pathExtension.lowercased() == "nxb" else { return nil }
            let flags = Set(arguments.dropFirst(2))
            let verify = arguments[0] == "verify"
            guard flags.count == arguments.count - 2,
                  flags.isSubset(of: verify ? ["--json", "--require-compatible"] : ["--json"]) else { return nil }
            return .inspect(file(arguments[1]), verify: verify, requireCompatible: flags.contains("--require-compatible"),
                            json: flags.contains("--json"))
        case "receive" where arguments.count >= 2:
            let flags = Set(arguments.dropFirst(2))
            guard arguments[1] == "-" || !arguments[1].hasPrefix("-"),
                  flags.count == arguments.count - 2,
                  flags.isSubset(of: ["--external", "--allow-untrusted", "--json"]) else { return nil }
            return .receive(arguments[1], external: flags.contains("--external"),
                            allowUntrusted: flags.contains("--allow-untrusted"), json: flags.contains("--json"))
        case "status" where arguments.count == 1 || arguments == ["status", "--json"]:
            return .status(json: arguments.count == 2)
        case "version", "--version":
            guard arguments.count == 1 || arguments == ["version", "--json"] else { return nil }
            return .version(json: arguments.count == 2)
        case "list" where arguments.count == 1 || arguments == ["list", "--json"]:
            return .list(json: arguments.count == 2)
        case "export" where (3...4).contains(arguments.count):
            guard let id = titleID(arguments[1]), !arguments[2].hasPrefix("-"),
                  file(arguments[2]).pathExtension.lowercased() == "nxb",
                  arguments.count == 3 || arguments[3] == "--json" else { return nil }
            return .export(id, output: file(arguments[2]), json: arguments.count == 4)
        case "share" where arguments.count >= 2:
            let flags = Set(arguments.dropFirst(2))
            guard !arguments[1].hasPrefix("-"),
                  titleID(arguments[1]) != nil || file(arguments[1]).pathExtension.lowercased() == "nxb",
                  flags.count == arguments.count - 2,
                  flags.isSubset(of: ["--local", "--external", "--json"]),
                  !(flags.contains("--local") && flags.contains("--external")) else { return nil }
            return .share(arguments[1], remote: flags.contains("--external"), json: flags.contains("--json"))
        case "set-signing" where arguments.count == 3:
            guard !arguments[1].hasPrefix("-"), !arguments[2].hasPrefix("-") else { return nil }
            return .signing(file(arguments[1]), file(arguments[2]))
        case "set-prod-keys" where arguments.count == 2:
            guard !arguments[1].hasPrefix("-") else { return nil }
            return .keys(file(arguments[1]))
        default:
            return nil
        }
    }

    private static let buildExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup"]

    private static func titleID(_ value: String) -> String? {
        let id = value.uppercased()
        guard value.utf8.count == 16, id.utf8.count == 16,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        return id
    }

    private static var library: GamePackageLibrary {
        let root = ShellHostConfig.defaultAppDataRoot().deletingLastPathComponent()
        return GamePackageLibrary(root: root.appendingPathComponent("NXB", isDirectory: true))
    }

    private static func lockLibrary() throws {
        let root = ShellHostConfig.defaultAppDataRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(".nx2apple-session.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_uid == geteuid(),
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw CocoaError(.fileWriteNoPermission)
        }
        // Keep the descriptor open until process exit. Never unlink a held lock.
        libraryLock = fd
    }

    private static func run(_ command: Command) async -> Int32 {
        switch command {
        case .importGame(let file, let json, let allowUntrusted):
            return await importGame(file, allowUntrusted: allowUntrusted, reporter: Reporter(json: json))
        case .build(let file, let destination, let updates, let dlc, let json):
            return await buildGame(file, to: destination, updates: updates, dlc: dlc, reporter: Reporter(json: json))
        case .inspect(let file, let verify, let requireCompatible, let json):
            return await inspectGame(file, verify: verify, requireCompatible: requireCompatible, reporter: Reporter(json: json))
        case .receive(let input, let external, let allowUntrusted, let json):
            return await receiveGame(input, external: external, allowUntrusted: allowUntrusted, reporter: Reporter(json: json))
        case .status(let json):
            let reporter = Reporter(json: json)
            reporter.status(signing: await signingStatus(),
                            keys: (try? ShellCommandLineSetup.buildKeysURL()).map { canOpenInput($0) } ?? false,
                            runtime: runtimeAvailable)
            return 0
        case .version(let json):
            Reporter(json: json).version()
            return 0
        case .list(let json):
            let reporter = Reporter(json: json)
            reporter.list(library.entries())
            return 0
        case .export(let id, let destination, let json):
            return await exportGame(id, to: destination, reporter: Reporter(json: json))
        case .share(let input, let remote, let json):
            let reporter = Reporter(json: json)
            if let id = titleID(input) {
                guard let entry = library.entries().first(where: { $0.id == id }) else {
                    reporter.failure("game_not_found", "No installed NXB game has that title ID. Run list to check.")
                    return 1
                }
                return await CatalystShareCommand.run(directory: entry.directory, remote: remote, json: json)
            }
            let archive = URL(fileURLWithPath: input).standardizedFileURL
            guard canOpenInput(archive) else {
                reporter.failure("input_unreadable", "The app cannot read that NXB.")
                return 66
            }
            return await CatalystShareCommand.run(directory: archive.deletingLastPathComponent(),
                                                  archive: archive, remote: remote, json: json)
        case .signing(let p12, let profile):
            guard canOpenInput(p12), canOpenInput(profile) else {
                output("The app cannot read the P12 or provisioning profile. Check the paths and app file access.", to: .standardError)
                return 66
            }
            guard let password = dm_shell_read_cli_password() else {
                output("A terminal is required to enter the P12 password.", to: .standardError)
                return 1
            }
            do {
                try await ShellCommandLineSetup.importSigningIdentity(pkcs12: p12, profile: profile, password: password)
                output("Signing identity saved.", to: .standardOutput)
                return 0
            } catch {
                output("Could not save the signing identity. Check the password, profile and app signing certificate.", to: .standardError)
                return 1
            }
        case .keys(let file):
            guard canOpenInput(file) else {
                output("The app cannot read prod.keys. Check the path and app file access.", to: .standardError)
                return 66
            }
            do {
                try await ShellCommandLineSetup.importBuildKeys(from: file)
                output("prod.keys saved.", to: .standardOutput)
                return 0
            } catch {
                output("Could not save prod.keys. Check the file and its permissions.", to: .standardError)
                return 1
            }
        }
    }

    private static var runtimeAvailable: Bool {
        #if canImport(GameRuntime)
        NXKitGameLauncher.shared != nil
        #else
        false
        #endif
    }

    private static func signingStatus() async -> String {
        do { try await ShellCommandLineSetup.validateSigningIdentity(); return "ready" }
        catch let error as ShellSigningIdentityStore.Failure {
            switch error {
            case .missing: return "missing"
            case .locked, .storage: return "unavailable"
            case .expired: return "expired"
            case .signerMismatch, .certificateNotInProfile: return "mismatch"
            case .invalid, .hostSignatureUnavailable: return "invalid"
            }
        } catch { return "unavailable" }
    }

    private static func inspectGame(_ file: URL, verify: Bool, requireCompatible: Bool, reporter: Reporter) async -> Int32 {
        guard canOpenInput(file) else {
            reporter.failure("input_unreadable", "The app cannot read the NXB file.")
            return 66
        }
        let work = Task.detached(priority: .userInitiated) {
            let check: GamePackage.VerifyPublisher = { try GamePackageSignature.verify(manifest: $0, proof: $1) }
            if verify {
                return try GamePackage.verifyArchive(file, verifyPublisher: check) {
                    reporter.verifiedBytes($0, total: $1)
                }
            }
            return try GamePackage.inspect(file, verifyPublisher: check)
        }
        do {
            let preview = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            let compatible: Bool?
            #if canImport(GameRuntime)
            if let runtime = NXKitGameLauncher.shared {
                compatible = (try? runtime.checkCompatibility(preview.manifest)) != nil
            } else { compatible = nil }
            #else
            compatible = nil
            #endif
            reporter.package(preview, verified: verify, compatible: compatible)
            if requireCompatible, compatible != true {
                reporter.failure("incompatible_runtime", "This NXB cannot run on this build of NX2Apple.")
                return 1
            }
            return 0
        } catch is CancellationError {
            reporter.failure("cancelled", "Verification cancelled.")
            return 130
        } catch {
            reporter.failure("invalid_package", "The NXB failed inspection or integrity verification.")
            return 1
        }
    }

    private static func importGame(_ file: URL, allowUntrusted: Bool, reporter: Reporter) async -> Int32 {
        guard canOpenInput(file) else {
            reporter.failure("input_unreadable", "The app cannot read the NXB file. Check the path and app file access.")
            return 66
        }
        #if canImport(GameRuntime)
        guard let runtime = NXKitGameLauncher.shared else {
            reporter.failure("runtime_unavailable", "The nxkit runtime is not available in this build.")
            return 1
        }
        let model = ShellLibrary.makeModel(packageLauncher: runtime, commandLineMode: true)
        do {
            let entry = try await model.importPackageFromCommandLine(file, allowUntrusted: allowUntrusted,
                progressBytes: { reporter.verifiedBytes($0, total: $1) }) { reporter.progress($0) }
            reporter.success(entry.id)
            return 0
        } catch {
            let result = Reporter.importFailure(error)
            reporter.failure(result.0, result.1)
            return result.0 == "cancelled" ? 130 : 1
        }
        #else
        reporter.failure("runtime_unavailable", "The nxkit runtime is not available in this build.")
        return 1
        #endif
    }

    private static func receiveGame(_ input: String, external: Bool, allowUntrusted: Bool, reporter: Reporter) async -> Int32 {
        #if canImport(GameRuntime)
        guard let runtime = NXKitGameLauncher.shared else {
            reporter.failure("runtime_unavailable", "The nxkit runtime is not available in this build.")
            return 1
        }
        let text: String
        if input == "-" {
            // Invitations carry a bearer credential. Scripts can supply one on
            // stdin instead of placing it in argv or shell history.
            do {
                guard isatty(STDIN_FILENO) == 0 else { throw CocoaError(.fileReadCorruptFile) }
                text = try await readInvitationLine().trimmingCharacters(in: .whitespacesAndNewlines)
            } catch is CancellationError {
                reporter.failure("cancelled", "Receive cancelled. No game was installed.")
                return 130
            } catch {
                reporter.failure("invalid_invitation", "Pipe one sharing link into receive -.")
                return 64
            }
        } else { text = input }
        guard !text.isEmpty, text.utf8.count <= 4096, let invitation = URL(string: text) else {
            reporter.failure("invalid_invitation", "Paste a local or external NX2Apple sharing link.")
            return 64
        }
        let model = ShellLibrary.makeModel(packageLauncher: runtime, commandLineMode: true)
        do {
            let progress = ReceiveProgress(reporter: reporter, stage: "receiving", label: "Receiving")
            let verification = ReceiveProgress(reporter: reporter, stage: PackageImportStage.readingAndVerifying.rawValue, label: "Verifying")
            let https = CatalystHTTPSTransport()
            let entry = try await model.receivePackageFromCommandLine(invitation, allowExternal: external,
                allowUntrusted: allowUntrusted, remoteTransport: { url, token, limit in
                    try await https.get(url, authorization: token, maximumBytes: limit)
                }, transferProgress: { progress.report($0, total: $1) },
                verificationProgress: { verification.report($0, total: $1) },
                progress: { reporter.progress($0) })
            reporter.success(entry.id)
            return 0
        } catch ShellCommandLineReceive.Failure.externalPermissionRequired {
            reporter.failure("external_permission_required", "Receiving an external link requires --external.")
            return 64
        } catch ShellCommandLineReceive.Failure.untrustedPackage {
            reporter.failure("untrusted_package", "The publisher is not trusted. Use --allow-untrusted only for a known source.")
            return 1
        } catch let error as PackageCommandLineImportError {
            let (code, message) = Reporter.importFailure(error)
            reporter.failure(code, message)
            return 1
        } catch is CancellationError {
            reporter.failure("cancelled", "Receive cancelled. No game was installed.")
            return 130
        } catch {
            if Task.isCancelled {
                reporter.failure("cancelled", "Receive cancelled. No game was installed.")
                return 130
            }
            reporter.failure("receive_failed", "Could not receive the package. Check the link and network connection.")
            return 1
        }
        #else
        reporter.failure("runtime_unavailable", "The nxkit runtime is not available in this build.")
        return 1
        #endif
    }

    private static func readInvitationLine() async throws -> String {
        // Keep the main queue free to deliver SIGINT when a producer leaves the
        // pipe open without writing a full line. The worker checks cancellation
        // even if stdin never becomes readable.
        let input = Task.detached(priority: .userInitiated) { () throws -> String in
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            var buffer = [UInt8](repeating: 0, count: 4097)
            var data = Data()
            while data.count < buffer.count {
                try Task.checkCancellation()
                let ready = poll(&descriptor, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0, descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let limit = buffer.count - data.count
                let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, limit) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                if count == 0 { break }
                let chunk = buffer.prefix(count)
                if let newline = chunk.firstIndex(of: 10) {
                    data.append(contentsOf: chunk.prefix(upTo: newline))
                    break
                }
                data.append(contentsOf: chunk)
            }
            try Task.checkCancellation()
            guard data.count <= 4096, let string = String(data: data, encoding: .utf8), !string.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return string
        }
        return try await withTaskCancellationHandler { try await input.value } onCancel: { input.cancel() }
    }

    private final class ReceiveProgress: @unchecked Sendable {
        private let lock = NSLock()
        private let reporter: Reporter
        private let stage: String
        private let label: String
        private var last: UInt64 = 0

        init(reporter: Reporter, stage: String, label: String) {
            self.reporter = reporter
            self.stage = stage
            self.label = label
        }
        func report(_ done: UInt64, total: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            guard done > last, done - last >= 8 << 20 || done == total else { return }
            last = done
            reporter.verifiedBytes(done, total: total, stage: stage, label: label)
        }
    }

    private static func exportGame(_ id: String, to destination: URL, reporter: Reporter) async -> Int32 {
        let library = Self.library
        guard let entry = library.entries().first(where: { $0.id == id }) else {
            reporter.failure("game_not_found", "No installed NXB game has that title ID. Run list to check.")
            return 1
        }
        let fm = FileManager.default
        guard let staged = prepareOutput(at: destination, reporter: reporter) else { return 1 }
        defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
        reporter.signingProgress()
        let export = Task.detached(priority: .userInitiated) {
            try library.exportForSharing(entry, to: staged) { done, total in
                reporter.signingProgress(done, total: total)
            }
        }
        do {
            try await withTaskCancellationHandler { try await export.value } onCancel: { export.cancel() }
            try Task.checkCancellation()
        } catch is CancellationError {
            reporter.failure("cancelled", "Export cancelled. No NXB was published.")
            return 130
        } catch {
            reporter.failure("export_failed", "Could not export the signed NXB. Check the game, signing setup, and free space.")
            return 1
        }
        guard publish(staged, to: destination, reporter: reporter) else { return 1 }
        reporter.exported(id)
        return 0
    }

    private static func prepareOutput(at destination: URL, reporter: Reporter) -> URL? {
        let outputStage = destination.deletingLastPathComponent()
            .appendingPathComponent(".nx2apple-output-" + UUID().uuidString, isDirectory: true)
        // Stage the finished archive in the destination directory so publishing
        // uses an atomic, no-clobber link on the same filesystem.
        var existing = stat()
        if lstat(destination.path, &existing) == 0 {
            reporter.failure("output_exists", "The output already exists. Choose a new NXB path.")
            return nil
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: outputStage, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            reporter.failure("output_unavailable", "The app cannot write to the output directory.")
            return nil
        }
        // Check the same filesystem now, before compiling or signing a game.
        let probe = outputStage.appendingPathComponent(".probe")
        let probeLink = outputStage.appendingPathComponent(".probe-link")
        guard fm.createFile(atPath: probe.path, contents: Data(), attributes: [.posixPermissions: 0o600]),
              link(probe.path, probeLink.path) == 0 else {
            try? fm.removeItem(at: outputStage)
            reporter.failure("output_unavailable", "The output folder does not support safe publication. Choose a writable folder on a filesystem that supports hard links.")
            return nil
        }
        try? fm.removeItem(at: probeLink)
        try? fm.removeItem(at: probe)
        return outputStage.appendingPathComponent("game.nxb")
    }

    private static func publish(_ staged: URL, to destination: URL, reporter: Reporter) -> Bool {
        if link(staged.path, destination.path) == 0 { return true }
        if errno == EEXIST {
            reporter.failure("output_exists", "The output already exists. Choose a new NXB path.")
        } else {
            reporter.failure("output_unavailable", "The app could not publish the NXB at the output path.")
        }
        return false
    }

    private static func buildGame(_ input: URL, to destination: URL, updates: [URL], dlc: [URL], reporter: Reporter) async -> Int32 {
        #if canImport(NxkitBuilder) && canImport(GameRuntime)
        guard NXKitGameLauncher.shared != nil else {
            reporter.failure("runtime_unavailable", "The nxkit runtime is not available in this build.")
            return 1
        }
        guard ([input] + updates + dlc).allSatisfy({ canOpenInput($0) }) else {
            reporter.failure("input_unreadable", "The app cannot read the game file. Check the path and app file access.")
            return 66
        }
        guard let keys = try? ShellCommandLineSetup.buildKeysURL() else {
            reporter.failure("keys_missing", "Run set-prod-keys before building a game.")
            return 1
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("nx2apple-build-" + UUID().uuidString, isDirectory: true)
        guard let staged = prepareOutput(at: destination, reporter: reporter) else { return 1 }
        defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            reporter.failure("workspace_unavailable", "The app could not create its temporary build directory.")
            return 1
        }
        defer { try? fm.removeItem(at: work) }
        do { try await ShellCommandLineSetup.validateSigningIdentity() }
        catch {
            if Task.isCancelled { return reporter.cancelledBuild() }
            reporter.failure("signing_identity", "Check your signing identity and unlock your Keychain before building.")
            return 1
        }
        let archive: URL
        do {
            try Task.checkCancellation()
            let request = try NXBBuilder.request(input: input, keys: keys, updates: updates, dlc: dlc, work: work)
            archive = try await NXBBuilder.prepare(request) { reporter.buildProgress($0) }
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled { return reporter.cancelledBuild() }
            reporter.failure("build_failed", "Game build failed. Check the source game and prod.keys.")
            return 1
        }
        reporter.signingProgress()
        do {
            let export = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try GamePackage.exportSigned(archive, to: staged, progress: { done, total in
                    reporter.signingProgress(done, total: total)
                }) {
                    try ShellSigningIdentityStore().signPackageManifest($0)
                }
            }
            try await withTaskCancellationHandler {
                try await export.value
            } onCancel: { export.cancel() }
        } catch {
            if Task.isCancelled { return reporter.cancelledBuild() }
            reporter.failure("export_failed", "Could not export the signed NXB. Check signing setup and free space.")
            return 1
        }
        if Task.isCancelled { return reporter.cancelledBuild() }
        guard publish(staged, to: destination, reporter: reporter) else { return 1 }
        reporter.built()
        return 0
        #else
        reporter.failure("builder_unavailable", "The nxkit builder is not available in this build.")
        return 1
        #endif
    }

    /// Test with the app's effective sandbox, not Terminal's permissions.
    /// The importer still opens and validates the file independently.
    private static func canOpenInput(_ file: URL) -> Bool {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var details = stat()
        return fstat(fd, &details) == 0 && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private nonisolated static func output(_ text: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data((text + "\n").utf8))
    }

    private struct Reporter: Sendable {
        let json: Bool

        func progress(_ stage: PackageImportStage) {
            let message: String
            switch stage {
            case .readingAndVerifying: message = "Reading and verifying package…"
            case .signing: message = "Signing game…"
            case .installing: message = "Installing game…"
            }
            if json { event(["event": "progress", "stage": stage.rawValue]) }
            else {
                let prefix = isatty(STDERR_FILENO) == 1 ? "\r\u{1B}[2K" : ""
                ShellCommandLine.output(prefix + message, to: .standardError)
            }
        }

        func buildProgress(_ progress: GameBuildProgress) {
            let label: (stage: String, message: String)
            switch progress.stage {
            case "inputs": label = ("inputs", "Copying game files")
            case "extract": label = ("extract", "Extracting game data")
            case "shaders": label = ("shaders", "Compiling shaders")
            case "analyze": label = ("analyze", "Analyzing game code")
            case "link": label = ("link", "Linking game binary")
            case "resources": label = ("resources", "Preparing game resources")
            case "archive": label = ("archive", "Packing game")
            case "prepared": label = ("prepared", "Game prepared")
            case "signing": label = ("signing", "Signing package for export")
            default: label = ("building", "Building game")
            }
            let count: String
            var fields: [String: Any] = ["event": "progress", "stage": label.stage]
            if let done = progress.completedFiles, let total = progress.totalFiles {
                count = " (\(done)/\(total))"
                fields["completed"] = done
                fields["total"] = total
                if progress.stage == "inputs" {
                    fields["completedFiles"] = done
                    fields["totalFiles"] = total
                }
            } else { count = "" }
            if let detail = progress.detail { fields["detail"] = detail }
            let description = label.message + (progress.detailLabel.map { " · " + $0 } ?? "")
            if json { event(fields) }
            else if isatty(STDERR_FILENO) == 1, let done = progress.completedFiles, let total = progress.totalFiles {
                let fraction = Double(done) / Double(total)
                let filled = min(24, max(0, Int(fraction * 24)))
                let bar = String(repeating: "#", count: filled) + String(repeating: "-", count: 24 - filled)
                let line = "\r\u{1B}[2K" + description + " [" + bar + "]" + count + (done == total ? "\n" : "")
                try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
            } else {
                let prefix = isatty(STDERR_FILENO) == 1 ? "\r\u{1B}[2K" : ""
                ShellCommandLine.output(prefix + description + count, to: .standardError)
            }
        }

        func signingProgress(_ done: Int? = nil, total: Int? = nil) {
            buildProgress(GameBuildProgress(stage: "signing", message: "",
                                            completedFiles: done, totalFiles: total, detail: total == nil ? nil : "archive"))
        }

        func cancelledBuild() -> Int32 {
            failure("cancelled", "Build cancelled. No NXB was published.")
            return 130
        }

        func version() {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            if json { event(["event": "version", "version": version, "cliProtocol": 1]) }
            else { ShellCommandLine.output("NX2Apple \(version) (CLI protocol 1)", to: .standardOutput) }
        }

        func status(signing: String, keys: Bool, runtime: Bool) {
            let revision = Bundle.main.object(forInfoDictionaryKey: "NXKitRuntimeRevision") as? String
            let abi = Bundle.main.object(forInfoDictionaryKey: "NXKitRuntimeABI") as? Int
            if json {
                var fields: [String: Any] = ["event": "status", "signing": signing, "buildKeysPresent": keys,
                                            "runtimeAvailable": runtime, "platform": "maccatalyst"]
                if let revision { fields["runtimeRevision"] = revision }
                if let abi { fields["runtimeABI"] = abi }
                event(fields)
            } else {
                ShellCommandLine.output("Signing: \(signing)\nBuild keys: \(keys ? "present" : "not available")\nRuntime: \(runtime ? "available" : "not available")", to: .standardOutput)
            }
        }

        func package(_ preview: GamePackage.Preview, verified: Bool, compatible: Bool?) {
            let m = preview.manifest
            let trust = preview.publisher.map { $0.trusted ? "trusted" : "untrusted" } ?? "unsigned"
            let compatibility = compatible.map { $0 ? "compatible" : "incompatible" } ?? "runtime_unavailable"
            if json {
                event(["event": verified ? "verified" : "inspected", "titleID": m.titleID, "name": m.name,
                       "publisherTrust": trust, "platform": m.platform, "runtimeABI": m.runtimeABI,
                       "runtimeRevision": m.runtimeRevision, "minOS": m.minOS, "compatibility": compatibility,
                       "manifestSHA256": preview.manifestSHA256, "files": m.files.count,
                       "payloadBytes": m.files.reduce(UInt64(0)) { $0 + $1.bytes }])
            } else {
                ShellCommandLine.output("\(m.titleID)  \(cleanName(m.name))\nPublisher: \(trust)\nRuntime: \(m.platform) ABI \(m.runtimeABI), \(compatibility)\nPayload: \(verified ? "verified" : "not fully verified")", to: .standardOutput)
            }
        }

        private func cleanName(_ name: String) -> String {
            let scalars = name.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
            }
            return String(String.UnicodeScalarView(scalars))
        }

        func list(_ games: [GamePackageLibrary.Entry]) {
            if json {
                event(["event": "games", "games": games.map { ["titleID": $0.id, "name": $0.manifest.name] }])
            } else if games.isEmpty {
                ShellCommandLine.output("No installed NXB games.", to: .standardOutput)
            } else {
                for game in games {
                    ShellCommandLine.output(game.id + "  " + cleanName(game.manifest.name), to: .standardOutput)
                }
            }
        }

        func exported(_ id: String) {
            if json { event(["event": "exported", "titleID": id]) }
            else { ShellCommandLine.output("Signed NXB exported.", to: .standardOutput) }
        }

        func built() {
            if json { event(["event": "built"]) }
            else { ShellCommandLine.output("Signed NXB exported.", to: .standardOutput) }
        }

        func success(_ titleID: String) {
            if json { event(["event": "installed", "titleID": titleID]) }
            else { ShellCommandLine.output("Installed \(titleID).", to: .standardOutput) }
        }

        func failure(_ code: String, _ message: String) {
            if json { event(["event": "error", "code": code, "message": message]) }
            else {
                let prefix = isatty(STDERR_FILENO) == 1 ? "\r\u{1B}[2K" : ""
                ShellCommandLine.output(prefix + message, to: .standardError)
            }
        }

        func verifiedBytes(_ done: UInt64, total: UInt64,
                           stage: String = PackageImportStage.readingAndVerifying.rawValue, label: String = "Verifying") {
            if json {
                event(["event": "bytes", "stage": stage,
                       "completed": done, "total": total])
            } else if isatty(STDERR_FILENO) == 1, total > 0 {
                let fraction = min(1, Double(done) / Double(total))
                let full = Int(fraction * 24)
                let bar = String(repeating: "#", count: full) + String(repeating: "-", count: 24 - full)
                let line = "\r" + label + " [\(bar)] \(Int(fraction * 100))%" + (done >= total ? "\n" : "")
                try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
            }
        }

        private func event(_ fields: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else { return }
            ShellCommandLine.output(line, to: .standardOutput)
        }

        static func importFailure(_ error: Error) -> (String, String) {
            if error is CancellationError { return ("cancelled", "Import cancelled.") }
            if let error = error as? PackageCommandLineImportError {
                let code: String
                switch error {
                case .busy: code = "library_busy"
                case .input: code = "invalid_package"
                case .untrusted: code = "untrusted_package"
                case .signingIdentity: code = "signing_identity"
                case .compatibility: code = "incompatible_runtime"
                case .alreadyInstalled: code = "already_installed"
                case .installation: code = "install_failed"
                }
                return (code, error.rawValue)
            }
            return ("import_failed", "Import failed. Check the package and signing setup.")
        }
    }
}
#endif
