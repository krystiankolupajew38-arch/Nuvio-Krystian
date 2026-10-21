# Nuvio-K development workflow

Start with `python3 scripts/krystian_build.py status --json`. Read
`docs/CODEX_WORKFLOW.md` for details. Inspect current artifacts with verify/report; prepare requests fresh provisioning.
Reuse scoped test evidence; never present stale results as validating changed source.

- Work on `fix/infuse-progress-ui-stream-picker-performance` for this preparation. Do not
  merge into main, force-push, or integrate experimental upstream PR #308.
- Treat physical Apple TV work as preparation-only unless the human explicitly
  authorizes deployment. Building or passing tests is not authorization.
- Never run `scripts/krystian-deploy.sh`; it combines building, installing and
  launching. The build helper has no physical-device command. The separate
  installer requires a later human GO and explicit execution flags.
- Preserve `com.krystian.nuvio`, its Top Shelf extension, App Group, callback
  scheme and branding. Never modify `Nuvio.Sideload` or its refresh automation.
- Keep private configuration, raw logs, signed artifacts, device identifiers,
  team/account identifiers, profiles and certificates outside Git. Print only
  compact redacted summaries. Do not paste raw Xcode or discovery output.
- Use `test --suite NuvioTVTests/ClassName` for affected regressions and
  `prepare --clean-build` when a new final clean build is justified.
- Source, test, generated-project and dependency fingerprints determine cache
  validity. Documentation/helper-only commits do not require an app rebuild.
- Run `python3 -B -m unittest discover -s scripts/tests -p 'test_krystian_build.py' -q`
  after changing the helper. Installer tests must mock every device operation.
- Keep callback seconds exact; unknown duration never proves completion.
  Preserve profile/episode/source identity and avoid duplicate Infuse/Trakt reports.
