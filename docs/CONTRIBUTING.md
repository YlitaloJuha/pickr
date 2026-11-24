# Contributing to Pickr.

Pickr. is a small photo app that groups near-duplicate photos into moments, so you tap the keepers and the rest go to Recently Deleted. It's SwiftUI on iOS 27, with no dependencies, and most of the logic lives in a Swift package that tests on a Mac. Start with the [README](../README.md), then [ARCHITECTURE.md](ARCHITECTURE.md) (how it fits together) and [PERSISTENCE.md](PERSISTENCE.md) (the stored data that upgrades depend on).

## Asking for features and reporting bugs

- **A bug:** open a [bug report](https://github.com/YlitaloJuha/pickr/issues/new?template=bug_report.yml). Say what you did, what you expected and what happened, plus your iOS version, device model, Pickr. version (Settings, at the bottom), roughly how many photos you have, and whether you use iCloud Photos and full or limited access.
- **Never attach your own photos,** or screenshots that show them. A bug report is public and stays public. Describe the photos instead ("12 photos taken a second apart"), reproduce it with the synthetic photos in `test-photos/`, or crop and blur first. Screenshots and photos can carry location and capture times.
- **A feature:** open a [feature request](https://github.com/YlitaloJuha/pickr/issues/new?template=feature_request.yml) with the problem first, then your idea. One per issue.
- **Asked already?** Add 👍 to the issue's first post instead of a new issue or a "+1" comment.
- **A security problem:** never in an issue. See [SECURITY.md](SECURITY.md).

## Setup

You need a Mac with Xcode 27.2 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
scripts/bootstrap.sh                 # once: copies the signing example, generates Pickr.xcodeproj
open Pickr.xcodeproj

cd PickrKit && swift test            # the package tests (most of the logic); no simulator needed
scripts/policy-check.sh              # the privacy and code-rule checks CI runs
```

Build the app without signing, as CI does:

```sh
xcodegen generate
xcodebuild build -project Pickr.xcodeproj -scheme Pickr \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

**Signing stays out of git.** `Config/Shared.xcconfig` is tracked and has no team. To run on your own device, set your team in `Config/Signing.local.xcconfig` (`bootstrap.sh` creates it from the `.example` with the team line commented out; git ignores it) and give your build its own bundle ID there, `PICKR_BUNDLE_ID = com.example.pickr`. Don't pick a team in Xcode's Signing & Capabilities tab: it writes the team into the project. `Pickr.xcodeproj` is generated and git-ignored; change `project.yml` instead.

**Test photos.** `test-photos/` holds 40 synthetic JPEGs in 10 moments: illustrated scenes (one per moment, each photo a slightly shifted burst frame) with a capture time and no other metadata, made by `swift scripts/make-test-photos.swift` (and checked with `--check test-photos`). Load them into a booted simulator with `xcrun simctl addmedia booted test-photos/*.jpg` (and `xcrun simctl privacy booted grant photos com.juha.Culler` for the hosted tests). At the default 1-minute window they make 7 moments.

**Demo mode.** A Debug build launched with `-PickrDemo YES` (add `-PickrDemoAppearance dark` or `light` to force one) shows the test photos without touching your photo library or settings: no PhotoKit, deletes in memory with no dialog, a fresh start every launch. It is the easy way to try a change on your own iPhone. In Xcode: Product → Scheme → Edit Scheme → Run → Arguments.

`scripts/verify.sh all` runs the policy checks, the package tests and the unsigned build in one go; `PICKR_STRICT=1 scripts/verify.sh all` also fails on compiler warnings, as reviews expect.

CI (`.github/workflows/ci.yml`) runs the policy checks, a [gitleaks](https://github.com/gitleaks/gitleaks) secret scan of the new commits, the package tests, an unsigned app build and (advisory for now) the hosted and UI tests on iPhone, iPad and iPhone Duo simulators (a failed test gets one retry, since the hosted simulators are sometimes slow), for every push to `main` and every pull request. A weekly run scans the full history for secrets.

## Code rules

The README's privacy promise and the App Store's "Data Not Collected" label depend on these. `scripts/policy-check.sh` checks most of them; reviewers check the rest.

- **No network, no analytics.** No `URLSession`, `Network`, `WKWebView`, analytics, crash reporting, ads, accounts or third-party SDKs, and no new dependencies. Links (the privacy policy, this repo, the Settings app) open other apps. The only downloads are the ones iOS makes itself when Pickr. shows a photo stored in iCloud.
- **No AI or ML.** No Vision, Core ML or Foundation Models. Grouping uses capture time; protection uses favorites and ratings.
- **One deletion site.** `PHAssetChangeRequest.deleteAssets` appears only in `Pickr/Platform/Photos/Deleter.swift`, and every delete reaches it through `Curator` and `PhotoLibraryClient.delete`. That keeps iOS's own confirmation dialog and Recently Deleted on every path. Keep the safety rails: protected favorites, the re-fetch at delete time, the extra dialog at 20 photos, silent cancel, a visible error on failure.
- **PhotoKit stays in one folder.** Only `Pickr/Platform/Photos/` imports `Photos` or `PhotosUI`. Everything else uses `PhotoLibraryClient`, which the tests fake.
- **Stable keys.** `UserDefaults` keys are never renamed, retyped or reinterpreted, and they appear only in `PersistedKeys.swift`. Pickr. 1.0 users upgrade with their settings, stats and Kept photos intact; [PERSISTENCE.md](PERSISTENCE.md) is the contract. A new key gets a row there in the same PR.
- **The privacy manifest rule.** A PR that starts using a required-reason API (file timestamps, free disk space, system boot time, active keyboards, or `UserDefaults` shared through an App Group) updates `Pickr/PrivacyInfo.xcprivacy` in the same PR. If what Pickr. stores or reads changes, [privacy.md](../privacy.md) changes in the same PR too.
- **Private logging.** `os.Logger`, for errors only. Photo identifiers, and anything else from the library, are interpolated with `privacy: .private`, never `.public`. No `print`.
- **Liquid Glass, system first.** Explicit `glassEffect` only in `ToastHost.swift`, `Filmstrip.swift` and `KeepToggle.swift`. No `presentationBackground`, `toolbarBackground`, `.ultraThinMaterial` or `safeAreaInset` for floating bars.
- **Ambient backgrounds stay pre-blurred.** The blurred photos behind lists and Review are 64 px backdrops blurred once with Core Image. Never a live SwiftUI `.blur` on them and never `backgroundExtensionEffect()`: on iOS 27 devices both turned the background black. Details in [Ambient backgrounds](ARCHITECTURE.md#ambient-backgrounds).
- **Demo mode stays out of Release.** Everything in `Pickr/App/Demo/`, and every mention of it, is inside `#if DEBUG`; `Deleter` refuses demo mode; UI tests never touch system UI such as the iOS delete dialog. `policy-check.sh` checks all three.
- **iOS 27 and up,** so no `#available` checks.
- **Layout by space, never by device.** One adaptive layout runs on iPhone, the iPhone Duo and iPad: decide with the size class and the view's own width (`onGeometryChange`), never `userInterfaceIdiom`, `UIScreen.main`, `UIDevice.current`, orientation or posture. A change to a screen is checked as a narrow stack and, where it applies, as a split (see [Adaptive layout](ARCHITECTURE.md#adaptive-layout)). User-facing text says "your device" and doesn't promise iPad until a release ships with it.
- **Logic goes in `PickrKit`,** with Swift Testing tests that run under `swift test`. Views stay thin. A bug fix starts with a test that reproduces it.
- **Plain words.** Name the outcome, not the mechanism: **Keep All**, **Show Again**, **Adjust**, **Photos taken within**, **Look back**, **Vibration**. The app never says "scan", "range", "restore", "select", "invert", "session", "haptics" or "grouping", and never "permanently" (photos go to Recently Deleted). The full list is under [Words](ARCHITECTURE.md#words). Code names stay as they are.
- Every control has an accessibility label, every gesture has a visible alternative, and user-facing text is a localizable string literal.
- Keep comments to short notes on why.

## Docs

When behaviour changes, update the README and the docs here in the same PR: [ARCHITECTURE.md](ARCHITECTURE.md) for structure and behaviour, [PERSISTENCE.md](PERSISTENCE.md) for anything stored, [privacy.md](../privacy.md) for anything that touches data. The README and `privacy.md` are also the App Store's support and privacy pages (served by GitHub Pages), so keep them free of Liquid template tags (`policy-check.sh` rejects them; a broken Pages build would freeze the live privacy policy). README pictures use the synthetic test photos only: `scripts/demo-gifs.sh` records them in demo mode ([RELEASING.md](RELEASING.md#readme-demos)).

## Licence

Pickr. is under the [MIT licence](../LICENSE). What you contribute is under the same licence. There's no contributor agreement to sign. The Pickr. name, app icon, screenshots and the artwork in `images/` aren't covered by the licence: a fork that ships to the App Store needs its own name, icon and bundle ID. [NOTICE](../NOTICE) has the details, including Apple's trademarks.

## Releases

See [RELEASING.md](RELEASING.md). The App Store build is made by the maintainer from this repository.
