#!/usr/bin/env bash
# Pickr. policy checks: the privacy promise and the code rules CI enforces.
#
#   scripts/policy-check.sh
#
# Checks 1-11 are blueprint §5.5; 12+ guard the other hard rules (iOS 27 minimum,
# no dependencies, isolation of the pure layers, Info.plist identity).
# Scans tracked and untracked files, skipping whatever .gitignore ignores.
# Exits 1 when any check fails. Check 11 only warns: a reviewer confirms it.
# Works with the bash 3.2 that ships with macOS and with GNU tools on Linux.

set -o pipefail
set -f # patterns below are matched with `case`, never expanded against the disk

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FAILURES=0
WARNINGS=0
FILES=()
SELECTED=()

# Word boundaries that work in both BSD and GNU `grep -E`.
NW='[^[:alnum:]_]'
B="(^|$NW)"
E="($NW|$)"

load_files() {
    local f
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        while IFS= read -r -d '' f; do
            [ -f "$f" ] && FILES+=("$f")
        done < <(git ls-files -z --cached --others --exclude-standard)
    else
        while IFS= read -r -d '' f; do
            FILES+=("${f#./}")
        done < <(find . -type f -not -path './.git/*' -not -path '*/.build/*' \
            -not -path '*/DerivedData/*' -not -path '*.xcodeproj/*' -not -path '*/.swiftpm/*' \
            -not -name 'Signing.local.xcconfig' -print0)
    fi
}

# select_files <include-glob>... [-- <exclude-glob>...]   → SELECTED
select_files() {
    SELECTED=()
    local includes=() excludes=() mode=include pattern f matched
    for pattern in "$@"; do
        if [ "$pattern" = "--" ]; then mode=exclude; continue; fi
        if [ "$mode" = include ]; then includes+=("$pattern"); else excludes+=("$pattern"); fi
    done
    for f in "${FILES[@]}"; do
        matched=0
        for pattern in "${includes[@]}"; do
            case "$f" in $pattern) matched=1; break ;; esac
        done
        [ "$matched" = 1 ] || continue
        for pattern in ${excludes[@]+"${excludes[@]}"}; do
            case "$f" in $pattern) matched=0; break ;; esac
        done
        [ "$matched" = 1 ] && SELECTED+=("$f")
    done
}

report_ok() { printf 'ok    [%s] %s\n' "$1" "$2"; }

report_fail() {
    printf 'FAIL  [%s] %s\n' "$1" "$2"
    printf '%s\n' "$3" | sed 's/^/        /'
    FAILURES=$((FAILURES + 1))
}

report_warn() {
    printf 'warn  [%s] %s\n' "$1" "$2"
    printf '%s\n' "$3" | sed 's/^/        /'
    WARNINGS=$((WARNINGS + 1))
}

# grep_selected <ERE> → matching lines of SELECTED files
grep_selected() {
    [ "${#SELECTED[@]}" -gt 0 ] || return 0
    grep -HnIE -e "$1" -- "${SELECTED[@]}" 2>/dev/null
}

# forbid <id> <message> <ERE>: fails when the pattern matches any SELECTED file.
forbid() {
    local hits
    hits="$(grep_selected "$3")"
    if [ -n "$hits" ]; then report_fail "$1" "$2" "$hits"; else report_ok "$1" "$2"; fi
}

load_files

SOURCES=('Pickr/*.swift' 'PickrKit/Sources/*.swift')
ALL_SWIFT=('*.swift')

# 1. No network APIs.
select_files "${SOURCES[@]}"
forbid 1 "no network APIs in app or package sources" \
    "${B}URLSession|${B}URLRequest$E|${B}NWConnection$E|${B}WKWebView$E|${B}SFSafariViewController$E|^[[:space:]]*(@[[:alnum:]_]+[[:space:]]+)*import[[:space:]]+([[:alpha:]]+[[:space:]]+)?(Network|WebKit|SafariServices)$E"

