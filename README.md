<p align="center">
  <img src="logo.png" width="160" alt="Boldonic" />
</p>

# Boldonic

Re-render EPUB ebooks with a larger share of each word in **bold** — an assistive reading comfort feature. Converts a copy (keeps the original) or replaces the file; destination folder is your choice, any depth.

## What it does

- A full-screen Boldonic dashboard (**Convert A File** / **Settings** / **About**) inside KOReader's Tools menu.
- **Convert A File** scans your device and lists only **EPUB** files (case-insensitive): search and multi-pick from the list, or convert the file you're currently reading.
- **Settings** — Ratio presets (Light/Medium/Strong/Custom), copy/replace mode, destination folder (any depth, create new folders).
- **About** — Version info and how it works.
- **Persistent conversion log** — Tracks converted books by source path, survives plugin updates, works across destination folders.
- **Duplicate protection** — Flags already-converted books, shows "Convert again" confirmation before overwriting.
- **Offline & private** — No network access, all processing on-device.

## Screenshots

The three tabs of the dashboard:

| **Convert A File** — pick files and the destination folder | **Settings** — ratio, mode, destination | **About** — version & how it works |
|:---:|:---:|:---:|
| <img src="screenshots/convert-a-file-tab.png" width="280" alt="Convert A File tab: pick files and destination folder" /> | <img src="screenshots/settings-tab.png" width="280" alt="Settings tab: ratio, mode, destination folder" /> | <img src="screenshots/about-tab.png" width="280" alt="About tab: version and how it works" /> |

The picker and the destination browser:

| **File picker** — only EPUBs, searchable and paged | **Destination browser** — folder tree with create/new folder |
|:---:|:---:|
| <img src="screenshots/convert-a-file-tab.png" width="360" alt="File picker: EPUBs listed, searchable, paged" /> | <img src="screenshots/settings-tab.png" width="360" alt="Destination browser: folder tree with create new folder" /> |

## Setup

1. On your device, copy `boldonic.koplugin/` into KOReader's `plugins/` folder and restart KOReader — or install straight from **Storefront** (search "Boldonic").
2. Open **Tools → Boldonic** to open the dashboard.
3. Use **Convert A File** to pick EPUBs and choose a destination folder.
4. Adjust **Settings** for bolding ratio, copy/replace mode, and output folder.

## Build & test

```sh
./scripts/build-zip.sh             # → releases/Boldonic-Plugin.zip
luajit koreader-plugin/test/harness_boldonic.lua
```

See `AGENTS.md` for repo conventions. GitHub Actions checks the Lua, runs the harness, and builds the zip on each push/PR.
