# Security

Pickr. has access to your whole photo library and can delete photos (to Recently Deleted). Please report security problems privately.

## Reporting

- Don't open a public issue.
- Use GitHub's private vulnerability reporting for this repository ([Security → Report a vulnerability](https://github.com/YlitaloJuha/pickr/security/advisories/new)), or contact the owner, @YlitaloJuha, directly.
- Say what you found, how to reproduce it, and which version (Settings, at the bottom) and iOS version. Please don't send your own photos; the synthetic ones in `test-photos/` reproduce most things.

## Supported versions

The latest App Store release, and the latest commit on `main`. Fixes ship as a new App Store release.

## What Pickr. does to stay safe

- **Nothing leaves your device.** The app has no network code: no `URLSession`, no web views, no analytics, crash reporting, ads or third-party SDKs, and no accounts. CI fails any change that adds a network API. The only downloads are the ones iOS makes itself when Pickr. shows a photo stored in iCloud.
- **Deleting always goes through iOS.** There is exactly one call to PhotoKit's `deleteAssets` in the code (CI checks it). iOS shows its own confirmation for every delete, and deleted photos go to Recently Deleted, where you can recover them for 30 days. The app re-checks the photos at delete time and never deletes hidden photos.
- **Guards against deleting the wrong thing.** With "Never delete favorites" (on by default), favorite and rated photos start as kept and Delete All skips them. Nothing in a moment is deleted until you've marked at least one photo to keep; photos about to be deleted carry a trash badge, and the button states the count ("Delete 4 Photos"). Deleting 20 photos or more at once asks one more time.
- **Little data, all on the device.** Settings, all-time stats and the Kept list (photo identifiers) in the app's own storage, plus a disposable index cache that is deleted when photo access is turned off. [privacy.md](../privacy.md) lists all of it. Photo identifiers are redacted in system logs (`privacy: .private`).
- **Demo mode can't reach your photos.** The mode that records the README demos (`-PickrDemo YES`) exists only in Debug builds, never in the App Store build, and uses the synthetic test photos in memory. The delete code refuses to run in it and the PhotoKit classes stop the app if created in it. CI checks that it stays out of Release builds, that the delete code refuses it, and that the UI tests never touch iOS's own dialogs.
- **An accurate privacy manifest.** `PrivacyInfo.xcprivacy` declares no tracking and no collected data, and a PR that adds a required-reason API must update it.
- **A small attack surface.** No entitlements or capabilities, no URL schemes, no extensions, no App Group, no iCloud container, no third-party code.
- **No secrets in the repository.** Signing settings live in a git-ignored file, and CI scans new commits with gitleaks on every push and pull request, and the full history every week.

## What you trust

- **Photo access is broad.** With full access, iOS lets Pickr. read every photo in your library, as it would any photo app. Pickr. reads only the details listed in [privacy.md](../privacy.md). You can choose limited access instead and pick which photos Pickr. sees (**Choose Photos** in the app, or iOS Settings → Privacy & Security → Photos).
- **A delete is a delete everywhere.** With iCloud Photos, deleting a photo deletes it on all your devices, and a photo in an iCloud Shared Photo Library is deleted for everyone in it. Recently Deleted still keeps it for 30 days.
- **The App Store build.** The maintainer builds and signs the App Store version from this repository. It isn't a reproducible build: you trust that the binary matches the source, as with most apps. Builds by others, under other names or bundle IDs, aren't the official app.
