#!/usr/bin/env bash
# 选出 runtime 版本最高的可用 iPhone 模拟器：UDID 输出到 stdout，名称与 runtime 输出到 stderr。
# 可选参数：机型名的正则（例如 '^iPhone \d+ Pro$'），优先选匹配的机型，没有匹配时退回任意 iPhone。
# 用法：DEVICE_ID=$(bash ios-swift/ci/pick-simulator.sh ['<机型正则>'])
set -euo pipefail

xcrun simctl list devices available --json | python3 -c '
import json, sys, re
prefer = re.compile(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else None
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            matched = bool(prefer and prefer.search(d["name"]))
            # 机型号按数字比较（iPhone 18 > iPhone 9）
            n = re.search(r"\d+", d["name"])
            key = (matched, version, int(n.group()) if n else 0, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"], runtime)
if best is None:
    sys.exit("no available iPhone simulator")
print(best[1])
print(f"{best[2]} / {best[3]}", file=sys.stderr)
' "${1:-}"
