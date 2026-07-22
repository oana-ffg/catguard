#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
xcodebuild_path="$(xcrun --find xcodebuild)"
derived_data_path="${repository_root}/.build/xcode-team"

"${xcodebuild_path}" \
    -project "${repository_root}/CatGuard.xcodeproj" \
    -scheme CatGuard \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "${derived_data_path}" \
    -allowProvisioningUpdates \
    build

echo "Built ${derived_data_path}/Build/Products/Release/CatGuard.app"
