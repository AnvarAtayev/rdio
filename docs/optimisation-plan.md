# Rdio optimisation plan

Date: 2025-07-14
Baseline before any changes: 1.4 MB binary, 2.3 MB `.app` (almost half of that was
the 909 KB `AppIcon.icns`), 13 Swift source files, no third-party deps, targets
macOS 14.

## Already applied

### Icon shrink (2025-07-14)

`packaging/AppIcon.icns` shipped with 10 PNG slices from 16×16 up to 1024×1024,
total 909 KB. `LSUIElement` is `true` so there's no Dock icon; the largest context
the icon ever appears in is the About window at 88 pt, served by the 128/@2x slice.
The 256 / 512 / 1024 slices were dead weight. Dropped them, leaving 16, 16@2x, 32,
32@2x, 128, 128@2x.

| | Before | After | Saved |
|---|---|---|---|
| `AppIcon.icns` | 909 KB | 56 KB | 853 KB (−94%) |
| `Rdio.app` | 2.3 MB | 1.5 MB | ~800 KB (−35%) |

Investigation notes:

- macOS bundle icons are raster only — `CFBundleIconFile` / `.iconset` accept
  PNG slices packed into `.icns`. There's no SVG path through that resolution,
  so the only way to shrink the icns is to drop unneeded slices, not to switch
  to a vector source.
- The original icns had byte-duplicate slots: `icon_256x256.png` was identical
  to `icon_128x128@2x.png` (34 109 bytes) and `icon_512x512.png` matched
  `icon_256x256@2x.png` (126 277 bytes) — the same image stuffed into multiple
  slots. The largest unique slice was 1024² at 567 KB.
- An SVG master would be a nicer design source but isn't installed as a build
  tool here (`sips` doesn't render SVG; `librsvg` / `potrace` would need
  installing) and auto-tracing the existing PNG with `potrace` loses the gradient
  and anti-aliasing. Decided not to introduce an SVG pipeline for this pass.
- For a future vector source: keep one `master.svg` in the repo, run a script
  (`rsvg-convert` via `brew install librsvg`) generating the 6 needed slices
  into a `.iconset`, then `iconutil -c icns`. Out of scope for now.

## Remaining optimisations

### 1. Speed / CPU

**1.1 `AppDelegate.menuNeedsUpdate` reloads stations from disk on every menu open**
`AppDelegate.swift:248`. `Stations.load()` re-reads and JSON-decodes
`stations.json` from disk every time the menu opens, then compares full arrays
with `!=`. For a few dozen stations this is fine, but it's synchronous I/O on
the main thread during a menu-open animation.
Remedy: stat the file's mtime; only re-read + decode when it has changed. Cache
the last mtime alongside `stations`. Avoids the `Equatable` walk over the whole
list on every open.

**1.2 `IconStyle.current` / `IconStyle.barCount` re-read `UserDefaults` on
every animator tick — DONE (2025-07-14)**

Cache `style` and `barCount` on `WaveformIconAnimator`; `updateSettings()`
re-reads both from UserDefaults only when Settings changes them. The animator's
`init` already seeds the cache from `IconStyle.current` / `IconStyle.barCount`.
`AppDelegate`'s `onIconSettingsChanged` closure calls `animator.updateSettings()`
before `refreshUI()`, so the next tick reads cached values instead of hitting
UserDefaults 10×/sec.

**1.3 `WaveformIconAnimator.tick()` allocated a fresh `NSImage` every frame —
DONE (2025-07-14)**

Combined fix with three independent wins:

- **A. Reuse backing image.** A single `NSImage` is cached per bar count;
  `render(bars:)` redraws it via `lockFocus`/`unlockFocus`. The closure-based
  `NSImage(size:flipped:)` alloc per tick is gone; only the bars are repainted.
