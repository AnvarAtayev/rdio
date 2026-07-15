<p align="center">
  <img src="docs/img/app-icon.png" width="112" height="112" alt="Rdio app icon">
</p>

<h1 align="center">Rdio</h1>

<p align="center">
  A tiny, native macOS menu bar radio player.
</p>

<p align="center">
  <a href="https://github.com/AnvarAtayev/rdio/releases/latest"><img src="https://img.shields.io/github/v/release/AnvarAtayev/rdio?label=version" alt="Latest version"></a>
  <a href="https://github.com/AnvarAtayev/rdio/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/AnvarAtayev/rdio/release.yml?label=build" alt="Build status"></a>
  <a href="https://github.com/AnvarAtayev/rdio/releases/latest"><img src="https://img.shields.io/badge/app%20size-1.5%20MB-blue" alt="App size"></a>
</p>

---

## Install

```sh
brew install --cask anvaratayev/tap/rdio
```

- Rdio is ad-hoc signed, not notarized, so macOS blocks the first launch.
- Open it
via **System Settings → Privacy & Security → Open Anyway**.

### Build from source

```sh
make app
open Rdio.app
```

Move `Rdio.app` to `/Applications` to keep it around. You'll need Xcode or the Command Line Tools.


## App features

### The menu

Everything lives behind the menu bar icon: play/pause, skip, shuffle, and
one-click switching between your stations. The one on air is checked.

<p align="center">
  <img src="docs/img/menu.png" width="300" alt="Rdio menu bar dropdown">
</p>

Media keys and Control Center work too.

### Find stations

**Settings/Stations.** Search the Radio Garden map of ~12,000 broadcasting cities, browse the most popular stations, or hit shuffle to land somewhere random in the world. Keep the ones you like.

<p align="center">
  <img src="docs/img/settings-stations.png" width="720" alt="Settings — Stations tab">
</p>

### Make it yours

**Settings/Design.** Choose the idle icon, and how the bars move while a station plays — spectrum, ripple, pulse, or nothing at all.

<p align="center">
  <img src="docs/img/settings-design.png" width="720" alt="Settings — Design tab">
</p>


## Stations file

Your stations live in `~/Library/Application Support/Rdio/stations.json`, seeded on first launch with SomaFM, Radio Paradise, FIP, and KEXP. Edit them in Settings, or open the JSON directly:

```json
[
  { "name": "SomaFM Groove Salad", "url": "https://ice2.somafm.com/groovesalad-128-mp3" }
]
```

Anything AVFoundation can play works as a `url`, including Radio Garden channels (`https://radio.garden/api/ara/content/listen/<id>/channel.mp3`).
