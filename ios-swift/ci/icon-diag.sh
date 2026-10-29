#!/usr/bin/env bash
# 临时诊断：AppIcon.icon 为什么导出失败。逐个去掉 icon.json 的设置，用 ictool / actool 编译，结果写成注释。
set -uo pipefail
OUT="${1:?output dir}"
D="$OUT/icon-diag"
mkdir -p "$D"
ICTOOL="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
SRC="ios-swift/Bookkeeping/AppIcon.icon"
esc() { cut -c1-300 | sed 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}'; }

echo "::notice title=Diag-ictool::$("$ICTOOL" --version 2>&1 | head -c 400 | esc)"
echo "::notice title=Diag-ictool-help::$("$ICTOOL" --help 2>&1 | head -n 60 | esc)"

mkdir -p "$D/ac"
xcrun actool "$SRC" --compile "$D/ac" --platform iphoneos --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$D/ac/partial.plist" --target-device iphone --errors --warnings --notices \
  --output-format human-readable-text > "$D/actool.log" 2>&1
echo "::notice title=Diag-actool::status=$? $(tail -n 40 "$D/actool.log" | esc)"

python3 - "$SRC" "$D" <<'PY'
import copy, json, os, shutil, sys
src, out = sys.argv[1], sys.argv[2]
base = json.load(open(os.path.join(src, "icon.json")))
def strip(m, key):
    m.pop(key, None)
    for g in m["groups"]:
        g.pop(key, None)
        for l in g["layers"]:
            l.pop(key, None)
    return m
def no_tinted(m):
    for holder in [m] + m["groups"] + [l for g in m["groups"] for l in g["layers"]]:
        if "fill-specializations" in holder:
            holder["fill-specializations"] = [s for s in holder["fill-specializations"] if s.get("appearance") != "tinted"]
    return m
def minimal(m):
    layer = m["groups"][1]["layers"][1]
    return {"fill": {"solid": "srgb:0.5,0.5,0.5,1.00000"}, "groups": [{"layers": [{"image-name": layer["image-name"], "name": "x"}]}],
            "supported-platforms": {"squares": "shared"}}
variants = {
    "full": lambda m: m,
    "no-colorspace": lambda m: strip(m, "color-space-for-untagged-svg-colors"),
    "no-lighting": lambda m: strip(m, "lighting"),
    "no-name": lambda m: (lambda m: [g.pop("name", None) for g in m["groups"]] and m)(m),
    "no-tinted": no_tinted,
    "no-glass": lambda m: strip(m, "glass"),
    "minimal": minimal,
}
for name, fn in variants.items():
    d = os.path.join(out, name + ".icon")
    shutil.copytree(src, d)
    json.dump(fn(copy.deepcopy(base)), open(os.path.join(d, "icon.json"), "w"), indent=2)
# 最小的图标，换一个最简单的 SVG（没有 XML 声明、没有分组、没有弧线）
d = os.path.join(out, "minimal-plain-svg.icon")
shutil.copytree(os.path.join(out, "minimal.icon"), d)
img = json.load(open(os.path.join(d, "icon.json")))["groups"][0]["layers"][0]["image-name"]
open(os.path.join(d, "Assets", img), "w").write('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><rect x="256" y="256" width="512" height="512" fill="#ffffff"/></svg>')
PY

for icon in "$D"/*.icon; do
  name=$(basename "$icon" .icon)
  "$ICTOOL" "$icon" --export-image --output-file "$D/$name.png" --platform iOS --rendition Default \
    --width 64 --height 64 --scale 1 > "$D/$name.log" 2>&1
  status=$?
  echo "::notice title=Diag-$name::ictool status=$status png=$([[ -f "$D/$name.png" ]] && echo yes || echo no) $(tail -n 8 "$D/$name.log" | esc)"
done
exit 1
