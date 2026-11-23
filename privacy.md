# Pickr. Privacy Policy

*Last updated: November 21, 2026*

Pickr. is a photo cleanup app that operates entirely on your device. This policy explains exactly what the app does and does not do with your data.

## What Pickr. accesses

Pickr. requests access to your photo library solely to:

1. Read photo details (capture time, last-edited time, favorite status and star rating, file size, and the photo's identifier) in order to find "moments": near-duplicate photos taken seconds apart, like a burst or a few tries at the same shot. Favorite status and star rating are used only for the "Never delete favorites" setting: favorite and rated photos start as kept, and Delete All skips them.
2. Move the photos you choose to delete into the system **Recently Deleted** album, using Apple's standard PhotoKit API. iOS itself presents the final confirmation dialog before any deletion takes place, and you can get deleted photos back from there for 30 days.

Pickr. never reads the contents of photos for any purpose other than displaying thumbnails and previews inside the app.

## What Pickr. does not do

- Pickr. does **not** collect, transmit, upload, or store your photos or metadata on any server.
- Pickr. does **not** use analytics, crash reporting, tracking, advertising SDKs, or any third-party services.
- Pickr. itself makes no network requests. If your library uses iCloud Photos, iOS may download a photo from iCloud when Pickr. shows it.
- Pickr. does **not** require an account and does not ask for any personal information.
- Pickr. does **not** use face recognition, machine learning, or AI analysis.

## Data stored on your device

Pickr. keeps a small amount of data inside its own app storage on your device:

- Your settings ("Photos taken within", "Look back", sort order, Vibration, and "Never delete favorites"), stored in `UserDefaults`, Apple's standard on-device preferences storage
- Aggregate all-time stats (photos deleted, space freed up, moments done, and the date you started using Pickr.), also in `UserDefaults`
- Your **Kept** list: the identifiers of photos you chose to keep, so they don't come back for cleanup, stored in a file in the app's storage
- A cache of the photo details listed above, plus a marker from iOS that lets Pickr. ask only for what changed since, so Pickr. opens quickly without going through your whole library again. iOS may clear it at any time, and Pickr. rebuilds it when needed. If you turn off Pickr.'s access to your photos, Pickr. deletes the cache the next time it opens.
- Which in-app tips you've already seen, stored by iOS

All of this data stays on your device and is removed when you delete the app. Like other app data, your settings, stats and Kept list are included in your device's backups (iCloud Backup or a backup to your computer); the cache is not.

Pickr. is open source, so you can check every statement in this policy against [its code](https://github.com/YlitaloJuha/pickr).

## Children

Pickr. does not knowingly collect any data from anyone, including children under 13.

## Changes to this policy

If this policy ever changes, the updated version will be posted at this URL with a new "Last updated" date.

## Contact

Questions about this policy or the app? Email **54-onrush-clones@icloud.com**.
