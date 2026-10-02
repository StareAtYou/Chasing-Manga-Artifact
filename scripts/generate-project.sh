#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
generator=${XCODEGEN_BIN:-xcodegen}
if ! command -v "$generator" >/dev/null; then echo '请安装 XcodeGen 2.46.0 或设置 XCODEGEN_BIN；不会自动安装。' >&2; exit 1; fi
version=$("$generator" --version)
if [[ "$version" != 'Version: 2.46.0' ]]; then echo "需要 XcodeGen 2.46.0，当前：$version" >&2; exit 1; fi
"$generator" generate --spec project.yml
