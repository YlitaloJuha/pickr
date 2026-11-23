#!/usr/bin/env bash
# README media from the iOS Simulator, in demo mode (synthetic test-photos only):
#   images/demo/hero.webp (dark) and hero-light.webp: the main action as an animation;
#   images/screens/<name>.png (light) and <name>-dark.png, then framed copies in
#   images/screens/framed/ (scripts/frame-screens.swift).
#
#   scripts/sim-capture.sh [--device "iPhone 17 Pro"] [--appearance light|dark] [--keep]
#
# Needs Xcode 27.2 with an iOS 27 simulator runtime, xcodegen, ffmpeg and img2webp (brew
# install webp). Simulator only: nothing on a real device or in any photo library is touched.
# Temporary files live in one mktemp directory, removed at the end unless --keep.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_NAME="iPhone 17 Pro"
APPEARANCES="dark light"
KEEP=0
DEMOS="hero review swipe adjust kept"
MARK_RE='PICKR-DEMO-MARK (light|dark) [a-z]+ (start|end|still:[a-z-]+) [0-9]+\.[0-9]+'

while [ $# -gt 0 ]; do
    case "$1" in
        --device) DEVICE_NAME="$2"; shift 2 ;;
        --appearance) APPEARANCES="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "sim-capture.sh: unknown option $1" >&2; exit 2 ;;
    esac
done

log() { printf '==> %s\n' "$*"; }
die() { printf 'sim-capture.sh: %s\n' "$*" >&2; exit 1; }
for tool in xcrun xcodegen ffmpeg img2webp python3; do
    command -v "$tool" >/dev/null || die "$tool not found"
done

TMP_BASE="${TMPDIR:-/tmp}"; TMP_BASE="${TMP_BASE%/}"
WORK="$(mktemp -d "$TMP_BASE/pickr-sim.XXXXXX")"
case "$WORK" in "$TMP_BASE"/pickr-sim.??????) ;; *) die "unexpected temporary directory $WORK" ;; esac
cleanup() {
    if [ "$KEEP" = 0 ]; then
        case "$WORK" in "$TMP_BASE"/pickr-sim.??????) rm -rf -- "$WORK" ;; esac
    else
        echo "kept $WORK"
    fi
}
trap cleanup EXIT

# The newest iOS 27 runtime and a device of the requested type on it.
RUNTIME="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["version"].startswith("27") and r["isAvailable"]]
print(sorted(rs, key=lambda r: r["version"])[-1]["identifier"] if rs else "")')"
[ -n "$RUNTIME" ] || die "no iOS 27 simulator runtime (Xcode > Settings > Components)"
UDID="$(xcrun simctl list devices -j | python3 -c '
import json, sys
name, rt = sys.argv[1], sys.argv[2]
ds = json.load(sys.stdin)["devices"].get(rt, [])
print(next((d["udid"] for d in ds if d["name"] == name and d["isAvailable"]), ""))' "$DEVICE_NAME" "$RUNTIME")"
if [ -z "$UDID" ]; then
    TYPE="$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
print(next((t["identifier"] for t in json.load(sys.stdin)["devicetypes"] if t["name"] == sys.argv[1]), ""))' "$DEVICE_NAME")"
    [ -n "$TYPE" ] || die "no simulator device type named $DEVICE_NAME"
    UDID="$(xcrun simctl create "Pickr demo ($DEVICE_NAME)" "$TYPE" "$RUNTIME")"
fi
log "simulator $DEVICE_NAME ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100

log "generating the project and building for testing"
"$ROOT/scripts/verify.sh" generate >/dev/null
DD="$WORK/DerivedData"
xcodebuild build-for-testing -project "$ROOT/Pickr.xcodeproj" -scheme Pickr -configuration Debug \
    -destination "id=$UDID" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO >"$WORK/build.log" 2>&1 ||
    { tail -30 "$WORK/build.log"; die "build-for-testing failed"; }

test_name() { printf 'test%s' "$(printf '%s' "$1" | cut -c1 | tr a-z A-Z)$(printf '%s' "$1" | cut -c2-)"; }