# 1b. No AI or ML frameworks (privacy promise 2).
forbid 1b "no Vision, Core ML or Foundation Models" \
    "^[[:space:]]*(@[[:alnum:]_]+[[:space:]]+)*import[[:space:]]+([[:alpha:]]+[[:space:]]+)?(Vision|CoreML|FoundationModels|CreateML)$E"

# 2. Photos and PhotosUI only in the platform adapter (and its hosted tests).
select_files 'Pickr/*.swift' 'PickrKit/*.swift' -- 'Pickr/Platform/Photos/*'
forbid 2 "import Photos/PhotosUI only in Pickr/Platform/Photos/" \
    "^[[:space:]]*(@[[:alnum:]_]+[[:space:]]+)*import[[:space:]]+([[:alpha:]]+[[:space:]]+)?Photos(UI)?$E"

# 3. Exactly one deletion call site.
select_files "${ALL_SWIFT[@]}" -- 'Pickr/Platform/Photos/Deleter.swift'
forbid 3 "deleteAssets only in Pickr/Platform/Photos/Deleter.swift" 'deleteAssets'

# 3b. Deletion is the app's only library write: no other change requests anywhere.
select_files "${SOURCES[@]}" -- 'Pickr/Platform/Photos/Deleter.swift'
forbid 3b "PhotoKit change requests only in Deleter.swift" \
    "${B}(performChanges|PHAssetChangeRequest|PHAssetCreationRequest|PHAssetCollectionChangeRequest|PHCollectionListChangeRequest)$E"

# 3c. ...and one call inside that file.
DELETER='Pickr/Platform/Photos/Deleter.swift'
if [ -f "$DELETER" ]; then
    count="$(grep -cE 'deleteAssets[[:space:]]*\(' "$DELETER")"
    if [ "$count" = 1 ]; then
        report_ok 3c "exactly one deleteAssets( call in Deleter.swift"
    else
        report_fail 3c "exactly one deleteAssets( call in Deleter.swift" "$DELETER: $count calls"
    fi
fi

# 4. No private size API, no maximum-size image requests.
select_files "${ALL_SWIFT[@]}"
forbid 4 'no private "fileSize" KVC key' '"fileSize"'
forbid 4b "no PHImageManagerMaximumSize" 'PHImageManagerMaximumSize'

# 4c. No other private-API doors (KVC, selectors) in app or package sources (App Review 2.5.1).
select_files "${SOURCES[@]}"
forbid 4c "no KVC or selector lookups in sources" \
    'value[[:space:]]*\([[:space:]]*forKey:|setValue[[:space:]]*\(|NSSelectorFromString|responds[[:space:]]*\([[:space:]]*to:'

# 5. No team ID in any tracked or untracked (non-ignored) file.
select_files '*' -- '*.example'
forbid 5 "no team ID (DEVELOPMENT_TEAM, DevelopmentTeam, teamID) outside *.example" \
    '(DEVELOPMENT_TEAM|DevelopmentTeam|teamID)["'"'"']?[[:space:]]*([:=]|</key>[[:space:]]*<string>)[[:space:]]*["'"'"']?[A-Z0-9]{10}'

# 6. No print-style logging; os.Logger only.
select_files "${SOURCES[@]}"
forbid 6 "no print/debugPrint/NSLog in sources" "${B}(print|debugPrint|NSLog)[[:space:]]*\\("

# 7. Banned glass imitations and floating-bar APIs.
select_files 'Pickr/*.swift'
forbid 7 "no presentationBackground/toolbarBackground/materials/safeAreaInset in Pickr/" \
    'presentationBackground[[:space:]]*\(|toolbarBackground|\.(ultraThin|thin|regular|thick|ultraThick)Material|UIBlurEffect|UIVisualEffectView|safeAreaInset[[:space:]]*\('

