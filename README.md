# Boldonic

**Boldonic** is a KOReader plugin that re-renders EPUB ebooks with a larger share of each word in bold — an assistive reading comfort feature. It makes text easier to read by bolding the first characters of each word, guiding the eye through the text.

## Features

- **Smart bolding engine** — Bolds the leading portion of each word (configurable ratio 10–90%), preserving readability while adding visual weight
- **Two conversion modes:**
  - **Copy original** (default) — Creates a `<book>_boldonic.epub` sibling file, keeps original untouched
  - **Replace original** — Rewrites the file in place, preserving reading progress & annotations
- **Flexible output** — Save copies next to the original or in any folder on the device
- **Full-screen dashboard** — Storefront-style UI with three tabs:
  - **Convert A File** — Device-wide EPUB picker with search, multi-select, real titles
  - **Settings** — Ratio, mode, destination folder
  - **About** — Version & how it works
- **Persistent conversion log** — Tracks converted books across folders, survives plugin updates
- **Duplicate protection** — Flags already-converted books, confirms before re-converting
- **Offline & private** — No network access, everything runs on-device

## Installation

1. Download the latest `boldonic.koplugin.zip` from [Releases](https://github.com/SkyWalker541/Boldonic/releases)
2. Unzip into `koreader/plugins/` on your device so you have `koreader/plugins/boldonic.koplugin/`
3. Restart KOReader
4. Open the menu → **Boldonic** to open the dashboard

## Usage

1. Open the **Boldonic** dashboard from the menu
2. **Convert A File** tab — Tap "Click Here To Convert File(s)" to pick EPUBs, or tap the "Currently open" row for one-tap conversion
3. **Settings** tab — Adjust bolding ratio, choose copy/replace mode, set output folder
4. **About** tab — Version info & how it works

## Requirements

- KOReader with `ffi/archiver` support (standard on recent builds)
- EPUB files (other formats not supported)

## License

MIT — see [LICENSE](LICENSE)
