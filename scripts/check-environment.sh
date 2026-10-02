#!/bin/bash
set -eu
failed=0
selected=$(xcode-select -p 2>/dev/null || true)
if [[ "$selected" != */Xcode*.app/Contents/Developer || ! -d "$selected/Platforms/iPhoneOS.platform" ]]; then
  echo "缺少完整 Xcode；当前 Developer 路径：${selected:-未配置}。安装 Xcode 并在 Xcode Settings > Locations 选择 Command Line Tools。" >&2
  failed=1
else
  xcodebuild -version
fi
if command -v swift >/dev/null; then swift --version; else echo '缺少 Swift' >&2; failed=1; fi
if command -v "${XCODEGEN_BIN:-xcodegen}" >/dev/null; then "${XCODEGEN_BIN:-xcodegen}" --version; else echo '未安装 XcodeGen 2.46.0（打开已提交工程不需要；重新生成才需要）' >&2; failed=1; fi
exit "$failed"
