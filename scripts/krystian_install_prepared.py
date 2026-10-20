#!/usr/bin/env python3
"""Separate physical-device update procedure. Requires a later, explicit user GO."""
import json
import pathlib
import sys

from krystian_build import (BUNDLE, BuildError, Builder, Runner, PrivateParser,
                            file_hash, require, version, write_json)


def apps(runner, config):
    raw, _ = runner.run(['xcrun', 'devicectl', 'device', 'info', 'apps', '--device',
                         config['device_id'], '--json-output', '-'], 'Read installed apps', capture=True)
    try:
        return json.loads(raw)['result']['apps']
    except (ValueError, KeyError):
        raise BuildError('Installed app inventory could not be verified.') from None


def find_app(items, identifier):
    matches = [item for item in items if item.get('bundleIdentifier') == identifier]
    require(len(matches) == 1, 'Expected installed app was not uniquely identified; refusing installation.')
    return matches[0]


def deploy(builder, go, confirmation):
    require(go and confirmation == 'UPDATE-NUVIO-K', 'Deployment requires explicit --go --confirm UPDATE-NUVIO-K after user authorization.')
    config = builder.config()
    prepared = builder.state.get('prepared')
    require(prepared, 'No prepared artifact is registered.')
    require(not builder.source['dirty'], 'Commit reviewed work before deployment.')
    builder.verify()  # Checks source, app/IPA hashes, identity, certificates and device provisioning.
    manifest_path = pathlib.Path(prepared['app']).parents[1] / 'manifest.json'
    from krystian_build import read_json
    manifest = read_json(manifest_path)
    require(manifest == prepared, 'Prepared manifest does not match the verified record.')
    runner = Runner(builder.root, device_authorized=True)
    before = apps(runner, config)
    existing = find_app(before, BUNDLE)
    original = find_app(before, 'Nuvio.Sideload')
    require(existing.get('version') == config.get('installed_version') and
            existing.get('bundleVersion') == config.get('installed_build'),
            'Installed version changed; review it before authorizing an update.')
    # Some CoreDevice versions expose signing continuity; this host currently does
    # not. A known mismatch always stops. Missing data is explicitly recorded.
    installed_team = existing.get('teamIdentifier')
    require(not installed_team or installed_team == config['team_id'], 'Installed signing team differs; refusing update.')
    audit = {'status': 'PREFLIGHT_PASSED', 'installed_signer_verified': bool(installed_team), 'uninstall_performed': False}
    write_json(builder.root / 'deployment.json', audit)
    try:
        runner.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', config['device_id'], prepared['app']], 'Update existing app')
        after = apps(runner, config)
        updated = find_app(after, BUNDLE)
        require((updated.get('version'), updated.get('bundleVersion')) == version(), 'Installed replacement version did not verify; stop for investigation.')
        unchanged = find_app(after, 'Nuvio.Sideload')
        require(all(original.get(key) == unchanged.get(key) for key in ('bundleIdentifier', 'version', 'bundleVersion', 'url')),
                'Original app inventory changed; stop for investigation.')
        runner.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', config['device_id'], BUNDLE], 'Launch updated app')
    except Exception:
        audit['status'] = 'STOPPED_REQUIRES_REVIEW'
        write_json(builder.root / 'deployment.json', audit)
        raise
    audit['status'] = 'UPDATED_VERSION_AND_LAUNCH_VERIFIED'
    write_json(builder.root / 'deployment.json', audit)
    return {'update': 'PASS', 'launch_request': 'PASS', 'original_app': 'UNCHANGED_IN_INVENTORY',
            'data_retention': 'VERIFY_SETTINGS_AND_ACCOUNTS_IN_APP',
            'installed_signer_verified_before_update': bool(installed_team)}


def main(argv=None):
    parser = PrivateParser(description=__doc__)
    parser.add_argument('--go', action='store_true')
    parser.add_argument('--confirm', default='')
    args = parser.parse_args(argv)
    try:
        # Do not even discover the target unless explicitly authorized.
        require(args.go and args.confirm == 'UPDATE-NUVIO-K', 'No deployment performed. A later explicit GO is required.')
        from krystian_build import exclusive_lock, private_home, safe_root
        with exclusive_lock(safe_root(private_home())):
            result = deploy(Builder(), args.go, args.confirm)
        print(json.dumps(result, sort_keys=True))
        return 0
    except BuildError as error:
        print(json.dumps({'status': 'STOPPED', 'message': str(error), 'uninstall_performed': False}))
    except Exception:
        print(json.dumps({'status': 'STOPPED', 'message': 'Inspect the private deployment record; no uninstall fallback is permitted.'}))
    return 1


if __name__ == '__main__':
    sys.exit(main())