# 8. Explicit glass only in the three allowed files.
select_files 'Pickr/*.swift' -- 'Pickr/DesignSystem/ToastHost.swift' 'Pickr/Features/Review/Filmstrip.swift' \
    'Pickr/Features/Review/KeepToggle.swift'
forbid 8 "glassEffect( only in ToastHost, Filmstrip and KeepToggle" 'glassEffect[[:space:]]*\('
select_files 'Pickr/*.swift'
forbid 8b "no UIKit glass (UIGlassEffect) anywhere in Pickr/" 'UIGlass(Container)?Effect'

# 9. UserDefaults key strings only in PersistedKeys.swift (tests excepted).
KEYS_FILE='PickrKit/Sources/PickrPersistence/PersistedKeys.swift'
if [ -f "$KEYS_FILE" ]; then
    patterns="$(mktemp "${TMPDIR:-/tmp}/pickr-keys.XXXXXX")"
    grep -oE '"(settings|ignoreList|stats|hint|app)\.[A-Za-z]+"' "$KEYS_FILE" | sort -u >"$patterns"
    if [ -s "$patterns" ]; then
        select_files "${SOURCES[@]}" -- "$KEYS_FILE"
        hits=""
        [ "${#SELECTED[@]}" -gt 0 ] && hits="$(grep -HnIF -f "$patterns" -- "${SELECTED[@]}" 2>/dev/null)"
        if [ -n "$hits" ]; then
            report_fail 9 "UserDefaults key strings only in PersistedKeys.swift" "$hits"
        else
            report_ok 9 "UserDefaults key strings only in PersistedKeys.swift ($(wc -l <"$patterns" | tr -d ' ') keys)"
        fi
    else
        report_fail 9 "UserDefaults key strings only in PersistedKeys.swift" "no key strings found in $KEYS_FILE"
    fi
    rm -f "$patterns"
else
    report_fail 9 "UserDefaults key strings only in PersistedKeys.swift" "$KEYS_FILE is missing"
fi

# 9d. The legacy keys are spelled exactly as v1 wrote them. Tests read through the same
#     constants, so a typo there would pass every test and silently lose user data.
if [ -f "$KEYS_FILE" ]; then
    missing=""
    for key in settings.timeWindowSeconds settings.scanRangePreset settings.customRangeStart \
        settings.customRangeEnd settings.onboardingCompleted settings.hapticFeedbackEnabled \
        ignoreList.photoIDs stats.photosDeleted stats.mbFreed stats.clustersCleared stats.firstUseDate \
        hint.tapToKeepDismissCount hint.swipeUpKeepDismissCount hint.longPressDismissCount \
        hint.longPressThumbDismissCount hint.pendingRestoreRefresh hint.refreshDismissCount \
        hint.swipeDismissCount; do
        grep -qF "\"$key\"" "$KEYS_FILE" || missing="$missing $key"
    done
    if [ -n "$missing" ]; then
        report_fail 9d "all 18 v1 keys spelled verbatim in PersistedKeys.swift" "missing:$missing"
    else
        report_ok 9d "all 18 v1 keys spelled verbatim in PersistedKeys.swift"
    fi
fi

# 10. No Liquid tags in the pages GitHub Pages renders for the App Store.
select_files 'README.md' 'privacy.md'
forbid 10 "no {{ or {% in README.md or privacy.md" '\{\{|\{%'

# 10b. The App Store Support and Privacy URLs are served from these two root files; a
#      .nojekyll file would stop README.md rendering as the site index.
missing=""
for page in README.md privacy.md; do [ -f "$page" ] || missing="$missing $page"; done
if [ -f .nojekyll ] || [ -n "$missing" ]; then
    report_fail 10b "README.md and privacy.md at the root, no .nojekyll" "missing:${missing:- none}; .nojekyll: $([ -f .nojekyll ] && echo present || echo absent)"
else
    report_ok 10b "README.md and privacy.md at the root, no .nojekyll"
fi