- **B. Cached backing bitmap.** A single `NSBitmapImageRep` is reused across
  ticks (reallocated only when `barCount` changes); each tick clears it with
  `CGContext.clear()` and redraws the bars into the same rep. The `NSImage`
  wrapper is created fresh per tick so the status button sees a new reference
  and redraws — reusing one `NSImage` instance silently skips the redraw. The
  pill shape (rounded `NSBezierPath`) is preserved.
- **C. 15 → 10 Hz.** `interval = 1.0 / 10.0`. Visually identical at 16 px; cuts
  every per-tick cost by 33%.
- **D. (covered by 1.2)** `tick()` reads `style`/`barCount` from cached fields
  instead of `IconStyle.current`/`IconStyle.barCount`.

After the cached image is drawn, `button?.needsDisplay = true` nudges the status
button to redraw since the image reference is the same each tick. Verified with
`swift run --selftest` — playback + tap path unchanged. The bar geometry
constants (`barWidth`, `gap`, `canvasHeight`, `minHeight`) are hoisted to the
top of the class so all draw paths agree.

**1.4 `IconPreview` runs a `TimelineView` at 15 Hz whenever the pointer hovers,
even on the About tab**
`SettingsWindow.swift:313`. The model's `windowIsVisible` correctly gates it,
but anyone who leaves the mouse resting on the preview keeps redrawing. Minor,
but the cadence `1.0/15.0` matches the menu bar and contends with it for
main-thread time.
Remedy: drop the preview to 10 Hz; it's a thumbnail.

**1.5 `refreshUI` is called on every `onChange` and walks all `stationItems`**
`AppDelegate.swift:206-209`. `stationItems` is iterated and `representedObject`
cast on every state change (including every track-title metadata update). For
6 stations irrelevant; for users with 100+ saved stations it's O(n) per
metadata tick.
Remedy: only the previously-checked and newly-checked items need their `state`
flipped — keep an `indexOfCurrent` var and update two items instead of n.

**1.6 `SettingsModel.updateVisiblePlaces` filters all 12k places on every
camera change**
`SettingsModel.swift:384-399`. The filter does a full scan plus a `.sorted`
plus `.prefix(150)` plus a `.map(\.id)` on both sides for the comparison — all
on the main thread, on every `.onEnd` map gesture.
Remedy:
- Pre-sort `allPlaces` by `size` once at load; the filter then preserves order
  and `.prefix(150)` needs no sort.
- Use a `Set<String>` for the current `visiblePlaces` IDs and compare with `==`
  instead of two `.map(\.id)` arrays.
- Better: grid-bucket places into lat/lon cells at load time so the filter is
  O(cells in view) not O(12k).

**1.7 `staticIcon` is recomputed every time the menu bar transitions back to idle**
`AppDelegate.swift:17-31,243`. Every `refreshUI` after stop/pause calls
`updateIconAnimation` which, when not animating, re-runs `staticIcon` —
re-rendering the SF Symbol into a fresh `NSImage`.
Remedy: compute once (lazily, then cache) and invalidate only when
`IdleIcon.current` changes (the `onIconSettingsChanged` path already exists).

### 2. Memory

**2.1 `RadioGarden.places()` cache lives in a static `var` — DONE (2025-07-14)**

`RadioGarden.swift:57` kept a process-lifetime `static var cachedPlaces`
holding ~12k `Place` structs (~1.8 MB). It was never released after the
settings window closed, and never needed if the user never opens
Settings → Stations.

Fix: deleted the static; `RadioGarden.places()` is now stateless — it reads
the on-disk cache (`placesCacheURL`, exposed for reuse) or fetches+caches the
payload each call. The in-memory copy lives only as `SettingsModel.allPlaces`,
which is already an instance property. Added `SettingsModel.releaseMapCache()`
which clears `allPlaces` + `visiblePlaces`; called from
`SettingsWindowController.windowWillClose`. The on-disk cache remains valid
for a week, so reopening the map re-populates without a network fetch.

