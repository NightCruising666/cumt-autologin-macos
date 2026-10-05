#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -u
project_dir="$(cd "$(dirname "$0")" && pwd)"
python_bin=""
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$candidate" ] && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
        python_bin="$candidate"
        break
    fi
done
if [ -z "$python_bin" ]; then
    printf '需要 Python 3.10 或更新版本。若已安装 Homebrew，可运行 brew install python。\n'
    printf '安装 Python 后，重新双击此入口即可；本项目没有第三方 Python 依赖。\n'
    read -r -p '按回车关闭…' reply
    exit 1
fi
"$python_bin" "$project_dir/cumt_login.py" "$@"
result=$?
if [ "$result" -eq 2 ]; then
    printf '\n本次跳过：请连接 CUMT_Stu；代理的 TUN 模式也可能拦截校园网路由。\n'
fi
printf '\n'
read -r -p '按回车关闭…' reply
exit "$result"