# 11. Required-reason APIs need a PrivacyInfo.xcprivacy entry (warning; a reviewer confirms).
MANIFEST='Pickr/PrivacyInfo.xcprivacy'
select_files "${SOURCES[@]}"
check_reason() { # <category> <ERE>
    local hits
    hits="$(grep_selected "$2")"
    [ -n "$hits" ] || return 0
    if ! grep -q "$1" "$MANIFEST" 2>/dev/null; then
        report_warn 11 "possible required-reason API without $1 in $MANIFEST" "$hits"
    fi
}
warnings_before=$WARNINGS
check_reason NSPrivacyAccessedAPICategoryFileTimestamp \
    'creationDateKey|contentModificationDateKey|contentAccessDateKey|attributeModificationDateKey|addedToDirectoryDateKey|NSFileCreationDate|NSFileModificationDate|FileAttributeKey\.(creationDate|modificationDate)|attributesOfItem|getattrlist|[^[:alnum:]_.](f|l)?stat\('
check_reason NSPrivacyAccessedAPICategorySystemBootTime 'systemUptime|mach_absolute_time'
check_reason NSPrivacyAccessedAPICategoryDiskSpace \
    'volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|NSFileSystemFreeSize|NSFileSystemSize|statv?fs|attributesOfFileSystem'
check_reason NSPrivacyAccessedAPICategoryActiveKeyboards 'activeInputModes'
check_reason 1C8F.1 'UserDefaults[[:space:]]*\([[:space:]]*suiteName'
[ "$WARNINGS" -eq "$warnings_before" ] && report_ok 11 "no undeclared required-reason APIs found"

# 12. iOS 27.0 is the minimum: no availability checks.
select_files 'Pickr/*.swift' 'PickrKit/*.swift' 'PickrAppTests/*.swift' 'PickrUITests/*.swift'
forbid 12 "no #available / #unavailable (minimum iOS 27.0)" '#(un)?available[[:space:]]*\('

# 13. Zero third-party dependencies.
select_files 'PickrKit/Package.swift'
forbid 13 "no package dependencies in PickrKit/Package.swift" '\.package[[:space:]]*\('
select_files 'project.yml'
forbid 13b "only the local PickrKit package in project.yml" '^[[:space:]]+(url|github|from|exactVersion|branch|revision):'

# 14. project.yml never carries signing or the app bundle ID.
forbid 14 "no bundleIdPrefix or DEVELOPMENT_TEAM in project.yml" \
    '^[[:space:]]*(bundleIdPrefix|DEVELOPMENT_TEAM)[[:space:]]*:'
hits="$(grep_selected '^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*:' | grep -v 'PICKR_BUNDLE_ID')"
if [ -n "$hits" ]; then
    report_fail 14b "test bundle IDs in project.yml derive from PICKR_BUNDLE_ID" "$hits"
else
    report_ok 14b "test bundle IDs in project.yml derive from PICKR_BUNDLE_ID"
fi

# 15. Info.plist: no add-only usage string; automatic limited-access alert suppressed.
PLIST='Pickr/Info.plist'
if [ -f "$PLIST" ]; then
    if grep -q 'NSPhotoLibraryAddUsageDescription' "$PLIST"; then
        report_fail 15 "Info.plist has no NSPhotoLibraryAddUsageDescription" "$PLIST"
    else
        report_ok 15 "Info.plist has no NSPhotoLibraryAddUsageDescription"
    fi
    if grep -q 'PHPhotoLibraryPreventAutomaticLimitedAccessAlert' "$PLIST"; then
        report_ok 15b "Info.plist sets PHPhotoLibraryPreventAutomaticLimitedAccessAlert"
    else
        report_fail 15b "Info.plist sets PHPhotoLibraryPreventAutomaticLimitedAccessAlert" "$PLIST"
    fi
    hits="$(grep -nE 'CFBundleURLTypes|UIBackgroundModes|NSAppTransportSecurity|NSUserTrackingUsageDescription|NSCameraUsageDescription|NSMicrophoneUsageDescription|NSLocation|NSContactsUsageDescription' "$PLIST")"
    if [ -n "$hits" ]; then
        report_fail 15c "Info.plist adds no URL schemes, background modes, ATS or other permissions" "$hits"
    else
        report_ok 15c "Info.plist adds no URL schemes, background modes, ATS or other permissions"
    fi