**2.2 `SettingsModel` is a single big `ObservableObject` driving the whole
settings tree**
`SettingsModel.swift:117-264`. Every `@Published` mutation re-evaluates the
body of every SwiftUI view observing it. The 12k `visiblePlaces`, `panelStations`,
`searchText`, `isPlaying`, etc. all hang off one object, so e.g. each metadata
tick (`isPlaying`) reinvalidates the map view body, even though the map only
cares about `visiblePlaces`.
Remedy: split into two or three `ObservableObject`s — e.g. `MapModel`
(places / visiblePlaces / panelStations / focus), `StationsEditorModel`
(editable stations), `AppearanceModel` (icon / style / about). SwiftUI already
handles multiple `@ObservedObject` in one view. Biggest win for settings-window
redraw cost.

**2.3 `WaveformIconAnimator.history` is built but `displayed` keeps its own copy too**
`WaveformIcon.swift:59-60`. Minor, but for `ripple` mode `history` is appended
to and `removeFirst`'d every tick — tiny arrays (3–8 floats), but the array
storage gets reallocated as it grows.
Remedy: use a small ring buffer or `Array` with a fixed cap and an index.

**2.4 The settings window's `NSHostingController(rootView:)` keeps the entire
SwiftUI tree alive for the app's lifetime — DONE (2025-07-14)**

`SettingsWindow.swift:19` constructed the `NSWindow` + `NSHostingController` +
SwiftUI tree once in the controller's `init`, and the controller lived on
`AppDelegate` as a `lazy var` — so once first shown, the window + hosting
controller + SwiftUI tree (including any loaded map data) stayed alive for the
process.

Fix: `SettingsWindowController` is now a plain `NSObject` (not an
`NSWindowController`) holding a `private var windowController: NSWindowController?`.
`show(tab:)` lazily builds the window + hosting controller on first call, then
reuses them while open. `windowWillClose` (via `NSWindowDelegate`) sets
`windowController = nil` and calls `model.releaseMapCache()`, dropping the
window, the hosting controller, and the entire SwiftUI tree. The next `show`
rebuilds from scratch. `SettingsModel` persists across opens (it's owned by
`AppDelegate`, not the window controller), so editable stations and playback
state survive close/reopen. The handler wiring (`playHandler`,
`onIconSettingsChanged`, etc.) is on the model and is unaffected.

**2.5 The `levelMeter` tap is retained on `RadioPlayer` even when paused /
disconnected**
`RadioPlayer.swift:77`. After a pause, `pause()` sets `metadataOutput = nil`
(line 93, good), but the `itemStatusObservation` from the prior `play()` is
released only when a new item replaces it; paused state keeps the old
observation closure captured. Minor leak per pause-without-replay.

### 3. Consolidations / cleanliness

**3.1 Two near-identical HTTP helpers — DONE (2025-07-15)**

`RadioGarden.get`, the inline fetch in `RadioBrowser.topStations`, and
`UpdateChecker.latestVersion` were three copies of "URLSession + 200-or-throw".

Fix: added `Sources/Rdio/HTTP.swift` — `enum HTTP` with `get(_ url:)`,
`get(_ request:)` (for callers that set headers), and
`decode<T: Decodable>(_:from:)` (GET + JSON-decode in one step). Non-200
responses throw `HTTP.StatusError(code:)` so callers can match a specific
status. RadioGarden's three calls and RadioBrowser's fetch collapse to
`HTTP.decode(...)` one-liners; `RadioGarden`'s private `get` is deleted.
`UpdateChecker.latestVersion` uses `HTTP.get(request)` (keeping its
`Accept: application/vnd.github+json` header) and preserves its 404→nil
"no releases yet" sentinel by catching `HTTP.StatusError` where `code == 404`.
Net ~25 dup lines removed. Verified with `swift build -c release` and
`--selftest`.

**3.2 `UpdateChecker.repo` and `issuesURL` / `latestVersion` disagree — DONE (2025-07-14)**

