"""Offline checks for safe, repeatable AutoChat release uploads."""
from contextlib import redirect_stderr, redirect_stdout
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from types import SimpleNamespace
import io
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'work/standalone/release.py'
SPEC = spec_from_file_location('autochat_release', SOURCE)
release = module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_asset_selection_defaults_to_main_zip_and_accepts_repeatable_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            main_zip = Path(directory) / 'AutoChat-1.0.0.zip'
            extras = [Path(directory) / name for name in (
                'AutoChat-1.0.0.zip.sha256', 'AutoChat-Interface-Demo-1.0.0.zip',
                'cover-autochat.png', 'PLUGIN-API.md')]
            main_zip.write_bytes(b'main')
            for path in extras:
                path.write_bytes(b'asset')

            default = release.collect_assets(str(main_zip), [])
            self.assertEqual([asset['name'] for asset in default], ['AutoChat-1.0.0.zip'])
            all_assets = release.collect_assets(str(main_zip), [str(path) for path in extras])
            self.assertEqual([asset['name'] for asset in all_assets],
                ['AutoChat-1.0.0.zip', 'AutoChat-1.0.0.zip.sha256',
                 'AutoChat-Interface-Demo-1.0.0.zip', 'cover-autochat.png', 'PLUGIN-API.md'])

    def test_gcm_lookup_is_oauth_only_selected_user_and_never_prints_password(self):
        completed = SimpleNamespace(returncode=0,
            stdout='protocol=https\nhost=github.com\nusername=YC426\npassword=secret-token\n',
            stderr='')
        with patch.object(release.subprocess, 'run', return_value=completed) as run:
            output = io.StringIO()
            with redirect_stdout(output):
                token = release.token_from_git('YC426')
        self.assertEqual(token, 'secret-token')
        self.assertEqual(output.getvalue(), '')
        args = run.call_args.args[0]
        self.assertIn('-c', args)
        self.assertIn('credential.helper=', args)
        self.assertIn('credential.helper=manager', args)
        self.assertIn('credential.username=YC426', args)
        self.assertEqual(args[-2:], ['credential', 'fill'])

    def test_tag_push_failure_aborts_before_release_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            zip_path = Path(directory) / 'AutoChat-1.0.0.zip'
            notes = Path(directory) / 'notes.md'
            zip_path.write_bytes(b'zip')
            notes.write_text('release notes', encoding='utf-8')
            with patch.object(release, 'token_from_git', return_value='secret-token'), \
                 patch.object(release, 'ensure_tag_pushed', side_effect=release.ReleaseError('tag push failed')), \
                 patch.object(release, 'request') as request:
                output = io.StringIO()
                with redirect_stdout(output), patch('sys.argv', [
                    'release.py', '--tag', 'v1.0.0', '--zip', str(zip_path),
                    '--notes-file', str(notes), '--credential-user', 'YC426']):
                    with self.assertRaises(SystemExit):
                        release.main()
            request.assert_not_called()
            self.assertNotIn('secret-token', output.getvalue())

    def test_git_push_is_checked_and_failure_stops_tag_flow(self):
        head = 'a' * 40
        with patch.object(release, 'git_output', return_value=head), \
             patch.object(release, 'remote_tag_commit', return_value=None), \
             patch.object(release, 'git_run') as run:
            run.side_effect = [
                SimpleNamespace(returncode=1, stdout=''),
                SimpleNamespace(returncode=0, stdout=''),
                subprocess.CalledProcessError(1, ['git', 'push']),
            ]
            with self.assertRaisesRegex(release.ReleaseError, 'tag push failed'):
                release.ensure_tag_pushed('v1.0.0', '1.0.0', 'YC426')
        push_call = run.call_args_list[-1]
        self.assertIn('push', push_call.args[0])
        self.assertTrue(push_call.kwargs['check'])
        self.assertEqual(run.call_count, 3)

    def test_existing_remote_tag_must_point_to_head_without_force_update(self):
        head = 'a' * 40
        with patch.object(release, 'git_run') as run:
            run.side_effect = [
                SimpleNamespace(returncode=0, stdout=head + '\n'),
                SimpleNamespace(returncode=1, stdout=''),
                SimpleNamespace(returncode=0, stdout='b' * 40 + '\trefs/tags/v1.0.0\n'),
            ]
            with self.assertRaises(release.ReleaseError):
                release.ensure_tag_pushed('v1.0.0', '1.0.0', 'YC426')
        self.assertEqual(run.call_count, 3)

    def test_retry_skips_same_named_asset_and_rejects_size_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            asset_path = Path(directory) / 'cover.png'
            asset_path.write_bytes(b'png-data')
            asset = {
                'path': str(asset_path), 'name': asset_path.name,
                'size': asset_path.stat().st_size,
                'sha256': release.file_sha256(asset_path),
                'content_type': 'image/png',
            }
            existing = [{'name': 'cover.png', 'size': len(b'png-data'),
                         'digest': 'sha256:' + asset['sha256']}]
            with patch.object(release, 'request') as request:
                output = io.StringIO()
                with redirect_stdout(output):
                    release.upload_assets('https://upload.example', [asset], existing, 'secret-token')
            request.assert_not_called()
            self.assertIn('already attached', output.getvalue())

            with self.assertRaises(release.ReleaseError):
                release.upload_assets('https://upload.example', [asset],
                    [{'name': 'cover.png', 'size': 1}], 'secret-token')

            with self.assertRaisesRegex(release.ReleaseError, 'cannot verify'):
                release.upload_assets('https://upload.example', [asset],
                    [{'name': 'cover.png', 'size': len(b'png-data')}], 'secret-token')

    def test_main_zip_version_mismatch_stops_before_credentials_or_release(self):
        with tempfile.TemporaryDirectory() as directory:
            zip_path = Path(directory) / 'AutoChat-0.8.7.zip'
            zip_path.write_bytes(b'zip')
            with patch.object(release, 'token_from_git') as token, \
                 patch.object(release, 'ensure_tag_pushed') as push, \
                 patch.object(release, 'request') as request:
                output = io.StringIO()
                with redirect_stdout(output), redirect_stderr(output), patch('sys.argv', [
                    'release.py', '--tag', 'v1.0.0', '--zip', str(zip_path),
                    '--credential-user', 'YC426']):
                    with self.assertRaises(SystemExit) as raised:
                        release.main()
            self.assertEqual(raised.exception.code, 1)
            token.assert_not_called()
            push.assert_not_called()
            request.assert_not_called()
            self.assertIn('does not match', output.getvalue())

    def test_positive_build_tag_accepts_stable_versioned_zip_in_dry_run(self):
        with tempfile.TemporaryDirectory() as directory:
            zip_path = Path(directory) / 'AutoChat-1.0.0.zip'
            zip_path.write_bytes(b'zip')
            with patch.object(release, 'token_from_git') as token, \
                 patch.object(release, 'ensure_tag_pushed') as push, \
                 patch.object(release, 'request') as request:
                output = io.StringIO()
                with redirect_stdout(output), patch('sys.argv', [
                    'release.py', '--tag', 'v1.0.0-build.2', '--zip', str(zip_path), '--dry-run']):
                    result = release.main()
            self.assertEqual(result, 0)
            self.assertIn('tag       : v1.0.0-build.2', output.getvalue())
            self.assertIn('AutoChat 1.0.0', output.getvalue())
            token.assert_not_called()
            push.assert_not_called()
            request.assert_not_called()

    def test_build_suffix_requires_canonical_positive_integer(self):
        invalid_tags = ('v1.0.0-build.0', 'v1.0.0-build.02',
                        'v1.0.0-build.two', 'v1.0.0-build.2.1')
        with tempfile.TemporaryDirectory() as directory:
            zip_path = Path(directory) / 'AutoChat-1.0.0.zip'
            zip_path.write_bytes(b'zip')
            for tag in invalid_tags:
                with self.subTest(tag=tag), \
                     patch.object(release, 'token_from_git') as token, \
                     patch.object(release, 'ensure_tag_pushed') as push, \
                     patch.object(release, 'request') as request:
                    output = io.StringIO()
                    with redirect_stdout(output), redirect_stderr(output), patch('sys.argv', [
                        'release.py', '--tag', tag, '--zip', str(zip_path),
                        '--credential-user', 'YC426']):
                        with self.assertRaises(SystemExit) as raised:
                            release.main()
                    self.assertEqual(raised.exception.code, 1)
                    token.assert_not_called()
                    push.assert_not_called()
                    request.assert_not_called()
                    self.assertIn('does not match', output.getvalue())

    def test_different_core_build_tag_mismatch_stops_before_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            zip_path = Path(directory) / 'AutoChat-1.0.0.zip'
            zip_path.write_bytes(b'zip')
            with patch.object(release, 'token_from_git') as token, \
                 patch.object(release, 'ensure_tag_pushed') as push, \
                 patch.object(release, 'request') as request:
                output = io.StringIO()
                with redirect_stdout(output), redirect_stderr(output), patch('sys.argv', [
                    'release.py', '--tag', 'v1.0.1-build.2', '--zip', str(zip_path),
                    '--credential-user', 'YC426']):
                    with self.assertRaises(SystemExit) as raised:
                        release.main()
            self.assertEqual(raised.exception.code, 1)
            token.assert_not_called()
            push.assert_not_called()
            request.assert_not_called()
            self.assertIn('does not match', output.getvalue())


if __name__ == '__main__':
    unittest.main()
