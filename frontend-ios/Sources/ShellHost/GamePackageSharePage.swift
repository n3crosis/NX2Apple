import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
import ShellUI
#if os(iOS)
import UIKit
#endif

/// An inner settings destination. Link serving and file export are independent
/// readers; neither operation replaces the installed game or its signing identity.
struct GamePackageSharePage: View {
    let entry: GamePackageLibrary.Entry
    let gameTunnel: GamePackageTunnelFactory?
    let export: @MainActor () async throws -> URL?
    let onOpen: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var server: GamePackageShareServer?
    @State private var linkTask: Task<Void, Never>?
    @State private var remote: Bool? = false
    @State private var link: URL?
    @State private var linkError: String?
    @State private var fileError: String?
    @State private var exporting = false
    @State private var savingFile = false
    @State private var archive: URL?
    @State private var previousIdleTimerDisabled: Bool?

    var body: some View {
        Form {
            Section { Text(verbatim: entry.manifest.name).font(.headline) }
            Section {
                if remote == nil {
                    Button(hostText("Local network")) { remote = false }
                } else if let link {
                    if let image = qrCode(link.absoluteString) {
                        Image(decorative: image, scale: 1).interpolation(.none).resizable()
                            .scaledToFit().frame(maxWidth: 280, maxHeight: 280).padding(12).background(.white)
                    }
                    ShareLink(item: link) { Label(hostText("Share link"), systemImage: "link") }
                    Text(hostText(remote == true ? "Scan or paste this link in NX2Apple on another device. Keep this screen open until the transfer finishes." : "Scan on another device on the same network. Keep this screen open until the transfer finishes."))
                } else if let linkError {
                    Text(verbatim: linkError).textSelection(.enabled)
                } else { ProgressView() }
                if remote != nil {
                    Button(hostText("Stop sharing")) { remote = nil }
                        .accessibilityIdentifier("sharing.stopLink")
                }
            }
            Section {
                if gameTunnel != nil {
                    Toggle(hostText("External sharing"), isOn: Binding(
                        get: { remote == true }, set: { remote = $0 }))
                        .accessibilityIdentifier("sharing.external")
                    if remote == true {
                        Text(hostText("Cloudflare can read transferred game data. Anyone with the link can download it."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button(hostText("Export NXB")) { exporting = true }
                    .disabled(exporting || savingFile)
                    .accessibilityIdentifier("sharing.saveFile")
                if exporting { ProgressView() }
                if let fileError { Text(verbatim: fileError).textSelection(.enabled) }
            }
        }
        .navigationTitle(hostText("Share game"))
        .navigationBarBackButtonHidden(exporting || savingFile)
        .interactiveDismissDisabled(exporting || savingFile)
        .onChange(of: remote) { _, _ in restartLink() }
        .task(id: exporting) {
            guard exporting else { return }
            defer { exporting = false }
            fileError = nil
            do {
                guard let url = try await export() else {
                    fileError = hostText("Game package unavailable")
                    return
                }
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                archive = url
                savingFile = true
            } catch {
                if !Task.isCancelled { fileError = error.localizedDescription }
            }
        }
        .background {
            if let archive, savingFile {
                PackageExportShareSheet(url: archive) { error in
                    if let error { fileError = GamePackageReceiveView.importFailureMessage(error) }
                    clearArchive()
                }
            }
        }
        .onAppear {
            onOpen()
            if linkTask == nil { restartLink() }
            #if os(iOS)
            if previousIdleTimerDisabled == nil {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { remote = nil }
        }
        .onDisappear {
            // The file-provider UI can cover the page. It must not stop a link
            // or release the installed generation while copying the archive.
            guard !savingFile else { return }
            onClose()
            linkTask?.cancel()
            let current = server
            Task { await current?.stop() }
            // A document-provider sheet may temporarily cover this page. Keep
            // its source alive until the exporter completion/cancel callback.
            if !savingFile { clearArchive() }
            #if os(iOS)
            if let previousIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            }
            previousIdleTimerDisabled = nil
            #endif
        }
    }

    // Unlike a view-bound task, this survives the file-provider covering the
    // page. Only Stop sharing, backgrounding, or leaving the page stops it.
    private func restartLink() {
        linkTask?.cancel()
        let previous = server
        server = nil
        link = nil
        linkError = nil
        let selectedMode = remote
        linkTask = Task {
            await previous?.stop()
            guard !Task.isCancelled, let selectedMode else { return }
            let current = GamePackageShareServer(tunnel: selectedMode ? gameTunnel?() : nil)
            server = current
            do {
                let result = try await current.start(directory: entry.directory, remote: selectedMode)
                if Task.isCancelled { await current.stop(); return }
                link = result
            } catch {
                await current.stop()
                if !Task.isCancelled { linkError = error.localizedDescription }
            }
        }
    }

    private func clearArchive() {
        if let archive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        archive = nil
        savingFile = false
    }

    private func qrCode(_ value: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