MARKS="$WORK/marks.txt"; : >"$MARKS"
for appearance in $APPEARANCES; do
    xcrun simctl ui "$UDID" appearance "$appearance"
    for demo in $DEMOS; do
        log "$demo ($appearance)"
        mov="$WORK/$demo-$appearance.mov"
        xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$mov" >"$WORK/rec-$demo-$appearance.log" 2>&1 &
        rec=$!
        for _ in $(seq 1 50); do grep -q "Recording started" "$WORK/rec-$demo-$appearance.log" && break; sleep 0.1; done
        python3 -c 'import time; print(f"{time.time():.3f}")' >"$WORK/$demo-$appearance.start"
        TEST_RUNNER_PICKR_DEMO=1 TEST_RUNNER_PICKR_DEMO_APPEARANCE="$appearance" \
            xcodebuild test-without-building -project "$ROOT/Pickr.xcodeproj" -scheme Pickr -configuration Debug \
            -destination "id=$UDID" -derivedDataPath "$DD" \
            -only-testing:"PickrUITests/DemoRecordingTests/$(test_name "$demo")" >"$WORK/test-$demo-$appearance.log" 2>&1 ||
            { grep -E "error:|failed" "$WORK/test-$demo-$appearance.log" | head -5; echo "    ($demo $appearance failed; continuing)"; }
        kill -INT "$rec" 2>/dev/null || true
        wait "$rec" 2>/dev/null || true
        grep -oE "$MARK_RE" "$WORK/test-$demo-$appearance.log" | sed 's/^PICKR-DEMO-MARK //' | sort -u >>"$MARKS" || true
    done
done
xcrun simctl status_bar "$UDID" clear || true

mark() { awk -v a="$1" -v d="$2" -v e="$3" '$1 == a && $2 == d && $3 == e { print $4; exit }' "$MARKS"; }
calc() { python3 -c "print(f'{$1:.3f}')"; }

mkdir -p "$ROOT/images/demo" "$ROOT/images/screens"
for appearance in $APPEARANCES; do
    suffix=""; [ "$appearance" = light ] && suffix="-light"
    # The hero animation: from its start mark to its end mark.
    start="$(mark "$appearance" hero start)"; end="$(mark "$appearance" hero end)"
    if [ -n "$start" ] && [ -n "$end" ]; then
        from="$(calc "$start - $(cat "$WORK/hero-$appearance.start")")"; dur="$(calc "$end - $start")"
        frames="$WORK/frames-$appearance"; mkdir -p "$frames"
        ffmpeg -nostdin -loglevel error -y -ss "$from" -t "$dur" -i "$WORK/hero-$appearance.mov" \
            -vf "fps=20,scale=390:-1:flags=lanczos" "$frames/f%04d.png"
        img2webp -loop 0 -lossy -q 82 -m 6 -d 50 "$frames"/f*.png -o "$ROOT/images/demo/hero$suffix.webp" >/dev/null
        printf '    images/demo/hero%s.webp (%s s)\n' "$suffix" "$dur"
    else
        echo "    no hero marks for $appearance"
    fi
    # The stills, at their marks, full resolution scaled to 756 px wide.
    awk -v a="$appearance" '$1 == a && $3 ~ /^still:/ { print $2, substr($3, 7), $4 }' "$MARKS" | sort -u -k2,2 |
        while read -r demo name at; do
            t="$(calc "$at - $(cat "$WORK/$demo-$appearance.start") + 0.4")"
            out="$name"; [ "$appearance" = dark ] && out="$name-dark"
            ffmpeg -nostdin -loglevel error -y -ss "$t" -i "$WORK/$demo-$appearance.mov" -frames:v 1 \
                -vf "scale=756:-2:flags=lanczos" "$ROOT/images/screens/$out.png"
            printf '    images/screens/%s.png\n' "$out"
        done
done
swift "$ROOT/scripts/frame-screens.swift" "$ROOT/images/screens" | sed 's/^/    /'
log "done"
