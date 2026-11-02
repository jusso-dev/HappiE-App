#!/usr/bin/env bash
# Builds HappiE for the simulator, serves the mock API, and captures key
# screens on an iPhone and an iPad. Screenshots land in $OUT_DIR.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/build/screenshots}"
DERIVED="${DERIVED:-$ROOT/build/DerivedData}"
BUNDLE_ID="au.com.HappiE"
CHILD_ID="c0000000-0000-4000-8000-000000000001"
SETTLE="${SETTLE:-4}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"

mkdir -p "$OUT_DIR" "$ROOT/build"

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

# Cold boots take minutes on CI runners; let them overlap the build.
xcrun simctl boot "$IPHONE" 2>/dev/null || true
xcrun simctl boot "$IPAD" 2>/dev/null || true

xcodebuild -project "$ROOT/HappiE.xcodeproj" -scheme HappiE \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build -quiet
APP="$DERIVED/Build/Products/Debug-iphonesimulator/HappiE.app"

SAMPLE="$ROOT/build/sample.mp4"
if [[ ! -f "$SAMPLE" ]] && command -v ffmpeg >/dev/null; then
  ffmpeg -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -t 20 \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$SAMPLE" || true
fi

MOCK_LOG="$ROOT/build/mock-api.log"
python3 "$ROOT/scripts/mock_api.py" "$SAMPLE" 2>"$MOCK_LOG" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:18080/children" >/dev/null && break
  sleep 0.2
done
curl -sf "http://127.0.0.1:18080/children" >/dev/null || { echo "Mock API did not start" >&2; exit 1; }

# launch <udid> <name> <ready-pattern> [app arguments...]: fresh install,
# launch, wait until the mock API logs a request matching <ready-pattern>
# (the screen's data has been fetched; empty pattern = no request to wait
# for), let it render, then capture.
launch() {
  local udid="$1" name="$2" ready="$3"
  shift 3
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP" || return 1
  local seen
  seen=$(wc -l <"$MOCK_LOG")
  # Explicit returns: errexit is off inside `if ! launch ...`.
  xcrun simctl launch "$udid" "$BUNDLE_ID" "$@" >/dev/null || return 1
  if [[ -n "$ready" ]]; then
    local waited=0
    until tail -n +"$((seen + 1))" "$MOCK_LOG" | grep -q -- "$ready"; do
      if (( waited >= READY_TIMEOUT )); then
        # Fail loudly: a loading-screen capture must not pass as the real screen.
        xcrun simctl io "$udid" screenshot "$OUT_DIR/$name-TIMEOUT.png" >/dev/null 2>&1 || true
        echo "::error::$name: no '$ready' request after ${READY_TIMEOUT}s"
        exit 1
      fi
      sleep 1
      waited=$((waited + 1))
    done
  else
    sleep 15
  fi
  sleep "$SETTLE"
  xcrun simctl io "$udid" screenshot "$OUT_DIR/$name.png" >/dev/null || return 1
  echo "captured $name"
}

for device in iphone ipad; do
  udid="$IPHONE"; [[ "$device" == ipad ]] && udid="$IPAD"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiBars 3 >/dev/null 2>&1 || true

  if ! launch "$udid" "$device-01-profiles" "GET /children" -HappiESelectedChildId none; then
    echo "::warning::HappiE does not install on the $device simulator; skipping its screens"
    continue
  fi
  launch "$udid" "$device-02-home" "GET /thumbs/" -HappiESelectedChildId "$CHILD_ID"
  launch "$udid" "$device-03-parent-gate" "/sync" -HappiESelectedChildId "$CHILD_ID" -uitest-parent-gate
  launch "$udid" "$device-04-error" "" -HappiEAPIBaseURL "http://localhost:9"
  if [[ -f "$SAMPLE" ]]; then
    launch "$udid" "$device-05-player" "GET /media/sample.mp4" -HappiESelectedChildId "$CHILD_ID" -uitest-play-first-video
  fi
done

ls -1 "$OUT_DIR"
