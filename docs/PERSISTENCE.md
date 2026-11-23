# Persistence: the contract contributors must not break

Pickr. 2.0 updates an app that people already have. Pickr. 1.0 stored settings, stats and every photo a user had already triaged in `UserDefaults`, and 2.0 must read all of it exactly as 1.0 wrote it. Get a key name or a type wrong and the app quietly forgets a user's settings or, worse, brings back thousands of photos they already dealt with.

So everything on this page is a contract. A pull request that changes a key, a type, a default or a migration rule must say so in its description, update this page and the tests in the same PR, and keep upgrades from 1.0 working.

## Rules

- **The bundle ID stays `com.juha.Culler`.** The App Store record, the app container and the `UserDefaults` domain are keyed by it. It is set once, as `PICKR_BUNDLE_ID` in `Config/Shared.xcconfig`. Forks override it locally (see [CONTRIBUTING.md](CONTRIBUTING.md#setup)); the official build never changes it.
- **Key strings live in exactly one file:** `PickrKit/Sources/PickrPersistence/PersistedKeys.swift`. Tests may repeat them; nothing else may. `scripts/policy-check.sh` enforces this.
- **Never rename, retype or reinterpret a key.** Add a new key instead, and migrate once.
- **Values are plain plist types.** Nothing is JSON-encoded inside `UserDefaults`.
- **Read with `object(forKey:)` and a cast,** so "absent" and "false/0" stay different. Never `@AppStorage` for these keys.
- **Defaults stay absent.** `SettingsRepository.save(s)` writes a key only when its value would read back differently, so `save(load())` writes nothing and `load()` after `save(s)` returns `s`.
- **`ignoreList.photoIDs` is read-only for all of 2.x.** Not written, not removed. Its fate is decided at 3.0.
- **`PickrPersistenceTests` hold the contract.** The fixture store contains every 1.0 key with its exact type. A change here starts with a failing test there.

## Legacy keys (written by 1.0, present on users' devices)

Domain: `UserDefaults.standard` of `com.juha.Culler`.

| Key (exact) | Type | 2.0 read | 2.0 write | Notes |
|---|---|---|---|---|
| `settings.timeWindowSeconds` | Int (seconds) | `object(forKey:) as? Int`. Absent means 60. **Clamp to 10…7200.** | Yes (live key) | Never reinterpret as minutes. |
| `settings.scanRangePreset` | String: `d7` `d14` `d30` `all` `custom` | Unknown or absent means `d30`. `custom` without both dates **scans as d30** and the UI shows "Look back: Month". | Yes (live key). Write `custom` **only after dates are applied** (Pick Dates). A v1 `custom` stored without dates is rewritten as `d30` on the first save. | Enum raw values are frozen. Shown as Week · 2 Weeks · Month · Everything · Pick Dates… |
| `settings.customRangeStart` / `settings.customRangeEnd` | Date (NSDate) | `object(forKey:) as? Date`. **Swap if start > end.** Use plain `UserDefaults`, never `@AppStorage`. | Yes: start at 00:00:00 local on the **First day**, end at 23:59:59 local on the **Last day**. The repository stores them as given; callers do the rounding. | Dates are written **before** `custom` and removed **after** it, so `custom` is never stored without both, even if the app stops mid-save. A range with `custom == nil` removes both dates: to keep offering the last range, change only `range.preset`. |
| `settings.onboardingCompleted` | Bool | `true` marks an existing user, who skips onboarding and sees What's New once. | Yes: set after the access step | |
| `settings.hapticFeedbackEnabled` | Bool | **Absent means `true`** (`object == nil ? true : bool`). | Yes | Shown as **Vibration**. Reading with `bool(forKey:)` alone would silently turn it off for most users. |
| **`ignoreList.photoIDs`** | **[String]** (`localIdentifier`s) | **Once**, during migration, as `object(forKey:) as? [String]`. **Not** `ignoreList.ids` and **not** JSON: an early spec named it wrongly. | **Never.** It stays in place, read-only, through all of 2.x. Deletion is decided at 3.0. | Highest-value data. Reading it wrong resurfaces every photo a user has already triaged. |
| `stats.photosDeleted` | Int | Default 0 | Yes (live) | Counts **confirmed** deletions in 2.0. |
| `stats.mbFreed` | Double, **MiB** | Once, during migration, converted to bytes as `round(mbFreed × 1_048_576)` | Never | Left in place. |
| `stats.clustersCleared` | Int | Default 0 | Yes (live) | +1 per successful deletion inside a moment. **Keep All does not count.** Shown as "Moments done". |
| `stats.firstUseDate` | Date | If absent, write now. Its presence marks a 1.0 user. | Write-once | Upgrade detection must read it **before** anything writes it (see [Launch order](#launch-order-and-migration)). |
| `hint.tapToKeepDismissCount` | Int | `>= 1` marks `TapToKeepTip` as already seen | Never | |
| `hint.swipeUpKeepDismissCount` | Int | `>= 1` marks `SwipeUpKeepTip` as already seen | Never | |
| `hint.longPressDismissCount`, `hint.longPressThumbDismissCount` | Int | Ignored. The gestures they taught are gone. | Never | |
| `hint.pendingRestoreRefresh`, `hint.refreshDismissCount`, `hint.swipeDismissCount` | Bool / Int | Ignored | Never (not deleted) | Written by early TestFlight builds only. |

## New 2.0 keys

| Key | Type | Default when absent | Meaning |
|---|---|---|---|
| `settings.timeWindowIsCustom` | Bool | `!{10,30,60,180}.contains(seconds)` | Whether "Photos taken within" is an Other… value, so an Other… of 1 or 3 minutes doesn't collapse into the preset. Migration writes it once. |
| `settings.momentOrder` | String `newest` / `mostSpace` | `newest` | **Sort**: Newest First / Biggest First |
| `settings.protectFavorites` | Bool | `true` | **Never delete favorites**: favorite and rated photos start as kept, and Delete All skips them |
| `stats.bytesFreed` | Int64 | from migration; until then read as `stats.mbFreed` converted (`round(MiB × 1_048_576)`); otherwise 0 | Lifetime freed bytes, shown as "Space freed up". The first `record` writes it and the migration then skips step 4, so the v1 total is converted exactly once on every path. Negative inputs count as 0; totals stop at `.max`. Displayed in decimal units (`ByteCountFormatStyle(style: .file)`, as iOS Settings → Storage does). |
| `app.schemaVersion` | Int | absent means 1.0 or a fresh install | Set to `2` as the **last** step of a successful migration |
| `app.whatsNewSeen` | String | absent | The version whose What's New sheet was shown (`"2.0"`) |

TipKit keeps its own on-device datastore (the default location; **no CloudKit**).

## Where data lives

| Data | Location | Format | Backed up |
|---|---|---|---|
| Settings and stats | `UserDefaults.standard` (the keys above) | plist primitives | yes |
| Kept | `Application Support/Pickr/kept.json` | `KeptFile` JSON (`.iso8601` dates), written with `Data.write(options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])` | yes |
| Index cache | `Library/Caches/Pickr/index.v1.plist` | columnar binary plist (below), written atomically with `.completeFileProtectionUntilFirstUserAuthentication` | no (disposable) |
| Tips | TipKit default datastore | system | yes |

SwiftData isn't used. The app needs no relationships or queries that can't be done in memory.

Demo mode (`-PickrDemo YES`, Debug builds only) never reads or writes any of these: its settings and stats live in an in-memory store, its `kept.json` and TipKit datastore in a new folder in the app's temporary directory at every launch, and it has no index cache.

**`kept.json`** (`KeptFile`, `version = 1`):

```json
{
  "version": 1,
  "items":   [ { "id": "<localIdentifier>", "kind": "keptAside", "since": "2026-11-21T10:00:00Z" } ],
  "orphans": [ ]
}
```

- `kind` is `keptAside` (the user chose **Keep All**; shown under "Moments you kept"), `reviewed` (the keepers of a partial delete, so they never come back as leftovers; shown under "Photos you picked") or `legacy` (imported from `ignoreList.photoIDs`; `since` is absent; shown under "Moments you kept").
- `cloudID` (optional) holds an iCloud Photos identifier so Kept can survive a move to a new device. It is only written once that feature ships.
- `orphans` holds items whose photo is confirmed gone. They are kept for one release and discarded in 2.1.

Reading and writing `kept.json`:

- **Encoding:** `.sortedKeys`, `.withoutEscapingSlashes`, `.iso8601` dates, so `since` keeps **whole seconds** (sub-second precision comes back truncated).
- **Tolerant decoding:** a missing `version` reads as 1 and a missing `orphans` as `[]`. Duplicate IDs collapse to the first entry, in `items` and in `orphans`. A missing file loads as an empty `KeptFile`.
- **A newer `version`** throws `KeptStoreError.unsupportedVersion` and leaves the file untouched. The migration stops (the schema version stays unset), and `KeptModel` keeps changes in memory instead of overwriting the file.
- **An unreadable file** (invalid JSON, an unknown `kind`, a bad date, no `items`) is renamed to `kept.unreadable-<UUID>.json` in the same folder, then `KeptStoreError.unreadable(preservedAt:)` is thrown. The next load starts empty instead of failing at every launch, a later save can't overwrite the damaged copy, and the migration re-imports the intact v1 list.
- **Any other error** (a read before the first unlock, a folder where the file should be) is rethrown and never moves the file; `KeptModel` then doesn't save over it.
- **Saves** go through one writer task in `KeptModel`, so they land in order and a burst of changes costs one write.

Changing this format means bumping `version` and reading every earlier version.

**The index cache** (`IndexCache`, in the app target) lets the Moments list appear at launch without a spinner and lets the next refresh ask PhotoKit only for what changed. It is a binary plist of columns, so 50,000 records load inside the launch budget:

| Key | Holds |
|---|---|
| `version` | `1` |
| `scope` | `full` or `limited`: the access level the index was built under |
| `ids` | photo identifiers, ascending by `(created, id)` |
| `created`, `modified` | little-endian `Double` columns (`timeIntervalSinceReferenceDate`; NaN = no modification date) |
| `flags` | one byte per photo: bit 0 favorite, bits 1–3 rating 0…5 |
| `sizeIDs`, `sizeBytes`, `sizeModified` | known sizes and the modification date each was measured at |
| `token` | the `PHPersistentChangeToken`, archived with `NSKeyedArchiver` (secure coding) |

- It is disposable: a missing, unreadable or other-version file means a full build, and iOS may purge it at any time. An out-of-order file is re-sorted rather than trusted.
- A cache built under another access level is deleted, never reused: a limited library and the whole library hold different photos.
- When the app starts indexing and photo access is **denied**, the cache is deleted, so no photo identifiers stay on disk.
- It is written about 1 s after the index or sizes change, off the main actor.
- To change the layout, bump `formatVersion` and the file name (`index.v2.plist`) rather than reading an old layout.

## Launch order and migration

`AppServices.launch()` runs these steps, in this order:

1. `wasUpgrade = MigrationV1.isUpgrade(defaults)`, evaluated **before** step 3 writes `stats.firstUseDate`. It is true only if `app.schemaVersion < 2` **and** (`settings.onboardingCompleted == true` or `stats.firstUseDate` exists). So it is true on an upgrader's first 2.0 launch, and again only while a failed Kept save keeps the migration unfinished. It is **never** true for a fresh install, which therefore never sees What's New. `MigrationV1.Report.wasUpgrade` uses the same value. Accepted consequence: an upgrader who quits on that first launch before What's New appears won't see it later; avoiding that would need another key. `AppServices.init` only reads, so `PickrApp` can evaluate `isUpgrade` before `launch()` too (for tips, step 6).
2. `MigrationV1.run(...)`, only if `app.schemaVersion < 2`:
   1. Read `ignoreList.photoIDs` through `MigrationV1.legacyKeptIDs(in:)`: `object(forKey:) as? [String]`, stored order kept, duplicates and empty strings dropped. Any other type gives `[]` without crashing. Nothing else reads the key.
   2. Load `kept.json` if it exists. A crashed earlier run may have left one.
   3. Merge: existing items win; new IDs become `KeptItem(kind: .legacy, since: nil)`. Save atomically. **If the save fails, stop.** Leave `schemaVersion` unset; `KeptModel` falls back to an in-memory set from `legacyKeptIDs(in:)`, and the migration retries at the next launch.
   4. If `stats.bytesFreed` is absent, write `Int64((mbFreed × 1_048_576).rounded())`.
   5. If `settings.timeWindowIsCustom` is absent, write `!{10,30,60,180}.contains(clamped seconds)`.
   6. Set `app.schemaVersion = 2`, **last**.
   - Fresh installs skip steps 1 to 5 and only set `schemaVersion = 2`.
   - **`ignoreList.photoIDs` is never written or removed in 2.x.**
3. Load the settings and stats repositories (`SettingsModel.applyLaunchState`). `StatsRepository.load` writes `firstUseDate` if it is absent. `showsWhatsNew = wasUpgrade && whatsNewSeen != "2.0"` (`SettingsModel.whatsNewVersion`).
4. `KeptModel` loads `kept.json`, or the legacy list from memory if the migration didn't finish.
5. `library.start()`. It returns once indexing has started; the index arrives over time.
6. After `launch()`, the app maps the v1 tip state once: `LegacyTips.seen` invalidates `TapToKeepTip` and `SwipeUpKeepTip` if their v1 counters are `>= 1`, and upgraders also get `SwipeMomentTip` invalidated. A TipKit parameter records that this ran, so it never runs twice.

The migration is **idempotent**: running it twice, or after a partial earlier run (`kept.json` present, no `schemaVersion`), gives the same result.

## Kept pruning

- **When:** after each complete library snapshot, and only if photo access is **full**. Never while access is limited, because a limited library hides photos that still exist.
- **What:** candidates are kept IDs missing from the index. They are checked with `existingIDs(among:)`, which **includes hidden photos**. Only items confirmed gone move to `orphans`. A deletion reported by the persistent change history prunes directly.
- **Orphans** are discarded in 2.1.

## Things the tests pin down

From `PickrPersistenceTests`; keep them passing:

- Absent keys give the defaults, and an absent `settings.hapticFeedbackEnabled` means `true`.
- `ignoreList.photoIDs` as `[String]` imports as `legacy` items. As `Data` it is ignored. `ignoreList.ids` is ignored.
- Inverted custom-range dates are swapped.
- A stored window of 45 becomes custom; 99,999 becomes 7,200.
- `mbFreed` 1.5 becomes exactly 1,572,864 bytes.
- `isUpgrade` follows the v1 marks and is false once the migration is done; a fresh install only gets the schema version.
- Two migration runs give the same result, and a partial earlier run merges correctly. The schema version is written last.
- A failed `kept.json` save leaves `schemaVersion` unset. The atomic write round-trips. An unreadable file is preserved and the next load starts empty; a newer file is left untouched.
- Saving what was loaded writes nothing, and defaults stay absent.
- The v1 `mbFreed` total is converted only once, and totals stop at their maximum.
- `scanRangePreset` is never written as `custom` without dates.
