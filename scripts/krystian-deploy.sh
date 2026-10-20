#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <Apple-TV-device-ID>" >&2
  echo 'Find the ID with: xcrun devicectl list devices' >&2
  exit 1
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
device_id="$1"
# Keep signed products outside synced Documents folders. File-provider metadata
# on an .app/.appex can cause codesign to reject it.
derived_data="$HOME/Library/Developer/Xcode/DerivedData/Nuvio-Krystian"
cd "$repo_root"
./scripts/krystian-generate.sh
xcodebuild -workspace tvosApp/NuvioTV.xcworkspace -scheme NuvioTV \
  -configuration Debug -destination "id=$device_id" \
  -derivedDataPath "$derived_data" -allowProvisioningUpdates build
app_path="$derived_data/Build/Products/Debug-appletvos/NuvioTV.app"
app_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Info.plist")"
if [[ "$app_id" != 'com.krystian.nuvio' ]]; then
  echo "Refusing to install unexpected bundle ID: $app_id" >&2
  exit 1
fi
xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch --device "$device_id" "$app_id"
