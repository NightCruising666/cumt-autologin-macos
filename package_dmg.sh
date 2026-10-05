#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$project_dir/build/CUMT Auto Login.app"
tool="${DMGBUILD_BIN:-dmgbuild}"
if ! command -v "$tool" >/dev/null; then
    printf '需要构建工具 dmgbuild 1.6.7。请在虚拟环境安装，并设置 DMGBUILD_BIN。\n' >&2
    exit 1
fi
if [ ! -d "$app_dir" ]; then
    printf '请先运行 ./build_macos.sh 构建应用。\n' >&2
    exit 1
fi
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_dir/Contents/Info.plist")"
output_path="${1:-$project_dir/build/校园网助手-$version-AppleSilicon.dmg}"
compiler=/Library/Developer/CommandLineTools/usr/bin/swiftc
sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
if [ ! -x "$compiler" ]; then
    compiler="$(xcrun --find swiftc)"
    sdk="$(xcrun --show-sdk-path)"
fi
mkdir -p "$project_dir/build/dmg-artwork" "$(dirname "$output_path")"
"$compiler" -swift-version 5 -parse-as-library -sdk "$sdk" \
    "$project_dir/packaging/MakeDMGBackground.swift" -o "$project_dir/build/make-dmg-background" -framework AppKit
"$project_dir/build/make-dmg-background" "$project_dir/build/dmg-artwork"
"$tool" -s "$project_dir/packaging/dmg-settings.py" \
    -D "app=$app_dir" -D "background=$project_dir/build/dmg-artwork/background.png" \
    '校园网助手' "$output_path"
/usr/bin/hdiutil verify "$output_path"
printf '已生成拖拽安装包：%s\n' "$output_path"
