#!/usr/bin/env bash
# One-time setup for a fresh checkout:
#   1. creates the git-ignored Config/Signing.local.xcconfig from the .example
#   2. generates Pickr.xcodeproj with XcodeGen
#
#   scripts/bootstrap.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOCAL=Config/Signing.local.xcconfig
if [ ! -f "$LOCAL" ]; then
    # The placeholder team stays commented out until you replace it, so simulator
    # builds work straight away.
    sed 's|^DEVELOPMENT_TEAM = YOUR_TEAM_ID|// DEVELOPMENT_TEAM = YOUR_TEAM_ID|' Config/Signing.local.xcconfig.example >"$LOCAL"
    echo "Created $LOCAL (git-ignored). Set your DEVELOPMENT_TEAM there to run on a device."
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen is not installed. Install it with: brew install xcodegen" >&2
    exit 1
fi

xcodegen generate --spec project.yml
echo "Done. Open Pickr.xcodeproj, or build from the command line:"
echo "  xcodebuild build -project Pickr.xcodeproj -scheme Pickr -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO"
