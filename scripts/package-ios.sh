#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPMENT_TEAM:?请设置自己的 Apple 开发 Team ID}"
: "${MANGA_DEVICE_UDID:?请设置目标 iPhone/iPad 的 UDID}"
root=$(pwd)
output="$root/release/ios"
products="$root/.build/ios-package"
swift scripts/check-ios-icons.swift Apps/iOS/Icons
mkdir -p "$output"
# Target builds also work when the device SDK is installed but a simulator runtime is unavailable.
xcodebuild -project ChasingManga.xcodeproj -target MangaIOS -configuration Release \
  -sdk iphoneos -destination "id=$MANGA_DEVICE_UDID" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" "SYMROOT=$products" build > "$output/build.log" 2>&1 || {
    tail -40 "$output/build.log" >&2
    echo '请在 Xcode 的 MangaIOS → Signing & Capabilities 中选择自己的 Team，并为连接的设备建立开发配置。' >&2
    exit 1
  }
app="$products/Release-iphoneos/MangaIOS.app"
codesign --verify --deep --strict "$app"
[[ -f "$app/embedded.mobileprovision" ]] || { echo '缺少设备授权描述文件，停止打包。' >&2; exit 1; }
staging=$(mktemp -d "$root/.build/ios-payload.XXXXXX")
trap 'rm -rf "$staging"' EXIT
security cms -D -i "$app/embedded.mobileprovision" > "$staging/profile.plist"
python3 - "$staging/profile.plist" "$app/Info.plist" "$MANGA_DEVICE_UDID" "$output/package-info.json" <<'PY'
import datetime,json,plistlib,sys
profile=plistlib.load(open(sys.argv[1],'rb')); app=plistlib.load(open(sys.argv[2],'rb'))
now=datetime.datetime.now(datetime.timezone.utc)
expiry=profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc)
if sys.argv[3] not in profile.get('ProvisionedDevices',[]): sys.exit('描述文件不包含目标设备，停止打包。')
if expiry <= now: sys.exit('描述文件已过期，停止打包。')
identifier=app['CFBundleIdentifier']; authorized=profile['Entitlements']['application-identifier']
if not (authorized.endswith('.'+identifier) or authorized.endswith('.*')): sys.exit('签名应用标识不匹配。')
info={'bundleIdentifier':identifier,'version':app['CFBundleShortVersionString'],'build':app['CFBundleVersion'],'minimumOSVersion':app['MinimumOSVersion'],'sdk':app['DTSDKName'],'profileExpiresUTC':expiry.isoformat(),'targetDeviceIncluded':True,'profileDeviceCount':len(profile['ProvisionedDevices']),'signing':'Apple Development'}
open(sys.argv[4],'w').write(json.dumps(info,ensure_ascii=False,indent=2)+'\n')
print('设备授权有效，签名到期时间：'+expiry.isoformat())
PY
mkdir -p "$staging/Payload"
ditto "$app" "$staging/Payload/MangaIOS.app"
ipa="$output/ChasingManga-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Info.plist")-iOS.ipa"
(cd "$staging" && /usr/bin/zip -qry package.ipa Payload)
mv "$staging/package.ipa" "$ipa"
shasum -a 256 "$ipa" > "$ipa.sha256"
printf '已生成：%s\n' "$ipa"
if [[ "${MANGA_INSTALL:-0}" == 1 ]]; then
  xcrun devicectl device install app --device "$MANGA_DEVICE_UDID" "$app"
  xcrun devicectl device process launch --device "$MANGA_DEVICE_UDID" com.chasingmanga.local.ios || {
    echo '已安装但启动失败。若为首次安装，请在手机“设置 → 通用 → VPN 与设备管理”信任自己的开发者账户，再启动。' >&2
    exit 1
  }
fi
