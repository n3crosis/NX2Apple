import SwiftUI
import ShellUI
import UniformTypeIdentifiers

/// Native cancellation is cooperative at stage boundaries, never by killing a running compiler.
public typealias GamePackageBuild = @MainActor (URL, URL, [URL], [URL], URL, @escaping @Sendable (GameBuildProgress) -> Void) async throws -> URL

struct GamePackageBuildView: View {
    let build: GamePackageBuild
    let onBuilt: (URL) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var signingSummary: (team: String, expiration: Date)?
    @State private var configuringSigning = false
    private let signingStore = ShellSigningIdentityStore()
    @State private var input: URL?
    @State private var hasKeys = false
    @State private var importingKeys = false
    private let keyStore = GameBuildKeys()
    @State private var updates: [URL] = []
    @State private var dlc: [URL] = []
    @State private var selection = 0
    @State private var picking = false
    @State private var building = false
    @State private var buildTask: Task<Void, Never>?
    @State private var discarding = false
    @State private var installing = false
    @State private var progressRun: UUID?
    @State private var stageStartedAt: Date?
    @State private var failure: String?
    @State private var report = GameBuildReport()
    @State private var failedBuildReport: String?
    @State private var reportCopied = false
    @State private var job: GameBuildJob?
    @State private var hasSavedJob = false

    private var signingReady: Bool {
        guard let signingSummary else { return false }
        return signingSummary.expiration > Date()
    }

