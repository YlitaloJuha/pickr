#!/usr/bin/env bash
# Verification commands for the 2.0 rebuild (blueprint §6.1), safe to run from several
# agents at once in the same checkout.
#
#   scripts/verify.sh kit        V-kit:    swift test in PickrKit
#   scripts/verify.sh app        V-app:    regenerate the project, build for iOS Simulator
#                                          (unsigned), check the bundle ID and team
#   scripts/verify.sh app-tests  build-for-testing (hosted and UI tests; runs need a runtime)
#   scripts/verify.sh policy     V-policy: scripts/policy-check.sh
#   scripts/verify.sh generate   regenerate Pickr.xcodeproj only
#   scripts/verify.sh all        policy, kit and app
#
# Environment (use your own paths when several agents verify in parallel):
#   PICKR_DD       DerivedData for app builds      (default $PICKR_SCRATCH/dd-default)
#   PICKR_SPM      SwiftPM scratch path for kit    (default $PICKR_SCRATCH/spm-default)
#   PICKR_SCRATCH  base for the defaults above
#   PICKR_STRICT=1 also fail on compiler warnings
#   PICKR_XCODEGEN_LOCK, PICKR_LOCK_STALE_SECONDS (300), PICKR_LOCK_MAX_WAIT (900)
#
# xcodegen rewrites the shared Pickr.xcodeproj, so it runs under a mkdir lock (atomic on
# every filesystem). A lock whose owner process is gone, or that is older than the stale
# timeout, is broken. Generation uses xcodegen's cache, so it only rewrites the project
# when project.yml or the file list changed.

set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Shared by every parallel run on this machine; the lock must live at one well-known path.
SHARED_SCRATCH="${TMPDIR:-/tmp}"; SHARED_SCRATCH="${SHARED_SCRATCH%/}/pickr-verify"
mkdir -p "$SHARED_SCRATCH"
SCRATCH="${PICKR_SCRATCH:-$SHARED_SCRATCH}"
DD="${PICKR_DD:-$SCRATCH/dd-default}"
SPM="${PICKR_SPM:-$SCRATCH/spm-default}"
LOCK="${PICKR_XCODEGEN_LOCK:-$SHARED_SCRATCH/xcodegen.lock}"
XCODEGEN_CACHE="$(dirname "$LOCK")/xcodegen-cache/Pickr"
STALE_AFTER="${PICKR_LOCK_STALE_SECONDS:-300}"
MAX_WAIT="${PICKR_LOCK_MAX_WAIT:-900}"
PROJECT="$ROOT/Pickr.xcodeproj"
DESTINATION='generic/platform=iOS Simulator'
EXPECTED_BUNDLE_ID='com.juha.Culler'

LOCK_HELD=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'verify.sh: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Lock

lock_age() {
    local mtime
    mtime="$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0)"
    echo $(($(date +%s) - mtime))
}

# True unless the process is known to be gone ("No such process"). A permission error
# means it exists.
pid_alive() {
    local pid="$1" err
    [ -n "$pid" ] || return 1
    err="$(kill -0 "$pid" 2>&1)" && return 0
    case "$err" in *"No such process"*) return 1 ;; esac
    return 0
}

lock_owner() { cut -d' ' -f1 "$LOCK/owner" 2>/dev/null; }

acquire_lock() {
    mkdir -p "$(dirname "$LOCK")" || die "cannot create $(dirname "$LOCK")"
    local waited=0 owner age
    until mkdir "$LOCK" 2>/dev/null; do
        owner="$(lock_owner)"
        age="$(lock_age)"
        if { [ -n "$owner" ] && ! pid_alive "$owner"; } || [ "$age" -ge "$STALE_AFTER" ]; then
            printf 'verify.sh: breaking stale xcodegen lock (owner %s, %ss old)\n' "${owner:-unknown}" "$age" >&2
            rm -rf "$LOCK"
            continue
        fi
        [ "$waited" -ge "$MAX_WAIT" ] && die "timed out after ${MAX_WAIT}s waiting for $LOCK (owner ${owner:-unknown})"
        [ $((waited % 15)) -eq 0 ] && printf 'verify.sh: waiting for xcodegen lock (owner %s)\n' "${owner:-unknown}" >&2
        sleep 1
        waited=$((waited + 1))
    done
    printf '%s %s %s\n' "$$" "$(hostname -s 2>/dev/null || echo host)" "$(date +%s)" >"$LOCK/owner"
    LOCK_HELD=1
}

release_lock() {
    if [ "$LOCK_HELD" = 1 ]; then
        # Remove it only if it is still ours (it may have been broken as stale).
        [ "$(lock_owner)" = "$$" ] && rm -rf "$LOCK"
        LOCK_HELD=0
    fi
}

trap release_lock EXIT
trap 'release_lock; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Steps

