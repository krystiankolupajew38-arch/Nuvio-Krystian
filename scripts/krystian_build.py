#!/usr/bin/env python3
"""Private local build preparation. This program never installs or launches on a device."""
import argparse
import contextlib
import fcntl
import datetime as dt
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[1]
BRANCH = 'fix/infuse-progress-ui-stream-picker-performance'
BUNDLE = 'com.krystian.nuvio'
GROUP = 'group.com.krystian.nuvio'
APP_NAME = 'Nuvio - Krystian'
SCHEMA = 1


class BuildError(Exception):
    """A public, deliberately non-sensitive failure message."""


class PrivateParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, 'Unsupported command or arguments. Use --help.\n')


@contextlib.contextmanager
def exclusive_lock(root):
    secure_dir(root)
    lock_path = root / 'operation.lock'
    require(not lock_path.is_symlink(), 'Unsafe lock file.')
    with lock_path.open('a') as lock:
        lock_path.chmod(0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BuildError('Another build-helper operation is active.') from None
        yield
        fcntl.flock(lock, fcntl.LOCK_UN)


def require(condition, message):
    if not condition:
        raise BuildError(message)


def private_home():
    return pathlib.Path(os.environ.get('NUVIO_K_BUILD_HOME',
        str(pathlib.Path.home() / 'Library/Application Support/NuvioKrystianBuild'))).expanduser()


def safe_root(path, repo=REPO):
    path = pathlib.Path(path).absolute()
    require(not path.is_symlink(), 'Private root must not be a symlink.')
    resolved = path.resolve()
    require(resolved not in [pathlib.Path('/'), pathlib.Path.home(), repo.resolve()], 'Unsafe private root.')
    require(repo.resolve() not in resolved.parents, 'Private output must be outside the repository.')
    require(resolved not in repo.resolve().parents, 'Private output must not contain the repository.')
    return resolved


def secure_dir(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(not path.is_symlink(), 'Private directories must not be symlinks.')
    path.chmod(0o700)


def write_json(path, value):
    secure_dir(path.parent)
    require(not path.is_symlink(), 'Private records must not be symlinks.')
    fd, temporary = tempfile.mkstemp(prefix='.record-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path, default=None):
    if not path.exists():
        return default
    require(not path.is_symlink() and stat.S_IMODE(path.stat().st_mode) & 0o077 == 0,
            'Private record permissions must be 0600.')
    try:
        return json.loads(path.read_text())
    except (ValueError, OSError):
        raise BuildError('Private record is unreadable; inspect it locally.') from None


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def tree_hash(path):
    require(path.is_dir() and not path.is_symlink(), 'Artifact bundle is missing or unsafe.')
    result = hashlib.sha256()
    for item in sorted(path.rglob('*')):
        result.update(str(item.relative_to(path)).encode())
        result.update(str(stat.S_IMODE(item.lstat().st_mode)).encode())
        if item.is_symlink():
            require(path.resolve() in item.resolve().parents, 'Artifact contains an external symlink.')
            result.update(os.readlink(item).encode())
        elif item.is_file():
            result.update(file_hash(item).encode())
    return result.hexdigest()


def redact(text, secrets=()):
    # Reports use a fixed schema and never include raw diagnostics. This is a
    # secondary defence for locally requested excerpts, not a general log exporter.
    for secret in sorted((str(s) for s in secrets if s), key=len, reverse=True):
        text = text.replace(secret, '[private]')
    text = re.sub(r'(?i)(?:https?|smb)://[^\s\"<>]+', '[url]', text)
    text = re.sub(r'(?i)(authorization|cookie|token|password|secret|api[_-]?key|development_team)\s*[:=]\s*[^\r\n]+', r'\1=[private]', text)
    text = re.sub(r'/Users/[^\s\"\']+', '[private-path]', text)
    text = re.sub(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', '[address]', text)
    text = re.sub(r'(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|\b[0-9a-f]{8}-[0-9a-f]{16}\b', '[device]', text)
    text = re.sub(r'\b[A-Z0-9]{10}\b', '[identifier]', text)
    text = re.sub(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}', '[account]', text)
    return text


class Runner:
    def __init__(self, root, verbose=False, device_authorized=False):
        self.root = root
        self.verbose = verbose
        self.device_authorized = device_authorized

    def run(self, args, label, cwd=REPO, check=True, capture=False):
        args = [str(a) for a in args]
        require(all('\x00' not in a for a in args), 'Invalid command argument.')
        require(not any('krystian-deploy.sh' in a for a in args), 'Legacy deployment is prohibited.')
        if 'devicectl' in args:
            readonly = args[1:5] == ['devicectl', 'device', 'info', 'apps']
            install = args[1:5] == ['devicectl', 'device', 'install', 'app']
            launch = args[1:5] == ['devicectl', 'device', 'process', 'launch']
            require(self.device_authorized and (readonly or install or launch), 'Device operations are unavailable in the build helper.')
        secure_dir(self.root / 'logs')
        log = self.root / 'logs' / (time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8] + '.log')
        started = time.monotonic()
        if self.verbose:
            print(label + ': running (details stay in private logs)', file=sys.stderr)
        try:
            with log.open('xb') as stream:
                log.chmod(0o600)
                result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE if capture else stream,
                                        stderr=stream if capture else subprocess.STDOUT,
                                        stdin=subprocess.DEVNULL, shell=False)
                if capture:
                    stream.write(result.stdout)
        except OSError:
            raise BuildError(label + ': tool unavailable; run doctor.') from None
        raw = log.read_bytes()
        record = {'exit_code': result.returncode, 'log': str(log),
                  'seconds': round(time.monotonic() - started, 2),
                  'warnings': len(re.findall(rb'\bwarning:', raw))}
        if check and result.returncode:
            raise BuildError(label + ': failed (exit ' + str(result.returncode) + '); private log retained.')
        return result.stdout if capture else raw, record


def git(*args, repo=REPO):
    try:
        return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        raise BuildError('Git inspection failed.') from None


def source_state(repo=REPO):
    commit = git('rev-parse', 'HEAD', repo=repo).decode().strip()
    branch = git('branch', '--show-current', repo=repo).decode().strip()
    index = {}
    for row in git('ls-files', '--stage', '-z', repo=repo).decode().split('\0'):
        if row:
            metadata, name = row.split('\t', 1)
            mode, oid, stage = metadata.split()
            index[name] = (mode, oid)
    changed = set(git('diff', '--name-only', '-z', repo=repo).decode().split('\0'))
    paths = git('ls-files', '--cached', '--others', '--exclude-standard', '-z', repo=repo).decode().split('\0')
    for pattern in ('tvosApp/NuvioTV/Sources/**/*.swift', 'tvosApp/TopShelf/**/*.swift',
                    'tvosApp/NuvioTVTests/**/*.swift', 'tvosApp/NuvioTVUITests/**/*.swift'):
        paths.extend(str(path.relative_to(repo)) for path in repo.glob(pattern))
    app = hashlib.sha256()
    tests = hashlib.sha256()
    generation = hashlib.sha256()
    for name in sorted(set(filter(None, paths))):
        path = repo / name
        if name == 'MPVKit' and path.is_dir():
            sub = source_state(path)
            content_id = sub['commit'] + sub['app'] + sub['tests']
            mode = 'submodule'
        else:
            if not (name.startswith(('tvosApp/', 'Vendor/', 'MPVKit/', 'Tuist/')) or name in ('mise.toml', 'Tuist.swift', 'Workspace.swift', 'scripts/krystian-generate.sh') or repo != REPO):
                continue
            if name in index and name not in changed:
                mode, content_id = index[name]
            elif path.is_file():
                value = path.read_bytes()
                mode = '100755' if path.stat().st_mode & 0o111 else '100644'
                # Match Git's content ID, so staging/committing unchanged source
                # does not invalidate evidence. Git detects dirty tracked files;
                # only those and untracked compilation inputs need reading again.
                content_id = hashlib.sha1(b'blob ' + str(len(value)).encode() + b'\0' + value).hexdigest()
            else:
                mode, content_id = 'missing', '<deleted>'
        is_test = name.startswith(('tvosApp/NuvioTVTests/', 'tvosApp/NuvioTVUITests/'))
        identity = name.encode() + mode.encode() + content_id.encode()
        if not is_test:
            app.update(identity)
        tests.update(identity)
        generation.update(name.encode())
        if path.is_file() and (path.name in ('Project.swift', 'Package.swift', 'Package.resolved', 'mise.toml', 'Tuist.swift', 'Workspace.swift', 'krystian-generate.sh') or name.startswith(('tvosApp/Configurations/', 'Tuist/'))):
            generation.update(path.read_bytes())
    # Local signing settings affect builds, although they must never be committed.
    local_signing = repo / 'tvosApp/Configurations/Signing.local.xcconfig'
    if local_signing.is_file():
        value = local_signing.read_bytes()
        for target in (app, tests, generation):
            target.update(value)
    resolved = repo / 'tvosApp/NuvioTV.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    if resolved.is_file():
        for target in (app, tests):
            target.update(resolved.read_bytes())
    generated = [repo / 'tvosApp/NuvioTV.xcodeproj/project.pbxproj',
                 repo / 'tvosApp/NuvioTV.xcworkspace/contents.xcworkspacedata']
    generated += list((repo / 'tvosApp/NuvioTV.xcodeproj/xcshareddata').glob('**/*.xcscheme'))
    generated += list((repo / 'tvosApp/NuvioTV.xcworkspace/xcshareddata').glob('**/*.xcscheme'))
    for path in sorted(generated):
        if path.is_file():
            for target in (app, tests):
                target.update(str(path.relative_to(repo)).encode() + path.read_bytes())
    return {'commit': commit, 'branch': branch, 'dirty': bool(git('status', '--porcelain', repo=repo)),
            'app': app.hexdigest(), 'tests': tests.hexdigest(), 'generation': generation.hexdigest()}


def version(repo=REPO):
    text = (repo / 'tvosApp/Project.swift').read_text()
    found = [re.search(r'let ' + key + r' = "([0-9.]+)"', text) for key in ('marketingVersion', 'projectVersion')]
    require(all(found), 'Project version is not recognized.')
    return tuple(item.group(1) for item in found)


def test_summary(raw):
    matches = re.findall(rb'Executed (\d+) tests?, with (\d+) failures?', raw)
    require(matches, 'Test result did not contain an executed test count.')
    total, failed = map(int, matches[-1])
    require(total > 0, 'No tests were executed.')
    skipped = len(re.findall(rb"Test Case .* skipped ", raw))
    return {'total': total, 'passed': total - failed - skipped, 'failed': failed, 'skipped': skipped}


def clean_cache(root, selected):
    require(selected in ('simulator', 'device'), 'Select exactly one generated cache.')
    path = root / 'derived-data' / selected
    require(not path.is_symlink() and not path.parent.is_symlink(), 'Refusing symlink cache deletion.')
    require(path.resolve().parent == (root / 'derived-data').resolve(), 'Unsafe cache path.')
    if path.exists():
        shutil.rmtree(path)


class Builder:
    def __init__(self, root=None, verbose=False):
        os.umask(0o077)
        self.root = safe_root(root or private_home())
        secure_dir(self.root)
        self.runner = Runner(self.root, verbose)
        self.state = read_json(self.root / 'state.json', {'schema': SCHEMA})
        require(self.state.get('schema') == SCHEMA, 'Unsupported local state version.')
        self.source = source_state()
        self.toolchain = self.toolchain_id()

    def save(self):
        write_json(self.root / 'state.json', self.state)

    def toolchain_id(self):
        try:
            raw = subprocess.check_output(['xcodebuild', '-version'], stderr=subprocess.DEVNULL)
            selected = subprocess.check_output(['xcode-select', '-p'], stderr=subprocess.DEVNULL)
            return digest(raw + selected)
        except (OSError, subprocess.CalledProcessError):
            return 'unavailable'

    def config(self):
        config = read_json(self.root / 'config.json')
        require(isinstance(config, dict) and config.get('team_id') and config.get('device_id'),
                'Private signing configuration is missing; see docs/CODEX_WORKFLOW.md.')
        require(re.fullmatch(r'[A-Z0-9]{10}', config['team_id']), 'Invalid private team configuration.')
        require(re.fullmatch(r'[A-Za-z0-9-]+', config['device_id']), 'Invalid private device configuration.')
        return config

    @staticmethod
    def profile_directories():
        return [pathlib.Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
                pathlib.Path.home() / 'Library/MobileDevice/Provisioning Profiles']

    def read_profile(self, path):
        raw, _ = self.runner.run(['security', 'cms', '-D', '-i', str(path)],
                                 'Provisioning inspection', capture=True)
        try:
            return plistlib.loads(raw[raw.index(b'<?xml'):])
        except (ValueError, plistlib.InvalidFileException):
            raise BuildError('Provisioning profile could not be decoded.') from None

    @contextlib.contextmanager
    def fresh_provisioning(self):
        """Prompt automatic signing using only this fork's exact cached profiles.

        Backups remain private. No certificate revocation, wildcard profile,
        unrelated bundle, or physical-device operation is part of this flow.
        """
        config = self.config()
        expected = {config['team_id'] + '.' + BUNDLE,
                    config['team_id'] + '.' + BUNDLE + '.TopShelf'}
        backup = self.root / 'profile-backups' / uuid.uuid4().hex
        secure_dir(backup)
        moved = []
        started = dt.datetime.now(dt.timezone.utc)
        self.state['provisioning_refresh'] = {'status': 'PENDING', 'started_utc': started.isoformat()}
        self.save()
        try:
            for parent in self.profile_directories():
                require(not parent.is_symlink(), 'Unsafe provisioning cache directory.')
                for path in sorted(parent.glob('*.mobileprovision')):
                    require(not path.is_symlink(), 'Unsafe provisioning cache entry.')
                    profile = self.read_profile(path)
                    entitlements = profile.get('Entitlements', {})
                    if (profile.get('TeamIdentifier') != [config['team_id']]
                            or entitlements.get('application-identifier') not in expected
                            or entitlements.get('get-task-allow') is not True):
                        continue
                    destination = backup / (str(len(moved)) + '.mobileprovision')
                    # Record the recovery mapping before moving any cached file.
                    write_json(backup / 'recovery.json', {
                        'profiles': [{'original': str(a), 'backup': str(b)} for a, b in moved + [(path, destination)]]})
                    shutil.move(str(path), str(destination))
                    destination.chmod(0o600)
                    moved.append((path, destination))
            yield started
        except BaseException:
            for original, saved in moved:
                # Never overwrite a profile Xcode wrote while attempting renewal.
                if not original.exists():
                    shutil.copy2(saved, original)
                    original.chmod(0o600)
            self.state['provisioning_refresh']['status'] = 'FAILED'
            self.save()
            raise
        else:
            self.state['provisioning_refresh']['status'] = 'PASS'
            self.save()

    def require_fresh_profiles(self, app, started):
        now = dt.datetime.now(dt.timezone.utc)
        for bundle in [app, app / 'PlugIns/TopShelf.appex']:
            profile = self.read_profile(bundle / 'embedded.mobileprovision')
            created = profile.get('CreationDate')
            expires = profile.get('ExpirationDate')
            require(isinstance(created, dt.datetime) and isinstance(expires, dt.datetime),
                    'Provisioning freshness dates are unavailable.')
            created = created.replace(tzinfo=dt.timezone.utc)
            expires = expires.replace(tzinfo=dt.timezone.utc)
            require(started - dt.timedelta(minutes=5) <= created <= now + dt.timedelta(minutes=5),
                    'Xcode did not return freshly issued profiles; preparation stopped. Check Xcode account provisioning.')
            require(expires >= now + dt.timedelta(days=6),
                    'Fresh provisioning has less than six days remaining; preparation stopped.')

    def signing_context(self):
        config = self.config()
        hasher = hashlib.sha256(json.dumps(config, sort_keys=True).encode())
        for parent in self.profile_directories():
            for path in sorted(parent.glob('*.mobileprovision')):
                hasher.update(path.read_bytes())
        raw, _ = self.runner.run(['security', 'find-identity', '-v', '-p', 'codesigning'], 'Signing inventory')
        hasher.update(raw)
        return hasher.hexdigest()

    def current(self, record, kind='app'):
        return bool(record and record.get('source', {}).get(kind) == self.source[kind]
                    and record.get('toolchain') == self.toolchain)

    def summary(self):
        build = self.state.get('build')
        tests = self.state.get('tests')
        prepared = self.state.get('prepared')
        artifact_status = 'UNAVAILABLE'
        signing_status = 'UNVERIFIED'
        if prepared:
            try:
                unchanged = self.current(prepared) and tree_hash(pathlib.Path(prepared['app'])) == prepared['app_sha256']
                unchanged = unchanged and file_hash(pathlib.Path(prepared['ipa'])) == prepared['ipa_sha256']
                valid_time = dt.datetime.fromisoformat(prepared['expires']) > dt.datetime.now(dt.timezone.utc)
                signing_current = self.signing_context() == prepared.get('signing_context')
                signing_status = 'PASS' if unchanged and valid_time and signing_current else 'REVERIFY'
                artifact_status = 'VERIFIED' if signing_status == 'PASS' else 'STALE'
            except (BuildError, OSError, KeyError, ValueError):
                artifact_status = 'STALE'
        result = {
            'branch': BRANCH if self.source['branch'] == BRANCH else '[other branch]',
            'commit': self.source['commit'], 'working_tree': 'MODIFIED' if self.source['dirty'] else 'CLEAN',
            'build': 'PASS' if self.current(build) and build.get('passed') else 'STALE_OR_UNAVAILABLE',
            'tests': {key: tests['counts'][key] for key in ('total', 'passed', 'failed', 'skipped') if type(tests['counts'].get(key)) is int} if self.current(tests, 'tests') and tests.get('passed') else 'STALE_OR_UNAVAILABLE',
            'test_scope': [item if re.fullmatch(r'NuvioTVTests(?:/[A-Za-z_][A-Za-z0-9_]*){1,2}|ALL_REGISTERED_UNIT_TESTS', item) else '[private]' for item in tests.get('suite', [])] if tests else [], 'signing': signing_status,
            'artifact': artifact_status, 'artifact_location': '<private-build-home>/prepared' if prepared else None,
            'provisioning_refresh': self.state.get('provisioning_refresh', {}).get('status', 'NOT_REQUESTED'),
            'deployment': 'NOT PERFORMED BY BUILD HELPER',
        }
        return result

    def doctor(self):
        raw, _ = self.runner.run(['xcodebuild', '-version'], 'Xcode')
        xcode = re.search(rb'Xcode ([0-9.]+)', raw)
        require(xcode, 'Xcode version unavailable.')
        tuist = REPO / '.tools/tuist/tuist'
        if not tuist.is_file():
            tuist = shutil.which('tuist')
        require(tuist, 'Tuist is missing; use the pinned toolchain.')
        raw, _ = self.runner.run([tuist, 'version'], 'Tuist')
        require(raw.strip() == b'4.207.0', 'Tuist differs from the pinned version.')
        simulator = self.simulator()
        config = self.config()
        raw, _ = self.runner.run(['security', 'find-identity', '-v', '-p', 'codesigning'], 'Signing inventory')
        require(re.search(rb'[1-9]\d* valid identities found', raw), 'No valid signing identity is available.')
        return {'xcode': xcode.group(1).decode(), 'tuist': '4.207.0', 'simulator': 'AVAILABLE',
                'private_signing_config': 'PRESENT', 'signing_identity': 'AVAILABLE', 'deployment': 'NOT PERFORMED'}

    def simulator(self):
        raw, _ = self.runner.run(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], 'Simulator inventory', capture=True)
        try:
            devices = json.loads(raw)['devices']
            for runtime, entries in devices.items():
                if 'tvOS' in runtime:
                    for entry in entries:
                        if entry.get('isAvailable'):
                            return entry['udid']
        except (ValueError, KeyError, TypeError):
            raise BuildError('Simulator inventory is unreadable.') from None
        raise BuildError('No compatible tvOS simulator is available.')

    def generate(self):
        workspace = REPO / 'tvosApp/NuvioTV.xcworkspace/contents.xcworkspacedata'
        old = self.state.get('generation', {})
        if workspace.is_file() and old.get('fingerprint') == self.source['generation'] and old.get('toolchain') == self.toolchain:
            return {'workspace': 'CURRENT'}
        self.runner.run([REPO / 'scripts/krystian-generate.sh'], 'Workspace generation')
        require(workspace.is_file(), 'Workspace generation did not produce a workspace.')
        self.source = source_state()
        self.state['generation'] = {'fingerprint': self.source['generation'], 'toolchain': self.toolchain}
        self.save()
        return {'workspace': 'GENERATED'}

    def xcode_args(self, device=False):
        return ['xcodebuild', '-workspace', 'tvosApp/NuvioTV.xcworkspace', '-scheme', 'NuvioTV',
                '-configuration', 'Debug', '-destination', 'generic/platform=tvOS' if device else 'platform=tvOS Simulator,id=' + self.simulator(),
                '-derivedDataPath', str(self.root / 'derived-data' / ('device' if device else 'simulator'))]

    def build(self, clean=False, device=False):
        self.generate()
        record_key = 'device_build' if device else 'build'
        self.state.pop(record_key, None)
        self.save()
        args = self.xcode_args(device)
        args += ['-allowProvisioningUpdates'] if device else ['CODE_SIGNING_ALLOWED=NO']
        raw, record = self.runner.run(args + (['clean'] if clean else []) + ['build'], 'Signed build' if device else 'Simulator build', check=False)
        require(source_state()['app'] == self.source['app'], 'Application source changed during build; results are not current.')
        record.update(source=self.source, toolchain=self.toolchain, passed=record['exit_code'] == 0)
        self.state[record_key] = record
        self.save()
        require(record['passed'], 'Build failed; inspect the private log.')
        return {'build': 'PASS', 'warnings': record['warnings']}

    def test(self, suites, clean=False):
        for suite in suites:
            require(re.fullmatch(r'NuvioTVTests(?:/[A-Za-z_][A-Za-z0-9_]*){1,2}', suite), 'Invalid test suite selector.')
        self.generate()
        self.state.pop('tests', None)
        self.save()
        secure_dir(self.root / 'test-results')
        result = self.root / 'test-results' / (uuid.uuid4().hex + '.xcresult')
        args = self.xcode_args() + ['CODE_SIGNING_ALLOWED=NO', '-resultBundlePath', str(result)]
        args += ['-only-testing:' + suite for suite in suites]
        raw, record = self.runner.run(args + (['clean'] if clean else []) + ['test'], 'Simulator tests', check=False)
        require(source_state()['tests'] == self.source['tests'], 'Test source changed during execution; results are not current.')
        counts = test_summary(raw)
        record.update(source=self.source, toolchain=self.toolchain, passed=record['exit_code'] == 0 and counts['failed'] == 0,
                      counts=counts, suite=suites or ['ALL_REGISTERED_UNIT_TESTS'], result=str(result))
        self.state['tests'] = record
        self.save()
        require(record['passed'], 'Tests failed; inspect the private result bundle.')
        return {'tests': counts, 'scope': record['suite'], 'warnings': record['warnings']}

    def verify_bundle(self, app, bundle_id):
        config = self.config()
        expected_version, expected_build = version()
        try:
            info = plistlib.loads((app / 'Info.plist').read_bytes())
            require(info['CFBundleIdentifier'] == bundle_id, 'Unexpected bundle identifier.')
            require((info['CFBundleShortVersionString'], info['CFBundleVersion']) == (expected_version, expected_build), 'Unexpected artifact version.')
            require('AppleTVOS' in info['CFBundleSupportedPlatforms'], 'Not a tvOS device artifact.')
            if bundle_id == BUNDLE:
                require(info['CFBundleDisplayName'] == APP_NAME, 'Branding mismatch.')
                schemes = [s for entry in info.get('CFBundleURLTypes', []) for s in entry.get('CFBundleURLSchemes', [])]
                require(schemes == ['nuvio-krystian'], 'Callback scheme mismatch.')
            self.runner.run(['codesign', '--verify', '--deep', '--strict', str(app)], 'Signature verification')
            raw, _ = self.runner.run(['codesign', '-d', '--entitlements', ':-', str(app)], 'Entitlement inspection', capture=True)
            # codesign writes status to stderr; the plist starts after that prefix.
            entitlements = plistlib.loads(raw[raw.index(b'<?xml'):])
            raw, _ = self.runner.run(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')], 'Provisioning inspection', capture=True)
            profile = plistlib.loads(raw[raw.index(b'<?xml'):])
            for values in (entitlements, profile['Entitlements']):
                require(values['application-identifier'] == config['team_id'] + '.' + bundle_id, 'Signing application identity mismatch.')
                require(values['com.apple.developer.team-identifier'] == config['team_id'], 'Signing team mismatch.')
                require(values['com.apple.security.application-groups'] == [GROUP], 'App Group mismatch.')
            require(profile['TeamIdentifier'] == [config['team_id']], 'Provisioning team mismatch.')
            require(config['device_id'] in profile['ProvisionedDevices'], 'Apple TV target is not provisioned.')
            expiry = profile['ExpirationDate'].replace(tzinfo=dt.timezone.utc)
            require(expiry > dt.datetime.now(dt.timezone.utc), 'Provisioning profile expired.')
            with tempfile.TemporaryDirectory(dir=self.root, prefix='certificate-') as temporary:
                prefix = str(pathlib.Path(temporary) / 'leaf')
                self.runner.run(['codesign', '-d', '--extract-certificates=' + prefix, str(app)], 'Certificate inspection')
                certificate = pathlib.Path(prefix + '0')
                require(certificate.read_bytes() in profile['DeveloperCertificates'], 'Certificate is not authorized by provisioning.')
                raw, _ = self.runner.run(['openssl', 'x509', '-inform', 'DER', '-in', str(certificate), '-noout', '-startdate', '-enddate'], 'Certificate validity', capture=True)
                dates = re.findall(rb'(?:notBefore|notAfter)=(.+)', raw)
                require(len(dates) == 2, 'Certificate validity unavailable.')
                start, end = [dt.datetime.strptime(x.decode(), '%b %d %H:%M:%S %Y %Z').replace(tzinfo=dt.timezone.utc) for x in dates]
                require(start <= dt.datetime.now(dt.timezone.utc) < end, 'Signing certificate is not currently valid.')
            return expiry
        except (KeyError, ValueError, OSError, plistlib.InvalidFileException):
            raise BuildError('Artifact metadata could not be verified.') from None

    def verify(self, app=None):
        prepared = self.state.get('prepared')
        if app is None:
            require(prepared, 'No prepared artifact is registered.')
            app = pathlib.Path(prepared['app'])
            require(self.current(prepared), 'Prepared artifact belongs to different source or toolchain.')
            require(tree_hash(app) == prepared['app_sha256'], 'Artifact checksum mismatch.')
            require(file_hash(pathlib.Path(prepared['ipa'])) == prepared['ipa_sha256'], 'IPA checksum mismatch.')
        expiry = min(self.verify_bundle(app, BUNDLE), self.verify_bundle(app / 'PlugIns/TopShelf.appex', BUNDLE + '.TopShelf'))
        result = {'signing': 'PASS', 'provisioning_expires_utc': expiry.isoformat(), 'version': '.'.join(version()[:1]), 'build': version()[1]}
        if prepared and str(app) == prepared['app']:
            prepared['expires'] = expiry.isoformat()
            prepared['signing_context'] = self.signing_context()
            self.save()
        return result

    def build_preparation_candidate(self, clean, started):
        built = self.root / 'derived-data/device/Build/Products/Debug-appletvos/NuvioTV.app'
        self.build(clean=clean, device=True)
        try:
            self.verify(built)
        except BuildError as error:
            # Generated incremental output can retain stale resource seals.
            # Retry only that signature failure, once, with a clean build.
            # Never retry away identity, entitlement, expiry or checksum failures.
            if clean or not str(error).startswith('Signature verification: failed (exit '):
                raise
            self.build(clean=True, device=True)
            self.verify(built)
        self.require_fresh_profiles(built, started)
        return built

    def prepare(self, clean=False):
        self.config()
        require(self.source['branch'] == BRANCH, 'Preparation requires the development branch.')
        tests = self.state.get('tests')
        require(self.current(tests, 'tests') and tests.get('passed'),
                'Run relevant simulator tests for current source before preparation.')
        # Preparation always requests fresh profiles; build intermediates remain
        # reusable. Verification alone does not initiate account changes.
        with self.fresh_provisioning() as started:
            built = self.build_preparation_candidate(clean, started)
        candidate = self.root / 'prepared' / ('candidate-' + uuid.uuid4().hex[:12])
        secure_dir(candidate / 'Payload')
        app = candidate / 'Payload/NuvioTV.app'
        ipa = candidate / ('Nuvio-Krystian-' + '-'.join(version()) + '.ipa')
        self.runner.run(['ditto', '--norsrc', '--noextattr', str(built), str(app)], 'Copy signed artifact')
        self.runner.run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', str(candidate / 'Payload'), str(ipa)], 'Package development IPA')
        verification = self.verify(app)
        record = {'source': self.source, 'toolchain': self.toolchain, 'app': str(app), 'ipa': str(ipa),
                  'app_sha256': tree_hash(app), 'ipa_sha256': file_hash(ipa),
                  'expires': verification['provisioning_expires_utc'], 'signing_context': self.signing_context()}
        self.state['prepared'] = record
        write_json(candidate / 'manifest.json', record)
        self.save()
        return dict(verification, artifact='PREPARED', provisioning_refresh='PASS', location='<private-build-home>/prepared', deployment='NOT PERFORMED')


def parser():
    result = PrivateParser(description=__doc__)
    result.add_argument('command', choices=['status', 'doctor', 'generate', 'build', 'test', 'prepare', 'verify', 'report', 'clean'])
    result.add_argument('--json', action='store_true', help='Print only a privacy-safe JSON summary.')
    result.add_argument('--verbose', action='store_true', help='Print phase progress, never raw logs or command arguments.')
    result.add_argument('--suite', action='append', default=[], help='Test selector NuvioTVTests/Class[/method]; repeatable.')
    result.add_argument('--clean-build', action='store_true', help='Explicit clean build before build, test or prepare.')
    result.add_argument('--cache', choices=['simulator', 'device'], help='Cache to remove with clean.')
    result.add_argument('--confirm-clean', action='store_true', help='Explicitly authorize only the selected generated cache removal.')
    return result


def execute(args):
    try:
        require(not args.suite or args.command == 'test', '--suite is only valid with test.')
        require(not args.clean_build or args.command in ('build', 'test', 'prepare'), '--clean-build is not valid for this command.')
        builder = Builder(verbose=args.verbose)
        if args.command in ('status', 'report'):
            output = builder.summary()
        elif args.command == 'doctor':
            output = builder.doctor()
        elif args.command == 'generate':
            output = builder.generate()
        elif args.command == 'build':
            output = builder.build(args.clean_build)
        elif args.command == 'test':
            output = builder.test(args.suite, args.clean_build)
        elif args.command == 'prepare':
            output = builder.prepare(args.clean_build)
        elif args.command == 'verify':
            output = builder.verify()
        else:
            require(args.confirm_clean and args.cache, 'clean requires --cache and --confirm-clean.')
            clean_cache(builder.root, args.cache)
            builder.state.pop('device_build' if args.cache == 'device' else 'build', None)
            builder.save()
            output = {'cache': args.cache, 'removed': True, 'prepared_artifacts': 'RETAINED', 'deployment': 'NOT PERFORMED'}
        print(json.dumps(output, sort_keys=True) if args.json else '\n'.join(f'{key}: {value}' for key, value in output.items()))
        return 0
    except BuildError as error:
        output = {'status': 'FAIL', 'message': str(error), 'deployment': 'NOT PERFORMED'}
    except Exception:
        output = {'status': 'FAIL', 'message': 'Unexpected local failure; inspect private prerequisites and records.', 'deployment': 'NOT PERFORMED'}
    print(json.dumps(output, sort_keys=True) if args.json else output['message'])
    return 1


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        with exclusive_lock(safe_root(private_home())):
            return execute(args)
    except BuildError as error:
        print(json.dumps({'status': 'FAIL', 'message': str(error)}))
        return 1
    except Exception:
        print(json.dumps({'status': 'FAIL', 'message': 'Private storage is unavailable; check local permissions.'}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
