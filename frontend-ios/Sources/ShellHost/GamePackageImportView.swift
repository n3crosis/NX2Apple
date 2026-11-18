import SwiftUI
import ShellUI
import ImageIO

/// Review transport provenance before the host signs a private executable copy.
/// Confirming an unknown publisher approves this import, not permanent trust.
public struct GamePackageImportView: View {
    public let preview: GamePackage.Preview
    public let importing: Bool
    public let onImport: () -> Void
    public let onCancel: () -> Void
    @State private var accepted = false

    public init(preview: GamePackage.Preview, importing: Bool,
                onImport: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.preview = preview; self.importing = importing
        self.onImport = onImport; self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        cover
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(verbatim: preview.manifest.name).font(.headline)
                    }
                }
                Section {
                    if let publisher = preview.publisher {
                        LabeledContent(hostText("Signed by"), value: publisher.subject ?? publisher.keyID)
                        if let expiry = publisher.expiresAt {
                            LabeledContent(hostText("Certificate expires"), value: expiry.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let fingerprint = publisher.certificateSHA256 {
                            Text(verbatim: fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if !publisher.trusted {
                            Text(hostText("The signature is valid, but this publisher is not trusted on this device."))
                        }
                    } else {
                        Label(hostText("Unsigned package"), systemImage: "exclamationmark.triangle")
                        Text(hostText("This package has no publisher signature. Only import it if you trust its source."))
                    }
                    if preview.publisher?.trusted != true {
                        Toggle(hostText("Allow this import"), isOn: $accepted)
                    }
                }
                Section {
                    Button(action: onImport) {
                        HStack {
                            Text(hostText("Import game"))
                            Spacer()
                            if importing { ProgressView() }
                        }
                    }
                    .disabled(importing || (preview.publisher?.trusted != true && !accepted))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(ShellPalette.background)
            .navigationTitle(hostText("Import game"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hostText("Cancel"), action: onCancel).disabled(importing)
                }
            }
        }
        .tint(ShellPalette.cream)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(importing)
        .presentationDetents([.medium, .large])
        .presentationBackground(ShellPalette.background)
    }

    @ViewBuilder private var cover: some View {
        if let data = preview.cover,
           let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
               [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
        } else { Image(systemName: "gamecontroller").font(.largeTitle) }
    }
}