else
    report_fail 15 "Info.plist present" "$PLIST is missing"
fi

# 15d. No entitlements or capabilities (blueprint §1.1).
select_files 'project.yml' '*.entitlements'
forbid 15d "no entitlements file or CODE_SIGN_ENTITLEMENTS" 'CODE_SIGN_ENTITLEMENTS|<plist'

# 16. TipKit stays in its local datastore; no other system frameworks that reach the cloud.
select_files "${SOURCES[@]}"
forbid 16 "no TipKit CloudKit sync, no CloudKit or iCloud storage" \
    "cloudKitContainer|${B}CKContainer$E|NSUbiquitousKeyValueStore|forUbiquityContainerIdentifier|ubiquityIdentityToken|^[[:space:]]*import[[:space:]]+CloudKit$E"

# 17. Window geometry from the container (resizable scenes, iPhone Duo); haptics via SwiftUI.
forbid 17 "no UIScreen.main" 'UIScreen\.main'
forbid 17b "no UIFeedbackGenerator (use sensoryFeedback)" 'UI[A-Za-z]*FeedbackGenerator'

# 17c. Layout by space, never by device (ADAPTIVE §1, §12.3): no legacy shared state, device
#      or orientation reads, no hinge APIs (iOS 27.1, unused in 2.0).
select_files 'Pickr/*.swift'
forbid 17c "no device, idiom, orientation, shared-window or hinge APIs in Pickr/" \
    'UIScreen[[:space:]]+mainScreen|userInterfaceIdiom|UI_USER_INTERFACE_IDIOM|UIDevice\.current|interfaceOrientation|statusBarOrientation|UIApplication\.shared\.(windows|keyWindow|connectedScenes)|onHingeChange|UIHingeInteraction|DeviceHinge'

# 17d. ignoresSafeArea always names its edges (a vertical system bar can hold a side edge).
forbid 17d "no bare ignoresSafeArea() in Pickr/" 'ignoresSafeArea[[:space:]]*\([[:space:]]*\)'

# 17e. The window resizes freely and there is one scene (ADAPTIVE §11, §12.2, D3).
select_files 'Pickr/*'
forbid 17e "no UIRequiresFullScreen anywhere in Pickr/" 'UIRequiresFullScreen'
if [ -f "$PLIST" ]; then
    problems=""
    if ! grep -q 'UISupportedInterfaceOrientations~ipad' "$PLIST"; then
        problems="${problems}UISupportedInterfaceOrientations~ipad is missing; "
    else
        ipad="$(sed -n '/UISupportedInterfaceOrientations~ipad/,/<\/array>/p' "$PLIST")"
        for orientation in Portrait PortraitUpsideDown LandscapeLeft LandscapeRight; do
            printf '%s\n' "$ipad" | grep -q "<string>UIInterfaceOrientation$orientation</string>" ||
                problems="${problems}iPad lacks $orientation; "
        done
    fi
    scenes="$(sed -n '/UIApplicationSupportsMultipleScenes/{n;p;}' "$PLIST")"
    case "$scenes" in *"<false/>"*) ;; *) problems="${problems}UIApplicationSupportsMultipleScenes is not false; " ;; esac
    if [ -n "$problems" ]; then
        report_fail 17f "Info.plist: all four iPad orientations, one scene" "$problems"
    else
        report_ok 17f "Info.plist: all four iPad orientations, one scene"
    fi
fi

