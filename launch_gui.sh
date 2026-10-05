#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$project_dir/build/CUMT Auto Login.app"
if [ ! -x "$app_dir/Contents/MacOS/CUMTMenu" ]; then
    /bin/bash "$project_dir/build_macos.sh"
fi
# A second short-lived process forwards the action to the existing instance.
exec /usr/bin/open -n "$app_dir" --args "$@"