generate() {
    command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
    acquire_lock
    local args=(generate --spec "$ROOT/project.yml" --project "$ROOT" --quiet)
    # The cache skips regeneration when nothing changed; never trust it without a project.
    if [ -f "$PROJECT/project.pbxproj" ]; then
        args+=(--use-cache --cache-path "$XCODEGEN_CACHE")
    else
        rm -f "$XCODEGEN_CACHE"
    fi
    mkdir -p "$(dirname "$XCODEGEN_CACHE")"
    log "xcodegen generate (lock $LOCK)"
    if ! (cd "$ROOT" && xcodegen "${args[@]}"); then
        release_lock
        die "xcodegen failed"
    fi
    # Write the cache after a fresh generation too, so the next run can skip.
    if [ ! -f "$XCODEGEN_CACHE" ]; then
        (cd "$ROOT" && xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" --quiet \
            --use-cache --cache-path "$XCODEGEN_CACHE") >/dev/null 2>&1 || true
    fi
    release_lock
}

# Waits until no regeneration is in progress, so xcodebuild never reads a half-written project.
wait_for_generation() {
    acquire_lock
    release_lock
}

# summarize <log> <label>: prints unique warnings and errors from a build log.
summarize() {
    local logfile="$1" label="$2" warnings errors
    warnings="$(grep -E '(: warning: |^warning: )' "$logfile" | sort -u)"
    errors="$(grep -E '(: error: |^error: |^xcodebuild: error:)' "$logfile" | sort -u)"
    WARNING_COUNT=0
    [ -n "$warnings" ] && WARNING_COUNT="$(printf '%s\n' "$warnings" | wc -l | tr -d ' ')"
    if [ -n "$errors" ]; then
        printf '%s errors:\n' "$label"
        printf '%s\n' "$errors" | head -50 | sed 's/^/    /'
    fi
    if [ "$WARNING_COUNT" -gt 0 ]; then
        printf '%s warnings (%s):\n' "$label" "$WARNING_COUNT"
        printf '%s\n' "$warnings" | head -50 | sed 's/^/    /'
    else
        printf '%s warnings: 0\n' "$label"
    fi
}

strict_gate() {
    if [ "${PICKR_STRICT:-0}" = 1 ] && [ "${WARNING_COUNT:-0}" -gt 0 ]; then
        die "$1: $WARNING_COUNT warning(s) with PICKR_STRICT=1"
    fi
}

run_kit() {
    command -v swift >/dev/null 2>&1 || die "swift not found"
    mkdir -p "$SPM"
    local logfile="$SPM/verify-kit.log"
    log "swift test (scratch $SPM, log $logfile)"
    if ! swift test --package-path "$ROOT/PickrKit" --scratch-path "$SPM" >"$logfile" 2>&1; then
        tail -60 "$logfile"
        summarize "$logfile" "kit"
        die "V-kit failed"
    fi
    grep -E '(Test run with|Executed [0-9]+ tests?)' "$logfile" | sed 's/^/    /'
    summarize "$logfile" "kit"
    strict_gate "V-kit"
    log "V-kit passed"
}

# xcode_build <action> <label>
xcode_build() {
    local action="$1" label="$2" logfile attempt
    command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found"
    generate
    mkdir -p "$DD"
    logfile="$DD/verify-$label.log"
    for attempt in 1 2; do
        wait_for_generation
        log "xcodebuild $action (attempt $attempt, DerivedData $DD, log $logfile)"
        if xcodebuild "$action" -project "$PROJECT" -scheme Pickr -destination "$DESTINATION" \
            -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO >"$logfile" 2>&1; then
            grep -E '^\*\* .* (SUCCEEDED|FAILED) \*\*' "$logfile" | sed 's/^/    /'
            summarize "$logfile" "$label"
            strict_gate "$label"
            return 0
        fi
        # A project rewritten mid-load shows up as an xcodebuild-level error: retry once.
        if [ "$attempt" = 1 ] && grep -q '^xcodebuild: error:' "$logfile"; then
            log "project could not be loaded; retrying after any regeneration finishes"
            continue
        fi
        break
    done
    tail -40 "$logfile"
    summarize "$logfile" "$label"
    die "$label failed"
}

check_identity() {
    local settings bundle_id teams
    wait_for_generation
    settings="$(xcodebuild -showBuildSettings -project "$PROJECT" -target Pickr -sdk iphonesimulator 2>/dev/null)"
    bundle_id="$(printf '%s\n' "$settings" | sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER = //p' | head -1)"
    [ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ] || die "PRODUCT_BUNDLE_IDENTIFIER is '$bundle_id', expected $EXPECTED_BUNDLE_ID"
    printf '    PRODUCT_BUNDLE_IDENTIFIER = %s\n' "$bundle_id"
    printf '%s\n' "$settings" |
        sed -nE 's/^ *(MARKETING_VERSION|CURRENT_PROJECT_VERSION|IPHONEOS_DEPLOYMENT_TARGET|SWIFT_VERSION) = /    \1 = /p'
    teams="$(grep -c DEVELOPMENT_TEAM "$PROJECT/project.pbxproj" || true)"
    [ "$teams" = 0 ] || die "project.pbxproj contains DEVELOPMENT_TEAM $teams time(s)"
    printf '    DEVELOPMENT_TEAM occurrences in project.pbxproj: 0\n'
}

run_app() {
    xcode_build build app
    check_identity
    log "V-app passed"
}

run_app_tests() {
    xcode_build build-for-testing app-tests
    log "build-for-testing passed (running the tests needs an iOS simulator runtime)"
}

run_policy() {
    log "policy-check"
    "$ROOT/scripts/policy-check.sh" || die "V-policy failed"
    log "V-policy passed"
}

run_all() {
    # Separate processes, so each step's lock ownership and exit are its own.
    local failed=() self="${BASH_SOURCE[0]}"
    "$self" policy || failed+=(policy)
    "$self" kit || failed+=(kit)
    "$self" app || failed+=(app)
    if [ "${#failed[@]}" -gt 0 ]; then
        die "failed: ${failed[*]}"
    fi
    log "all green: V-policy, V-kit, V-app"
}

case "${1:-}" in
    kit) run_kit ;;
    app) run_app ;;
    app-tests) run_app_tests ;;
    policy) run_policy ;;
    generate) generate ;;
    all) run_all ;;
    *)
        sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
