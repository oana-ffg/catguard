#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
xcodebuild_path="$(xcrun --find xcodebuild)"
derived_data_path="${repository_root}/.build/xcode-team"
app_path="${derived_data_path}/Build/Products/Release/CatGuard.app"

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "Set DEVELOPMENT_TEAM to your Personal Team ID for this build." >&2
    exit 1
fi

"${xcodebuild_path}" \
    -project "${repository_root}/CatGuard.xcodeproj" \
    -scheme CatGuard \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "${derived_data_path}" \
    -allowProvisioningUpdates \
    "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}" \
    build

signature_details="$(/usr/bin/codesign -dv --verbose=2 "${app_path}" 2>&1)"
team_identifier="$(printf '%s\n' "${signature_details}" | sed -n 's/^TeamIdentifier=//p')"
if [[ "${team_identifier}" != "${DEVELOPMENT_TEAM}" ]]; then
    echo "Build completed without the requested Apple Development Team signature; the Focus Filter will not work." >&2
    exit 1
fi

/usr/bin/codesign --verify --strict "${app_path}"
echo "Built ${app_path} with Team ID ${team_identifier}"