    private var types: [UTType] {
        (selection == 1 ? ["keys"] : ["nsp", "nsz", "xci", "xcz", "nup"])
            .compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { configuringSigning = true } label: {
                        HStack {
                            LabeledContent(hostText("Signing identity"),
                                           value: signingSummary?.team ?? hostText("Configure"))
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("builder.signingIdentity")
                    .disabled(building)
                } footer: {
                    if signingSummary == nil {
                        Text(hostText("Import a P12 certificate and provisioning profile before building games."))
                    } else if !signingReady {
                        Text(hostText("The provisioning profile is expired or invalid."))
                    }
                }
                Section {
                    fileButton(hostText("Game file"), value: job?.input.name ?? input?.lastPathComponent, selection: 0)
                        .disabled(hasSavedJob || building)
                    HStack {
                        fileButton("prod.keys", value: hasKeys ? "prod.keys" : nil, selection: 1)
                        if importingKeys { ProgressView() }
                        if hasKeys {
                            Button(role: .destructive) {
                                guard !GameBuildJob.running else { return }
                                do { try keyStore.remove(); hasKeys = keyStore.exists }
                                catch {
                                    failedBuildReport = nil
                                    failure = hostText("Could not remove prod.keys. Try again.")
                                }
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(hostText("Remove prod.keys"))
                        }
                    }.disabled(building || GameBuildJob.running)
                    if let job {
                        LabeledContent(hostText("Updates (optional)"), value: job.updates.map(\.name).joined(separator: ", "))
                        LabeledContent(hostText("DLC (optional)"), value: job.dlc.map(\.name).joined(separator: ", "))
                    } else {
                        optionalFiles(hostText("Updates (optional)"), files: $updates, selection: 2).disabled(building)
                        optionalFiles(hostText("DLC (optional)"), files: $dlc, selection: 3).disabled(building)
                    }
                } footer: {
                    Text(hostText("prod.keys is saved on this device for future builds and is never included in shared games. Keep this app open while building."))
                }
                Section {
                    Button {
                        guard buildTask == nil else { return }
                        buildTask = Task { await prepare(); buildTask = nil }
                    } label: {
                        HStack {
                            Text(hasSavedJob ? hostText("Resume build") : hostText("Build game"))
                            Spacer()
                            if building { ProgressView() }
                        }
                    }
                    .disabled(buildTask != nil || building || !signingReady || (input == nil && job == nil) || !hasKeys)
                    .accessibilityIdentifier("builder.build")
                }
                if hasSavedJob {
                    Section {
                        if let job {
                            Text(stageLabel(job.stage))
                                .accessibilityIdentifier("builder.stage")
                            if let detail = GameBuildProgress.detailLabel(stage: job.stage, detail: job.detail) {
                                Text(hostText(String.LocalizationValue(stringLiteral: detail))).font(.subheadline).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("builder.detail")
                            }
                            if building, let stageStartedAt {
                                HStack {
                                    Text(hostText("Time in current step"))
                                    Spacer()
                                    Text(stageStartedAt, style: .timer).monospacedDigit()
                                }.font(.footnote)
                            }
                            if let done = job.completedFiles, let total = job.totalFiles {
                                ProgressView(value: Double(done), total: Double(total))
                                LabeledContent(job.stage == "inputs" ? hostText("Files prepared") : hostText("Progress"), value: "\(done) / \(total)")
                                    .accessibilityIdentifier("builder.fileProgress")
                            } else if building {
                                VStack(alignment: .leading, spacing: 8) {
                                    ProgressView().progressViewStyle(.linear)
                                    Text(hostText("Waiting for this step to finish. Detailed progress is not available."))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            ScrollView {
                                Text(verbatim: job.logs.joined(separator: "\n"))
                                    .font(.footnote.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 180)
                        }
                        Button(hostText("Discard build"), role: .destructive) {
                            if building {
                                discarding = true
                                buildTask?.cancel()
                            } else {
                                Task { await discard() }
                            }
                        }.disabled(discarding || installing || (building && buildTask == nil))
                        if discarding { Text(hostText("Discarding after the current step…")) }
                    } footer: {
                        Text(hostText("Reopen Build games to resume. Completed file copies are kept. An interrupted compilation starts again."))
                    }
                }
                if let failure {
                    Section {
                        Text(verbatim: failure).textSelection(.enabled)
                        if let failedBuildReport {
                            Button {
                                ShellHostConfig.systemCopyToPasteboard(failedBuildReport)
                                reportCopied = true
                            } label: {
                                Label(reportCopied ? hostText("Build report copied") : hostText("Copy build report"),
                                      systemImage: reportCopied ? "checkmark" : "doc.on.doc")
                            }
                            .accessibilityIdentifier("builder.copyReport")
                        }
                    }
                }
            }
            .disabled(importingKeys)
            .scrollContentBackground(.hidden)
            .background(ShellPalette.background)
            .navigationDestination(isPresented: $configuringSigning) {
                ShellSigningIdentityView(store: signingStore)
                    .onDisappear { refreshSigningIdentity() }
            }
            .navigationTitle(hostText("Build games"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !configuringSigning {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(hostText("Cancel")) { dismiss() }.disabled(building || importingKeys)
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: types.isEmpty ? [.data] : types,
                          allowsMultipleSelection: selection > 1) { result in
                do {
                    let urls = try result.get()
                    switch selection {
                    case 0: input = urls.first
                    case 1:
                        guard let source = urls.first else { return }
                        Task { await importKeys(source) }
                    case 2: updates = urls
                    default: dlc = urls
                    }
                } catch {
                    let error = error as NSError
                    guard !(error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError),
                          !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
                    failedBuildReport = nil
                    failure = error.localizedDescription
                }
            }
        }
        .task {
            hasKeys = keyStore.exists
            refreshSigningIdentity()
            configuringSigning = !signingReady
            hasSavedJob = GameBuildJob.exists()
            if hasSavedJob {
                do { job = try GameBuildJob.load() }
                catch { failure = error.localizedDescription }
            }
        }
        .tint(ShellPalette.cream)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(building || importingKeys)
    }

    private func importKeys(_ source: URL) async {
        guard !GameBuildJob.running else { return }
        GameBuildJob.running = true
        importingKeys = true
        failedBuildReport = nil
        defer { importingKeys = false; GameBuildJob.running = false }
        do {
            try await Task.detached(priority: .userInitiated) { [keyStore] in
                try keyStore.save(from: source)
            }.value
            hasKeys = keyStore.exists
            failure = nil
        } catch {
            failure = hostText("Could not save prod.keys. Choose a keys file and try again.")
        }
    }

    private func filenames(_ urls: [URL]) -> String? {
        urls.isEmpty ? nil : urls.map(\.lastPathComponent).joined(separator: ", ")
    }

    private func fileButton(_ title: String, value: String?, selection: Int) -> some View {
        Button { self.selection = selection; picking = true } label: {
            LabeledContent(title, value: value ?? hostText("Choose file…"))
        }
        .buttonStyle(.borderless)
    }

    private func optionalFiles(_ title: String, files: Binding<[URL]>, selection: Int) -> some View {
        HStack {
            fileButton(title, value: filenames(files.wrappedValue), selection: selection)
            if !files.wrappedValue.isEmpty {
                Button { files.wrappedValue = [] } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(hostText("Clear"))
            }
        }
    }

    private func refreshSigningIdentity() {
        signingSummary = signingStore.identitySummary()
    }

    static func signingFailureMessage(_ error: Error) -> String {
        guard let failure = error as? ShellSigningIdentityStore.Failure else {
            return error.localizedDescription
        }
        switch failure {
        case .missing: return hostText("No signing identity saved")
        case .hostSignatureUnavailable: return hostText("This app's signing certificate could not be verified.")
        case .signerMismatch: return hostText("Choose the P12 certificate used to sign this app.")
        case .certificateNotInProfile: return hostText("The provisioning profile does not include this P12 certificate.")
        case .expired: return hostText("The provisioning profile is expired or invalid.")
        case .invalid: return hostText("Check the P12 password and use a profile from this app's signing team.")
        case .storage, .locked: return hostText("Saved signing identity details unavailable")
        }
    }

    private func stageLabel(_ stage: String) -> String {
        switch stage {
        case "inputs": hostText("Copying game files")
        case "extract": hostText("Extracting game data")
        case "shaders": hostText("Compiling shaders")
        case "analyze": hostText("Analyzing game code")
        case "link": hostText("Linking game binary")
        case "resources": hostText("Preparing game resources")
        case "archive": hostText("Packing game")
        case "prepared": hostText("Game prepared")
        case "install": hostText("Signing and installing game")
        default: hostText("Building game")
        }
    }

    // The view may have stayed open while another window completed or replaced a job.
    // Called only while holding the process-wide job gate, before any write or delete.
    private func currentJobUnchanged() -> Bool {
        guard !GameBuildJob.isCurrent(id: job?.id, exists: hasSavedJob) else { return true }
        hasSavedJob = GameBuildJob.exists()
        job = try? GameBuildJob.load()
        return false
    }

    private func clearJob() async throws {
        try await Task.detached(priority: .utility) { try GameBuildJob.discard() }.value
        job = nil
        hasSavedJob = false
        failure = nil
        failedBuildReport = nil
        input = nil
        updates = []
        dlc = []
    }

    private func discard() async {
        guard !building, !GameBuildJob.running else { return }
        failedBuildReport = nil
        building = true
        GameBuildJob.running = true
        defer { building = false; GameBuildJob.running = false }
        guard currentJobUnchanged() else { return }
        do {
            try await clearJob()
        } catch { failure = error.localizedDescription }
    }

    private func prepare() async {
        refreshSigningIdentity()
        guard signingReady else { configuringSigning = true; return }
        hasKeys = keyStore.exists
        guard hasKeys, !building, !GameBuildJob.running, job != nil || input != nil else { return }
        let keys = keyStore.url
        building = true
        GameBuildJob.running = true
        failure = nil
        report = GameBuildReport()
        failedBuildReport = nil
        reportCopied = false
        defer {
            building = false
            GameBuildJob.running = false
            buildTask = nil
            discarding = false
            installing = false
            stageStartedAt = nil
        }
        guard currentJobUnchanged() else { return }
        var scoped: [URL] = []
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        func access(_ url: URL) -> URL {
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            return url
        }
        do {
            do {
                try await Task.detached(priority: .userInitiated) { [signingStore] in
                    try signingStore.validateIdentity()
                }.value
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failure = Self.signingFailureMessage(error)
                failedBuildReport = report.text(failure: .signingIdentity)
                return
            }
            try Task.checkCancellation()
            if job == nil {
                // A corrupt/interrupted job must be explicitly discarded, never overwritten.
                guard !hasSavedJob, let input else { return }
                if GameBuildJob.exists() {
                    hasSavedJob = true
                    job = try GameBuildJob.load()
                    return
                }
                let created = try GameBuildJob(input: .init(access(input)),
                    updates: updates.map { try .init(access($0)) }, dlc: dlc.map { try .init(access($0)) })
                try created.save()
                job = created
                hasSavedJob = true
            }
            guard let saved = job else { return }
            let work = GameBuildJob.directory
            let source = try access(saved.input.resolve(in: work, slot: "base"))
            let updateURLs = try saved.updates.enumerated().map { try access($0.element.resolve(in: work, slot: "updates/\($0.offset)")) }
            let dlcURLs = try saved.dlc.enumerated().map { try access($0.element.resolve(in: work, slot: "dlc/\($0.offset)")) }
            let run = UUID()
            progressRun = run
            stageStartedAt = Date()
            defer { progressRun = nil }
            // Keep one ordered consumer and drain it before publishing the
            // installing state. Separate MainActor tasks can arrive out of order.
            let (events, continuation) = AsyncStream<GameBuildProgress>.makeStream()
            let consumer = Task { @MainActor in
                for await event in events {
                    guard progressRun == run else { return }
                    if job?.stage != event.stage || job?.detail != event.detail { stageStartedAt = Date() }
                    report.record(event)
                    job?.record(event, label: stageLabel(event.stage))
                    do { try job?.save() } catch { failure = error.localizedDescription }
                }
            }
            let output: URL
            do {
                output = try await build(source, keys, updateURLs, dlcURLs, work) {
                    continuation.yield($0)
                }
            } catch {
                continuation.finish()
                await consumer.value
                throw error
            }
            continuation.finish()
            await consumer.value
            progressRun = nil
            try Task.checkCancellation()
            installing = true
            // Installation is atomic in the importer. Keep the complete archive if it fails.
            stageStartedAt = Date()
            let install = GameBuildProgress(stage: "install", message: "")
            report.record(install)
            job?.record(install, label: stageLabel("install"))
            try job?.save()
            try await onBuilt(output)
            try await Task.detached(priority: .utility) { try GameBuildJob.discard() }.value
            job = nil
            hasSavedJob = false
            dismiss()
        } catch {
            progressRun = nil
            if Task.isCancelled {
                do { try await clearJob() }
                catch { failure = error.localizedDescription }
            } else {
                let native = error as? NativeGameBuildFailure
                failure = native == nil ? error.localizedDescription : hostText("Game build failed. Check the build report for details.")
                failedBuildReport = report.text(failure: installing ? .installFailed : .buildFailed, native: native)
            }
            hasSavedJob = GameBuildJob.exists()
        }
    }
}
