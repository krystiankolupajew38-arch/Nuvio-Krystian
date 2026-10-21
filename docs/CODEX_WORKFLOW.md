# Nuvio-K local build workflow

Current preparation branch: `fix/infuse-progress-ui-stream-picker-performance`.
The helper rejects other branches for preparation; deployment still requires a
separate explicit human GO.

Begin a session with:

```sh
python3 scripts/krystian_build.py status --json
```

The helper uses Python 3's standard library and the existing macOS development
tools. It never installs or launches an application on a physical device.
It reports compact results and keeps full command output in private local logs.
`--verbose` prints phase names, never raw command arguments or diagnostics.

## Commands

| Command | Behavior |
| --- | --- |
| `status`, `report` | Inspect source, cached validation, checksums and signing context; no build |
| `doctor` | Check Xcode, pinned Tuist, a tvOS simulator, signing identities and private configuration |
| `generate` | Regenerate only if manifest, source inventory or dependency inputs changed |
| `build` | Incremental unsigned simulator development build |
| `test` | Run registered unit tests on an available tvOS simulator |
| `prepare` | Incremental signed generic tvOS build, verification and development IPA packaging; reuse only after checks |
| `verify` | Recheck registered artifact hashes, app/extension identities, signing, certificate dates and provisioning |
| `clean --cache simulator --confirm-clean` | Remove only the selected managed DerivedData cache; keep prepared artifacts and evidence |

Examples:

```sh
python3 scripts/krystian_build.py doctor --json
python3 scripts/krystian_build.py test --suite NuvioTVTests/ExternalPlaybackReturnTests
python3 scripts/krystian_build.py test --suite NuvioTVTests/PlayerControlsSettingsTests/testPercentageResumeWithZeroSeedSeeksAfterActualDurationLoads
python3 scripts/krystian_build.py prepare --clean-build
python3 scripts/krystian_build.py verify --json
python3 -B -m unittest discover -s scripts/tests -p 'test_krystian_build.py' -q
```

`--suite` is repeatable. Omit it for all registered unit tests. `--clean-build`
is available for build, test and prepare; normal development uses incremental
DerivedData. There is no general shell-command option, export-log option, output
path option, scheduler, watcher or deployment option in the build helper.

## Private storage

The default private root is `~/Library/Application Support/NuvioKrystianBuild`.
An optional `NUVIO_K_BUILD_HOME` may select another directory outside the repo.
Root, logs and record directories use mode 0700; config, state, manifests and raw
logs use 0600. Do not paste those files into Codex or upload them. Public output
uses `<private-build-home>` and `Apple TV target` aliases. Exact artifact paths
are in the private manifest and may be shared privately only when requested.

`config.json` contains `team_id`, `device_id`, `installed_version` and
`installed_build`. Populate it locally from the existing signing configuration
and approved read-only target inventory; do not put real values in scripts or
repository documentation. Use mode 0600. Signing remains in the ignored
`tvosApp/Configurations/Signing.local.xcconfig`. No credentials are passed on the
Xcode command line. Local device tools require a target identifier as a process
argument during a later explicitly authorized deployment; these arguments are
never printed by this workflow.

Raw logs can contain private paths, account identifiers or signed URLs. They stay
in restricted local storage. Reports are built from a small fixed schema, not by
exporting/redacting arbitrary logs. There is intentionally no raw-report export.
The secondary `redact` function is not a guarantee that arbitrary text is safe
for publication. Never commit logs, provisioning profiles, certificates, private
keys, app bundles, IPAs, xcresults, private config or device discovery JSON.

## Cache and evidence rules

Application and test fingerprints cover source, resource and dependency contents,
submodule contents, local signing configuration, generated project/schemes and
package resolution. The source inventory includes ignored Swift sources that
Tuist could compile. A generation fingerprint tracks manifest/dependency inputs
and the source-file inventory; normal Swift edits do not regenerate the project.
Toolchain identity includes the selected Xcode version and developer directory.

Records retain the commit and dirty state at validation time. Documentation or
helper-only commits may reuse the same application fingerprint. `prepare` requires passing current simulator test evidence (with its scope retained),
re-verifies that mapping and updates the private manifest to the current commit.
This is source equivalence, not a claim that an older binary embeds the new Git
SHA. Changing application inputs invalidates build/artifact results; changing
tests invalidates test results. A source edit during a command rejects its result.
A failed build/test clears prior success. Only an executed, nonempty test run is
reported as passing, and its selected scope is retained.

Prepared apps have a recursive SHA-256 covering relative paths, modes and file
contents; IPAs have a file SHA-256. Reuse checks both. Signing verification checks
both app and Top Shelf, expected version/build, bundle identity, callback scheme,
App Group, team identity from private config, device authorization, profile expiry,
and whether the signing certificate is authorized by the embedded profile and
currently valid. Changed local profiles, identities or private configuration mark
signing stale. `verify` rechecks the actual embedded material. Profile renewal is
not inferred from a successful build; report the actual embedded expiry.

The initial local evidence was adopted from this preparation session: 1,275 tests
passed in the full clean simulator run, then 95 affected tests passed after the
last checkpoint-pruning optimization. Full-suite evidence is historical; the
95-test result is tied to the final application/test fingerprint. Both result
bundles and the final clean device-build log are retained privately. Do not rerun
the app suite merely because build-helper documentation changed.

## Deployment boundary

`scripts/krystian_install_prepared.py` is separate and must not be invoked during
preparation, except through mocked unit tests. Even read-only target discovery
requires its explicit authorization flags. After the human says GO, use:

```sh
python3 scripts/krystian_install_prepared.py --go --confirm UPDATE-NUVIO-K
```

That future operation locks the private state, verifies a clean reviewed source
state, source/artifact checksums, manifest, signing and provisioning, then reads
the target inventory. It requires the expected existing version from private
config and the separate original app to be present. A known signing-team mismatch
stops. The current device query does not expose the installed signer, so signing
continuity and data retention cannot be guaranteed from that inventory alone.

Only after these checks does the separate installer update the existing bundle,
without an uninstall. It checks the replacement version and unchanged original
app inventory, then requests launch of the replacement bundle. Any failure stops;
there is no uninstall, deletion, profile-installation or reinstall fallback.
An installation failure may leave the prior app or an updated app; inspect the
private audit record before retrying. A successful launch request is not proof
of functional playback or retained settings. Verify profiles, sources, accounts,
Continue Watching and a known Infuse resume point in the app after authorized
installation. No physical operation has been executed during preparation.

## Quick handover

Use `status --json`, `report --json` and `verify --json`. The private state and
prepared manifest contain source commits, fingerprints, checksums and evidence
references. The privacy-safe release review is in
`docs/krystian-validation-2026-10-20.md`. Push only reviewed source, tests and
workflow files to the development branch. Main and the original app remain
outside this workflow.