`SettingsModel.swift:85-100` had `repo = "anvar936/rdio"` while `issuesURL` and
`latestVersion` hardcoded `"AnvarAtayev/rdio"` with double-slash typos
(`github.com//AnvarAtayev/...`, `api.github.com/repos//AnvarAtayev/...`).
Three issues: `repo` was defined but unused (intended single source of truth
was dead), the two URL literals disagreed with `repo` and each other, and both
had stray `/` segments that GitHub's API doesn't normalise.

Fix: set `repo = "AnvarAtayev/rdio"` (confirmed real GitHub repo) and made both
URLs interpolate from it:

```swift
static var issuesURL: URL {
    URL(string: "https://github.com/\(repo)/issues")!
}
static func latestVersion() async throws -> String? {
    let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    ...
}
```

Now `repo` is the only place the account name lives, so the three can't drift.
The 404 branch in the About page's update check
(`SettingsModel.swift:343-348`) now triggers only when the real repo genuinely
has no releases, instead of silently masking the wrong-URL bug as
"No releases published yet." Verified with `swift build`.

**3.3 Duplicate appearance-default registration**
`AppDelegate.swift:56-63` registers defaults including `AppAppearance.key`;
`SettingsModel.init` (`SettingsModel.swift:277`) reads `AppAppearance.current`
which falls back to `.system`. Fine, but `IconStyle.styleKey` default is
registered as `.spectrum` while `SettingsModel.init` (`:271`) redundantly falls
back to `.spectrum` via `?? .spectrum`.
Remedy: pick one mechanism.

**3.4 `player.onChange` fires on every track-title update, but most of
`refreshUI` only cares about state changes**
`RadioPlayer.swift:153-156`, `AppDelegate.swift:176-232`. Track title changes
drive `refreshUI`'s title-line and tooltip, but the whole body runs (including
`stationItems` walk + `transportView.update` + icon-animation re-decision).
Remedy: split `onChange` into `onStateChanged` and `onMetadata`, or pass a hint
payload. `refreshUI` then does the cheap path for metadata, the full path for
state.

**3.5 `MPRemoteCommandCenter` targets hop to main via `DispatchQueue.main.async`**
`RadioPlayer.swift:183,188,193,198,203,208`. `setUpRemoteCommandCenter` already
runs on main; the targets capture `weak self` and bounce to main, but
MPRemoteCommand handlers can be invoked off-main so the bounce is correct —
but the pattern is verbose (6 near-identical blocks).
Remedy: small helper `private func cmd(_ command: MPRemoteCommand,
handler: @escaping (RadioPlayer) -> Void)` that does the weak-self capture +
main bounce + `.success` / `.commandFailed`.

**3.6 `openMapSearch` and `openSettings` do the same thing — DONE (2025-07-15)**

Both routed to `settingsController.show(tab: .stations)`, so `openMapSearch`
was a byte-identical duplicate. Applied the minimal remedy: pointed the
"Search…" menu item's action at `#selector(openSettings)` and deleted
`openMapSearch`. Behaviour is unchanged (Search still opens the Stations tab);
a real distinction (e.g. a dedicated `.search` tab) can be added later without
resurrecting the dead selector. Verified with `swift build -c release`.

**3.7 `PanelStation` and `Station` conversions are duplicated**
`SettingsModel.swift:71,75-81,487-489,491-494`. `panelStation` / `station` /
`play` / `isFavorite` / `addFavorite` all convert between `PanelStation`,
`RadioGarden.Channel`, `RadioBrowser.Station`, and `Station`.
Remedy: `PanelStation` can `init(station: Station, id: String, subtitle: String)`
and `Station(from panel: PanelStation)`; the garden/browser adapters become
one-liners.

