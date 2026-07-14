# Rdio

A tiny, fast, native macOS menu bar radio player. No Electron, no Python, no
dependencies — a single small Swift + AVFoundation binary.

## Features

- Lives in the menu bar (no Dock icon)
- Simple dropdown with ⏮ ⏯ ⏭ transport buttons (previous/next steps through
  your saved stations) and one-click station switching
- **Settings window** (menu → Settings…, ⌘,) with a sidebar:
  - **Stations** — Radio Garden world map of ~12k broadcasting cities (click
    a dot to list its stations, search by name/city/genre, ▶ plays, ＋
    favorites) plus your editable favorites list below
  - **Design** — pick the idle menu bar icon (radio, antenna, waveform, …),
    the playing animation (live spectrum / ripple / pulse / none) with 3–8
    bars and a live preview, and whether the track title shows in the menu bar
  - **About** — version, update check (GitHub releases), start at login,
    Buy Me a Coffee link
- Shows the current track title in the menu and (optionally) the menu bar
- Media keys / Control Center integration, including next/previous station
- Auto-reconnects after short network drops
- Station list is a plain JSON file you can also edit by hand

## Build & install

Requires macOS 14+ and Xcode (or the Command Line Tools).

```sh
make app      # builds Rdio.app in the repo root
open Rdio.app
```

Move `Rdio.app` to `/Applications` to keep it around, and add it in
System Settings → General → Login Items to start it at login.

Dev loop:

```sh
make run       # run the bare binary from the terminal (Ctrl-C to quit)
make selftest  # connect to every saved station muted, report PASS/FAIL
```

## Stations

On first launch Rdio seeds `~/Library/Application Support/Rdio/stations.json`
with a few good defaults (SomaFM, Radio Paradise, FIP, KEXP). Edit them in
Settings → Stations (or open the JSON from there); changes are picked up the
next time the menu opens.

```json
[
  { "name": "SomaFM Groove Salad", "url": "https://ice2.somafm.com/groovesalad-128-mp3" }
]
```

Anything AVFoundation can play works as a `url`, including Radio Garden
channel URLs (`https://radio.garden/api/ara/content/listen/<id>/channel.mp3`).

## Notes

- The Radio Garden API is unofficial and could change without notice. Saved
  stations keep working regardless — searching is the only feature that
  depends on it.
- Some stations (often ones found via Radio Garden) stream over plain
  `http://`. Those play in the bundled `Rdio.app` — its Info.plist carries the
  App Transport Security exception for media — but not via `make run`.
- The waveform icon shows a real FFT spectrum (five log-spaced bands,
  ~40 Hz–16 kHz) on streams that expose an audio track to processing taps
  (e.g. SomaFM); other streams get a synthesized-but-cute dance.
  `make selftest` reports which is which, with per-band peaks.
