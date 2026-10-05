#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
compiler=/Library/Developer/CommandLineTools/usr/bin/swiftc
sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
if [ ! -x "$compiler" ]; then
    compiler="$(xcrun --find swiftc)"
    sdk="$(xcrun --show-sdk-path)"
fi
mkdir -p "$project_dir/build"
"$compiler" -swift-version 5 -parse-as-library -sdk "$sdk" \
    "$project_dir/macos/Models.swift" "$project_dir/macos/NetworkBackend.swift" \
    "$project_dir/tests/native/TestRunner.swift" -o "$project_dir/build/native-tests"
python3 "$project_dir/tests/native/run.py"
"$compiler" -swift-version 5 -parse-as-library -sdk "$sdk" \
    "$project_dir/macos/AppCleanup.swift" "$project_dir/tests/native/CleanupTests.swift" -o "$project_dir/build/cleanup-tests"
"$project_dir/build/cleanup-tests"
