#!/bin/bash
set -e
project_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$project_dir/build/CUMT Auto Login.app"
if [ ! -x "$app_dir/Contents/MacOS/CUMTMenu" ]; then
    /bin/bash "$project_dir/build_macos.sh"
fi
exec /usr/bin/open "$app_dir"
