import SwiftUI
import UniformTypeIdentifiers

/// Explicit owner-controlled import. No automatic account or keychain discovery.
public struct ShellSigningIdentityView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pkcs12: Data?
    @State private var profile: Data?
    @State private var password = ""
    @State private var selectingProfile = false
    @State private var picking = false
    @State private var saving = false
    @State private var loading = false
    @State private var saved = false
    @State private var removing = false
    @State private var message: String?
    private let store: ShellSigningIdentityStore

    public init(store: ShellSigningIdentityStore = .init()) { self.store = store }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(hostText("Your signing identity stays on this device. It must match the team that signed this app. Imported code still needs iOS approval."))
                    Text(saved ? hostText("Signing identity saved on this device") : hostText("No signing identity saved"))
                }
                Section {
                    Button(pkcs12 == nil ? hostText("Choose P12 certificate") : hostText("P12 certificate selected")) {
                        selectingProfile = false; picking = true
                    }.accessibilityIdentifier("signing.chooseP12")
                    Button(profile == nil ? hostText("Choose provisioning profile") : hostText("Provisioning profile selected")) {
                        selectingProfile = true; picking = true
                    }.accessibilityIdentifier("signing.chooseProfile")
                    SecureField(hostText("P12 password"), text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("signing.password")
                    Button(hostText("Save signing identity")) { save() }
                        .disabled(pkcs12 == nil || profile == nil || saving || loading)
                        .accessibilityIdentifier("signing.save")
                }.disabled(saving || loading)
                if saved {
                    Section {
                        Button(hostText("Remove signing identity"), role: .destructive) { removing = true }
                            .disabled(saving || loading)
                            .accessibilityIdentifier("signing.remove")
                    }
                }
                if saving || loading { ProgressView() }
                if let message { Text(message).accessibilityIdentifier("signing.status") }
            }
            .navigationTitle(hostText("Signing identity"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(hostText("Done")) { clear(); dismiss() }
                        .disabled(saving || loading)
                        .accessibilityIdentifier("signing.close")
                }
            }
            .interactiveDismissDisabled(saving || picking || loading)
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                receive(result)
            }
            .confirmationDialog(hostText("Remove the signing identity from this device?"), isPresented: $removing,
                                titleVisibility: .visible) {
                Button(hostText("Remove signing identity"), role: .destructive) {
                    do { try store.remove(); saved = false; clear(); message = nil }
                    catch { message = hostText("The signing identity could not be removed.") }
                }
            }
            .onAppear { saved = store.hasIdentity }
            .onDisappear { clear() }
        }
    }

    private func clear() { password = ""; pkcs12 = nil; profile = nil }

    private func receive(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard !loading else { return }
        let isProfile = selectingProfile
        let expected = isProfile ? ["mobileprovision"] : ["p12", "pfx"]
        guard expected.contains(url.pathExtension.lowercased()) else {
            message = hostText("Choose a valid P12 certificate or provisioning profile.")
            return
        }
        let limit = isProfile ? ProvisioningProfile.maxProfileBytes : 1024 * 1024
        loading = true
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                try? ShellSigningIdentityStore.readImportedFile(url, maximumBytes: limit)
            }.value
            loading = false
            if let data {
                if isProfile { profile = data } else { pkcs12 = data }
                message = nil
            } else {
                message = hostText("Choose a valid P12 certificate or provisioning profile.")
            }
        }
    }

    private func save() {
        guard let pkcs12, let profile, !saving,
              let executable = Bundle.main.executableURL,
              let team = FrameworkSignature.inspect(executable: executable)?.teamID, !team.isEmpty else {
            message = hostText("This app has no usable signing team.")
            return
        }
        saving = true
        let enteredPassword = password
        password = ""
        let identityStore = store
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> ShellSigningIdentityStore.Failure? in
                do {
                    try identityStore.save(pkcs12: pkcs12, profile: profile, password: enteredPassword, expectedTeamID: team)
                    return nil
                } catch let error as ShellSigningIdentityStore.Failure { return error }
                catch { return .storage }
            }.value
            saving = false
            if let outcome {
                switch outcome {
                case .hostSignatureUnavailable: message = hostText("This app's signing certificate could not be verified.")
                case .signerMismatch: message = hostText("Choose the P12 certificate used to sign this app.")
                case .certificateNotInProfile: message = hostText("The provisioning profile does not include this P12 certificate.")
                case .expired: message = hostText("The provisioning profile is expired or invalid.")
                case .invalid: message = hostText("Check the P12 password and use a profile from this app's signing team.")
                default: message = hostText("The signing identity could not be saved. Unlock this device and try again.")
                }
            } else {
                clear(); saved = true
                message = hostText("Signing identity saved. Choose an imported game to re-sign.")
            }
        }
    }
}
