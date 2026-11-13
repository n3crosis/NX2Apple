import SwiftUI

struct GameResigningView: View {
    @Bindable var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: CatalogueEntry?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(hostText("Only imported games can be re-signed. This does not renew the app itself."))
                    if !ShellFrameworkResigner.isAvailable {
                        Text(hostText("This build does not include the native signing backend."))
                    } else if !model.canResignGames {
                        Text(hostText("Restart the app before re-signing an imported game."))
                    }
                }
                Section {
                    ForEach(model.resignableGames) { game in
                        Button(game.title) { selected = game }
                            .disabled(!model.canResignGames || !ShellFrameworkResigner.isAvailable)
                            .accessibilityIdentifier("signing.game." + game.id)
                    }
                    if model.resignableGames.isEmpty { Text(hostText("No imported games to re-sign.")) }
                }
            }
            .navigationTitle(hostText("Re-sign imported game"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(hostText("Done")) { dismiss() } } }
            .confirmationDialog(hostText("Re-sign this game using your local identity?"), isPresented: Binding(
                get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
                    if let selected {
                        Button(selected.title) {
                            let id = selected.id
                            self.selected = nil
                            dismiss()
                            Task { await model.resignGame(id) }
                        }
                    }
                }
        }
    }
}
