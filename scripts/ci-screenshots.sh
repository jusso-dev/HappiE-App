#!/usr/bin/env bash
# Builds HappiE for the simulator, serves the mock API, and captures key
# screens on an iPhone and an iPad. Screenshots land in $OUT_DIR.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/build/screenshots}"
DERIVED="${DERIVED:-$ROOT/build/DerivedData}"
BUNDLE_ID="au.com.HappiE"
CHILD_ID="c0000000-0000-4000-8000-000000000001"
SETTLE="${SETTLE:-7}"

mkdir -p "$OUT_DIR"

pick_device() {
  # Simulator on the newest iOS runtime: the first preferred name that
  # exists, otherwise any device whose name starts with the first word.
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
preferred = sys.argv[1:]
prefix = preferred[0].split()[0]
def version(runtime):
    return [int(n) for n in re.findall(r"\d+", runtime.rsplit(".", 1)[-1])]
runtimes = sorted(
    ((r, d) for r, d in json.load(sys.stdin)["devices"].items() if ".iOS-" in r),
    key=lambda item: version(item[0]),
)
if not runtimes:
    sys.exit()
devices = runtimes[-1][1]
by_name = {d["name"]: d["udid"] for d in devices}
match = next((by_name[n] for n in preferred if n in by_name), None)
match = match or next((d["udid"] for d in devices if d["name"].startswith(prefix)), "")
print(match)
' "$@"
}

IPHONE="${IPHONE_UDID:-$(pick_device "iPhone 17 Pro" "iPhone 17" "iPhone 16 Pro" "iPhone 16")}"
IPAD="${IPAD_UDID:-$(pick_device "iPad Air 11-inch (M4)" "iPad Air 11-inch (M3)" "iPad (A16)")}"
[[ -n "$IPHONE" && -n "$IPAD" ]] || { echo "No iPhone/iPad simulator available" >&2; exit 1; }

xcodebuild -project "$ROOT/HappiE.xcodeproj" -scheme HappiE \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build -quiet
APP="$DERIVED/Build/Products/Debug-iphonesimulator/HappiE.app"

SAMPLE="$ROOT/build/sample.mp4"
if [[ ! -f "$SAMPLE" ]] && command -v ffmpeg >/dev/null; then
  ffmpeg -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -t 20 \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$SAMPLE" || true
fi

python3 "$ROOT/scripts/mock_api.py" "$SAMPLE" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:18080/children" >/dev/null && break
  sleep 0.2
done
curl -sf "http://127.0.0.1:18080/children" >/dev/null || { echo "Mock API did not start" >&2; exit 1; }

# launch <udid> <name> [app arguments...]: fresh install, launch, capture.
launch() {
  local udid="$1" name="$2"
  shift 2
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP" || return 1
  xcrun simctl launch "$udid" "$BUNDLE_ID" "$@" >/dev/null
  sleep "$SETTLE"
  xcrun simctl io "$udid" screenshot "$OUT_DIR/$name.png" >/dev/null
  echo "captured $name"
}

for device in iphone ipad; do
  udid="$IPHONE"; [[ "$device" == ipad ]] && udid="$IPAD"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiBars 3 >/dev/null 2>&1 || true

  if ! launch "$udid" "$device-01-profiles" -HappiESelectedChildId none; then
    echo "::warning::HappiE does not install on the $device simulator; skipping its screens"
    continue
  fi
  launch "$udid" "$device-02-home" -HappiESelectedChildId "$CHILD_ID"
  launch "$udid" "$device-03-parent-gate" -HappiESelectedChildId "$CHILD_ID" -uitest-parent-gate
  launch "$udid" "$device-04-error" -HappiEAPIBaseURL "http://localhost:9"
  if [[ -f "$SAMPLE" ]]; then
    launch "$udid" "$device-05-player" -HappiESelectedChildId "$CHILD_ID" -uitest-play-first-video
  fi
done

ls -1 "$OUT_DIR"
