#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$project_dir/build/CUMT Auto Login.app"
version="$(/usr/bin/plutil -extract version raw "$project_dir/app-metadata.json")"
repository_url="$(/usr/bin/plutil -extract repository_url raw "$project_dir/app-metadata.json")"
# A release built after setting origin points to the user's repository.
# An explicit metadata URL takes precedence; never link to the upstream repo.
if [ -z "$repository_url" ]; then
    origin="$(git -C "$project_dir" remote get-url origin 2>/dev/null || true)"
    case "$origin" in
        git@github.com:*) repository_url="https://github.com/${origin#git@github.com:}" ;;
        ssh://git@github.com/*) repository_url="https://github.com/${origin#ssh://git@github.com/}" ;;
        https://github.com/*) repository_url="$origin" ;;
    esac
    repository_url="${repository_url%/}"
    repository_url="${repository_url%.git}"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
compiler=/Library/Developer/CommandLineTools/usr/bin/swiftc
sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
if [ ! -x "$compiler" ]; then
    compiler="$(xcrun --find swiftc)"
    sdk="$(xcrun --show-sdk-path)"
fi
"$compiler" -swift-version 5 -sdk "$sdk" -target "$(uname -m)-apple-macosx13.0" -O \
    "$project_dir/macos/Models.swift" "$project_dir/macos/NetworkBackend.swift" "$project_dir/macos/AppCleanup.swift" "$project_dir/macos/main.swift" -o "$app_dir/Contents/MacOS/CUMTMenu" -framework AppKit -framework Security -framework LocalAuthentication
rm -f "$app_dir/Contents/Resources/cumt_login.py" "$app_dir/Contents/Resources/gui_backend.py"
rm -rf "$app_dir/Contents/Resources/__pycache__"
cp "$project_dir/LICENSE" "$project_dir/NOTICE.md" "$app_dir/Contents/Resources/"
"$compiler" -swift-version 5 -parse-as-library -sdk "$sdk" "$project_dir/macos/MakeIcon.swift" -o "$project_dir/build/make-icon" -framework AppKit
"$project_dir/build/make-icon" "$project_dir/build/AppIcon.iconset"
/usr/bin/iconutil -c icns "$project_dir/build/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
rm -f "$app_dir/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string local.cumt.autologin.menu "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleName -string 'CUMT Auto Login' "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string '校园网助手' "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string CUMTMenu "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$version" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$version" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CUMTProjectURL -string "$repository_url" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 13.0 "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert LSUIElement -bool true "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$app_dir/Contents/Info.plist"
# The school exposes an HTTP portal. Restrict the exception to its IP address;
# unrelated HTTPS traffic keeps normal TLS validation.
/usr/bin/plutil -insert NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true,"NSExceptionDomains":{"10.2.5.251":{"NSExceptionAllowsInsecureHTTPLoads":true,"NSIncludesSubdomains":false},"connect.rom.miui.com":{"NSExceptionAllowsInsecureHTTPLoads":true},"204.ustclug.org":{"NSExceptionAllowsInsecureHTTPLoads":true}}}' "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir"
printf '已生成：%s\n' "$app_dir"
