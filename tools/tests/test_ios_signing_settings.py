"""Offline wiring checks for the device-local signing import in Settings.

The host model and simulator tests exercise state and presentation on Apple SDKs.
"""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "frontend-ios/Sources"


class IOSSigningSettingsTests(unittest.TestCase):
    def test_settings_routes_import_after_menu_dismissal(self):
        settings = (SOURCES / "ShellUI/ShellSettingsView.swift").read_text()
        self.assertIn('Button(action: actions.onImportSigningIdentity)', settings)
        self.assertIn('.accessibilityIdentifier("shellSettings.signing")', settings)
        self.assertIn('.shellTarget("shs.signing", action: actions.onImportSigningIdentity)', settings)
        actions = (SOURCES / "ShellUI/ShellInputs.swift").read_text()
        self.assertIn('self.onImportSigningIdentity = onImportSigningIdentity', actions)
        library = (SOURCES / "ShellUI/LibraryView.swift").read_text()
        self.assertIn('handOffMenu { actions.onImportSigningIdentity() }', library)
        self.assertIn('onDismiss: runPendingMenuAction', library)
        model = (SOURCES / "ShellHost/ShellHostModel.swift").read_text()
        self.assertIn('onImportSigningIdentity: { [weak self] in self?.importingSigningIdentity = true }', model)
        host = (SOURCES / "ShellHost/ShellHostView.swift").read_text()
        self.assertIn('.sheet(isPresented: $model.importingSigningIdentity) { ShellSigningIdentityView() }', host)

    def test_game_chooser_only_selects_games(self):
        chooser = (SOURCES / "ShellHost/GameResigningView.swift").read_text()
        self.assertNotIn('ShellSigningIdentityView', chooser)
        self.assertNotIn('identityPresented', chooser)
        self.assertIn('ForEach(model.resignableGames)', chooser)
        self.assertIn('await model.resignGame(id)', chooser)

    def test_import_validation_errors_have_specific_localized_messages(self):
        view = (SOURCES / 'ShellHost/ShellSigningIdentityView.swift').read_text()
        english = json.loads((ROOT / 'frontend/l10n/en.json').read_text())
        catalog = json.loads((SOURCES / 'ShellHost/Resources/Localizable.xcstrings').read_text())
        for error in ['hostSignatureUnavailable', 'signerMismatch', 'certificateNotInProfile']:
            key = 'ios.host.signing.' + error
            message = english[key]
            self.assertIn(f'case .{error}: message = hostText("{message}")', view)
            self.assertIn(message, catalog['strings'])
            for path in (ROOT / 'frontend/l10n').glob('*.json'):
                with self.subTest(error=error, language=path.stem):
                    self.assertTrue(json.loads(path.read_text())[key])

    def test_settings_label_reuses_every_existing_translation(self):
        for path in (ROOT / "frontend/l10n").glob('*.json'):
            with self.subTest(language=path.stem):
                data = json.loads(path.read_text())
                self.assertEqual(data['ios.ui.signing.identity'], data['ios.host.signing.9332c25e9c45'])
        catalog = json.loads((SOURCES / 'ShellUI/Resources/Localizable.xcstrings').read_text())
        self.assertIn('Signing identity', catalog['strings'])


if __name__ == '__main__':
    unittest.main()