# 18. The pure layers stay pure.
select_files 'PickrKit/Sources/*.swift'
forbid 18 "no SwiftUI in PickrKit" "^[[:space:]]*(@[[:alnum:]_]+[[:space:]]+)*import[[:space:]]+SwiftUI$E"
select_files 'PickrKit/Sources/PickrModels/*.swift'
forbid 18b "no withAnimation in models" 'withAnimation'
select_files 'PickrKit/Sources/PickrCore/*.swift'
forbid 18c "PickrCore reads no clock or current calendar" \
    "Date\\.now|Date\\(\\)|Calendar\\.(current|autoupdatingCurrent)|TimeZone\\.(current|autoupdatingCurrent)|Locale\\.(current|autoupdatingCurrent)"

# 19. Every delete goes through Curator.
select_files "${SOURCES[@]}" -- 'PickrKit/Sources/PickrModels/Curator.swift'
forbid 19 "client.delete only in Curator.swift" 'client\.delete[[:space:]]*\('

# 20. No TODO without a contract-change reference.
select_files 'Pickr/*.swift' 'PickrKit/*.swift' 'PickrAppTests/*.swift' 'PickrUITests/*.swift'
hits="$(grep_selected "${B}(TODO|FIXME)$E" | grep -v 'contract-changes')"
if [ -n "$hits" ]; then
    report_fail 20 "every TODO/FIXME cites a contract-changes note" "$hits"
else
    report_ok 20 "every TODO/FIXME cites a contract-changes note"
fi

# 21. Plain language (audit/COPY.md): none of the banned words in what people read. Checks
#     the String Catalog's keys and English values, not the translator comments.
CATALOG='Pickr/Localizable.xcstrings'
if [ -f "$CATALOG" ] && command -v python3 >/dev/null 2>&1; then
    hits="$(python3 -I - "$CATALOG" <<'PY'
import json, re, sys
banned = re.compile(r"\b(scan\w*|range\w*|restor\w*|select\w*|invert\w*|session\w*|haptic\w*|grouping\w*|cluster\w*|permanent\w*)", re.I)
def values(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "value" and isinstance(value, str):
                yield value
            else:
                yield from values(value)
    elif isinstance(node, list):
        for item in node:
            yield from values(item)
for key, entry in json.load(open(sys.argv[1]))["strings"].items():
    for text in [key, *values(entry.get("localizations", {}).get("en", {}))]:
        match = banned.search(text)
        if match:
            print(f"{match.group(0)!r} in {text!r}")
PY
)"
    if [ -n "$hits" ]; then
        report_fail 21 "no banned words (scan, range, restore, select, …) in Localizable.xcstrings" "$hits"
    else
        report_ok 21 "no banned words (scan, range, restore, select, …) in Localizable.xcstrings"
    fi
elif [ -f "$CATALOG" ]; then
    report_warn 21 "python3 not found: the plain-language check of $CATALOG was skipped" "$CATALOG"
fi

# 22. Demo mode (Pickr/App/Demo/, `-PickrDemo YES`: the README recordings) exists only in
#     Debug builds. Its files are wrapped in #if DEBUG, every mention of it elsewhere in
#     Pickr/ sits inside #if DEBUG (comment lines aside), and Release never bundles the photos.
DEMO_PATTERN='Demo(Mode|Services|PhotoLibrary|ImageLoader)|PickrDemo|refuseInDemoMode'

# outside_debug <ERE> <file>...: code lines matching the pattern that no #if DEBUG encloses.
outside_debug() {
    local pattern="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    awk -v pat="$pattern" '
        FNR == 1 { depth = 0 }
        /^[[:space:]]*#if[[:space:]]+DEBUG([[:space:]]|$)/ { depth++; debug[depth] = 1; next }
        /^[[:space:]]*#if[[:space:]]/ { depth++; debug[depth] = 0; next }
        /^[[:space:]]*#else/ { if (depth > 0) debug[depth] = 0; next }
        /^[[:space:]]*#endif/ { if (depth > 0) depth--; next }
        /^[[:space:]]*\/\// { next }
        $0 ~ pat {
            inside = 0
            for (i = 1; i <= depth; i++) if (debug[i]) inside = 1
            if (!inside) printf "%s:%d: %s\n", FILENAME, FNR, $0
        }' "$@"
}

