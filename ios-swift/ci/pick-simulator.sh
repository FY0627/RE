#!/usr/bin/env bash
# 选出 runtime 版本最高的可用 iPhone 模拟器：UDID 输出到 stdout，名称与 runtime 输出到 stderr。
# 用法：DEVICE_ID=$(bash ios-swift/ci/pick-simulator.sh)
set -euo pipefail

xcrun simctl list devices available --json | python3 -c '
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
'
