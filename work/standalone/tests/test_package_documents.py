"""Release archives carry author-facing interface docs outside the engine addon."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
BUILDER = ROOT / 'work/standalone/build_mod.py'


class PackageDocumentsTests(unittest.TestCase):
    def test_main_archive_contains_docs_and_only_expected_optional_cover(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, '-B', str(BUILDER), '--output-dir', directory],
                cwd=ROOT, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            output = Path(directory) / 'AutoChat-1.0.0.zip'
            self.assertTrue(output.is_file())
            with zipfile.ZipFile(output) as package:
                self.assertIsNone(package.testzip())
                names = set(package.namelist())
                expected = {
                    'Addon/9ba626afa44a3aa3.patch_0',
                    'Addon/9ba626afa44a3aa3.patch_0.stream',
                    'Addon/9ba626afa44a3aa3.patch_0.gpu_resources',
                    'manifest.json', 'README.txt',
                    'Docs/PLUGIN-API.md', 'Docs/INTERFACE-DEMO.md'}
                self.assertTrue(expected.issubset(names), names)
                self.assertLessEqual(names - expected, {'cover-autochat.png'})
                manifest = json.loads(package.read('manifest.json'))
                self.assertEqual(manifest['Name'], 'AutoChat 1.0.0')
                self.assertEqual(package.read('Docs/PLUGIN-API.md'),
                                 (ROOT / 'docs/PLUGIN-API.md').read_bytes())
                self.assertEqual(package.read('Docs/INTERFACE-DEMO.md'),
                                 (ROOT / 'docs/INTERFACE-DEMO.md').read_bytes())
                if 'cover-autochat.png' in names:
                    self.assertEqual(manifest.get('IconPath'), 'cover-autochat.png')
                    self.assertEqual(package.read('cover-autochat.png'),
                                     (ROOT / 'assets/cover-autochat.png').read_bytes())
                else:
                    self.assertNotIn('IconPath', manifest)


if __name__ == '__main__':
    unittest.main()
