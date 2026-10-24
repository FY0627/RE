#!/usr/bin/env bash
# 核心业务测试：
#   1. macOS 主机上 `swift test`（BKCore 包，纯 Swift，含 SQLite）
#   2. iOS 模拟器上同一套测试（iOS 的 Foundation / SQLite 行为）
# 用法：bash ios-swift/ci/test.sh <输出目录>
set -euo pipefail

OUT="${1:?output dir}"
PACKAGE_DIR="ios-swift/Packages/BKCore"
mkdir -p "$OUT/logs" "$OUT/results"

# 分层约束：App 不能直接 import 数据库层
if grep -rn --include='*.swift' -E '^\s*(@testable\s+)?import\s+BKDatabase' ios-swift/Bookkeeping; then
  echo "::error::ios-swift/Bookkeeping 直接 import 了 BKDatabase，违反 App → BKBackend → BKDatabase 的依赖方向"
  exit 1
fi

echo "== swift test (macOS host)"
set +e
(cd "$PACKAGE_DIR" && swift test --parallel --xunit-output "$OUT/results/swift-test.xml") 2>&1 | tee "$OUT/logs/swift-test.log"
STATUS=${PIPESTATUS[0]}
set -e
if [[ $STATUS -ne 0 ]]; then
  echo "::error title=swift test::macOS 主机上的核心业务测试失败（退出码 $STATUS）"
  exit $STATUS
fi

echo "== choose an iOS simulator"
DEVICE_ID=$(xcrun simctl list devices available --json | python3 -c '
import json, sys, re
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            key = (version, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"], runtime)
if best is None:
    sys.exit("no available iPhone simulator")
print(best[1])
print(f"{best[2]} / {best[3]}", file=sys.stderr)
')
echo "simulator: $DEVICE_ID"

echo "== xcodebuild test (iOS Simulator)"
rm -rf "$OUT/results/BKCore-iOS-Simulator.xcresult"
set +e
(cd "$PACKAGE_DIR" && xcodebuild test \
  -scheme BKCore-Package \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath "$OUT/derived-package" \
  -resultBundlePath "$OUT/results/BKCore-iOS-Simulator.xcresult") 2>&1 | tee "$OUT/logs/simulator-test.log"
STATUS=${PIPESTATUS[0]}
set -e
if [[ $STATUS -ne 0 ]]; then
  echo "::error title=iOS Simulator tests::模拟器上的核心业务测试失败（退出码 $STATUS）"
  exit $STATUS
fi

HOST_CASES=$(grep -o '<testcase ' "$OUT/results/swift-test.xml" 2>/dev/null | wc -l | tr -d ' ')
HOST_FAILS=$(grep -o '<failure' "$OUT/results/swift-test.xml" 2>/dev/null | wc -l | tr -d ' ')
SIM_SUMMARY=$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$OUT/logs/simulator-test.log" | tail -n 1 | sed 's/^[[:space:]]*//')
echo "::notice title=Tests::macOS swift test: ${HOST_CASES} cases, ${HOST_FAILS} failures; iOS Simulator: ${SIM_SUMMARY:-see log}"