**3.8 `Station.location` and `EditableStation.location` and `defaultName` are
duplicated plumbing**
`Stations.swift:3-10`, `SettingsModel.swift:118-155`. The Codable `Station` and
the editable `EditableStation` carry parallel optional fields with the same
semantics. The conversion in `reloadStationsFromDisk` / `persistNow`
(`:284-289,322-332`) is field-by-field.
Remedy: make `EditableStation` a thin wrapper over `Station` + a `UUID`, or have
`persistNow` / `load` map with `Codable`-synthesised initialisers. Minor smell
but real 30 lines of glue.

### 4. App size

**4.1 `AppIcon.icns` shrink — DONE (see above).**

**4.2 The binary is 1.4 MB with SwiftUI linked**
`otool -L` shows `SwiftUI`, `_MapKit_SwiftUI`, `Combine` all dynamically linked
(good, not in the binary) but `__swift5_typeref` is 27 KB — ~7% of `__TEXT`.
These are inherent to using SwiftUI for the settings window. If you ever want
to push further, reimplement the three settings tabs in AppKit (the menu code
already is) and drop SwiftUI + Combine + _MapKit_SwiftUI dependency entirely.
The `Map` view is more work to replicate, but `StationsPage` minus the map is
straightforward AppKit. Not worth it now; flagged for completeness.

**4.3 Swift optimisation level**
`Makefile` uses `swift build -c release` (`.build/release/Rdio`). This is `-O`
by default. `-Osize` (size optimisation) typically saves 5–10% on Swift
`__text` at the cost of a little speed.
Remedy: try `swift build -c release -Xswiftc -Osize` and measure. For a menu
bar app the speed hit is invisible; the size hit on `__text` (294 KB) is real.

**4.4 `swift build` does not pass `-dead_strip_dylibs`**
Unused weak Swift runtime libs are still loaded at launch.
Remedy: add `-Xlinker -dead_strip_dylibs` to confirm only used libs survive.
Combined with `import` only where needed (e.g. `MapKit` is already gated to
`SettingsModel` / `StationsPage`), this reduces launch-time dyld work (not
binary size) — but improves cold-start time, which feels like "app size".

**4.5 `import MediaPlayer` in `RadioPlayer.swift` is one symbol cluster**
`RadioPlayer.swift:3`. `MediaPlayer` pulls `MPRemoteCommandCenter` +
`MPNowPlayingInfoCenter`. We use ~8 symbols out of a huge framework. It's
dynamic so it doesn't bloat the binary, but it does add to dyld binding at
launch (minor). Not actionable unless you drop the Control Center integration;
flagging only.

**4.6 No test target, no resources, no asset catalog — already minimal.**
Nothing to remove here. The `.gitignore` correctly excludes `.build` and
`Rdio.app`.

### Priority order

| # | Effort | Payoff |
|---|---|---|
| ~~4.1 shrink `AppIcon.icns`~~ | done | ~800 KB app size |
| ~~3.2 fix `UpdateChecker` URL typos / consolidate~~ | done | bug fix + cleanup |
| 2.2 split `SettingsModel` into ~3 ObservableObjects | 1–2 h | biggest CPU win in settings |
| ~~1.3 reuse one `NSImage` in the animator + drop to 10 Hz~~ | done | biggest steady-state CPU win |
| ~~2.1 / 2.4 release `cachedPlaces` + window controller on close~~ | done | ~1.8 MB reclaimed after Settings use |
| 1.6 grid-bucket places for `updateVisiblePlaces` | 1 h | smooth map on slow Macs |
| ~~3.1 one `HTTP` helper~~ | done | removed ~25 dup lines |
| 1.1 stat-based menu reload | 20 min | removes per-open decode |
| ~~3.6 unify `openMapSearch` / `openSettings`~~ | done | dead code removed |
| ~~1.2 cache style/barCount in animator~~ | done | tiny CPU |
| 1.7 cache `staticIcon` | 10 min | tiny CPU |
| 4.3 try `-Osize` | 5 min | likely 10–15 KB off binary |