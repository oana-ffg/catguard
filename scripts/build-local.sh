#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
identity_name="CatGuard Local Development"

"${script_directory}/create-local-signing-identity.sh"

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
    build

echo "Built ${derived_data_path}/Build/Products/Release/CatGuard.app"
echo "Note: self-signed builds support manual arm, but macOS Focus Filters require an Apple Development Team ID."
echo "Use scripts/build-development.sh after selecting your Personal Team in Xcode for Focus integration."
