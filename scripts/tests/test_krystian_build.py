import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import krystian_build as kb
import krystian_install_prepared as ki


class BuildHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name) / 'private'
        kb.secure_dir(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def builder(self):
        instance = object.__new__(kb.Builder)
        instance.root = self.root
        instance.runner = mock.Mock()
        instance.source = {'app': 'app-hash', 'tests': 'test-hash', 'commit': 'a' * 40,
                           'branch': kb.BRANCH, 'dirty': False, 'generation': 'generation'}
        instance.toolchain = 'xcode'
        instance.state = {'schema': 1}
        return instance

    def test_private_json_permissions_and_roundtrip(self):
        path = self.root / 'state.json'
        kb.write_json(path, {'key': 'private'})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(kb.read_json(path), {'key': 'private'})
        path.chmod(0o644)
        with self.assertRaises(kb.BuildError):
            kb.read_json(path)

    def test_unsafe_roots_rejected(self):
        for path in [pathlib.Path('/'), pathlib.Path.home(), kb.REPO, kb.REPO / 'outputs']:
            with self.subTest(path=str(path)), self.assertRaises(kb.BuildError):
                kb.safe_root(path)

    def test_symlink_records_and_clean_are_rejected(self):
        real = self.root / 'real'
        real.mkdir()
        (self.root / 'derived-data').mkdir()
        (self.root / 'derived-data/simulator').symlink_to(real)
        with self.assertRaises(kb.BuildError):
            kb.clean_cache(self.root, 'simulator')
        (self.root / 'record.json').symlink_to(real / 'secret')
        with self.assertRaises(kb.BuildError):
            kb.write_json(self.root / 'record.json', {})

    def test_clean_preserves_prepared_artifacts(self):
        (self.root / 'derived-data/simulator').mkdir(parents=True)
        (self.root / 'prepared').mkdir()
        kb.clean_cache(self.root, 'simulator')
        self.assertTrue((self.root / 'prepared').exists())
        with self.assertRaises(kb.BuildError):
            kb.clean_cache(self.root, '../prepared')

    def test_log_is_private_and_failure_does_not_disclose_output(self):
        secret = 'https://media.invalid/stream?token=SECRET'
        def failed(args, **kwargs):
            kwargs['stdout'].write(secret.encode())
            return subprocess.CompletedProcess(args, 65)
        runner = kb.Runner(self.root)
        with mock.patch.object(kb.subprocess, 'run', side_effect=failed):
            with self.assertRaises(kb.BuildError) as error:
                runner.run(['xcodebuild', 'build'], 'Build')
        self.assertNotIn('SECRET', str(error.exception))
        logs = list((self.root / 'logs').glob('*.log'))
        self.assertEqual(logs[0].stat().st_mode & 0o777, 0o600)
        self.assertIn(secret, logs[0].read_text())

    def test_missing_tool_has_safe_failure(self):
        with mock.patch.object(kb.subprocess, 'run', side_effect=FileNotFoundError('/private/name/tool')):
            with self.assertRaises(kb.BuildError) as error:
                kb.Runner(self.root).run(['missing'], 'Build')
        self.assertNotIn('/private', str(error.exception))

    def test_build_runner_rejects_all_physical_device_commands(self):
        for operation in [['info', 'apps'], ['install', 'app'], ['process', 'launch'], ['uninstall', 'app']]:
            with self.subTest(operation=operation), mock.patch.object(kb.subprocess, 'run') as run:
                with self.assertRaises(kb.BuildError):
                    kb.Runner(self.root).run(['xcrun', 'devicectl', 'device'] + operation, 'Device')
                run.assert_not_called()

    def test_legacy_script_is_always_prohibited(self):
        with self.assertRaises(kb.BuildError):
            kb.Runner(self.root, device_authorized=True).run(['bash', 'scripts/krystian-deploy.sh'], 'Legacy')

    def test_result_counts_and_missing_evidence(self):
        result = kb.test_summary(b'Executed 3 tests, with 0 failures\nExecuted 12 tests, with 2 failures')
        self.assertEqual(result, {'total': 12, 'passed': 10, 'failed': 2, 'skipped': 0})
        for raw in [b'BUILD SUCCEEDED', b'Executed 0 tests, with 0 failures']:
            with self.assertRaises(kb.BuildError):
                kb.test_summary(raw)

    def test_current_requires_matching_source_and_toolchain(self):
        b = self.builder()
        record = {'source': dict(b.source), 'toolchain': 'xcode'}
        self.assertTrue(b.current(record))
        record['source']['app'] = 'older'
        self.assertFalse(b.current(record))
        record['source']['app'] = 'app-hash'
        record['toolchain'] = 'different'
        self.assertFalse(b.current(record))

    def test_status_never_reports_stale_tests_as_current(self):
        b = self.builder()
        b.state['tests'] = {'passed': True, 'source': {'tests': 'old'}, 'toolchain': 'xcode',
                            'counts': {'total': 1275}, 'suite': ['https://secret.invalid/token']}
        output = json.dumps(b.summary())
        self.assertIn('STALE_OR_UNAVAILABLE', output)
        self.assertNotIn('1275', output)
        self.assertNotIn('secret.invalid', output)

    def test_report_only_exports_numeric_test_counts(self):
        b = self.builder()
        b.state['tests'] = {'passed': True, 'source': b.source, 'toolchain': 'xcode',
                            'counts': {'total': 12, 'passed': 12, 'failed': 0, 'skipped': 0,
                                       'private_url': 'https://secret.invalid'}, 'suite': []}
        self.assertNotIn('secret.invalid', json.dumps(b.summary()))

    def test_redaction_defence(self):
        raw = '/Users/private-person/private.log 192.0.2.1 someone@example.invalid ABCDE12345 00000000-0000000000000000 https://host.invalid/path?token=secret\nAuthorization: Bearer topsecret'
        result = kb.redact(raw)
        for secret in ['private-person', '192.0.2.1', 'someone@', 'ABCDE12345', '00000000-', 'host.invalid', 'topsecret']:
            self.assertNotIn(secret, result)

    def test_dangerous_cli_is_rejected_without_echoing_arguments(self):
        output = io.StringIO()
        with contextlib.redirect_stderr(output), self.assertRaises(SystemExit) as exit_code:
            kb.parser().parse_args(['install', '--token=secret'])
        self.assertNotEqual(exit_code.exception.code, 0)
        self.assertNotIn('secret', output.getvalue())

    def test_missing_simulator(self):
        b = self.builder()
        b.runner.run.return_value = (b'{"devices": {}}', {})
        with self.assertRaises(kb.BuildError):
            b.simulator()

    def test_only_tvos_simulators_are_selected(self):
        b = self.builder()
        b.runner.run.return_value = (json.dumps({'devices': {
            'iOS': [{'isAvailable': True, 'udid': 'phone'}],
            'tvOS': [{'isAvailable': True, 'udid': 'simulator'}]}}).encode(), {})
        self.assertEqual(b.simulator(), 'simulator')

    def test_build_failure_clears_previous_success(self):
        b = self.builder()
        b.state['build'] = {'passed': True}
        b.generate = mock.Mock()
        b.xcode_args = mock.Mock(return_value=['xcodebuild'])
        b.runner.run.return_value = (b'error: private', {'exit_code': 65, 'warnings': 0})
        with mock.patch.object(kb, 'source_state', return_value=b.source), self.assertRaises(kb.BuildError):
            b.build()
        self.assertFalse(b.state['build']['passed'])

    def test_successful_build_uses_arrays_and_never_run(self):
        b = self.builder()
        b.generate = mock.Mock()
        b.xcode_args = mock.Mock(return_value=['xcodebuild'])
        b.runner.run.return_value = (b'BUILD SUCCEEDED', {'exit_code': 0, 'warnings': 1})
        with mock.patch.object(kb, 'source_state', return_value=b.source):
            self.assertEqual(b.build()['build'], 'PASS')
        self.assertEqual(b.runner.run.call_args.args[0], ['xcodebuild', 'CODE_SIGNING_ALLOWED=NO', 'build'])

    def test_source_changed_during_build_is_rejected(self):
        b = self.builder()
        b.generate = mock.Mock()
        b.xcode_args = mock.Mock(return_value=['xcodebuild'])
        b.runner.run.return_value = (b'BUILD SUCCEEDED', {'exit_code': 0, 'warnings': 0})
        with mock.patch.object(kb, 'source_state', return_value={'app': 'changed'}), self.assertRaises(kb.BuildError):
            b.build()
        self.assertNotIn('build', b.state)

    def test_test_failure_is_not_cached_as_success(self):
        b = self.builder()
        b.generate = mock.Mock()
        b.xcode_args = mock.Mock(return_value=['xcodebuild'])
        b.runner.run.return_value = (b'Executed 10 tests, with 1 failure', {'exit_code': 65, 'warnings': 0})
        with mock.patch.object(kb, 'source_state', return_value=b.source), self.assertRaises(kb.BuildError):
            b.test(['NuvioTVTests/ExternalPlaybackReturnTests'])
        self.assertFalse(b.state['tests']['passed'])

    def test_artifact_hash_mismatch_fails_before_signing(self):
        b = self.builder()
        app = self.root / 'NuvioTV.app'
        app.mkdir()
        (app / 'Info.plist').write_bytes(b'changed')
        b.state['prepared'] = {'source': b.source, 'toolchain': b.toolchain, 'app': str(app), 'app_sha256': 'old'}
        with self.assertRaises(kb.BuildError):
            b.verify()
        b.runner.run.assert_not_called()

    def test_artifact_hash_covers_nested_files(self):
        app = self.root / 'app'
        app.mkdir()
        (app / 'nested').mkdir()
        file = app / 'nested/data'
        file.write_bytes(b'first')
        initial = kb.tree_hash(app)
        file.write_bytes(b'second')
        self.assertNotEqual(initial, kb.tree_hash(app))

    def signing_fixture(self):
        b = self.builder()
        b.config = mock.Mock(return_value={'team_id': 'TESTTEAM01', 'device_id': 'test-device'})
        app = self.root / 'NuvioTV.app'
        app.mkdir()
        info = {'CFBundleIdentifier': kb.BUNDLE, 'CFBundleShortVersionString': kb.version()[0], 'CFBundleVersion': kb.version()[1],
                'CFBundleSupportedPlatforms': ['AppleTVOS'], 'CFBundleDisplayName': kb.APP_NAME,
                'CFBundleURLTypes': [{'CFBundleURLSchemes': ['nuvio-krystian']}]}
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        entitlements = {'application-identifier': 'TESTTEAM01.' + kb.BUNDLE, 'com.apple.developer.team-identifier': 'TESTTEAM01',
                        'com.apple.security.application-groups': [kb.GROUP]}
        profile = {'Entitlements': entitlements, 'TeamIdentifier': ['TESTTEAM01'], 'ProvisionedDevices': ['test-device'],
                   'ExpirationDate': dt.datetime(2099, 1, 1), 'DeveloperCertificates': [b'certificate']}
        def run(args, *unused, **kwargs):
            if 'codesign' == args[0] and '--entitlements' in args:
                return plistlib.dumps(entitlements), {}
            if 'security' == args[0]:
                return plistlib.dumps(profile), {}
            if 'openssl' == args[0]:
                return b'notBefore=Jan  1 00:00:00 2020 GMT\nnotAfter=Jan  1 00:00:00 2099 GMT\n', {}
            if 'codesign' == args[0]:
                for item in args:
                    if item.startswith('--extract-certificates='):
                        pathlib.Path(item.split('=', 1)[1] + '0').write_bytes(b'certificate')
            return b'', {}
        b.runner.run.side_effect = run
        return b, app, profile, entitlements

    def test_valid_signing_and_no_private_export(self):
        b, app, profile, entitlements = self.signing_fixture()
        self.assertGreater(b.verify_bundle(app, kb.BUNDLE).year, 2030)

    def test_expired_profile_is_rejected(self):
        b, app, profile, entitlements = self.signing_fixture()
        profile['ExpirationDate'] = dt.datetime(2000, 1, 1)
        with self.assertRaisesRegex(kb.BuildError, 'expired'):
            b.verify_bundle(app, kb.BUNDLE)

    def test_wrong_device_is_rejected_without_echo(self):
        b, app, profile, entitlements = self.signing_fixture()
        profile['ProvisionedDevices'] = ['other-secret-device']
        with self.assertRaises(kb.BuildError) as error:
            b.verify_bundle(app, kb.BUNDLE)
        self.assertNotIn('secret', str(error.exception))

    def test_wrong_entitlement_is_rejected(self):
        b, app, profile, entitlements = self.signing_fixture()
        entitlements['com.apple.security.application-groups'] = ['unexpected']
        with self.assertRaises(kb.BuildError):
            b.verify_bundle(app, kb.BUNDLE)

    def test_invalid_signature_fails(self):
        b, app, profile, entitlements = self.signing_fixture()
        b.runner.run.side_effect = kb.BuildError('Signature verification failed.')
        with self.assertRaises(kb.BuildError):
            b.verify_bundle(app, kb.BUNDLE)

    def test_certificate_must_be_in_profile(self):
        b, app, profile, entitlements = self.signing_fixture()
        profile['DeveloperCertificates'] = [b'different-certificate']
        with self.assertRaises(kb.BuildError):
            b.verify_bundle(app, kb.BUNDLE)

    def test_missing_dependencies_fail_doctor(self):
        b = self.builder()
        b.runner.run.side_effect = kb.BuildError('Xcode unavailable.')
        with self.assertRaises(kb.BuildError):
            b.doctor()

    def test_installer_without_go_never_constructs_builder(self):
        with mock.patch.object(ki, 'Builder') as builder, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ki.main([]), 1)
        builder.assert_not_called()

    def test_installer_preflight_failure_cannot_install(self):
        b = self.builder()
        b.config = mock.Mock(return_value={'team_id': 'TESTTEAM01', 'device_id': 'test-device'})
        b.state['prepared'] = {'app': str(self.root / 'app')}
        b.verify = mock.Mock(side_effect=kb.BuildError('Expired'))
        with mock.patch.object(ki, 'Runner') as runner, self.assertRaises(kb.BuildError):
            ki.deploy(b, True, 'UPDATE-NUVIO-K')
        runner.assert_not_called()

    def installer_fixture(self):
        b = self.builder()
        b.config = mock.Mock(return_value={'team_id': 'TESTTEAM01', 'device_id': 'test-device',
                                           'installed_version': '3.4.5', 'installed_build': '76'})
        app = self.root / 'prepared/candidate/Payload/NuvioTV.app'
        b.state['prepared'] = {'app': str(app)}
        kb.write_json(app.parents[1] / 'manifest.json', b.state['prepared'])
        b.verify = mock.Mock()
        original = {'bundleIdentifier': 'Nuvio.Sideload', 'version': '3.4.5', 'bundleVersion': '76', 'url': 'original'}
        old = {'bundleIdentifier': kb.BUNDLE, 'version': '3.4.5', 'bundleVersion': '76'}
        new = dict(old, version=kb.version()[0], bundleVersion=kb.version()[1])
        return b, [old, original], [new, dict(original)]

    def test_installer_success_uses_only_expected_update_and_launch_with_mocked_tools(self):
        b, before, after = self.installer_fixture()
        with mock.patch.object(ki, 'Runner') as runner, mock.patch.object(ki, 'apps', side_effect=[before, after]):
            result = ki.deploy(b, True, 'UPDATE-NUVIO-K')
        self.assertEqual(result['update'], 'PASS')
        commands = [call.args[0] for call in runner.return_value.run.call_args_list]
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[0][1:5], ['devicectl', 'device', 'install', 'app'])
        self.assertEqual(commands[1][-1], kb.BUNDLE)
        self.assertFalse(any('uninstall' in command or 'Nuvio.Sideload' in command for command in commands))

    def test_installer_missing_existing_app_stops_before_mutation(self):
        b, before, after = self.installer_fixture()
        with mock.patch.object(ki, 'Runner') as runner, mock.patch.object(ki, 'apps', return_value=before[1:]), self.assertRaises(kb.BuildError):
            ki.deploy(b, True, 'UPDATE-NUVIO-K')
        runner.return_value.run.assert_not_called()

    def test_installer_known_signing_mismatch_stops(self):
        b, before, after = self.installer_fixture()
        before[0]['teamIdentifier'] = 'OTHERTEAM1'
        with mock.patch.object(ki, 'Runner') as runner, mock.patch.object(ki, 'apps', return_value=before), self.assertRaises(kb.BuildError):
            ki.deploy(b, True, 'UPDATE-NUVIO-K')
        runner.return_value.run.assert_not_called()

    def test_installer_failed_update_never_uninstalls_or_launches(self):
        b, before, after = self.installer_fixture()
        with mock.patch.object(ki, 'Runner') as runner, mock.patch.object(ki, 'apps', return_value=before):
            runner.return_value.run.side_effect = kb.BuildError('Update failed')
            with self.assertRaises(kb.BuildError):
                ki.deploy(b, True, 'UPDATE-NUVIO-K')
        self.assertEqual(len(runner.return_value.run.call_args_list), 1)
        self.assertEqual(kb.read_json(b.root / 'deployment.json')['status'], 'STOPPED_REQUIRES_REVIEW')

    def test_installer_wrong_updated_version_does_not_launch(self):
        b, before, after = self.installer_fixture()
        after[0]['bundleVersion'] = '76'
        with mock.patch.object(ki, 'Runner') as runner, mock.patch.object(ki, 'apps', side_effect=[before, after]), self.assertRaises(kb.BuildError):
            ki.deploy(b, True, 'UPDATE-NUVIO-K')
        self.assertEqual(len(runner.return_value.run.call_args_list), 1)

    def test_cli_failure_returns_nonzero_and_safe_json(self):
        with mock.patch.object(kb, 'Builder', side_effect=RuntimeError('/Users/private-person/secret')), contextlib.redirect_stdout(io.StringIO()) as output:
            result = kb.execute(kb.parser().parse_args(['status', '--json']))
        self.assertEqual(result, 1)
        self.assertNotIn('private-person', output.getvalue())
        self.assertEqual(json.loads(output.getvalue())['status'], 'FAIL')

    def test_lock_permission_failure_never_leaks_path(self):
        with mock.patch.object(kb, 'exclusive_lock', side_effect=PermissionError('/Users/private-person/secret')), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(kb.main(['status', '--json']), 1)
        self.assertNotIn('private-person', output.getvalue())
        self.assertEqual(json.loads(output.getvalue())['status'], 'FAIL')

    def test_incremental_signature_failure_gets_one_clean_retry_and_all_checks(self):
        b = self.builder()
        b.build = mock.Mock()
        b.verify = mock.Mock(side_effect=[kb.BuildError('Signature verification: failed (exit 1); private log retained.'), {}])
        b.require_fresh_profiles = mock.Mock()
        started = kb.dt.datetime.now(kb.dt.timezone.utc)
        app = b.build_preparation_candidate(False, started)
        self.assertEqual(b.build.call_args_list, [mock.call(clean=False, device=True), mock.call(clean=True, device=True)])
        self.assertEqual(b.verify.call_count, 2)
        b.require_fresh_profiles.assert_called_once_with(app, started)

    def test_clean_retry_does_not_bypass_other_checks_or_loop(self):
        for clean, message in [(False, 'Signing team mismatch.'),
                               (True, 'Signature verification: failed (exit 1); private log retained.')]:
            b = self.builder()
            b.build = mock.Mock()
            b.verify = mock.Mock(side_effect=kb.BuildError(message))
            b.require_fresh_profiles = mock.Mock()
            with self.assertRaises(kb.BuildError):
                b.build_preparation_candidate(clean, kb.dt.datetime.now(kb.dt.timezone.utc))
            self.assertEqual(b.build.call_count, 1)
            b.require_fresh_profiles.assert_not_called()

    def provisioning_fixture(self):
        b = self.builder()
        b.config = mock.Mock(return_value={'team_id': 'TESTTEAM01', 'device_id': 'test-device'})
        cache = self.root / 'profile-cache'
        cache.mkdir()
        b.profile_directories = mock.Mock(return_value=[cache])
        profiles = {}
        for name, team, bundle in [('app', 'TESTTEAM01', kb.BUNDLE),
                                   ('extension', 'TESTTEAM01', kb.BUNDLE + '.TopShelf'),
                                   ('original', 'TESTTEAM01', 'Nuvio.Sideload'),
                                   ('wildcard', 'TESTTEAM01', '*'),
                                   ('other-team', 'OTHERTEAM1', kb.BUNDLE)]:
            path = cache / (name + '.mobileprovision')
            path.write_bytes(name.encode())
            profiles[path] = {'TeamIdentifier': [team], 'Entitlements': {
                'application-identifier': team + '.' + bundle, 'get-task-allow': True}}
        b.read_profile = mock.Mock(side_effect=lambda path: profiles[path])
        return b, cache

    def test_profile_refresh_moves_only_exact_fork_profiles(self):
        b, cache = self.provisioning_fixture()
        with b.fresh_provisioning():
            self.assertFalse((cache / 'app.mobileprovision').exists())
            self.assertFalse((cache / 'extension.mobileprovision').exists())
            for name in ['original', 'wildcard', 'other-team']:
                self.assertEqual((cache / (name + '.mobileprovision')).read_bytes(), name.encode())
        self.assertEqual(b.state['provisioning_refresh']['status'], 'PASS')
        self.assertEqual(len(list((self.root / 'profile-backups').glob('*/*.mobileprovision'))), 2)

    def test_profile_refresh_failure_restores_backups_without_overwriting_new_profile(self):
        b, cache = self.provisioning_fixture()
        with self.assertRaises(kb.BuildError):
            with b.fresh_provisioning():
                (cache / 'app.mobileprovision').write_bytes(b'new-profile')
                raise kb.BuildError('test renewal failure')
        self.assertEqual((cache / 'app.mobileprovision').read_bytes(), b'new-profile')
        self.assertEqual((cache / 'extension.mobileprovision').read_bytes(), b'extension')
        self.assertEqual(b.state['provisioning_refresh']['status'], 'FAILED')

    def test_profile_refresh_rejects_symlink_cache(self):
        b, cache = self.provisioning_fixture()
        link = self.root / 'linked-cache'
        link.symlink_to(cache, target_is_directory=True)
        b.profile_directories.return_value = [link]
        with self.assertRaisesRegex(kb.BuildError, 'Unsafe provisioning'):
            with b.fresh_provisioning():
                self.fail('Must reject a symlink before moving profiles')
        self.assertTrue((cache / 'app.mobileprovision').exists())

    def test_fresh_profile_checks_both_targets_and_rejects_old_or_short_lived_profiles(self):
        b = self.builder()
        now = kb.dt.datetime.now(kb.dt.timezone.utc)
        fresh = {'CreationDate': now, 'ExpirationDate': now + kb.dt.timedelta(days=7)}
        app = self.root / 'app'
        b.read_profile = mock.Mock(return_value=fresh)
        b.require_fresh_profiles(app, now)
        self.assertEqual(b.read_profile.call_count, 2)
        for invalid in [dict(fresh, CreationDate=now - kb.dt.timedelta(days=2)),
                        dict(fresh, ExpirationDate=now + kb.dt.timedelta(days=5)),
                        {'ExpirationDate': fresh['ExpirationDate']}]:
            b.read_profile.side_effect = [fresh, invalid]
            with self.assertRaises(kb.BuildError):
                b.require_fresh_profiles(app, now)

    def test_prepare_never_reuses_artifact_without_renewal(self):
        b = self.builder()
        b.state['tests'] = {'source': b.source, 'toolchain': b.toolchain, 'passed': True}
        b.state['prepared'] = {'source': b.source, 'toolchain': b.toolchain}
        with mock.patch.object(b, 'config'), mock.patch.object(b, 'fresh_provisioning', side_effect=kb.BuildError('renewal requested')) as refresh:
            with self.assertRaisesRegex(kb.BuildError, 'renewal requested'):
                b.prepare()
            refresh.assert_called_once()

    def test_prepare_rejects_old_branch_before_build(self):
        self.assertEqual(kb.BRANCH, 'fix/infuse-progress-ui-stream-picker-performance')
        b = self.builder()
        b.source['branch'] = 'fix/infuse-return-progress-reliability'
        with mock.patch.object(b, 'config'), mock.patch.object(b, 'build') as build, self.assertRaisesRegex(kb.BuildError, 'development branch'):
            b.prepare()
        build.assert_not_called()

    def test_prepare_requires_current_test_evidence(self):
        b = self.builder()
        with mock.patch.object(b, 'config'), mock.patch.object(b, 'build') as build, self.assertRaises(kb.BuildError):
            b.prepare()
        build.assert_not_called()

    def test_fingerprints_survive_staging_and_commit(self):
        repo = self.root / 'fixture'
        repo.mkdir()
        def git(*args):
            return subprocess.run(['git', '-C', str(repo), *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git('init')
        git('config', 'user.email', 'fixture@example.invalid')
        git('config', 'user.name', 'Fixture')
        source = repo / 'tvosApp/NuvioTV/Sources/Fixture.swift'
        source.parent.mkdir(parents=True)
        source.write_text('original')
        git('add', '.')
        git('commit', '-m', 'fixture')
        with mock.patch.object(kb, 'REPO', repo):
            before = kb.source_state(repo)
            source.write_text('changed')
            changed = kb.source_state(repo)
            self.assertNotEqual(before['app'], changed['app'])
            git('add', '.')
            self.assertEqual(changed['app'], kb.source_state(repo)['app'])
            git('commit', '-m', 'changed')
            self.assertEqual(changed['app'], kb.source_state(repo)['app'])
            (repo / 'README.md').write_text('docs only')
            self.assertEqual(changed['app'], kb.source_state(repo)['app'])
            (repo / '.gitignore').write_text('Ignored.swift\n')
            (source.parent / 'Ignored.swift').write_text('compiled ignored source')
            self.assertNotEqual(changed['app'], kb.source_state(repo)['app'])

    def test_capture_keeps_json_separate_from_diagnostics(self):
        def capture(args, **kwargs):
            kwargs['stderr'].write(b'private diagnostic\n')
            return subprocess.CompletedProcess(args, 0, stdout=b'{"safe": true}')
        with mock.patch.object(kb.subprocess, 'run', side_effect=capture):
            raw, record = kb.Runner(self.root).run(['xcrun', 'simctl'], 'Simulator', capture=True)
        self.assertEqual(json.loads(raw), {'safe': True})
        self.assertIn('private diagnostic', pathlib.Path(record['log']).read_text())


if __name__ == '__main__':
    unittest.main()
