"""Exercise build_shell.sh's actual validation/generation stages without Apple tools."""
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / 'frontend-ios/Shell/build_shell.sh'


def stage(index, args, env):
    source = SCRIPT.read_text().split("<<'PY'")[index + 1].split('\n', 1)[1].split('\nPY\n', 1)[0]
    return subprocess.run([sys.executable, '-I', '-', *map(str, args)], input=source,
                          env={**os.environ, **env}, text=True, capture_output=True)


class SharedShellBuild(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.receipt = dict(abi=1, profile_abi=1, runtime_version='fs1-fixture', chain='b-fixture')
        self.runtime = self.root / 'DmSharedRuntime.framework'
        self.runtime.mkdir()
        (self.runtime / 'DmSharedRuntime').write_bytes(b'fixture')
        self.write_runtime()
        self.list = self.root / 'frameworks.txt'
        self.runtime_list = self.root / 'runtime.txt'

    def write_runtime(self):
        (self.runtime / 'shared-runtime.json').write_text(json.dumps(self.receipt))
        (self.runtime / 'Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleExecutable='DmSharedRuntime', DMSharedRuntimeABI=self.receipt['abi'],
            DMSharedProfileABI=self.receipt['profile_abi'], DMSharedRuntimeVersion=self.receipt['runtime_version'],
            DMChain=self.receipt['chain'])))

    def game(self, number, loader='FS', **updates):
        title = f'{number:016X}'
        name = 'DmGame' + title
        path = self.root / (name + '.framework')
        path.mkdir()
        (path / name).write_bytes(b'fixture')
        manifest = dict(title_id=title, name='Fixture', framework=path.name,
                        framework_executable=name, loader=loader, chain=self.receipt['chain'],
                        shared_runtime={k: self.receipt[k] for k in ('abi', 'profile_abi', 'runtime_version')})
        manifest.update(updates)
        (path / 'game.manifest.json').write_text(json.dumps(manifest))
        return path

    def validate(self, games, runtime=True):
        return stage(0, [self.list, self.runtime_list, self.root / 'runtime-chain.txt'], dict(
            DM_SHELL_FRAMEWORKS='\n'.join(map(str, games)),
            DM_SHELL_SHARED_RUNTIME=str(self.runtime) if runtime else ''))

    def test_two_fs_and_legacy_embed_runtime_once_with_signing(self):
        games = [self.game(1), self.game(2), self.game(3, loader='FH', chain='b-legacy')]
        result = self.validate(games)
        self.assertEqual(result.returncode, 0, result.stderr)
        template = self.root / 'template.yml'
        template.write_text('dependencies:\n  # @FRAMEWORKS@\n')
        output = self.root / 'project.yml'
        result = stage(1, [template, self.list, self.runtime_list, output], {})
        self.assertEqual(result.returncode, 0, result.stderr)
        text = output.read_text()
        self.assertEqual(text.count('DmSharedRuntime.framework'), 1)
        for path in games: self.assertIn(str(path), text)
        self.assertEqual(text.count('codeSign: true'), 4)
        self.assertEqual(text.count('link: false'), 4)
        self.assertEqual(text.count('embed: true'), 4)

    def test_fs_requires_runtime(self):
        result = self.validate([self.game(1)], runtime=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FS requires DM_SHELL_SHARED_RUNTIME', result.stderr)
        self.assertFalse(self.list.exists())

    def test_legacy_only_different_chains_still_supported(self):
        result = self.validate([self.game(1, loader='FH', chain='b-old'), self.game(2, loader='FH')], runtime=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.runtime_list.read_text(), '')

    def test_fs_contract_mismatches_rejected(self):
        for key in ('abi', 'profile_abi', 'runtime_version'):
            with self.subTest(key=key):
                required = {k: self.receipt[k] for k in ('abi', 'profile_abi', 'runtime_version')}
                required[key] = 'wrong'
                result = self.validate([self.game(len(list(self.root.glob('DmGame*'))) + 1, shared_runtime=required)])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f'{key} mismatch', result.stderr)

    def test_fs_chain_mismatch_rejected(self):
        result = self.validate([self.game(1, chain='b-old')])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('shader chain mismatch', result.stderr)

    def test_runtime_receipt_must_match_native_metadata(self):
        self.receipt['runtime_version'] = 'fs1-other'
        (self.runtime / 'shared-runtime.json').write_text(json.dumps(self.receipt))
        result = self.validate([])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('receipt disagrees', result.stderr)

    def test_runtime_executable_required(self):
        (self.runtime / 'DmSharedRuntime').unlink()
        result = self.validate([])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no executable', result.stderr)

    def test_duplicate_titles_rejected(self):
        game = self.game(1)
        result = self.validate([game, game])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already in the shell', result.stderr)

    def test_unknown_loader_rejected(self):
        result = self.validate([self.game(1, loader='FR')])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('built without a host', result.stderr)


if __name__ == '__main__':
    unittest.main()
