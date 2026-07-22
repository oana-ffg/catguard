#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
identity_name="CatGuard Local Development"

"${script_directory}/create-local-signing-identity.sh"

certificate_hash="$({
    security find-certificate -c "${identity_name}" -Z
} | awk '/SHA-1 hash:/ { print $3; exit }')"

if [[ ! "${certificate_hash}" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "Could not read the SHA-1 fingerprint for '${identity_name}'." >&2
    exit 1
fi

app_requirement="identifier \"com.oanaffg.CatGuard\" and certificate leaf = H\"${certificate_hash}\""
helper_requirement="identifier \"com.oanaffg.CatGuard.Helper\" and certificate leaf = H\"${certificate_hash}\""
xcodebuild_path="$(xcrun --find xcodebuild)"
derived_data_path="${repository_root}/.build/xcode-local"

"${xcodebuild_path}" \
    -project "${repository_root}/CatGuard.xcodeproj" \
    -scheme CatGuard \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "${derived_data_path}" \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=${identity_name}" \
    DEVELOPMENT_TEAM= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "CATGUARD_APP_SIGNING_REQUIREMENT=${app_requirement}" \
    "CATGUARD_HELPER_SIGNING_REQUIREMENT=${helper_requirement}" \
    build

echo "Built ${derived_data_path}/Build/Products/Release/CatGuard.app"
