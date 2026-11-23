# Releasing

How a version of Pickr. gets to the App Store. Only the maintainer ships the official app; this page is generic on purpose, so it holds no team ID, Apple ID or App Store Connect details. Keep those out of the repository: signing comes from the git-ignored `Config/Signing.local.xcconfig`.

## Before you start

- `main` is green in CI: `policy`, `secrets`, `kit` and `app`, and the advisory `sim` jobs (hosted and UI tests on iPhone 17, iPad Pro 11-inch (M5) and iPhone Duo) have been looked at.
- The manual device pass in [ARCHITECTURE.md](ARCHITECTURE.md#testing) is done, and the performance results are recorded there.
- If the release changes what Pickr. stores or reads: `privacy.md` is updated with a new "Last updated" date, `PrivacyInfo.xcprivacy` matches the code, and the App Store privacy label still says what the app does ("Data Not Collected").
- If the release touches anything in [PERSISTENCE.md](PERSISTENCE.md): an upgrade was tested on a device running the previous App Store version with real data.
- **The first release with iPad** (`TARGETED_DEVICE_FAMILY` "1,2"): the layout checks in [ARCHITECTURE.md](ARCHITECTURE.md#testing) passed on all three iPad sizes. This is **permanent**: once a build with iPad is live, every later version must support iPad too, and App Store Connect rejects an upload that drops it. Add iPad 13" screenshots (2064 × 2752, made from `test-photos/` in the `iPad Pro 13-inch (M5)` simulator), check the App Store availability for Apple silicon Macs and Vision Pro on purpose, and only then let user-facing text mention iPad.

## 1. Set the version

In `project.yml`:

- `MARKETING_VERSION`: the user-facing version, for example `2.1`.
- `CURRENT_PROJECT_VERSION`: the build number. It must be higher than every build already uploaded for this app in App Store Connect, including TestFlight builds.

Then regenerate the project with `xcodegen generate`.

## 2. Check the privacy policy is live

The App Store links to the privacy policy and support page served by GitHub Pages from `main`. After merging, both must return 200:

```sh
curl -sI https://ylitalojuha.github.io/pickr/ | head -1
curl -sI https://ylitalojuha.github.io/pickr/privacy | head -1
```

An updated policy goes live **before** the release that needs it.

## 3. Archive and upload

With your team in `Config/Signing.local.xcconfig` and automatic signing:

1. Xcode → select the **Pickr** scheme and **Any iOS Device**.
2. **Product → Archive** (the scheme archives the Release configuration).
3. In the Organizer, **Validate App**, then **Distribute App → App Store Connect → Upload**.

From the command line instead:

```sh
xcodebuild archive -project Pickr.xcodeproj -scheme Pickr -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Pickr.xcarchive
xcodebuild -exportArchive -archivePath build/Pickr.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
```

`ExportOptions.plist` holds your team and upload method; it is git-ignored and stays on your Mac. Never commit certificates, provisioning profiles, `.p8` keys or App Store Connect key IDs. If uploads are ever automated in CI, those go into GitHub encrypted secrets only.

## 4. TestFlight, then review

1. Wait for the build to finish processing in App Store Connect, then test it through TestFlight on a real device: first launch, an upgrade over the previous version, the core loop, and cancelling the delete dialog.
2. Fill in "What's New" and check the screenshots still match the app (re-record them as in [README demos](#readme-demos) if the screens changed).
3. Submit for review.

## 5. After release

- Tag the commit the build came from: `git tag -a v2.1-build120 -m "Pickr. 2.1 (120)"` and push the tag.
- Check the support and privacy URLs again.
- Close the issues the release fixed.

## README demos

**Simulator (preferred):** `scripts/sim-capture.sh` builds for testing, boots an iPhone 17 Pro simulator with a 9:41 status bar, runs `DemoRecordingTests` in demo mode in dark and light, records each with `simctl io recordVideo`, and writes the hero animation (`images/demo/hero.webp`, `hero-light.webp`) and the screenshots (`images/screens/`, framed into `images/screens/framed/`). Needs an iOS 27 simulator runtime, ffmpeg and `img2webp` (`brew install webp`). Nothing outside the simulator is touched.

**Device:** the rest of this section records on a USB iPhone instead.

The README's GIFs and screenshots come from a real iPhone running a Debug build in **demo mode** (`-PickrDemo YES`): the 40 synthetic photos of `test-photos/`, no PhotoKit, nothing on the iPhone changed ([ARCHITECTURE.md](ARCHITECTURE.md#demo-mode-debug-builds-only)). Never use your own photos.

1. You need Xcode 27.2, `xcodegen`, `ffmpeg` and `python3`, your team in `Config/Signing.local.xcconfig`, and the iPhone on a USB cable, unlocked and trusted, with Developer Mode on. Turn on Do Not Disturb and set Auto-Lock to Never.
2. `scripts/demo-gifs.sh --check` checks the tools, the iPhone and screen capture without building. The screen is recorded over USB as QuickTime does (`scripts/enable-ios-screen-capture.swift`), which needs **Camera** access for your terminal app (System Settings → Privacy & Security → Camera); only the iPhone's screen is ever opened, never a camera.
3. `scripts/demo-gifs.sh` builds, runs `DemoRecordingTests` (hero, review, swipe, adjust, kept) once per appearance while recording, and cuts each recording at the marks the tests log. It writes `images/demo/<demo>.gif` (dark) and `<demo>-light.gif`, and the stills `images/screens/<name>.png` (light) and `<name>-dark.png`. `--only <demo>` and `--appearance light|dark` narrow it down.
4. If the screen can't be captured, `--recorder manual` runs the demos while you record with Control Center's Screen Recording; then `--from-recording <file> --marks <file>` cuts that file.
5. `swift scripts/frame-screens.swift` puts the stills into iPhone frames in `images/screens/framed/`.

The script writes only to its own temporary folder and those two image folders, and refuses to run if it contains a command that could delete anything.