select_files 'Pickr/App/Demo/*.swift'
hits=""
for f in ${SELECTED[@]+"${SELECTED[@]}"}; do
    first="$(grep -v '^[[:space:]]*$' "$f" | head -1)"
    last="$(grep -v '^[[:space:]]*$' "$f" | tail -1)"
    [ "$first" = "#if DEBUG" ] || hits="${hits}${f}: does not start with #if DEBUG"$'\n'
    [ "$last" = "#endif" ] || hits="${hits}${f}: does not end with #endif"$'\n'
done
if [ -n "$hits" ]; then
    report_fail 22 "files in Pickr/App/Demo/ are wrapped in #if DEBUG" "${hits%$'\n'}"
else
    report_ok 22 "files in Pickr/App/Demo/ are wrapped in #if DEBUG"
fi

select_files 'Pickr/*.swift'
hits="$(outside_debug "$DEMO_PATTERN" ${SELECTED[@]+"${SELECTED[@]}"})"
if [ -n "$hits" ]; then
    report_fail 22a "demo mode is referenced only inside #if DEBUG in Pickr/" "$hits"
else
    report_ok 22a "demo mode is referenced only inside #if DEBUG in Pickr/"
fi

# 22b. test-photos/ is bundled for demo mode in Debug only: Release excludes it.
if grep -qE '^[[:space:]]*-[[:space:]]*path:[[:space:]]*test-photos' project.yml 2>/dev/null; then
    if grep -A2 -E '^[[:space:]]+Release:[[:space:]]*$' project.yml |
        grep -qE '^[[:space:]]+EXCLUDED_SOURCE_FILE_NAMES:[[:space:]]*"?test-photos"?[[:space:]]*$'; then
        report_ok 22b "test-photos/ is bundled in Debug only (Release excludes it)"
    else
        report_fail 22b "test-photos/ is bundled in Debug only (Release excludes it)" \
            "project.yml bundles test-photos but no Release config sets EXCLUDED_SOURCE_FILE_NAMES: test-photos"
    fi
else
    report_ok 22b "test-photos/ is bundled in Debug only (not bundled at all)"
fi

# 22c. Deleter refuses demo mode before anything else, so before performChanges.
if [ -f "$DELETER" ]; then
    refuse="$(grep -nE '^[[:space:]]*try[[:space:]]+refuseInDemoMode\(DemoMode\.isActive\)' "$DELETER" | head -1 | cut -d: -f1)"
    perform="$(grep -nE '^[[:space:]]*try[[:space:]]+await[[:space:]]+[[:alnum:]_.]*performChanges' "$DELETER" | head -1 | cut -d: -f1)"
    if [ -n "$refuse" ] && [ -n "$perform" ] && [ "$refuse" -lt "$perform" ]; then
        report_ok 22c "Deleter refuses demo mode before performChanges"
    else
        report_fail 22c "Deleter refuses demo mode before performChanges" \
            "$DELETER: refuseInDemoMode at line ${refuse:-none}, performChanges at line ${perform:-none}"
    fi
fi

# 23. UI tests never touch system UI: no SpringBoard or other app, no interruption monitor,
#     so nothing can confirm an iOS "Delete photos?" dialog, even on a device.
select_files 'PickrUITests/*'
forbid 23 "PickrUITests never touch SpringBoard, other apps or interruption monitors" \
    'com\.apple\.springboard|addUIInterruptionMonitor|bundleIdentifier[[:space:]]*:'

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "policy-check: $FAILURES check(s) failed, $WARNINGS warning(s)."
    exit 1
fi
echo "policy-check: all checks passed ($WARNINGS warning(s))."
