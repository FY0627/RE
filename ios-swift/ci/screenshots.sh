#!/usr/bin/env bash
# 在 iOS 模拟器上运行 Debug 版 App，浅色 / 深色各截一组主要页面，和 IPA 放进同一个产物。
# App 以截图模式启动（见 Bookkeeping/Diagnostics/ScreenshotMode.swift）：独立的临时账本 + 虚构演示数据。
# 用法：bash ios-swift/ci/screenshots.sh <输出目录>
set -Eeuo pipefail
# -E：shoot() 等函数里的失败也触发 ERR，并报出行号
trap 'echo "::error title=screenshots.sh::screenshots.sh line $LINENO failed: $BASH_COMMAND"' ERR

OUT="${1:?output dir}"
BUNDLE_ID="com.example.bookkeepingApp.swift"
SHOTS="$OUT/ipa/screenshots"
mkdir -p "$OUT/logs" "$SHOTS"
rm -f "$SHOTS"/*.png

DEVICE_ID=$(bash ios-swift/ci/pick-simulator.sh)
echo "simulator: $DEVICE_ID"
# 前面的模拟器测试可能已经启动了它
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b

echo "== build Debug iphonesimulator"
set +e
xcodebuild \
  -project ios-swift/Bookkeeping.xcodeproj \
  -scheme Bookkeeping \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath "$OUT/derived-sim" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$OUT/logs/screenshots-build.log"
STATUS=${PIPESTATUS[0]}
set -e
if [[ $STATUS -ne 0 ]]; then
  echo "::warning title=Screenshots::模拟器构建失败（退出码 ${STATUS}），本次没有截图；IPA 不受影响"
  exit $STATUS
fi

APP="$OUT/derived-sim/Build/Products/Debug-iphonesimulator/Bookkeeping.app"
xcrun simctl install "$DEVICE_ID" "$APP"
MARKER="$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)/tmp/bk-screenshot-ready"

# 固定状态栏，截图之间只有界面本身的差别
xcrun simctl status_bar "$DEVICE_ID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

MISSED=0
shoot() {
  local name="$1"; shift
  local token="$name-$RANDOM"
  xcrun simctl launch --terminate-running-process "$DEVICE_ID" "$BUNDLE_ID" \
    -BKScreenshot YES -BKScreenshotToken "$token" "$@" > /dev/null
  # App 写入标记表示数据已加载、页面已到位；首次启动较慢，最多等 60 秒
  local ready=0
  for _ in $(seq 1 120); do
    if [[ "$(cat "$MARKER" 2>/dev/null || true)" == "$token" ]]; then ready=1; break; fi
    sleep 0.5
  done
  if [[ $ready -eq 0 ]]; then
    echo "::warning title=Screenshots::$name 等待界面就绪超时，截图可能不完整"
    MISSED=$((MISSED + 1))
  fi
  sleep 0.5
  xcrun simctl io "$DEVICE_ID" screenshot --type=png "$SHOTS/$name.png" > /dev/null
  echo "shot: $name.png"
}

for appearance in light dark; do
  xcrun simctl ui "$DEVICE_ID" appearance "$appearance"
  shoot "1-home-$appearance" -BKScreenshotTab home
  shoot "2-assets-$appearance" -BKScreenshotTab assets
  shoot "3-stats-$appearance" -BKScreenshotTab stats
  shoot "4-profile-$appearance" -BKScreenshotTab profile
  shoot "5-pending-$appearance" -BKScreenshotTab home -BKScreenshotSheet pending
done

xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl status_bar "$DEVICE_ID" clear || true

COUNT=$(ls "$SHOTS"/*.png | wc -l | tr -d ' ')
DEVICE_NAME=$(xcrun simctl list devices | grep "$DEVICE_ID" | sed -E 's/^[[:space:]]*//; s/ \(.*//')
echo "count=$COUNT" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "device=$DEVICE_NAME" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "::notice title=Screenshots::${COUNT} 张截图（${DEVICE_NAME}，超时 ${MISSED} 张），在 IPA 产物的 screenshots/ 目录"
