# Architecture

How Pickr. 2.0 is put together, and the rules that keep it that way. Read this before a change that crosses a layer. The persisted data is a separate contract: [PERSISTENCE.md](PERSISTENCE.md).

Words in quotes or bold are what people see in the app. Code names differ in places (the **Adjust** sheet is `GroupingSheet`, **Keep All** is `Curator.keepAside`, **Show Again** is `Curator.restore`, **Vibration** is `hapticsEnabled`); see [Words](#words) for the list.

## In one paragraph

Pickr. groups photos taken close together in time into **moments**. The user taps the photos to keep, and the rest go to Recently Deleted through one PhotoKit request, behind iOS's own confirmation dialog. One adaptive layout serves iPhone, the iPhone Duo and iPad, iOS 27 or later, with no network code, no ML and no dependencies. iPad support is built in; it ships in 2.0 only if the layout checks pass on all three iPad sizes, because it is permanent for the App Store record once live. Almost all logic lives in a local Swift package, `PickrKit`, that builds and tests on a Mac with `swift test`. The app target holds only the SwiftUI views, the PhotoKit adapter and the composition root.

## Layout

```
pickr/
├── project.yml                 XcodeGen spec (target "Pickr"); no team, no bundle ID
├── Config/Shared.xcconfig      PICKR_BUNDLE_ID; includes the git-ignored Signing.local.xcconfig
├── PickrKit/                   local Swift package
│   ├── Sources/PickrCore/          Foundation only. Sendable values and pure algorithms
│   │   └── Contracts/              PhotoID, AssetRecord, Moment, grouping types, PhotoLibraryClient
│   ├── Sources/PickrPersistence/   Foundation only. UserDefaults keys, settings, stats, Kept file, migration
│   ├── Sources/PickrModels/        Observation + Foundation, MainActor. App state; no SwiftUI import
│   ├── Sources/PickrTestSupport/   FakePhotoLibrary, the test-photos timeline fixture
│   └── Tests/                      PickrCoreTests, PickrPersistenceTests, PickrModelsTests (Swift Testing)
├── Pickr/                      the app target (MainActor by default)
│   ├── App/                    PickrApp, LiveServices (composition root), PickrCommands (keyboard menus)
│   │   └── Demo/               demo mode, Debug builds only (DemoMode, DemoPhotoLibrary, DemoImageLoader)
│   ├── Platform/Photos/        the ONLY code that imports Photos or PhotosUI (indexer, cache, queries, sizes, images, delete)
│   ├── DesignSystem/           cards, tiles, grid, toasts, haptics, image loading, PhotoPager (UIKit),
│   │                           Theme (+ Motion), ColumnLayout (stack or split), AmbientColor +
│   │                           AmbientPalette + AmbientStripLayout (backgrounds), ScrollFocus +
│   │                           FocusLine (most visible item), DragSelect
│   └── Features/               Root, Moments (+ MomentsColumns, ReviewStartView), Review,
│                               Kept (+ KeptColumns), Grouping, Settings, Tips
├── PickrAppTests/              hosted smoke tests (need a simulator runtime)
├── PickrUITests/               first run and the core loop, with test-photos; the README demo recordings
├── test-photos/                40 synthetic illustrated JPEGs (scripts/make-test-photos.swift)
├── NOTICE                      what the MIT licence doesn't cover; trademarks; no dependencies
└── scripts/                    bootstrap.sh, verify.sh, policy-check.sh, make-test-photos.swift,
                                demo-gifs.sh (+ enable-ios-screen-capture.swift), frame-screens.swift
```

The models live in the package, not the app, so the state machine (access states, refresh, review flow, deletion) runs under `swift test` against a fake photo library, with no simulator.

**Dependency direction:** `PickrCore` ← `PickrPersistence` ← `PickrModels` ← app. Core knows nothing about storage; models know nothing about PhotoKit or SwiftUI. The app talks to PhotoKit only through `PhotoLibraryClient`, which `Platform/Photos/LivePhotoLibrary` implements and `PickrTestSupport/FakePhotoLibrary` fakes.

## Navigation

```
RootView
├─ OnboardingView                 new users only: Welcome → access primer → system prompt
└─ TabView (.tabBarOnly: bottom tab bar when compact, top tab bar when regular)
   ├─ Moments  MomentsColumns  → ColumnLayout from its own width
   │    stack:  NavigationStack
   │              MomentsScreen  → toolbar: Adjust (sheet), Sort menu, Settings sheet
   │              └─ ReviewScreen (pushed, zoom transition, tab bar hidden; All | One by One)
   │            bottom accessory (on both tabs, nothing pushed): "Clean Up 7 Moments" / "Frees up to 32 MB"
   │    split:  NavigationSplitView (.balanced)
   │              sidebar: MomentsScreen (300–420 pt, highlights the moment under review)
   │                       → toolbar: Adjust (popover), Sort menu, Settings sheet
   │              detail:  ReviewScreen, or ReviewStartView ("Clean Up 7 Moments")
   └─ Kept     KeptColumns     → same rule
        stack:  KeptScreen → KeptMomentScreen (pushed, zoom transition, tab bar hidden)
        split:  KeptScreen beside KeptMomentScreen, or "Choose a moment"
   What's New sheet               upgraders, once
```

- **Stack or split** (`DesignSystem/ColumnLayout.swift`, the one place for the rule): **split** when the horizontal size class is regular, the tab content is **≥ 740 pt** wide and the list is showing (access granted, ready, at least one moment); otherwise the iPhone **stack**. 740 pt comes from the content: a 300 pt sidebar plus a Review that still fits three 136 pt tiles. Every other state (primer, denied, indexing, failed, "All clean") is one full-width column. The container measures itself with `onGeometryChange` and publishes `\.columnLayout`.
- In a split, `ReviewScreen` reads `columnLayout` for exactly three differences: no push transition, the tab bar stays, and the status bar is never hidden. Finishing a review ends it in place: the detail returns to `ReviewStartView`, or the tab becomes the full-width celebration.
- Never more than **one sheet** at a time; screens inside a sheet push on the sheet's own stack. Settings and What's New are form-sized (`.presentationSizing(.form)`) when regular. **Adjust is a popover** anchored to its toolbar button when the Moments tab is split, so the list visibly regroups beside it (`.presentationCompactAdaptation(.sheet)` if the window narrows); in the stack it is the sheet. `router.sheet == .grouping` drives both.
- One toast host per tab container, on the trailing column (the `NavigationStack` in the stack, the detail in the split), so a toast never shows twice. The capsule is at most 480 pt wide. `toastHost(isRaised:)` is raised from model state while Review or the Kept moment is on top, and the capsule then sits above what that screen marks with `toastsStayAbove(_:)` (its bottom bar; in One by One the filmstrip and Keep toggle), so it never covers Skip, the main button or the ⋯ menu. It drops back as that screen starts to leave.
- **The tab bar** never minimizes (`.tabBarMinimizeBehavior(.never)`: minimizing moved the accessory differently per tab). In the stack it hides while Review or the Kept moment is pushed and comes back as soon as that screen starts closing (the router has let go of it while the screen is held for the pop), not after the zoom settles.
- **The bottom accessory** (**Clean Up 7 Moments**, `ReviewAccessory`) shows on **both tabs** whenever the Moments tab is stacked with moments listed and nothing is pushed on either tab (`RootView.showsAccessory`: `momentsPath` and `keptPath` empty; the accessory outlives a hidden tab bar and would cover the pushed screen's bottom bar). It deliberately doesn't check `router.tab`, so switching tabs never resizes the tab bar. From Kept it switches to Moments and starts the review there (`startReview(at: nil)`). In a split, `ReviewStartView` takes its place.
- **Delete 4 Photos**, **Keep All & Next** or **Skip** in Review moves on to the next moment. After the last one the user is back on the list with a summary toast.
- `Router` (in `PickrModels`) owns the tab, both navigation paths, the sheet and the current `ReviewSession`. Three invariants make a stack ↔ split swap lossless: `momentsPath.contains(.review) == (review != nil)` in both directions; `startReview(at:)` during a review replaces the session and carries the summary over (a sidebar tap, Previous Moment); and the last selection per moment is remembered for the app session. So collapsing a split mid-review lands on the pushed Review with the same moment, selection, mode and photo index.

## Adaptive layout

One layout for every iPhone, the iPhone Duo and every iPad. Views decide from **the space they are given**, never from the device.

- **Rules.** Width decisions read `horizontalSizeClass` and are written `== .regular` (a nil size class takes the narrow branch); height decisions read `verticalSizeClass`; geometric decisions read the view's own size with `onGeometryChange`, measured by the container that switches. Never the device model, `userInterfaceIdiom`, `UIScreen.main`, `UIDevice.current`, the interface orientation, `UIApplication.shared.windows`/`keyWindow`, posture or the hinge APIs. Models hold no layout. `ignoresSafeArea` names its edges and never the horizontal ones on content, because a vertical system bar can hold a side edge.
- **Grid.** The Review grid's column count comes from its own width: `min(6, max(3, Int(width / 180)))`, so tiles grow on bigger screens. Tiles larger than 360 px request the `viewer` size class (view size × scale); preheating uses the same class. `MomentCard`'s strip shows as many 48 pt thumbnails as fit (3–6).
- **Readable widths.** Full-width states, onboarding and the Kept empty state cap at 540 pt; cards in a wide stack at 680 pt; How Pickr. Finds Moments at 640 pt; the filmstrip at 560 pt; toasts at 480 pt.
- **Compact height** (a landscape phone): the onboarding hero and the One by One filmstrip hide (the Keep toggle stays); lists scroll and bars stay.
- **A bottom bar that floats** (the open iPhone Duo's detail column): the system lays Review's bottom bar over the content without reserving safe area. `ReviewSingle` measures the top of the bar's Skip button (`ReviewBottomBar.onTopChange`) and raises the filmstrip and Keep toggle just above it (`lift`, 0 wherever the bar reserves its space).
- **The pager on resize.** On a rotation, fold or window drag, the pager recomputes its item size and keeps the same photo centred (the `index` binding is the truth). It re-requests larger images only after the bounds grow by more than 10 % **and** the drag has ended (`effectiveGeometry.isInteractivelyResizing`). Horizontally it stays inside the safe area.
- **What survives a resize, rotation or fold:** the tab, paths, open review and sheet (`Router`); moment, selection, mode, photo index and summary (`ReviewSession`); the list's scroll anchor (state above the stack/split switch); the current toast; the ambient photo (shown at once; if the new layout puts another item under the focus line, that one fades in once). A pending bulk-delete dialog is dismissed with nothing deleted. A commit in flight survives only because buttons start it with `Task { await session.commit() }`, never inside `.task`.
- **iPhone Duo:** no posture or hinge code. Closed (466 pt) is the iPhone stack; open like a book (951 × 669 pt) is a split if the system reports regular width; open and turned (669 pt wide) is a roomy stack (669 < 740). Half-open uses whichever screen iOS lights.
- **Windows:** one scene (`UIApplicationSupportsMultipleScenes` = NO), because `AppServices` and the `Router` are app-wide; a second window could commit the same moment twice. The window resizes freely in Stage Manager and Split View. No orientation lock.
- **Keyboard** (`App/PickrCommands.swift`): a **Clean Up** menu in the iPadOS menu bar and the ⌘-hold overlay. Space **Keep Photo**; ⌘⌫ **Delete 4 Photos**; ⌘K **Keep All**; ⌘↓ **Skip**; ⌘↑ **Previous Moment**; ⌘1 / ⌘2 **All** / **One by One**; ⌥⌘1 / ⌥⌘2 the tabs; ⌘Z **Undo** while a toast offers it; ⌥⌘A **Adjust…**; ⌘, **Settings…**; ⌘R **Refresh**. Commands read `@FocusedValue(\.reviewSession)` (published by `ReviewScreen` with `focusedSceneValue`) and are disabled while a sheet or popover is up. Inside Review: ← / → photos or the focus ring, ↑ / ↓ rows, Return opens One by One, Esc goes back, 1–9 toggle photos 1–9. The focus ring is a solid 2 pt accent outline, shown after a key press.
- **Pointer:** tiles get a hover highlight and a hollow "click to keep" circle (solid content, never for touch); secondary click opens the context menus.
- **Drag-select** (`DesignSystem/DragSelect.swift`, every device): in the Review grid, a drag that starts clearly horizontal (or any pointer click-drag) paints keep or unkeep across a range, as in Photos; vertical drags keep scrolling. It applies `session.toggle(_:)` per changed tile with a selection haptic, auto-scrolls near the edges, and is only an accelerator: VoiceOver keeps the per-tile actions.

## Ambient backgrounds

The background is **blurred photos from the screen**, so the system glass above it picks up their colours. It is ambience, never decoration on content (`DesignSystem/AmbientColor.swift`, `.ambientBackground(_:strip:)`). `AmbientSource` has two cases: `.plain` and `.photo(PhotoID)`. There are no colour washes.

- **Lists: the photo strip.** The Moments and Kept lists in the stack pass their `ScrollFocus` as `strip:`. Every moment row's first photo (the one its card's strip leads with) sits 1:1 behind its row and scrolls with it. Photo *i* is fully opaque at row *i*'s vertical centre and blends linearly into photo *i + 1* by row *i + 1*'s centre; segments are drawn in painter's order, each over the one before with a top gradient mask, so there is never a gap. Above the first row the first photo reaches the top of the screen, below the last row the last photo reaches the bottom. Only the rows on screen plus one on each side are drawn (`DesignSystem/AmbientStripLayout.swift`, pure geometry). There are no time-based fades: a row whose photo arrives late shows its nearest neighbour's photo until then. Until rows report, the list's single source stands in.
- **Single photos:** Review and the Kept moment in **All** show the focused tile; **One by One** and the Kept photo the photo shown; the split's start views ("Clean Up 7 Moments", "Choose a moment") the first photo of the sidebar list's focused moment. Until a screen has reported, its first item. A new photo **cross-fades over the old one** in 0.6 s: the old one stays fully opaque until the new one is fully in and is then removed, so nothing passes through the plain background. Photos that arrive during a fade wait for it and only the latest follows (two layers at most).
- **Focus:** the row or tile whose frame crosses a line **40 % down** the scroll container wins; if none does, the nearest one; in a grid row, the tile nearest the centre (`DesignSystem/FocusLine.swift`, a pure function). `DesignSystem/ScrollFocus.swift` feeds it: `ScrollFocus<ID>` with `.scrollFocusContainer(_:)` on the `List` or `ScrollView`, `.scrollFocusItem(_:in:)` on each row or tile, and `.onScrollFocusChange` to copy the focus into state that outlives the container. Frames are measured in **window (`.global`) coordinates** with `onGeometryChange` (a named space on a `List` isn't guaranteed to resolve inside its rows). `focused` changes only when another item takes the line; `frames` changes every scroll frame and only the strip reads it. Read both in the background modifier, never in the list's body.
- **Row rules:** `scrollFocusItem` is never conditional (always the same view type, so a `List` row keeps its identity), and row traits (`.cardRow()`, `listRowBackground`, `listRowInsets`, …) go on the row's **outermost** view, where the `List` reads them. Plain-list section footers draw an opaque band over the strip, so footers are clear rows instead (`KeptScreen`).
- **One source per tab**, from model state and the focused item, never from the layout. In a split the **detail column** paints it; the sidebar paints nothing (`scrollContentBackground(.hidden)`) and shows its own system glass, though it still tracks its focus for the start view. In the stack the screen on top paints it.
- **Images:** no new image work while scrolling. `ThumbnailView` reports every final thumbnail it shows (card strips, filmstrip, grid tiles), and a backdrop of at most **64 px** on its longer side plus the photo's 8×8 average colour are drawn from it off the main actor (arithmetic, not ML). The blur is **baked into the backdrop once** with Core Image (`AmbientPalette.backdropBlurRadius`, 9 px, about a 60 pt blur at screen size); after that it is only scaled to fill. The **300** newest stay in memory per photo ID (about 12 KB each); nothing is persisted, and the strip holds the backdrops of the rows it draws. Only if a single photo hasn't been shown within **200 ms** does the modifier ask `ImageLoading` for its `.card` image.
- **No live blur, no `backgroundExtensionEffect()`.** On iOS 27 devices a SwiftUI blur on the background layer, and `backgroundExtensionEffect()`, both rendered the layer black (and a live blur cost a full-screen blur per scroll frame). Keep it that way.
- **Legibility** (`DesignSystem/AmbientPalette.swift`, pure colour maths): the backdrop at saturation 0.8; over it a tint, the photo's average colour tamed (saturation ≤ 0.45, lightness 0.88–0.96 in light and 0.04–0.09 in dark, blended 90/10 with `systemGroupedBackground`) at 42 %; then the dim, 25 % white in light and 35 % black in dark. In the strip each segment carries its own tint and the dim is drawn once over the whole strip. Primary text keeps about **5.6:1** in the worst case (5.62 light, 5.58 dark), swept over every average colour and every blend of two tints in the tests; the dim alone would give 2.0–2.4:1, so the tint is never left out.
- **Layout changes:** a container swap (stack ↔ split, rotation, a Duo fold) shows the current look at once and re-lays out the strip with the rows, with no fetch and no fade; if a grid puts another tile under the line, that photo then fades in once, as after a scroll.
- **Where not:** cards and tiles stay solid; the pager is clear around the photo; sheets, popovers, Settings and onboarding stay plain.
- **Accessibility:** Reduce Motion makes changes instant; Reduce Transparency or Increase Contrast give the plain background and load nothing; VoiceOver ignores it (decorative, no hit testing).

## Behaviour that tests lock

- **Grouping:** sort ascending by capture date, ties broken by identifier. A photo joins the current moment when `created − previous.created <= window`: **inclusive**, and **chained** to the previous photo, not the first. Moments with fewer than 2 photos are dropped. Moments are listed newest first, by their last photo.
- **What is scanned:** images with a capture date; hidden photos excluded; screenshots, Live Photos (one item), edited and iCloud-only photos included; bursts by their representative only; Kept photos removed before grouping.
- **Defaults:** "Photos taken within" 1 min (10 sec, 30 sec, 1 min, 3 min, or Other… for 1–120 min; `TimeWindow`), "Look back" Month (Week, 2 Weeks, Month, Everything, or Pick Dates…; `ScanRange` `d7`/`d14`/`d30`/`all`/`custom`), Vibration on, "Never delete favorites" on.
- **Tap to keep:** nothing is pre-selected except protected photos. A commit needs at least one kept and one deleted photo. After a partial delete the keepers go to Kept under "Photos you picked" (`reviewed`), so they never come back as leftovers.
- **Deletion:** one PhotoKit request per commit. A cancel is silent. On success the moment disappears at once. Stats change only after a confirmed delete.
- **Savings:** cards show the keep-one estimate (total minus the largest photo), as "… to free up"; the main button ("Delete 4 Photos" / "Frees up 6.8 MB") shows the exact sum. Unknown sizes make the figure "about …".

The golden cases are in `PickrCoreTests`. The fixture is the 40 test photos: 10 moments at a 10 s window, 9 at 30 s, 7 at 1 min, 3 at 3 min and 1 at 4 min.

## Contracts

`PickrCore/Contracts/` holds the shared types: `PhotoID`, `AssetRecord`, `Moment` and `MomentID` (the earliest photo's ID, so a moment keeps its identity across refreshes), `MomentList`, `ByteEstimate`, `TimeWindow`, `ScanRange`, `GroupingSettings`, `LibraryAccess`, `LibraryError`, `IndexEvent`, `DeletionReceipt` and the `PhotoLibraryClient` protocol:

```swift
public protocol PhotoLibraryClient: Sendable {
    func access() async -> LibraryAccess
    func requestAccess() async -> LibraryAccess
    func indexEvents() -> AsyncStream<IndexEvent>        // cached snapshot, progress, complete snapshot, then one per change
    func refresh() async                                 // single-flight
    func resolveSizes(_ ids: [PhotoID]) async -> SizeTable
    func currentRecords(_ ids: [PhotoID]) async -> [AssetRecord]   // re-fetch, hidden excluded
    func existingIDs(among ids: [PhotoID]) async -> Set<PhotoID>   // hidden INCLUDED (prune safety)
    func delete(_ ids: [PhotoID]) async throws(LibraryError) -> DeletionReceipt
}
```

The pure algorithms sit next to the contracts in `PickrCore`: `Clusterer`, `MomentPipeline` (range ∩ index − Kept → moments → order), `Savings`, `Selection`, `IndexMath`, `DensityHistogram` and `PickrFormat` (bytes, time spans, day titles). They take `now` and a `Calendar` as arguments; nothing in `PickrCore` reads the clock.

`PickrModels` holds the app state: `SettingsModel`, `KeptModel`, `LibraryModel`, `ToastCenter`, `ReviewSession`, `Router`, and `Curator`, **the only path that deletes, changes Kept or records stats**. `AppServices` wires them together; `LiveServices` in the app passes in the live photo library and `UserDefaults.standard`. Views read the models from the environment by type (`@Environment(LibraryModel.self)`, …), `Curator` as `@Environment(\.curator)` and the image loader as `@Environment(\.imageLoader)`.

What the views can count on:

- **Toasts come from the models, never from views.** `Curator` posts the delete, Keep All and Show Again toasts (Keep All and Show Again with Undo; Show All Again without) and an error toast with Try Again on every failure. `ReviewSession` posts "this moment changed"; `Router` posts the end-of-review summary, only if something was deleted. `ToastCenter.show(_:undo:)`, `showError(_:retry:)` and `dismiss(_:)` are the API, and `ToastCenter` is the only timer: 5 s, or 10 s while VoiceOver runs (`ToastHost` sets `displayDuration`). Views only add haptics, from the returned `CommitResult` or with `.sensoryFeedback` on `toasts.current?.id`. The toast texts live in `PickrModels/ToastMessages.swift`. That target has no resources, so they are added to `Localizable.xcstrings` by hand.
- **Rules for buttons and menus:** `Curator.canDeleteWhole(_:)` (false when every photo is protected: disable Delete All, say "Favorites are kept.") and `needsBulkConfirmation(wholeMoment:)` (20 or more deletable photos: show the extra dialog first). `ReviewSession` mirrors them for the current moment (`canDeleteWhole`, `needsBulkConfirmation`, `deletableCount`) and adds `isCommitting` (true while the iOS dialog is up: disable the bar), `deletionEstimate` (the exact size on the main button) and `keepAside()` (Keep All from the ⋯ menu, then move on).
- **Review lifecycle (`Router`):** `review != nil` exactly while `.review` is on `momentsPath`; popping it (Back, or `endReview()`) ends the session. Selections of moments left without a commit are remembered for the app session. When the queue ends, `Router` pops, posts the summary and sets `scrollTarget` to the last reviewed moment still listed; on Back or Esc mid-review `closeReview()` sets it to the current moment. The Moments list scrolls there without animation, behind Review, and sets it back to `nil`, so the zoom returns to a card on screen. The review destination keeps the `ReviewSession` it was built with (in `@State`), so the pop animation never shows an empty frame. `startReview(at:)` does nothing when the list is empty or the moment is gone, and closes any open sheet.
- **Launch:** `AppServices.init` only reads settings, so `onboardingCompleted` is right from the first frame. `launch()` doesn't open What's New; `RootView` presents it while `settings.showsWhatsNew` is true and calls `dismissWhatsNew()` on Continue (it stores `SettingsModel.whatsNewVersion`, "2.0").
- **Adjust changes regroup at once,** off the main actor, with no PhotoKit call; changes in the same main-actor turn share one computation. A `.custom` range without dates scans as 30 days.
- **Cost:** `KeptModel.groups(index:window:)` and `liveIDs(in:)` (the Show All Again count, live photos only) are O(library) on the main actor: compute them in `.task(id:)` or cache them, never in `body`. `LibraryModel.photoCount(in:)` is O(log n).

Changing a contract is a deliberate act: say so in the PR, and update the fake, the tests and this page with it.

## Concurrency

| Layer | Isolation | Rules |
|---|---|---|
| `PickrCore` | nonisolated; every type is a `Sendable` value | Pure functions. No `Task`, no globals, no `Date.now` or `Calendar.current`. |
| `PickrPersistence` | nonisolated structs over `KeyValueStore`; `actor KeptStore` | Atomic file writes happen inside the actor. |
| `PickrModels` and the app | MainActor by default, with `NonisolatedNonsendingByDefault` and `InferIsolatedConformances` | Models are `@Observable`. No `withAnimation` in models; views animate with `.animation(_:value:)`. Heavy pure work runs in `@concurrent nonisolated static func` helpers. |
| `actor LibraryIndexer` | its own actor | Owns the index, the size cache, the change token and the single-flight refresh. The only code that touches `PHAssetResource`. Only `Sendable` snapshots leave it. |
| `LibraryChangeObserver` | nonisolated `Sendable` class | Forwards PhotoKit change callbacks into an `AsyncStream`, debounced by 300 ms. |
| `ImageLoader` | nonisolated `Sendable` | Wraps `PHCachingImageManager` and a lock-protected ID → `PHAsset` cache. |
| `Deleter` | `@concurrent static func` | The hop off the main actor is explicit. |

- **Staleness:** `LibraryModel` keeps a generation counter and drops any regroup result that is out of date.
- **Cancellation:** views use `.task(id:)`; image streams cancel their PhotoKit request on termination; the indexer checks for cancellation while enumerating; the pager cancels in `prepareForReuse`. No fire-and-forget `Task {}` outlives its view.
- **Regrouping** happens on a change in the Adjust sheet, a Kept change, a new index snapshot, or (for Sort → Biggest First, `mostSpace`) a batch of sizes, at most every 500 ms. It is in memory and instant; nothing rescans the library.

## PhotoKit pipeline (`Pickr/Platform/Photos/`)

**Index.** The app keeps a persisted index of the library so it never rescans on launch or foreground.
- **Cold start:** load the on-disk cache (`IndexCache`, `Library/Caches/Pickr/index.v1.plist`) and show it at once as an incomplete snapshot, then refresh. The cache is a columnar binary plist (identifiers, dates, favorite and rating flags, sizes, the change token, and the access level it was built under). A cache built under another access level is deleted, never reused, and the cache is deleted when indexing starts with access denied. The layout is in [PERSISTENCE.md](PERSISTENCE.md#where-data-lives).
- **Refresh (single-flight):** with full access, a full-access cache and a saved change token, ask `fetchPersistentChanges(since:)` what was inserted, updated or deleted, fetch only those, and apply the delta. After history errors 3105/3210, under limited access, or with no cache, do a full build. Calls made during a refresh share it and get one more pass afterwards, so no nudge is lost.
- **Full build:** one image fetch, newest first, with hidden photos and non-representative burst frames excluded, user library only. It reads only identifier, creation date, modification date, favorite and rating, and never touches resources while enumerating. Progress every 1,000 records (when there is more than one chunk); on a first build, partial snapshots after 2,000 and every 10,000 more, so the default range fills in first. Partial snapshots never replace a cached index.
- **Cache writes** happen about 1 s after the index or sizes change, off the actor, atomically.
- **Queries** (`AssetQueries`) set every fetch flag explicitly and fetch identifiers in batches of 500. Re-fetches for delete and review use the index's visibility rules. Existence checks for Kept pruning are as inclusive as possible (hidden photos, every burst frame, shared and synced assets), and without full access every ID counts as existing.
- **Triggers:** launch, returning to the foreground (a cheap token check), PhotoKit change notifications (debounced by 300 ms), and the limited-library picker closing.

**Sizes.** `bytes = Σ PHAssetResource.dataSize` over every resource of the asset (the public iOS 27 API; no private keys). If every value is unknown, the photo's size is unknown and figures show "about". Sizes are fetched lazily, only for photos in moments, newest first, in batches of 200, and cached by (id, modification date).

**Images.** `ImageLoader` wraps `PHCachingImageManager` with one shared `PHImageRequestOptions` per kind, used for both requests and caching: card 144 px, filmstrip 168 px and tile 360 px are opportunistic, fast-resize and aspect-fill; the viewer is the view size × scale at high quality. Network access is allowed, so iOS may download iCloud originals. A lock-protected LRU holds 2,000 `PHAsset`s. Never `PHImageManagerMaximumSize`. All (grid) and the filmstrip preheat ±12 around the visible items; One by One preheats ±1. No preheating when the system prefers reduced resource use.

**The viewer** (`PhotoPager`, UIKit): each page asks for a quick `tile` image alongside the `viewer` image, so a page is never blank. A spinner appears only if the viewer image takes longer than 0.4 s. A viewer stream carries only the high-quality image, so a stream that ends empty means the load failed. The page then keeps the tile image and says "Couldn't download from iCloud", or "Couldn't load this photo" if nothing loaded; VoiceOver hears the note too. Don't put a placeholder back into the viewer stream. Not done yet (an `ImageLoadEvent` stream, proposed): a progress ring that fills up, and showing the iCloud note only for network errors.

**Deletion.** `Deleter.swift` is the **only** place that calls `PHAssetChangeRequest.deleteAssets`:
1. Re-fetch the IDs, hidden photos excluded.
2. If nothing is left, throw `.nothingToDelete`.
3. `PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(fetchResult) }`. iOS shows its own dialog; photos go to Recently Deleted for 30 days.
4. Return `DeletionReceipt(deleted:missing:)`. Stats count `deleted`, never what was requested.

**Safety rails** (in `Curator` and `Deleter`):
- Favorite or rated photos start as kept when "Never delete favorites" is on (the default), and Delete All skips them ("Favorites are kept."). A moment of only protected photos can't be deleted whole.
- A bulk delete of 20 photos or more asks once more in the app before the iOS dialog.
- Once one photo is kept, every photo that will be deleted shows a trash badge, and the main button always states the count ("Delete 4 Photos").
- Cancel is silent; any real failure shows an error toast with Try Again, on every path.

**Errors** map to `LibraryError`: user cancelled (3072, in either the Photos or the Cocoa domain) → `.cancelled`; access denied or restricted → `.notAuthorized`; library offline or switching → `.unavailable`; network errors → `.network`; `limitExceeded` → `.limitExceeded`; anything else → `.failed(domain:code:)`.

**Limited access** stays limited: the Moments screen shows "Pickr. can see only some of your photos." with **Choose Photos**, which opens the system limited-library picker through a small UIKit anchor, and Kept pruning never runs while access is limited. With access off it shows "Pickr. needs your photos to find moments." with **Open Settings**.

## Interface rules

- **Liquid Glass, system first.** Toolbars, tab bar, bottom accessory and sheets get glass from the system. An explicit `glassEffect` appears in only three files: `DesignSystem/ToastHost.swift`, `Features/Review/Filmstrip.swift` and `Features/Review/KeepToggle.swift`. Never glass on cards, tiles, photos or rows. Split views, sidebars, popovers and form sheets get system glass on their own; `ReviewStartView`'s button is inline (`.borderedProminent`); hover highlights and the focus ring are solid content. The toolbar item holding the iOS 27 `.tabs` picker (All / One by One) sets `.sharedBackgroundVisibility(.hidden)`: the picker brings its own glass, and the bar's shared glass drew a second outline.
- **Banned:** `presentationBackground`, `toolbarBackground`, `.ultraThinMaterial`, `safeAreaInset` for floating bars (use `safeAreaBar`), and custom segmented controls. `scripts/policy-check.sh` enforces the glass rules.
- **One prominent action per screen** (`.glassProminent`). Floating buttons are glass; inline buttons are bordered.
- **Confirmations:** deletes get the iOS dialog, plus one app dialog at 20 photos or more ("Delete all 47 photos in this moment?"). Reversible actions (Keep All, Show Again) get an undo toast and no dialog.
- **Motion** (BLUEPRINT §3.6): one movement per action, the same every time. Every animation is one of `Motion` in `DesignSystem/Theme.swift`: **advance** (`.smooth`, 0.35 s: the next moment slides in from the trailing edge, Previous Moment from the leading edge), **crossFade** (0.25 s: All ↔ One by One, a split's detail, a screen's states), **chrome** (0.2 s: bars and floating controls, a toast stepping aside), **listChange** (`.smooth`, 0.3 s: a row the person removed) and **reducedFade** (0.2 s: what replaces any movement under Reduce Motion). The system's own transitions (tab switch, push, sheet, popover, dialogs) are left alone; models never animate; a stack ↔ split swap never animates (`ColumnLayoutReader` drops it). Pushes zoom out of and back into their card (`zoomTransition`).
- **Accessibility:** every gesture has a visible control and an accessibility action. With Reduce Motion, zoom transitions become cross-fades.
- **Context-menu previews** get the image loader passed explicitly (`.environment(\.imageLoader, …)`): iOS hosts them outside the view's environment, where the default loader shows nothing.
- **Vibration** (haptics in code) uses `.sensoryFeedback` and respects the **Vibration** setting (`hapticsEnabled`): selection for toggles, success for a delete, error for a failure, a light impact for Keep All and Show Again. Commit results, and actions from the menu bar, play from the root through `CommandHaptics` (`App/PickrCommands.swift`), because the screen that started a commit may be gone when it ends.
- **Strings** are `LocalizedStringKey` / `String(localized:)` literals in an English String Catalog, so the app can be translated. Wording follows [Words](#words).
- **No `#available` checks.** The minimum is iOS 27.0; anything newer must be gated, and nothing is planned.

## Words

Say it the way you'd say it to a friend who has never heard of PhotoKit: name the outcome, not the mechanism. The app never says "scan", "range", "restore", "select", "invert", "session", "haptics" or "grouping". "Recently Deleted" stays, because that's the album's name in Photos; never "permanently".

| In the app | In code |
|---|---|
| moment | `Moment` |
| **Keep All** / **Delete All** (card swipes, Review ⋯) | `Curator.keepAside` / `Curator.deleteWhole` |
| **Delete 4 Photos** / "Frees up 6.8 MB"; **Keep All & Next** when every photo is kept; **Skip** | `ReviewSession.commit()` / `skip()` |
| **Clean Up 7 Moments** / "Frees up to 32 MB" (bottom accessory on both tabs in the stack, start view in the split); "… to free up" | `ReviewAccessory`, `ReviewStartView`, `Savings` |
| Kept tab: **Moments you kept** / **Photos you picked** | `KeptKind.keptAside` (and `legacy`) / `.reviewed` |
| **Show Again**, **Show Moment Again**, **Show Photo Again**, **Show All Again…** | `Curator.restore` / `restoreAll` |
| **Adjust** (toolbar button and sheet) | `GroupingSheet`, `GroupingSettings` |
| **Photos taken within**: 10 sec · 30 sec · 1 min · 3 min · Other… | `TimeWindow` |
| **Look back**: Week · 2 Weeks · Month · Everything · Pick Dates… (**First day** / **Last day**) | `ScanRange`, `CustomRangeScreen` |
| **Sort**: Newest First · Biggest First | `MomentOrder.newest` / `.mostSpace` |
| **All** / **One by One** | `ReviewSession.Mode.grid` / `.single` |
| **Vibration** | `hapticsEnabled` |
| **Never delete favorites** | `protectFavorites` |
| **Just now** / **All time**; **Photos deleted** / **Space freed up** / **Moments done** / **Using Pickr. since** | `ReviewSession.summary` / `LifetimeStats` |
| **How Pickr. Finds Moments** | `HowItWorksScreen` |
| **Clean Up** menu: **Keep Photo**, **Delete 4 Photos**, **Keep All**, **Skip**, **Previous Moment**; **Adjust…**, **Settings…**, **Refresh** | `PickrCommands` |
| "Choose a moment" (empty Kept detail in a split) | `KeptColumns` |

The iOS prompts and the PhotoKit delete dialog are system text. The one sentence inside the photo-access prompt is ours, in the same plain words (owner decision, `audit/COPY.md`): `NSPhotoLibraryUsageDescription` in `Info.plist`, "Pickr. looks at when your photos were taken to find near-duplicates taken seconds apart, so you can keep the best and delete the rest. Everything happens on your device."

## Logging

`os.Logger(subsystem: "com.juha.Culler", category: …)` (`photos`, `Library`, `Kept`, …), for errors only. Photo identifiers are always interpolated with `privacy: .private`; error domains and codes aren't personal and may be public. No `print`. `OSSignposter` intervals mark the full build, deltas, size batches, the first Moments frame and regrouping; they stay on the device. There is no telemetry and no MetricKit upload.

## Testing

| Suite | Runs | Covers |
|---|---|---|
| `PickrCoreTests` | `swift test` (CI) | golden grouping cases, property tests (order-independence, gaps, stable moment IDs), the test-photos fixture, `TimeWindow`, `ScanRange` around DST, selection, savings, formatting in `en_US`, `en_GB` and `fi_FI`, 200k records in well under a second |
| `PickrPersistenceTests` | `swift test` (CI) | every 1.0 key with its exact type, defaults, migration and its idempotency, failed saves ([PERSISTENCE.md](PERSISTENCE.md#things-the-tests-pin-down)) |
| `PickrModelsTests` | `swift test` (CI) | access × load phase (limited stays limited), regroup without a library call, deletion success, cancel and failure, stale moments, the review flow, protection, undo, pruning |
| `PickrAppTests` | simulator | `IndexCacheTests` (round trip, corrupt, other-version and unsorted files), `PhotoErrorMappingTests`, `ImageLoaderTests` (streams, cancellation, the iCloud failure), `AmbientTests` (`FocusLineTests`, `ScrollFocusTests`, `AmbientStripLayoutTests`, `AmbientPaletteTests`: the focus rule, the strip's segments and the worst-case contrast sweep), `DemoModeTests` (launch arguments, the delete guard, the demo library and loader), fetch-flag and access tests, and a live suite that needs `xcrun simctl privacy booted grant photos com.juha.Culler` and `xcrun simctl addmedia booted test-photos/*.jpg`: 40 records, a cached relaunch, 40 sizes, re-fetch and existence checks, a thumbnail |
| `PickrUITests` | simulator | first run, access and review against the live library, stopping at the Delete button; delete, toast and moving on in demo mode; an accessibility audit; on an iPad, open Review from the sidebar, keep two photos with Space, and check the highlight follows Skip. `DemoRecordingTests` (the README demos) are skipped unless `PICKR_DEMO=1` |

**Layout checks** (simulator, before iPad is turned on for a release): every screen on `iPad Pro 13-inch (M5)`, `iPad Pro 11-inch (M5)`, `iPad mini (A20 Pro)`, `iPhone Duo` and `iPhone 17 Pro`, in both orientations; a stack ↔ split swap mid-review (window resize, rotation, Duo closed → half-open → open → closed) keeping the moment, selection, mode and photo; the Adjust popover ↔ sheet flip; one toast above the right bar; the list strip following its rows with no gap or dip, the detail's photo under the bars, following the focus line as you scroll, with no flash on a fold, and plain with Reduce Transparency; the keyboard map; drag-select against scrolling; nothing under a vertical bar or the Duo's sensor housing.

A manual pass on a device before each release checks the ambient backgrounds render (not black) and covers VoiceOver, the largest Dynamic Type size, Reduce Motion, Reduce Transparency, Increase Contrast, limited and denied access, an iCloud-optimized library offline, a large library against the budget below, and cancelling the delete dialog.

## Demo mode (Debug builds only)

`Pickr/App/Demo/` lets the README demos be recorded on a real iPhone without touching anyone's photos or data. A Debug build launched with `-PickrDemo YES` (`-PickrDemoAppearance light|dark` forces the colour scheme):

- shows the 40 synthetic photos of `test-photos/`, which `project.yml` bundles in Debug builds only (capture times from their EXIF, made-up but stable sizes);
- never touches PhotoKit: `LiveServices` builds `DemoPhotoLibrary` and `DemoImageLoader` instead, so there is no access prompt, index cache or change observer, and deletes happen in memory with no iOS dialog;
- keeps settings and stats in an in-memory store and Kept in a fresh folder in the app's temporary directory, and TipKit in its own datastore there with every tip hidden; every launch starts the same (onboarding done, Look back Everything).

**Guards**, because a mistake here would delete real photos: every file in `Demo/` and every mention of it elsewhere is `#if DEBUG`, and Release excludes `test-photos/` (policy checks 22–22b); `Deleter` refuses demo mode before `performChanges` (22c), and `LivePhotoLibrary`, `ImageLoader` and `LibraryChangeObserver` `precondition` that it is off; the UI tests that run in demo mode check for the `pickr.demo-mode` accessibility marker before touching anything; no UI test touches SpringBoard, another app or an interruption monitor (23), so nothing can confirm an iOS delete dialog, and the live `PickrUITests` test stops at the Delete button. `scripts/demo-gifs.sh` drives `DemoRecordingTests` on the device ([RELEASING.md](RELEASING.md#readme-demos)).

## Performance budget (measured on a device)

| Metric | Target |
|---|---|
| Moments list, first frame with a cache, 50k library | < 300 ms after launch |
| Foreground refresh with no changes | < 50 ms |
| Adjust change (time or look-back) → new list | < 150 ms |
| Full build, 50k library | a few seconds, in the background, with progress, cancellable |
| Peak memory in One by One, 48 MP photos | < 250 MB |

Measured results are recorded here before each release.
