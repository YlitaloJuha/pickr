#!/usr/bin/env bash
# README demo GIFs and screenshots of Pickr., recorded on a real iPhone in demo mode.
#
#   scripts/demo-gifs.sh [--only <demo>] [--appearance light|dark] [--keep-mov]
#                        [--device <udid>] [--recorder auto|helper|ffmpeg|manual]
#                        [--derived-data <dir>] [--mark-offset <seconds>] [--square]
#   scripts/demo-gifs.sh --from-recording <file or folder> --marks <file>
#                        [--recording-start <seconds since 1970>] [--only …] [--appearance …]
#   scripts/demo-gifs.sh --check        preflight, tools, iPhone and screen capture; no build
#
# Demos (PickrUITests/DemoRecordingTests): hero, review, swipe, adjust, kept. They run in
# demo mode (-PickrDemo YES, Debug builds): the 40 synthetic photos of test-photos/ in
# memory, no PhotoKit, nothing on the iPhone changed. For each appearance and demo the
# script records the iPhone's screen while the test runs, cuts the recording at the marks the
# test logs, and writes
#   images/demo/<demo>.gif (dark) and images/demo/<demo>-light.gif (light), 390 px wide;
#   images/screens/<name>.png (light) and <name>-dark.png for moments, review-grid,
#   review-single, adjust and kept.
#
# Recording: over USB as QuickTime does (scripts/enable-ios-screen-capture.swift records;
# ffmpeg does instead if it lists the iPhone's screen itself). If the screen can't be
# captured, it explains the fallback: --recorder manual runs the demos while you record with
# Control Center's Screen Recording, then cuts the file you pass (--from-recording).
#
# Needs Xcode 27.2, xcodegen, ffmpeg, python3, and the iPhone connected by USB, unlocked,
# with Developer Mode on and your team in Config/Signing.local.xcconfig. docs/RELEASING.md
# ("README demos") has the steps.
#
# Safety: nothing on the iPhone is deleted and no photo library is touched; on the Mac the
# script writes only to its own mktemp directory and to images/demo and images/screens, and
# its preflight refuses to start if this file contains a forbidden command.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/scripts/demo-gifs.sh"
PROJECT="$ROOT/Pickr.xcodeproj"
OUT_GIFS="$ROOT/images/demo"
OUT_STILLS="$ROOT/images/screens"

ALL_DEMOS="hero review swipe adjust kept"
GIF_WIDTH=390
STILL_WIDTH="${PICKR_DEMO_STILL_WIDTH:-756}"
MAX_GIF_BYTES="${PICKR_DEMO_MAX_GIF_BYTES:-4000000}"
# The display's corner radius as a fraction of its width (iPhone 17: 55 of 402 pt).
CORNER_FRACTION="${PICKR_DEMO_CORNER:-0.137}"
# The screen's aspect ratio (iPhone 17: 1206 × 2622 px); recordings are cropped to it.
SCREEN_ASPECT="${PICKR_DEMO_SCREEN_ASPECT:-0.45995}"
# Cut this long after the start mark: the tests hold still for a second after it.
HEAD_PAD=0.3
# Stills are taken this long after their mark, once animations have settled.
STILL_PAD=0.35

log() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf 'demo-gifs.sh: warning: %s\n' "$*" >&2; }
die() {
    printf 'demo-gifs.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '2,31p' "$SELF" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Preflight: refuse to run if this file contains a command that could delete or change
# anything outside the script's own temporary directory. The patterns are assembled from
# pieces so that they don't match themselves.

preflight() {
    local hits="" pattern
    local dctl="devicectl" sctl="simctl" osa="osa" pics="Pictures" movs="Movies" dls="Downloads"
    local patterns=(
        "${dctl}[[:space:]]+device[[:space:]]+(files[[:space:]]+delete|uninstall)"
        "${sctl}[[:space:]]+(uninstall|erase|delete)"
        "${osa}script"
        "idevice""installer|idevice""fs|afc""client"
        "find[[:space:]].*-delete|unlink[[:space:]]|srm[[:space:]]"
        "${pics}/|${movs}/|${dls}/|photos""library"
    )
    for pattern in "${patterns[@]}"; do
        hits="$hits$(grep -nE -- "$pattern" "$SELF" || true)"
    done
    # Removing files happens in safe_remove only.
    hits="$hits$(awk '
        /^safe_remove\(\) \{/ { inside = 1 }
        inside && /^\}/ { inside = 0; next }
        /^[[:space:]]*#/ { next }
        !inside && /(^|[[:space:];&|(`])rm([[:space:]]|$)/ { print FNR ": " $0 }
    ' "$SELF")"
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" | sed 's/^/    /' >&2
        die "preflight: forbidden commands in $SELF; refusing to start"
    fi
}

# ---------------------------------------------------------------------------
# Temporary files: one mktemp directory, removed only through safe_remove.

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
WORK=""
KEEP_WORK=0
RECORDER_PID=""

make_work_dir() {
    WORK="$(mktemp -d "$TMP_BASE/pickr-demo.XXXXXX")"
    case "$WORK" in
        "$TMP_BASE"/pickr-demo.??????) ;;
        *) die "unexpected temporary directory '$WORK'" ;;
    esac
    [ -d "$WORK" ] || die "could not create a temporary directory in $TMP_BASE"
    mkdir -p "$WORK/rec" "$WORK/logs" "$WORK/results" "$WORK/gif"
}

# safe_remove <path>: removes the path only if it is the script's temporary directory or
# inside it. Anything else is refused.
safe_remove() {
    local target="${1:-}"
    if [ -z "$WORK" ] || [ -z "$target" ]; then
        warn "safe_remove: refusing an empty path"
        return 1
    fi
    case "$WORK" in
        "$TMP_BASE"/pickr-demo.??????) ;;
        *)
            warn "safe_remove: refusing, the temporary directory '$WORK' is not the script's own"
            return 1
            ;;
    esac
    case "$target" in
        *"/../"* | *"/.." | *"/./"*)
            warn "safe_remove: refusing '$target' (relative components)"
            return 1
            ;;
        "$WORK" | "$WORK"/*) ;;
        *)
            warn "safe_remove: refusing '$target': not inside $WORK"
            return 1
            ;;
    esac
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        return 0
    fi
    rm -rf -- "$target"
}

stop_recorder() {
    local pid="$RECORDER_PID" waited
    [ -n "$pid" ] || return 0
    RECORDER_PID=""
    kill -0 "$pid" 2>/dev/null || {
        wait "$pid" 2>/dev/null || true
        return 0
    }
    kill -INT "$pid" 2>/dev/null || true
    for waited in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for waited in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
    fi
    if kill -0 "$pid" 2>/dev/null; then
        warn "the recorder did not stop; killing it (that recording may be unusable)"
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    stop_recorder
    if [ -n "$WORK" ]; then
        if [ "$KEEP_WORK" = 1 ]; then
            printf 'demo-gifs.sh: kept the temporary files in %s\n' "$WORK" >&2
        else
            safe_remove "$WORK" || true
        fi
    fi
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# publish <file> <destination>: copies a finished file over its place in images/demo or
# images/screens. Never anywhere else, never removes anything.
publish() {
    local source="$1" destination="$2"
    case "$destination" in
        "$OUT_GIFS"/*.gif | "$OUT_STILLS"/*.png) ;;
        *) die "refusing to write outside images/demo and images/screens: $destination" ;;
    esac
    case "${destination##*/}" in
        *[!a-z0-9.-]*) die "unexpected output name: $destination" ;;
    esac
    [ -s "$source" ] || die "nothing to publish for $destination"
    mkdir -p "$(dirname "$destination")"
    cp -f "$source" "$destination"
}

# ---------------------------------------------------------------------------
# Options

ONLY=""
APPEARANCES="dark light"
DEVICE="${PICKR_DEMO_DEVICE:-}"
RECORDER="auto"
DERIVED_DATA=""
MARK_OFFSET=0
FROM_RECORDING=""
MARKS_FILE=""
RECORDING_START=""
CHECK_ONLY=0
KEEP_MOV=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --only)
            ONLY="${2:-}"
            shift
            ;;
        --appearance)
            APPEARANCES="${2:-}"
            shift
            ;;
        --device)
            DEVICE="${2:-}"
            shift
            ;;
        --recorder)
            RECORDER="${2:-}"
            shift
            ;;
        --derived-data)
            DERIVED_DATA="${2:-}"
            shift
            ;;
        --mark-offset)
            MARK_OFFSET="${2:-}"
            shift
            ;;
        --from-recording)
            FROM_RECORDING="${2:-}"
            shift
            ;;
        --marks)
            MARKS_FILE="${2:-}"
            shift
            ;;
        --recording-start)
            RECORDING_START="${2:-}"
            shift
            ;;
        --square) CORNER_FRACTION=0 ;;
        --keep-mov) KEEP_MOV=1 ;;
        --check) CHECK_ONLY=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
    shift
done

if [ -n "$ONLY" ]; then
    case " $ALL_DEMOS " in
        *" $ONLY "*) ;;
        *) die "--only must be one of: $ALL_DEMOS" ;;
    esac
fi
DEMOS="${ONLY:-$ALL_DEMOS}"
case "$APPEARANCES" in
    "dark light" | dark | light) ;;
    *) die "--appearance must be light or dark" ;;
esac
case "$RECORDER" in
    auto | helper | ffmpeg | manual) ;;
    *) die "--recorder must be auto, helper, ffmpeg or manual" ;;
esac
case "$MARK_OFFSET" in
    '' | *[!0-9.-]*) die "--mark-offset takes seconds, for example -0.4" ;;
esac
if [ -n "$RECORDING_START" ]; then
    case "$RECORDING_START" in
        *[!0-9.]*) die "--recording-start takes seconds since 1970" ;;
    esac
fi

# ---------------------------------------------------------------------------
# Small helpers

calc() { awk "BEGIN { printf \"%.3f\", $1 }"; }
is_less() { awk "BEGIN { exit !($1 < $2) }"; }
file_size() { wc -c <"$1" | tr -d ' '; }
megabytes() { awk -v b="$1" 'BEGIN { printf "%.2f MB", b / 1000000 }'; }

test_name() {
    case "$1" in
        hero) echo testHero ;;
        review) echo testReview ;;
        swipe) echo testSwipe ;;
        adjust) echo testAdjust ;;
        kept) echo testKept ;;
    esac
}

require_tools() {
    local tool missing=""
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    [ -z "$missing" ] || die "missing tools:$missing (ffmpeg: brew install ffmpeg; xcodegen: brew install xcodegen)"
}

# ---------------------------------------------------------------------------
# The iPhone

DEVICE_NAME=""

# Finds the iPhone (the one given, or the only one connected by USB) with devicectl.
resolve_device() {
    local json="$WORK/devices.json" found
    if ! xcrun devicectl list devices --json-output "$json" >"$WORK/logs/devicectl.log" 2>&1; then
        tail -5 "$WORK/logs/devicectl.log" >&2
        die "xcrun devicectl could not list devices (is Xcode 27.2 selected?)"
    fi
    found="$(python3 -I - "$json" "$DEVICE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
wanted = sys.argv[2].strip().upper()
rows = []
for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    if hardware.get("platform") != "iOS" or hardware.get("reality") != "physical":
        continue
    udid = hardware.get("udid", "")
    if wanted and udid.upper() != wanted:
        continue
    wired = connection.get("transportType") == "wired"
    if not wanted and not wired:
        continue
    rows.append("\t".join([
        udid,
        properties.get("name", ""),
        properties.get("osVersionNumber", "?"),
        properties.get("developerModeStatus", "?"),
        connection.get("tunnelState", "?"),
        "wired" if wired else connection.get("transportType", "?"),
    ]))
print("\n".join(rows))
PY
)"
    if [ -z "$found" ]; then
        if [ -n "$DEVICE" ]; then
            die "no iPhone with UDID $DEVICE is paired with this Mac (xcrun devicectl list devices)"
        fi
        die "no iPhone connected by USB. Connect it with a cable, unlock it and trust this Mac, or pass --device <udid>."
    fi
    if [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" -gt 1 ]; then
        printf '%s\n' "$found" | cut -f1,3 | sed 's/^/    /' >&2
        die "more than one iPhone is connected by USB; pick one with --device <udid>"
    fi
    local os mode tunnel transport
    IFS=$'\t' read -r DEVICE DEVICE_NAME os mode tunnel transport <<<"$found"
    note "iPhone $DEVICE (iOS $os, Developer Mode $mode, $transport, tunnel $tunnel)"
    case "$os" in 27.*) ;; *) warn "the iPhone runs iOS $os; Pickr. 2.0 needs iOS 27" ;; esac
    [ "$mode" = enabled ] || die "Developer Mode is not on (Settings > Privacy & Security > Developer Mode)"
    [ "$transport" = wired ] || warn "the iPhone is not connected by USB; screen capture needs the cable"
}

require_signing() {
    local file="$ROOT/Config/Signing.local.xcconfig"
    [ -f "$file" ] || die "Config/Signing.local.xcconfig is missing: run scripts/bootstrap.sh and set DEVELOPMENT_TEAM there"
    grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' "$file" ||
        die "set DEVELOPMENT_TEAM in Config/Signing.local.xcconfig (git-ignored) to sign for the iPhone"
}

# ---------------------------------------------------------------------------
# Screen capture

HELPER=""
SCREEN_NAME=""

build_helper() {
    HELPER="$WORK/enable-ios-screen-capture"
    log "compiling scripts/enable-ios-screen-capture.swift"
    if ! swiftc -swift-version 6 -O -o "$HELPER" "$ROOT/scripts/enable-ios-screen-capture.swift" \
        >"$WORK/logs/helper-build.log" 2>&1; then
        tail -20 "$WORK/logs/helper-build.log" >&2
        die "the screen capture helper did not compile"
    fi
}

manual_instructions() {
    cat >&2 <<EOF

The iPhone's screen can't be recorded over USB: $1
Record it on the iPhone instead:
  1. On the iPhone, turn on Do Not Disturb (so no notification shows up in the GIFs), set
     Auto-Lock to Never and keep it unlocked.
  2. Run: scripts/demo-gifs.sh --recorder manual$( [ -n "$ONLY" ] && printf ' --only %s' "$ONLY")
     It builds, asks you to start Screen Recording from Control Center, runs the demos and
     writes the marks file it needs to cut the recording.
  3. Stop the recording, move it to this Mac (AirDrop or Image Capture) and give its path
     when asked, or later run:
     scripts/demo-gifs.sh --from-recording <file or folder> --marks <marks file>
EOF
}

# Chooses how to record: the helper (in-process CoreMediaIO + AVFoundation) unless ffmpeg
# itself lists the iPhone's screen under exactly its name. Never a camera.
choose_recorder() {
    local status=0 listing
    [ "$RECORDER" != manual ] || return 0
    build_helper
    log "looking for the iPhone's screen (screen capture devices)"
    listing="$("$HELPER" --name "$DEVICE_NAME" --udid "$DEVICE" --wait 12 2>"$WORK/logs/helper-list.log")" || status=$?
    case "$status" in
        0) ;;
        3)
            manual_instructions "camera access is denied for this terminal. Allow it in System Settings > Privacy & Security > Camera and run again, or:"
            exit 3
            ;;
        *)
            cat "$WORK/logs/helper-list.log" >&2
            manual_instructions "no capture device for the iPhone appeared (is it unlocked, trusted and on the cable?)."
            exit 2
            ;;
    esac
    SCREEN_NAME="$(printf '%s\n' "$listing" | awk -F'\t' '$4 == "chosen" { print $3; exit }')"
    [ -n "$SCREEN_NAME" ] || die "the helper chose no screen"
    note "screen capture device: $SCREEN_NAME"
    if [ "$RECORDER" = helper ]; then
        return 0
    fi
    # ffmpeg lists only what its own process may see; it must show this exact name (a
    # Continuity Camera is "<name> Camera" and is never used).
    if ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 |
        sed -nE 's/^\[AVFoundation[^]]*\] \[[0-9]+\] (.*)$/\1/p' | grep -qxF -- "$SCREEN_NAME"; then
        RECORDER=ffmpeg
        note "recording with ffmpeg"
    elif [ "$RECORDER" = ffmpeg ]; then
        die "ffmpeg does not list the iPhone's screen; use --recorder helper (the default)"
    else
        RECORDER=helper
        note "recording with the helper (ffmpeg can't see screen capture devices)"
    fi
}

# start_recording <base>: starts recording to <base>.mov (helper) or <base>.mkv (ffmpeg) and
# waits for the first frame. Writes <base>.start when known.
start_recording() {
    local base="$1" waited
    case "$RECORDER" in
        helper)
            "$HELPER" --record "$base.mov" --name "$SCREEN_NAME" --udid "$DEVICE" \
                --started-file "$base.start" --wait 15 >"$base.recorder.log" 2>&1 &
            RECORDER_PID=$!
            # The iPhone sends frames only when its screen changes: open Pickr. in demo mode
            # (synthetic photos only) so the first frame arrives; the test relaunches it anyway.
            sleep 1
            xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
                com.juha.Culler -PickrDemo YES -PickrDemoAppearance "${CURRENT_APPEARANCE:-dark}" \
                >"$base.nudge.log" 2>&1 || true
            for waited in $(seq 1 60); do
                [ -s "$base.start" ] && return 0
                kill -0 "$RECORDER_PID" 2>/dev/null || break
                sleep 0.5
            done
            ;;
        ffmpeg)
            ffmpeg -hide_banner -nostdin -loglevel warning -f avfoundation -capture_cursor 0 \
                -framerate 60 -use_wallclock_as_timestamps 1 -i "$SCREEN_NAME:none" \
                -c:v libx264 -preset ultrafast -crf 16 -pix_fmt yuv420p -fps_mode passthrough \
                -copyts -f matroska "$base.mkv" >"$base.recorder.log" 2>&1 &
            RECORDER_PID=$!
            for waited in $(seq 1 40); do
                if [ -s "$base.mkv" ] && [ "$(file_size "$base.mkv")" -gt 4096 ]; then
                    calc "$(date +%s)" >"$base.start.approx"
                    return 0
                fi
                kill -0 "$RECORDER_PID" 2>/dev/null || break
                sleep 0.5
            done
            ;;
    esac
    cat "$base.recorder.log" >&2 || true
    stop_recorder
    return 1
}

# recording_start <base>: the recording's first frame in seconds since 1970.
recording_start() {
    local base="$1" start
    if [ -s "$base.start" ]; then
        tr -d '[:space:]' <"$base.start"
        return 0
    fi
    if [ -f "$base.mkv" ]; then
        start="$(ffprobe -v error -show_entries format=start_time -of default=nw=1:nk=1 "$base.mkv" 2>/dev/null || true)"
        if [ -n "$start" ] && is_less 1000000000 "$start"; then
            printf '%s' "$start"
            return 0
        fi
        if [ -s "$base.start.approx" ]; then
            warn "no wall-clock timestamps in the ffmpeg recording; using the time it appeared (cuts may be early)"
            tr -d '[:space:]' <"$base.start.approx"
            return 0
        fi
    fi
    return 1
}

recording_file() {
    local base="$1"
    if [ -s "$base.mov" ]; then printf '%s' "$base.mov"; elif [ -s "$base.mkv" ]; then printf '%s' "$base.mkv"; fi
}

# ---------------------------------------------------------------------------
# Build and tests

DD=""

build_for_testing() {
    DD="${DERIVED_DATA:-$WORK/DerivedData}"
    mkdir -p "$DD"
    log "generating the project (scripts/verify.sh generate)"
    "$ROOT/scripts/verify.sh" generate >"$WORK/logs/generate.log" 2>&1 || {
        tail -20 "$WORK/logs/generate.log" >&2
        die "xcodegen failed"
    }
    log "build-for-testing on the iPhone (Debug, DerivedData $DD)"
    if ! xcodebuild build-for-testing -project "$PROJECT" -scheme Pickr -configuration Debug \
        -destination "id=$DEVICE" -destination-timeout 60 -derivedDataPath "$DD" \
        -allowProvisioningUpdates >"$WORK/logs/build.log" 2>&1; then
        grep -E '(error:|^\*\* )' "$WORK/logs/build.log" | sort -u | head -30 >&2 || true
        printf '    full log: %s\n' "$WORK/logs/build.log" >&2
        KEEP_WORK=1
        die "build-for-testing failed. Check: the iPhone is unlocked and trusts this Mac, Developer Mode is on, and Xcode is signed in to the team in Config/Signing.local.xcconfig."
    fi
    note "built"
}

# run_test <demo> <appearance> <log>: runs one demo test with demo mode on. Its marks go to
# the marks file.
run_test() {
    local demo="$1" appearance="$2" logfile="$3" result status=0
    result="$WORK/results/$demo-$appearance.xcresult"
    TEST_RUNNER_PICKR_DEMO=1 TEST_RUNNER_PICKR_DEMO_APPEARANCE="$appearance" \
        xcodebuild test-without-building -project "$PROJECT" -scheme Pickr -configuration Debug \
        -destination "id=$DEVICE" -destination-timeout 60 -derivedDataPath "$DD" \
        -only-testing:"PickrUITests/DemoRecordingTests/$(test_name "$demo")" \
        -resultBundlePath "$result" >"$logfile" 2>&1 &
    local pid=$! waited=0
    # On a device xcodebuild can hang after the tests finish: once the suite reports, give it
    # 15 s to exit, then stop it (the marks are already in the log).
    while kill -0 "$pid" 2>/dev/null; do
        if grep -qE "Test Suite 'Selected tests' (passed|failed)" "$logfile"; then
            waited=$((waited + 1))
            if [ "$waited" -ge 15 ]; then
                kill -TERM "$pid" 2>/dev/null || true
                break
            fi
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null || status=$?
    if grep -q "Test Suite 'Selected tests' passed" "$logfile"; then status=0; fi
    collect_marks "$demo" "$appearance" "$logfile" "$result"
    if [ "$status" -ne 0 ] || grep -q "Test Case .* skipped" "$logfile"; then
        grep -E '(error:|failed|skipped|Demo mode is not on)' "$logfile" | sort -u | head -15 | sed 's/^/    /' >&2 || true
        printf '    full log: %s\n' "$logfile" >&2
        return 1
    fi
}

MARK_RE='PICKR-DEMO-MARK (light|dark) [a-z]+ (start|end|still:[a-z-]+) [0-9]+\.[0-9]+'

# The marks come from the console output, or from the result bundle's activities.
collect_marks() {
    local demo="$1" appearance="$2" logfile="$3" result="$4" found test
    found="$(grep -oE "$MARK_RE" "$logfile" || true)"
    if [ -z "$found" ] && [ -d "$result" ]; then
        test="DemoRecordingTests/$(test_name "$demo")"
        found="$( { xcrun xcresulttool get test-results activities --path "$result" --test-id "$test()" 2>/dev/null ||
            xcrun xcresulttool get test-results activities --path "$result" --test-id "$test" 2>/dev/null || true; } |
            grep -oE "$MARK_RE" || true)"
    fi
    if [ -z "$found" ]; then
        warn "no marks from $demo ($appearance)"
        return 0
    fi
    printf '%s\n' "$found" | sed 's/^PICKR-DEMO-MARK //' | awk -v a="$appearance" -v d="$demo" '$1 == a && $2 == d' >>"$MARKS_FILE"
}

# mark_time <appearance> <demo> <event>: the mark's time, or nothing.
mark_time() {
    awk -v a="$1" -v d="$2" -v e="$3" '$1 == a && $2 == d && $3 == e { print $4; exit }' "$MARKS_FILE"
}

# ---------------------------------------------------------------------------
# Conversion

MASKS_DIR=""

# video_geometry <file>: "<width> <height> <duration>", width and height as displayed.
video_geometry() {
    local file="$1" size rotation duration width height
    size="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$file")"
    rotation="$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=rotation -of default=nw=1:nk=1 "$file" 2>/dev/null | head -1)"
    duration="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$file")"
    width="${size%x*}"
    height="${size#*x}"
    case "${rotation:-0}" in
        90 | -90 | 270 | -270) printf '%s %s %s\n' "$height" "$width" "$duration" ;;
        *) printf '%s %s %s\n' "$width" "$height" "$duration" ;;
    esac
}

# crop_filter <width> <height>: a crop to the screen's aspect ratio when the frame has bars,
# else nothing. Ends with a comma when not empty.
crop_filter() {
    awk -v w="$1" -v h="$2" -v t="$SCREEN_ASPECT" 'BEGIN {
        a = w / h
        if (a > t * 1.02) { cw = int(h * t / 2) * 2; printf "crop=%d:%d:%d:0,", cw, h, int((w - cw) / 2) }
        else if (a < t / 1.02) { ch = int(w / t / 2) * 2; printf "crop=%d:%d:0:%d,", w, ch, int((h - ch) / 2) }
    }'
}

# corner_mask <width> <height>: a grey mask with the display's rounded corners, or nothing
# when corners stay square.
corner_mask() {
    local width="$1" height="$2" radius mask
    radius="$(awk -v w="$width" -v f="$CORNER_FRACTION" 'BEGIN { printf "%d", w * f + 0.5 }')"
    [ "$radius" -gt 0 ] || return 0
    mask="$MASKS_DIR/mask-${width}x${height}-r$radius.png"
    if [ ! -s "$mask" ]; then
        ffmpeg -v error -y -f lavfi -i "color=c=black:s=${width}x${height},format=gray" \
            -vf "geq=lum='if(lte(hypot(X-min(max(X,$radius),W-1-$radius),Y-min(max(Y,$radius),H-1-$radius)),$radius),255,0)'" \
            -frames:v 1 "$mask"
    fi
    printf '%s' "$mask"
}

# make_gif <recording> <from> <duration> <crop> <out> : the GIF, trying smaller settings
# until it fits MAX_GIF_BYTES. Prints the settings used.
make_gif() {
    local recording="$1" from="$2" duration="$3" crop="$4" out="$5"
    local geometry width height out_height mask palette attempt fps dither size reserve graph
    geometry="$(video_geometry "$recording")"
    width="$(printf '%s' "$geometry" | cut -d' ' -f1)"
    height="$(printf '%s' "$geometry" | cut -d' ' -f2)"
    out_height="$(awk -v w="$width" -v h="$height" -v c="$crop" -v g="$GIF_WIDTH" -v t="$SCREEN_ASPECT" 'BEGIN {
        if (c != "") { a = (w / h > t * 1.02 || w / h < t / 1.02) ? t : w / h } else { a = w / h }
        printf "%d", int(g / a / 2 + 0.5) * 2 }')"
    mask="$(corner_mask "$GIF_WIDTH" "$out_height")"
    palette="$WORK/gif/palette.png"
    reserve=0
    [ -n "$mask" ] && reserve=1
    for attempt in "18 sierra2_4a" "15 sierra2_4a" "15 bayer:bayer_scale=4" "12 bayer:bayer_scale=3"; do
        fps="${attempt%% *}"
        dither="${attempt#* }"
        local scale="[0:v]${crop}fps=$fps,scale=$GIF_WIDTH:$out_height:flags=lanczos,format=rgba"
        if [ -n "$mask" ]; then
            graph="$scale[v];[1:v]format=gray[m];[v][m]alphamerge"
            ffmpeg -v error -y -ss "$from" -t "$duration" -i "$recording" -i "$mask" \
                -filter_complex "$graph,palettegen=max_colors=256:stats_mode=diff:reserve_transparent=$reserve" \
                -frames:v 1 -update 1 "$palette"
            ffmpeg -v error -y -ss "$from" -t "$duration" -i "$recording" -i "$mask" -i "$palette" \
                -filter_complex "$graph[a];[a][2:v]paletteuse=dither=$dither:diff_mode=rectangle:alpha_threshold=128" \
                -loop 0 "$out"
        else
            ffmpeg -v error -y -ss "$from" -t "$duration" -i "$recording" \
                -filter_complex "$scale,palettegen=max_colors=256:stats_mode=diff:reserve_transparent=0" \
                -frames:v 1 -update 1 "$palette"
            ffmpeg -v error -y -ss "$from" -t "$duration" -i "$recording" -i "$palette" \
                -filter_complex "$scale[v];[v][1:v]paletteuse=dither=$dither:diff_mode=rectangle" \
                -loop 0 "$out"
        fi
        size="$(file_size "$out")"
        if [ "$size" -le "$MAX_GIF_BYTES" ]; then
            printf '%s fps, %s, %sx%s' "$fps" "$dither" "$GIF_WIDTH" "$out_height"
            return 0
        fi
        note "$(megabytes "$size") at $fps fps with $dither; trying smaller settings"
    done
    warn "$(basename "$out") is still $(megabytes "$size") (over $(megabytes "$MAX_GIF_BYTES"))"
    printf '%s fps, %s, %sx%s, over budget' "$fps" "$dither" "$GIF_WIDTH" "$out_height"
}

# render <recording> <recording start> <appearance> <demo>: the demo's GIF and stills.
render() {
    local recording="$1" rec_start="$2" appearance="$3" demo="$4"
    local start end from to duration geometry width height total crop gif settings still name t png dest suffix
    start="$(mark_time "$appearance" "$demo" start)"
    end="$(mark_time "$appearance" "$demo" end)"
    if [ -z "$start" ] || [ -z "$end" ]; then
        warn "$demo ($appearance): no start or end mark; skipped"
        return 1
    fi
    geometry="$(video_geometry "$recording")"
    read -r width height total <<<"$geometry"
    from="$(calc "$start - $rec_start + $MARK_OFFSET + $HEAD_PAD")"
    to="$(calc "$end - $rec_start + $MARK_OFFSET")"
    duration="$(calc "$to - $from")"
    if is_less "$from" 0 || is_less "$total + 0.5" "$to" || is_less "$duration" 1; then
        warn "$demo ($appearance): the marks ($from s to $to s) fall outside the recording (0 to $total s)."
        warn "the clocks may disagree: pass --mark-offset <seconds> (or --recording-start for a Control Center recording)"
        return 1
    fi
    crop="$(crop_filter "$width" "$height")"

    suffix=""
    [ "$appearance" = light ] && suffix="-light"
    gif="$WORK/gif/$demo$suffix.gif"
    settings="$(make_gif "$recording" "$from" "$duration" "$crop" "$gif")"
    publish "$gif" "$OUT_GIFS/$demo$suffix.gif"
    note "images/demo/$demo$suffix.gif: $(megabytes "$(file_size "$gif")"), $(printf '%.1f' "$duration") s, $settings"

    for still in $(awk -v a="$appearance" -v d="$demo" '$1 == a && $2 == d && $3 ~ /^still:/ { sub(/^still:/, "", $3); print $3 }' "$MARKS_FILE" | sort -u); do
        name="$still"
        [ "$appearance" = dark ] && name="$still-dark"
        t="$(calc "$(mark_time "$appearance" "$demo" "still:$still") - $rec_start + $MARK_OFFSET + $STILL_PAD")"
        png="$WORK/gif/$name.png"
        ffmpeg -v error -y -ss "$t" -i "$recording" -frames:v 1 \
            -vf "${crop}scale=$STILL_WIDTH:-2:flags=lanczos" "$png"
        dest="$OUT_STILLS/$name.png"
        publish "$png" "$dest"
        note "images/screens/$name.png"
    done
}

# ---------------------------------------------------------------------------
# Runs

FAILED=""

record_all() {
    local appearance demo base logfile rec_start recording
    for appearance in $APPEARANCES; do
        for demo in $DEMOS; do
            log "$demo ($appearance)"
            CURRENT_APPEARANCE="$appearance"
            base="$WORK/rec/$demo-$appearance"
            logfile="$WORK/logs/test-$demo-$appearance.log"
            if ! start_recording "$base"; then
                warn "$demo ($appearance): the recording did not start"
                FAILED="$FAILED $demo-$appearance"
                continue
            fi
            if ! run_test "$demo" "$appearance" "$logfile"; then
                stop_recorder
                warn "$demo ($appearance): the test failed; no GIF"
                FAILED="$FAILED $demo-$appearance"
                continue
            fi
            stop_recorder
            recording="$(recording_file "$base")"
            rec_start="$(recording_start "$base" || true)"
            if [ -z "$recording" ] || [ -z "$rec_start" ]; then
                cat "$base.recorder.log" >&2 2>/dev/null || true
                warn "$demo ($appearance): no usable recording"
                FAILED="$FAILED $demo-$appearance"
                continue
            fi
            render "$recording" "$rec_start" "$appearance" "$demo" || FAILED="$FAILED $demo-$appearance"
        done
    done
}

run_manual() {
    local appearance demo answer
    [ -t 0 ] || die "--recorder manual asks you to start the recording: run it in a terminal"
    cat <<EOF

On the iPhone:
  1. Turn on Do Not Disturb, so no notification shows up in the recording.
  2. Set Auto-Lock to Never and keep the iPhone unlocked, on the cable.
  3. Open Control Center and start Screen Recording.
Press Return here once it is recording.
EOF
    read -r answer
    for appearance in $APPEARANCES; do
        for demo in $DEMOS; do
            log "$demo ($appearance)"
            run_test "$demo" "$appearance" "$WORK/logs/test-$demo-$appearance.log" ||
                FAILED="$FAILED $demo-$appearance"
        done
    done
    KEEP_WORK=1
    cat <<EOF

Stop the recording on the iPhone (the red status bar pill, then Stop), and move it to this
Mac with AirDrop or Image Capture. Marks file: $MARKS_FILE
EOF
    printf 'Path of the recording (or a folder; the newest movie in it is used), empty to stop: '
    read -r answer
    if [ -z "$answer" ]; then
        printf 'Later: scripts/demo-gifs.sh --from-recording <file or folder> --marks %s\n' "$MARKS_FILE"
        return 0
    fi
    FROM_RECORDING="$answer"
    cut_recording
}

# The newest movie in a folder, or the file itself. Only reads.
pick_recording() {
    local path="$1" newest
    if [ -d "$path" ]; then
        newest="$(find "$path" -maxdepth 1 -type f \( -iname '*.mov' -o -iname '*.mp4' \) -print0 |
            xargs -0 ls -t 2>/dev/null | head -1)"
        [ -n "$newest" ] || die "no .mov or .mp4 in $path"
        printf '%s' "$newest"
    else
        [ -f "$path" ] || die "no such recording: $path"
        printf '%s' "$path"
    fi
}

# The recording's start: --recording-start, else its creation date, which iOS may write at the
# start or at the end; whichever puts every mark inside the recording wins.
manual_recording_start() {
    local recording="$1" duration created first last
    duration="$(video_geometry "$recording" | cut -d' ' -f3)"
    if [ -n "$RECORDING_START" ]; then
        printf '%s' "$RECORDING_START"
        return 0
    fi
    created="$(ffprobe -v error -show_entries format_tags=com.apple.quicktime.creationdate,creation_time \
        -of default=nw=1 "$recording" 2>/dev/null | python3 -I -c '
import sys
from datetime import datetime
tags = dict(line.strip().split("=", 1) for line in sys.stdin if "=" in line)
for key in ("TAG:com.apple.quicktime.creationdate", "TAG:creation_time"):
    value = tags.get(key)
    if value:
        value = value.replace("Z", "+00:00")
        if len(value) > 5 and value[-5] in "+-" and value[-3] != ":":
            value = value[:-2] + ":" + value[-2:]
        print("%.3f" % datetime.fromisoformat(value).timestamp())
        break
')"
    [ -n "$created" ] || die "the recording has no creation date; pass --recording-start <seconds since 1970>"
    first="$(awk '{ print $4 }' "$MARKS_FILE" | sort -n | head -1)"
    last="$(awk '{ print $4 }' "$MARKS_FILE" | sort -n | tail -1)"
    if ! is_less "$first" "$created" && ! is_less "$created + $duration" "$last"; then
        printf '%s' "$created"
    elif ! is_less "$first" "$(calc "$created - $duration")" && ! is_less "$created" "$last"; then
        calc "$created - $duration"
    else
        die "the marks don't fit the recording's time ($created, $duration s); pass --recording-start <seconds since 1970>"
    fi
}

cut_recording() {
    local recording rec_start appearance demo
    [ -s "$MARKS_FILE" ] || die "no marks in ${MARKS_FILE:-(none)}"
    recording="$(pick_recording "$FROM_RECORDING")"
    log "cutting $recording"
    rec_start="$(manual_recording_start "$recording")"
    note "recording starts at $rec_start (seconds since 1970)"
    for appearance in $APPEARANCES; do
        for demo in $DEMOS; do
            if [ -z "$(mark_time "$appearance" "$demo" start)" ]; then
                continue
            fi
            log "$demo ($appearance)"
            render "$recording" "$rec_start" "$appearance" "$demo" || FAILED="$FAILED $demo-$appearance"
        done
    done
}

report() {
    local file
    log "results"
    for file in "$OUT_GIFS"/*.gif "$OUT_STILLS"/*.png; do
        [ -f "$file" ] || continue
        [ "$file" -nt "$WORK" ] || continue
        note "${file#"$ROOT"/}  $(megabytes "$(file_size "$file")")"
    done
    if [ -n "$FAILED" ]; then
        die "failed:$FAILED (logs in $WORK/logs; rerun with --only <demo>)"
    fi
}

# ---------------------------------------------------------------------------
# Main

preflight
make_work_dir
MASKS_DIR="$WORK/gif"
require_tools ffmpeg ffprobe python3 awk

if [ -n "$FROM_RECORDING" ]; then
    [ -n "$MARKS_FILE" ] || die "--from-recording needs --marks <file> (written by --recorder manual)"
    [ -s "$MARKS_FILE" ] || die "no marks in $MARKS_FILE"
    cut_recording
    report
    exit 0
fi

require_tools xcodebuild xcrun xcodegen swiftc
log "preflight passed; temporary files in $WORK"
resolve_device
require_signing
choose_recorder
if [ "$CHECK_ONLY" = 1 ]; then
    log "check passed: recorder $RECORDER"
    exit 0
fi

MARKS_FILE="$WORK/marks.txt"
: >"$MARKS_FILE"
[ "$KEEP_MOV" = 1 ] && KEEP_WORK=1
build_for_testing
if [ "$RECORDER" = manual ]; then
    run_manual
else
    record_all
fi
report
