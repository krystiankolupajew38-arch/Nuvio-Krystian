# Nuvio - Krystian

Personal Apple TV development fork of [bobsupra/NuvioTVOS](https://github.com/bobsupra/NuvioTVOS). The upstream license and attribution are retained. Your repository is [krystiankolupajew38-arch/Nuvio-Krystian](https://github.com/krystiankolupajew38-arch/Nuvio-Krystian).

## App identity

- Home-screen name: **Nuvio - Krystian**
- App bundle ID: `com.krystian.nuvio`
- Top Shelf extension: `com.krystian.nuvio.TopShelf`
- App Group: `group.com.krystian.nuvio`
- Deep links and external-player callbacks: `nuvio-krystian://`

This installs separately from the existing `Nuvio.Sideload` app. The existing refresh script manages that original app only; it does not refresh this development build.

The fork registers only its own URL scheme to avoid competing with your original app for Nuvio and Stremio links. Configure add-ons inside Settings rather than opening generic Stremio installation links. Infuse remains an external-player option.

Local app data is separate. Signing in to the same Nuvio account can still sync account data between installations; use a separate account for experiments that should not change your everyday library/settings.

## Open and build

The generated workspace is `tvosApp/NuvioTV.xcworkspace`. Open it in Xcode, select the **NuvioTV** scheme, choose your Apple TV, then Run.

To build, install, and launch from Terminal:

```sh
xcrun devicectl list devices
./scripts/krystian-deploy.sh <Apple-TV-device-ID>
```

The deploy script puts build output in `~/Library/Developer/Xcode/DerivedData/Nuvio-Krystian`. Keep signed build output outside synced Documents folders: file-provider metadata can cause code-signing failures. Xcode's default Derived Data location is suitable too.

The initial Personal Team provisioning expires on 26 October 2026 at 23:57 UK time, as recorded in the embedded profile. Rebuild and deploy to renew it; there is no automatic refresh configured for this fork.

To regenerate after project changes:

```sh
./scripts/krystian-generate.sh
```

Tuist 4.207.0 is pinned in `mise.toml`. This checkout also has a verified official copy under ignored `.tools/tuist/`. For a fresh clone, install the pinned tool using mise and initialize the submodule:

```sh
git submodule update --init --recursive
mise install
./scripts/krystian-generate.sh
```

Edit `tvosApp/Project.swift` for project settings; Xcode project files are generated and ignored. Swift source files are discovered automatically when regenerating.

Signing uses the ignored `tvosApp/Configurations/Signing.local.xcconfig`. Set `DEVELOPMENT_TEAM` there. Never commit certificates, profiles, tokens, or add-on URLs containing credentials.

This fork omits upstream's push-notification, associated-domain, and iCloud key-value entitlements because this Mac's Personal Team cannot provision them. Those Apple services are unavailable in this build. App Groups are retained for Top Shelf. Nuvio account sync is a separate service from iCloud.

## Development workflow

`upstream` points to bobsupra/NuvioTVOS; its push URL is disabled in this checkout to prevent accidental upstream pushes. `origin` points to your own repository. Keep personal changes on `main`, and create a branch per feature:

```sh
git switch -c feature/short-description
# Make changes, build, and test on Apple TV.
git add <specific-files>
git commit -m "Describe the change"
git push -u origin HEAD
```

To bring in upstream changes, start with a clean working tree:

```sh
git fetch upstream
git switch main
git merge upstream/main
git submodule update --init --recursive
./scripts/krystian-generate.sh
```

This initial download contains only the latest upstream revision. Fetch older history if needed with `git fetch --unshallow upstream`.

## Where to make changes

- `tvosApp/NuvioTV/Sources/UI/`: screens and reusable UI
- `tvosApp/NuvioTV/Sources/ViewModels/`: screen behaviour
- `tvosApp/NuvioTV/Sources/Data/Repository/`: catalogs and source fetching
- `tvosApp/NuvioTV/Sources/Models/PlayerModels.swift`: external-player URLs and callbacks
- `tvosApp/NuvioTV/Sources/NuvioTVApp.swift`: app navigation and playback handoff
- `tvosApp/NuvioTVTests/`: unit tests

The inherited CI configuration uses a custom `xcode-27` runner; it is not ready to run on an ordinary personal fork without runner configuration. Start with local Xcode builds and tests.

## First-device checks

- Both the original app and Nuvio - Krystian appear on Apple TV.
- Configure sources in the new app and select Infuse in playback settings.
- Open a title in Infuse and verify returning reaches the new app.
- If App Groups are available, verify a Top Shelf item opens the new app.
- Confirm the original app still opens and its refresh process remains unchanged.

## Verified setup — 20 October 2026

- Tuist 4.207.0 generated the workspace successfully.
- Xcode 27.1 built the tvOS app successfully, unsigned and then signed.
- The signed `com.krystian.nuvio` app installed successfully on the paired Apple TV.
- Property lists and shell-script syntax passed validation.
- Launch was attempted, but Apple TV refused because it was asleep; launch and playback remain unverified.
- Automated unit tests and account-dependent playback checks have not yet been run.
