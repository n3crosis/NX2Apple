import SwiftUI
import ShellUI

/// `LibraryView` on a `ShellHostModel`: the real shell screen, plus the read-only log sheet and the notice alert. The
/// launch arguments of the demo (initial selection and so on) are not part of it.
public struct ShellHostView: View {
    @Bindable private var model: ShellHostModel
    @State private var receivingPackage = false
    @State private var receiverPresented = false
    @State private var buildingPackage = false
    private let buildGame: GamePackageBuild?
    private let gameTunnel: GamePackageTunnelFactory?
    private let initialSelection: String?
    private let initialDetailOpen: Bool

    public init(model: ShellHostModel, initialSelection: String? = nil, initialDetailOpen: Bool = false, buildGame: GamePackageBuild? = nil, gameTunnel: GamePackageTunnelFactory? = nil) {
        self.buildGame = buildGame
        self.gameTunnel = gameTunnel
        self.model = model
        self.initialSelection = initialSelection
        self.initialDetailOpen = initialDetailOpen
    }

    private var libraryInputEnabled: Bool {
        !receiverPresented && model.sharingPackage == nil && !buildingPackage && model.canPreparePackage
    }

    private var canPrepareExternalPackage: Bool { libraryInputEnabled && model.hasExternalPackage }

    public var body: some View {
        Group {
            if model.isDeepLinkLaunching {
                Color.black.ignoresSafeArea()
                    .accessibilityIdentifier("deeplink.launching")
            } else {
                LibraryView(games: model.libraryDetails, controllers: model.controllers, actions: model.actions, input: model.input,
                            initialSelection: initialSelection, initialDetailOpen: initialDetailOpen, globalPadMap: model.globalPadMap,
                            padMerge: model.padMerge, padSnapshot: model.padSnapshot,
                            signingWarning: model.signingWarning,
                            onDismissSigningWarning: { model.dismissSigningWarning() }, signingTeamID: model.signingTeamID, inputEnabled: libraryInputEnabled,
                            signingIdentityPresented: $model.importingSigningIdentity,
                            signingIdentityContent: AnyView(ShellSigningIdentityView()),
                            canOpenHomeButtonSettings: model.canOpenHomeButtonSettings,
                            importGameButton: AnyView(importButton))
                    .disabled(model.launchingGame || model.resigningGame || model.importingPackage)
                    .sheet(item: $model.sharingPackage) { entry in
                        GamePackageShareView(entry: entry, gameTunnel: gameTunnel)
                    }
                    .sheet(isPresented: $receivingPackage, onDismiss: { receiverPresented = false }) {
                        GamePackageReceiveView(model: model) { receivingPackage = false }
                    }
                    .sheet(isPresented: $buildingPackage) {
                        if let buildGame {
                            GamePackageBuildView(build: buildGame) { output in
                                try await model.installBuiltPackage(output)
                            }
                        }
                    }
                    .sheet(item: Binding(get: { receiverPresented ? nil : model.packagePreview }, set: { if case nil = $0 { model.cancelPackageImport() } })) { prepared in
                        GamePackageImportView(preview: prepared.preview, importing: model.importingPackage,
                            onImport: { Task { await model.importPackage() } }, onCancel: { model.cancelPackageImport() })
                            .interactiveDismissDisabled(model.importingPackage)
                            .alert(Text(verbatim: hostText("NX2Apple")), isPresented: Binding(
                                get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                                Button(hostText("OK")) { model.notice = nil }
                            } message: { Text(model.notice ?? "") }
                    }
                    .overlay {
                        if model.launchingGame {
                            ZStack {
                                Color.black.opacity(0.45).ignoresSafeArea()
                                ProgressView { Text("Preparing game…", bundle: .module) }
                                    .padding(24)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                                    .accessibilityIdentifier("launch.progress")
                            }
                        }
                    }
            }
        }
            .sheet(item: $model.cloudConflict, onDismiss: {
                model.cancelCloudConflictIfPending()
            }) { prompt in
                ScrollView {
                    CloudSaveConflictView(prompt: prompt) { decision in
                        model.resolveCloudConflict(decision)
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(ShellPalette.background)
            }
            .sheet(item: $model.log) { LogView(log: $0) }
            .alert(Text(verbatim: model.noticeTitle ?? hostText("NX2Apple")), isPresented: Binding(
                get: { model.packagePreview == nil && model.notice != nil }, set: { if !$0 { model.notice = nil; model.noticeTitle = nil } })) {
                Button(hostText("OK")) { model.notice = nil; model.noticeTitle = nil }
            } message: { Text(model.notice ?? "") }
            .onChange(of: canPrepareExternalPackage, initial: true) { _, ready in
                guard ready else { return }
                Task {
                    guard canPrepareExternalPackage else { return }
                    await model.prepareNextExternalPackage()
                }
            }
            .onAppear { model.startControllers() }
            .onDisappear { model.stopControllers() }
    }
    @ViewBuilder private var importButton: some View {
        Menu {
            Button(hostText("Import prebuilt games")) { receiverPresented = true; receivingPackage = true }
                .accessibilityIdentifier("package.import.choose")
            if buildGame != nil { Button(hostText("Build games")) { buildingPackage = true } }
        } label: {
            Label(hostText("Import prebuilt games"), systemImage: "square.and.arrow.down")
        }
        .disabled(!libraryInputEnabled || model.isGameRunning)
        .accessibilityIdentifier("package.import.open")
    }

}

/// Read-only, selectable game logs and operation diagnostics.
struct LogView: View {
    let log: LogPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if log.truncated { Text(hostText("Only the end of the log is shown.")).font(.footnote).foregroundStyle(.secondary) }
                    Text(verbatim: log.text ?? hostText("This game has no log yet. It appears after the game has run."))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(log.text == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(log.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(hostText("Done")) { dismiss() }.accessibilityIdentifier("log.close") } }
        }
        .tint(ShellPalette.cream)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("log.sheet")
    }
}
