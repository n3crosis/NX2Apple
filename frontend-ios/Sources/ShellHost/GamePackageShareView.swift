import SwiftUI
import UniformTypeIdentifiers
import ShellUI
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
import VisionKit
#endif

struct GamePackageShareView: View {
    let entry: GamePackageLibrary.Entry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let gameTunnel: GamePackageTunnelFactory?
    @State private var server: GamePackageShareServer?
    @State private var remote: Bool?
    @State private var previousIdleTimerDisabled: Bool?
    @State private var url: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(verbatim: entry.manifest.name).font(.headline)
                if remote == nil {
                    Button(hostText("Local network")) { remote = false }
                    if gameTunnel != nil {
                        Text(hostText("Cloudflare can read transferred game data. Anyone with the link can download it."))
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(hostText("Share over the internet")) { remote = true }
                    }
                } else if let url, let image = qrCode(url.absoluteString) {
                    Image(decorative: image, scale: 1).interpolation(.none).resizable()
                        .scaledToFit().frame(maxWidth: 280, maxHeight: 280).padding(12).background(.white)
                    Text(hostText(remote == true ? "Scan or paste this link in NX2Apple on another device. Keep this screen open until the transfer finishes." : "Scan on another device on the same network. Keep this screen open until the transfer finishes."))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    ShareLink(item: url) { Label(hostText("Share link"), systemImage: "link") }
                } else if let error {
                    Text(verbatim: error).textSelection(.enabled)
                } else { ProgressView() }
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ShellPalette.background)
            .navigationTitle(hostText("Share game"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(hostText("Done")) { dismiss() } } }
        }
        .tint(ShellPalette.cream).preferredColorScheme(.dark)
        .task(id: remote) {
            guard !Task.isCancelled, let remote else { return }
            #if os(iOS)
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
            let server = GamePackageShareServer(tunnel: remote ? gameTunnel?() : nil)
            self.server = server
            do {
                try Task.checkCancellation()
                url = try await server.start(directory: entry.directory, remote: remote)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if Task.isCancelled { await server.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await server?.stop() }
                dismiss()
            }
        }
        .onDisappear {
            #if os(iOS)
            if let previousIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            }
            previousIdleTimerDisabled = nil
            #endif
            Task { await server?.stop() }
        }
    }

    private func qrCode(_ value: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

struct GamePackageReceiveView: View {
    static func importFailureMessage(_ error: Error) -> String? {
        let error = error as NSError
        guard !(error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError),
              !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return nil }
        return error.localizedDescription
    }

    let model: ShellHostModel
    let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var link = ""
    @State private var receiving = false
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var pickingPackage = false
    @State private var scanning = false
    @State private var allowInternet = false

    private var internetLink: Bool {
        URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme == "https"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { pickingPackage = true } label: {
                        Label(hostText("Choose file…"), systemImage: "folder")
                    }.disabled(receiving)
                }
                Section {
                    TextField(hostText("Sharing link"), text: $link)
                        .autocorrectionDisabled().disabled(receiving)
                    #if os(iOS) && !targetEnvironment(macCatalyst)
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button(hostText("Scan QR code")) { scanning = true }.disabled(receiving)
                    }
                    #endif
                    if internetLink {
                        Toggle(hostText("Allow internet transfer"), isOn: $allowInternet)
                            .accessibilityIdentifier("sharing.allowInternet").disabled(receiving)
                        Text(hostText("Cloudflare can read transferred game data. Anyone with the link can download it."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button { receiving = true } label: {
                        HStack {
                            Text(hostText("Receive game"))
                            Spacer()
                            if receiving { ProgressView() }
                        }
                    }.disabled(receiving || (internetLink && !allowInternet) || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if receiving { ProgressView(value: progress).accessibilityLabel(hostText("Receiving game")) }
                }
                if let error { Section { Text(verbatim: error).textSelection(.enabled) } }
            }
            .scrollContentBackground(.hidden).background(ShellPalette.background)
            .navigationTitle(hostText("Import prebuilt games"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(hostText("Cancel"), action: close) } }
        }
        .tint(ShellPalette.cream).preferredColorScheme(.dark)
        .fileImporter(isPresented: $pickingPackage, allowedContentTypes: [UTType(filenameExtension: "nxb") ?? .data]) { result in
            switch result {
            case .success(let url):
                model.enqueueExternalPackage(url)
                close()
            case .failure(let failure):
                if let message = Self.importFailureMessage(failure) { error = message }
            }
        }
        .onChange(of: link) { _, _ in allowInternet = false }
        .task(id: receiving) {
            guard receiving else { return }
            defer { receiving = false }
            #if os(iOS)
            let previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
            #endif
            error = nil
            progress = 0
            do {
                guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw GamePackageError.invalid(hostText("Invalid sharing link"))
                }
                let client = try GamePackageShareClient(url: url, remote: allowInternet)
                try await withTaskCancellationHandler {
                    try await model.receivePackage(client) { bytes, total in
                        Task { @MainActor in progress = total > 0 ? Double(bytes) / Double(total) : 0 }
                    }
                } onCancel: {
                    Task { await client.cancel() }
                }
                if !Task.isCancelled { close() }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { close() } }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .sheet(isPresented: $scanning) {
            NavigationStack {
                GameShareScanner { value in link = value; scanning = false }
                    .ignoresSafeArea(edges: .bottom)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(hostText("Cancel")) { scanning = false } } }
            }
        }
        #endif
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
private struct GameShareScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning { try? controller.startScanning() }
    }
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        private var delivered = false
        init(scanned: @escaping (String) -> Void) { self.scanned = scanned }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for case .barcode(let code) in addedItems {
                if let value = code.payloadStringValue {
                    delivered = true
                    dataScanner.stopScanning()
                    scanned(value)
                    return
                }
            }
        }
    }
}
#endif
