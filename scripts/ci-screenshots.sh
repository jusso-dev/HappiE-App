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
  # Newest available simulator whose name starts with $1.
  xcrun simctl list devices available -j | python3 -c '
import json, sys
prefix = sys.argv[1]
runtimes = json.load(sys.stdin)["devices"]
found = [
    (runtime, d["udid"], d["name"])
    for runtime, devices in runtimes.items() if "iOS" in runtime
    for d in devices if d["name"].startswith(prefix)
]
found.sort()
print(found[-1][1] if found else "")
' "$1"
}

IPHONE="${IPHONE_UDID:-$(pick_device "iPhone")}"
IPAD="${IPAD_UDID:-$(pick_device "iPad")}"
[[ -n "$IPHONE" && -n "$IPAD" ]] || { echo "No iPhone/iPad simulator available" >&2; exit 1; }

xcodebuild -project "$ROOT/HappiE.xcodeproj" -scheme HappiE \
  -destination "id=$IPHONE" -derivedDataPath "$DERIVED" \
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

# launch <udid> <name> [app arguments...]: fresh install, launch, capture.
launch() {
  local udid="$1" name="$2"
  shift 2
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP"
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

  launch "$udid" "$device-01-profiles" -HappiESelectedChildId none
  launch "$udid" "$device-02-home" -HappiESelectedChildId "$CHILD_ID"
  launch "$udid" "$device-03-parent-gate" -HappiESelectedChildId "$CHILD_ID" -uitest-parent-gate
  launch "$udid" "$device-04-error" -HappiEAPIBaseURL "http://localhost:9"
  if [[ -f "$SAMPLE" ]]; then
    launch "$udid" "$device-05-player" -HappiESelectedChildId "$CHILD_ID" -uitest-play-first-video
  fi
done

ls -1 "$OUT_DIR"
